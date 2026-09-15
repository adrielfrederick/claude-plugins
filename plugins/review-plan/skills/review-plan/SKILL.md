---
name: review-plan
description: Facilitates an automated plan review loop using parallel Claude reviewer agents, then a final Codex (gpt-6-astra, high effort) feedback pass, iterating on feedback until the plan is approved.
---

After a plan is created:

## Setup

1. **Save the plan to the repo**: Copy the plan document to `<repo-root>/docs/plans/` with a descriptive filename (e.g., `docs/plans/auth-redesign.md`). Resolve the repo root by running `git rev-parse --show-toplevel`.

   **Enforce the plan contract before starting the loop.** The plan document must open with an objective section and end with two sections (add them if missing; an empty section must say `None` explicitly):
   - `## Objective` — the first section after the title. It states the outcome the plan exists to produce, as the change an observer would see after execution — a behaviour, a metric, a capability — not as the work to be done ("p95 poller latency under 2 s", not "rewrite the poller"). Any outcome the plan relies on implicitly (a refactor that is really for a later feature, a migration that assumes a traffic pattern) is stated here or dropped. It ends with **Success criteria**: two to five concrete signals that would show the objective was met, each checkable after execution — a metric with a threshold, a command with its expected output, a user-visible behaviour — with a note on when and how each is checked. Reviewers judge the plan against this section; without it they review against a goal they inferred, which is the failure the section exists to prevent. If the plan has no such section, write one from the plan's own text and confirm it with the writer before pass 1 — the objective is the writer's to state, not the reviewer's to guess.
   - `## Operator forks` — the few genuine decisions only the human operator can make (scope cuts, product shape, risk tolerance). Each fork lists the options and a recommendation. Anything resolvable by evidence, code inspection, or existing convention must be decided in the plan body instead of deferred here.
   - `## Live gates` — every execution step that touches real money, production data/config, or irreversible external effects (payments, orders, emails, deletions), each paired with its concrete operator validation (e.g., dry-run output review, supervised small-stakes test, prod read-back).

   **Check the plan size budget.** `PLAN_WORD_BUDGET=5000`. Run `wc -w` on the plan and record the count in the review document header. A plan over budget is still reviewed — but first it gets a **plan diet** (below), and the writer gets a **strong warning** with a split proposal. Never refuse a review over length.

   (Why: a reviewer agent's context is mostly codebase verification, and a plan past ~5k words crowds that out; the passes then get spent on plan-internal inconsistencies instead of on whether the plan matches the code. Length is usually a symptom: the plan is recording how the design was reached instead of directing what gets built.)

   **Plan diet — when over budget, before pass 1.** A plan exists to drive execution by an agent that can read the codebase. Anything that records thinking rather than directs work is cut or moved:

   | Keep — it drives execution | Cut or move — it records thinking |
   |---|---|
   | What to build: files, functions, data shapes, contracts, PR packets and their order | Decision narration. Keep one line per decision (what was decided, pointer to the evidence); the reasoning goes to an investigation or notes file |
   | Verification: commands, expected outputs, gates | History of the plan itself: earlier drafts, "pass 2 changed X", review-loop artefacts — the review document is that record |
   | Operator forks and Live gates | Rejected alternatives beyond a one-line reason each |
   | The numbers the plan depends on, with a pointer to where they came from | Census and measurement tables that justified a decision already taken |
   | Constraints an implementer cannot discover from the code | Context restated from CLAUDE.md, other plans, or code an agent will read at execution time |
   | The objective, its success criteria, and a short problem statement | Motivation and narrative beyond that statement; the same rule stated in three sections |

   The test for a sentence: would an implementing agent do anything differently without it? If not, it goes. Moved material lands in a companion file under the repo's notes/investigations convention (or `docs/plans/<slug>-context.md` if there is none) with a one-line pointer from the plan; material with no future reader is deleted — git keeps it.

   Re-measure after the diet. If the plan is still over budget, write the warning into the review document header and say it to the writer directly before launching pass 1:

   ```
   Plan words: 7,900 / 5,000 — OVER BUDGET after diet
   Split proposal: <two or three independently reviewable plans, each named by the PR packets or sections it would own, in build order>
   ```

   The warning is repeated at wrap-up (step 9). Proceed with the review regardless — the budget shapes the plan, it does not block it.

2. **Create the review document** in a `reviews/` subdirectory beside the plan, with a `-review` suffix (e.g., `docs/plans/reviews/auth-redesign-review.md` for `docs/plans/auth-redesign.md`). Create the directory if it does not exist. Reviews are long and rarely read, and keeping them out of the plans directory keeps it browsable. If a review of this plan already exists at the legacy location beside the plan (`docs/plans/auth-redesign-review.md`), move it into `reviews/` first (`git mv` in a git repo), repoint any links to it, and continue that document rather than starting a new one. The review's `Plan:` header stays repo-root-relative, and any markdown link from the review to the plan is relative to `reviews/` (`../auth-redesign.md`).

   ```
   Plan: docs/plans/auth-redesign.md
   Review Status: In Progress
   Plan words: 4210 / 5000

   ## Findings ledger

   | ID | Dimension | Severity | Finding | Plan § | Status |
   |---|---|---|---|---|---|
   <!-- ledger-end -->

   ## Transcript
   ```

   The **ledger** is the authoritative state of the review: one row per finding, updated in place. The **transcript** is the chronological audit trail of reviewer and author blocks, appended only. Reviewers in later passes work from the ledger and the plan delta, not from the whole transcript.

   Ledger vocabulary:
   - **ID**: `P<pass>-<dim><n>` with dim ∈ `S` (Scope), `D` (Data model), `C` (Code quality), `T` (Testing), `F` (Failure patterns), `H` (Holistic), `X` (Codex, pass 6 only). E.g. `P1-S2`, `P3-H1`, `P6-X1`.
   - **Severity**: `blocking` | `non-blocking`. A finding that names no concrete change to the plan is non-blocking.
   - **Status**: `open` (raised, unanswered) → `fixed` (plan changed, awaiting verification) or `pushed-back` (author disagrees; reasoning lives in the transcript) → `verified` | `reopened` | `conceded` (reviewer accepted the pushback) | `withdrawn` (reviewer retracted).
   - **Terminal** statuses: `verified`, `conceded`, `withdrawn`, and `duplicate (<ID>)` — the author's mark for a finding another reviewer raised in the same pass; the surviving row keeps the stricter severity. For **non-blocking** rows, `fixed` and `pushed-back` are also terminal — they are closed by the author's answer and never gate exit.
   - **Clean ledger**: no `blocking` row in a non-terminal status. A fix nobody has verified is not clean.

3. **Create the scratch directory and record the start state**:

   ```bash
   SKILL_DIR="<this skill's base directory>"   # holds scripts/ledger.py and scripts/launch-codex.sh
   SLUG=auth-redesign            # the plan's basename without .md
   SCRATCH=/tmp/review-plan/$SLUG; mkdir -p "$SCRATCH"
   PASS=0
   ```

   `$SKILL_DIR/scripts/ledger.py <review-doc> add|set|open` is the only way the ledger is edited: `add` inserts rows above the sentinel, `set` changes a row's status, `open` prints the non-terminal blocking rows (exit 1 if any) — the exit test and the verify packet in one command.

   Per-pass files live under `$SCRATCH/pass-N/`: each reviewer's block, the pre-edit plan snapshot, and the plan delta. Reviewers write their blocks **there**, and you append them to the transcript in a fixed order. Reviewers never write to the review document, so parallel agents cannot interleave or clobber each other, and a block can never land after the response to it.

## Pass schedule

Passes 1–5 are the **Claude loop**: at most five passes of fixed types, two of them full reviews and the rest **scoped verification passes** that rule on the open findings and look for regressions the fixes introduced. The Claude loop exits at the first verify pass that leaves the ledger clean. Pass 6 is a single **Codex final review** that runs once, after the Claude loop has exited for any reason, and gets one author response with no re-verification.

| Pass | Type | Agents | Reads | Skipped when |
|---|---|---|---|---|
| 1 | Dimension review (full) | 4 Sonnet in parallel, +1 failure-patterns agent when the patterns file exists | plan, rubric | never |
| 2 | Dimension verify (scoped) | one Sonnet per dimension that has a non-terminal blocking row | its pass-1 block, the author response, the plan delta, its rows | ledger already clean |
| 3 | Holistic review (full) | 1 Fable, fresh | plan, ledger, transcript; rules on every non-terminal blocking row | never — a clean ledger after pass 2 only means it has no rows to rule on |
| 4 | Holistic verify (scoped) | the pass-3 agent, resumed | pass-3 block, author response, plan delta, its rows | ledger clean after pass 3 |
| 5 | Final verify (scoped) | the pass-3 agent, resumed | as pass 4 | ledger clean after pass 4 |
| 6 | Codex final review (full) | 1 Codex `gpt-6-astra` at high effort, via `scripts/launch-codex.sh` | plan, ledger, transcript; rules on every non-terminal blocking row | never — only when the Codex CLI is unavailable, in which case the gap is noted and the review still completes |

After pass 5 the Claude loop ends whatever the ledger says. Pass 6 then runs, the author answers its rows once, and anything still non-terminal goes to the operator in the wrap-up. Pass 6 is always numbered 6 (its IDs are `P6-X<n>`) even when the Claude loop exited after pass 3 or 4.

(Why pass 6: the five Claude passes share one model family and one set of rubrics, so their blind spots correlate. A different model with a different training and tool stack, reading the finished plan and the whole ledger, catches what all five agreed to miss. It runs last so it reviews the converged plan, and it gets no verify pass so the loop stays bounded — its fixes are reported as unverified rather than re-reviewed.)

**Full-recheck escape.** If an author response's plan delta **adds or rewrites** more than 20% of the plan's lines (count `+` lines in the unified diff, not deletions — a hygiene cut is not a design change), or marks any fix as a `(design change)`, the next holistic pass is a **full holistic review by a fresh Fable agent** instead of a scoped verify. It takes the pass-4 slot and pass 5 verifies it. This fires at most once per loop.

**Resuming agents.** Verify passes prefer to **resume** the reviewer that raised the findings — via SendMessage to the agent the Agent tool returned — because it already holds the plan and the code it verified and must not re-explore. If the harness does not expose the agent for resumption, launch a fresh agent of the same model with the verify packet (which includes the prior block, so nothing is lost but exploration time).

## Loop

Repeat from step 4 until a Claude-loop exit condition (step 8) fires; then run pass 6 (steps 4–7 once more with `PASS=6`) and go to step 9.

4. **Increment pass**: `PASS += 1` (or `PASS=6` when entering the Codex pass from step 8); `P=$SCRATCH/pass-$PASS; mkdir -p "$P"`. For a verify pass, assemble the packet:
   - `$P/delta.patch` — produced by the previous author step (step 7c).
   - `$P/rows-<dimension>.md` (pass 2) or `$P/rows.md` (holistic and Codex passes) — the ledger rows the verifier must rule on: every non-terminal `blocking` row in its dimension (all of them, for the holistic verifier — `ledger.py <review-doc> open` lists them), followed by any non-terminal `non-blocking` rows marked "information only".
   - The previous author block (paste it into the prompt; it is short).

   For pass 6 the packet is `$P/rows.md` (may be empty — write `None` explicitly) plus the latest `delta.patch` if one exists; there is no prior Codex block.

5. **Launch reviewers** — every agent for the pass in a **single message** (parallel tool calls). Prompts are assembled from the templates under *Agent Prompts*: common preamble + pass-type section + rubric.
   - **Pass 1**: `model: "sonnet"`, one agent per dimension. **Conditional 5th agent — Project Failure Patterns**: resolve the repo root by walking up from the plan's directory looking for a `.git` entry. If `<repo-root>/.claude/skills/extensions/failure-patterns.md` exists, launch a 5th Sonnet agent in the same batch with the Dimension 5 rubric and the absolute path of the patterns file. If it does not exist, do not launch it.
   - **Pass 2**: only the dimensions with a non-terminal blocking row. Resume each dimension's pass-1 agent (see *Resuming agents*), or launch fresh Sonnet agents with the verify packet.
   - **Pass 3**: `model: "fable"`, one fresh agent, holistic rubric.
   - **Pass 4 / 5**: resume the pass-3 agent with the verify packet; or a fresh Fable agent with the packet; or, when the full-recheck escape fired, a fresh Fable agent with the full holistic rubric.
   - **Pass 6 (Codex)**: not an Agent-tool launch. Write the prompt — common preamble with the Codex variant of rule 6, the *Codex final review* pass-type section, and the holistic rubric — to `$P/prompt-codex.txt`, then run the launcher as **one foreground bash call** with a tool timeout of at least `CODEX_TIMEOUT_SECONDS` (default 1200 s):

     ```bash
     REPO_ROOT=$(git -C "$(dirname <plan>)" rev-parse --show-toplevel)
     "$SKILL_DIR/scripts/launch-codex.sh" --pass-dir "$P" --repo "$REPO_ROOT"
     ```

     The script pins the model and effort (`gpt-6-astra`, `high`), a read-only sandbox, and a watchdog; it is the single source of truth for those flags, so never hand-write a `codex exec` line here. Exit 0 means `$P/codex.md` holds the block (Codex's final message, captured by `-o`). Exit 1 means no block, and a marker file in `$P` names why: `.codex-skipped` (CLI missing, broken, or older than the verified floor — its one line says which), `.codex-crashed` (non-zero exit, no output, or output that isn't a valid `<claude-reviewer>` block — `log-codex.txt` has the cause), or `.codex-killed` (watchdog). On `.codex-crashed` re-run the launcher **once**; on any other marker, or a second crash, treat pass 6 as absent: append a one-line `<claude-reviewer>` gap note to the transcript naming the marker and go to step 9. A missing Codex pass never fails the review and is never treated as `ready`.

     After the launcher returns, `head -12 "$P/log-codex.txt"` and confirm the session header shows `model: gpt-6-astra` and `reasoning effort: high` (the script warns if not). If they differ, the host's Codex config or CLI has drifted — report it in the wrap-up rather than trusting the block silently.

   Every Claude agent writes **exactly one block file** at the path you give it (`$P/<dimension>.md` — `scope`, `data-model`, `code-quality`, `testing`, `failure-patterns`, or `holistic`) and returns a short report: verdict, the block path, and its ledger rows. It never edits the plan or the review document. Codex cannot write files (read-only sandbox), so its block is its final message, and you derive its ledger rows from the block's `### Findings` and `### Rulings` lines yourself (dimension `Codex`, IDs `P6-X<n>`).

6. **Collect**:
   a. Append the block files to the transcript in fixed order — `scope`, `data-model`, `code-quality`, `testing`, `failure-patterns`, `holistic`, or `codex` — with `cat "$P/<dimension>.md" >> <review-doc>`. Then read the new blocks once (`cat "$P"/*.md`). If an agent produced no block (failure, timeout), append a one-line `<claude-reviewer>` note naming the gap and continue; its rows keep their status.
   b. Update the ledger with `ledger.py`: `add` the new rows; `set` the status rulings verifiers reported (`verified` / `reopened` / `conceded` / `withdrawn`). If a verifier failed to rule on a row it was given, ask it once more; if the ruling is still missing, set the row to `reopened` — a silent omission never closes a blocking finding. (Codex cannot be asked again mid-pass; a row it was given and did not rule on stays as it was, and you note the omission in the gap line.)
   c. Extract the verdicts. After pass 2 a clean ledger proceeds to pass 3. After pass 3, 4, or 5, if the ledger is clean, or the holistic verdict is `stop review`, the **Claude loop** is over: answer any non-blocking rows the pass raised (step 7b — fix or push back, no further Claude pass, no delta needed), then go to pass 6 (step 4 with `PASS=6`). After pass 6: answer every row it raised or reopened (step 7, once — no further reviewer pass) and go to step 9.

7. **Respond (author step)** — when any row is `open` or `reopened`, or the ledger is otherwise not clean:
   a. Snapshot the plan: `cp <plan> "$P/plan-before.md"`.
   b. For each `open` / `reopened` row: fix the plan, or push back. A fix sets `fixed`; a disagreement sets `pushed-back`, with your reasoning in the response block. Two reviewers raising the same defect: keep the row with the stricter severity or the more complete statement, mark the other `duplicate (<ID>)`, fix once. Answer non-blocking rows the same way; either answer closes them. Never silently ignore a row.
   c. Produce the delta for the next pass and set the ledger statuses (`ledger.py <review-doc> set P1-S1=fixed 'P1-S2=duplicate (P1-C1)' ...`): `mkdir -p "$SCRATCH/pass-$((PASS+1))"; diff -u "$P/plan-before.md" <plan> > "$SCRATCH/pass-$((PASS+1))/delta.patch"`. Count added/rewritten lines (`grep -c '^+[^+]'`) against the plan's total for the full-recheck test.
   d. Append the author block (format below): one line per row, by ID; never restate the finding; at most two sentences for a pushback; mark any fix that changes the design with `(design change)`.

   **Pass 6 response.** Nobody verifies this response, so it is held to a stricter bar: fix only what you can verify against the code yourself, and cite the evidence in the author line as a reviewer would (`file:line`). A pass-6 fix that would be a `(design change)` is still made and marked, but it goes to the operator at wrap-up as an unverified design change. Still snapshot the plan and write `$P/delta.patch` (against `$P/plan-before.md`, in the same directory — there is no next pass) so the record shows what Codex changed. Pass-6 `fixed` rows stay `fixed`; do not mark them `verified`.

8. **Claude-loop exit conditions** — any one sends the loop to pass 6 (step 4 with `PASS=6`):
   - The ledger is clean (checked in step 6c, before responding) after pass 3, 4, or 5. A clean ledger after pass 2 does not exit — pass 3 still runs, with no rows to rule on.
   - The holistic verdict is `stop review` (also step 6c).
   - Every finding in this pass was pushed back with no plan change — the disagreement needs a human, and Codex gets to weigh in on it first (its packet carries the pushed-back rows).
   - `PASS == 5` has completed.

   Otherwise go back to step 4. Pass 6 has no exit condition of its own: after its author step (or its gap note), go to step 9.

## Wrap up

9. Set `Review Status: Complete`, or `Review Status: Complete — operator needed` when blocking rows remain non-terminal — except pass-6 `fixed` rows, which are closed by the author's evidence-cited fix and never gate status (they are reported as unverified instead). A pass-6 blocking row that is `pushed-back`, or a pass-6 fix marked `(design change)`, does need the operator. Add one line under the header: `Findings: <n> blocking, <m> non-blocking — verified <a>, conceded <b>, pushed back <c>, open <d>, fixed in pass 6 (unverified) <e>`, followed by `Codex pass: ran | skipped (<marker reason>)`. Re-run `wc -w` and update `Plan words:` — fixes add words, and a plan the loop pushed over budget gets the same warning and split proposal as step 1. Tell the user the loop is finished: passes run, the key changes made, what Codex found and how it was answered (or why it did not run), the word count against budget (with the split proposal when over), and anything left for the operator. Then present the plan's **Operator forks** for resolution — options plus your recommendation for each, not the whole plan. Record each resolution as **one line** in the plan's decision log (decision, date, pointer to the fork) — not the reasoning; the review transcript holds that. The plan is build-ready (`planned` in repos using roadmap tags) only once all forks are resolved.

## Block formats

Timestamps come from `date '+%Y-%m-%d %H:%M %Z'`, never from memory.

**Reviewer block** (written to `$P/<dimension>.md`):

```
<claude-reviewer>
Pass N - {dimension name | Holistic Review | Holistic Verify | Codex Review} - YYYY-MM-DD HH:MM TZ

Verdict: ready | needs revision | stop review

### Findings
- **P1-S1** [blocking] §4.2 — one-sentence claim. Evidence: path/file.py:123 (or the query run). Change: what the plan must say or do.
- **P1-S2** [non-blocking] §6 — ...

### Rulings   (verify passes — and any pass where you rule on a pushed-back row; one line per row)
- P1-S1: verified — one line saying what you checked.
- P1-D2: reopened — the fix does X but the plan still assumes Y at §5.1.
- P1-T1: conceded — the author's pushback holds because ...
</claude-reviewer>
```

Rules for reviewer blocks — they are read by the author and by later reviewers, and every byte costs a pass:
- Findings only. No method narration, no "confirmed sound" lists, no restating the plan or prior findings. A verified ruling is one line. The block ends at the last finding or ruling — no "no other findings", no "verified against the codebase" summary, no closing paragraph of any kind. (Reviewers add these unless told not to; the rule is here because they did.)
- At most ~120 words per finding. Claim, evidence, change — nothing else.
- Every finding cites a plan section and a file:line (or the exact query/command) — verify against the codebase, do not speculate.
- No findings in your scope this pass: write `No findings.` under `### Findings`.
- IDs: `P<pass>-<dim><n>`, numbered from 1 within your block.

**Reviewer return message** (the Agent tool result, read by the orchestrator):

```
Verdict: needs revision
Block: /tmp/review-plan/auth-redesign/pass-1/scope.md
| ID | Dimension | Severity | Finding | Plan § | Status |
| P1-S1 | Scope | blocking | Callers of load_grid in poller not covered | §4.2 | open |
| P1-S2 | Scope | non-blocking | Env var GRID_TTL undocumented | §6 | open |
```

For verify passes the rows carry the new status (`verified` / `reopened` / `conceded` / `withdrawn`), and any new finding is a new row with `open`.

The Codex reviewer (pass 6) has no return message: its whole final message is the block, captured to `$P/codex.md`. The orchestrator builds its rows from the block — one `open` row per `### Findings` line, one `set` per `### Rulings` line.

**Author block** (appended to the transcript by you):

```
<claude-author>
Pass N Response - YYYY-MM-DD HH:MM TZ

- P1-S1: fixed — §4.2 now lists the three poller call sites and the ordering constraint.
- P1-D2: pushed back — the column is NOT NULL since migration 0042 (backend/migrations/0042_*.py:18); the null-handling the reviewer asks for cannot trigger.
- P1-T1 (non-blocking): fixed — added the failure-path case to §7.
- P3-H1: fixed (design change) — the cache moved from per-request to per-round; §5 rewritten.
Plan delta: pass-2/delta.patch — 41 of 612 lines changed.
</claude-author>
```

---

## Agent Prompts

### Common preamble (every agent prompt)

```
You are reviewing a software development plan. You evaluate the plan against your assigned rubric, write exactly one feedback block to the file path given below, and return a short report. You never edit the plan and never edit the review document.

## Files

- Plan document: {absolute-path-to-plan}
- Review document (ledger + transcript): {absolute-path-to-review}
- Write your block to: {absolute-path-to-block-file}
- Repository root to verify against: {absolute-repo-root} (use absolute paths under it for every read and grep — the plan may live in a worktree)

## Rules

1. Verify claims against the actual codebase before flagging them. Read the code; do not speculate.
2. Findings only. No narration of your method, no lists of things you confirmed are fine, no restating the plan or earlier findings. At most ~120 words per finding: claim, evidence (file:line or the exact query), and the concrete change the plan needs. The block ends at the last finding or ruling — no "no other findings", no "verified against the codebase" summary.
3. A finding that names no concrete change is non-blocking.
4. Do not re-raise a ledger row that is `verified`, `conceded`, `withdrawn` or `duplicate` unless you have new evidence the earlier ruling missed. Do not re-raise a `pushed-back` row unless you can answer the author's reasoning; say `conceded` if you cannot.
5. Get the timestamp from `date '+%Y-%m-%d %H:%M %Z'`.
6. Write the block in the exact format below to the block path, then return ONLY three things: `Verdict: ...`, `Block: <path>`, and your ledger rows as a markdown table (ID | Dimension | Severity | Finding | Plan § | Status). Nothing else in the return message — no summary, no "notable", no list of what you checked.

## Verdicts

- `needs revision` — at least one blocking finding is open or reopened in your scope.
- `ready` — no blocking finding is open or reopened in your scope.
- `stop review` — (holistic only) every blocking row is terminal and the remaining non-blocking items do not justify another pass.

## Block format

<claude-reviewer>
Pass {N} - {dimension} - {timestamp}

Verdict: ...

### Findings
- **P{N}-{dim}{n}** [blocking|non-blocking] §{plan section} — claim. Evidence: ... Change: ...
(or `No findings.`)

### Rulings          ← verify passes, and any pushed-back row you rule on
- {row ID}: verified | reopened | conceded | withdrawn — one line.
</claude-reviewer>
```

**Codex variant (pass 6 only).** Codex runs in a read-only sandbox and cannot write files, and its final message is captured verbatim as the block. Replace the `Write your block to:` line in *Files* with `Your block is your final message (it is captured to a file for you); do not try to write files.`, and replace rule 6 with:

```
6. Your FINAL message must be exactly one block in the format below — starting with `<claude-reviewer>` and ending with `</claude-reviewer>` — and nothing else: no preamble, no summary after the closing tag, no ledger table. Work through the codebase with shell commands as needed before you answer; only the final message is kept.
```

### Pass-type section: full review (pass 1 and pass 3)

```
## This pass: full review

Read the plan document thoroughly. The review document's ledger lists any findings already raised; on pass 1 it is empty. Evaluate the whole plan against your rubric. Number your findings P{N}-{dim}1, P{N}-{dim}2, ...

(Pass 3 only) You must also rule on every non-terminal blocking row, re-checking the revised text and the code — the rows are listed here, and the latest plan delta is at {absolute-path-to-delta.patch}:
{contents of rows.md}
```

### Pass-type section: scoped verify (passes 2, 4, 5)

```
## This pass: scoped verify

The author revised the plan in response to the previous pass. You are NOT re-reviewing the plan. You are ruling on the rows below and checking the delta for regressions in your scope.

- Rows you must rule on (every one, no omissions; rows marked "information only" are non-blocking — rule on them in one line if you can, never re-open them):
{contents of rows.md}
- The author's response:
{previous author block}
- Plan delta (unified diff of the revision): {absolute-path-to-delta.patch}
- Your previous block, for the evidence you cited: {absolute-path-to-prior-block}

Do:
1. For each row: re-read the revised plan section and re-check the code. Rule `verified` (the change resolves it), `reopened` (it does not — say what is still wrong, one line), `conceded` (the author's pushback holds), or `withdrawn` (you were wrong).
2. Read the delta. If a change introduced a new problem in your scope — a contradiction with an unchanged section, a broken citation, a new gap — raise it as a new finding with a fresh ID (P{N}-{dim}1, ...). Only fix-introduced problems; do not re-review unchanged text.
3. Write the block and return the rows with their new statuses.
```

When the agent is being **resumed** rather than launched fresh, prefix this section with: "You reviewed this plan in pass {M}; your context already holds the plan and the code you verified. Do not re-explore what you have already read."

### Pass-type section: Codex final review (pass 6)

```
## This pass: final independent review

You are the last reviewer. Five passes of Claude reviewers have already reviewed this plan against the rubric below and the author has revised it; the ledger and transcript in the review document record every finding, fix and pushback so far. You come from a different model and tool stack, and your job is to catch what those reviewers agreed to miss: verify the plan against the codebase yourself rather than trusting the ledger's `verified` rulings, and look hardest at cross-cutting assumptions, at sections the fixes touched (the latest delta is at {absolute-path-to-delta.patch}, or `None`), and at anything the plan asserts about the code without a file:line.

Give the most weight to **Outcome & Efficacy**. "Will executing this plan produce the outcome in `## Objective`?" is the question hardest to answer from inside a plan's own framing, and every reviewer before you shared that framing. Read the objective and success criteria first, then read the design as an attempt to meet them, and say where it would not.

Nobody verifies your findings after this pass — the author fixes or pushes back once and the review ends — so every finding must carry evidence the author can check in one read (file:line or the exact command and its output). A finding you cannot evidence is non-blocking.

Number your findings P6-X1, P6-X2, ... You must also rule on every non-terminal blocking row listed here (`conceded` / `reopened` / `verified` / `withdrawn`, one line each; `None` means there are none):
{contents of rows.md}
```

### Dimension 1: Scope & Completeness

```
## Your Review Dimension: Scope & Completeness

Focus exclusively on whether the plan covers its implementation scope end-to-end:

- Does every code path that will be modified or created have a clear specification?
- Are there consumers of the modified code (callers, importers, dependents) that the plan doesn't account for? Grep the codebase for imports and usages of functions/modules being changed.
- Is rollout/migration ordering addressed? If the plan touches shared state, databases, or APIs, what happens to running code during the transition?
- Are setup, cleanup, environment variables, dependencies, and configuration changes covered?
- Are ownership boundaries clear — does the plan specify what belongs to backend, frontend, data, infra?
- If the project has sprint/variant paths (e.g., mobile vs desktop, standard vs premium), are all variants covered?
- Does the plan end with `## Operator forks` and `## Live gates` sections? Flag if either is missing. Flag any fork that is actually resolvable by evidence or existing convention (the author should decide it, not defer it to the operator). Flag any step touching real money, production data/config, or irreversible external effects that is absent from Live gates.
- Does the plan open with `## Objective` ending in **Success criteria**? Flag if it is missing, if the objective is phrased as work rather than outcome, or if any criterion cannot be checked after execution. Do not judge here whether the design will meet the criteria — that is the holistic reviewer's question; yours is whether the section exists and is checkable.

Be direct and actionable. Separate blocking concerns from minor follow-ups. Prefer concrete examples over generic criticism. Verify your claims against the actual codebase.
```

### Dimension 2: Data Model & Storage Accuracy

```
## Your Review Dimension: Data Model & Storage Accuracy

Focus exclusively on whether the plan's references to data models, schemas, and storage are correct:

- For every table, column, field, model attribute, or type referenced in the plan: verify it actually exists in the codebase. Read the relevant model definitions, migration files, schema files, or type definitions. Flag any reference to structures that don't exist.
- Check key-space and identity translations: if the plan involves passing IDs, keys, or identifiers across module boundaries, verify the formats match (e.g., slugs vs abbreviations vs numeric IDs vs UUIDs). Flag any mismatch.
- If the plan proposes new fields or models, check they don't conflict with existing ones.
- If the plan reads from or writes to storage (DB, files, cache, APIs), verify the assumed data shape matches reality.
- Check that nullable/optional fields are handled correctly — does the plan assume a field is always present when it could be null?

Be direct and actionable. Every finding must reference the specific file and line/definition you checked. Do not speculate — read the code and verify.
```

### Dimension 3: Code Quality & Reuse

```
## Your Review Dimension: Code Quality & Reuse

Focus exclusively on design quality and reuse of existing code:

- Does the plan propose creating new helpers, utilities, or abstractions when equivalent ones already exist? Search the codebase for existing implementations before flagging.
- Is the design the simplest that matches the current architecture? Watch for over-engineering, unnecessary indirection, or premature abstraction.
- Does the plan introduce hidden coupling between modules that should remain independent?
- Does it propose parallel implementations instead of extending established code paths? If so, is there an explicit migration plan?
- Are there brittle sequencing assumptions (step A must complete before step B) that aren't enforced in the design?
- Does the plan follow the project's existing patterns and conventions?

Be direct and actionable. When flagging duplication, name the existing module/function that should be reused and its file path.
```

### Dimension 4: Testing & Verification

```
## Your Review Dimension: Testing & Verification

Focus exclusively on whether the plan's testing and verification strategy matches its risk level:

- Are the proposed tests sufficient for the complexity and risk of the changes? High-risk changes (data migrations, financial calculations, security) need more coverage than UI tweaks.
- Are there missing edge cases, boundary conditions, or failure-path tests?
- Are validation/verification commands concrete and runnable? Check that referenced test commands, scripts, or tools actually exist in the project.
- If the plan modifies shared fixtures, test data, or test utilities, are downstream test consumers accounted for?
- Are there data-contract or integration boundaries that need contract tests?
- Does the plan specify how to verify the changes work end-to-end, not just that tests pass?

Be direct and actionable. When suggesting a missing test, describe the specific scenario and expected behavior — don't just say "add more tests."
```

### Dimension 5: Project Failure Patterns (conditional, Sonnet)

```
## Your Review Dimension: Project Failure Patterns

A project-local file at {absolute-path-to-failure-patterns.md}
documents recurring bug classes specific to this codebase. For each pattern in
that file:

1. Read the pattern's "Triggers when" condition. Determine whether this plan
   matches. If not, move on — DO NOT report the pattern.
2. If the pattern triggers, read its "What to check" guidance and evaluate
   whether the plan addresses it. Cite file:line evidence from the codebase
   when flagging gaps.
3. Each pattern fires at most once per review pass per matching site.

If no patterns trigger on this plan, write `No findings.` with verdict `ready`.
Do not manufacture findings — most plans will not match any pattern, and that
is the expected outcome.
```

### Holistic Review (pass 3 — and pass 4 when the full-recheck escape fired — Fable; also the rubric for the pass-6 Codex review, with `H` read as `X`)

```
## Your Review: Holistic

You are performing a holistic review of the plan across ALL dimensions. Read the plan, then the review document: the ledger is the authoritative state of every finding so far; the transcript holds the reasoning behind fixes and pushbacks. Your job is to catch cross-cutting issues the dimension reviewers missed, and problems the author's revisions introduced.

Review the plan against the four dimensions, then against the efficacy question that none of them asks:

### Scope & Completeness
{same rubric as Dimension 1}

### Data Model & Storage Accuracy
{same rubric as Dimension 2}

### Code Quality & Reuse
{same rubric as Dimension 3}

### Testing & Verification
{same rubric as Dimension 4}

### Outcome & Efficacy

The dimension reviewers check that the plan is complete, accurate, well-built and tested. None of them asks whether executing it produces the outcome in `## Objective`. You do:

- Trace the mechanism from each proposed change to each success criterion. Where is the link asserted rather than shown? Name the assumption, and the evidence in the codebase or the measurement that would establish it. Check the ones you can check now.
- What must be true of the current system for the design to work — data volumes, call patterns, ordering, an external service's behaviour, a user's actual workflow — that the plan states without evidence or does not state at all?
- What would make the plan succeed on its own terms, every step done and every test green, yet miss the objective? A criterion no change touches; a bottleneck the design moves rather than removes; a second-order effect on the metric (cache added, staleness introduced); a fix for the symptom the problem statement names rather than its cause.
- Are the success criteria checkable after execution, and does the plan say how and when each will be checked? A criterion with no measurement is a hope, not a criterion.
- Does the plan carry an outcome the objective does not state — a refactor that is really for a later feature, a migration that assumes a traffic pattern? It belongs in `## Objective` or out of the plan.

A finding here is blocking when it names a concrete gap between the design and a stated criterion that the plan must close; a doubt you cannot evidence is non-blocking. Cite the plan section and the file:line or measurement, as for any finding.

Additionally, look for:
- Cross-cutting concerns that span multiple dimensions (e.g., a scope gap that also creates a testing gap)
- Inconsistencies between sections, especially between revised and unrevised text
- Whether a `pushed-back` row deserves reconsideration — rule `conceded` or `reopened` on each one; do not leave it hanging
- Whether `## Operator forks` defers decisions the author could resolve from evidence, and whether `## Live gates` covers every money/prod-touching step
- Content that records thinking instead of driving execution: decision narration, history of the plan's own drafts, rejected alternatives at length, census tables behind settled decisions, context restated from files an implementer will read anyway. Raise it as ONE non-blocking finding that names the sections to cut and what one-line replacement each needs. Long plans starve reviewers of code-verification context, so this is worth the line.

Also weigh any failure-pattern findings in the ledger when forming your verdict.

Number new findings P{N}-H1, P{N}-H2, ... Use `Verdict: stop review` when every blocking row is terminal and what remains is not worth another pass, even if non-blocking suggestions remain.
```

---

## Notes

- Claude reviewer agents (passes 1–5) are launched via the **Agent tool** with `model: "sonnet"` (dimension passes) or `model: "fable"` (holistic passes). Pass 6 is the only pass that needs an external CLI: `scripts/launch-codex.sh` runs the **Codex CLI** with `gpt-6-astra` at `high` reasoning effort, pinned in the script (the single source of truth — a host's `~/.codex/config.toml` default is deliberately not relied on; the devbox sets none). The pin was verified on 2026-09-14 on the laptop (codex 0.153.4) and the devbox (0.154.0); the script's `MIN_CODEX` floor is the lowest of those. To change the model, effort, timeout or floor, edit the script and bump the plugin version.
- Codex is optional at runtime: if the CLI is missing, broken, too old, out of capacity, or stalls past `CODEX_TIMEOUT_SECONDS`, the launcher leaves a marker file and exits 1, and the review completes without pass 6 (gap noted in the transcript and the wrap-up). Install/update with `codex update` on a laptop; on the devbox it lives at `~/.local/bin/codex`, which is on PATH only in a login shell (`bash -lc`).
- **The Codex sandbox must be able to start on the host.** The launcher probes it (`codex sandbox -- /usr/bin/true`) before spending a pass, because `codex exec` only enters the OS sandbox when the model runs a shell command: a host where the sandbox is broken still answers a "reply PONG" smoke test, and then returns a well-formed block saying it could read nothing. On **Ubuntu 24.04** (the devbox) `bwrap` fails with `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`, because 24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`: an unconfined process may create a user namespace but gets no capabilities inside it, so bwrap cannot configure the namespace's loopback. Neither Codex's bundled `bwrap` nor the system `bubblewrap` package (verified 2026-09-14, 0.9.0-1ubuntu0.1) ships an exempting profile. The fix is the distro's own pattern for such tools (see `/etc/apparmor.d/1password`, `Discord`): install the system package so Codex uses `/usr/bin/bwrap` (it prefers a `bwrap` on PATH over its bundled copy), then load an unconfined profile that grants it `userns`:

  ```
  sudo apt install -y bubblewrap
  sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOF'
  abi <abi/4.0>,
  include <tunables/global>
  profile bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,
    include if exists <local/bwrap>
  }
  EOF
  sudo apparmor_parser -r /etc/apparmor.d/bwrap
  codex sandbox -- /usr/bin/true && echo sandbox-ok
  ```

  The broader alternative, `sysctl kernel.apparmor_restrict_unprivileged_userns=0`, lifts the mitigation for every unprivileged process; prefer the per-binary profile. A failed probe is a `.codex-skipped` whose one line names the error and points here. There is deliberately **no** `CODEX_SANDBOX_UNAVAILABLE` bypass here, unlike pr-review-loop: running an external model's shell commands unsandboxed is defensible only on a throwaway container, and this skill runs on persistent machines with credentials. Fix the host, or run the review on one whose sandbox works.
- `"fable"` is the Agent tool's alias for the current Claude Fable model, so the holistic pass tracks the newest Fable release without a change here. If the Agent tool on a host rejects `model: "fable"` (older Claude Code, or no Fable access), fall back to `model: "opus"` for that pass and say so in the transcript.
- All agents for a pass MUST be launched in a single message (parallel tool calls) to minimise wall-clock time.
- Verify passes resume the original reviewer when the harness allows (SendMessage to the agent returned by the Agent tool). A resumed agent keeps its model. A fresh verify agent gets the prior block path in its packet so it can re-check the same evidence.
- Reviewers write blocks to `$SCRATCH/pass-N/`, never to the review document. Only the orchestrator writes the review document, so the transcript is always in pass order and a block can never land after its response. `/tmp` is per-host and per-boot; the transcript in the repo is the durable record.
- If an agent fails or times out, note the gap in the transcript and continue with the blocks you have. Never treat a missing block as `ready`.
- The ledger is the single source of truth for review state. The transcript is the audit trail. A reviewer that wants the history reads the ledger first and the transcript only for the reasoning behind a specific row.

## What changed in 0.6.3 (and why)

The launcher probes the Codex sandbox before launching. The first real pass 6 on the devbox produced a well-formed block that said Codex could read nothing: every shell command had died at sandbox setup (`bwrap: loopback: Failed RTM_NEWADDR`), a failure the pre-release smoke test could not see because a prompt that only replies never enters the sandbox. The probe runs one command through the same sandbox and skips the pass with the error and the host fix when it fails. The host fix on Ubuntu 24.04 is the system `bubblewrap` package; no sandbox bypass was added (see Notes).

## What changed in 0.6.0 (and why)

A sixth pass: a single Codex `gpt-6-astra` (high effort) review that runs after the Claude loop exits for any reason, reads the converged plan plus the whole ledger, rules on any still-open blocking rows, and gets one author response with no re-verification. Passes 1–5 share one model family and one rubric set, so their misses correlate; a different model on the finished plan is cheap independent signal. It is last so it sees the converged plan, and it has no verify pass so the loop stays bounded — its fixes are reported as unverified, and a pushed-back or design-changing pass-6 row goes to the operator. The pass is optional at runtime: a missing or failing Codex CLI is a noted gap, never a failed review.

An efficacy question. Reading the rubrics side by side showed that no reviewer asked whether executing the plan would produce its intended outcome: Scope checks the work is fully specified, Testing checks the verification strategy, and the holistic pass repeated the four dimensions. A plan could pass every rubric and build the wrong thing. Two changes close that: the plan contract now requires an opening `## Objective` section with checkable success criteria, so the goal is the writer's explicit statement rather than the reviewer's inference; and the holistic rubric gains an **Outcome & Efficacy** section that traces each change to each criterion and asks what would let the plan succeed on its own terms yet miss the objective. It sits in the holistic pass, not a fifth dimension agent, because the question needs the whole plan in view. The Codex pass inherits the rubric and is told to weight that section most, which also makes pass 6 a different lens from pass 3 rather than a second run of the same one. Scope now checks only that the section exists and is checkable.

## What changed in 0.5.0 (and why)

The review document moved from beside the plan into a `reviews/` subdirectory (step 2). In one repo, 93 review transcripts sat interleaved with 106 plans in a single directory: nearly half the files and half the text in the folder a reader browses to find a plan, and cited by almost nothing outside the plan itself. A re-review of a plan whose review is still at the old location moves that file into `reviews/` instead of starting a second one.

## What changed in 0.4.0 (and why)

Measured over 89 loops in one repo: pass duration did not grow with the review file, but loops grew from a median 3 passes to 5 because exit needed every reviewer to say `ready` in the same pass, and every pass was a full re-review by fresh agents that re-explored the codebase. Blocking findings decayed 6 → 4 → 2 → 1 → 0 per pass, so the last one or two passes were confirmation passes. 0.4.0 makes exit ledger-driven (no non-terminal blocking finding), turns passes 2, 4 and 5 into scoped verifies that resume the original reviewer, caps reviewer prose to findings only, moves block writes out of the shared file, and adds a plan word budget that trims and warns rather than refuses — a long plan is usually recording decisions instead of directing work.
