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
6. **Scratch layout + GC.** State splits by lifetime: `history.md` persists per-PR so follow-up loops reuse prior pushbacks; packet/prompts/reviews are scoped per-run so failed/timed-out agents can never leak a stale file into the next invocation.

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
   ```

   All subsequent phases reference `$PACKET`, `$RUN_DIR`, and `$HISTORY` — never the old `/tmp/pr-review-packet` or `/tmp/pr-review-history.md` paths.

## Phase 0.5: Build the review packet

Pre-extract everything agents need into `$PACKET`. Without this, each of the 3–6 agents independently rediscovers the repo (cat diff, read CLAUDE.md, dump source files), which dominated token cost in prior runs.

```bash
gh pr diff $PR_NUMBER > "$PACKET/diff.patch"

# Per-file split — eliminates output-truncation re-read loops
gh pr diff $PR_NUMBER | awk '
  /^diff --git / { if (out) close(out); split($0, a, " "); f=a[4]; sub(/^b\//,"",f); gsub(/\//,"__",f); out="'"$PACKET"'/files/" f ".patch" }
  out { print > out }
'

git diff "$BASE_BRANCH"...HEAD -U30 > "$PACKET/diff-wide.patch"
[ -f CLAUDE.md ] && cp CLAUDE.md "$PACKET/CLAUDE.md"
[ -f AGENTS.md ] && cp AGENTS.md "$PACKET/AGENTS.md"
[ -f .claude/skills/extensions/failure-patterns.md ] && cp .claude/skills/extensions/failure-patterns.md "$PACKET/failure-patterns.md"
git diff --stat "$BASE_BRANCH"...HEAD > "$PACKET/changed-files.txt"
```

The packet is the agent interface. Agent prompts (see `agent-prompts.md`) tell them to read from here and forbid whole-file dumps.

## Phase 1: Codex review

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

**Conditional add-on — `failure-pattern-analyst`:** if `$PACKET/failure-patterns.md` exists, add it to the parallel batch on every round. When the file is absent, do not spawn it (the persona self-short-circuits, but gating here avoids the launch cost).

**Judgment add-ons — you decide each round whether to include them, launched in the *same* parallel batch (never a separate round):**

| Agent | Add it when |
|---|---|
| `comment-analyzer` | The diff adds or changes a non-trivial amount of comments, docstrings, or docs whose accuracy is worth verifying — not just a couple of one-line comments. |
| `code-simplifier` | The change is large or spans multiple files with real logic complexity — a plausible candidate for consolidation/simplification. A small, single-file, mechanical diff is not. |

There is no fixed diff-size gate — judge from the packet (`changed-files.txt`, the diff). These two earn their keep on some PRs and are pure noise on others. Default to including a judgment add-on on the round where its trigger first clearly applies (usually the first round on a large diff); don't re-run it every round once it has reported, unless the change has grown materially. When in doubt on a small/clean diff, omit both.

Never omit a **core-tier** agent — each catches a different class of issue.

### Step 3: Build prompts from `agent-prompts.md`

**You MUST read `agent-prompts.md` and use those prompts verbatim.** Do NOT write your own prompt. This is the single most common failure mode in prior runs — Claude improvises a prompt, drops the severity-discipline block and the packet-read rules, and the agents waste tokens rediscovering the repo and producing low-quality findings. Follow these steps exactly:

1. Read `agent-prompts.md` (it's in the same directory as SKILL.md).
2. For each agent being launched this round:
   a. Start with the **Review Packet Usage** block (the ` ``` ` block under that heading in agent-prompts.md). Replace the `{PACKET_PATH}` placeholder with the actual value of `$PACKET` (e.g. `/tmp/pr-review/1234/runs/1712345678-9876/packet`).
   b. If `ITERATION > 0`, append the **History Usage** block (the ` ``` ` block under that heading) with `{HISTORY_CONTENTS}` replaced with the actual contents of `$HISTORY`.
   c. Append the agent's specific **persona** block (e.g. the `code-reviewer` section's ` ``` ` block).
   d. If the rising severity floor is active (see Phase 4), append: *"The loop has run 2+ rounds without a CRITICAL finding. Raise your bar — only report findings you are 90%+ confident would block a senior reviewer's approval. Anything below that is 'No issues found'."*
3. Write the assembled prompt to `$RUN_DIR/prompt-{ROLE}.txt`.

### Step 4: Launch agents

**Per-agent configuration** (flags per [CLI reference](https://developers.openai.com/codex/cli/reference), reasoning config per [advanced config](https://developers.openai.com/codex/config-advanced#model-reasoning-verbosity-and-limits)):

| Agent | Model | Sandbox | Effort | Summaries |
|---|---|---|---|---|
| code-reviewer | (default) | `--full-auto` | medium | none |
| test-analyzer | (default) | `--full-auto` | medium | none |
| silent-failure-hunter | (default) | `-s read-only` | high → medium once `CONSECUTIVE_CLEAN_ROUNDS ≥ 1` | none |
| type-design-analyzer | gpt-5.4-mini | `-s read-only` | medium | none |
| comment-analyzer | gpt-5.4-mini | `-s read-only` | low | none |
| code-simplifier | gpt-5.4-mini | `-s read-only` | low | none |
| failure-pattern-analyst | (default) | `-s read-only` | medium | none |

Reasoning is controlled via the `-c` config override flag with these keys:
- `-c model_reasoning_summary=concise` — minimizes "thinking" summary blocks (API accepts `concise`, `detailed`, or `auto`; `none` is rejected). `concise` reduced per-agent token cost ~25% vs the `auto` default in prior runs.
- `-c model_reasoning_effort={low|medium|high}` — `high` for `silent-failure-hunter` (traces error paths through call sites) **only while `CONSECUTIVE_CLEAN_ROUNDS == 0`; drop it to `medium` once `CONSECUTIVE_CLEAN_ROUNDS ≥ 1`** (after a clean round the deep trace rarely surfaces anything new, and SFH is a recurring critical-path agent); `low` for pattern-matching agents.

The invocation for each agent follows this exact pattern — do not improvise:

```bash
codex exec {SANDBOX} {MODEL_FLAG} \
  -c model_reasoning_summary=concise \
  -c model_reasoning_effort={EFFORT} \
  -C "$(git rev-parse --show-toplevel)" \
  -o "$RUN_DIR/review-{ROLE}.txt" \
  "$(cat "$RUN_DIR/prompt-{ROLE}.txt")"
```

Where for each agent:
- `code-reviewer`: `SANDBOX=--full-auto`, `MODEL_FLAG=`, `EFFORT=medium`
- `test-analyzer`: `SANDBOX=--full-auto`, `MODEL_FLAG=`, `EFFORT=medium`
- `silent-failure-hunter`: `SANDBOX="-s read-only"`, `MODEL_FLAG=`, `EFFORT=high` while `CONSECUTIVE_CLEAN_ROUNDS == 0`, else `EFFORT=medium`
- `type-design-analyzer`: `SANDBOX="-s read-only"`, `MODEL_FLAG="-m gpt-5.4-mini"`, `EFFORT=medium`
- `comment-analyzer`: `SANDBOX="-s read-only"`, `MODEL_FLAG="-m gpt-5.4-mini"`, `EFFORT=low`
- `code-simplifier`: `SANDBOX="-s read-only"`, `MODEL_FLAG="-m gpt-5.4-mini"`, `EFFORT=low`
- `failure-pattern-analyst`: `SANDBOX="-s read-only"`, `MODEL_FLAG=`, `EFFORT=medium`

**CRITICAL: After the first agent finishes, check its session header** (first ~10 lines of output) to verify `reasoning effort` and `reasoning summaries` show the intended values, not defaults. If they show `high`/`auto`, stop and debug the `-c` flags before launching more agents.

Run agents in parallel (background bash), each wrapped in a **per-agent wall-clock watchdog**.

Why this exists: codex has no reliable internal wall cap, and the loop-level `TIMEOUT_SECONDS=3600` is checked only *between* rounds (Phase 4) — it cannot interrupt a round that is currently hung. Log analysis of recent runs found the median agent finishes in 2–10 min, but a handful of rounds ran **28–167 minutes** because codex sat in internal API-degradation/network backoff (or the laptop slept mid-run); token counts on those agents were normal, so the time was pure stall, not work — and those tail runs were ~⅔ of all review-loop wall time. A hard per-agent deadline of `AGENT_TIMEOUT_SECONDS` (default 900s = 15 min) sits far above every legitimate agent and far below every observed stall, so it reclaims that tail without ever killing real work.

**Do NOT use GNU `timeout`/`gtimeout`** (not portable; absent on default macOS). Use a portable bash deadline poll, and it must be **deadline-based, not `sleep N && kill`** — a `sleep`-based timer is itself suspended when the machine sleeps, so it would never fire on a sleep-induced stall; a deadline poll compares wall-clock each tick and kills on the first tick after wake.

Launch each agent with this block (one per agent, all backgrounded so they run concurrently). It supersedes the bare invocation shown above — it adds the `log-$ROLE.txt` redirect and the watchdog:

```bash
# $ROLE, $SANDBOX, $MODEL_FLAG, $EFFORT set per the per-agent table above.
codex exec $SANDBOX $MODEL_FLAG \
  -c model_reasoning_summary=concise \
  -c model_reasoning_effort=$EFFORT \
  -C "$(git rev-parse --show-toplevel)" \
  -o "$RUN_DIR/review-$ROLE.txt" \
  "$(cat "$RUN_DIR/prompt-$ROLE.txt")" > "$RUN_DIR/log-$ROLE.txt" 2>&1 &
APID=$!
(
  DEADLINE=$(( $(date +%s) + AGENT_TIMEOUT_SECONDS ))
  while kill -0 "$APID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      kill -TERM "$APID" 2>/dev/null; sleep 5; kill -KILL "$APID" 2>/dev/null
      printf '\nWATCHDOG_KILLED after %ss\n' "$AGENT_TIMEOUT_SECONDS" >> "$RUN_DIR/review-$ROLE.txt"
      break
    fi
    sleep 15
  done
) &
```

After launching the batch, `wait` for the codex PIDs — each either completes or is watchdog-killed. A killed agent leaves a `WATCHDOG_KILLED` sentinel in its `review-$ROLE.txt`; Phase 1 Step 5 treats that (like an empty/missing file) as "this agent produced no findings this round" and notes it in the wrap-up.

**Systemic-degradation guard:** if **every** agent in a round was watchdog-killed (all outputs are the sentinel / empty), do not treat the round as clean — exit the loop with status `CODEX_DEGRADED` and tell the user codex was unreachable/stalled and to retry later. A partial kill (some agents produced real output) proceeds normally on the agents that completed.

### Step 5: Read and parse findings

Read each `$RUN_DIR/review-{ROLE}.txt`. Parse structured findings. If the file does not exist, is empty, or contains the `WATCHDOG_KILLED` sentinel (the watchdog killed a stalled agent), skip that agent and note it in the summary as "no findings (watchdog-killed)" — do not retry it inline. (Because `$RUN_DIR` is unique per invocation, a missing file unambiguously means this run's agent failed — there is no risk of reading a prior run's output.) If **every** agent this round was watchdog-killed, follow the systemic-degradation guard in Step 4: exit `CODEX_DEGRADED`.

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

- `agent-prompts.md` — the six agent personas plus shared Review Packet Usage and History Usage blocks
- `verbose-mode.md` — PR-posting mechanics used only when `verbose` is passed
