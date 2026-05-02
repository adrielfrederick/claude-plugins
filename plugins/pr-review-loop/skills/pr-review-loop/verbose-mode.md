# Verbose Mode — PR Posting Mechanics

Read this file only when `QUIET_MODE == false` (the user invoked with `verbose`). Quiet mode is the default and does not use any of this.

## Contents
- Phase 2 Verbose: posting the Codex review to the PR
- Phase 3 Verbose: posting Claude's response
- Phase 5 Verbose: final summary

## Phase 2 Verbose — post Codex review to the PR

**CRITICAL:** Post the review to the PR BEFORE starting Phase 3. Do not begin addressing feedback until the review is visible on the PR. Human reviewers need to follow along. Sequence is always: Codex reviews → post → Claude responds.

### Step 1: Get the PR's latest commit SHA

```bash
COMMIT_SHA=$(gh pr view $PR_NUMBER --json headRefOid -q .headRefOid)
```

### Step 2: Build `$RUN_DIR/review-payload.json`

(Use the per-run scratch dir set up in SKILL.md Phase 0 — never bare `/tmp/review-payload.json`, which would collide across parallel loops.)

```json
{
  "commit_id": "<COMMIT_SHA>",
  "body": "CODEX: Review Round N Summary\n\n## Critical (X)\n- ...\n\n## Important (Y)\n- ...\n\n## Suggestions (Z)\n- ...",
  "event": "COMMENT",
  "comments": [
    {
      "path": "backend/api/routes.py",
      "line": 42,
      "side": "RIGHT",
      "body": "CODEX: [code-reviewer] **CRITICAL** — Description.\n\n**Suggested fix:**\n```python\n# suggested code\n```"
    }
  ]
}
```

Rules for the comments array:
- `path`: relative to repo root
- `line`: line number in the new version (right side)
- `side`: always `"RIGHT"`
- `body`: prefix `CODEX:`, include agent name in brackets, severity in bold
- Only include lines that are part of the diff. GitHub rejects inline comments on unchanged lines — move those to the summary body.

### Step 3: Validate comment lines against the diff

```bash
gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/files --paginate \
  -q '.[] | {path: .filename, patch: .patch}' > "$RUN_DIR/pr-files-patches.json"
```

For each comment, confirm the `line` falls within a `+` hunk of that file's patch. If not, move the issue to the summary body.

### Step 4: Post the review

```bash
gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/reviews \
  --method POST \
  --input "$RUN_DIR/review-payload.json"
```

If the API rejects (usually an invalid line reference):
1. Post the summary as a plain PR comment: `gh pr comment $PR_NUMBER --body "..."`
2. Post each inline comment individually, skipping failures:
   ```bash
   gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/comments \
     --method POST \
     -f commit_id="$COMMIT_SHA" -f path="file.py" -f line=42 \
     -f side="RIGHT" -f body="CODEX: ..."
   ```

Then report: "Posted CODEX review round {N} with X critical, Y important, Z suggestion issues."

## Phase 3 Verbose — post Claude's response

After fixes are committed and pushed, post a `CLAUDE:` summary comment. Run this in parallel with the validation suite:

```bash
gh pr comment $PR_NUMBER --body "CLAUDE: Response to Review Round {N}

## Addressed
- [file:line] Fixed: description of fix

## Pushed Back
- [file:line] Disagree: reasoning

## Validation
- Lint: PASS/FAIL
- Build: PASS/FAIL
- Tests: PASS/FAIL (X passed, Y failed)

Pushed fixup commit: {SHORT_SHA}"
```

## Phase 5 Verbose — final summary

```bash
gh pr comment $PR_NUMBER --body "CLAUDE: Review Loop Complete

## Summary
- Iterations: {N} ({M} Codex rounds + {N-M} Claude fix rounds)
- Final round: {CODEX_REVIEW_CLEAN | CODEX_REVIEW_WITH_ISSUES | CLAUDE_FIX | TIMEOUT}
- Total issues found: {X}
- Issues resolved: {Y}
- Issues pushed back: {Z}
- Duration: {minutes}m

## Status
{CLEAN | NEEDS_HUMAN_REVIEW | TIMED_OUT | MAX_ITERATIONS_REACHED}

Unresolved IMPORTANT pushbacks do not block CLEAN — see individual round comments for reasoning."
```
