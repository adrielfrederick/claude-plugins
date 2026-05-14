---
name: context-setup
description: Bootstrap the vault-context client in the current repo — install package if missing, create config, wire a Stop hook + an MCP scheduled routine, gitignore + cold-start fetch. User-invoked via /context-setup.
---

# /context-setup

You are bootstrapping the **vault-context** client in the user's current git repo.
The client posts session gists to the vault-bot server and pulls state-block
synthesis. The full design lives in
`/Users/adriel/Adriel Vault/01-Active/07 - Context System/Unified Morning Workflow Plan 2026-05-13.md`.

## Pre-flight

1. **`pwd`** — confirm the current directory.
2. **Check it's a git repo:** `git rev-parse --show-toplevel`. If not, refuse:
   "vault-context requires a git repo; run `git init` first."
3. **Detect OS:** uname → darwin / linux / windows. Used only for
   session-source path detection in Step 2 — the scheduled routine itself is
   OS-independent (it's an MCP task, not a launchd/cron/schtasks entry).
4. **Confirm `vault-context` is installed:**
   `python3 -c "import vault_context; print(vault_context.__version__)"`. If
   the import fails, install:
   - **Laptop (macOS) / Linux dev machine** (vault-bot repo checked out):
     `pip install -e ~/dev/vault-bot/vault-context`.
   - **Any other machine** (PC, fresh laptop — no vault-bot checkout): install
     straight from the server, which hosts the built wheel. No file copying:
     ```
     curl -L -o vault_context.whl <server-url>/api/context/client-wheel
     pip install vault_context.whl
     ```
     PowerShell alternative to `curl`:
     `Invoke-WebRequest <server-url>/api/context/client-wheel -OutFile vault_context.whl`.
     The `<server-url>` is the same base URL you'll enter in Step 1; the
     `/api/context/client-wheel` endpoint is unauthenticated, so this works
     before the bearer token is configured.

## Step 1 — Slug + server config

Ask the user:

```
Project slug for this repo? (suggested from dirname: <basename>)
```

Validate against the allowlist `^[a-z0-9][a-z0-9-]{0,63}$`. Re-prompt if invalid.

Ask:

```
Server URL? (default: https://<production-base-url>)
```

Ask:

```
Bearer token? (will be stored via `keyring` if available, else CONTEXT_API_TOKEN env var.
Generate fresh: `openssl rand -hex 32`)
```

Persist the token:

```bash
python3 -c "from vault_context.secrets import set_token_in_keyring; set_token_in_keyring('<token>')"
```

If `keyring` raises on import (headless Linux), echo a one-liner the user
should add to their shell rc:

```bash
export CONTEXT_API_TOKEN='<token>'
```

## Step 2 — Cache + session source

`docs/sessions/` is the default cache directory inside the repo. If
`docs/` does NOT exist, ask the user where the cache should live; default
to `.vault-context/sessions/` if they decline `docs/`.

For session-source detection (writes-the-gist branch):

- macOS / Linux: `~/.claude/projects/-<encoded-repo-path>/` is the JSONL
  source. Verify it exists with `ls`. If absent, run the helper:
  `python3 -c "from pathlib import Path; print(Path.home() / '.claude' / 'projects' / '-' + str(Path.cwd()).replace('/', '-'))"`.
- Windows: `%LOCALAPPDATA%\AnthropicClaude\claude\projects\-<encoded>`.

Some repos won't have session JSONLs (e.g. shared/CI-only). For those, leave
`session_jsonl_dir` unset; the daily-state fetch will still work.

## Step 3 — Write `.claude/vault-context.yaml`

```yaml
project_slug: <slug>
server_url: <url>
cache_dir: docs/sessions
session_jsonl_dir: <abs path>
debounce_seconds: 1800
lookback_hours: 48
```

Path: `<repo-root>/.claude/vault-context.yaml`.

## Step 4 — Gitignore

Append (if not already present) to `<repo-root>/.gitignore`:

```
.claude/vault-context.yaml
.claude/.vault-context-debounce
.claude/.vault-context-state-marker
docs/sessions/
```

If any of these files already exist tracked, run
`git rm --cached -r <path>` first so the gitignore takes effect.

## Step 5 — Stop hook

Append to `<repo-root>/.claude/settings.json` (create if missing):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "vault-context write-gist --config ${CLAUDE_PROJECT_DIR}/.claude/vault-context.yaml" }
        ]
      }
    ]
  }
}
```

The Stop hook respects `DEBOUNCE_SECONDS` (config default 1800).

## Step 6 — Scheduled routine (MCP)

Create an MCP scheduled task (the `scheduled-tasks` server) that runs
`vault-context refresh` 3× / day. This replaces the old per-OS
launchd / cron / schtasks path: MCP routines run anywhere Claude Code runs,
and they're observable + debuggable via `list_scheduled_tasks` (last run,
next run, enabled state).

Call `create_scheduled_task` with:

- **taskId:** `<slug>-context` (e.g. `f1-predictions-context`)
- **description:** `vault-context refresh for <slug> — session gists + once/day state refresh`
- **cronExpression:** `0 11,17,22 * * *` — the `scheduled-tasks` server
  evaluates cron in the user's **local** timezone, so this is 11:00 / 17:00 /
  22:00 PT directly; no UTC conversion.
- **prompt:** keep it THIN. All real logic lives in the versioned
  `vault-context` package — the (unversioned) task SKILL.md is just a shim:

  ```
  Run this command via the Bash tool, then report its stdout, stderr, and
  exit code:

  vault-context refresh --config <ABSOLUTE-path-to-.claude/vault-context.yaml>

  This is the scheduled context-sync routine for <slug>: it writes session
  gists for ended Claude Code sessions and, at most once per local day,
  refreshes the project's state.md. Do nothing else. A nonzero exit code
  means some POSTs failed — surface it plainly; the routine self-heals on
  the next fire.
  ```

`create_scheduled_task` shows the user an approval prompt — that is the
confirmation step; go ahead and call it.

**`vault-context` must be on PATH for the MCP task's Bash environment.** If
`which vault-context` from a plain shell doesn't resolve, use the absolute
path (e.g. `~/.local/bin/vault-context`) in the prompt instead.

## Step 7 — Cold-start fetch

Pull existing gists from the server so the local cache mirrors canonical:

```
vault-context fetch --config <repo>/.claude/vault-context.yaml
```

## Step 8 — Migrate existing gists (if any)

If the repo already had `docs/sessions/*.md` (e.g. f1-predictions):

```
vault-context migrate --config <abs path> --dry-run
```

Show the plan. Confirm. Then run without `--dry-run`. Files unchanged in
their content; only frontmatter mutates to add `synced_at`.

## Step 9 — Dry-run daily-state (only for repos with session source)

```
vault-context daily-state --config <abs path>
```

Show the proposed state block (server prints what was POSTed). Ask
"looks reasonable?" before confirming. If the user says no, undo by deleting
`<vault>/Project Summaries/<slug>/state.md`.

## Step 10 — Install summary

Print:

```
✅ vault-context installed for <slug>
   Config:   <repo>/.claude/vault-context.yaml
   Cache:    <repo>/docs/sessions (gitignored)
   Server:   <url>
   Hooks:    Stop hook → write-gist (debounced 30min)
   Routine:  MCP task <slug>-context → vault-context refresh, 11/17/22 PT
   Next:     refresh runs at the next scheduled tick (write-gist every fire,
             daily-state once per local day)
```

## Guardrails

- **Never commit the token** — keyring or env-var only.
- **Never overwrite an existing `.claude/settings.json`** — read, splice, write.
- **Never run destructive `git` ops** without confirmation; `git rm --cached`
  is the only one this skill should ever need.
- **If the user already ran context-setup once on this repo** (config exists),
  default to "update mode": offer to refresh the token, re-validate the
  schedule, or re-run the cold-start fetch. Don't blow away the existing
  config.
- **If the server URL is unreachable** (curl health probe fails), warn but
  don't refuse — the user may be offline and want to set up first.
