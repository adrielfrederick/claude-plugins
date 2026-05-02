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
5. Safety nets: `MAX_ITERATIONS=10`, `TIMEOUT_SECONDS=3600`. These are caps, NOT budgets — do not reduce thoroughness to fit within them.
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

| Condition | Agents |
|---|---|
| First iteration, OR last primary round had CRITICAL | **Primary** (all 3, parallel): `code-reviewer`, `test-analyzer`, `silent-failure-hunter` |
| Last primary round had 0 CRITICAL, diff ≥ 200 lines | **Secondary** (all 3, parallel): `comment-analyzer`, `type-design-analyzer`, `code-simplifier` |
| Last primary round had 0 CRITICAL, diff < 200 lines | Skip secondary entirely → Phase 5 |

**Conditional add-on — `failure-pattern-analyst`:** if `$PACKET/failure-patterns.md` exists, spawn this agent in parallel with the **Primary** tier on every primary round (and skip it on secondary-only rounds). When the file is absent, do not spawn it. The persona itself short-circuits if the file is missing from the packet, but gating in the skill avoids the launch cost on projects without patterns.

Never omit agents within a tier. Each catches a different class of issue.

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
| silent-failure-hunter | (default) | `-s read-only` | high | none |
| type-design-analyzer | gpt-5.4-mini | `-s read-only` | medium | none |
| comment-analyzer | gpt-5.4-mini | `-s read-only` | low | none |
| code-simplifier | gpt-5.4-mini | `-s read-only` | low | none |
| failure-pattern-analyst | gpt-5.4-mini | `-s read-only` | low | none |

Reasoning is controlled via the `-c` config override flag with these keys:
- `-c model_reasoning_summary=concise` — minimizes "thinking" summary blocks (API accepts `concise`, `detailed`, or `auto`; `none` is rejected). `concise` reduced per-agent token cost ~25% vs the `auto` default in prior runs.
- `-c model_reasoning_effort={low|medium|high}` — `high` only for `silent-failure-hunter` (traces error paths through call sites); `low` for pattern-matching agents.

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
- `silent-failure-hunter`: `SANDBOX="-s read-only"`, `MODEL_FLAG=`, `EFFORT=high`
- `type-design-analyzer`: `SANDBOX="-s read-only"`, `MODEL_FLAG="-m gpt-5.4-mini"`, `EFFORT=medium`
- `comment-analyzer`: `SANDBOX="-s read-only"`, `MODEL_FLAG="-m gpt-5.4-mini"`, `EFFORT=low`
- `code-simplifier`: `SANDBOX="-s read-only"`, `MODEL_FLAG="-m gpt-5.4-mini"`, `EFFORT=low`
- `failure-pattern-analyst`: `SANDBOX="-s read-only"`, `MODEL_FLAG="-m gpt-5.4-mini"`, `EFFORT=low`

**CRITICAL: After the first agent finishes, check its session header** (first ~10 lines of output) to verify `reasoning effort` and `reasoning summaries` show the intended values, not defaults. If they show `high`/`auto`, stop and debug the `-c` flags before launching more agents.

Run agents in parallel (background bash). **Do not wrap the invocation in `timeout`, `gtimeout`, or any equivalent.** GNU `timeout` is not portable (absent on default macOS, not installed by default on many Linux images) and prior runs showed every invocation emitting a `timeout: command not found` retry loop — so the per-agent cap was never actually in force anyway. Codex has its own internal completion semantics, and the loop-level `TIMEOUT_SECONDS=3600` guard in Phase 4 is the real backstop. If a future run genuinely hangs a single agent for tens of minutes, revisit with a portable watchdog (bash `sleep N && kill`) rather than adding an external dependency.

### Step 5: Read and parse findings

Read each `$RUN_DIR/review-{ROLE}.txt`. Parse structured findings. If the file does not exist or returned no structured output, skip that agent and note in the summary. (Because `$RUN_DIR` is unique per invocation, a missing file unambiguously means this run's agent failed — there is no risk of reading a prior run's output.)

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
- Status: {CLEAN | NEEDS_HUMAN_REVIEW | TIMED_OUT | MAX_ITERATIONS_REACHED}

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

**Both modes**: report the final status and PR URL to the user.

## Bundled files

- `agent-prompts.md` — the six agent personas plus shared Review Packet Usage and History Usage blocks
- `verbose-mode.md` — PR-posting mechanics used only when `verbose` is passed
