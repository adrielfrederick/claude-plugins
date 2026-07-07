#!/usr/bin/env bash
#
# build-prompts.sh — deterministically assemble Codex reviewer prompts from the
# fragments in ../prompts/. Replaces the error-prone "Claude assembles the
# prompt by hand" step, which was the loop's single most frequent failure mode
# (dropped discipline blocks, duplicated history, drifted read-rules).
#
# Assembly order per role (canonical blocks are byte-exact copies of the
# fragments; nothing is paraphrased):
#   1. _packet.txt            ({PACKET_PATH} → --packet)          — always
#   2. _history.txt + history file contents                       — if --history
#   3. --context file contents (under a fixed header)             — if --context
#   4. _scoped.txt scoped-verify addendum                         — if --scoped
#   5. <role>.txt persona                                         — always
#   6. _severity-floor.txt                                        — if --severity-floor
#
# Blocks are joined by a line containing only `---`.
#
# Usage:
#   build-prompts.sh --packet <dir> --out <round-dir> --roles r1,r2,... \
#                    [--history <file>] [--severity-floor] [--context <file>]
#
# Writes <round-dir>/prompt-<role>.txt for each role. Exit non-zero on any
# missing fragment or bad argument — a half-assembled prompt must never reach
# an agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="$SCRIPT_DIR/../prompts"

PACKET=""
OUT_DIR=""
ROLES=""
HISTORY_FILE=""
CONTEXT_FILE=""
SEVERITY_FLOOR=0
SCOPED=0

die() { echo "build-prompts.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --packet)         PACKET="${2:-}"; shift 2 ;;
    --out)            OUT_DIR="${2:-}"; shift 2 ;;
    --roles)          ROLES="${2:-}"; shift 2 ;;
    --history)        HISTORY_FILE="${2:-}"; shift 2 ;;
    --context)        CONTEXT_FILE="${2:-}"; shift 2 ;;
    --severity-floor) SEVERITY_FLOOR=1; shift ;;
    --scoped)         SCOPED=1; shift ;;
    *)                die "unknown argument: $1" ;;
  esac
done

[ -n "$PACKET" ]  || die "--packet is required"
[ -n "$OUT_DIR" ] || die "--out is required"
[ -n "$ROLES" ]   || die "--roles is required"
[ -d "$PACKET" ]  || die "packet dir not found: $PACKET (a typo here would build prompts pointing at nothing)"
# Same malformed-comma rejection as launch-agents.sh --only: bash read -a drops
# a trailing empty field on some builds, so "code-reviewer," would silently
# build one prompt instead of failing.
case "$ROLES" in
  ,*|*,|*,,*) die "--roles has an empty role (leading/trailing/double comma): '$ROLES'" ;;
esac
[ -d "$PROMPTS_DIR" ] || die "prompts dir not found: $PROMPTS_DIR"
[ -f "$PROMPTS_DIR/_packet.txt" ] || die "missing fragment: _packet.txt"

if [ -n "$HISTORY_FILE" ]; then
  [ -f "$HISTORY_FILE" ] || die "history file not found: $HISTORY_FILE"
  [ -f "$PROMPTS_DIR/_history.txt" ] || die "missing fragment: _history.txt"
fi
if [ -n "$CONTEXT_FILE" ]; then
  [ -f "$CONTEXT_FILE" ] || die "context file not found: $CONTEXT_FILE"
fi
if [ "$SEVERITY_FLOOR" -eq 1 ]; then
  [ -f "$PROMPTS_DIR/_severity-floor.txt" ] || die "missing fragment: _severity-floor.txt"
fi
if [ "$SCOPED" -eq 1 ]; then
  [ -f "$PROMPTS_DIR/_scoped.txt" ] || die "missing fragment: _scoped.txt"
  # Fail closed: a scoped round tells agents to verify $PACKET/delta.patch, so a
  # missing/empty delta would produce a review of nothing that still reports
  # clean. Require the delta to exist and be non-empty before building prompts.
  [ -s "$PACKET/delta.patch" ] || die "--scoped requires a non-empty $PACKET/delta.patch (was the delta written?)"
fi

mkdir -p "$OUT_DIR"

sep() { printf '\n---\n'; }

# Pre-validate every persona fragment before writing anything, so a typo'd role
# fails the whole call instead of leaving some prompts written and some not.
IFS=',' read -r -a ROLE_ARR <<< "$ROLES"
for role in "${ROLE_ARR[@]}"; do
  [ -n "$role" ] || die "--roles contains an empty role"
  [ -f "$PROMPTS_DIR/$role.txt" ] || die "unknown role '$role' (no $role.txt fragment)"
done

for role in "${ROLE_ARR[@]}"; do
  out="$OUT_DIR/prompt-$role.txt"
  {
    # 1. Packet block, with the packet path substituted. Bash literal
    #    replacement, not sed: a packet path containing sed metacharacters
    #    (&, |, \) would otherwise corrupt the substitution.
    packet_block="$(cat "$PROMPTS_DIR/_packet.txt")"
    printf '%s\n' "${packet_block//"{PACKET_PATH}"/$PACKET}"

    # 2. History: fixed preamble, then the actual history file verbatim.
    if [ -n "$HISTORY_FILE" ]; then
      sep
      cat "$PROMPTS_DIR/_history.txt"
      printf '\n'
      cat "$HISTORY_FILE"
    fi

    # 3. Orchestrator-authored context (scope / non-goals for THIS PR).
    if [ -n "$CONTEXT_FILE" ]; then
      sep
      printf '## This PR — scope & non-goals (orchestrator note)\n\n'
      cat "$CONTEXT_FILE"
    fi

    # 4. Scoped-verify addendum — narrows the persona to just the delta.
    if [ "$SCOPED" -eq 1 ]; then
      sep
      cat "$PROMPTS_DIR/_scoped.txt"
    fi

    # 5. Persona.
    sep
    cat "$PROMPTS_DIR/$role.txt"

    # 6. Rising severity floor.
    if [ "$SEVERITY_FLOOR" -eq 1 ]; then
      sep
      cat "$PROMPTS_DIR/_severity-floor.txt"
    fi
  } > "$out"
  echo "wrote $out"
done
