---
name: pr-review-loop
description: Automated PR review loop — spawns Codex reviewer agents to review the current branch's open PR, then Claude addresses feedback, iterating until clean or limits hit. Use when the user asks to "review" / "run review loop on" the current PR, wants automated code review from multiple perspectives before merge, or invokes `/pr-review-loop`. Requires an open PR on the current branch.
---

# Automated PR Review Loop

Orchestrate a review loop between **Codex** (reviewer) and **Claude** (author) on the current branch's open PR.

## Priorities (ranked — the loop's behavior must reflect these)

1. **Code quality.** More reviews can help, but nonsense findings and loop-induced churn destroy quality. Stop when marginal findings are no longer worth addressing. Tests the loop adds are code the PR has to carry: a loop that has added more test lines than production lines has stopped improving quality (Phase 3).
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
codex --version  >/dev/null 2>&1 || { echo "Error: codex is on PATH but won't run — likely a broken install (missing vendored binary, or macOS Gatekeeper/cert rejection). Run 'codex --version' to see the failure; reinstalling the npm package usually fixes it."; exit 1; }
command -v gh    >/dev/null 2>&1 || { echo "Error: gh (GitHub CLI) not found on PATH. Install: https://cli.github.com/"; exit 1; }
```

(`command -v` alone is not enough: a broken vendored binary passes it and then every agent dies mid-round — observed live when a codex release's signing cert was revoked.)

**Codex version floor.** The review roles are pinned to Codex models that have a hard client-version minimum — a too-old CLI is rejected *server-side* with a 400 ("requires a newer version of Codex"), not a clean "model not found", and the model names are baked into older CLIs so they *look* available. `launch-agents.sh` enforces the floor before spawning any agent and `die`s with the required version if the CLI is too old, so you don't check it here — but if a round dies with a "too old for the … models" message, upgrade Codex (`codex update` on a laptop; **rebuild the runner image** on the server, since it bakes Codex in at build time) and re-run. The exact models + floor live in `launch-agents.sh` (single source of truth).

If either is missing, stop and tell the user with the install link from the error message — do not proceed to the numbered steps below.

1. `git rev-parse --show-toplevel` to confirm we're in a git repo.
2. `gh pr view --json number,baseRefName,headRefName,url` — if no PR, stop and tell the user.
3. Extract: `PR_NUMBER`, `BASE_BRANCH`, `HEAD_BRANCH`, `PR_URL`, `OWNER_REPO` (`gh repo view --json nameWithOwner -q .nameWithOwner`).
4. **Loop state lives in a file, not in your head.** Every counter the exit decision reads — `ITERATION`, `START_TIME`, `PR_ROUNDS_TOTAL`, `CONSECUTIVE_CLEAN_ROUNDS`, `FIX_INDUCED_ROUNDS`, `SEVERITY_FLOOR_ACTIVE`, `SCOPED_NEXT`, `LAST_FIX_CLASS` — is owned by `scripts/loop-state.sh` and stored in `$RUN_DIR/state`. You never increment a counter, and you never evaluate an exit condition yourself: Phase 2 asks the script whether to fix (`triage`), Phase 4 asks it whether to continue (`round-end`), and you do what it prints. It is initialised in Step 8, once `PRIOR_ROUNDS` is known.

   **Why (0.15.0):** on f1-predictions#1155 every cap below was prose the model had to remember, and every one failed differently across a 24-round, three-run loop: the per-run cap fired and the driver started "run 2" itself; the per-PR budget was never evaluated in the second run; the fix-induced counter was never mentioned in 17 rounds. Counters in a long context get skipped; a verdict printed by a script gets obeyed.
5. Caps (defaults inside `loop-state.sh init`; override only if the user asks): `MAX_ITERATIONS=10` per run, `TIMEOUT_SECONDS=3600` per run, `MAX_PR_ROUNDS=12` per PR across all runs, `MAX_FIX_INDUCED_ROUNDS=3`, plus `AGENT_TIMEOUT_SECONDS=900` (per-agent wall-clock watchdog — see Phase 1 Step 4; not a loop-state key). These are caps, NOT budgets — do not reduce thoroughness to fit within them. `TIMEOUT_SECONDS` is evaluated only *between* rounds and cannot interrupt a hung round; `AGENT_TIMEOUT_SECONDS` is what bounds a single round's wall time.

   **A run that exits on any cap is over for this session.** `MAX_ITERATIONS_REACHED`, `FIX_BUDGET_EXHAUSTED`, `TIMED_OUT`: post the wrap-up and stop. Never start a second run yourself to "review the last round's fixes" — that is exactly how #1155 went from 10 rounds to 17 in one session, and `loop-state.sh` refuses a second `init` in the same run dir for that reason. A new run needs a human: re-label in CI, or re-invoke the skill. `MAX_PR_ROUNDS` is the cap that survives that re-label (it counts every round the PR has ever had — Step 8), and it is what terminates a PR the loop cannot converge on; f1-predictions#623 spent 13 rounds across two runs without either reaching the per-run cap.
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
   # Opportunistic GC: drop run dirs older than 7 days across all repos/PRs.
   # Depth 4 = /tmp/pr-review/<owner__repo>/<PR>/runs/<RUN_ID>. history.md sits at depth 3 and is preserved.
   find /tmp/pr-review -mindepth 4 -maxdepth 4 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
   # Legacy pre-0.7.0 layout (/tmp/pr-review/<PR>/ with no repo slug): GC whole PR dirs.
   # ! -name '*__*' so a digit-leading repo namespace (e.g. 37signals__rails) is never matched.
   find /tmp/pr-review -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' ! -name '*__*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true

   # Namespace by repo, not just PR number: a long-lived runner container hosts
   # several repos on ONE /tmp, so two repos' PR #12 must never share state — a
   # shared history.md would feed one repo's pushbacks into the other's review.
   PR_ROOT="/tmp/pr-review/${OWNER_REPO//\//__}/$PR_NUMBER"
   RUN_ID="$(date +%s)-$$"
   RUN_DIR=$PR_ROOT/runs/$RUN_ID
   PACKET=$RUN_DIR/packet
   HISTORY=$PR_ROOT/history.md
   mkdir -p "$PACKET/files"
   echo "$RUN_DIR" > "$PR_ROOT/current-run"   # the ONE blessed pointer to this run — no ad-hoc *_rundir.txt / current_run files
   ```

   All subsequent phases reference `$PACKET`, `$RUN_DIR`, `$HISTORY`, and the per-round `$ROUND_DIR` (defined at the top of each Phase 1 round) — never the old `/tmp/pr-review-packet` or `/tmp/pr-review-history.md` paths, and never a hand-invented run-dir pointer file (Phase 0 writes exactly one: `$PR_ROOT/current-run`).

   **Cross-call state — variables do NOT survive between bash calls.** Every bash snippet below runs in a fresh shell. Loop counters live in `$RUN_DIR/state` and are read back with `loop-state.sh get` (Step 4) — never carry them in your head. What does live in **your conversation** is the handful of paths and SHAs (`$SKILL_DIR`, `$RUN_DIR`, `$PACKET`, `$HISTORY`, `$ROUND_DIR`, `ROUND_BASE_SHA`, `SCOPED_THIS`): when you run a snippet, set every one it reads at the top of that same bash call (re-inline the literal values). Never paste a snippet whose variables you haven't defined in that call — an empty `$MARKER_CID` makes the marker deletion a silent no-op. The values that must survive even a fresh conversation are on disk: `$PR_ROOT/current-run` (this run's dir), `$PR_ROOT/marker-cid` (Phase 0.5 → Phase 5), and `$RUN_DIR/state` (every counter, plus `LAST_FIX_BASE_SHA` for the scoped delta).

8. **Reconstruct history + read the fix budget (both PR-resident).** `$HISTORY` lives in `/tmp`, which dies on a container redeploy and is never shared between the laptop and the runner. But "All Prior Pushbacks" is the #1 anti-non-convergence device — losing it silently re-litigates settled disagreements. So the wrap-up (Phase 5) embeds the history verbatim inside an HTML-comment block, and Phase 0 rebuilds `$HISTORY` from the newest such block whenever the local file is absent. The same fetch also yields `PRIOR_ROUNDS`, the PR's lifetime round count, which is read on **every** run (not only when the local file is missing) because it is what the Phase 4 fix budget spends:

   ```bash
   HISTORY_IO="$SKILL_DIR/scripts/history-io.sh"
   ROUNDS_FILE="$PR_ROOT/rounds-total"
   # Fetched UNCONDITIONALLY, not just when $HISTORY is missing: the same block
   # carries the fix-budget counter below, which has to be read on every run or
   # the budget silently resets whenever the local file happens to survive.
   # Match the exact HTML opener, not a bare mention — otherwise a human/bot
   # comment that merely says "pr-review-loop:history" could be picked by `last`
   # and clobber the real history. Warn (don't silently swallow) if the read
   # fails — losing prior pushbacks silently is exactly the non-convergence this
   # feature exists to prevent.
   # The selector (history-io.sh history-filter, tested by selftest.sh) requires
   # the opener at a LINE START, so a comment that only quotes the token in
   # prose can't be selected by `last` over an older comment holding the real
   # block. Extraction is anchored the same way — both ends of the round-trip
   # require a real opener, and both come from the one tested source.
   if ! body="$(gh pr view "$PR_NUMBER" --json comments \
     -q "$("$HISTORY_IO" history-filter)" 2>&1)"; then
     echo "Warning: couldn't read PR comments to reconstruct review history ($body) — proceeding without prior pushback history." >&2
     body=""
   fi
   # Only overwrite $HISTORY if extraction is non-empty AND the local copy is
   # absent — a live local file is newer than anything on the PR.
   if [ ! -f "$HISTORY" ] && [ -n "$body" ]; then
     extracted="$(printf '%s\n' "$body" | "$HISTORY_IO" extract)"
     if [ -n "$extracted" ]; then
       printf '%s\n' "$extracted" > "$HISTORY"
       echo "Reconstructed \$HISTORY from the PR's prior wrap-up (local file was absent)."
     fi
   fi
   # Rounds this PR has already had, across ALL prior runs — max of the local
   # file and EVERY `pr-review-loop:rounds N` marker on the PR (see
   # history-io.sh for why both exist and why max is the safe direction). Read
   # from every comment, not just the summary: since 0.15.0 the progress
   # comment carries the marker too, rewritten each round, so a run killed
   # mid-loop (the CI cap, a crash) still leaves its rounds on the PR. 0 on a
   # first run.
   all_bodies="$(gh pr view "$PR_NUMBER" --json comments -q "$("$HISTORY_IO" rounds-filter)" 2>/dev/null || true)"
   PRIOR_ROUNDS="$(printf '%s\n' "$all_bodies" | "$HISTORY_IO" rounds-total "$ROUNDS_FILE")"
   echo "This PR has had $PRIOR_ROUNDS review round(s) before this run."

   # Initialise the loop state (Step 4). Refuses to run twice in one run dir.
   LOOP_STATE="$SKILL_DIR/scripts/loop-state.sh"
   "$LOOP_STATE" init --state "$RUN_DIR/state" --rounds-file "$ROUNDS_FILE" --prior-rounds "$PRIOR_ROUNDS"
   ```

   From here `ITERATION`, `PR_ROUNDS_TOTAL` and the rest are read with `"$LOOP_STATE" get --state "$RUN_DIR/state" KEY` whenever a snippet needs them. If `init` warns that the PR is already at or over `MAX_PR_ROUNDS`, tell the user now: the run will do one round and exit `FIX_BUDGET_EXHAUSTED`, which is the intended behaviour, not a bug.

   The PR is the durable copy; the local file is just the working copy. This makes pushback history a property of the PR, not the machine that happened to run the last loop.

9. **In-flight guard — check (don't race another loop).** The runner's workflow `concurrency` serializes runner runs, but nothing stops a laptop loop racing a `review`-label runner loop on the same PR — both would push commits to the same branch. Here, only *check* for a live loop on another host and abort if found. `marker-blocks` exits 0 when a fresh marker from a different host holds the PR (its 75-min freshness window — just above the whole-loop `TIMEOUT_SECONDS` — treats anything older as a dead run):

   ```bash
   HOST="$(hostname)"; NOW="$(date +%s)"
   # Don't silently treat a comment-read FAILURE as "no marker" — warn and fall
   # back to best-effort (the guard is defense-in-depth atop the runner's
   # workflow concurrency; a transient gh blip shouldn't hard-fail the loop, and
   # if gh is truly down the packet build below fails loudly anyway).
   if ! existing="$(gh pr view "$PR_NUMBER" --json comments \
     -q '[.comments[].body | select(contains("pr-review-loop:running"))] | last // ""' 2>&1)"; then
     echo "Warning: couldn't read PR comments to check for a concurrent loop ($existing) — proceeding without the in-flight guard. If a runner loop is also active on this PR, cancel one." >&2
     existing=""
   fi
   if [ -n "$existing" ] && printf '%s' "$existing" | "$SKILL_DIR/scripts/history-io.sh" marker-blocks "$HOST" "$NOW"; then
     echo "Another pr-review-loop is running on PR #$PR_NUMBER from another host. Aborting to avoid racing pushes. If that run is dead, delete its 'pr-review-loop:running' comment and retry."
     exit 1
   fi
   ```

   A marker from the **same** host deliberately does not block: it's treated as a dead prior run on this machine (a crashed local loop must not lock you out for 75 minutes). Corollary: the guard does not protect two loops started concurrently on the *same* machine — never start a second loop on a PR this host is already reviewing.

   **Do NOT post your own marker here.** Posting is deferred to the end of Phase 0.5 (below) — after the fail-prone setup (base-ref resolution, packet build) has succeeded — so a preflight/setup hard-exit can never leave an orphaned marker that false-blocks the next run for 75 minutes. `MARKER_CID` stays unset until then, so Phase 5's deletion is a safe no-op on any early exit.

## Phase 0.5: Build the review packet

Pre-extract everything agents need into `$PACKET`. Without this, each of the 3–6 agents independently rediscovers the repo (cat diff, read CLAUDE.md, dump source files), which dominated token cost in prior runs.

**One-time static copies** — only the review-relevant sections of the guideline docs, not the whole file. The full CLAUDE.md is often 10–12KB of deployment/planning/comms prose that every agent re-reads; a diff review needs only commands, testing, conventions, and style limits.

```bash
# Copy CLAUDE.md but drop sections irrelevant to reviewing a diff. Keep it simple:
# prefer to copy whole if unsure, but trim the obvious non-review sections when present.
[ -f CLAUDE.md ] && cp CLAUDE.md "$PACKET/CLAUDE.md"   # then trim in-place (see note below)
[ -f AGENTS.md ] && cp AGENTS.md "$PACKET/AGENTS.md"
[ -f .claude/skills/extensions/failure-patterns.md ] && cp .claude/skills/extensions/failure-patterns.md "$PACKET/failure-patterns.md"
```

After copying `$PACKET/CLAUDE.md`, read it and remove sections a code reviewer doesn't need (deployment, scheduling, planning/execution contracts, communication-style rules), keeping Project/Environment/Commands/Testing/Conventions/style limits. If a section's relevance is ambiguous, keep it — the goal is dropping obvious bulk, not aggressive pruning.

**Diff artifacts — a script you re-run every round.** Claude pushes fix commits between rounds, so the diff changes; `refresh-packet.sh` regenerates `diff.patch`, the per-file `files/` splits, `manifest.txt`, `diff-wide.patch`, and `changed-files.txt`, and owns **base-ref resolution** (on a laptop the bare base branch exists locally; in a CI/runner head-only checkout it must resolve `origin/<base>` or fetch — it hard-fails rather than silently producing an empty packet). Call it here, and again at the top of every round (Phase 1 Step 0) — never hand-generate these artifacts:

```bash
"$SKILL_DIR/scripts/refresh-packet.sh" \
  --repo "$(git rev-parse --show-toplevel)" \
  --packet "$PACKET" \
  --pr "$PR_NUMBER" \
  --base "$BASE_BRANCH"     # the bare name from gh pr view; the script resolves it fresh each call
```

If it exits non-zero, stop and surface its error — do not improvise the artifacts by hand (hand-generated packets are the drift class the scripts exist to kill).

**PR-size gate (0.15.0) — before the marker is posted.** A packet above ~3,000 added lines does not converge: #1155 started at 3,900 and fed five reviewers something new for 24 rounds, and the runner's 75-minute cap gets about three rounds on a packet that size. Measure it, excluding artifacts a reviewer does not read (JSON, CSV, notebooks, lockfiles, snapshots, minified/generated code, binaries — `diff-size.sh` has the list; add project-specific patterns with `PR_SIZE_EXCLUDE='<glob>:<glob>'`):

```bash
"$SKILL_DIR/scripts/diff-size.sh" \
  --repo "$(git rev-parse --show-toplevel)" \
  --base-ref "$(cat "$PACKET/base-ref.txt")" \
  > "$RUN_DIR/size.txt"; SIZE_RC=$?
cat "$RUN_DIR/size.txt"
```

Read `verdict=` from `$RUN_DIR/size.txt`:
- `OK` — continue.
- `WARN` (≥ 1,500 counted lines) — tell the user the PR is large for a loop, name the counted total and the top files, and continue. Report it in the wrap-up's Overview.
- `STOP` (≥ 2,500 counted lines; exit code 3) — **do not review.** Post a wrap-up now (Phase 5 template, status `PR_TOO_LARGE`) giving the counted and excluded totals, the top files, and the recommendation: split the PR, or — if the count is inflated by a file type the exclusion list misses — re-run with `PR_SIZE_EXCLUDE='<glob>'`. Carry the `pr-review-loop:summary` and `pr-review-loop:rounds {PRIOR_ROUNDS}` markers as usual (CI's reconcile needs the summary marker). No in-flight marker has been posted yet, so there is nothing to remove; stop after the post.

The gate measures `git diff --numstat` against the same base ref the packet used (`$PACKET/base-ref.txt`), so a stale local base branch cannot inflate it any more than it could inflate the packet.

The packet is the agent interface. The assembled agent prompts (see `agent-prompts.md`, built by `build-prompts.sh`) tell agents to read from here — including `manifest.txt` for exact filenames — and forbid whole-file dumps.

**Post the in-flight marker now** (deferred from Phase 0 Step 9 — the fail-prone setup above has succeeded, so from here every exit funnels through Phase 5, which deletes it).

Post it with `gh-io.sh` — **never a bare `gh pr comment`**. Every GitHub *write* in this skill goes through that script, which retries with backoff and falls back from REST to GraphQL on each attempt. A single-shot `gh` call here is exactly what stranded two locks on reduction#10 during GitHub's 2026-07-16 degradation (REST 5xx'd; GraphQL was up the whole time). It also persists the comment's **node id** alongside the numeric id, which Phase 5's GraphQL fallback needs and which cannot be looked up later without the same REST endpoint that goes down:

```bash
GH_IO="$SKILL_DIR/scripts/gh-io.sh"
# Self-derive HOST/NOW — do NOT reuse Phase 0 Step 9's values: this snippet runs
# in a fresh shell (empty expansions would post a malformed marker that silently
# defeats the guard for other hosts), and the 75-min freshness window should
# start at posting time anyway, not at the earlier check.
HOST="$(hostname)"; NOW="$(date +%s)"
printf '🔒 pr-review-loop running on `%s` (auto-removed at loop end) <!-- pr-review-loop:running %s %s -->\n' \
  "$HOST" "$HOST" "$NOW" > "$RUN_DIR/marker-body.txt"
"$GH_IO" post-comment --repo "$OWNER_REPO" --pr "$PR_NUMBER" \
  --body-file "$RUN_DIR/marker-body.txt" --id-file "$PR_ROOT/marker-cid"
```

`post-comment` writes `"<databaseId> <nodeId>"` to `--id-file` as part of the same operation that posts, so there is no window where a marker exists on the PR that nothing knows the id of. Phase 5 reads that file back. If this call **fails** (both APIs down), it exits non-zero and no marker was posted — stop and tell the user GitHub is unreachable; do not proceed to review with no lock.

**Post the progress comment now** — a lightweight status table edited in place each round so anyone watching the PR can follow the loop's progress without waiting for the final summary. It carries a `<!-- pr-review-loop:progress -->` marker (deliberately NOT `pr-review-loop:summary`, so it can never satisfy reconcile). Phase 5 deletes it once the summary supersedes it.

```bash
{
  echo "### Review in progress"
  echo "<!-- pr-review-loop:progress -->"
  echo "<!-- pr-review-loop:rounds $PRIOR_ROUNDS -->"   # rewritten every round (Phase 2/3) so a killed run still counts
  echo
  echo "| Round | Agents | Findings | Fixed | Pushed back | Status |"
  echo "|:---:|---|:---:|:---:|:---:|---|"
  echo "| 0 | — | — | — | — | ⏳ reviewing… |"
} > "$RUN_DIR/progress.md"
"$GH_IO" post-comment --repo "$OWNER_REPO" --pr "$PR_NUMBER" \
  --body-file "$RUN_DIR/progress.md" --id-file "$PR_ROOT/progress-cid"
```

If posting the progress comment fails, log a warning and continue — progress visibility is nice-to-have, not load-bearing (though the `pr-review-loop:rounds` line it carries is what lets a run killed mid-loop still count toward the PR's budget; `$PR_ROOT/rounds-total` is the same-host backup). Set `PROGRESS_POSTED=1` on success, `0` on failure; every later edit checks this before calling `gh-io.sh edit-comment`.

**From this moment, every exit routes through Phase 5** — not just the enumerated statuses, but *any* fatal error in Phases 1–4: a failed `refresh-packet.sh` or `build-prompts.sh`, an unfixable agent-crash environment, a rejected push, a gh outage. If you must stop for any reason, first run Phase 5's marker-removal step (post the wrap-up too if there's anything to report). Never end the turn with the marker still posted — an orphaned marker false-blocks every other host for 75 minutes.

## Phase 1: Codex review

### Step 0: Start the round

Set up this round's directory and refresh the diff (Claude pushed fixes last round, so the diff has moved):

```bash
LOOP_STATE="$SKILL_DIR/scripts/loop-state.sh"; STATE="$RUN_DIR/state"
ITERATION="$("$LOOP_STATE" get --state "$STATE" ITERATION)"   # starts at 0; advanced by round-end in Phase 4
ROUND_DIR="$RUN_DIR/round-$ITERATION"
mkdir -p "$ROUND_DIR"
ROUND_BASE_SHA="$(git rev-parse HEAD)"   # HEAD *before* this round's fixes — used to compute the delta for a later scoped verify
[ "$ITERATION" -eq 0 ] && printf '%s\n' "$ROUND_BASE_SHA" > "$RUN_DIR/round-0-base-sha.txt"   # where the loop started; Phase 3's test budget measures from here
# Refresh the packet so diff.patch / files/ / manifest.txt / diff-wide.patch /
# changed-files.txt reflect the current PR head (Claude pushed fixes last round).
"$SKILL_DIR/scripts/refresh-packet.sh" \
  --repo "$(git rev-parse --show-toplevel)" \
  --packet "$PACKET" \
  --pr "$PR_NUMBER" \
  --base "$BASE_BRANCH"
```

All prompt/review/log files for this round live in `$ROUND_DIR`, never in `$RUN_DIR` directly. This is what makes Step 5's "a missing review file means *this round's* agent failed" reasoning sound — a stale file from round N−1 sits in `round-$((ITERATION-1))`, out of this round's parse path.

**Is this a scoped verify round?** Consume the flag Phase 4 set for this round, and if scoped, write the delta of the fix under verification (see "Scoped verify rounds" after Phase 4 for the full mechanics):

```bash
SCOPED_THIS="$("$LOOP_STATE" get --state "$STATE" SCOPED_NEXT)"   # set by round-end; each scoped round is decided fresh
if [ "$SCOPED_THIS" = "1" ]; then
  LAST_FIX_BASE_SHA="$("$LOOP_STATE" get --state "$STATE" LAST_FIX_BASE_SHA)"
  [ -n "$LAST_FIX_BASE_SHA" ] || { echo "scoped round with no LAST_FIX_BASE_SHA recorded — Phase 3 step 7 must set it" >&2; exit 1; }
  git diff "$LAST_FIX_BASE_SHA"...HEAD > "$PACKET/delta.patch"   # just the tests/docs-only fix being verified
fi
```

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
LOOP_STATE="$SKILL_DIR/scripts/loop-state.sh"; STATE="$RUN_DIR/state"
ITERATION="$("$LOOP_STATE" get --state "$STATE" ITERATION)"

"$BUILD_PROMPTS" \
  --packet "$PACKET" \
  --out "$ROUND_DIR" \
  --roles "$ROLES" \
  $( [ "$ITERATION" -gt 0 ] && printf -- '--history %s' "$HISTORY" ) \
  $( [ -f "$ROUND_DIR/context.txt" ] && printf -- '--context %s' "$ROUND_DIR/context.txt" ) \
  $( [ "$("$LOOP_STATE" get --state "$STATE" SEVERITY_FLOOR_ACTIVE)" = "1" ] && printf -- '--severity-floor' )
```

`--history` only when `ITERATION > 0`; `--severity-floor` only when the rising floor is active (`round-end` sets `SEVERITY_FLOOR_ACTIVE=1` in the state file once `CONSECUTIVE_CLEAN_ROUNDS >= 2`). The script writes `$ROUND_DIR/prompt-<role>.txt` for each role and exits non-zero if any fragment or role is missing — a half-assembled prompt never reaches an agent.

### Step 4: Launch agents

**The per-agent sandbox / model / effort config lives in `scripts/launch-agents.sh`** (the `role_config` function) — that script is the single source of truth, so this doc does not restate the table (it drifted from the code before). The script also sets the codex reasoning flags every agent shares: `-c model_reasoning_summary=concise` (minimizes "thinking" summary blocks; ~25% cheaper than the `auto` default) and `-c model_reasoning_effort` per role. The one runtime knob you pass is `--sfh-effort`: `high` for `silent-failure-hunter` while `CONSECUTIVE_CLEAN_ROUNDS == 0`, dropping to `medium` once `≥ 1` (after a clean round the deep error-path trace rarely surfaces anything new). To change any per-agent flag, edit `launch-agents.sh` and bump the plugin version — never hand-transcribe flags here.

Call the script once per round:

```bash
LOOP_STATE="$SKILL_DIR/scripts/loop-state.sh"; STATE="$RUN_DIR/state"
SFH_EFFORT="$("$LOOP_STATE" get --state "$STATE" SFH_EFFORT)"   # medium once CONSECUTIVE_CLEAN_ROUNDS ≥ 1, else high

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

**Run `$LAUNCH_AGENTS` as ONE foreground bash call**, with a tool-timeout ≥ `AGENT_TIMEOUT_SECONDS` (the CI runner sets a high `BASH_DEFAULT_TIMEOUT_MS` for this). The script blocks internally — it launches the batch, then `wait`s until every codex PID has completed or been watchdog-killed, then writes `$ROUND_DIR/.done` — so the whole round stays inside one turn. **Do NOT** background the launch and then stop/yield to "wait" for it: per the Runtime note above, a non-interactive `claude --print` run is never resumed, so a backgrounded batch is orphaned and killed the instant you stop and the loop dies with no summary. (If a single call would exceed your bash tool-timeout, poll in-turn instead: start `$LAUNCH_AGENTS` `nohup`-detached, then loop short `sleep`+check bash calls until `$ROUND_DIR/.done` exists — still never yielding the turn. **Bound that poll by a deadline** and treat expiry as a round failure, never as "keep waiting".)

**The poll-in-turn escape hatch above is for `$LAUNCH_AGENTS` only.** It is safe there for two specific reasons: the script writes `.done` as a discrete sentinel the instant it finishes, and it watchdog-kills its own agents, so the thing being polled is guaranteed to terminate. **Do not generalize it to other long-running commands** — build, typecheck, or test runs (see Phase 3 Step 4). Polling for one of those to finish re-creates the very hang the watchdog exists to prevent, because nothing is bounding the command itself. And never poll a file fed by a buffering pipeline: `cmd | tail -60` writes *nothing* until `cmd` reaches EOF, so a poll waiting for content in that file cannot succeed until the command it is waiting on has already exited.

**Systemic-degradation guard:** if **every** agent in a round was watchdog-killed (all outputs are the sentinel / empty), do not treat the round as clean — set status `CODEX_DEGRADED` and **go to Phase 5** (so the wrap-up posts and the in-flight marker is removed), telling the user codex was unreachable/stalled and to retry later. A partial kill (some agents produced real output) proceeds normally on the agents that completed.

### Step 5: Read and parse findings

First check the launcher's exit: if `launch-agents.sh` exited non-zero, `$ROUND_DIR/.failed` lists the roles that **crashed** (codex exited non-zero without producing a review — bad/deprecated flag, untrusted or missing binary, auth error). A crashed agent is **not** "no findings" — it never ran. Do not treat a crash as clean: report it, surface the agent's `log-<role>.txt` (the first ~15 lines usually name the cause), fix the environment/flags, and re-run the round. If the environment **can't** be fixed (broken codex install, revoked auth), set `CODEX_DEGRADED` and go to Phase 5 — don't stop mid-loop with the marker posted. If **every** agent crashed, set `CODEX_DEGRADED` and **go to Phase 5** — never a direct exit once the in-flight marker is posted, since Phase 5 is what removes it (same routing as the all-watchdog-killed case).

Then read each `$ROUND_DIR/review-{ROLE}.txt` and parse structured findings, classifying by trailing sentinel:
- ends with a `WATCHDOG_KILLED` line → the watchdog killed a stalled agent; note "no findings (watchdog-killed)" and do not retry inline.
- ends with an `AGENT_FAILED exit=N` line → the agent crashed (also in `.failed`); handle per the paragraph above — **never** count as "no findings."
- missing or empty with no sentinel and no `.failed` entry → treat as "no findings" (agent ran, said nothing). Because `$ROUND_DIR` is unique per round, a missing file unambiguously means *this round's* agent, not a stale prior-round file.

If **every** agent this round was watchdog-killed, follow the systemic-degradation guard in Step 4: set `CODEX_DEGRADED` and go to Phase 5 (never exit before Phase 5 once the in-flight marker is posted — Phase 5 removes it).

## Phase 2: Aggregate findings

1. Collect findings from all agents this round.
2. **Deduplicate**: if multiple agents flag the same `file:line` or the same underlying bug, merge into one. Log-analysis showed SFH + code-reviewer regularly double-count — aggressive dedup saves Claude effort in Phase 3.
3. Categorize as CRITICAL / IMPORTANT / SUGGESTION. From here "findings" means CRITICAL + IMPORTANT after dedup; SUGGESTIONs never drive a round.

3a. **Bucket every finding into exactly one of three, then ask the state script whether the round is worth fixing.**
   - **substantive** — about the PR's own code, or a real bug that a fix introduced (a wrong output, a crash, a regression — with a concrete scenario).
   - **fix-induced** — an edge case of code the *previous* round's fix added, that the fix "could also handle". Not a bug in the fix.
   - **coverage-only** — asks for a test and names no bug in current code.

   ```bash
   LOOP_STATE="$SKILL_DIR/scripts/loop-state.sh"; STATE="$RUN_DIR/state"
   "$LOOP_STATE" triage --state "$STATE" --scoped "$SCOPED_THIS" \
     --criticals {C} --findings {C+I} --fix-induced {F} --coverage-only {V}
   ```

   `FIX` → Phase 3 as normal. `EXIT NEEDS_HUMAN_REVIEW diminishing-returns` → **do not fix anything.** The round had no CRITICAL and every finding was fix-induced or coverage-only: that is the tail-chasing signature — each round hardening the previous round's hardening — and the loop's marginal finding is no longer worth a round (on #1155 the last three full rounds were exactly this). Record the round with no fix and go to Phase 5, listing the findings for the human to judge:

   ```bash
   "$LOOP_STATE" round-end --state "$STATE" --scoped "$SCOPED_THIS" \
     --criticals 0 --findings {C+I} --fix-induced {F} --coverage-only {V} --pushed-back 0 \
     --code-changed 0 --fix-class prod --forced-exit NEEDS_HUMAN_REVIEW:diminishing-returns
   ```

   `triage` never fires on round 0 (there is no previous fix to chase, and a coverage-only round 0 is answered by Phase 3's decline rules) nor on a scoped verify (its findings are about the delta by construction and cheap to address).

**Quiet mode**: keep findings in memory; do not post. Report locally: "Round {N}: X critical, Y important, Z suggestions."

**Verbose mode**: follow `verbose-mode.md` to post the review to the PR before Phase 3.

4. **Update the progress comment** (both modes). Rebuild `$RUN_DIR/progress.md` with the current round's row showing the finding counts and "⏳ fixing…" status, then edit in place:

   ```bash
   # Rebuild the full table from conversation state (all rounds so far).
   # Each prior round's row is already known; this round adds a new one.
   # Keep the two marker lines at the top: `pr-review-loop:progress`, then
   # `pr-review-loop:rounds N` with N = "$LOOP_STATE" get ROUNDS_INCLUDING_CURRENT
   # (this round's reviews have run, so it counts if the run dies now).
   # The current round's row:
   #   | {N} | {agent list} | {total findings} | — | — | ⏳ fixing… |
   # Prior rounds show their final resolved state:
   #   | {N} | {agent list} | {findings} | {fixed} | {pushed back} | ✅ |
   ```

   ```bash
   if [ "$PROGRESS_POSTED" = "1" ]; then
     # ... write the rebuilt table to "$RUN_DIR/progress.md" ...
     "$GH_IO" edit-comment --repo "$OWNER_REPO" \
       --id-file "$PR_ROOT/progress-cid" --body-file "$RUN_DIR/progress.md" \
       || echo "Warning: could not update progress comment (non-fatal)." >&2
   fi
   ```

## Phase 3: Claude responds

1. For each finding: **Agree** (fix it), **Partially agree** (modified fix), or **Disagree** (pushback with written reasoning). A pushback must **cite the evidence that defeats the finding** — the specific code line, existing guard, type/constant, or project convention that makes it wrong or already-handled — not just assert judgment. If you can't point to concrete evidence, either fix it or ask, don't hand-wave. (These citations become the "All Prior Pushbacks" entries reviewers must clear a higher bar to re-raise, so they need to actually hold up.)

   **Coverage-only findings are answered, not implemented, by default (0.15.0).** A finding that asks for a test and names no bug in current code needs no "defeating evidence" — the test genuinely does not exist, and that is not a reason to write it. Decline it, citing one of:
   - (a) an existing test that already exercises the path — name it (`rg` the symbol in the test tree);
   - (b) the repo's test conventions in the packet's CLAUDE.md / AGENTS.md (e.g. "verification tooling gets one smoke test", "the permanent suite stays small");
   - (c) the loop's **test budget** — run

     ```bash
     "$SKILL_DIR/scripts/diff-size.sh" --repo "$(git rev-parse --show-toplevel)" \
       --base-ref "$(cat "$PACKET/base-ref.txt")" --since "$(cat "$RUN_DIR/round-0-base-sha.txt")"
     ```

     and once it reports `test_budget=EXCEEDED` (the loop has added more test lines than production lines since round 0), every further coverage-only finding goes to `## Remaining Suggestions` with that reason;
   - (d) it asks for a test of code the previous round's fix added — you already own that (below).

   Write the decline into `$HISTORY` as a pushback like any other, so it is not re-raised. **Implement** a coverage finding only when it meets the test-analyzer's own bar: it names a bug in current code (then the bug is the fix and the test proves it), or it covers a CRITICAL fixed this loop that landed without one. On #1155 the fixer accepted 50 of 51 findings, because a coverage request could never be "defeated"; 1,825 test lines followed.

   **When your fix adds a guard, its test goes in the same commit.** That is what makes "the previous round's fix has no test" a finding nobody can raise next round. One focused test per guard — not a parametrised sweep of every state the guard touches.
2. After each file edit: run project-appropriate format+lint with auto-fix on the changed file (e.g. `ruff format <file> && ruff check <file> --fix`).
3. Stage, commit with a descriptive message, and push:
   ```bash
   git add <changed files>
   git commit -m "<subject line>" -m "<body>"
   git push
   ```

   **Subject line** — a conventional-commit-style summary of what changed, not which round triggered it. Examples:
   - `fix: fail-close on unbridged pit-lane penalties in C14 writer`
   - `test: add wiring test for strict exclusion in main()`
   - `fix: guard against NaN in lap-delta interpolation`

   Keep it under 72 characters. Do NOT use `--fixup` — the cascading `fixup! fixup! fixup!` prefixes are unreadable and add no useful context.

   **Body** — list the 2–3 Codex findings this commit addresses (one line each: agent name, file:line, one-sentence description). This gives anyone watching the PR branch a clear picture of what each commit responds to, since the Codex reviews themselves are not visible on the PR in quiet mode. Example:
   ```
   Addresses review round 3 findings:
   - failure-pattern-analyst: fit_start_residuals.py:1464 — artifact writer
     calls pit_lane_exclusions() without strict=True
   - test-analyzer: fit_start_spread.py:725 — no wiring test proving main()
     passes strict=True
   ```

   **You cannot push changes to `.github/workflows/*` when running in CI.** The
   job's `GITHUB_TOKEN` is a GitHub App token, and the `workflows` permission is
   not available to it — it isn't a key you can add to the workflow's
   `permissions:` block, so no amount of config grants it. The push is rejected
   server-side with *"refusing to allow a GitHub App to create or update workflow
   … without `workflows` permission"*, and because the rejection lands at push
   time, a fix committed first has to be unwound.

   So **don't attempt it**: when a finding targets a workflow file and you're
   running in CI, do not edit it. Route it to `## Remaining Suggestions` as an
   explicit operator action — name the file, line, and the exact one-line change
   — and say the loop's token cannot push workflow files. This is a deliberate
   privilege boundary, not a misconfiguration: the loop executes PR code, so a
   token that could rewrite CI would let reviewed code rewrite the pipeline that
   runs on the default branch. On a laptop run (a human's own credentials) the
   edit is fine — this restriction is CI-only.
4. **In parallel with posting/reporting**, run **targeted validation** on this round's fix: the lint/format check, then the tests that cover the files changed this round. Commands come from CLAUDE.md / project config. **Targeted means:** every test file changed this round, plus every test file that imports a module changed this round (grep the test tree for the module path), plus any always-on smoke command the project names. Run the project's **full suite only** (a) on the final candidate — Phase 4's full-validation gate before a CLEAN exit — or (b) when this round's fix changed a shared production interface, default or config whose consumers a grep cannot enumerate, and say so in the round summary. If validation fails, fix, amend, force-push with `--force-with-lease`.

   **Why targeted (0.14.0):** a full suite after every narrow fix was the largest single cost in long loops — one 2026-09 loop ran a project's full backend suite five times at ~11 minutes each inside a 110-minute review. The final full run catches what the targeted runs missed; the intermediate ones only repeat it.

   **Every validation command must be bounded, and its output must survive.** The
   agent-watchdog rationale in Phase 1 Step 4 applies here verbatim: `TIMEOUT_SECONDS`
   is only checked *between* rounds, so it cannot interrupt a validation command
   hanging inside one. Run each as:

   ```bash
   timeout "${VALIDATE_TIMEOUT_SECONDS:-900}" <command> > "$ROUND_DIR/validate-<name>.log" 2>&1
   rc=$?
   tail -60 "$ROUND_DIR/validate-<name>.log"    # read the FILE, after the fact
   ```

   - **Never pipe the command into `tail`/`head`.** `cmd | tail -60` emits nothing
     until `cmd` reaches EOF, so a command that hangs leaves a **zero-byte** log and
     destroys the one artifact that would name the culprit. Redirect to a file and
     `tail` the file afterwards — then partial output survives the kill.
   - **Exit 124 (timed out) is a validation FAILURE.** Report which command timed out
     and at what bound; do not re-run it, and do not wait on it. A hang is a finding
     about the project, not an obstacle to work around.
   - **Never poll for a validation command to finish** — see the escape-hatch note in
     Phase 1 Step 4.

   **Why this is spelled out:** a runner loop on a large PR ran a project's full test
   suite unbounded. One test wedged at 0% CPU; the `| tail -60` pipe kept its log at
   zero bytes; the loop then started a 25-minute poll waiting for content in that
   file — which could not arrive until the very command it was waiting on exited.
   The job died at CI's 75-minute cap. Round 0's reviews had **already completed
   successfully**; the entire run was thrown away after the work was done, and no
   summary was ever posted.
5. **Verbose mode**: post `CLAUDE:` response comment per `verbose-mode.md`. **Quiet mode**: report locally.
6. **Update `$HISTORY`**: append this round's round-summary + resolved items to `## Recent Rounds` (trim to last 2); append each pushback to `## All Prior Pushbacks` (grows forever).
6a. **Update the progress comment** (both modes). Rebuild `$RUN_DIR/progress.md` — this round's row now shows its final state (`{fixed}`, `{pushed_back}`, `✅`), and the `pr-review-loop:rounds` line still reads `ROUNDS_INCLUDING_CURRENT` (Phase 2 step 4). If the loop will continue (Phase 4 decides), append a placeholder row for the next round (`| {N+1} | — | — | — | — | ⏳ reviewing… |`):

   ```bash
   if [ "$PROGRESS_POSTED" = "1" ]; then
     # ... write the rebuilt table to "$RUN_DIR/progress.md" ...
     "$GH_IO" edit-comment --repo "$OWNER_REPO" \
       --id-file "$PR_ROOT/progress-cid" --body-file "$RUN_DIR/progress.md" \
       || echo "Warning: could not update progress comment (non-fatal)." >&2
   fi
   ```

7. **Classify this round's change** (Phase 4 uses it to decide whether the next round can be a cheaper scoped verify). Look at the files you changed this round and set `LAST_FIX_CLASS`:

   ```bash
   CHANGED="$(git diff --name-only "$ROUND_BASE_SHA" HEAD)"
   LAST_FIX_BASE_SHA="$ROUND_BASE_SHA"   # remember where this round's fix started, for delta.patch
   ```

   - `tests` — **every** changed file is a test file (`test/`, `spec/`, `__tests__/`, `*_test.*`, `*.test.*`, `tests/…`).
   - `docs` — every changed file is documentation (`*.md`, `*.rst`, `*.txt`), **or** the only code changes are comments/docstrings (judge this — a `git diff` where every `+`/`-` line is a comment).
   - `prod` — anything else (any production-logic change, however small — a type alias, a one-line guard, a rename all count as `prod`).

   When in doubt, classify `prod`. Only `tests` / `docs` unlock a scoped verify; `prod` always gets a full batch next round. If you changed nothing this round (`CHANGED` is empty — all pushbacks), classify `prod`: an empty change set must not vacuously count as "all tests".

   **Classify the final pushed state.** If you amend/force-push *after* this step (e.g. a late validation fix from step 4), re-run this classification — a `docs` round whose validation fix touched prod code must become `prod`, or Phase 4 would wrongly unlock a scoped verify for a production change.

   Record where this round's fix started, for a later scoped delta (the class itself is passed to `round-end` in Phase 4):

   ```bash
   "$LOOP_STATE" set --state "$STATE" LAST_FIX_BASE_SHA "$ROUND_BASE_SHA"
   ```

## Phase 4: Loop check

> **Do not self-certify.** 80% of wrong CLEAN exits historically came from Claude declaring clean without Codex re-verifying the fixes. And **do not self-decide**: the exit is computed by `loop-state.sh round-end` from the numbers you pass it. You report the round; the script rules.

1. **Report the round** — one call, every round, no exceptions:

   ```bash
   LOOP_STATE="$SKILL_DIR/scripts/loop-state.sh"; STATE="$RUN_DIR/state"
   "$LOOP_STATE" round-end --state "$STATE" \
     --criticals {C} --findings {C+I} --fix-induced {F} --coverage-only {V} \
     --pushed-back {P} --code-changed {0|1} --fix-class {tests|docs|prod} \
     --scoped "$SCOPED_THIS" \
     $( [ "${ALL_WATCHDOG_KILLED:-0}" = "1" ] && printf -- '--all-watchdog-killed' )
   ```

   - `{C}` / `{C+I}`: CRITICAL and CRITICAL+IMPORTANT counts after Phase 2 dedup (SUGGESTIONs are not findings here).
   - `{F}` / `{V}`: the Phase 2 buckets (disjoint; substantive is the remainder).
   - `--code-changed`: 1 if this round pushed any commit, 0 if every finding was declined.
   - `--fix-class`: Phase 3 step 7's `LAST_FIX_CLASS` (the script forces `prod` when nothing changed).

   The script advances every counter, persists the PR's lifetime round count to `$PR_ROOT/rounds-total`, and prints exactly one line.

2. **`CONTINUE scoped=S severity_floor=F sfh_effort=E`** → go back to Phase 1. Phase 1 reads `SCOPED_NEXT`, `SEVERITY_FLOOR_ACTIVE` and `SFH_EFFORT` from the state file itself; the printed values are for your round summary. `scoped=1` means the next round is a **scoped verify** (see below): the review was CRITICAL-free and this round's fix touched only tests/docs.

3. **`EXIT CLEAN …`** → **full-validation gate first.** Before honouring a CLEAN, run the project's full validation set once on the final head — lint, build/typecheck and the full test suite — bounded and logged exactly as Phase 3 Step 4 describes. Skip it only if the last full run already ran on this exact head SHA. A failure is not CLEAN: fix it in Phase 3 terms, commit, push, then

   ```bash
   "$LOOP_STATE" validation-fix --state "$STATE" --fix-class {tests|docs|prod}
   ```

   and go back to Phase 1 — the next round is a scoped verify or a full batch per the class, and no review round was counted for the validation fix (the CLEAN the script printed is void; `validation-fix` clears it). If validation passes, record which head it covered for Phase 5 and exit CLEAN.

4. **Any other `EXIT <STATUS> <reason>`** → Phase 5 with that status. What the script means by each:

   | Status | Fires when | Meaning |
   |---|---|---|
   | `CLEAN` | no code change this round and 0 CRITICAL | Classic clean, a scoped verify that found nothing, and clean-on-pushback (Claude declined every remaining IMPORTANT with reasoning) are all this one rule. |
   | `NEEDS_HUMAN_REVIEW critical-declined` | no code change and a CRITICAL was declined | A standoff on a CRITICAL is a human's call, not another identical round. |
   | `NEEDS_HUMAN_REVIEW diminishing-returns` | forced by Phase 2 triage | 0 CRITICAL and every finding fix-induced or coverage-only. Listed for the human, unfixed. |
   | `CODEX_DEGRADED` | every agent watchdog-killed | Systemic Codex stall (Phase 1 Step 4). |
   | `TIMED_OUT` | `TIMEOUT_SECONDS` elapsed | Checked between rounds only. |
   | `MAX_ITERATIONS_REACHED` | `ITERATION >= MAX_ITERATIONS` | This run is over. **Do not start another** — Phase 0 Step 5. |
   | `FIX_BUDGET_EXHAUSTED pr-rounds …` | `PRIOR_ROUNDS + ITERATION >= MAX_PR_ROUNDS` | The PR's lifetime budget; survives re-labels by design. |
   | `FIX_BUDGET_EXHAUSTED fix-induced …` | three consecutive rounds whose findings were all fix-induced/coverage-only | Backstop for the triage exit, in case triage was skipped. |

   CLEAN sits above the caps in the script's order: a round that converged is CLEAN even if it was the last one the budget allowed.

   **Fix-induced findings get no special CLEAN** (0.7.0, unchanged): a round that fixed anything is never CLEAN on its own say-so — Codex reviews the pushed state next round, scoped or full per `LAST_FIX_CLASS`. What 0.15.0 changed is that a round consisting *only* of such findings is no longer fixed at all (Phase 2 triage). **Removed in 0.15.0:** the "3 consecutive CRITICAL-free rounds ⇒ CLEAN" exit — it could fire on a round that changed code, shipping fixes no reviewer had seen. The streak still raises the severity floor (`≥ 2`) and drops the silent-failure-hunter to medium effort (`≥ 1`).

   Once `round-end` has printed an `EXIT`, it refuses further calls for this run. That is deliberate.

### Scoped verify rounds

**Why:** loops historically ended with a full 4-agent round that found nothing — pure token waste. When the previous full round was clean of CRITICALs and Claude's only response was a **tests-only or docs/comments-only** fix, a full re-review is overkill: that fix can't introduce a production regression, so verifying it with 2 agents on just the delta is enough. Production changes never qualify (Phase 3 classifies them `prod`), so a scoped round can certify CLEAN without risk of missing a production bug — this is why the tests/docs-only gate matters and must stay strict.

**When:** `round-end` sets `SCOPED_NEXT=1` in the state file iff the latest review had 0 CRITICAL and `LAST_FIX_CLASS` ∈ {`tests`, `docs`}. Phase 1 Step 0 reads it into `SCOPED_THIS` and writes `$PACKET/delta.patch` from the recorded `LAST_FIX_BASE_SHA`.

**How a scoped round differs (Phase 1 Steps 2–4):**
- **Step 2 — agents:** `code-reviewer` plus the persona that owns the fix's domain, derived from `LAST_FIX_CLASS` — no core tier. **Use this `SCOPED_ROLES` in both Step 3 and Step 4** (don't hardcode `test-analyzer`, or a `docs` fix gets the wrong reviewer):
  ```bash
  LAST_FIX_CLASS="$("$LOOP_STATE" get --state "$STATE" LAST_FIX_CLASS)"
  case "$LAST_FIX_CLASS" in
    tests) SCOPED_ROLES="code-reviewer,test-analyzer" ;;
    docs)  SCOPED_ROLES="code-reviewer,comment-analyzer" ;;
    *)     echo "not scoped-eligible: $LAST_FIX_CLASS" >&2; exit 1 ;;   # Phase 4 gates this; never reached
  esac
  ```
- **Step 3 — prompts:** build with `--scoped` (appends the delta-focus addendum) and `--history` (prior pushbacks still apply); skip `--severity-floor` (the scoped addendum already says "report only if the fix itself is wrong"):
  ```bash
  "$BUILD_PROMPTS" --packet "$PACKET" --out "$ROUND_DIR" \
    --roles "$SCOPED_ROLES" --history "$HISTORY" --scoped
  ```
- **Step 4 — launch:** `--only "$SCOPED_ROLES"` — the one sanctioned path that bypasses core-tier enforcement (a normal round must never pass `--only`):
  ```bash
  "$LAUNCH_AGENTS" --run-dir "$ROUND_DIR" --repo "$(git rev-parse --show-toplevel)" \
    --sfh-effort medium --only "$SCOPED_ROLES"
  ```

**Outcome (Phase 4):** a clean scoped round → CLEAN exit; any finding → address it in Phase 3, then escalate to a full batch next round. A scoped round never chains into another scoped round.

## Phase 5: Wrap-up

**Quiet mode**: post a single comprehensive PR comment — the full story of the loop. A human reading only this should understand everything.

**Post it with `gh-io.sh post-comment`** (write the body to a file first — it is long and multi-line), never a bare `gh pr comment`:

```bash
GH_IO="$SKILL_DIR/scripts/gh-io.sh"   # re-set: fresh shell
# ... write the summary below to "$RUN_DIR/summary.md" ...
"$GH_IO" post-comment --repo "$OWNER_REPO" --pr "$PR_NUMBER" --body-file "$RUN_DIR/summary.md"
```

**If that call exits non-zero, the loop has failed** — the whole point of the run is the verdict, and it did not reach the PR. Do not carry on to the marker removal and report success. Say so plainly in your final message to the user, print the summary you were trying to post so the work isn't lost, and report the run's status as failed. (In CI the workflow's reconcile step independently catches this — see "CI reconciliation" below — but a laptop run has no such backstop, so the honest report is yours to make.)

```
CLAUDE: Automated Review Summary
<!-- pr-review-loop:summary -->
<!-- pr-review-loop:rounds {PR_ROUNDS_TOTAL} -->

## Overview
- Iterations: {N} rounds this run ({M} Codex + {N-M} Claude fix); {PR_ROUNDS_TOTAL} for this PR across all runs
- Duration: {minutes}m
- Agents used: {list}
- Status: {CLEAN | NEEDS_HUMAN_REVIEW | FIX_BUDGET_EXHAUSTED | PR_TOO_LARGE | TIMED_OUT | MAX_ITERATIONS_REACHED | CODEX_DEGRADED} ({reason from round-end, e.g. diminishing-returns})
- Size: {counted} counted added lines ({excluded} excluded as artifacts) — {OK | WARN | STOP}
- Test budget: the loop added {T} test lines against {P} production lines — {OK | EXCEEDED}

## Issues Fixed
- [severity] `file:line` — {original issue} → Fixed: {how}

## Issues Pushed Back
- [severity] `file:line` — {original issue}
  Author reasoning: {Claude's rationale}

## Remaining Suggestions (not addressed)
- `file:line` — {suggestion}

## Validation
- Rounds 0–N: targeted — lint plus the tests covering each round's changed files (name the test files or selectors run; name any round that ran the full suite and why)
- Full suite once on {FINAL_HEAD_SHA}: PASS/FAIL/TIMEOUT (X passed, Y failed; name any command that hit its bound and the bound it hit)

## Commits
{list of commit SHAs with their subject lines}

<!-- pr-review-loop:history
{verbatim contents of $HISTORY}
-->
```

The `pr-review-loop:summary` marker on the second line is **required in both modes** and must be byte-exact. It's how `gh-io.sh reconcile` (and the CI workflow) tells "the loop published its verdict" from "the loop died quietly" — the heading prose is not the contract, since a human comment can quote it. Keep it an HTML comment so it stays invisible in the rendered comment.

The `pr-review-loop:rounds` marker is **required in both modes** and carries `PR_ROUNDS_TOTAL` (= `PRIOR_ROUNDS + ITERATION`) — the PR's lifetime review-round count, which is what makes the Phase 4 fix budget survive a re-label. Write the number as plain digits. Also persist the local copy in the same bash call that posts the wrap-up, so a re-run on the same runner doesn't need to re-read the PR:

```bash
printf '%s\n' "$PR_ROUNDS_TOTAL" > "$PR_ROOT/rounds-total"
```

Both copies are written because either can be lost independently (see `history-io.sh`); Phase 0 takes the max. **Write them on every exit, not just `FIX_BUDGET_EXHAUSTED`** — a `TIMED_OUT` run's rounds count against the PR too, and skipping the write there is precisely how #623 would have escaped the budget.

The trailing `pr-review-loop:history` block is **required in both modes** — it's the durable copy of "All Prior Pushbacks" + "Recent Rounds" that Phase 0 reconstructs from when a later loop runs on a fresh machine or after a container redeploy (see Phase 0 Step 8). It's an HTML comment, so it's invisible in the rendered comment. Paste `$HISTORY` verbatim between the markers; the `-->` must be on its own line so the extractor stops there.

Also post inline comments on the diff for pushed-back items and remaining suggestions (reuse the inline-comment posting logic in `verbose-mode.md`, step 4, but only for these unresolved items).

**Verbose mode**: post the short final summary from `verbose-mode.md` — through `gh-io.sh post-comment`, and carrying the same `pr-review-loop:summary` marker and `pr-review-loop:history` block. Individual round comments already tell the story.

### Reporting a `FIX_BUDGET_EXHAUSTED` exit

This exit means "the loop stopped being productive", **not** "the PR is fine" and **not** "the PR is broken". The reader is a human deciding what to do next, so the wrap-up must give them that decision and not a verdict:

- **Say which budget ran out** — `MAX_PR_ROUNDS` (with `PRIOR_ROUNDS` + this run's rounds, so the count across runs is visible) or the `MAX_FIX_INDUCED_ROUNDS` streak.
- **Flag the unreviewed state explicitly.** The last round's fixes were pushed but never reviewed — that is inherent to stopping here. Name those commits under "Commits" and say plainly that no reviewer has seen them.
- **Characterise the spiral, don't re-list it.** One or two sentences on what the rounds kept circling (e.g. "each round added a link to the resume-safety chain and the next found a gap in that link"). The per-round detail is already in `$HISTORY`.
- **Recommend, don't decide.** Typically: merge as-is if the remaining findings are acceptable, split the PR, or hand-review the last fixes. Do not mark ready, do not re-run the loop, and do not remove the `review` label.

Re-labelling after this exit *will* immediately re-exhaust the budget (the count is PR-resident by design). That is intentional: the next loop should start only after a human has changed something — split the PR, or reset the counter deliberately by editing the `pr-review-loop:rounds` marker on the newest summary comment and deleting `$PR_ROOT/rounds-total`.

### Reporting a `NEEDS_HUMAN_REVIEW` (diminishing-returns) exit

The loop stopped because the round's findings were all fix-induced or coverage-only with no CRITICAL — the marginal round would have hardened the previous round's hardening. Nothing from that round was fixed; that is the point.

- **List the round's findings verbatim under `## Remaining Suggestions`**, each tagged `[fix-induced]` or `[coverage-only]`, with the agent and `file:line`. The human decides which, if any, are worth a commit.
- **Say what converged.** The last fixes *were* reviewed (this round reviewed them and found only these), so unlike `FIX_BUDGET_EXHAUSTED` there is no unreviewed state. Say so.
- **Recommend, don't decide.** Typically: merge as-is, or hand-pick one or two of the listed items. Do not mark ready, do not re-run the loop.

### Reporting a `PR_TOO_LARGE` exit

No review ran. Give the counted and excluded line totals, the top files from `$RUN_DIR/size.txt`, and the two ways forward: split the PR (name a seam if one is visible in the top files), or re-run with `PR_SIZE_EXCLUDE='<glob>'` if a file type the exclusion list misses inflated the count. Carry the `pr-review-loop:summary` marker and `pr-review-loop:rounds {PRIOR_ROUNDS}` (no rounds were added). Do not mark ready.

### Mark ready for review (CLEAN exits only)

After posting the wrap-up, **if and only if the loop exited `CLEAN`** (Phase 4), mark the PR ready for review when it is currently a draft:

```bash
if [ "$(gh pr view "$PR_NUMBER" --json isDraft -q .isDraft)" = "true" ]; then
  gh pr ready "$PR_NUMBER"
fi
```

Rationale: some repos (e.g. f1-predictions) keep PRs in draft *during* the loop so CI doesn't run on every review-loop push, then defer the single CI run to `ready_for_review`. Marking ready here fires that end-of-cycle CI. On repos that don't use draft-first the PR isn't a draft, so this is a no-op. **Never mark ready on a non-CLEAN exit** (`NEEDS_HUMAN_REVIEW` / `FIX_BUDGET_EXHAUSTED` / `PR_TOO_LARGE` / `TIMED_OUT` / `MAX_ITERATIONS_REACHED` / `CODEX_DEGRADED`) — an unconverged PR must stay a draft and out of CI.

### Remove the progress comment

Delete the progress comment posted in Phase 0.5 — the summary supersedes it, and leaving both clutters the PR. Do this on **every** exit, after the summary is posted (so there's never a gap where neither is visible). Best-effort: a failure to delete is cosmetic, not structural.

```bash
GH_IO="$SKILL_DIR/scripts/gh-io.sh"   # re-set: fresh shell
if [ -f "$PR_ROOT/progress-cid" ]; then
  "$GH_IO" delete-comment --repo "$OWNER_REPO" --id-file "$PR_ROOT/progress-cid" \
    || echo "Warning: could not remove the progress comment — it's harmless but cosmetic." >&2
fi
```

### Remove the in-flight marker

Delete the `pr-review-loop:running` marker posted at the end of Phase 0.5 (do this on **every** exit, clean or not, so a finished run never blocks the next one):

```bash
GH_IO="$SKILL_DIR/scripts/gh-io.sh"   # re-set: fresh shell
# --id-file is the pair post-comment persisted in Phase 0.5 ("<databaseId>
# <nodeId>"); gh-io reads both, deletes via REST with a GraphQL fallback, and
# removes the file on success. If the marker was never posted (an early
# preflight exit) the file doesn't exist and this is a no-op.
if [ -f "$PR_ROOT/marker-cid" ]; then
  "$GH_IO" delete-comment --repo "$OWNER_REPO" --id-file "$PR_ROOT/marker-cid" \
    || echo "The in-flight marker on PR #$PR_NUMBER could not be removed via REST or GraphQL — say so in your final message and tell the user to delete it by hand, or the next loop on this PR is blocked for ~75 min." >&2
fi
```

(`$OWNER_REPO` is the `nameWithOwner` from Phase 0 Step 3.) A 404 counts as success — the marker being gone is the goal, however it got there. If the delete genuinely fails, **report it in your final message**; don't let it live and die as a stderr line the user never sees.

**Both modes**: report the final status and PR URL to the user.

### CI reconciliation (why the marker is not the last word)

`claude --print` exits 0 whenever the model produced text, so nothing about *this* skill's own exit can prove the loop finished. Under CI the workflow therefore runs `gh-io.sh reconcile` with `if: always()` after the loop: it removes any marker still standing and fails the job with `::error::` annotations if the summary never landed. That is the check that would have caught reduction#10, where two runs reported success over a locked PR with no verdict. Nothing here needs to *call* reconcile — just know that the `pr-review-loop:summary` marker and the `$PR_ROOT/marker-cid` file are the contract it reads, so don't hand-roll either.

## Bundled files

- `scripts/refresh-packet.sh` — resolves the base ref and (re)generates the packet's diff artifacts, including `base-ref.txt` (Phase 0.5, Phase 1 Step 0)
- `scripts/diff-size.sh` — the PR-size gate (warn 1,500 / stop 2,500 counted added lines, artifacts excluded) and the loop's test budget (`--since`) (Phase 0.5, Phase 3)
- `scripts/loop-state.sh` — every loop counter and the exit decision: `init`, `get`, `set`, `triage`, `round-end`, `validation-fix` (Phase 0, 1, 2, 3, 4); tested by `selftest.sh`
- `scripts/build-prompts.sh` — deterministically assembles agent prompts from `prompts/` fragments (Phase 1 Step 3)
- `scripts/launch-agents.sh` — launches the Codex batch under per-agent watchdogs; enforces the core tier; honors `CODEX_SANDBOX_UNAVAILABLE` (Phase 1 Step 4)
- `scripts/history-io.sh` — parses the PR-resident history block and in-flight markers (Phase 0 Steps 8–9); tested by `selftest.sh`
- `scripts/gh-io.sh` — every GitHub **write** the loop makes (marker post, marker delete, summary post, progress comment post/edit/delete), with retry + a REST→GraphQL fallback; also the `reconcile` the CI workflow runs to prove the loop finished (Phase 0.5, Phase 5)
- `scripts/selftest.sh` — runnable coverage for all of the above (no repo CI; run `bash scripts/selftest.sh`)
- `prompts/` — the prompt fragments: `_packet.txt`, `_history.txt`, `_severity-floor.txt`, `_scoped.txt` (scoped-verify addendum), and one persona file per agent
- `agent-prompts.md` — documents the fragments and assembly order (no longer hand-assembled)
- `verbose-mode.md` — PR-posting mechanics used only when `verbose` is passed
