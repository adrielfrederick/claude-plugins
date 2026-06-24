# CLAUDE.md

This repo is both a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`) and the home of the plugins it lists, under `plugins/`: `review-plan`, `pr-review-loop`, `context-setup`, and `recap`.

## Session gists live in the main working tree

Session gists (written by the `recap` plugin and the `vault-context` auto-gist pipeline) are stored in `docs/sessions/` of the **main working tree** — never inside a linked git worktree, because a worktree's copy is destroyed when the worktree is torn down.

So if you're doing development from a worktree, `./docs/sessions/` won't be the right place to look. Resolve the main working tree first and read gists from there:

```bash
git worktree list --porcelain | sed -n 's/^worktree //p' | head -1
```

`git worktree list` always lists the main working tree first, so this returns its path even from inside a linked worktree (and returns the repo root unchanged when you're not in a worktree). Then look in `<that-path>/docs/sessions/`.

## Versioning

Each plugin carries its own `version` in `plugins/<name>/.claude-plugin/plugin.json`. Bump it on any behavioral change to that plugin's skill(s).
