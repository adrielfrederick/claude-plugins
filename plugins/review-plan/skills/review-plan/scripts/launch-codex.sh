#!/usr/bin/env bash
#
# launch-codex.sh — run the pass-6 Codex reviewer (gpt-6-astra, high effort)
# for review-plan, under a wall-clock watchdog.
#
# Why a script: the model pin, effort, sandbox and watchdog must be identical on
# every host. The laptop's ~/.codex/config.toml happens to default to
# gpt-6-astra/high; the devbox's config sets no model at all. Pinning here makes
# the pass deterministic everywhere, and the version floor fails fast with one
# clear line instead of a 400 mid-pass.
#
# The prompt must already exist at <pass-dir>/prompt-codex.txt (assembled by the
# orchestrator from SKILL.md's Agent Prompts). Codex writes:
#   <pass-dir>/codex.md          — its reviewer block (codex -o output)
#   <pass-dir>/log-codex.txt     — full stdout/stderr transcript
# Failure is recorded OUT-OF-BAND (review content is model-controlled, so text
# alone must not be able to spoof the classification):
#   <pass-dir>/.codex-skipped    — preflight failed (CLI missing/broken/too old)
#   <pass-dir>/.codex-crashed    — codex exited non-zero, produced no output,
#                                   or produced output that isn't a valid
#                                   <claude-reviewer> block
#   <pass-dir>/.codex-killed     — watchdog deadline hit
# Any of those means "no Codex block this pass" — the orchestrator notes the gap
# in the transcript and continues to wrap-up. Never a loop failure.
#
# Usage:
#   launch-codex.sh --pass-dir <dir> --repo <path>
#
# Exit: 0 when a block was produced; 1 otherwise (a marker file names why).
set -u

PASS_DIR=""
REPO=""
: "${CODEX_TIMEOUT_SECONDS:=1200}"

# Single source of truth for the pass-6 reviewer. Bump the plugin version when
# changing either. MIN_CODEX is the lowest CLI verified to accept gpt-6-astra
# (laptop 0.153.4, devbox 0.154.0 on 2026-09-14); older CLIs may bake the name
# in and 400 server-side, as the gpt-5.6 family did.
CODEX_MODEL="gpt-6-astra"
CODEX_EFFORT="high"
MIN_CODEX="0.153.4"

die() { echo "launch-codex.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pass-dir) PASS_DIR="${2:-}"; shift 2 ;;
    --repo)     REPO="${2:-}"; shift 2 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ -n "$PASS_DIR" ] || die "--pass-dir is required"
[ -n "$REPO" ]     || die "--repo is required"
[ -d "$PASS_DIR" ] || die "pass dir not found: $PASS_DIR"
[ -d "$REPO" ]     || die "repo not found: $REPO"
[ -f "$PASS_DIR/prompt-codex.txt" ] || die "prompt not found: $PASS_DIR/prompt-codex.txt"
case "$CODEX_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) die "CODEX_TIMEOUT_SECONDS must be a positive integer (got '$CODEX_TIMEOUT_SECONDS')" ;;
esac
[ "$CODEX_TIMEOUT_SECONDS" -gt 0 ] || die "CODEX_TIMEOUT_SECONDS must be > 0"

# codex.md too, not just the marker files — otherwise a rerun in the same
# pass dir (the documented .codex-crashed retry) that exits 0 with no new
# output would see the PRIOR attempt's block as fresh and pass validation.
rm -f "$PASS_DIR/.codex-skipped" "$PASS_DIR/.codex-crashed" "$PASS_DIR/.codex-killed" "$PASS_DIR/codex.md"

# ── Preflight: a missing, broken or too-old CLI skips the pass, never fails it.
skip() { echo "$*" > "$PASS_DIR/.codex-skipped"; echo "launch-codex.sh: skipped — $*" >&2; exit 1; }

command -v codex >/dev/null 2>&1 || skip "codex CLI not on PATH (install: https://developers.openai.com/codex/cli)"
have="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$have" ] || skip "codex is on PATH but 'codex --version' fails (broken install — reinstall the npm package)"
# have >= min  ⟺  min sorts first (or equal) under version sort.
if [ "$(printf '%s\n%s\n' "$MIN_CODEX" "$have" | sort -V | head -1)" != "$MIN_CODEX" ]; then
  skip "codex $have is older than $MIN_CODEX, the floor verified for $CODEX_MODEL (run 'codex update')"
fi

# ── Launch under a deadline-based watchdog (not `sleep N && kill`: a sleep timer
# is suspended on machine sleep and never fires; a wall-clock poll kills on the
# first tick after wake). Same rationale as pr-review-loop's launch-agents.sh.
# stdin is /dev/null so codex never blocks on "Reading additional input from stdin".
codex exec -s read-only --skip-git-repo-check -m "$CODEX_MODEL" \
  -c model_reasoning_summary=concise \
  -c model_reasoning_effort="$CODEX_EFFORT" \
  -C "$REPO" \
  -o "$PASS_DIR/codex.md" \
  "$(cat "$PASS_DIR/prompt-codex.txt")" > "$PASS_DIR/log-codex.txt" 2>&1 < /dev/null &
apid=$!

(
  deadline=$(( $(date +%s) + CODEX_TIMEOUT_SECONDS ))
  while kill -0 "$apid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      : > "$PASS_DIR/.codex-killed"
      # Snapshot children before killing the parent (they reparent on its death
      # and pgrep -P would then miss them). SIGTERM first, then a grace period,
      # then SIGKILL — a stalled codex or child that ignores SIGTERM must not be
      # able to leave `wait "$apid"` below blocked forever past the deadline.
      cpids="$(pgrep -P "$apid" 2>/dev/null || true)"
      kill -TERM "$apid" 2>/dev/null
      # shellcheck disable=SC2086  # cpids is a space-separated PID list
      [ -n "$cpids" ] && kill -TERM $cpids 2>/dev/null
      sleep 5
      kill -KILL "$apid" 2>/dev/null
      # shellcheck disable=SC2086
      [ -n "$cpids" ] && kill -KILL $cpids 2>/dev/null
      break
    fi
    sleep 5
  done
) &
wpid=$!

wait "$apid"; rc=$?
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null

if [ -f "$PASS_DIR/.codex-killed" ]; then
  echo "launch-codex.sh: watchdog killed codex after ${CODEX_TIMEOUT_SECONDS}s" >&2
  exit 1
fi
if [ "$rc" -ne 0 ] || [ ! -s "$PASS_DIR/codex.md" ]; then
  : > "$PASS_DIR/.codex-crashed"
  echo "launch-codex.sh: codex exited $rc without a block — see $PASS_DIR/log-codex.txt" >&2
  exit 1
fi

# A non-empty codex.md is not necessarily a valid block: Codex could exit 0
# after a refusal, a preamble, or malformed output with no findings section.
# The orchestrator parses `### Findings`/`### Rulings` lines directly out of
# this file (SKILL.md's reviewer-block contract), so require the envelope
# before trusting it, not just non-emptiness.
if ! grep -q "^<claude-reviewer>" "$PASS_DIR/codex.md" \
   || ! grep -q "^</claude-reviewer>" "$PASS_DIR/codex.md" \
   || ! grep -q "^### Findings" "$PASS_DIR/codex.md"; then
  : > "$PASS_DIR/.codex-crashed"
  echo "launch-codex.sh: codex.md is not a valid reviewer block (missing <claude-reviewer> envelope or ### Findings) — see $PASS_DIR/codex.md" >&2
  exit 1
fi

# Canary: confirm the pins took (a config.toml or CLI drift can silently override them).
if ! grep -q "^model: $CODEX_MODEL" "$PASS_DIR/log-codex.txt" \
   || ! grep -q "^reasoning effort: $CODEX_EFFORT" "$PASS_DIR/log-codex.txt"; then
  echo "launch-codex.sh: WARNING — session header does not show model=$CODEX_MODEL effort=$CODEX_EFFORT; check $PASS_DIR/log-codex.txt" >&2
fi
echo "launch-codex.sh: block written to $PASS_DIR/codex.md"
exit 0
