---
name: pr-review-loop
description: Automated PR review loop — spawns Codex reviewer agents to review the current branch's open PR, then Claude addresses feedback, iterating until clean or limits hit. Use when the user asks to "review" / "run review loop on" the current PR, wants automated code review from multiple perspectives before merge, or invokes `/pr-review-loop`. Requires an open PR on the current branch.
---

# Automated PR Review Loop

Orchestrate a review loop between **Codex** (reviewer) and **Claude** (author) on the current branch's open PR.

## Priorities (ranked — the loop's behavior must reflect these)

1. **Code quality.** More reviews can help, but nonsense findings and loop-induced churn destroy quality. Stop when marginal findings are no longer worth addressing.
2. **Token efficiency.** Don't burn tokens on findings that won't change the code. Every round after convergence is waste.
3. **Wall time.** Parallelize where possible, but never at the cost of accuracy or reliability.

Every design decision — when to stop, what severity bar to apply, which agents to run — defers to (1) before (2) before (3).

## Modes

`$ARGUMENTS` is parsed for the word `verbose` (case-insensitive):
- **Default (quiet)**: findings stay local; a single summary is posted at loop end. Cleaner PR, fewer tokens.
- **Verbose** (`verbose`): every round is posted to the PR. See `verbose-mode.md` for posting mechanics.

Set `QUIET_MODE=true` unless `verbose` is in `$ARGUMENTS`. Tell the user which mode is active.

## Runtime: drive the whole loop within one turn

You may be running non-interactively under `claude --print` (e.g. a self-hosted
CI runner triggered by a label). In that mode **there is no turn resumption and
no scheduled wakeup — you are never re-invoked after you stop.** So you must
carry every phase to completion within a single turn: never launch background
work and then stop/yield to "wait" for it to finish and resume you. Anything you
background is orphaned and killed the moment you stop, and the loop dies silently
with no summary. Block on long-running work **inline** instead (see Phase 1
Step 4). This is also correct interactively — it just matters most here.

## Phase 0: Setup

**Preflight — required CLIs.** Before anything else, verify the external CLIs this skill shells out to are on PATH:

```bash
command -v codex >/dev/null 2>&1 || { echo "Error: Codex CLI not found on PATH. This skill uses the Codex CLI to run reviewer agents. Install: https://developers.openai.com/codex/cli"; exit 1; }
command -v gh    >/dev/null 2>&1 || { echo "Error: gh (GitHub CLI) not found on PATH. Install: https://cli.github.com/"; exit 1; }
```

If either is missing, stop and tell the user with the install link from the error message — do not proceed to the numbered steps below.

1. `git rev-parse --show-toplevel` to confirm we're in a git repo.
2. `gh pr view --json number,baseRefName,headRefName,url` — if no PR, stop and tell the user.
3. Extract: `PR_NUMBER`, `BASE_BRANCH`, `HEAD_BRANCH`, `PR_URL`, `OWNER/REPO` (`gh repo view --json nameWithOwner -q .nameWithOwner`).
4. `START_TIME=$(date +%s)`, `ITERATION=0`, `CONSECUTIVE_CLEAN_ROUNDS=0`.
5. Safety nets: `MAX_ITERATIONS=10`, `TIMEOUT_SECONDS=3600` (whole-loop, across rounds), `AGENT_TIMEOUT_SECONDS=900` (per-agent wall-clock watchdog — see Phase 1 Step 4). These are caps, NOT budgets — do not reduce thoroughness to fit within them. Note `TIMEOUT_SECONDS` is evaluated only *between* rounds (Phase 4) and so cannot interrupt a round that is currently hung; `AGENT_TIMEOUT_SECONDS` is the guard that actually bounds a single round's wall time.
6. **Locate the bundled scripts.** This skill ships its helper scripts and prompt fragments next to this SKILL.md, under `scripts/` and `prompts/`. Set `SKILL_DIR` to **this skill's base directory** — the absolute path printed as "Base directory for this skill" when the skill loads (equivalently, the directory this SKILL.md lives in). Anchoring on the base dir works for **both** install layouts: standalone (`~/.claude/skills/pr-review-loop`) and plugin (`.../plugins/pr-review-loop/skills/pr-review-loop`).

   ```bash
   SKILL_DIR="<this skill's base directory>"   # e.g. /Users/adriel/.claude/skills/pr-review-loop
   BUILD_PROMPTS="$SKILL_DIR/scripts/build-prompts.sh"
   LAUNCH_AGENTS="$SKILL_DIR/scripts/launch-agents.sh"
   ```

   `build-prompts.sh` self-locates its `prompts/` fragments relative to its own path, so you never pass the fragment dir. **Do NOT** anchor on `${CLAUDE_PLUGIN_ROOT}` — it is unset for standalone skill installs, so `${CLAUDE_PLUGIN_ROOT:?}/...` would hard-fail there.

7. **Scratch layout + GC.** State splits by lifetime: `history.md` persists per-PR so follow-up loops reuse prior pushbacks; the packet is per-run; **prompts/reviews/logs are per-round** (`$RUN_DIR/round-N/`) so a failed/timed-out agent in round N can never leak a stale file from round N−1 into the parse.

   ```bash
   mkdir -p /tmp/pr-review
   # Opportunistic GC: drop run dirs older than 7 days across all PRs.
   # Depth 3 = /tmp/pr-review/<PR>/runs/<RUN_ID>. history.md sits at depth 2 and is preserved.
   find /tmp/pr-review -mindepth 3 -maxdepth 3 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

   PR_ROOT=/tmp/pr-review/$PR_NUMBER
   RUN_ID="$(date +%s)-$$"
   RUN_DIR=$PR_ROOT/runs/$RUN_ID
   PACKET=$RUN_DIR/packet
   HISTORY=$PR_ROOT/history.md
   mkdir -p "$PACKET/files"
   echo "$RUN_DIR" > "$PR_ROOT/current-run"   # the ONE blessed pointer to this run — no ad-hoc *_rundir.txt / current_run files
   ```

   All subsequent phases reference `$PACKET`, `$RUN_DIR`, `$HISTORY`, and the per-round `$ROUND_DIR` (defined at the top of each Phase 1 round) — never the old `/tmp/pr-review-packet` or `/tmp/pr-review-history.md` paths, and never a hand-invented run-dir pointer file (Phase 0 writes exactly one: `$PR_ROOT/current-run`).

## Phase 0.5: Build the review packet

Pre-extract everything agents need into `$PACKET`. Without this, each of the 3–6 agents independently rediscovers the repo (cat diff, read CLAUDE.md, dump source files), which dominated token cost in prior runs.

**Resolve the base ref first.** `$BASE_BRANCH` is a bare name (e.g. `main`) from `gh pr view`. On the laptop a local `main` usually exists, but in a CI/runner checkout (the vault-bot `pr-runner`) only the PR head is checked out — bare `main` doesn't resolve, and neither may `origin/main`, so every `git diff "$BASE_BRANCH"...HEAD` errors. Resolve once, up front, fetching if needed, and hard-fail rather than silently producing an empty packet:

```bash
if git rev-parse -q --verify "refs/heads/$BASE_BRANCH" >/dev/null 2>&1; then
  :                                             # local branch (laptop)
elif git rev-parse -q --verify "refs/remotes/origin/$BASE_BRANCH" >/dev/null 2>&1; then
  BASE_BRANCH="origin/$BASE_BRANCH"             # remote-tracking ref present
else
  # head-only checkout (runner): fetch the base so a merge-base exists for the 3-dot diff.
  git fetch --no-tags origin "$BASE_BRANCH" 2>/dev/null \
    && BASE_BRANCH=FETCH_HEAD \
    || { echo "Error: cannot resolve base ref '$BASE_BRANCH' — no local/remote ref and fetch failed."; exit 1; }
fi
```

**One-time static copies** — only the review-relevant sections of the guideline docs, not the whole file. The full CLAUDE.md is often 10–12KB of deployment/planning/comms prose that every agent re-reads; a diff review needs only commands, testing, conventions, and style limits.

```bash
# Copy CLAUDE.md but drop sections irrelevant to reviewing a diff. Keep it simple:
# prefer to copy whole if unsure, but trim the obvious non-review sections when present.
[ -f CLAUDE.md ] && cp CLAUDE.md "$PACKET/CLAUDE.md"   # then trim in-place (see note below)
[ -f AGENTS.md ] && cp AGENTS.md "$PACKET/AGENTS.md"
[ -f .claude/skills/extensions/failure-patterns.md ] && cp .claude/skills/extensions/failure-patterns.md "$PACKET/failure-patterns.md"
```

After copying `$PACKET/CLAUDE.md`, read it and remove sections a code reviewer doesn't need (deployment, scheduling, planning/execution contracts, communication-style rules), keeping Project/Environment/Commands/Testing/Conventions/style limits. If a section's relevance is ambiguous, keep it — the goal is dropping obvious bulk, not aggressive pruning.

**Diff artifacts — a routine you re-run every round.** Claude pushes fixup commits between rounds, so the diff changes; regenerate these at the start of each round (Phase 1 Step 0), not just once:

```bash
# refresh_packet_diff: safe to re-run; overwrites the diff artifacts in place.
gh pr diff $PR_NUMBER > "$PACKET/diff.patch"

rm -rf "$PACKET/files"; mkdir -p "$PACKET/files"
# Per-file split — eliminates output-truncation re-read loops
gh pr diff $PR_NUMBER | awk '
  /^diff --git / { if (out) close(out); split($0, a, " "); f=a[4]; sub(/^b\//,"",f); gsub(/\//,"__",f); out="'"$PACKET"'/files/" f ".patch" }
  out { print > out }
'
# manifest.txt: exact per-file patch names, so agents read the right files instead of guessing paths or running `find` (the PR 470 token sink).
ls "$PACKET/files" > "$PACKET/manifest.txt"

git diff "$BASE_BRANCH"...HEAD -U30 > "$PACKET/diff-wide.patch"
git diff --stat "$BASE_BRANCH"...HEAD > "$PACKET/changed-files.txt"
```

The packet is the agent interface. The assembled agent prompts (see `agent-prompts.md`, built by `build-prompts.sh`) tell agents to read from here — including `manifest.txt` for exact filenames — and forbid whole-file dumps.

## Phase 1: Codex review

### Step 0: Start the round

Set up this round's directory and refresh the diff (Claude pushed fixups last round, so the diff has moved):

```bash
ROUND_DIR="$RUN_DIR/round-$ITERATION"   # ITERATION starts at 0; incremented in Phase 4
mkdir -p "$ROUND_DIR"
# Re-run the refresh_packet_diff routine from Phase 0.5 so diff.patch / diff-wide.patch /
# files/ / changed-files.txt / manifest.txt reflect the current PR head.
```

All prompt/review/log files for this round live in `$ROUND_DIR`, never in `$RUN_DIR` directly. This is what makes Step 5's "a missing review file means *this round's* agent failed" reasoning sound — a stale file from round N−1 sits in `round-$((ITERATION-1))`, out of this round's parse path.

### Step 1: Build review history (skip on first iteration)

If `ITERATION > 0`, update `$HISTORY` with asymmetric retention. Note `$HISTORY` may already contain content from a prior loop invocation on the same PR — that's intentional: follow-up reviews should inherit "All Prior Pushbacks" so the same disagreements aren't re-litigated.

- **`## All Prior Pushbacks`** — every pushback from every round, tagged by round number. Never dropped. These are the #1 source of loop non-convergence.
- **`## Recent Rounds`** — last 2 rounds only, with resolved findings and how they were fixed.

Example:
```markdown
## All Prior Pushbacks
- **R2** backend/api/routes.py:88 — CODEX suggested adding retry logic
  CLAUDE: "This endpoint is idempotent; retries belong at the caller level per architecture docs."
- **R5** backend/betting/identity.py:147 — CODEX flagged team slug validation
  CLAUDE: "Pre-existing PRIMARY KEY schema constraint. Schema migration is out of scope for this PR."

## Recent Rounds (last 2)
### Round N-1
CODEX: 0 CRITICAL, 6 IMPORTANT. CLAUDE: 4 fixed, 2 pushed back.
#### Resolved
- backend/api/routes.py:42 — Missing error handling → added try/except with logging
```

### Step 2: Choose which agents to run

Every review round launches **one parallel batch** — there is no serial "secondary round" (it was the single most frequent critical-path agent and rarely changed the verdict). The batch = the **core tier** plus the conditional pattern agent plus any **judgment add-ons** you select for this round.

**Core tier — always, every round, all parallel:**
`code-reviewer`, `test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`.

These four run on every round regardless of diff size. `type-design-analyzer` is in the core tier (promoted from the old secondary round) because it reliably surfaces real invariant/encapsulation IMPORTANTs and, running in parallel, adds ~0 wall time.

**Conditional add-on — `failure-pattern-analyst`:** `launch-agents.sh` runs it by default. When `$PACKET/failure-patterns.md` is absent, pass `--skip failure-pattern-analyst` (the persona self-short-circuits, but skipping avoids the launch cost).

**Judgment add-ons — you decide each round whether to include them, launched in the *same* parallel batch (never a separate round):**

| Agent | Add it when |
|---|---|
| `comment-analyzer` | The diff adds or changes a non-trivial amount of comments, docstrings, or docs whose accuracy is worth verifying — not just a couple of one-line comments. |
| `code-simplifier` | The change is large or spans multiple files with real logic complexity — a plausible candidate for consolidation/simplification. A small, single-file, mechanical diff is not. |

There is no fixed diff-size gate — judge from the packet (`changed-files.txt`, the diff). These two earn their keep on some PRs and are pure noise on others. Default to including a judgment add-on on the round where its trigger first clearly applies (usually the first round on a large diff); don't re-run it every round once it has reported, unless the change has grown materially. When in doubt on a small/clean diff, omit both. Add them with `--add comment-analyzer` / `--add code-simplifier`.

Never omit a **core-tier** agent — each catches a different class of issue. This is now enforced structurally: `launch-agents.sh` always runs the core tier and refuses `--skip` on a core agent, so the PR-470-style accidental omission of `silent-failure-hunter` cannot recur.

### Step 3: Build prompts with `build-prompts.sh`

**Do NOT hand-assemble prompts.** Improvised assembly — dropped discipline blocks, duplicated history, drifted read-rules — was the loop's single most frequent failure mode (a "verbatim" prior run still duplicated the whole history block). `build-prompts.sh` assembles them deterministically from the `prompts/` fragments; you only choose the roles and flags.

**(Optional) write a context note first.** If this PR benefits from scope framing an agent can't infer from the diff — its place in a stack/arc, or explicit non-goals ("PR3 of 3, frontend only; backend shipped in #469 — do not flag missing backend logic") — write it (≤6 lines) to `$ROUND_DIR/context.txt` and pass `--context`. This is the *only* prose you author; it rides under a fixed header, leaving the canonical blocks byte-exact. Omit it when the diff speaks for itself.

Then call the script once, listing exactly the roles Step 2 selected:

```bash
ROLES="code-reviewer,test-analyzer,silent-failure-hunter,type-design-analyzer,failure-pattern-analyst"
# add ,comment-analyzer / ,code-simplifier if selected; drop failure-pattern-analyst if no failure-patterns.md

"$BUILD_PROMPTS" \
  --packet "$PACKET" \
  --out "$ROUND_DIR" \
  --roles "$ROLES" \
  $( [ "$ITERATION" -gt 0 ] && printf -- '--history %s' "$HISTORY" ) \
  $( [ -f "$ROUND_DIR/context.txt" ] && printf -- '--context %s' "$ROUND_DIR/context.txt" ) \
  $( [ "$SEVERITY_FLOOR_ACTIVE" = "1" ] && printf -- '--severity-floor' )
```

`--history` only when `ITERATION > 0`; `--severity-floor` only when the rising floor is active (Phase 4 sets `SEVERITY_FLOOR_ACTIVE=1` when `CONSECUTIVE_CLEAN_ROUNDS >= 2`). The script writes `$ROUND_DIR/prompt-<role>.txt` for each role and exits non-zero if any fragment or role is missing — a half-assembled prompt never reaches an agent.

### Step 4: Launch agents

**The per-agent sandbox / model / effort config lives in `scripts/launch-agents.sh`** (the `role_config` function) — that script is the single source of truth, so this doc does not restate the table (it drifted from the code before). The script also sets the codex reasoning flags every agent shares: `-c model_reasoning_summary=concise` (minimizes "thinking" summary blocks; ~25% cheaper than the `auto` default) and `-c model_reasoning_effort` per role. The one runtime knob you pass is `--sfh-effort`: `high` for `silent-failure-hunter` while `CONSECUTIVE_CLEAN_ROUNDS == 0`, dropping to `medium` once `≥ 1` (after a clean round the deep error-path trace rarely surfaces anything new). To change any per-agent flag, edit `launch-agents.sh` and bump the plugin version — never hand-transcribe flags here.

Call the script once per round:

```bash
SFH_EFFORT=$( [ "${CONSECUTIVE_CLEAN_ROUNDS:-0}" -ge 1 ] && echo medium || echo high )

# ADDON_FLAGS: set from Step 2's judgment, e.g. ADDON_FLAGS="--add comment-analyzer"
# or "--add comment-analyzer --add code-simplifier"; leave empty to add neither.
ADDON_FLAGS=""
SKIP_FLAGS=$( [ ! -f "$PACKET/failure-patterns.md" ] && echo "--skip failure-pattern-analyst" )

AGENT_TIMEOUT_SECONDS=$AGENT_TIMEOUT_SECONDS \
"$LAUNCH_AGENTS" \
  --run-dir "$ROUND_DIR" \
  --repo "$(git rev-parse --show-toplevel)" \
  --sfh-effort "$SFH_EFFORT" \
  $SKIP_FLAGS $ADDON_FLAGS
```

The script reads `$ROUND_DIR/prompt-<role>.txt`, launches every selected agent in parallel each under a watchdog, `wait`s, and writes `$ROUND_DIR/.done`. It runs the **core tier unconditionally** and refuses to `--skip` a core agent. `--sfh-effort medium` once `CONSECUTIVE_CLEAN_ROUNDS ≥ 1` (after a clean round the deep error-path trace rarely surfaces anything new); `high` otherwise.

**Sandbox availability (locked-down containers).** If the environment variable `CODEX_SANDBOX_UNAVAILABLE` is set, `launch-agents.sh` overrides **every** agent's sandbox to `--dangerously-bypass-approvals-and-sandbox` (ignoring the per-role sandbox in its `role_config`). Some environments — notably unprivileged CI containers (e.g. a Railway-hosted self-hosted runner) — can't create the user namespaces Codex's `bubblewrap`/`landlock` sandbox needs, so **every** `codex exec` fails at sandbox setup (`Permission denied` creating a namespace) and the agents review nothing. (With the agent-failure detection in Step 5 these now surface as `AGENT_FAILED` rather than an ungrounded false-clean — but the round still does no real review, so the bypass is what lets it actually run.) Bypassing runs Codex with no OS sandbox and no approval prompts — acceptable **only** because such a runner is itself a locked-down, single-purpose, throwaway container (the container is the sandbox) reviewing trusted, same-repo PRs. When the var is unset (local/interactive), the per-role sandboxes apply unchanged so real sandboxing is in force. Export it before the `$LAUNCH_AGENTS` call:

```bash
[ -n "${CODEX_SANDBOX_UNAVAILABLE:-}" ] && export CODEX_SANDBOX_UNAVAILABLE   # the script reads it
```

**CRITICAL: After the first agent finishes, check its session header** — `head` the corresponding `$ROUND_DIR/log-<role>.txt` (first ~10 lines) and verify `reasoning effort` and `reasoning summaries` show the intended values, not defaults. If they show `high`/`auto` when you asked for something else, stop and debug the codex `-c` flags / CLI version before trusting the round. (On the runner the codex CLI can drift ahead of the laptop's — this check is the canary.)

**Watchdog rationale (why the script wraps each agent in a deadline poll):** codex has no reliable internal wall cap, and the loop-level `TIMEOUT_SECONDS=3600` is checked only *between* rounds (Phase 4) — it cannot interrupt a round that is currently hung. Log analysis found the median agent finishes in 2–10 min, but a handful of rounds ran **28–167 minutes** because codex sat in API-degradation/network backoff (or the laptop slept mid-run); token counts were normal, so the time was pure stall — and those tails were ~⅔ of all review-loop wall time. The per-agent deadline `AGENT_TIMEOUT_SECONDS` (default 900s) sits far above every legitimate agent and far below every observed stall. The poll is **deadline-based, not `sleep N && kill`** (a sleep timer is itself suspended on machine sleep and would never fire; a deadline poll compares wall-clock each tick and kills on the first tick after wake) — this guards server-side network stalls on the runner as well as laptop sleep. A watchdog-killed agent leaves a `WATCHDOG_KILLED` sentinel in its `review-<role>.txt`; Step 5 treats that as "no findings this round."

**Run `$LAUNCH_AGENTS` as ONE foreground bash call**, with a tool-timeout ≥ `AGENT_TIMEOUT_SECONDS` (the CI runner sets a high `BASH_DEFAULT_TIMEOUT_MS` for this). The script blocks internally — it launches the batch, then `wait`s until every codex PID has completed or been watchdog-killed, then writes `$ROUND_DIR/.done` — so the whole round stays inside one turn. **Do NOT** background the launch and then stop/yield to "wait" for it: per the Runtime note above, a non-interactive `claude --print` run is never resumed, so a backgrounded batch is orphaned and killed the instant you stop and the loop dies with no summary. (If a single call would exceed your bash tool-timeout, poll in-turn instead: start `$LAUNCH_AGENTS` `nohup`-detached, then loop short `sleep`+check bash calls until `$ROUND_DIR/.done` exists — still never yielding the turn.)

**Systemic-degradation guard:** if **every** agent in a round was watchdog-killed (all outputs are the sentinel / empty), do not treat the round as clean — exit the loop with status `CODEX_DEGRADED` and tell the user codex was unreachable/stalled and to retry later. A partial kill (some agents produced real output) proceeds normally on the agents that completed.

### Step 5: Read and parse findings

First check the launcher's exit: if `launch-agents.sh` exited non-zero, `$ROUND_DIR/.failed` lists the roles that **crashed** (codex exited non-zero without producing a review — bad/deprecated flag, untrusted or missing binary, auth error). A crashed agent is **not** "no findings" — it never ran. Do not treat a crash as clean: report it, surface the agent's `log-<role>.txt` (the first ~15 lines usually name the cause), fix the environment/flags, and re-run the round. If **every** agent crashed, exit `CODEX_DEGRADED` (same as the all-watchdog-killed case).

Then read each `$ROUND_DIR/review-{ROLE}.txt` and parse structured findings, classifying by trailing sentinel:
- ends with a `WATCHDOG_KILLED` line → the watchdog killed a stalled agent; note "no findings (watchdog-killed)" and do not retry inline.
- ends with an `AGENT_FAILED exit=N` line → the agent crashed (also in `.failed`); handle per the paragraph above — **never** count as "no findings."
- missing or empty with no sentinel and no `.failed` entry → treat as "no findings" (agent ran, said nothing). Because `$ROUND_DIR` is unique per round, a missing file unambiguously means *this round's* agent, not a stale prior-round file.

If **every** agent this round was watchdog-killed, follow the systemic-degradation guard in Step 4: exit `CODEX_DEGRADED`.

## Phase 2: Aggregate findings

1. Collect findings from all agents this round.
2. **Deduplicate**: if multiple agents flag the same `file:line` or the same underlying bug, merge into one. Log-analysis showed SFH + code-reviewer regularly double-count — aggressive dedup saves Claude effort in Phase 3.
3. Categorize as CRITICAL / IMPORTANT / SUGGESTION.

**Quiet mode**: keep findings in memory; do not post. Report locally: "Round {N}: X critical, Y important, Z suggestions."

**Verbose mode**: follow `verbose-mode.md` to post the review to the PR before Phase 3.

## Phase 3: Claude responds

1. For each finding: **Agree** (fix it), **Partially agree** (modified fix), or **Disagree** (pushback with written reasoning).
2. After each file edit: run project-appropriate format+lint with auto-fix on the changed file (e.g. `ruff format <file> && ruff check <file> --fix`).
3. Stage, fixup-commit, and push:
   ```bash
   FIXUP_TARGET=$(git log --oneline -1 --format="%H")
   git add <changed files>
   git commit --fixup=$FIXUP_TARGET -m "fixup! Address CODEX review round {N}"
   git push
   ```
4. **In parallel with posting/reporting**, run full validation (lint check, build/typecheck, tests). Commands come from CLAUDE.md / project config. If validation fails, fix, amend, force-push with `--force-with-lease`.
5. **Verbose mode**: post `CLAUDE:` response comment per `verbose-mode.md`. **Quiet mode**: report locally.
6. **Update `$HISTORY`**: append this round's round-summary + resolved items to `## Recent Rounds` (trim to last 2); append each pushback to `## All Prior Pushbacks` (grows forever).

## Phase 4: Loop check

> **Do not self-certify.** 80% of wrong CLEAN exits historically came from Claude declaring clean without Codex re-verifying the fixes.

1. `ITERATION++`.
2. If `$(( $(date +%s) - START_TIME )) >= TIMEOUT_SECONDS` → exit `TIMED_OUT`.
3. If `ITERATION >= MAX_ITERATIONS` → exit `MAX_ITERATIONS_REACHED`.
3b. If every agent this round was watchdog-killed (Phase 1 Step 4 systemic-degradation guard) → exit `CODEX_DEGRADED`.
4. Check exit conditions (first match wins):

   **CLEAN** if any of:
   - Claude made no code changes this round AND last Codex review had 0 CRITICAL (classic clean exit).
   - Last Codex review had 0 CRITICAL and every remaining IMPORTANT is either (a) in "All Prior Pushbacks" with Claude's rebuttal standing, or (b) Claude-declined-with-reasoning this round (**clean-on-pushback** — Claude is explicitly allowed to decline IMPORTANTs without a code change).
   - Every new IMPORTANT this round targets code Claude added THIS round to fix a prior finding (**fix-induced-only** — tail-chasing signature; another fix round just creates more surface).
   - `CONSECUTIVE_CLEAN_ROUNDS >= 3` (3 rounds without any CRITICAL is strong convergence).

   **NEEDS_HUMAN_REVIEW** if:
   - All issues from the previous round were pushbacks with no code changes AND reviewer is still surfacing the same disagreements (full author/reviewer standoff).

   **Otherwise** (Claude made code changes, no exit condition met):
   - If the latest review had 0 CRITICAL, increment `CONSECUTIVE_CLEAN_ROUNDS`. Otherwise reset to 0.
   - If `CONSECUTIVE_CLEAN_ROUNDS >= 2`, **raise the severity floor** for the next round (see Phase 1 Step 3 — agents get the 90%-confidence instruction).
   - Go back to **Phase 1**.

5. If exiting → Phase 5.

## Phase 5: Wrap-up

**Quiet mode**: post a single comprehensive PR comment — the full story of the loop. A human reading only this should understand everything.

```
CLAUDE: Automated Review Summary

## Overview
- Iterations: {N} rounds ({M} Codex + {N-M} Claude fix)
- Duration: {minutes}m
- Agents used: {list}
- Status: {CLEAN | NEEDS_HUMAN_REVIEW | TIMED_OUT | MAX_ITERATIONS_REACHED | CODEX_DEGRADED}

## Issues Fixed
- [severity] `file:line` — {original issue} → Fixed: {how}

## Issues Pushed Back
- [severity] `file:line` — {original issue}
  Author reasoning: {Claude's rationale}

## Remaining Suggestions (not addressed)
- `file:line` — {suggestion}

## Validation
- Lint / Build / Tests: PASS/FAIL (X passed, Y failed)

## Commits
{list of fixup SHAs with one-line descriptions}
```

Also post inline comments on the diff for pushed-back items and remaining suggestions (reuse the inline-comment posting logic in `verbose-mode.md`, step 4, but only for these unresolved items).

**Verbose mode**: post the short final summary from `verbose-mode.md`. Individual round comments already tell the story.

### Mark ready for review (CLEAN exits only)

After posting the wrap-up, **if and only if the loop exited `CLEAN`** (Phase 4), mark the PR ready for review when it is currently a draft:

```bash
if [ "$(gh pr view "$PR_NUMBER" --json isDraft -q .isDraft)" = "true" ]; then
  gh pr ready "$PR_NUMBER"
fi
```

Rationale: some repos (e.g. f1-predictions) keep PRs in draft *during* the loop so CI doesn't run on every review-loop push, then defer the single CI run to `ready_for_review`. Marking ready here fires that end-of-cycle CI. On repos that don't use draft-first the PR isn't a draft, so this is a no-op. **Never mark ready on a non-CLEAN exit** (`NEEDS_HUMAN_REVIEW` / `TIMED_OUT` / `MAX_ITERATIONS_REACHED` / `CODEX_DEGRADED`) — an unconverged PR must stay a draft and out of CI.

**Both modes**: report the final status and PR URL to the user.

## Bundled files

- `scripts/build-prompts.sh` — deterministically assembles agent prompts from `prompts/` fragments (Phase 1 Step 3)
- `scripts/launch-agents.sh` — launches the Codex batch under per-agent watchdogs; enforces the core tier (Phase 1 Step 4)
- `prompts/` — the prompt fragments: `_packet.txt`, `_history.txt`, `_severity-floor.txt`, and one persona file per agent
- `agent-prompts.md` — documents the fragments and assembly order (no longer hand-assembled)
- `verbose-mode.md` — PR-posting mechanics used only when `verbose` is passed
