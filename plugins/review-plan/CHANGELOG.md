# review-plan changelog

## 0.6.4

Prompt cleanup for current models: reviewer findings are shaped as claim, evidence and change with no word cap; dropped the generic "be direct and actionable" lines that repeated the common preamble; plain-case wording in the failure-patterns rubric. This version history moved out of SKILL.md into this file, so it no longer loads with the skill.

## 0.6.3

The launcher probes the Codex sandbox before launching. The first real pass 6 on the devbox produced a well-formed block that said Codex could read nothing: every shell command had died at sandbox setup (`bwrap: loopback: Failed RTM_NEWADDR`), a failure the pre-release smoke test could not see because a prompt that only replies never enters the sandbox. The probe runs one command through the same sandbox and skips the pass with the error and the host fix when it fails. The host fix on Ubuntu 24.04 is the system `bubblewrap` package; no sandbox bypass was added (see Notes).

## 0.6.0

A sixth pass: a single Codex `gpt-6-astra` (high effort) review that runs after the Claude loop exits for any reason, reads the converged plan plus the whole ledger, rules on any still-open blocking rows, and gets one author response with no re-verification. Passes 1–5 share one model family and one rubric set, so their misses correlate; a different model on the finished plan is cheap independent signal. It is last so it sees the converged plan, and it has no verify pass so the loop stays bounded — its fixes are reported as unverified, and a pushed-back or design-changing pass-6 row goes to the operator. The pass is optional at runtime: a missing or failing Codex CLI is a noted gap, never a failed review.

An efficacy question. Reading the rubrics side by side showed that no reviewer asked whether executing the plan would produce its intended outcome: Scope checks the work is fully specified, Testing checks the verification strategy, and the holistic pass repeated the four dimensions. A plan could pass every rubric and build the wrong thing. Two changes close that: the plan contract now requires an opening `## Objective` section with checkable success criteria, so the goal is the writer's explicit statement rather than the reviewer's inference; and the holistic rubric gains an **Outcome & Efficacy** section that traces each change to each criterion and asks what would let the plan succeed on its own terms yet miss the objective. It sits in the holistic pass, not a fifth dimension agent, because the question needs the whole plan in view. The Codex pass inherits the rubric and is told to weight that section most, which also makes pass 6 a different lens from pass 3 rather than a second run of the same one. Scope now checks only that the section exists and is checkable.

## 0.5.0

The review document moved from beside the plan into a `reviews/` subdirectory (step 2). In one repo, 93 review transcripts sat interleaved with 106 plans in a single directory: nearly half the files and half the text in the folder a reader browses to find a plan, and cited by almost nothing outside the plan itself. A re-review of a plan whose review is still at the old location moves that file into `reviews/` instead of starting a second one.

## 0.4.0

Measured over 89 loops in one repo: pass duration did not grow with the review file, but loops grew from a median 3 passes to 5 because exit needed every reviewer to say `ready` in the same pass, and every pass was a full re-review by fresh agents that re-explored the codebase. Blocking findings decayed 6 → 4 → 2 → 1 → 0 per pass, so the last one or two passes were confirmation passes. 0.4.0 makes exit ledger-driven (no non-terminal blocking finding), turns passes 2, 4 and 5 into scoped verifies that resume the original reviewer, caps reviewer prose to findings only, moves block writes out of the shared file, and adds a plan word budget that trims and warns rather than refuses — a long plan is usually recording decisions instead of directing work.
