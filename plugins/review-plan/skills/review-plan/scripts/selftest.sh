#!/usr/bin/env bash
#
# selftest.sh — runnable coverage for launch-codex.sh (pass 6's Codex
# launcher). This script has no other CI; a regression here silently
# reintroduces the failures it exists to prevent (a dropped model/effort pin,
# an unbounded stall past CODEX_TIMEOUT_SECONDS, a crash or empty output read
# as a successful block, a sandbox that cannot start read as a review). Uses a fake `codex` on PATH so nothing hits the
# network.
#
# Run: bash scripts/selftest.sh   (exit 0 = all pass)
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH="$DIR/launch-codex.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
REPO="$WORK/repo"; mkdir -p "$REPO"

mkpass() { local d="$1"; mkdir -p "$d"; echo "prompt body" > "$d/prompt-codex.txt"; }

echo "== argument / precondition validation =="
check "missing --pass-dir dies"   '! bash "$LAUNCH" --repo "$REPO" 2>/dev/null'
check "missing --repo dies"       '! bash "$LAUNCH" --pass-dir "$WORK/p1" 2>/dev/null'
check "nonexistent pass-dir dies" '! bash "$LAUNCH" --pass-dir "$WORK/no-such-dir" --repo "$REPO" 2>/dev/null'
check "nonexistent repo dies"     '! bash "$LAUNCH" --pass-dir "$WORK/p1" --repo "$WORK/no-such-repo" 2>/dev/null'
P1="$WORK/p-noprompt"; mkdir -p "$P1"
check "missing prompt file dies"  '! bash "$LAUNCH" --pass-dir "$P1" --repo "$REPO" 2>/dev/null'
check "unknown argument dies"     '! bash "$LAUNCH" --pass-dir "$P1" --repo "$REPO" --bogus x 2>/dev/null'

P2="$WORK/p-badtimeout"; mkpass "$P2"
check "non-numeric timeout dies"  '! CODEX_TIMEOUT_SECONDS=abc bash "$LAUNCH" --pass-dir "$P2" --repo "$REPO" 2>/dev/null'
check "zero timeout dies"         '! CODEX_TIMEOUT_SECONDS=0 bash "$LAUNCH" --pass-dir "$P2" --repo "$REPO" 2>/dev/null'
check "negative timeout dies"     '! CODEX_TIMEOUT_SECONDS=-5 bash "$LAUNCH" --pass-dir "$P2" --repo "$REPO" 2>/dev/null'

echo "== preflight: codex CLI absent =="
PA="$WORK/p-absent"; mkpass "$PA"
# Build a PATH dir of symlinks to every real executable EXCEPT codex, rather
# than stripping a directory from PATH: on hosts (e.g. this container) where
# codex is baked into the same system dir as bash/grep/coreutils, removing
# that whole dir would break the launcher script itself, not just hide codex.
NOCODEX_BIN="$WORK/nocodex-bin"; mkdir -p "$NOCODEX_BIN"
for d in $(printf '%s' "$PATH" | tr ':' '\n'); do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "codex" ] && continue
    [ -e "$NOCODEX_BIN/$name" ] && continue
    ln -s "$f" "$NOCODEX_BIN/$name" 2>/dev/null
  done
done
err="$(PATH="$NOCODEX_BIN" bash "$LAUNCH" --pass-dir "$PA" --repo "$REPO" 2>&1)"; rc=$?
check "absent CLI exits non-zero"      '[ "'"$rc"'" -ne 0 ]'
check "absent CLI writes .codex-skipped" '[ -f "$PA/.codex-skipped" ]'
check "absent CLI names install link"  'grep -q "developers.openai.com/codex/cli" "$PA/.codex-skipped"'
check "no crashed/killed markers"      '[ ! -f "$PA/.codex-crashed" ] && [ ! -f "$PA/.codex-killed" ]'

echo "== preflight: codex CLI broken (--version fails) =="
PB="$WORK/p-broken"; mkpass "$PB"
cat > "$BIN/codex" <<'BROKEN'
#!/usr/bin/env bash
exit 1
BROKEN
chmod +x "$BIN/codex"
PATH="$BIN:$PATH" bash "$LAUNCH" --pass-dir "$PB" --repo "$REPO" >/dev/null 2>&1
check "broken CLI writes .codex-skipped" '[ -f "$PB/.codex-skipped" ]'
check "broken CLI names reinstall"       'grep -q "broken install" "$PB/.codex-skipped"'

echo "== preflight: codex CLI too old =="
PO="$WORK/p-old"; mkpass "$PO"
cat > "$BIN/codex" <<'OLD'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.140.0"; exit 0; }
OLD
chmod +x "$BIN/codex"
PATH="$BIN:$PATH" bash "$LAUNCH" --pass-dir "$PO" --repo "$REPO" >/dev/null 2>&1
check "old CLI writes .codex-skipped"    '[ -f "$PO/.codex-skipped" ]'
check "old CLI names the version floor"  'grep -q "0.153.4" "$PO/.codex-skipped"'
check "old CLI runs no codex exec"       '[ ! -f "$PO/codex.md" ]'

echo "== preflight: codex sandbox cannot start =="
PSB="$WORK/p-sandbox"; mkpass "$PSB"
cat > "$BIN/codex" <<'NOSANDBOX'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.153.4"; exit 0; }
[ "$1" = "sandbox" ] && { echo "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted" >&2; exit 1; }
# Reaching exec here is the regression: the launcher must not spend a pass on a
# host whose sandbox cannot run a single command.
echo "EXEC REACHED" > "$PSB_DIR/exec-reached"
exit 0
NOSANDBOX
chmod +x "$BIN/codex"
PATH="$BIN:$PATH" PSB_DIR="$PSB" bash "$LAUNCH" --pass-dir "$PSB" --repo "$REPO" >/dev/null 2>&1
rc=$?
check "sandbox probe fails: exits non-zero"       '[ "'"$rc"'" -ne 0 ]'
check "sandbox probe fails: writes .codex-skipped" '[ -f "$PSB/.codex-skipped" ]'
check "sandbox probe fails: names the bwrap error" 'grep -q "RTM_NEWADDR" "$PSB/.codex-skipped"'
check "sandbox probe fails: names the host fix"    'grep -q "bubblewrap" "$PSB/.codex-skipped"'
check "sandbox probe fails: runs no codex exec"    '[ ! -f "$PSB/exec-reached" ] && [ ! -f "$PSB/codex.md" ]'
check "sandbox probe fails: not crashed/killed"    '[ ! -f "$PSB/.codex-crashed" ] && [ ! -f "$PSB/.codex-killed" ]'

echo "== success: pinned model/effort/sandbox args, valid block written =="
export SANDBOX_TRACE="$WORK/trace.txt"
export PROMPT_CAPTURE="$WORK/received-prompt.txt"
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.153.4"; exit 0; }
[ "$1" = "sandbox" ] && exit 0
printf '%s\n' "$*" >> "$SANDBOX_TRACE"
echo "model: gpt-6-astra"
echo "reasoning effort: high"
a=("$@")
out=""; for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "-o" ] && out="${a[$((i+1))]}"; done
# Capture the exact final positional arg (the prompt text) — not a
# space-joined "$*" — so a regression that passes the prompt's filename
# instead of its content, or mangles it across the $(cat ...) boundary, is
# caught even when the value contains embedded whitespace/metacharacters.
printf '%s' "${a[$((${#a[@]}-1))]}" > "$PROMPT_CAPTURE"
{
  echo "<claude-reviewer>"
  echo "Pass 6 - Codex Review - 2026-09-14 00:00 UTC"
  echo
  echo "Verdict: ready"
  echo
  echo "### Findings"
  echo "No findings."
  echo "</claude-reviewer>"
} > "$out"
FAKE
chmod +x "$BIN/codex"
PS="$WORK/p-success"; mkpass "$PS"
# Distinctive multiline prompt with whitespace and shell metacharacters.
printf 'Review this plan.\n  indented line with a $VAR and "quotes" and `backticks`\nlast line\n' > "$PS/prompt-codex.txt"
: > "$SANDBOX_TRACE"
PATH="$BIN:$PATH" bash "$LAUNCH" --pass-dir "$PS" --repo "$REPO" >/dev/null 2>&1
rc=$?
check "success exits 0"                 '[ "$rc" -eq 0 ]'
check "success writes codex.md"         '[ -s "$PS/codex.md" ]'
check "success writes log-codex.txt"    '[ -s "$PS/log-codex.txt" ]'
check "no marker files on success"      '[ ! -f "$PS/.codex-skipped" ] && [ ! -f "$PS/.codex-crashed" ] && [ ! -f "$PS/.codex-killed" ]'
check "pinned model gpt-6-astra passed" 'grep -q -- "-m gpt-6-astra" "$SANDBOX_TRACE"'
check "pinned effort high passed"       'grep -q -- "model_reasoning_effort=high" "$SANDBOX_TRACE"'
check "read-only sandbox passed"        'grep -q -- "-s read-only" "$SANDBOX_TRACE"'
check "repo passed via -C"              'grep -qF -- "-C $REPO" "$SANDBOX_TRACE"'
# Both sides go through the same $(cat ...) command substitution (which
# strips trailing newlines), matching exactly what the launcher itself does.
check "exact prompt content passed"     '[ "$(cat "$PROMPT_CAPTURE")" = "$(cat "$PS/prompt-codex.txt")" ]'

echo "== stale codex.md from a prior attempt is cleared before relaunch =="
PST="$WORK/p-stale"; mkpass "$PST"
printf '<claude-reviewer>\nstale content from a prior crashed attempt\n### Findings\nNo findings.\n</claude-reviewer>\n' > "$PST/codex.md"
: > "$SANDBOX_TRACE"
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.153.4"; exit 0; }
[ "$1" = "sandbox" ] && exit 0
exit 0
FAKE
chmod +x "$BIN/codex"
PATH="$BIN:$PATH" bash "$LAUNCH" --pass-dir "$PST" --repo "$REPO" >/dev/null 2>&1
rc=$?
check "stale codex.md: exits non-zero, not silently reused" '[ "$rc" -ne 0 ]'
check "stale codex.md: cleared, not left in place"          '[ ! -s "$PST/codex.md" ]'
check "stale codex.md: classified as crashed"                '[ -f "$PST/.codex-crashed" ]'

echo "== malformed block is classified as crashed, not accepted =="
PM="$WORK/p-malformed"
write_and_run() {
  local body="$1"
  rm -rf "$PM"; mkpass "$PM"
  cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "--version" ] && { echo "codex-cli 0.153.4"; exit 0; }
[ "\$1" = "sandbox" ] && exit 0
out=""; a=("\$@"); for ((i=0;i<\${#a[@]};i++)); do [ "\${a[\$i]}" = "-o" ] && out="\${a[\$((i+1))]}"; done
printf '%s' "$body" > "\$out"
FAKE
  chmod +x "$BIN/codex"
  PATH="$BIN:$PATH" bash "$LAUNCH" --pass-dir "$PM" --repo "$REPO" >/dev/null 2>&1
}
write_and_run 'Sorry, I cannot review this plan.'
rc=$?
check "no envelope at all: fails"        '[ "'"$rc"'" -ne 0 ]'
check "no envelope at all: crashed marker" '[ -f "$PM/.codex-crashed" ]'

write_and_run "$(printf '<claude-reviewer>\nVerdict: ready\n### Findings\nNo findings.')"
rc=$?
check "missing closing tag: fails"       '[ "'"$rc"'" -ne 0 ]'
check "missing closing tag: crashed marker" '[ -f "$PM/.codex-crashed" ]'

write_and_run "$(printf '<claude-reviewer>\nVerdict: ready\n</claude-reviewer>')"
rc=$?
check "missing Findings section: fails"  '[ "'"$rc"'" -ne 0 ]'
check "missing Findings section: crashed marker" '[ -f "$PM/.codex-crashed" ]'

echo "== crash: codex exits non-zero =="
PC="$WORK/p-crash"; mkpass "$PC"
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.153.4"; exit 0; }
[ "$1" = "sandbox" ] && exit 0
exit 1
FAKE
chmod +x "$BIN/codex"
PATH="$BIN:$PATH" bash "$LAUNCH" --pass-dir "$PC" --repo "$REPO" >/dev/null 2>&1
rc=$?
check "crash exits non-zero"        '[ "$rc" -ne 0 ]'
check "crash writes .codex-crashed" '[ -f "$PC/.codex-crashed" ]'
check "crash writes no block"       '[ ! -s "$PC/codex.md" ]'

echo "== crash: exit-0 with empty output =="
PE="$WORK/p-empty"; mkpass "$PE"
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.153.4"; exit 0; }
[ "$1" = "sandbox" ] && exit 0
exit 0
FAKE
chmod +x "$BIN/codex"
PATH="$BIN:$PATH" bash "$LAUNCH" --pass-dir "$PE" --repo "$REPO" >/dev/null 2>&1
rc=$?
check "empty-output exits non-zero"        '[ "$rc" -ne 0 ]'
check "empty-output writes .codex-crashed" '[ -f "$PE/.codex-crashed" ]'

echo "== watchdog: codex stalls past the deadline =="
PW="$WORK/p-watchdog"; mkpass "$PW"
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.153.4"; exit 0; }
[ "$1" = "sandbox" ] && exit 0
trap '' TERM
sleep 120
FAKE
chmod +x "$BIN/codex"
start=$(date +%s)
PATH="$BIN:$PATH" CODEX_TIMEOUT_SECONDS=1 bash "$LAUNCH" --pass-dir "$PW" --repo "$REPO" >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
check "watchdog exits non-zero"        '[ "$rc" -ne 0 ]'
check "watchdog writes .codex-killed"  '[ -f "$PW/.codex-killed" ]'
check "watchdog writes no block"       '[ ! -s "$PW/codex.md" ]'
# The fake ignores SIGTERM, so the launcher must escalate to SIGKILL after the
# grace period rather than blocking forever in `wait` — this is the exact fix
# for the IMPORTANT finding (SIGTERM-only left the loop hung on a stalled
# process that ignored it). Bounded well under the fake's 120s sleep.
check "watchdog escalates to SIGKILL (bounded wall time)" '[ "$elapsed" -lt 30 ]'

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
