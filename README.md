# claude-plugins

Two Claude Code plugins for automated review workflows:

- **`review-plan`** — runs a plan document through parallel Claude reviewer agents (Sonnet for dimension passes, Opus for holistic passes), iterating on feedback until the plan is approved or hits a max-pass cap. Pure Claude Code; no external dependencies.
- **`pr-review-loop`** — runs the current branch's open PR through Codex reviewer agents (`code-reviewer`, `test-analyzer`, `silent-failure-hunter`, plus secondary-tier personas), then has Claude address feedback and iterate until convergence. Requires the [Codex CLI](https://developers.openai.com/codex/cli) and [GitHub CLI](https://cli.github.com/).

Both plugins support a project-local extension at `.claude/skills/extensions/failure-patterns.md` — a list of bug patterns specific to the codebase being reviewed. When that file exists, an additional `failure-pattern-analyst` reviewer is spawned that checks the plan or diff against each pattern. See the SKILL.md files for the format.

## Install

This repo serves as both a marketplace and the home of the plugins it lists. Add it once, then install either or both plugins:

```
/plugin marketplace add adrielfrederick/claude-plugins
/plugin install review-plan
/plugin install pr-review-loop
```

Updates are pull-based:

```
/plugin marketplace update
```

## Requirements

- **`review-plan`** — Claude Code only.
- **`pr-review-loop`** — Claude Code, plus:
  - [Codex CLI](https://developers.openai.com/codex/cli) on PATH (the loop shells out to `codex exec` to run reviewer agents).
  - [GitHub CLI (`gh`)](https://cli.github.com/) on PATH (used to read the PR, post comments, push fixup commits).

  The skill performs a preflight check on first invocation and stops with an install link if either is missing.

## Usage

Once installed, invoke the slash commands directly:

- `/review-plan <path-to-plan.md>` — runs the plan through the review loop. Saves the plan to `docs/plans/` and creates a companion `<plan>-review.md` review conversation document.
- `/pr-review-loop` — runs the loop against the current branch's open PR (use `/pr-review-loop verbose` to post each round to the PR; default is a single summary at loop end). Requires an open PR on the current branch.

## License

MIT — see [LICENSE](LICENSE).
