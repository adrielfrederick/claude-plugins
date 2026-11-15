---
name: gist
description: Manual checkpoint — write a session gist capturing the current Claude Code session with full in-context fidelity. Use when the user invokes /gist explicitly to checkpoint progress mid-session or before closing out. Not the same as Claude Code's built-in /recap, which prints a throwaway in-terminal summary; /gist writes a durable file.
---

# /gist — Session Gist Writer (manual checkpoint)

Captures a Claude Code session as a dated markdown gist in the current repo's `docs/sessions/` folder. The goal is to eliminate the "reconstitute context next session" tax — the next session (or the user) can read the gist to understand what was done, what was decided, what was tried and failed, and what comes next.

## When to invoke

- User types `/gist` (optionally with a slug: `/gist boost-calibration`)
- User says "save a session gist" / "checkpoint this session" / similar

This plugin was named `recap` until 0.3.0; it was renamed because Claude Code's built-in `/recap` (an in-terminal "while you were away" summary that writes nothing to disk) now owns that name. If the user asks for a "recap" and it's ambiguous whether they want a file written, ask.

## Workflow

### 1. Determine the repo (write to the MAIN working tree, not a worktree)

Find the repo root for the current cwd with `git rev-parse --show-toplevel`. If it fails (not in a git repo), tell the user and stop — `/gist` is only for tracked repos.

**Then resolve the durable base path.** If `/gist` is invoked from a linked git worktree, the gist must NOT land under the worktree — when the worktree is torn down, the gist goes with it. Always write to the MAIN working tree instead. Compute it:

```bash
git worktree list --porcelain | sed -n 's/^worktree //p' | head -1
```

`git worktree list` always lists the main working tree first, so this returns its path even when you're standing inside a linked worktree — and returns the repo root unchanged when you're *not* in a worktree, so it's safe to run unconditionally. It also handles paths with spaces (e.g. `~/Adriel Vault`). Call this path **`base`** and use it as the root for everything below: the `docs/sessions/` location AND the `repo` frontmatter basename. (Edge case: if `git worktree list` shows the main tree as `(bare)` — no working tree — fall back to `--show-toplevel` and warn the user the gist may be ephemeral.)

The vault is no exception: it is checked out on more than one machine (the laptop at `~/Adriel Vault`, and the vault-bot server wherever the vault is mounted there), so its gists go to `<base>/docs/sessions/` like any other repo's, with `base` being wherever the vault's root is on the machine you're running on. Never hardcode a machine-specific path.

### 2. Ensure the sessions directory

**Resolving the path depends on which repo you're in** (always rooted at `base`, the main working tree from step 1 — never the worktree's `--show-toplevel`):

- **Code repos (e.g. `~/dev/f1-predictions`, `~/dev/unfurl`, or any `~/dev/*`):** `<base>/docs/sessions/`. Create it if missing — `docs/sessions/` is the agreed idiomatic location.
- **The vault:** `<base>/docs/sessions/`, with `base` resolved on the current machine (laptop or vault-bot server). Create it if missing.
- **Other repos:** If there's no existing `docs/` convention, ask the user where session gists should live.

### 3. Capture the session_id

Read the current Claude Code session's id from the env var:

```bash
echo "$CLAUDE_CODE_SESSION_ID"
```

It goes in the frontmatter and is how step 5 tells a re-gist of this session (overwrite) apart from a different session that picked the same slug (new `part-N` file). If the env var is empty (unusual — should be set in any interactive session), proceed without it and flag the absence in your output so the user knows.

### 4. Classify the session shape

Pick ONE of these:

- **`research`** — investigated something, surfaced facts or alternatives.
- **`drafting`** — wrote a doc, post, PRD, training material, message.
- **`notes-processing`** — transcript cleanup, screenshot extraction, conversation summary.
- **`planning`** — architecture, design discussion, strategy session, decision-mapping.
- **`vault-hygiene`** — maintenance, reorganization, link/index repair.
- **`personal`** — family, finance, household, scheduling, personal admin.
- **`project-work`** — code, build, or implementation work in a code repo.

Pick the dominant shape. If genuinely split, pick the one closest to the session's *outcome* (what landed) rather than the opener.

### 5. Pick the filename

Format: `YYYY-MM-DD - <slug>.md` (absolute date, space-dash-space separator, matches vault naming conventions).

- Slug comes from `$ARGUMENTS` if provided (e.g. `/gist boost-calibration` → slug = `boost-calibration`)
- Otherwise, synthesize a short kebab-case slug from the session's dominant theme (3–6 words, e.g. `context-system-design`, `wastegate-oscillation-debug`)
- **Normalize the slug — whatever its source — before building the filename** (a `$ARGUMENTS` slug is NOT exempt): lowercase; replace every character outside `[a-z0-9-]` with a hyphen; strip leading/trailing hyphens; collapse consecutive hyphens. Dots are the common trap — a version number like `v1.2` must become `v1-2`. The finished filename should match `^\d{4}-\d{2}-\d{2} - [a-z0-9][a-z0-9-]{0,80}\.md$`.
- If a gist for today with the same slug already exists AND it has a DIFFERENT `session_id` in its frontmatter, append a suffix: `- part-2`, `- part-3`, etc. (Don't overwrite a different session's file.) If the existing file has the SAME `session_id`, you ARE re-gisting the same session — overwrite it.

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

### User: `/gist`
You: detect repo → grab `$CLAUDE_CODE_SESSION_ID` → classify shape → synthesize slug from session theme → write gist → report path.

### User: `/gist context-system-design`
You: detect repo → grab session_id → classify shape → use provided slug → write gist → report path.

## What NOT to do

- Don't write the gist to the vault when you're in a code repo (gists are in-repo execution detail and belong with the code they describe).
- **Don't write the gist inside a git worktree.** If invoked from a linked worktree, resolve the main working tree (`base`, step 1) and write there — a gist under a worktree is lost when the worktree is removed, which defeats the whole point of a checkpoint.
- Don't paste the raw transcript. This is a synthesis, not a log.
- Don't use relative dates anywhere.
- Don't skip the "Dead ends" section if there were any — that's the whole point.
- Don't invent facts. If you didn't actually try something in this session, don't list it. If uncertain about a decision's reasoning, say so rather than fabricating.
- **Don't omit `session_id` from frontmatter** unless `$CLAUDE_CODE_SESSION_ID` is genuinely empty — without it, a later `/gist` in the same session can't recognize its own earlier file and will write a `part-2` duplicate instead of overwriting.
