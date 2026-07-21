# Plan: mark-ready must verify CI actually ran

**Status:** scoped
**Source:** reduction [#18](https://github.com/adrielfrederick/reduction/pull/18), 2026-07-21 — a CLEAN loop left the PR ready, mergeable, and with every CI job SKIPPED.
**Current plugin version:** 0.9.1 (a behavioral skill change here needs a bump, per repo `CLAUDE.md`)

## The problem

On a CLEAN exit, SKILL.md → *"Mark ready for review (CLEAN exits only)"* does:

```bash
if [ "$(gh pr view "$PR_NUMBER" --json isDraft -q .isDraft)" = "true" ]; then
  gh pr ready "$PR_NUMBER"
fi
```

The documented intent is that `ready_for_review` fires the repo's deferred
end-of-cycle CI run. But this fires an **event** and assumes CI follows. It
doesn't verify, and there is no path that notices when CI didn't run.

Repos using the draft-first pattern guard every job with
`if: github.event.pull_request.draft == false`, so a run evaluated while the PR
is still a draft skips all jobs. When a second `pull_request` event lands on the
same head within a few seconds — most obviously the PR author pushing while the
loop wraps up — the workflow's `cancel-in-progress` concurrency group collapses
the two, and the run that survives is the one evaluated as a draft. Every job
skips, nothing re-runs, and the PR sits ready and mergeable with an all-SKIPPED
check list that reads as green at a glance.

## Evidence

reduction#18, times UTC, from the Actions API and the PR timeline:

| Time | Event |
|---|---|
| 16:31:14 | author pushes head `40fdc83` (PR still a draft) |
| 16:31:16 | loop marks ready — 2s later, before the run even exists |
| 16:31:20 | one CI run created for `40fdc83` → **all four jobs skipped** |
| — | no further `pull_request` run; PR ready + mergeable, all checks SKIPPED |
| 16:35:14/19 | manual draft toggle → run created → green |

The window is small but it is not exotic: an author pushing a last commit while
a clean loop finishes is ordinary, and the loop's own final fixup push lands in
exactly the same window.

## Why it matters

The draft-first pattern exists so the loop's fixup pushes don't burn Actions
minutes, deferring to a single run at the end. When *that* run is the one lost,
the PR's only CI signal is missing — and "no failures" becomes
indistinguishable from "never ran". Any merge gate reading the check list waves
it through. This is a quiet path to merging unverified code, which inverts what
the loop is for.

## The change

In the mark-ready step, verify instead of assume:

1. After `gh pr ready`, poll briefly for a CI run on the **current head SHA**
   whose conclusion is something other than `skipped` (or absent).
2. If none appears inside a short window, force a PR-attached run by toggling
   draft state — `gh pr ready --undo && gh pr ready` — which re-fires
   `ready_for_review` with no competing event in flight.
3. Report the outcome in the wrap-up's **Validation** section, so CI status is
   stated rather than inferred. Today that section can say nothing about CI at
   all, which is how this went unnoticed on #18.

### Constraint: the forced re-run must be the draft toggle, not `workflow_dispatch`

`gh workflow run` executes the jobs but its result does **not** attach to the
PR's check rollup. Verified on the same PR: a dispatched run went green at
16:33 while the PR's own checks still showed all-SKIPPED. It satisfies a human
reading the Actions tab, not a branch protection rule. Write this into the step
so a future simplification doesn't "helpfully" swap it in.

### Keep intact

- **Never force a run on a non-CLEAN exit.** The existing rule — an unconverged
  PR stays a draft and out of CI — is load-bearing and must not be weakened;
  the verification path runs only inside the CLEAN branch.
- The toggle emits `converted_to_draft`. Confirm nothing else (other workflows,
  branch protection automation) keys on that event before shipping.
- Repos that don't use draft-first never enter this path: the PR isn't a draft,
  `gh pr ready` is already a no-op, and step 1 finds a real run immediately.

## Validation

- A repo with the draft-skip guard: push a commit and let the loop mark ready
  within the same few seconds; confirm the loop notices the skipped run and
  forces a real one.
- Confirm the PR's own `statusCheckRollup` (not just the Actions tab) ends with
  non-skipped conclusions.
- Confirm a non-CLEAN exit still leaves the PR a draft with no forced run.

## Notes

Originally drafted in `vault-bot/docs/ROADMAP.md` because `pr-runner/` hosts the
runner service and PR-review-loop operational findings had been landing there
(`ci(pr-runner):` / `ci(pr-review-loop):` commits). Moved here on Adriel's call:
the code being changed is this repo's skill, not the runner container. The
runner needs no change for this.
