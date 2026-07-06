# Agent Prompts

The Codex reviewer prompts are **assembled deterministically by
`scripts/build-prompts.sh`** from plain-text fragments in `prompts/`. Claude
does not hand-write or paraphrase these prompts — improvised assembly (dropped
discipline blocks, duplicated history, drifted read-rules) was the loop's single
most frequent failure mode. SKILL.md Phase 1 calls `build-prompts.sh`; this file
documents what it assembles.

## Fragments (`prompts/`)

Shared blocks (prefixed `_`):

| Fragment | Role in the prompt |
|---|---|
| `_packet.txt` | Review Packet Usage + read discipline + severity discipline. Contains a `{PACKET_PATH}` placeholder the script substitutes. Prepended to **every** agent. |
| `_history.txt` | "How to Use Prior Review History" preamble. Included only when a `--history` file is passed (ITERATION > 0). The actual history contents are appended verbatim after it by the script — there is no `{HISTORY_CONTENTS}` placeholder. |
| `_severity-floor.txt` | The rising-severity-floor instruction. Appended only when `--severity-floor` is passed (see SKILL.md Phase 4). |

Personas (one file per agent, the filename is the role name):
`code-reviewer.txt`, `test-analyzer.txt`, `silent-failure-hunter.txt`,
`comment-analyzer.txt`, `type-design-analyzer.txt`, `code-simplifier.txt`,
`failure-pattern-analyst.txt`.

## Assembly order

`build-prompts.sh` concatenates, per role, blocks joined by a `---` line:

1. **`_packet.txt`** — always, with `{PACKET_PATH}` substituted.
2. **`_history.txt` + history file** — only when `--history <file>` is passed.
3. **Context file** — only when `--context <file>` is passed. This is the one
   orchestrator-authored block: a short (≤6 line) note stating what the PR is,
   its place in a stack/arc, and explicit non-goals (e.g. "PR3 of 3, frontend
   only; backend already shipped in #469 — do not flag missing backend logic").
   It rides under a fixed header so the canonical blocks stay byte-exact. Claude
   MAY write `$RUN_DIR/context.txt`; everything else is fixed.
4. **`<role>.txt` persona** — always.
5. **`_severity-floor.txt`** — only when `--severity-floor` is passed.

## Changing a prompt

Edit the fragment. That is the **only** supported way to change agent behavior —
do not add prompt text in SKILL.md or in the orchestrator's bash. A fragment
edit is picked up by every future run with no other change. Bump the plugin
version on any behavioral edit (per repo CLAUDE.md).

## Roles at a glance

- **code-reviewer** (full-auto): guideline compliance, bugs, quality.
- **test-analyzer** (full-auto): behavioral coverage gaps.
- **silent-failure-hunter** (read-only): swallowed errors, masked failures.
- **type-design-analyzer** (read-only, mini): illegal-states-unrepresentable.
- **comment-analyzer** (read-only, mini): comment/doc accuracy.
- **code-simplifier** (read-only, mini): clarity-preserving simplification.
- **failure-pattern-analyst** (read-only): project-local `failure-patterns.md`
  bug classes; self-short-circuits if the file is absent.

Sandbox / model / effort per role live in `scripts/launch-agents.sh`, not here.
