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

echo "== persona content (review-quality fields) =="
RC="$WORK/r-content"; mkdir -p "$RC"
bash "$BUILD" --packet "$PACKET" --out "$RC" \
  --roles code-reviewer,test-analyzer,silent-failure-hunter,type-design-analyzer,comment-analyzer,code-simplifier,failure-pattern-analyst >/dev/null
# EVERY persona that now requires a failure-scenario/cost line is checked — a
# regression dropping it from any one of them must fail the suite.
for r in code-reviewer test-analyzer silent-failure-hunter type-design-analyzer comment-analyzer code-simplifier; do
  check "$r has failure_scenario field" 'grep -qi "Failure scenario" "$RC/prompt-'"$r"'.txt"'
done
check "failure-pattern-analyst has failure scenario" 'grep -qi "failure scenario" "$RC/prompt-failure-pattern-analyst.txt"'
check "code-reviewer has removed-behavior" 'grep -qi "Removed-behavior audit" "$RC/prompt-code-reviewer.txt"'
check "code-reviewer has cross-file trace" 'grep -qi "Cross-file trace" "$RC/prompt-code-reviewer.txt"'
check "comment-analyzer severity aligned"  'grep -qi "ACTIVELY MISLEADING" "$RC/prompt-comment-analyzer.txt"'
check "code-simplifier caps at SUGGESTION" 'grep -qi "default to SUGGESTION" "$RC/prompt-code-simplifier.txt"'

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
rcw=$?
check "watchdog appended sentinel"        'grep -q "^WATCHDOG_KILLED" "$RDw/review-code-reviewer.txt"'
check "watchdog kill != AGENT_FAILED"     '! grep -q "^AGENT_FAILED" "$RDw/review-code-reviewer.txt"'
check "watchdog batch exits 0"            '[ "$rcw" -eq 0 ]'
check "watchdog writes .done"             '[ -f "$RDw/.done" ]'
check "watchdog leaves no .failed"        '[ ! -f "$RDw/.failed" ]'

echo "== exit-0 with empty output =="
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$BIN/codex"
RDe="$WORK/run-empty"; mkdir -p "$RDe"; mkprompts "$RDe" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDe" --repo "$WORK" --skip failure-pattern-analyst >/dev/null 2>&1
rce=$?
check "exit-0 empty output fails batch"   '[ "$rce" -ne 0 ]'
check "exit-0 empty writes .failed"       '[ -s "$RDe/.failed" ]'
check "exit-0 empty AGENT_FAILED marker"  'grep -q "AGENT_FAILED exit=0-empty-output" "$RDe/review-code-reviewer.txt"'

echo "== packet path with sed metacharacters =="
PKAMP="$WORK/pk&meta"; mkdir -p "$PKAMP/files"
RDamp="$WORK/r-amp"; mkdir -p "$RDamp"
bash "$BUILD" --packet "$PKAMP" --out "$RDamp" --roles code-reviewer >/dev/null
check "ampersand path substituted literally" 'grep -qF "$PKAMP/" "$RDamp/prompt-code-reviewer.txt"'
check "no corrupted placeholder remains"     '! grep -q "{PACKET_PATH}" "$RDamp/prompt-code-reviewer.txt"'

echo "== CODEX_SANDBOX_UNAVAILABLE bypass =="
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
out=""; a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "-o" ] && out="${a[$((i+1))]}"; done
[ -n "$out" ] && echo "No issues found." > "$out"
printf '%s\n' "$*" >> "$SANDBOX_TRACE"
FAKE
chmod +x "$BIN/codex"
RDsb="$WORK/run-sandbox"; mkdir -p "$RDsb"; mkprompts "$RDsb" "${ALL[@]}"
export SANDBOX_TRACE="$WORK/sandbox-trace.txt"; : > "$SANDBOX_TRACE"
PATH="$BIN:$PATH" CODEX_SANDBOX_UNAVAILABLE=1 bash "$LAUNCH" --run-dir "$RDsb" --repo "$WORK" \
  --skip failure-pattern-analyst >/dev/null 2>&1
check "bypass flag used when sandbox unavailable" 'grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$SANDBOX_TRACE"'
check "no per-role sandbox under bypass"           '! grep -q -- "-s read-only" "$SANDBOX_TRACE"'
: > "$SANDBOX_TRACE"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDsb" --repo "$WORK" --skip failure-pattern-analyst >/dev/null 2>&1
check "no bypass when var unset"                   '! grep -q -- "--dangerously-bypass" "$SANDBOX_TRACE"'
check "write agents use -s workspace-write"        'grep -q -- "-s workspace-write" "$SANDBOX_TRACE"'
check "no deprecated --full-auto flag"             '! grep -q -- "--full-auto" "$SANDBOX_TRACE"'

echo "== history-io.sh (PR-resident history / in-flight markers) =="
HIO="$DIR/history-io.sh"
{
  printf '%s\n' "CLAUDE: Automated Review Summary" "## Commits" "- abc123 did a thing" ""
  printf '%s\n' "<!-- pr-review-loop:history"
  printf '%s\n' "## All Prior Pushbacks" "- R1 foo.py:10 — CODEX said X; CLAUDE declined." ""
  printf '%s\n' "## Recent Rounds (last 2)" "### Round 1" "CODEX: 0 CRITICAL." "-->"
} > "$WORK/comment-body.txt"
bash "$HIO" extract < "$WORK/comment-body.txt" > "$WORK/hist-out.txt"
check "extract keeps All Prior Pushbacks" 'grep -q "All Prior Pushbacks" "$WORK/hist-out.txt"'
check "extract keeps Recent Rounds"       'grep -q "### Round 1" "$WORK/hist-out.txt"'
check "extract drops wrap-up prose"       '! grep -q "Automated Review Summary" "$WORK/hist-out.txt"'
check "extract drops opening marker"      '! grep -q "pr-review-loop:history" "$WORK/hist-out.txt"'
check "extract drops closing marker"      '! grep -qx -- "-->" "$WORK/hist-out.txt"'
# A wrap-up that QUOTES the opener token in prose (before the real block) must
# not fool the extractor — only the line-start opener counts. (Caught in dogfood.)
{
  printf '%s\n' "CLAUDE: Automated Review Summary" \
    "- fix: match the \`<!-- pr-review-loop:history\` opener exactly" ""
  printf '%s\n' "<!-- pr-review-loop:history" "REAL-HISTORY-CONTENT" "-->"
} > "$WORK/comment-prose.txt"
bash "$HIO" extract < "$WORK/comment-prose.txt" > "$WORK/hist-prose.txt"
check "extract ignores prose mention of opener" 'grep -qx "REAL-HISTORY-CONTENT" "$WORK/hist-prose.txt"'
check "extract drops the prose bullet"          '! grep -q "fix: match" "$WORK/hist-prose.txt"'
MARKER='🔒 pr-review-loop running on `runnerbox` (auto-removed at loop end) <!-- pr-review-loop:running runnerbox 1783400000 -->'
check "marker-host parses host"           '[ "$(printf "%s" "$MARKER" | bash "$HIO" marker-host)" = "runnerbox" ]'
check "marker-epoch parses epoch"         '[ "$(printf "%s" "$MARKER" | bash "$HIO" marker-epoch)" = "1783400000" ]'
# marker-blocks decision: exit 0 = block (another active host), exit 1 = proceed
NOW=1783400300   # 300s after the marker epoch → fresh
check "fresh other-host marker blocks"    'printf "%s" "$MARKER" | bash "$HIO" marker-blocks laptop  '"$NOW"''
check "own-host marker proceeds"          '! printf "%s" "$MARKER" | bash "$HIO" marker-blocks runnerbox '"$NOW"''
check "stale other-host marker proceeds"  '! printf "%s" "$MARKER" | MARKER_MAX_AGE=60 bash "$HIO" marker-blocks laptop '"$NOW"''
check "malformed marker proceeds"         '! printf "garbage no marker" | bash "$HIO" marker-blocks laptop '"$NOW"''
check "empty marker proceeds"             '! printf "" | bash "$HIO" marker-blocks laptop '"$NOW"''
# The history-selection jq predicate (used by SKILL.md via `gh -q`) is the same
# string selftest runs through `jq` — so selector + extractor are covered end to
# end and can't drift. A NEWER prose-only comment must NOT win over an older real
# block. Skips only if jq is unavailable.
if command -v jq >/dev/null 2>&1; then
  FILTER="$(bash "$HIO" history-filter)"
  printf '%s' '{"comments":[
    {"body":"CLAUDE: summary\n\n<!-- pr-review-loop:history\nREAL-BLOCK-CONTENT\n-->"},
    {"body":"a human says: fixed by matching the <!-- pr-review-loop:history opener"}
  ]}' > "$WORK/comments.json"
  jq -r "$FILTER" < "$WORK/comments.json" | bash "$HIO" extract > "$WORK/recon.txt"
  check "selector+extract: older real block wins over newer prose" 'grep -qx "REAL-BLOCK-CONTENT" "$WORK/recon.txt"'
  check "selector+extract: reconstruction is non-empty"            '[ -s "$WORK/recon.txt" ]'
else
  echo "  (skip: jq not installed — history-selector test needs jq)"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
