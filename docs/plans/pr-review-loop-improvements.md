# Plan: pr-review-loop improvements (evidence-driven, July 2026)

**Status:** planned
**Source analysis:** transcripts from the f1-predictions #468/#469/#470 review pass (2026-07-04, `/tmp/pr-review/{468,469,470}`), comparison against the built-in `/code-review` methodology, and the vault-bot `pr-runner` deployment.
**Current plugin version:** 0.2.0

## Problems being solved (with evidence)

1. **Prompt drift.** Despite SKILL.md's bold "use prompts verbatim" warning, prompts shrank 5.7KB → 4.5KB → 2.9KB across the 468→470 session. The compressed 470 packet block dropped the `__` filename detail; code-reviewer wasted ~7 execs guessing paths and re-reading patches, read whole source files, never used `diff-wide.patch` — 84,925 tokens on a 5KB diff (test-analyzer: 10,527 in the same round). Instructions alone don't hold across a long session; the assembly must be deterministic.
2. **Core-tier violation.** silent-failure-hunter was silently omitted from both rounds of PR 470.
3. **Round overwrite.** Rounds reuse `$RUN_DIR`, overwriting `prompt-*`/`review-*`/`log-*`. Loses per-round transcripts AND breaks Step 5's "missing file unambiguously means failure" invariant from round 2 on (a failed round-N launch leaves round-N−1's review file to be parsed as fresh output). PR 446 improvised `-r2` dirs; 468–470 overwrote — unspecified, so behavior varies.
4. **Confirm-clean rounds cost like full reviews.** Final rounds: ~289k (468), ~345k (469), ~147k (470) Codex tokens for unanimous "No issues found."
5. **Severity inflation.** comment-analyzer's persona-local scale ("IMPORTANT = incomplete/outdated") contradicts the global bar ("senior reviewer would block merge") — a docstring wording nuance drove a fix in 469.
6. **Runner breakage (vault-bot).** `git diff "$BASE_BRANCH"...HEAD` fails on the Actions runner (no local base branch; bare `main` doesn't resolve to `origin/main`). `history.md` lives in container `/tmp` — pushback history silently resets across environments/redeploys.
7. **Improvised state files.** Five naming schemes for "where is the current run dir" (`.current_run_dir`, `CURRENT_RUN_DIR`, `433_rundir.txt`, …).

## Non-goals

- No adversarial verify layer between Codex and Claude (finding volume is 0–2/round; Claude-as-author already triages with full context).
- No change to the core loop shape (single parallel batch, quiet/verbose modes, exit conditions other than the fix-induced clarification below).
- No new agents (the two new review angles fold into the existing code-reviewer persona).

---

## PR 1 — Deterministic assembly + run hygiene (plugin 0.3.0)

The structural slice. Everything here removes improvisation surface; no review-behavior change intended.

### 1a. Prompt fragments + `build-prompts.sh`

- Convert `agent-prompts.md` into plain-text fragments under `skills/pr-review-loop/prompts/`:
  - `_packet.txt` (Review Packet Usage, with `{PACKET_PATH}` placeholder)
  - `_history.txt` (History Usage, with `{HISTORY_CONTENTS}` placeholder)
  - `_severity-floor.txt` (the rising-floor addendum)
  - `code-reviewer.txt`, `test-analyzer.txt`, `silent-failure-hunter.txt`, `type-design-analyzer.txt`, `comment-analyzer.txt`, `code-simplifier.txt`, `failure-pattern-analyst.txt`
- New `skills/pr-review-loop/scripts/build-prompts.sh`:
  ```
  build-prompts.sh --packet <dir> --out <round-dir> --roles r1,r2,... \
                   [--history <file>] [--severity-floor] [--context <file>]
  ```
  Concatenates `_packet` + (`_history`) + (`--context` file) + persona + (`_severity-floor`) per role, substitutes placeholders, writes `<round-dir>/prompt-<role>.txt`. Pure cat/sed; no model in the loop.
- `agent-prompts.md` shrinks to a short doc: assembly order, pointer to `prompts/`, and the rule that fragment edits are the ONLY way to change agent prompts.
- **CONTEXT block (formalizes the good half of the drift):** SKILL.md Phase 1 gains an optional step — Claude MAY write `$RUN_DIR/context.txt`, ≤6 lines, stating what the PR is, its place in a stack/arc, and explicit non-goals (the 470 improvisation: "backend fields shipped in #469; do not flag missing backend logic"). Passed via `--context`. Canonical blocks stay byte-exact.

### 1b. `launch-agents.sh`

- New `skills/pr-review-loop/scripts/launch-agents.sh` embedding the per-agent table (sandbox/model/effort), the deadline-poll watchdog, log redirects, and `.done` sentinel:
  ```
  launch-agents.sh --run-dir <round-dir> --repo <path> [--sfh-effort high|medium] \
                   [--add comment-analyzer] [--add code-simplifier] [--skip failure-pattern-analyst]
  ```
  Core tier (code-reviewer, test-analyzer, silent-failure-hunter, type-design-analyzer) is unconditional — there is no flag to skip a core agent (fixes the PR 470 omission). failure-pattern-analyst included by default, `--skip` only when `failure-patterns.md` is absent.
- Keeps the Step 4 header check (verify effort/summary config on the first finished agent) in SKILL.md.

### 1c. Round subdirectories + per-round packet refresh

- Layout becomes `$RUN_DIR/round-N/{prompt-*,review-*,log-*,context.txt}` with a shared `$RUN_DIR/packet/`.
- Phase 1 explicitly regenerates the diff artifacts (`diff.patch`, `diff-wide.patch`, per-file splits, `changed-files.txt`, `manifest.txt`) at the top of every round — currently unspecified; 468–470 happened to do it, but nothing requires it.
- Step 5's missing-file rule now reads from `round-N/` only, restoring the "missing ⇒ this round's agent failed" invariant.

### 1d. Packet improvements

- `manifest.txt`: `ls "$PACKET/files/" > "$PACKET/manifest.txt"`; `_packet.txt` names it — kills the path-guessing failure class even if discipline slips.
- **CLAUDE.md trim:** Phase 0.5 instructs Claude to copy only review-relevant sections (commands, testing, conventions, style limits) into `$PACKET/CLAUDE.md`, dropping deployment/planning/communication sections. Saves ~2–3k tokens × 5–6 agents × rounds.
- **Base-ref resolution (runner bugfix, lives in packet code so it lands here):**
  ```bash
  git rev-parse -q --verify "refs/heads/$BASE_BRANCH" >/dev/null 2>&1 || BASE_BRANCH="origin/$BASE_BRANCH"
  ```
  before any `git diff "$BASE_BRANCH"...HEAD`.

### 1e. State-file hygiene

- Phase 0 specifies: `echo "$RUN_DIR" > "$PR_ROOT/current-run"` — the one blessed location; SKILL.md forbids ad-hoc state files at `/tmp/pr-review/` root.

### Validation (PR 1)

- `shellcheck` both scripts.
- Golden test: run `build-prompts.sh` for all 7 roles against a fixture packet/history and diff the output against prompts assembled per the 0.2.0 instructions — byte-identical modulo intended changes (manifest line, trimmed-CLAUDE.md note).
- Live smoke: one full loop on a small draft PR (f1-predictions or a sandbox repo); confirm round dirs, manifest, current-run file, and that all core agents launched.

---

## PR 2 — Review-quality + token-efficiency behavior (plugin 0.4.0)

### 2a. Scoped verify rounds (the big token win)

New round type in Phase 4/Phase 1. **Trigger:** previous review round had 0 CRITICAL AND Claude's response this round was small and mechanical — tests-only, docs/comments-only, or a localized non-branching change (e.g. a type alias). **Shape:**
- Agents: code-reviewer + the persona(s) whose findings were addressed (2 agents typical).
- Packet gains `delta.patch` = diff of this round's fixup commits only; prompt scopes the review to verifying the fixes and spotting regressions in changed lines (full diff available for reference).
- Effort: medium; mini model where the persona table already uses it.
- **Escalation:** any CRITICAL/IMPORTANT from a scoped round ⇒ next round is a full batch. CLEAN can exit from a scoped round (Codex still verifies — this is not self-certification).
Expected saving: 100–250k Codex tokens + a few minutes per loop (every observed loop ended with a full-cost unanimous-clean round).

### 2b. Severity-scale alignment

- comment-analyzer: IMPORTANT only for *actively misleading* docs likely to cause a real downstream bug; everything else SUGGESTION.
- code-simplifier: cap at SUGGESTION except where complexity plausibly hides a defect.
- All personas: severity words defined by reference to the shared block ("would a senior reviewer block merge"), removing persona-local redefinitions.

### 2c. `failure_scenario` as a required output field

Every persona's output format gains: `Failure scenario: <concrete inputs/state → wrong output/crash>` (cleanup/doc findings: the concrete cost). If the agent cannot write one, the finding is downgraded or omitted. (Ported from /code-review; its strongest anti-speculation device.)

### 2d. Two new angles inside code-reviewer

Add focus bullets (no new agents):
- **Removed-behavior audit:** for every deleted/replaced line, name the invariant it enforced and find where the new code re-establishes it; a guard/validation/test that vanished is a candidate.
- **Cross-file trace:** for each changed function, grep callers and check for broken call sites (new precondition, changed return shape, new exception).

### 2e. Pushback evidence rule + fix-induced clarification

- Phase 3: a pushback must cite the code line, guard, or project convention that defeats the finding — not just assert judgment.
- Phase 4: fix-induced-only findings — Claude MAY address them (as in 468 R2), but the follow-up round is then a **scoped verify round**, not a full batch. (Reconciles the exit rule the transcripts show being ignored with the behavior that actually happened.)

### Validation (PR 2)

- Live loop on a real PR with at least one findings round; confirm the scoped round triggers, uses delta.patch, and escalates correctly if seeded with a deliberate bug in a fixup.
- Re-read one loop's history.md to confirm pushbacks carry citations.

---

## PR 3 — Cross-environment portability (plugin 0.5.0 + vault-bot repo changes)

### 3a. PR-resident history

- Wrap-up comment (both modes) embeds a machine-readable block:
  ```
  <!-- pr-review-loop:history
  {json: all prior pushbacks + last-2-rounds summary}
  -->
  ```
- Phase 0: if `$HISTORY` is absent (fresh container, other machine), reconstruct it from the newest `pr-review-loop:history` block in the PR's comments (`gh pr view --json comments`). Local file remains the working copy; the PR is the durable copy. Fixes the laptop↔runner split-brain and container-`/tmp` loss.

### 3b. In-flight guard

- Phase 0 posts a marker comment (`<!-- pr-review-loop:running <host> <epoch> -->`) and deletes it in Phase 5. If a marker fresher than 75 min from another host exists, abort with a clear message instead of racing fixup pushes. (Laptop run vs `review`-label runner run on the same PR.)

### 3c. vault-bot repo changes (separate PR in vault-bot)

- `.github/workflows/pr-review-loop.yml`: add an `if: always()` upload-artifact step capturing `/tmp/pr-review/<PR>/runs/` (logs, prompts, reviews) — today all runner-side telemetry dies with the container; this analysis would have been impossible for runner loops.
- `pr-runner/README.md`: note the codex CLI version can drift ahead of the laptop's; the Step 4 header check is the canary for `-c` flag breakage.

### 3d. Doc touch-up

- Watchdog rationale: note it guards server-side network stalls as well as laptop sleep (mechanism unchanged).

### Validation (PR 3)

- Loop a test PR locally → delete `/tmp/pr-review/<PR>` → re-run: history reconstructed from the PR comment (pushbacks not re-litigated).
- Label-trigger a run on the Railway runner: packet builds (base-ref fix from PR 1), artifact uploads, wrap-up posts.
- Start a local loop while a marker is fresh: confirm abort.

---

## Sequencing & mechanics

- Order: PR 1 → PR 2 → PR 3. PR 2's scoped rounds and persona edits ride on PR 1's fragments/scripts; PR 3's history block is independent but touches the same wrap-up section PR 2 adjusts.
- Each PR bumps `plugins/pr-review-loop/.claude-plugin/plugin.json` (0.3.0 / 0.4.0 / 0.5.0) per repo convention, and updates SKILL.md + README where behavior is described.
- Each PR goes through `/pr-review-loop` itself (dogfooding — the loop reviewing its own changes is the best live smoke test).
- After merge: refresh the plugin from the marketplace on the laptop; redeploy the pr-runner (it installs the plugin at entrypoint) so both environments pick up the same version.

## Decisions taken in-plan (flagging, not asking)

- Scoped verify rounds CAN exit CLEAN (Codex verifies; self-certification rule intact). If this ever produces a wrong CLEAN, tighten to "scoped round must be followed by one cheap full batch" — the escalation hook makes that a one-line change.
- `agent-prompts.md` is demoted to documentation; `prompts/` fragments become the single source of truth (two sources would re-create drift).
- In-flight guard uses a PR comment (visible, debuggable) rather than a hidden lock file or GitHub deployment — consistent with the loop's existing PR-comment surface.
