---
name: review-plan
description: Facilitates an automated plan review loop using parallel Claude reviewer agents, iterating on feedback until the plan is approved.
---

After a plan is created:

1. **Save the plan to the repo**: Copy the plan document to `<repo-root>/docs/plans/` with a descriptive filename (e.g., `docs/plans/auth-redesign.md`). Resolve the repo root by running `git rev-parse --show-toplevel`.

2. **Create a review conversation document**: Create a companion file at the same path with a `-review` suffix (e.g., `docs/plans/auth-redesign-review.md`). Start it with:
   - `Plan: <relative-path-to-plan>` (e.g., `Plan: docs/plans/auth-redesign.md`)
   - `Review Status: In Progress`

3. **Record the start state**: Set `PASS=0`, `MAX_PASSES=5`.

4. **Run the review loop**. Repeat from step 5 until any exit condition is met (step 9).

---

5. **Increment pass**: `PASS += 1`

6. **Choose review strategy based on pass number**:

   - **Passes 1-2 (parallel dimension review with Sonnet)**: Launch **4 reviewer agents in parallel** using the Agent tool, all in a single message. Each agent uses `model: "sonnet"`. Each agent covers one review dimension (see Agent Prompts below). Each agent's prompt includes:
     - The absolute path to the plan document
     - The absolute path to the review conversation document
     - Instructions to read both files before reviewing
     - Its dimension-specific rubric
     - The output format (see step 7)

     **Conditional 5th agent — Project Failure Patterns**: Resolve the repo root by walking up from the plan document's directory looking for a `.git` entry. If `<repo-root>/.claude/skills/extensions/failure-patterns.md` exists, launch a 5th Sonnet agent in the same parallel batch using the Dimension 5 rubric below. Pass the absolute path of the patterns file to the agent. If the file does not exist, do not launch this agent — the four standard dimension agents are sufficient.

   - **Passes 3-5 (holistic review with Opus)**: Launch **1 reviewer agent** using the Agent tool with `model: "opus"`. This agent reviews the full plan against all dimensions holistically, with full context of all prior feedback and author responses. Its prompt includes:
     - The absolute path to the plan document
     - The absolute path to the review conversation document
     - The full review rubric (all 4 dimensions combined)
     - The output format (see step 7)

7. **Reviewer agent output format**: Each reviewer agent MUST append its feedback to the **END** of the review conversation document. Never insert above existing content. The document must read chronologically top-to-bottom.

   For **parallel dimension agents** (passes 1-2), each agent appends a block like:

   ```
   <claude-reviewer>
   Pass N - {dimension name} - YYYY-MM-DD HH:MM TZ

   Verdict: ready | needs revision

   {Findings as bullet points. Each finding must be labeled:}
   - **Blocking**: issue that must be fixed
   - **Non-blocking**: suggestion or minor improvement

   </claude-reviewer>
   ```

   For the **holistic agent** (passes 3-5), the agent appends:

   ```
   <claude-reviewer>
   Pass N - Holistic Review - YYYY-MM-DD HH:MM TZ

   Verdict: ready | needs revision | stop review

   ### Scope & Completeness
   - ...

   ### Data Model & Storage Accuracy
   - ...

   ### Code Quality & Reuse
   - ...

   ### Testing & Verification
   - ...

   Next step: ...
   </claude-reviewer>
   ```

8. **Read the updated review document**: After all agents complete, re-read the review conversation document. Extract the verdict(s) from the latest pass.

   - **If all verdicts are `ready`**: Go to step 10 (wrap up).
   - **If any verdict is `stop review`**: Go to step 10 (wrap up).
   - **If any verdict is `needs revision`**: Read the feedback, assess each finding, and update the plan document accordingly. If you disagree with a finding, explain your reasoning rather than silently ignoring it. Then append your response to the **END** of the review conversation document:

     ```
     <claude-author>
     Pass N Response - YYYY-MM-DD HH:MM TZ

     ## Changes Made
     - [description of each change]

     ## Pushed Back
     - [finding]: [reasoning for disagreeing]

     </claude-author>
     ```

9. **Check exit conditions** (any triggers exit to step 10):
   - `PASS >= MAX_PASSES` (5 passes completed)
   - Latest verdict is `ready` or `stop review`
   - All findings from previous pass were pushed back with no code changes (human needed)

   Otherwise, go back to step 5.

---

10. **Wrap up**: Update the review document — change the header to `Review Status: Complete`. Notify the user that the review loop is finished and summarize the key changes made during the review.

---

## Agent Prompts

### Common preamble (included in every agent prompt)

```
You are reviewing a software development plan. Your job is to evaluate the plan against your assigned rubric and append exactly one feedback block to the review conversation document.

## Files

- Plan document: {absolute-path-to-plan}
- Review conversation: {absolute-path-to-review}

## Instructions

1. Read the plan document thoroughly.
2. Read the review conversation document to see any prior feedback passes and author responses.
3. If prior `<claude-author>` response blocks exist, consider whether the author addressed earlier feedback before raising the same points again. Do NOT re-flag resolved issues unless the fix itself introduced a new problem. Do NOT re-flag pushed-back issues unless you have a stronger counter-argument than what the author already provided.
4. Evaluate the plan against your rubric below.
5. Append exactly one feedback block to the END of the review conversation document. CRITICAL: Always append to the very end of the file. Never insert above existing content.
6. Do NOT modify the plan document. Only append to the review conversation document.
7. If no significant issues remain in your dimension, use `Verdict: ready`.

## Verdicts
- `needs revision` — blocking issues remain in your dimension.
- `ready` — no blocking issues in your dimension.
- `stop review` — (holistic reviewer only) diminishing returns make another round unhelpful.
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

A project-local file at <repo-root>/.claude/skills/extensions/failure-patterns.md
documents recurring bug classes specific to this codebase. For each pattern in
that file:

1. Read the pattern's "Triggers when" condition. Determine whether this plan
   matches. If not, move on — DO NOT report the pattern.
2. If the pattern triggers, read its "What to check" guidance and evaluate
   whether the plan addresses it. Cite file:line evidence from the codebase
   when flagging gaps.
3. Each pattern fires at most once per review pass per matching site.

If no patterns trigger on this plan, append a feedback block with verdict
`ready` and body "No project-specific failure patterns triggered." Do not
manufacture findings — most plans will not match any pattern, and that is the
expected outcome.

Severity and verdict semantics match the other reviewers in your cohort —
see the common preamble.
```

### Holistic Review (passes 3-5, Opus)

```
## Your Review: Holistic

You are performing a holistic review of the plan across ALL dimensions. You have access to all prior feedback and author responses. Your job is to catch cross-cutting issues that dimension-specific reviewers may have missed, and to verify that prior feedback was adequately addressed.

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
- Issues introduced by the author's revisions in response to prior feedback
- Inconsistencies between different parts of the plan
- Whether pushed-back items from prior rounds deserve reconsideration

Also consider any feedback from the failure-pattern-analyst when forming your holistic verdict.

Use `Verdict: stop review` if the plan is good enough and further iteration would yield diminishing returns, even if minor non-blocking suggestions remain.
```

---

## Notes

- Reviewer agents are launched via the **Agent tool** with `model: "sonnet"` (passes 1-2) or `model: "opus"` (passes 3+). No external CLI is needed.
- For passes 1-2, all 4 dimension agents MUST be launched in a single message (parallel tool calls) to minimize wall-clock time.
- Each agent invocation is independent — they don't share state beyond what's in the review document.
- If an agent fails or times out, note the gap and continue with available feedback.
- The review document is the single source of truth for the conversation. All feedback and responses are appended chronologically.
