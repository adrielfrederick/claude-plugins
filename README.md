# claude-plugins

Four Claude Code plugins:

- **`review-plan`** — runs a plan document through parallel Claude reviewer agents (Sonnet for dimension passes, Fable for holistic passes), iterating until no blocking finding is left unverified or the pass schedule is exhausted. Since 0.4.0 the review state lives in a findings ledger, later passes are scoped verifies that resume the original reviewer, and plans over 5,000 words get a trim pass plus a split warning before review. Pure Claude Code; no external dependencies.
- **`pr-review-loop`** — runs the current branch's open PR through a single parallel batch of Codex reviewer agents (core tier: `code-reviewer`, `test-analyzer`, `silent-failure-hunter`; plus judgment add-ons `comment-analyzer` / `code-simplifier` / `type-design-analyzer` when the diff warrants), then has Claude address feedback and iterate until convergence. Prompts are assembled deterministically from bundled fragments; each agent runs under a wall-clock watchdog; a converged tests/docs-only fix gets a cheap 2-agent **scoped verify** round instead of a full batch. Loop counters and every exit decision live in a state file owned by `loop-state.sh` (not in the model's context); a round whose findings are all fix-induced or coverage-only hands off to a human instead of hardening the hardening; every finding is triaged for reachability, so guards against triggers that can't occur in how the code actually runs are declined; and a PR-size gate warns at 1,500 and stops at 2,500 added reviewable lines (JSON, lockfiles, snapshots and other artifacts excluded). Pushback history is embedded in the PR itself (so loops resume across machines/containers), and an in-flight marker stops two hosts racing the same PR. Requires the [Codex CLI](https://developers.openai.com/codex/cli) and [GitHub CLI](https://cli.github.com/).
- **`context-setup`** — bootstraps the `vault-context` client in any git repo: installs the package if missing, writes `.claude/vault-context.yaml`, wires a debounced Stop hook plus an OS-appropriate scheduled task (launchd / cron / Task Scheduler), gitignores the gist cache, and runs a cold-start fetch from the context server. Cross-platform.
- **`recap`** — manual session-gist checkpoint: synthesizes the current Claude Code session into a dated markdown gist (Goal / Outcome / Decisions / Dead ends / Next / Files touched) under `docs/sessions/` in the repo's main working tree. Frontmatter (`session_id`, `shape`, filename schema) is interoperable with the `vault-context` auto-gist pipeline, so `/recap` and the scheduled jobs share state instead of producing duplicates. Pure Claude Code; no external dependencies.

The two review plugins support a project-local extension at `.claude/skills/extensions/failure-patterns.md` — a list of bug patterns specific to the codebase being reviewed. When that file exists, an additional `failure-pattern-analyst` reviewer is spawned that checks the plan or diff against each pattern. See the SKILL.md files for the format.

## Install

This repo serves as both a marketplace and the home of the plugins it lists. Add it once, then install the plugins you want:

```
/plugin marketplace add adrielfrederick/claude-plugins
/plugin install review-plan
/plugin install pr-review-loop
/plugin install context-setup
/plugin install recap
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
- **`context-setup`** — Claude Code, plus the `vault-context` package and a reachable context-API server. The skill installs the package itself on first run (editable install on a dev machine, or a wheel on a PC) and performs its own preflight checks.
- **`recap`** — Claude Code only. Writes into a git repo (it resolves the main working tree, so it's worktree-safe); no external dependencies.

## Usage

Once installed, invoke the slash commands directly:

- `/review-plan <path-to-plan.md>` — runs the plan through the review loop. Saves the plan to `docs/plans/` and creates a companion `reviews/<plan>-review.md` review conversation document beside it (since 0.5.0; earlier versions wrote it next to the plan, and a re-review moves such a legacy file into `reviews/`). Enforces a plan contract (since 0.2.0): every plan must end with `## Operator forks` (the few decisions only the human can make, presented for resolution at wrap-up — options + recommendation each) and `## Live gates` (steps touching real money / prod data / irreversible effects, each with its operator validation); reviewers flag missing sections, evidence-resolvable forks, and uncovered gates. Since 0.4.0: a `PLAN_WORD_BUDGET` of 5,000 words — over budget, the author first cuts content that records thinking rather than drives execution (decision narration, plan history, restated context), then the writer gets a strong warning with a split proposal, and the review runs regardless; the review document carries a **findings ledger** (one row per finding with a status that must reach `verified`/`conceded`/`withdrawn` for every blocking row before the loop exits); passes 2, 4 and 5 are scoped verifies that rule on open rows and check the plan delta for fix-introduced regressions, resuming the original reviewer where the harness allows; reviewers write blocks to `/tmp/review-plan/<slug>/pass-N/` and the orchestrator appends them, so the transcript is always in pass order.
- `/pr-review-loop` — runs the loop against the current branch's open PR (use `/pr-review-loop verbose` to post each round to the PR; default is a single summary at loop end). Requires an open PR on the current branch.
- `/context-setup` — run inside a git repo to wire it into the vault-context system. Prompts for the project slug, server URL, and token, then writes config + hooks + a scheduled task and does a cold-start fetch. Run again later in "update mode" to refresh the token or re-validate the schedule.
- `/recap [optional-slug]` — checkpoint the current session as a gist in `docs/sessions/`. Pass a slug to name it (`/recap boost-calibration`), or let it synthesize one from the session theme. In repos with `vault-context`, this is the manual "capture it now with full fidelity" override for the scheduled auto-gist jobs.

## License

MIT — see [LICENSE](LICENSE).
