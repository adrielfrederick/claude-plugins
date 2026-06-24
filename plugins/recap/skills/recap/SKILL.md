---
name: recap
description: Manual checkpoint — write a session gist capturing the current Claude Code session with full in-context fidelity. Use when the user invokes /recap explicitly to checkpoint progress mid-session or before closing out. NOTE for repos with `vault-context` installed (f1-predictions, Unfurl, vault): the scheduled `<slug>-context` MCP routine auto-writes gists for ended sessions 3×/day from the JSONL transcript — /recap is the manual override for "I want this captured *now* with full in-context fidelity," and the two produce interoperable files (same session_id, same filename schema) so they don't duplicate.
---

# /recap — Session Gist Writer (manual checkpoint)

Captures a Claude Code session as a dated markdown gist in the current repo's `docs/sessions/` folder. The goal is to eliminate the "reconstitute context next session" tax — the next session (or the user) can read the gist to understand what was done, what was decided, what was tried and failed, and what comes next.

**Interop with `vault-context`** (as of vault-context 0.5.0 / recap 0.1.0): both systems write gists to the same `docs/sessions/` with the same filename schema (`YYYY-MM-DD - <slug>.md`) and the same frontmatter keys (`session_id`, `date`, `repo`, `slug`, `shape`). `vault-context`'s `write_gists` performs slug-drift cleanup keyed by frontmatter `session_id`, so when a manually-written /recap gist and an auto-written vault-context gist share a `session_id`, they end up at the SAME on-disk path (the later writer overwrites; no orphans). **For this to work, /recap MUST include `session_id` in the frontmatter** — see step 3 below.

## When to invoke

- User types `/recap` (optionally with a slug: `/recap boost-calibration`)
- User says "save a session gist" / "checkpoint this session" / similar

## Workflow

### 1. Determine the repo (write to the MAIN working tree, not a worktree)

Find the repo root for the current cwd with `git rev-parse --show-toplevel`. If it fails (not in a git repo), tell the user and stop — `/recap` is only for tracked repos.

**Then resolve the durable base path.** If `/recap` is invoked from a linked git worktree, the gist must NOT land under the worktree — when the worktree is torn down, the gist goes with it. Always write to the MAIN working tree instead. Compute it:

```bash
git worktree list --porcelain | sed -n 's/^worktree //p' | head -1
```

`git worktree list` always lists the main working tree first, so this returns its path even when you're standing inside a linked worktree — and returns the repo root unchanged when you're *not* in a worktree, so it's safe to run unconditionally. It also handles paths with spaces (e.g. `~/Adriel Vault`). Call this path **`base`** and use it as the root for everything below: the `docs/sessions/` location AND the `repo` frontmatter basename. (Edge case: if `git worktree list` shows the main tree as `(bare)` — no working tree — fall back to `--show-toplevel` and warn the user the gist may be ephemeral.)

If `base` is `~/Adriel Vault`, that's fine — session gists for vault-level work go in `~/Adriel Vault/docs/sessions/` (create the folder if it doesn't exist; we're establishing the convention).

### 2. Ensure the sessions directory

**Resolving the path depends on which repo you're in** (always rooted at `base`, the main working tree from step 1 — never the worktree's `--show-toplevel`):

- **Code repos (e.g. `~/dev/f1-predictions`, `~/dev/unfurl`, or any `~/dev/*`):** `<base>/docs/sessions/`. Create it if missing — `docs/sessions/` is the agreed idiomatic location.
- **The vault (`~/Adriel Vault`):** The vault structure doesn't use a top-level `docs/` folder. Session gists for vault meta-work (context system, vault maintenance, note organization) go in `01-Active/07 - Context System/sessions/`. If the session was clearly about a different vault project (e.g. a deep SBA strategy session), ask the user whether they want the gist in that project's folder (`01-Active/0X - Project/sessions/`) or in the general Context System folder.
- **Other repos:** If there's no existing `docs/` convention and it's not the vault, ask the user where session gists should live.

### 3. Capture the session_id (CRITICAL for interop)

Read the current Claude Code session's id from the env var:

```bash
echo "$CLAUDE_CODE_SESSION_ID"
```

This is the same identifier `vault-context` uses to dedupe / rename gists across re-syntheses. If the env var is empty (unusual — should be set in any interactive session), proceed without it; the gist will still write but vault-context won't be able to recognize it as the same session and may produce a duplicate auto-gist later. Flag the absence in your output so the user knows.

### 4. Classify the session shape

Pick ONE of these (the vocab `vault-context` also uses; keeps the two systems' outputs compatible):

- **`research`** — investigated something, surfaced facts or alternatives.
- **`drafting`** — wrote a doc, post, PRD, training material, message.
- **`notes-processing`** — transcript cleanup, screenshot extraction, conversation summary.
- **`planning`** — architecture, design discussion, strategy session, decision-mapping.
- **`vault-hygiene`** — maintenance, reorganization, link/index repair.
- **`personal`** — family, finance, household, scheduling, personal admin.
- **`project-work`** — code, build, or implementation work in a code repo.

Pick the dominant shape. If genuinely split, pick the one closest to the session's *outcome* (what landed) rather than the opener.

### 5. Pick the filename

Format: `YYYY-MM-DD - <slug>.md` (absolute date, space-dash-space separator, matches vault naming conventions AND `vault-context`'s output).

- Slug comes from `$ARGUMENTS` if provided (e.g. `/recap boost-calibration` → slug = `boost-calibration`)
- Otherwise, synthesize a short kebab-case slug from the session's dominant theme (3–6 words, e.g. `context-system-design`, `wastegate-oscillation-debug`)
- Normalize: lowercase, alphanumerics + hyphens only, no leading/trailing hyphens, no consecutive hyphens.
- If a gist for today with the same slug already exists AND it has a DIFFERENT `session_id` in its frontmatter, append a suffix: `- part-2`, `- part-3`, etc. (Don't overwrite a different session's file.) If the existing file has the SAME `session_id`, you ARE re-recapping the same session — overwrite it.

### 6. Synthesize the gist content

You (the model) have the session in your context. Summarize it using the template below. Be ruthless about compression — this is reference material for cold reads, not a transcript.

**Hard rules:**
- **Absolute dates only.** Never "today", "yesterday", "last week". Always YYYY-MM-DD.
- **Capture dead ends explicitly.** "Tried X, didn't work because Y" is the single highest-value section — it prevents the next session from re-exploring the same failed path.
- **File paths should be full repo-relative paths**, so future greps work.
- **Be concrete about decisions + why.** "Decided X" is useless without the reasoning — and the reasoning is what gets lost between sessions.
- **"Next" should be actionable**, not aspirational. Bullet one concrete next step per item.
- **Skip sections that are genuinely empty.** If there were no dead ends, omit the section. Don't pad.

### 7. Write the file

Use the Write tool. Report the path back to the user.

If the user wants to edit before writing (infer from their tone or ask if unsure), show the draft first.

## Template

```markdown
---
session_id: <value of $CLAUDE_CODE_SESSION_ID, full id>
date: YYYY-MM-DD
repo: <basename of `base` — the main working tree from step 1, not the worktree dir>
slug: <slug>
shape: <one of: research, drafting, notes-processing, planning, vault-hygiene, personal, project-work>
---

# <One-line title — what this session was about>

**Session date**: YYYY-MM-DD
**Repo**: `<absolute or tilde path to repo root>`

## Goal

<1–2 sentences: what the user set out to do at the start of this session>

## Outcome

<1–3 bullets: what landed, what shipped, what got closed out>
- <outcome 1>
- <outcome 2>

## Decisions + why

<Each decision as a bullet with the reasoning. Why > what.>
- **<decision>** — <why this, not the alternative>

## Dead ends

<Things tried that didn't work. Each bullet: what was tried + why it failed / why abandoned.>
- <dead end 1>

## Next

<What the next session should pick up. Concrete, actionable bullets.>
- [ ] <next step 1>
- [ ] <next step 2>

## Files touched

<Full repo-relative paths, grouped by intent if helpful>
- `path/to/file.ts` — <one-line why>
- `path/to/other.md` — <one-line why>

## Open questions

<Optional. Things that came up but weren't resolved, tagged for future thought.>
- <question 1>
```

## Examples

### User: `/recap`
You: detect repo → grab `$CLAUDE_CODE_SESSION_ID` → classify shape → synthesize slug from session theme → write gist → report path.

### User: `/recap context-system-design`
You: detect repo → grab session_id → classify shape → use provided slug → write gist → report path.

### User: `/recap and push to vault`
(Later phase — not in v1. For now, ignore the "push to vault" part and just write the local gist. Tell the user vault-push is a separate routine that hasn't shipped yet.)

## What NOT to do

- Don't write the gist to the vault when you're in a code repo (wrong tier — gists are in-repo for execution detail; the vault gets summarized snapshots pushed from routines).
- **Don't write the gist inside a git worktree.** If invoked from a linked worktree, resolve the main working tree (`base`, step 1) and write there — a gist under a worktree is lost when the worktree is removed, which defeats the whole point of a checkpoint.
- Don't paste the raw transcript. This is a synthesis, not a log.
- Don't use relative dates anywhere.
- Don't skip the "Dead ends" section if there were any — that's the whole point.
- Don't invent facts. If you didn't actually try something in this session, don't list it. If uncertain about a decision's reasoning, say so rather than fabricating.
- **Don't omit `session_id` from frontmatter** unless `$CLAUDE_CODE_SESSION_ID` is genuinely empty — without it, vault-context can't tell this gist apart from a future auto-gist for the same session and will write a duplicate.
