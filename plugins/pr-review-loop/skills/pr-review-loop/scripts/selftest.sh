#!/usr/bin/env bash
#
# selftest.sh — runnable coverage for the deterministic-assembly + launch
# machinery. These scripts have no other CI; a regression here silently
# reintroduces the exact failures the machinery exists to prevent (prompt
# drift, a dropped core agent, an unkilled stall, a crashed agent read as
# "no findings"). Uses a fake `codex` on PATH so nothing hits the network.
#
# Run: bash scripts/selftest.sh   (exit 0 = all pass)
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$DIR/build-prompts.sh"
LAUNCH="$DIR/launch-agents.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PACKET="$WORK/packet"; mkdir -p "$PACKET/files"
printf 'hist body\n' > "$WORK/history.md"
printf 'ctx body\n'  > "$WORK/context.txt"

echo "== build-prompts.sh =="
R="$WORK/r-first"; mkdir -p "$R"
bash "$BUILD" --packet "$PACKET" --out "$R" --roles code-reviewer,test-analyzer >/dev/null
check "first round writes both prompts" '[ -f "$R/prompt-code-reviewer.txt" ] && [ -f "$R/prompt-test-analyzer.txt" ]'
check "packet path substituted"          'grep -q "$PACKET/" "$R/prompt-code-reviewer.txt"'
check "no unsubstituted placeholder"      '! grep -q "{PACKET_PATH}" "$R/prompt-code-reviewer.txt"'
check "no history block on first round"   '! grep -q "How to Use Prior Review History" "$R/prompt-code-reviewer.txt"'

R2="$WORK/r-full"; mkdir -p "$R2"
bash "$BUILD" --packet "$PACKET" --out "$R2" --roles code-reviewer \
  --history "$WORK/history.md" --context "$WORK/context.txt" --severity-floor >/dev/null
check "history block present once"        '[ "$(grep -c "How to Use Prior Review History" "$R2/prompt-code-reviewer.txt")" -eq 1 ]'
check "history body included"             'grep -q "hist body" "$R2/prompt-code-reviewer.txt"'
check "context body included"             'grep -q "ctx body" "$R2/prompt-code-reviewer.txt"'
check "severity floor appended"           'grep -q "SEVERITY FLOOR RAISED" "$R2/prompt-code-reviewer.txt"'
# block order: packet(1) < history(2) < context(3) < persona(4) < floor(5)
order_ok() {
  local f="$R2/prompt-code-reviewer.txt"
  local p h c s
  p=$(grep -n "Everything you need is in" "$f" | head -1 | cut -d: -f1)
  h=$(grep -n "How to Use Prior Review History" "$f" | head -1 | cut -d: -f1)
  c=$(grep -n "orchestrator note" "$f" | head -1 | cut -d: -f1)
  s=$(grep -n "SEVERITY FLOOR RAISED" "$f" | head -1 | cut -d: -f1)
  [ "$p" -lt "$h" ] && [ "$h" -lt "$c" ] && [ "$c" -lt "$s" ]
}
check "blocks in canonical order"         'order_ok'
check "unknown role fails non-zero"       '! bash "$BUILD" --packet "$PACKET" --out "$R2" --roles nope 2>/dev/null'

echo "== launch-agents.sh (fake codex) =="
BIN="$WORK/bin"; mkdir -p "$BIN"
# fake codex: writes "No issues found." to the -o path, exits 0
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
out=""; a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "-o" ] && out="${a[$((i+1))]}"; done
[ -n "$out" ] && echo "No issues found." > "$out"
FAKE
chmod +x "$BIN/codex"

mkprompts() { local d="$1"; shift; for r in "$@"; do echo "p" > "$d/prompt-$r.txt"; done; }
ALL=(code-reviewer test-analyzer silent-failure-hunter type-design-analyzer failure-pattern-analyst comment-analyzer code-simplifier)

# default batch minus fpa, plus one add-on
RD="$WORK/run-sel"; mkdir -p "$RD"; mkprompts "$RD" "${ALL[@]}"
PATH="$BIN:$PATH" AGENT_TIMEOUT_SECONDS=30 bash "$LAUNCH" --run-dir "$RD" --repo "$WORK" \
  --sfh-effort high --skip failure-pattern-analyst --add comment-analyzer >/dev/null 2>&1
for r in code-reviewer test-analyzer silent-failure-hunter type-design-analyzer comment-analyzer; do
  check "launched $r"                     '[ -f "$RD/review-'"$r"'.txt" ]'
done
check "fpa skipped"                       '[ ! -f "$RD/review-failure-pattern-analyst.txt" ]'
check "code-simplifier not auto-added"    '[ ! -f "$RD/review-code-simplifier.txt" ]'
check ".done written on success"          '[ -f "$RD/.done" ]'
check "no .failed on success"             '[ ! -f "$RD/.failed" ]'

# refuse to skip a core agent
RDx="$WORK/run-core"; mkdir -p "$RDx"; mkprompts "$RDx" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDx" --repo "$WORK" --skip silent-failure-hunter >/dev/null 2>&1
check "refuses to skip a core agent (non-zero)" '[ "$?" -ne 0 ]'

echo "== agent-failure detection =="
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$BIN/codex"
RDf="$WORK/run-fail"; mkdir -p "$RDf"; mkprompts "$RDf" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDf" --repo "$WORK" --skip failure-pattern-analyst >/dev/null 2>&1
rc=$?
check "launcher exits non-zero on crash"  '[ "$rc" -ne 0 ]'
check ".failed lists crashed agents"      '[ -s "$RDf/.failed" ]'
check "AGENT_FAILED sentinel appended"    'grep -q "^AGENT_FAILED" "$RDf/review-code-reviewer.txt"'

echo "== watchdog kill =="
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
sleep 120
FAKE
chmod +x "$BIN/codex"
RDw="$WORK/run-wd"; mkdir -p "$RDw"; mkprompts "$RDw" "${ALL[@]}"
# tiny deadline so the watchdog fires fast; only the core tier to keep it quick
PATH="$BIN:$PATH" AGENT_TIMEOUT_SECONDS=1 bash "$LAUNCH" --run-dir "$RDw" --repo "$WORK" \
  --skip failure-pattern-analyst >/dev/null 2>&1
check "watchdog appended sentinel"        'grep -q "^WATCHDOG_KILLED" "$RDw/review-code-reviewer.txt"'
check "watchdog kill != AGENT_FAILED"     '! grep -q "^AGENT_FAILED" "$RDw/review-code-reviewer.txt"'

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
