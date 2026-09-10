---
name: review-plan
description: Facilitates an automated plan review loop using parallel Claude reviewer agents, iterating on feedback until the plan is approved.
---

After a plan is created:

## Setup

1. **Save the plan to the repo**: Copy the plan document to `<repo-root>/docs/plans/` with a descriptive filename (e.g., `docs/plans/auth-redesign.md`). Resolve the repo root by running `git rev-parse --show-toplevel`.

   **Enforce the plan contract before starting the loop.** The plan document must end with two sections (add them if missing; an empty section must say `None` explicitly):
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
   | A short problem statement | Motivation and narrative beyond that statement; the same rule stated in three sections |

   The test for a sentence: would an implementing agent do anything differently without it? If not, it goes. Moved material lands in a companion file under the repo's notes/investigations convention (or `docs/plans/<slug>-context.md` if there is none) with a one-line pointer from the plan; material with no future reader is deleted — git keeps it.

   Re-measure after the diet. If the plan is still over budget, write the warning into the review document header and say it to the writer directly before launching pass 1:

   ```
   Plan words: 7,900 / 5,000 — OVER BUDGET after diet
   Split proposal: <two or three independently reviewable plans, each named by the PR packets or sections it would own, in build order>
   ```

   The warning is repeated at wrap-up (step 9). Proceed with the review regardless — the budget shapes the plan, it does not block it.

2. **Create the review document** at the same path with a `-review` suffix (e.g., `docs/plans/auth-redesign-review.md`):

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
   - **ID**: `P<pass>-<dim><n>` with dim ∈ `S` (Scope), `D` (Data model), `C` (Code quality), `T` (Testing), `F` (Failure patterns), `H` (Holistic). E.g. `P1-S2`, `P3-H1`.
   - **Severity**: `blocking` | `non-blocking`. A finding that names no concrete change to the plan is non-blocking.
   - **Status**: `open` (raised, unanswered) → `fixed` (plan changed, awaiting verification) or `pushed-back` (author disagrees; reasoning lives in the transcript) → `verified` | `reopened` | `conceded` (reviewer accepted the pushback) | `withdrawn` (reviewer retracted).
   - **Terminal** statuses: `verified`, `conceded`, `withdrawn`, and `duplicate (<ID>)` — the author's mark for a finding another reviewer raised in the same pass; the surviving row keeps the stricter severity. For **non-blocking** rows, `fixed` and `pushed-back` are also terminal — they are closed by the author's answer and never gate exit.
   - **Clean ledger**: no `blocking` row in a non-terminal status. A fix nobody has verified is not clean.

3. **Create the scratch directory and record the start state**:

   ```bash
   SKILL_DIR="<this skill's base directory>"   # holds scripts/ledger.py
   SLUG=auth-redesign            # the plan's basename without .md
   SCRATCH=/tmp/review-plan/$SLUG; mkdir -p "$SCRATCH"
   PASS=0
   ```

   `$SKILL_DIR/scripts/ledger.py <review-doc> add|set|open` is the only way the ledger is edited: `add` inserts rows above the sentinel, `set` changes a row's status, `open` prints the non-terminal blocking rows (exit 1 if any) — the exit test and the verify packet in one command.

   Per-pass files live under `$SCRATCH/pass-N/`: each reviewer's block, the pre-edit plan snapshot, and the plan delta. Reviewers write their blocks **there**, and you append them to the transcript in a fixed order. Reviewers never write to the review document, so parallel agents cannot interleave or clobber each other, and a block can never land after the response to it.

## Pass schedule

At most five passes of fixed types. Two are full reviews; the rest are **scoped verification passes** that rule on the open findings and look for regressions the fixes introduced. Exit at the first verify pass that leaves the ledger clean.

| Pass | Type | Agents | Reads | Skipped when |
|---|---|---|---|---|
| 1 | Dimension review (full) | 4 Sonnet in parallel, +1 failure-patterns agent when the patterns file exists | plan, rubric | never |
| 2 | Dimension verify (scoped) | one Sonnet per dimension that has a non-terminal blocking row | its pass-1 block, the author response, the plan delta, its rows | ledger already clean |
| 3 | Holistic review (full) | 1 Fable, fresh | plan, ledger, transcript; rules on every non-terminal blocking row | never — a clean ledger after pass 2 only means it has no rows to rule on |
| 4 | Holistic verify (scoped) | the pass-3 agent, resumed | pass-3 block, author response, plan delta, its rows | ledger clean after pass 3 |
| 5 | Final verify (scoped) | the pass-3 agent, resumed | as pass 4 | ledger clean after pass 4 |

After pass 5 the loop ends whatever the ledger says; anything still non-terminal goes to the operator in the wrap-up.

**Full-recheck escape.** If an author response's plan delta **adds or rewrites** more than 20% of the plan's lines (count `+` lines in the unified diff, not deletions — a hygiene cut is not a design change), or marks any fix as a `(design change)`, the next holistic pass is a **full holistic review by a fresh Fable agent** instead of a scoped verify. It takes the pass-4 slot and pass 5 verifies it. This fires at most once per loop.

**Resuming agents.** Verify passes prefer to **resume** the reviewer that raised the findings — via SendMessage to the agent the Agent tool returned — because it already holds the plan and the code it verified and must not re-explore. If the harness does not expose the agent for resumption, launch a fresh agent of the same model with the verify packet (which includes the prior block, so nothing is lost but exploration time).

## Loop

Repeat from step 4 until an exit condition (step 8) fires.

4. **Increment pass**: `PASS += 1`; `P=$SCRATCH/pass-$PASS; mkdir -p "$P"`. For a verify pass, assemble the packet:
   - `$P/delta.patch` — produced by the previous author step (step 7c).
   - `$P/rows-<dimension>.md` (pass 2) or `$P/rows.md` (holistic passes) — the ledger rows the verifier must rule on: every non-terminal `blocking` row in its dimension (all of them, for the holistic verifier — `ledger.py <review-doc> open` lists them), followed by any non-terminal `non-blocking` rows marked "information only".
   - The previous author block (paste it into the prompt; it is short).

5. **Launch reviewers** — every agent for the pass in a **single message** (parallel tool calls). Prompts are assembled from the templates under *Agent Prompts*: common preamble + pass-type section + rubric.
   - **Pass 1**: `model: "sonnet"`, one agent per dimension. **Conditional 5th agent — Project Failure Patterns**: resolve the repo root by walking up from the plan's directory looking for a `.git` entry. If `<repo-root>/.claude/skills/extensions/failure-patterns.md` exists, launch a 5th Sonnet agent in the same batch with the Dimension 5 rubric and the absolute path of the patterns file. If it does not exist, do not launch it.
   - **Pass 2**: only the dimensions with a non-terminal blocking row. Resume each dimension's pass-1 agent (see *Resuming agents*), or launch fresh Sonnet agents with the verify packet.
   - **Pass 3**: `model: "fable"`, one fresh agent, holistic rubric.
   - **Pass 4 / 5**: resume the pass-3 agent with the verify packet; or a fresh Fable agent with the packet; or, when the full-recheck escape fired, a fresh Fable agent with the full holistic rubric.

   Every agent writes **exactly one block file** at the path you give it (`$P/<dimension>.md` — `scope`, `data-model`, `code-quality`, `testing`, `failure-patterns`, or `holistic`) and returns a short report: verdict, the block path, and its ledger rows. It never edits the plan or the review document.

6. **Collect**:
   a. Append the block files to the transcript in fixed order — `scope`, `data-model`, `code-quality`, `testing`, `failure-patterns`, or `holistic` — with `cat "$P/<dimension>.md" >> <review-doc>`. Then read the new blocks once (`cat "$P"/*.md`). If an agent produced no block (failure, timeout), append a one-line `<claude-reviewer>` note naming the gap and continue; its rows keep their status.
   b. Update the ledger with `ledger.py`: `add` the new rows; `set` the status rulings verifiers reported (`verified` / `reopened` / `conceded` / `withdrawn`). If a verifier failed to rule on a row it was given, ask it once more; if the ruling is still missing, set the row to `reopened` — a silent omission never closes a blocking finding.
   c. Extract the verdicts. After pass 3 or later, if the ledger is clean, or the holistic verdict is `stop review`, the loop is over: answer any non-blocking rows the pass raised (step 7b — fix or push back, no further reviewer pass, no delta needed) and go to step 9. After pass 2 a clean ledger proceeds to pass 3.

7. **Respond (author step)** — when any row is `open` or `reopened`, or the ledger is otherwise not clean:
   a. Snapshot the plan: `cp <plan> "$P/plan-before.md"`.
   b. For each `open` / `reopened` row: fix the plan, or push back. A fix sets `fixed`; a disagreement sets `pushed-back`, with your reasoning in the response block. Two reviewers raising the same defect: keep the row with the stricter severity or the more complete statement, mark the other `duplicate (<ID>)`, fix once. Answer non-blocking rows the same way; either answer closes them. Never silently ignore a row.
   c. Produce the delta for the next pass and set the ledger statuses (`ledger.py <review-doc> set P1-S1=fixed 'P1-S2=duplicate (P1-C1)' ...`): `mkdir -p "$SCRATCH/pass-$((PASS+1))"; diff -u "$P/plan-before.md" <plan> > "$SCRATCH/pass-$((PASS+1))/delta.patch"`. Count added/rewritten lines (`grep -c '^+[^+]'`) against the plan's total for the full-recheck test.
   d. Append the author block (format below): one line per row, by ID; never restate the finding; at most two sentences for a pushback; mark any fix that changes the design with `(design change)`.

8. **Exit conditions** — any one exits to step 9:
   - The ledger is clean (checked in step 6c, before responding) after pass 3, 4, or 5. A clean ledger after pass 2 does not exit — pass 3 still runs, with no rows to rule on.
   - The holistic verdict is `stop review` (also step 6c).
   - Every finding in this pass was pushed back with no plan change — the disagreement needs a human.
   - `PASS == 5` has completed.

   Otherwise go back to step 4.

## Wrap up

9. Set `Review Status: Complete`, or `Review Status: Complete — operator needed` when blocking rows remain non-terminal. Add one line under the header: `Findings: <n> blocking, <m> non-blocking — verified <a>, conceded <b>, pushed back <c>, open <d>`. Re-run `wc -w` and update `Plan words:` — fixes add words, and a plan the loop pushed over budget gets the same warning and split proposal as step 1. Tell the user the loop is finished: passes run, the key changes made, the word count against budget (with the split proposal when over), and anything left for the operator. Then present the plan's **Operator forks** for resolution — options plus your recommendation for each, not the whole plan. Record each resolution as **one line** in the plan's decision log (decision, date, pointer to the fork) — not the reasoning; the review transcript holds that. The plan is build-ready (`planned` in repos using roadmap tags) only once all forks are resolved.

## Block formats

Timestamps come from `date '+%Y-%m-%d %H:%M %Z'`, never from memory.

**Reviewer block** (written to `$P/<dimension>.md`):

```
<claude-reviewer>
Pass N - {dimension name | Holistic Review | Holistic Verify} - YYYY-MM-DD HH:MM TZ

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

### Holistic Review (pass 3 — and pass 4 when the full-recheck escape fired — Fable)

```
## Your Review: Holistic

You are performing a holistic review of the plan across ALL dimensions. Read the plan, then the review document: the ledger is the authoritative state of every finding so far; the transcript holds the reasoning behind fixes and pushbacks. Your job is to catch cross-cutting issues the dimension reviewers missed, and problems the author's revisions introduced.

Review the plan against all four dimensions:

### Scope & Completeness
{same rubric as Dimension 1}

### Data Model & Storage Accuracy
{same rubric as Dimension 2}

### Code Quality & Reuse
{same rubric as Dimension 3}

### Testing & Verification
{same rubric as Dimension 4}

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

- Reviewer agents are launched via the **Agent tool** with `model: "sonnet"` (dimension passes) or `model: "fable"` (holistic passes). No external CLI is needed.
- `"fable"` is the Agent tool's alias for the current Claude Fable model, so the holistic pass tracks the newest Fable release without a change here. If the Agent tool on a host rejects `model: "fable"` (older Claude Code, or no Fable access), fall back to `model: "opus"` for that pass and say so in the transcript.
- All agents for a pass MUST be launched in a single message (parallel tool calls) to minimise wall-clock time.
- Verify passes resume the original reviewer when the harness allows (SendMessage to the agent returned by the Agent tool). A resumed agent keeps its model. A fresh verify agent gets the prior block path in its packet so it can re-check the same evidence.
- Reviewers write blocks to `$SCRATCH/pass-N/`, never to the review document. Only the orchestrator writes the review document, so the transcript is always in pass order and a block can never land after its response. `/tmp` is per-host and per-boot; the transcript in the repo is the durable record.
- If an agent fails or times out, note the gap in the transcript and continue with the blocks you have. Never treat a missing block as `ready`.
- The ledger is the single source of truth for review state. The transcript is the audit trail. A reviewer that wants the history reads the ledger first and the transcript only for the reasoning behind a specific row.

## What changed in 0.4.0 (and why)

Measured over 89 loops in one repo: pass duration did not grow with the review file, but loops grew from a median 3 passes to 5 because exit needed every reviewer to say `ready` in the same pass, and every pass was a full re-review by fresh agents that re-explored the codebase. Blocking findings decayed 6 → 4 → 2 → 1 → 0 per pass, so the last one or two passes were confirmation passes. 0.4.0 makes exit ledger-driven (no non-terminal blocking finding), turns passes 2, 4 and 5 into scoped verifies that resume the original reviewer, caps reviewer prose to findings only, moves block writes out of the shared file, and adds a plan word budget that trims and warns rather than refuses — a long plan is usually recording decisions instead of directing work.
