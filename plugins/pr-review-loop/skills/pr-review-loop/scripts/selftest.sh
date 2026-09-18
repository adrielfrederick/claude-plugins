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
# Same malformed-comma strictness as launch-agents --only: "code-reviewer,"
# must die, not silently build one prompt (read -a drops the empty field).
check "roles trailing comma dies"         '! bash "$BUILD" --packet "$PACKET" --out "$R2" --roles "code-reviewer," 2>/dev/null'
check "roles double comma dies"           '! bash "$BUILD" --packet "$PACKET" --out "$R2" --roles "code-reviewer,,test-analyzer" 2>/dev/null'
# A typo'd packet path must fail here, not produce prompts pointing at nothing.
check "nonexistent packet dir dies"       '! bash "$BUILD" --packet "$WORK/no-such-packet" --out "$R2" --roles code-reviewer 2>/dev/null'

echo "== build-prompts.sh --scoped =="
# Fail closed FIRST, while there is no delta.patch — a scoped round that reviews
# a missing/empty delta would report clean without checking the fix.
RSE="$WORK/r-scoped-empty"; mkdir -p "$RSE"
check "scoped fails with no delta.patch"   '! bash "$BUILD" --packet "$PACKET" --out "$RSE" --roles code-reviewer --scoped 2>/dev/null'
: > "$PACKET/delta.patch"   # zero-byte delta — must also fail closed (regression guard for -s vs -f)
check "scoped fails with empty delta.patch" '! bash "$BUILD" --packet "$PACKET" --out "$RSE" --roles code-reviewer --scoped 2>/dev/null'
rm -f "$PACKET/delta.patch"
# Now provide a delta and verify the scoped addendum assembles correctly.
printf 'diff --git a/x b/x\n+real change\n' > "$PACKET/delta.patch"
RS="$WORK/r-scoped"; mkdir -p "$RS"
bash "$BUILD" --packet "$PACKET" --out "$RS" --roles code-reviewer,test-analyzer --scoped >/dev/null
check "scoped succeeds with a delta.patch" '[ -f "$RS/prompt-code-reviewer.txt" ]'
check "scoped addendum present"           'grep -q "SCOPED VERIFY ROUND" "$RS/prompt-code-reviewer.txt"'
check "scoped points at delta.patch"      'grep -q "delta.patch" "$RS/prompt-code-reviewer.txt"'
check "scoped addendum precedes persona"  '[ "$(grep -n "SCOPED VERIFY ROUND" "$RS/prompt-code-reviewer.txt" | head -1 | cut -d: -f1)" -lt "$(grep -n "expert code reviewer" "$RS/prompt-code-reviewer.txt" | head -1 | cut -d: -f1)" ]'
check "non-scoped omits the addendum"     '! grep -q "SCOPED VERIFY ROUND" "$R/prompt-code-reviewer.txt"'
rm -f "$PACKET/delta.patch"

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
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
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

echo "== codex version floor (gpt-5.6 family) =="
# Every role runs a gpt-5.6-* model (heavy: sol, mini: luna), which the API
# rejects with a 400 below codex 0.144.1. launch-agents.sh must refuse to spawn
# when the CLI is too old — one clear message beats every agent 400ing mid-round.
# Fake an old codex (the model name is present but the server gate isn't) and
# confirm the launch dies before any agent runs — for a heavy batch AND a mini
# batch, since the guard matches the whole family, not one model.
cat > "$BIN/codex" <<'OLD'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.143.0"; exit 0; }
out=""; a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "-o" ] && out="${a[$((i+1))]}"; done
[ -n "$out" ] && echo "No issues found." > "$out"
OLD
chmod +x "$BIN/codex"
RDver="$WORK/run-oldcodex"; mkdir -p "$RDver"; mkprompts "$RDver" "${ALL[@]}"
errver="$(PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDver" --repo "$WORK" --skip failure-pattern-analyst 2>&1)"; rcver=$?
check "old codex fails a heavy batch"       '[ "'"$rcver"'" -ne 0 ]'
check "old codex names the version floor"   'printf "%s" "'"$errver"'" | grep -q "too old for the gpt-5.6"'
check "old codex launches no agents"        '! ls "$RDver"/review-*.txt >/dev/null 2>&1'
# A mini (gpt-5.6-luna) scoped batch must ALSO hit the floor — the guard keys on
# the gpt-5.6- family prefix, not on the heavy model.
RDmini="$WORK/run-mini-oldcodex"; mkdir -p "$RDmini"; mkprompts "$RDmini" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDmini" --repo "$WORK" --only type-design-analyzer >/dev/null 2>&1
rcmini=$?
check "old codex fails a mini (luna) batch"  '[ "'"$rcmini"'" -ne 0 ]'
check "old codex runs no mini agents"        '[ ! -f "$RDmini/review-type-design-analyzer.txt" ]'
# Restore a current-codex fake — the sections below assume a CLI that clears the
# gpt-5.6 floor (they don't set their own version and select 5.6 roles).
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
out=""; a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "-o" ] && out="${a[$((i+1))]}"; done
[ -n "$out" ] && echo "No issues found." > "$out"
FAKE
chmod +x "$BIN/codex"

# refuse to skip a core agent
RDx="$WORK/run-core"; mkdir -p "$RDx"; mkprompts "$RDx" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDx" --repo "$WORK" --skip silent-failure-hunter >/dev/null 2>&1
check "refuses to skip a core agent (non-zero)" '[ "$?" -ne 0 ]'

# --only: scoped verify runs EXACTLY the named roles, bypassing core-tier enforcement
RDo="$WORK/run-only"; mkdir -p "$RDo"; mkprompts "$RDo" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDo" --repo "$WORK" --only code-reviewer,test-analyzer >/dev/null 2>&1
check "--only runs exactly the named roles"   '[ -f "$RDo/review-code-reviewer.txt" ] && [ -f "$RDo/review-test-analyzer.txt" ]'
check "--only omits unnamed core agents"      '[ ! -f "$RDo/review-silent-failure-hunter.txt" ] && [ ! -f "$RDo/review-type-design-analyzer.txt" ]'
check "--only rejects an unknown role"        '! bash "$LAUNCH" --run-dir "$RDo" --repo "$WORK" --only nope 2>/dev/null'
check "--only rejects combining with --add"   '! bash "$LAUNCH" --run-dir "$RDo" --repo "$WORK" --only code-reviewer --add comment-analyzer 2>/dev/null'
check "--only rejects an empty value"         '! bash "$LAUNCH" --run-dir "$RDo" --repo "$WORK" --only "" 2>/dev/null'
# Duplicate roles would launch two codex processes clobbering the same
# review/log files — the normal-round branch dedupes, --only must refuse.
check "--only rejects a duplicate role"       '! bash "$LAUNCH" --run-dir "$RDo" --repo "$WORK" --only code-reviewer,code-reviewer 2>/dev/null'
# Malformed comma patterns must be rejected BEFORE any agent launches, and
# deterministically (bash read -a drops a trailing empty field on some builds).
for bad in "code-reviewer," ",code-reviewer" "code-reviewer,,test-analyzer"; do
  RDbad="$WORK/run-only-bad"; rm -rf "$RDbad"; mkdir -p "$RDbad"; mkprompts "$RDbad" "${ALL[@]}"
  err="$(PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDbad" --repo "$WORK" --only "$bad" 2>&1)"; rc=$?
  check "--only rejects '$bad' (non-zero)"       '[ "'"$rc"'" -ne 0 ]'
  check "--only rejects '$bad' (empty-role diag)" 'printf "%s" "'"$err"'" | grep -q "empty role"'
  check "--only rejects '$bad' (no agents ran)"   '! ls "$RDbad"/review-*.txt >/dev/null 2>&1'
done

echo "== agent-failure detection =="
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
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
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
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
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
exit 0
FAKE
chmod +x "$BIN/codex"
RDe="$WORK/run-empty"; mkdir -p "$RDe"; mkprompts "$RDe" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDe" --repo "$WORK" --skip failure-pattern-analyst >/dev/null 2>&1
rce=$?
check "exit-0 empty output fails batch"   '[ "$rce" -ne 0 ]'
check "exit-0 empty writes .failed"       '[ -s "$RDe/.failed" ]'
check "exit-0 empty AGENT_FAILED marker"  'grep -q "AGENT_FAILED exit=0-empty-output" "$RDe/review-code-reviewer.txt"'

echo "== non-numeric AGENT_TIMEOUT_SECONDS =="
# A bad timeout used to kill the watchdog subshell silently, leaving the agent
# unbounded — it must fail the launch up front instead. Zero is numeric but
# would watchdog-kill every agent on the first tick; also rejected.
check "non-numeric timeout dies"          '! PATH="$BIN:$PATH" AGENT_TIMEOUT_SECONDS=abc bash "$LAUNCH" --run-dir "$RDe" --repo "$WORK" --skip failure-pattern-analyst 2>/dev/null'
check "zero timeout dies"                 '! PATH="$BIN:$PATH" AGENT_TIMEOUT_SECONDS=0 bash "$LAUNCH" --run-dir "$RDe" --repo "$WORK" --skip failure-pattern-analyst 2>/dev/null'

echo "== watchdog classification is out-of-band (sentinel spoof) =="
# A crashed agent whose OUTPUT happens to contain a WATCHDOG_KILLED line is
# model text, not a kill record — it must classify as AGENT_FAILED, not as a
# watchdog kill (which would let the batch exit 0 on a crash).
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
out=""; a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "-o" ] && out="${a[$((i+1))]}"; done
[ -n "$out" ] && printf 'WATCHDOG_KILLED spoofed by model output\n' > "$out"
exit 1
FAKE
chmod +x "$BIN/codex"
RDsf="$WORK/run-spoof"; mkdir -p "$RDsf"; mkprompts "$RDsf" "${ALL[@]}"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDsf" --repo "$WORK" --skip failure-pattern-analyst >/dev/null 2>&1
rcsf=$?
check "spoofed sentinel still fails batch"  '[ "$rcsf" -ne 0 ]'
check "spoofed sentinel writes .failed"     '[ -s "$RDsf/.failed" ]'
check "spoofed sentinel gets AGENT_FAILED"  'grep -q "^AGENT_FAILED" "$RDsf/review-code-reviewer.txt"'

echo "== spurious watchdog fire on a completed agent =="
# The reverse race: the agent finishes inside the watchdog's final poll tick,
# so the marker+sentinel land on a review that completed with exit 0. The reap
# loop must treat that as a success and strip the spurious sentinel, not report
# a partial/killed review. Simulated by pre-creating the marker file.
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
out=""; a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "-o" ] && out="${a[$((i+1))]}"; done
[ -n "$out" ] && printf 'No issues found.\nWATCHDOG_KILLED after 900s\n' > "$out"
FAKE
chmod +x "$BIN/codex"
RDsp="$WORK/run-spurious"; mkdir -p "$RDsp"; mkprompts "$RDsp" "${ALL[@]}"
: > "$RDsp/.watchdog-killed-code-reviewer"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDsp" --repo "$WORK" --skip failure-pattern-analyst >/dev/null 2>&1
rcsp=$?
check "spurious-fire batch succeeds"        '[ "$rcsp" -eq 0 ]'
check "spurious marker file removed"        '[ ! -f "$RDsp/.watchdog-killed-code-reviewer" ]'
check "spurious sentinel stripped"          '! grep -q "^WATCHDOG_KILLED" "$RDsp/review-code-reviewer.txt"'
check "review content survives the strip"   'grep -q "No issues found." "$RDsp/review-code-reviewer.txt"'

echo "== zombie-fire: marker on a CRASHED agent stays a crash =="
# kill -0 succeeds on a zombie, so a fast-crashing agent that sits unreaped
# (while the loop waits on a slower agent) can collect a watchdog marker at the
# deadline. A marker is only credible with signal-death exit codes (143/137) —
# a marker + exit 1 must classify AGENT_FAILED, not "expected watchdog kill".
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
exit 1
FAKE
chmod +x "$BIN/codex"
RDzf="$WORK/run-zombie"; mkdir -p "$RDzf"; mkprompts "$RDzf" "${ALL[@]}"
: > "$RDzf/.watchdog-killed-code-reviewer"
PATH="$BIN:$PATH" bash "$LAUNCH" --run-dir "$RDzf" --repo "$WORK" --skip failure-pattern-analyst >/dev/null 2>&1
rczf=$?
check "zombie-fire batch fails"             '[ "$rczf" -ne 0 ]'
check "zombie-fire classifies AGENT_FAILED" 'grep -q "^AGENT_FAILED exit=1" "$RDzf/review-code-reviewer.txt"'
check "zombie-fire lists role in .failed"   'grep -q "^code-reviewer$" "$RDzf/.failed"'

echo "== packet path with sed metacharacters =="
PKAMP="$WORK/pk&meta"; mkdir -p "$PKAMP/files"
RDamp="$WORK/r-amp"; mkdir -p "$RDamp"
bash "$BUILD" --packet "$PKAMP" --out "$RDamp" --roles code-reviewer >/dev/null
check "ampersand path substituted literally" 'grep -qF "$PKAMP/" "$RDamp/prompt-code-reviewer.txt"'
check "no corrupted placeholder remains"     '! grep -q "{PACKET_PATH}" "$RDamp/prompt-code-reviewer.txt"'

echo "== CODEX_SANDBOX_UNAVAILABLE bypass =="
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.144.1"; exit 0; }
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
# A history line that merely STARTS with "-->" (quoted code/HTML in a pushback)
# must not close the block early and silently truncate everything after it —
# only a bare `-->` line (the writer's guaranteed closer) ends extraction.
{
  printf '%s\n' "<!-- pr-review-loop:history" "LINE-ONE" "--> quoted, not a closer" "LINE-TWO" "-->" "AFTER-THE-BLOCK"
} > "$WORK/comment-arrow.txt"
bash "$HIO" extract < "$WORK/comment-arrow.txt" > "$WORK/hist-arrow.txt"
check "extract keeps content after a quoted -->" 'grep -qx "LINE-TWO" "$WORK/hist-arrow.txt"'
check "extract keeps the quoted --> line itself" 'grep -q "quoted, not a closer" "$WORK/hist-arrow.txt"'
check "extract stops at the bare closer"         '! grep -q "AFTER-THE-BLOCK" "$WORK/hist-arrow.txt"'
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
  # A comment whose body BEGINS with the opener has no leading \n — the
  # selector must still match it (startswith), or history is silently dropped.
  printf '%s' '{"comments":[
    {"body":"<!-- pr-review-loop:history\nBODY-START-CONTENT\n-->"}
  ]}' > "$WORK/comments-start.json"
  jq -r "$FILTER" < "$WORK/comments-start.json" | bash "$HIO" extract > "$WORK/recon-start.txt"
  check "selector matches an opener at body start" 'grep -qx "BODY-START-CONTENT" "$WORK/recon-start.txt"'
else
  echo "  (skip: jq not installed — history-selector test needs jq)"
fi

echo "== history-io.sh rounds (per-PR fix budget) =="
# ITERATION resets every run, so MAX_ITERATIONS bounds a RUN and not a PR —
# f1-predictions#623 spent 13 rounds across two runs without either reaching 10.
# This counter is what survives a re-label, so UNDERCOUNTING silently hands back
# budget the PR has already spent. Every case below is a way that could happen.
ROUNDS_MARKER='<!-- pr-review-loop:rounds 7 -->'
printf '13\n'    > "$WORK/rounds-file.txt"
printf 'garbage\n' > "$WORK/rounds-corrupt.txt"
: > "$WORK/rounds-empty.txt"
check "rounds-parse reads the marker" \
  '[ "$(printf "%s" "$ROUNDS_MARKER" | bash "$HIO" rounds-parse)" = "7" ]'
check "rounds-parse is empty with no marker" \
  '[ -z "$(printf "no marker here" | bash "$HIO" rounds-parse)" ]'
# Fresh container: local file gone, the PR-resident marker is the only source.
check "marker alone survives a lost local file" \
  '[ "$(printf "%s" "$ROUNDS_MARKER" | bash "$HIO" rounds-total "$WORK/nonexistent")" = "7" ]'
# Deleted or hand-edited summary comment: the local file is the only source.
check "local file alone survives a lost marker" \
  '[ "$(printf "no marker" | bash "$HIO" rounds-total "$WORK/rounds-file.txt")" = "13" ]'
# Max, not "prefer one" — either source can lag, and undercounting is the bug.
check "max wins when the file is ahead" \
  '[ "$(printf "%s" "$ROUNDS_MARKER" | bash "$HIO" rounds-total "$WORK/rounds-file.txt")" = "13" ]'
check "max wins when the marker is ahead" \
  '[ "$(printf "<!-- pr-review-loop:rounds 20 -->" | bash "$HIO" rounds-total "$WORK/rounds-file.txt")" = "20" ]'
check "no source at all is 0, not empty" \
  '[ "$(printf "nothing" | bash "$HIO" rounds-total "$WORK/nonexistent")" = "0" ]'
# A half-written counter from a killed run must read as 0 rather than abort the
# loop — the PR-resident marker still carries the real total in that case.
check "a corrupt counter file degrades to 0" \
  '[ "$(printf "nothing" | bash "$HIO" rounds-total "$WORK/rounds-corrupt.txt")" = "0" ]'
check "an empty counter file degrades to 0" \
  '[ "$(printf "nothing" | bash "$HIO" rounds-total "$WORK/rounds-empty.txt")" = "0" ]'
# Phase 0 pipes the fetched comment body in; that fetch can legitimately be empty.
check "rounds-total works with no stdin" \
  '[ "$(bash "$HIO" rounds-total "$WORK/rounds-file.txt" < /dev/null)" = "13" ]'
# The rounds marker must not cross-match the in-flight marker: both are
# `pr-review-loop:` HTML comments, and the running marker's trailing epoch is a
# long digit run that a loose pattern would happily read as a round count.
check "the running marker is not read as a rounds count" \
  '[ "$(printf "%s" "$MARKER" | bash "$HIO" rounds-total "$WORK/nonexistent")" = "0" ]'
check "a rounds marker is not read as a host" \
  '[ -z "$(printf "%s" "$ROUNDS_MARKER" | bash "$HIO" marker-host)" ]'
# Both markers coexist on a real PR; each must find only its own.
BOTH="$ROUNDS_MARKER"$'\n''<!-- pr-review-loop:running runnerbox 1783400000 -->'
check "rounds parses alongside a running marker" \
  '[ "$(printf "%s" "$BOTH" | bash "$HIO" rounds-parse)" = "7" ]'
check "host parses alongside a rounds marker" \
  '[ "$(printf "%s" "$BOTH" | bash "$HIO" marker-host)" = "runnerbox" ]'
# The wrap-up template puts the rounds marker in the same comment as the history
# block, so extraction and the counter must not interfere with each other.
{
  printf '%s\n' "CLAUDE: Automated Review Summary" "<!-- pr-review-loop:summary -->" "$ROUNDS_MARKER" ""
  printf '%s\n' "<!-- pr-review-loop:history" "HIST-WITH-ROUNDS" "-->"
} > "$WORK/comment-rounds.txt"
bash "$HIO" extract < "$WORK/comment-rounds.txt" > "$WORK/hist-rounds.txt"
check "extract still works with a rounds marker present" \
  'grep -qx "HIST-WITH-ROUNDS" "$WORK/hist-rounds.txt"'
check "extract drops the rounds marker itself" \
  '! grep -q "pr-review-loop:rounds" "$WORK/hist-rounds.txt"'
check "rounds reads out of a full wrap-up comment" \
  '[ "$(bash "$HIO" rounds-total "$WORK/nonexistent" < "$WORK/comment-rounds.txt")" = "7" ]'
# A comment that merely MENTIONS the marker syntax in prose (a human quoting
# the wrap-up while discussing it) must not poison the lifetime round count —
# only a real, standalone marker line is honored.
INJECT="Careful, I saw a pr-review-loop:rounds 999 mention in an earlier comment."
check "prose mention of the rounds token parses to nothing" \
  '[ -z "$(printf "%s" "$INJECT" | bash "$HIO" rounds-parse)" ]'
if command -v jq >/dev/null 2>&1; then
  printf '%s' '{"comments":[{"body":"<!-- pr-review-loop:rounds 4 -->"},{"body":"'"$INJECT"'"}]}' > "$WORK/comments-inject.json"
  check "rounds-filter excludes a prose mention of the token" \
    '[ "$(jq -r "$(bash "$HIO" rounds-filter)" < "$WORK/comments-inject.json" | bash "$HIO" rounds-total "$WORK/nonexistent")" = "4" ]'
fi
# A comment that BEGINS with a real-looking marker and then continues in prose
# on the SAME line must also parse to nothing — a trailing `.*` (no end
# anchor) would still match this and poison the count, as a leading-`.*`
# pattern let happen against the plain-prose case above.
TRAILING_INJECT="<!-- pr-review-loop:rounds 999 --> quoted from the previous summary"
check "marker with trailing prose on the same line parses to nothing" \
  '[ -z "$(printf "%s" "$TRAILING_INJECT" | bash "$HIO" rounds-parse)" ]'

echo "== refresh-packet.sh (fixture repo + fake gh) =="
REFRESH="$DIR/refresh-packet.sh"
FR="$WORK/fixture-repo"
git init -q -b main "$FR" 2>/dev/null || { git init -q "$FR"; git -C "$FR" checkout -qb main; }
git -C "$FR" config user.email t@t; git -C "$FR" config user.name t
mkdir -p "$FR/src/sub"
printf 'base\n' > "$FR/src/sub/a.txt"; printf 'base\n' > "$FR/b.txt"
git -C "$FR" add -A; git -C "$FR" commit -qm base
git -C "$FR" checkout -qb feature
printf 'change\n' >> "$FR/src/sub/a.txt"; printf 'change\n' >> "$FR/b.txt"
git -C "$FR" add -A; git -C "$FR" commit -qm change
# fake gh: `gh pr diff <n>` = git diff $FAKE_BASE...HEAD in cwd (refresh-packet
# cds into --repo before calling gh, matching the real gh's repo inference).
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "pr" ] && [ "$2" = "diff" ] || exit 1
git diff "${FAKE_BASE:?}"...HEAD
FAKE
chmod +x "$BIN/gh"
PK="$WORK/packet-rp"; mkdir -p "$PK"
PATH="$BIN:$PATH" FAKE_BASE=main bash "$REFRESH" --repo "$FR" --packet "$PK" --pr 1 --base main >/dev/null
check "refresh: diff.patch written"        '[ -s "$PK/diff.patch" ]'
check "refresh: per-file split with __"    '[ -f "$PK/files/src__sub__a.txt.patch" ]'
check "refresh: manifest lists the splits" 'grep -qx "src__sub__a.txt.patch" "$PK/manifest.txt" && grep -qx "b.txt.patch" "$PK/manifest.txt"'
check "refresh: diff-wide written"         '[ -s "$PK/diff-wide.patch" ]'
check "refresh: changed-files written"     '[ -s "$PK/changed-files.txt" ]'
# Idempotent re-run must REPLACE files/, not merge over a stale prior round.
printf 'stale\n' > "$PK/files/stale.patch"
PATH="$BIN:$PATH" FAKE_BASE=main bash "$REFRESH" --repo "$FR" --packet "$PK" --pr 1 --base main >/dev/null
check "refresh: stale split removed on re-run" '[ ! -f "$PK/files/stale.patch" ]'
# Dot-path-only PR: every changed file lives under a dot-directory, so every
# per-file split name begins with a dot. A plain `ls` omits dotfiles, which left
# the manifest EMPTY → agents saw "0 files to review" → a vacuous "clean" review.
# (Live repro: a .github/workflows/*.yml-only PR.) This is the degenerate case —
# the manifest goes fully empty; the MIXED case, where a dot-path file hides
# among normal ones and only the count looks off, is covered in "path forms"
# below. awk now emits the manifest directly, so neither `ls` nor `ls -A` is in
# the path at all, but both cases stay pinned.
FRD="$WORK/fixture-dotonly"
git init -q -b main "$FRD" 2>/dev/null || { git init -q "$FRD"; git -C "$FRD" checkout -qb main; }
git -C "$FRD" config user.email t@t; git -C "$FRD" config user.name t
mkdir -p "$FRD/.github/workflows"
printf 'name: ci\non: push\n' > "$FRD/.github/workflows/pr.yml"
git -C "$FRD" add -A; git -C "$FRD" commit -qm base
git -C "$FRD" checkout -qb feature
printf 'jobs: {}\n' >> "$FRD/.github/workflows/pr.yml"
git -C "$FRD" add -A; git -C "$FRD" commit -qm change
PKD="$WORK/packet-dotonly"; mkdir -p "$PKD"
PATH="$BIN:$PATH" FAKE_BASE=main bash "$REFRESH" --repo "$FRD" --packet "$PKD" --pr 1 --base main >/dev/null
check "refresh: dot-only PR splits the dotfile"    '[ -f "$PKD/files/.github__workflows__pr.yml.patch" ]'
check "refresh: dot-only manifest is non-empty"    '[ -s "$PKD/manifest.txt" ]'
check "refresh: dot-only manifest lists the split" 'grep -qx ".github__workflows__pr.yml.patch" "$PKD/manifest.txt"'
# Runner case: no local base branch, but a remote-tracking ref exists.
BASESHA="$(git -C "$FR" rev-parse main)"
git -C "$FR" update-ref refs/remotes/origin/main "$BASESHA"
git -C "$FR" branch -qD main
out="$(PATH="$BIN:$PATH" FAKE_BASE=origin/main bash "$REFRESH" --repo "$FR" --packet "$PK" --pr 1 --base main)"
check "refresh: falls back to origin/<base>" 'printf "%s" "$out" | grep -q "base=origin/main"'
# Runner case #2 (the head-only checkout the fallback exists for): no local
# main AND no remote-tracking origin/main, but an origin remote HAS main, so an
# explicit `git fetch origin main` resolves it to FETCH_HEAD. Separate fixture
# with a real bare origin so the fetch actually succeeds.
REMOTE="$WORK/remote.git"; git init -q --bare "$REMOTE"
FR2="$WORK/fixture-fetch"
git init -q -b main "$FR2" 2>/dev/null || { git init -q "$FR2"; git -C "$FR2" checkout -qb main; }
git -C "$FR2" config user.email t@t; git -C "$FR2" config user.name t
printf 'base\n' > "$FR2/f.txt"; git -C "$FR2" add -A; git -C "$FR2" commit -qm base
git -C "$FR2" remote add origin "$REMOTE"; git -C "$FR2" push -q origin main
BASE2="$(git -C "$FR2" rev-parse main)"
git -C "$FR2" checkout -qb feature
printf 'change\n' >> "$FR2/f.txt"; git -C "$FR2" add -A; git -C "$FR2" commit -qm change
git -C "$FR2" branch -qD main                                    # no local base ref
git -C "$FR2" update-ref -d refs/remotes/origin/main 2>/dev/null || true  # no remote-tracking ref
PK2="$WORK/packet-fetch"; mkdir -p "$PK2"
out2="$(PATH="$BIN:$PATH" FAKE_BASE="$BASE2" bash "$REFRESH" --repo "$FR2" --packet "$PK2" --pr 1 --base main)"
check "refresh: fetch fallback resolves FETCH_HEAD"  'printf "%s" "$out2" | grep -q "base=FETCH_HEAD"'
check "refresh: fetch fallback writes diff-wide"     '[ -s "$PK2/diff-wide.patch" ]'
check "refresh: fetch fallback writes changed-files" '[ -s "$PK2/changed-files.txt" ]'
# No local ref, no remote-tracking ref, no origin remote → fetch fails → die.
git -C "$FR" update-ref -d refs/remotes/origin/main
check "refresh: unresolvable base dies"    '! PATH="$BIN:$PATH" FAKE_BASE=main bash "$REFRESH" --repo "$FR" --packet "$PK" --pr 1 --base main 2>/dev/null'
# An empty diff (base == head) must die, not build a vacuous packet.
git -C "$FR" branch -q main HEAD
check "refresh: empty diff dies"           '! PATH="$BIN:$PATH" FAKE_BASE=main bash "$REFRESH" --repo "$FR" --packet "$PK" --pr 1 --base main 2>/dev/null'
check "refresh: not-a-repo dies"           '! PATH="$BIN:$PATH" FAKE_BASE=main bash "$REFRESH" --repo "$WORK" --packet "$PK" --pr 1 --base main 2>/dev/null'

echo "== refresh-packet.sh: path forms (every shape git emits) =="
# The MIXED-diff sibling of the dot-only case above, and the reason `ls -A`
# alone was not enough: a 2-file PR (.github/workflows/ci.yml + pyproject.toml)
# reported files=1: the split WAS written, the manifest just omitted it, so
# agents told to read manifest.txt for the file list never saw the PR's main
# file. One fixture covers every header shape, because each resolves by a
# different route — ---/+++ lines, `rename to`, or the `diff --git` header.
FR3="$WORK/fixture-paths"
git init -q -b main "$FR3" 2>/dev/null || { git init -q "$FR3"; git -C "$FR3" checkout -qb main; }
git -C "$FR3" config user.email t@t; git -C "$FR3" config user.name t
mkdir -p "$FR3/.github/workflows" "$FR3/sub dir" "$FR3/a" "$FR3/a__b"
printf 'base\n' > "$FR3/.github/workflows/ci.yml"
printf 'base\n' > "$FR3/pyproject.toml"
printf 'base\n' > "$FR3/sub dir/with space.txt"
printf 'base\n' > "$FR3/unicode-caf$(printf '\303\251').txt"
printf 'base\n' > "$FR3/old-name.txt"
printf 'base\n' > "$FR3/mode-only.sh"
printf 'base\n' > "$FR3/to-delete.txt"
printf 'base\n' > "$FR3/a/b__c.py"        # these two flatten to the SAME name
printf 'base\n' > "$FR3/a__b/c.py"
printf '\211PNG\000\001bin\000' > "$FR3/logo.png"
git -C "$FR3" add -A; git -C "$FR3" commit -qm base
git -C "$FR3" checkout -qb feature
printf 'change\n' >> "$FR3/.github/workflows/ci.yml"       # dot-directory (the live bug)
printf 'change\n' >> "$FR3/pyproject.toml"
printf 'change\n' >> "$FR3/sub dir/with space.txt"         # space → old `$4` split gave "dir"
printf 'change\n' >> "$FR3/unicode-caf$(printf '\303\251').txt"  # C-quoted header
printf 'change\n' >> "$FR3/a/b__c.py"
printf 'change\n' >> "$FR3/a__b/c.py"
printf 'new\n'    >  "$FR3/.hidden-root-file"              # dot-file at repo root
git -C "$FR3" mv old-name.txt renamed-name.txt             # halves differ → needs `rename to`
chmod +x "$FR3/mode-only.sh"                               # no ---/+++ lines at all
printf '\211PNG\000\002new\000' > "$FR3/logo.png"          # binary: no ---/+++ either
rm "$FR3/to-delete.txt"                                    # +++ is /dev/null → falls back to ---
git -C "$FR3" add -A; git -C "$FR3" commit -qm change
PK3="$WORK/packet-paths"; mkdir -p "$PK3"
out3="$(PATH="$BIN:$PATH" FAKE_BASE=main bash "$REFRESH" --repo "$FR3" --packet "$PK3" --pr 1 --base main)"
HDRS3="$(grep -c '^diff --git ' "$PK3/diff.patch")"

# Split exists AND is listed. Both halves matter: the live bug wrote the split
# but omitted the manifest entry, and agents only ever read the manifest.
inmanifest() { grep -qxF "$1" "$PK3/manifest.txt" && [ -f "$PK3/files/$1" ]; }
check "paths: dot-directory split + manifest entry" 'inmanifest ".github__workflows__ci.yml.patch"'
check "paths: dot-file at repo root"                'inmanifest ".hidden-root-file.patch"'
check "paths: plain sibling still works"            'inmanifest "pyproject.toml.patch"'
check "paths: space keeps the real name"            'inmanifest "sub dir__with space.txt.patch"'
check "paths: rename uses the NEW name"             'inmanifest "renamed-name.txt.patch"'
check "paths: rename does not use the old name"     '! [ -f "$PK3/files/old-name.txt.patch" ]'
check "paths: mode-only change (no ---/+++)"        'inmanifest "mode-only.sh.patch"'
check "paths: binary file (no ---/+++)"             'inmanifest "logo.png.patch"'
check "paths: deletion (+++ is /dev/null)"          'inmanifest "to-delete.txt.patch"'
# Matched by pattern, not by the exact escape: the filesystem decides whether é
# lands as NFC (\303\251) or NFD (e\314\201), and that is not what is under test.
# What IS under test is that the C-quote WRAPPER is stripped — the old code kept
# it and produced the name "b__unicode-caf\303\251.txt", leading quote and all.
qname="$(grep -m1 '^unicode-caf.*\.txt\.patch$' "$PK3/manifest.txt")"
check "paths: C-quoted non-ASCII is unwrapped"      '[ -n "$qname" ] && [ -f "$PK3/files/$qname" ]'
check "paths: C-quote wrapper not left in the name" '! grep -q "\"" "$PK3/manifest.txt"'
# a/b__c.py and a__b/c.py flatten identically; merging them would hide one file.
check "paths: flatten collision is de-duped"        'inmanifest "a__b__c.py.patch" && inmanifest "a__b__c.py~2.patch"'

# The counts must agree, and the reported number must be the real one — the bug
# under-reported files=1 for a 2-file diff without raising anything.
check "paths: reported files= equals header count" 'printf "%s" "$out3" | grep -q "files=$HDRS3"'
check "paths: manifest count equals header count"  '[ "$(wc -l < "$PK3/manifest.txt" | tr -d " ")" -eq "$HDRS3" ]'
check "paths: files/ count equals header count"    '[ "$(find "$PK3/files" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d " ")" -eq "$HDRS3" ]'
# Splits must partition diff.patch exactly: no line lost, misfiled, or doubled.
( cd "$PK3/files" && while IFS= read -r n; do cat "$n"; done < ../manifest.txt ) > "$WORK/rejoined.patch"
check "paths: splits rejoin to diff.patch byte-for-byte" 'cmp -s "$PK3/diff.patch" "$WORK/rejoined.patch"'

# gh emitting something that is not a patch (an auth page, an error blob) used
# to yield a non-empty diff.patch, an EMPTY manifest and a cheerful files=0 —
# the same silent-vacuum class as the dot-path bug. It must die instead.
GB="$WORK/bin-garbage"; mkdir -p "$GB"
cat > "$GB/gh" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "pr" ] && [ "$2" = "diff" ] || exit 1
printf 'not a patch at all\njust some prose\n'
FAKE
chmod +x "$GB/gh"
PK4="$WORK/packet-garbage"; mkdir -p "$PK4"
check "paths: non-patch gh output dies" '! PATH="$GB:$PATH" bash "$REFRESH" --repo "$FR3" --packet "$PK4" --pr 1 --base main 2>/dev/null'

echo "== gh-io.sh (fake gh: REST/GraphQL health is switchable) =="
GHIO="$DIR/gh-io.sh"
if ! command -v jq >/dev/null 2>&1; then
  echo "  (skip: jq not installed — the gh-io tests need jq)"
else
# A fake `gh` backed by a real comment store, so the REST→GraphQL fallback is
# exercised end-to-end rather than mocked at the seam. FAKE_MODE picks which
# transport is healthy: `rest-down` reproduces the 2026-07-16 incident (REST
# 5xx, GraphQL fine), `rest-html` the degraded-proxy variant where REST exits 0
# but hands back an HTML error page. The fake applies gh-io's own `--jq` filters
# to the JSON it serves, so a drifted filter fails here instead of in a live run.
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
set -u
MODE="${FAKE_MODE:-ok}"
STORE="${FAKE_STORE:?}"
[ -s "$STORE" ] || printf '[]' > "$STORE"

JQF=""; SLURP=0; args=(); i=1
while [ $i -le $# ]; do
  a="${!i}"
  case "$a" in
    --jq)    i=$((i+1)); JQF="${!i}" ;;
    --slurp) SLURP=1; args+=("$a") ;;
    *)       args+=("$a") ;;
  esac
  i=$((i+1))
done
set -- ${args[@]+"${args[@]}"}
# Mirror the real gh: --slurp and --jq are mutually exclusive. Without this the
# fake happily accepts a combination that fails in production — which is exactly
# how the REST list fallback shipped broken and passed its tests.
if [ "$SLURP" = "1" ] && [ -n "$JQF" ]; then
  echo 'the `--slurp` option is not supported with `--jq` or `--template`' >&2; exit 1
fi

emit() { if [ -n "$JQF" ]; then printf '%s' "$1" | jq -r "$JQF"; else printf '%s' "$1"; fi; }
argval() { for a in "$@"; do case "$a" in "$PREFIX"*) printf '%s' "${a#$PREFIX}"; return;; esac; done; }
body_arg() { PREFIX="body=@"; local f; f="$(argval "$@")"; [ -n "$f" ] && cat "$f"; }

[ "${1:-}" = "api" ] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
shift

if [ "${1:-}" = "graphql" ]; then
  case "$MODE" in all-down|graphql-down) echo "GraphQL: 503 Service Unavailable" >&2; exit 1 ;; esac
  PREFIX="query="; Q="$(argval "$@")"
  case "$Q" in
    *"pullRequest(number:\$n){id}"*)
      emit '{"data":{"repository":{"pullRequest":{"id":"PR_NODE"}}}}' ;;
    *addComment*)
      B="$(body_arg "$@")"
      NEXT=$(( $(jq -r '[.[].databaseId] | max // 100' "$STORE") + 1 ))
      jq --argjson n "$NEXT" --arg b "$B" '. + [{databaseId:$n, id:"NODE_\($n)", body:$b}]' \
        "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
      emit "$(jq -nc --argjson n "$NEXT" '{data:{addComment:{commentEdge:{node:{databaseId:$n,id:"NODE_\($n)"}}}}}')" ;;
    *updateIssueComment*)
      PREFIX="id="; NID="$(argval "$@")"
      B="$(body_arg "$@")"
      jq -e --arg i "$NID" 'any(.[]; .id == $i)' "$STORE" >/dev/null \
        || { echo "Could not resolve to a node with the global id of '$NID'" >&2; exit 1; }
      jq --arg i "$NID" --arg b "$B" 'map(if .id == $i then .body = $b else . end)' \
        "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
      DBID="$(jq -r --arg i "$NID" '.[] | select(.id == $i) | .databaseId' "$STORE")"
      emit "$(jq -nc --argjson d "$DBID" '{data:{updateIssueComment:{issueComment:{databaseId:$d}}}}')" ;;
    *deleteIssueComment*)
      PREFIX="id="; NID="$(argval "$@")"
      jq -e --arg i "$NID" 'any(.[]; .id == $i)' "$STORE" >/dev/null \
        || { echo "Could not resolve to a node with the global id of '$NID'" >&2; exit 1; }
      jq --arg i "$NID" 'map(select(.id != $i))' "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
      emit '{"data":{"deleteIssueComment":{"clientMutationId":null}}}' ;;
    *"comments(last:100)"*)
      emit "$(jq -c '{data:{repository:{pullRequest:{comments:{nodes:.}}}}}' "$STORE")" ;;
    *) echo "fake gh: unhandled query: $Q" >&2; exit 1 ;;
  esac
  exit 0
fi

# ── REST ──
if [ "$MODE" = "rest-down" ] || [ "$MODE" = "all-down" ]; then
  echo "gh: HTTP 503: Service Unavailable" >&2; exit 1
fi
if [ "$MODE" = "rest-html" ]; then
  # Exits 0 with an HTML error page — the shape gh-io must reject rather than
  # persist as a comment id.
  printf '<html><head><title>GitHub Unicorn</title></head></html>'; exit 0
fi
METHOD=GET; PATH_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    -f|-F) shift 2 ;;
    --paginate|--slurp) shift ;;
    *) PATH_ARG="$1"; shift ;;
  esac
done
case "$METHOD/$PATH_ARG" in
  POST/*/comments)
    B="$(body_arg "$@")"; B="${B:-$(cat "${FAKE_BODY:-/dev/null}")}"
    NEXT=$(( $(jq -r '[.[].databaseId] | max // 100' "$STORE") + 1 ))
    jq --argjson n "$NEXT" --arg b "$B" '. + [{databaseId:$n, id:"NODE_\($n)", body:$b}]' \
      "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
    emit "$(jq -nc --argjson n "$NEXT" '{id:$n, node_id:"NODE_\($n)"}')" ;;
  PATCH/*/issues/comments/*)
    CID="${PATH_ARG##*/}"
    B="$(body_arg "$@")"; B="${B:-$(cat "${FAKE_BODY:-/dev/null}")}"
    jq -e --argjson c "$CID" 'any(.[]; .databaseId == $c)' "$STORE" >/dev/null \
      || { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
    jq --argjson c "$CID" --arg b "$B" 'map(if .databaseId == $c then .body = $b else . end)' \
      "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
    emit "$(jq -nc --argjson c "$CID" '{id:$c, node_id:"NODE_\($c)"}')" ;;
  DELETE/*/issues/comments/*)
    CID="${PATH_ARG##*/}"
    jq -e --argjson c "$CID" 'any(.[]; .databaseId == $c)' "$STORE" >/dev/null \
      || { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
    jq --argjson c "$CID" 'map(select(.databaseId != $c))' "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE" ;;
  GET/*/comments*)
    emit "$(jq -c '[[.[] | {id:.databaseId, node_id:.id, body:.body}]]' "$STORE")" ;;
  *) echo "fake gh: unhandled REST $METHOD $PATH_ARG" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BIN/gh"

# The fake's REST POST loses `-F body=@…` to the flag-stripping loop above, so
# hand it the same file out-of-band. Real gh reads the flag; only the fake needs this.
export FAKE_BODY
GS="$WORK/gh-store.json"
BODYF="$WORK/marker-body.txt"; FAKE_BODY="$BODYF"
printf '🔒 pr-review-loop running on `h1` <!-- pr-review-loop:running h1 1700000000 -->\n' > "$BODYF"
IDF="$WORK/marker-cid"
# Keep the backoff at 0 so the failure paths don't actually sleep ~60s.
export GH_IO_BACKOFF=0 GH_IO_ATTEMPTS=2

reset_store() { printf '[]' > "$GS"; rm -f "$IDF"; }

# Healthy REST: the ordinary path still works.
reset_store
out="$(PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" 2>/dev/null)"
check "gh-io: post via REST returns id + node" 'printf "%s" "$out" | grep -qx "101 NODE_101"'
check "gh-io: post persists the --id-file"     'grep -qx "101 NODE_101" "$IDF"'

# The incident shape: REST 5xx, GraphQL healthy. Must fall back, not lose the post.
reset_store
out="$(PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=rest-down bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" 2>/dev/null)"
check "gh-io: post falls back to GraphQL when REST 5xx" 'printf "%s" "$out" | grep -qx "101 NODE_101"'
check "gh-io: GraphQL-posted comment is in the store"   'jq -e "length == 1" "$GS" >/dev/null'

# Degraded proxy: REST exits 0 with HTML. The id shape-check must reject it and
# fall back — persisting "<html>" as a comment id would strand the marker forever.
reset_store
out="$(PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=rest-html bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" 2>/dev/null)"
check "gh-io: post rejects an HTML 200 and falls back" 'printf "%s" "$out" | grep -qx "101 NODE_101"'
check "gh-io: id-file never holds an HTML body"        'grep -qx "101 NODE_101" "$IDF"'

# Both down: must exit NON-ZERO. This is the whole point — a swallowed failure
# here is what let reduction#10 report a green run over a locked PR.
reset_store
check "gh-io: post exits nonzero when both APIs are down" \
  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=all-down bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" 2>/dev/null'
check "gh-io: no id-file written on total failure" '[ ! -f "$IDF" ]'

# delete-comment: reads the pair from --id-file, falls back, clears the file.
reset_store
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" >/dev/null 2>&1
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=rest-down bash "$GHIO" delete-comment --repo o/r --id-file "$IDF" >/dev/null 2>&1
check "gh-io: delete falls back to GraphQL"    'jq -e "length == 0" "$GS" >/dev/null'
check "gh-io: delete clears the --id-file"     '[ ! -f "$IDF" ]'

# A 404 is the goal state, not an error — a retry racing its own success, or a
# marker a human already removed, must not fail the run.
reset_store
check "gh-io: delete treats 404 as success" \
  'PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" delete-comment --repo o/r --cid 999 2>/dev/null'
check "gh-io: delete without a node id fails loudly when REST is down" \
  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=rest-down bash "$GHIO" delete-comment --repo o/r --cid 999 2>/dev/null'

# edit-comment: updates body in place, reads --id-file, falls back to GraphQL.
reset_store
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" >/dev/null 2>&1
EDITF="$WORK/edit-body.txt"; printf 'Updated progress: round 2 done\n' > "$EDITF"; FAKE_BODY="$EDITF"
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" edit-comment --repo o/r --id-file "$IDF" --body-file "$EDITF" >/dev/null 2>&1
check "gh-io: edit updates comment body" \
  'jq -e ".[0].body == \"Updated progress: round 2 done\"" "$GS" >/dev/null'
# REST-down: falls back to GraphQL. Use a distinct body so a stale REST-written
# value can't masquerade as proof the GraphQL path actually ran.
EDITF2="$WORK/edit-body-2.txt"; printf 'Updated progress: round 3 done (via graphql)\n' > "$EDITF2"; FAKE_BODY="$EDITF2"
check "gh-io: edit falls back to GraphQL and exits 0" \
  'PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=rest-down bash "$GHIO" edit-comment --repo o/r --id-file "$IDF" --body-file "$EDITF2" >/dev/null 2>&1'
check "gh-io: edit via GraphQL updates comment body" \
  'jq -e ".[0].body == \"Updated progress: round 3 done (via graphql)\"" "$GS" >/dev/null'
# All-down: fails.
check "gh-io: edit fails when both APIs are down" \
  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=all-down bash "$GHIO" edit-comment --repo o/r --id-file "$IDF" --body-file "$EDITF2" 2>/dev/null'
# Empty body: dies.
check "gh-io: edit rejects empty body" \
  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" bash "$GHIO" edit-comment --repo o/r --cid 101 --body-file /dev/null 2>/dev/null'
FAKE_BODY="$BODYF"

# newest-comment-id: the monotonic baseline reconcile scopes its check with.
reset_store
check "gh-io: newest-comment-id is 0 on an empty PR" \
  '[ "$(PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" newest-comment-id --repo o/r --pr 7 2>/dev/null)" = "0" ]'
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" >/dev/null 2>&1
check "gh-io: newest-comment-id returns the max" \
  '[ "$(PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" newest-comment-id --repo o/r --pr 7 2>/dev/null)" = "101" ]'

echo "== gh-io.sh reconcile (the reduction#10 regression) =="
SUMF="$WORK/summary-body.txt"
printf 'CLAUDE: Automated Review Summary\nStatus: CLEAN\n<!-- pr-review-loop:summary -->\n' > "$SUMF"

# Exactly the reduction#10 end state: marker still up, summary never posted.
reset_store
FAKE_BODY="$BODYF"
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" >/dev/null 2>&1
rec="$(PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" reconcile --repo o/r --pr 7 --id-file "$IDF" --after 100 2>&1)"; rc=$?
check "reconcile: exits nonzero on the orphaned-lock end state" '[ "$rc" -ne 0 ]'
check "reconcile: annotates the leftover lock"   'printf "%s" "$rec" | grep -q "::error title=pr-review-loop lock left behind::"'
check "reconcile: annotates the missing summary" 'printf "%s" "$rec" | grep -q "::error title=pr-review-loop summary missing::"'
check "reconcile: actually removes the lock"     'jq -e "length == 0" "$GS" >/dev/null'
check "reconcile: clears the --id-file"          '[ ! -f "$IDF" ]'

# Reconcile must be able to clean up during the very incident that strands the
# lock — REST down is when it is needed most.
reset_store
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" >/dev/null 2>&1
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=rest-down bash "$GHIO" reconcile --repo o/r --pr 7 --id-file "$IDF" --after 100 >/dev/null 2>&1
check "reconcile: removes the lock over GraphQL when REST is down" 'jq -e "length == 0" "$GS" >/dev/null'

# The mirror case exercises the REST comment-list fallback, which is otherwise
# dead code (reconcile reads via GraphQL first). `gh api --slurp` is rejected
# alongside `--jq`, so this is the test that keeps that path honest.
reset_store
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$BODYF" --id-file "$IDF" >/dev/null 2>&1
rec="$(PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=graphql-down bash "$GHIO" reconcile --repo o/r --pr 7 --id-file "$IDF" --after 100 2>&1)"
check "reconcile: lists over REST when GraphQL is down" 'printf "%s" "$rec" | grep -q "lock left behind"'
check "reconcile: removes the lock over REST when GraphQL is down" 'jq -e "length == 0" "$GS" >/dev/null'

# A properly finished loop: marker removed, summary posted → silent success.
reset_store
FAKE_BODY="$SUMF"
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$SUMF" >/dev/null 2>&1
check "reconcile: clean loop exits 0" \
  'PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" reconcile --repo o/r --pr 7 --after 100 2>/dev/null'

# --after is what scopes the check to THIS run: a summary from an EARLIER loop
# on the same PR must not vouch for a run that posted nothing. Without this the
# second reduction#10 run would have passed on the first run's comment.
check "reconcile: a stale summary below --after does not count" \
  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" reconcile --repo o/r --pr 7 --after 101 2>/dev/null'

# The token, not the prose, is the contract — a human comment quoting the
# summary's heading must not satisfy the check.
reset_store
FAKE_BODY="$WORK/prose.txt"
printf 'I looked for the CLAUDE: Automated Review Summary and it never showed up.\n' > "$WORK/prose.txt"
PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" post-comment --repo o/r --pr 7 --body-file "$WORK/prose.txt" >/dev/null 2>&1
check "reconcile: prose about the summary is not a summary" \
  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" FAKE_MODE=ok bash "$GHIO" reconcile --repo o/r --pr 7 --after 100 2>/dev/null'

check "gh-io: bad --repo dies"  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" bash "$GHIO" newest-comment-id --repo notaslug --pr 7 2>/dev/null'
check "gh-io: bad --pr dies"    '! PATH="$BIN:$PATH" FAKE_STORE="$GS" bash "$GHIO" newest-comment-id --repo o/r --pr x 2>/dev/null'
check "gh-io: empty body dies"  '! PATH="$BIN:$PATH" FAKE_STORE="$GS" bash "$GHIO" post-comment --repo o/r --pr 7 --body-file /dev/null 2>/dev/null'
check "gh-io: unknown subcommand dies" '! PATH="$BIN:$PATH" FAKE_STORE="$GS" bash "$GHIO" frobnicate 2>/dev/null'
fi

echo "== loop-state.sh (counters + exit decision) =="
# Every cap the skill defines was prose on f1-predictions#1155 and every one
# failed: the per-run cap was sidestepped by a self-started second run, the
# per-PR budget was never evaluated, the fix-induced streak never mentioned.
# The counters and the verdict now live here, so each rule is pinned.
LS="$DIR/loop-state.sh"
ST="$WORK/ls-state"; RF="$WORK/ls-rounds"; mkdir -p "$ST"
check "init writes the state file"      'bash "$LS" init --state "$ST/state" --rounds-file "$RF" --prior-rounds 2 >/dev/null && [ -f "$ST/state" ]'
check "init refuses a second init"      '! bash "$LS" init --state "$ST/state" --rounds-file "$RF" --prior-rounds 2 2>/dev/null'
check "init rejects a non-numeric prior" '! bash "$LS" init --state "$WORK/ls-x" --rounds-file "$RF" --prior-rounds abc 2>/dev/null'
check "init requires --rounds-file"     '! bash "$LS" init --state "$WORK/ls-y" --prior-rounds 0 2>/dev/null'
check "init warns when the PR is already over budget" 'bash "$LS" init --state "$WORK/ls-over" --rounds-file "$RF" --prior-rounds 12 2>&1 | grep -q "WARNING"'
check "get ITERATION starts at 0"       '[ "$(bash "$LS" get --state "$ST/state" ITERATION)" = "0" ]'
check "get ROUNDS_INCLUDING_CURRENT is prior+1" '[ "$(bash "$LS" get --state "$ST/state" ROUNDS_INCLUDING_CURRENT)" = "3" ]'
check "get SFH_EFFORT is high at start"  '[ "$(bash "$LS" get --state "$ST/state" SFH_EFFORT)" = "high" ]'
check "get unknown key dies"            '! bash "$LS" get --state "$ST/state" NOPE 2>/dev/null'
check "get without state file dies"     '! bash "$LS" get --state "$WORK/no-such-state" ITERATION 2>/dev/null'
check "set LAST_FIX_BASE_SHA accepts hex" 'bash "$LS" set --state "$ST/state" LAST_FIX_BASE_SHA abc1234 >/dev/null && [ "$(bash "$LS" get --state "$ST/state" LAST_FIX_BASE_SHA)" = "abc1234" ]'
check "set rejects a non-hex sha"        '! bash "$LS" set --state "$ST/state" LAST_FIX_BASE_SHA "not a sha" 2>/dev/null'
check "set rejects a counter"            '! bash "$LS" set --state "$ST/state" ITERATION 5 2>/dev/null'
check "set rejects a bad fix class"      '! bash "$LS" set --state "$ST/state" LAST_FIX_CLASS nope 2>/dev/null'
# ── triage (Phase 2): the diminishing-returns exit ──
tri() { bash "$LS" triage --state "$ST/state" "$@"; }
check "triage never exits on round 0"    '[ "$(tri --criticals 0 --findings 2 --fix-induced 0 --coverage-only 2)" = "FIX" ]'
check "triage rejects buckets > findings" '! tri --criticals 0 --findings 1 --fix-induced 1 --coverage-only 1 2>/dev/null'
re() { bash "$LS" round-end --state "$ST/state" "$@"; }
out="$(re --criticals 1 --findings 3 --fix-induced 0 --coverage-only 1 --pushed-back 0 --fixed 3 --code-changed 1 --fix-class prod --scoped 0)"
check "round 0 with a CRITICAL continues full" '[ "$out" = "CONTINUE scoped=0 severity_floor=0 sfh_effort=high" ]'
check "round-end advances ITERATION"     '[ "$(bash "$LS" get --state "$ST/state" ITERATION)" = "1" ]'
check "round-end persists prior+iter to the rounds file" '[ "$(cat "$RF")" = "3" ]'
check "triage: all fix-induced/coverage after round 0 exits" '[ "$(tri --criticals 0 --findings 2 --fix-induced 1 --coverage-only 1)" = "EXIT NEEDS_HUMAN_REVIEW diminishing-returns" ]'
check "triage: one substantive finding keeps fixing" '[ "$(tri --criticals 0 --findings 3 --fix-induced 1 --coverage-only 1)" = "FIX" ]'
check "triage: a CRITICAL keeps fixing"  '[ "$(tri --criticals 1 --findings 1 --fix-induced 1 --coverage-only 0)" = "FIX" ]'
check "triage: a scoped round keeps fixing" '[ "$(tri --scoped 1 --criticals 0 --findings 1 --fix-induced 1 --coverage-only 0)" = "FIX" ]'
check "triage: zero findings is FIX (nothing to do)" '[ "$(tri --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0)" = "FIX" ]'
# ── round-end (Phase 4): next-round type, streaks, floor ──
out="$(re --criticals 0 --findings 2 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 2 --code-changed 1 --fix-class tests --scoped 0)"
check "tests-only fix after a clean review earns a scoped verify" '[ "$out" = "CONTINUE scoped=1 severity_floor=0 sfh_effort=medium" ]'
out="$(re --criticals 0 --findings 1 --fix-induced 1 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 1)"
check "scoped round with a finding escalates to a full batch" 'printf "%s" "$out" | grep -q "^CONTINUE scoped=0"'
check "scoped round does not earn severity-floor credit" 'printf "%s" "$out" | grep -q "severity_floor=0"'
out="$(re --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 0)"
check "second clean full round raises the severity floor" 'printf "%s" "$out" | grep -q "severity_floor=1"'
check "a substantive finding resets the fix-induced streak" '[ "$(bash "$LS" get --state "$ST/state" FIX_INDUCED_ROUNDS)" = "0" ]'
out="$(re --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 1 --fixed 0 --code-changed 0 --fix-class tests --scoped 0)"
check "no code change + 0 CRITICAL is CLEAN (clean-on-pushback)" 'printf "%s" "$out" | grep -q "^EXIT CLEAN"'
check "an empty change set is forced to prod class" '[ "$(bash "$LS" get --state "$ST/state" LAST_FIX_CLASS)" = "prod" ]'
check "round-end refuses to run after an exit" '! re --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 2>/dev/null'
# validation-fix: the CLEAN gate failed, a fix was pushed — void the CLEAN, count nothing
out="$(bash "$LS" validation-fix --state "$ST/state" --fix-class tests)"
check "validation-fix sets scoped next without counting a round" '[ "$out" = "CONTINUE scoped=1 severity_floor=1 sfh_effort=medium" ] && [ "$(bash "$LS" get --state "$ST/state" ITERATION)" = "5" ]'
check "validation-fix voids the CLEAN"   '[ -z "$(bash "$LS" get --state "$ST/state" EXIT_STATUS)" ]'
check "round-end runs again after validation-fix" 're --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 1 | grep -q "^EXIT CLEAN"'
# ── every exit status, each on a fresh state ──
fresh() { rm -rf "$WORK/ls-$1"; mkdir -p "$WORK/ls-$1"; bash "$LS" init --state "$WORK/ls-$1/state" --rounds-file "$WORK/ls-$1/rounds" "${@:2}" >/dev/null 2>&1; }
rend() { bash "$LS" round-end --state "$WORK/ls-$1/state" "${@:2}"; }
fresh standoff --prior-rounds 0
check "declined CRITICAL with no change → NEEDS_HUMAN_REVIEW" 'rend standoff --criticals 1 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 1 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 | grep -q "^EXIT NEEDS_HUMAN_REVIEW critical-declined"'
check "validation-fix refuses after a non-CLEAN exit" '! bash "$LS" validation-fix --state "$WORK/ls-standoff/state" --fix-class tests >/dev/null 2>&1'
fresh maxit --prior-rounds 0 --max-iterations 2
rend maxit --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 0 >/dev/null
check "per-run cap → MAX_ITERATIONS_REACHED" 'rend maxit --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 0 | grep -q "^EXIT MAX_ITERATIONS_REACHED"'
fresh budget --prior-rounds 11 --max-pr-rounds 12
check "per-PR budget counts prior rounds → FIX_BUDGET_EXHAUSTED" 'rend budget --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 0 | grep -q "^EXIT FIX_BUDGET_EXHAUSTED pr-rounds"'
check "budget exit still persists the lifetime count" '[ "$(cat "$WORK/ls-budget/rounds")" = "12" ]'
fresh cleanlast --prior-rounds 11 --max-pr-rounds 12
check "CLEAN outranks the budget on the last allowed round" 'rend cleanlast --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 | grep -q "^EXIT CLEAN"'
fresh streak --prior-rounds 0 --max-fix-induced 2
rend streak --criticals 0 --findings 1 --fix-induced 0 --coverage-only 1 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 0 >/dev/null
check "fix-induced streak backstop → FIX_BUDGET_EXHAUSTED" 'rend streak --criticals 0 --findings 2 --fix-induced 1 --coverage-only 1 --pushed-back 0 --fixed 2 --code-changed 1 --fix-class prod --scoped 0 | grep -q "^EXIT FIX_BUDGET_EXHAUSTED fix-induced"'
fresh timed --prior-rounds 0 --timeout 1
sleep 2
check "wall clock → TIMED_OUT"           'rend timed --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 0 | grep -q "^EXIT TIMED_OUT"'
fresh wdk --prior-rounds 0
check "all agents watchdog-killed → CODEX_DEGRADED" 'rend wdk --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 --all-watchdog-killed | grep -q "^EXIT CODEX_DEGRADED"'
fresh forced --prior-rounds 4
check "forced exit is echoed verbatim"   '[ "$(rend forced --criticals 0 --findings 2 --fix-induced 1 --coverage-only 1 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 --forced-exit NEEDS_HUMAN_REVIEW:diminishing-returns)" = "EXIT NEEDS_HUMAN_REVIEW diminishing-returns" ]'
check "forced exit still counts the round" '[ "$(cat "$WORK/ls-forced/rounds")" = "5" ]'
fresh args --prior-rounds 0
check "round-end rejects a bad --code-changed" '! rend args --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed yes --fix-class prod --scoped 0 2>/dev/null'
check "round-end rejects a bad --fix-class" '! rend args --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 1 --fix-class nope --scoped 0 2>/dev/null'
check "round-end rejects a missing count" '! rend args --criticals 0 --findings 0 --pushed-back 0 --code-changed 1 --fix-class prod --scoped 0 2>/dev/null'
check "a corrupt state file dies, not silently resets" 'printf "BOGUS=1\n" > "$WORK/ls-args/state" && ! bash "$LS" get --state "$WORK/ls-args/state" ITERATION 2>/dev/null'

# save()'s write must not be swallowed: no caller checks its exit status, so a
# failure that used to fall through silently would let round-end (or `set`)
# print a verdict while the counters it just decided on were never persisted.
fresh savefail --prior-rounds 0
chmod 555 "$WORK/ls-savefail"
check "save failure dies instead of silently dropping state" \
  '! bash "$LS" set --state "$WORK/ls-savefail/state" LAST_FIX_BASE_SHA abc1234 2>/dev/null'
chmod 755 "$WORK/ls-savefail"

# write_rounds_file()'s mkdir -p can fail too (a path component is a regular
# file, not a directory) — that failure must die just like save()'s, not just
# emit a verdict with the lifetime round count silently left stale.
rm -rf "$WORK/ls-roundsfail"; mkdir -p "$WORK/ls-roundsfail"
printf 'x' > "$WORK/ls-roundsfail-blocker"
bash "$LS" init --state "$WORK/ls-roundsfail/state" --rounds-file "$WORK/ls-roundsfail-blocker/rounds" --prior-rounds 0 >/dev/null 2>&1
check "write_rounds_file failure dies instead of silently dropping the count" \
  '! bash "$LS" round-end --state "$WORK/ls-roundsfail/state" --criticals 0 --findings 0 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 2>/dev/null'

# An unresolved finding (neither fixed nor pushed back) must never reach the
# CLEAN branch just because --code-changed is 0 — that would silently accept
# an IMPORTANT finding no one engaged with.
fresh unaccounted --prior-rounds 0
check "unaccounted finding with no code change dies, not CLEAN" \
  '! rend unaccounted --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 2>/dev/null'
fresh overpushed --prior-rounds 0
check "--pushed-back exceeding --findings dies" \
  '! rend overpushed --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 2 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 2>/dev/null'
fresh forcedunaccounted --prior-rounds 0
check "forced-exit bypasses the pushed-back requirement" \
  'rend forcedunaccounted --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 0 --code-changed 0 --fix-class prod --scoped 0 --forced-exit NEEDS_HUMAN_REVIEW:diminishing-returns | grep -q "^EXIT NEEDS_HUMAN_REVIEW"'
# A round CAN change code and still silently drop a finding: fixing one of two
# IMPORTANTs and reporting neither a matching --fixed nor a --pushed-back for
# the second must be rejected too, not just the --code-changed 0 case above.
fresh partial --prior-rounds 0
check "code-changed round accounting for only some findings dies" \
  '! rend partial --criticals 0 --findings 2 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 1 --fix-class prod --scoped 0 2>/dev/null'
fresh mixed --prior-rounds 0
check "mixed fixed + pushed-back accounting for all findings succeeds" \
  'rend mixed --criticals 0 --findings 2 --fix-induced 0 --coverage-only 0 --pushed-back 1 --fixed 1 --code-changed 1 --fix-class prod --scoped 0 | grep -q "^CONTINUE"'
fresh fixedwithoutcode --prior-rounds 0
check "--fixed > 0 with --code-changed 0 dies" \
  '! rend fixedwithoutcode --criticals 0 --findings 1 --fix-induced 0 --coverage-only 0 --pushed-back 0 --fixed 1 --code-changed 0 --fix-class prod --scoped 0 2>/dev/null'

echo "== diff-size.sh (PR-size gate + test budget) =="
# f1-predictions#1155 started at 3,900 added lines; a packet that size never
# converges and the repo's "split before labeling" rule was not followed. The
# gate counts what a reviewer reads — JSON, lockfiles, binaries and friends are
# artifacts — and the --since mode is the fixer's test budget (Phase 3).
DS="$DIR/diff-size.sh"
FS="$WORK/fixture-size"
git init -q -b main "$FS" 2>/dev/null || { git init -q "$FS"; git -C "$FS" checkout -qb main; }
git -C "$FS" config user.email t@t; git -C "$FS" config user.name t
mkdir -p "$FS/src" "$FS/tests" "$FS/data"
printf 'base\n' > "$FS/src/a.py"; printf 'x\n' > "$FS/data/big.json"
git -C "$FS" add -A; git -C "$FS" commit -qm base
git -C "$FS" checkout -qb feature
seq 1 10 > "$FS/src/a.py"                       # +10 -1 prod
seq 1 4  > "$FS/tests/test_a.py"                # +4 tests
seq 1 100 > "$FS/data/big.json"                 # +100 -1 artifact (json)
seq 1 50 > "$FS/poetry.lock"                    # +50 artifact (lockfile)
printf '\211PNG\000\001bin\000' > "$FS/img.png"   # binary
seq 1 7 > "$FS/notes.md"                        # +7 counted (docs are read)
git -C "$FS" add -A; git -C "$FS" commit -qm "author"
LOOPSTART="$(git -C "$FS" rev-parse HEAD)"
seq 1 13 > "$FS/src/a.py"                       # loop: +3 prod
seq 1 12 > "$FS/tests/test_a.py"                # loop: +8 tests
git -C "$FS" mv data/big.json data/moved.json; seq 1 105 > "$FS/data/moved.json"   # renamed artifact, +5
git -C "$FS" add -A; git -C "$FS" commit -qm "loop fixes"
out="$(bash "$DS" --repo "$FS" --base-ref main --since "$LOOPSTART")"; rc=$?
kv() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
check "size: counts reviewable lines only"     '[ "$(kv counted_added)" = "32" ]'
check "size: excludes json + lockfile lines"   '[ "$(kv excluded_added)" = "155" ]'
# 4 = the lockfile, the binary, and the json seen as delete+add (base→HEAD has
# no rename: the 1-line base file and the 105-line result share nothing).
check "size: excluded file count includes binary" '[ "$(kv excluded_files)" = "4" ]'
check "size: renamed artifact stays excluded"  '! printf "%s" "$out" | grep -q "moved.json"'
check "size: default verdict OK"               '[ "$(kv verdict)" = "OK" ] && [ "$rc" -eq 0 ]'
check "size: loop prod lines since start"      '[ "$(kv loop_prod_added)" = "3" ]'
check "size: loop test lines since start"      '[ "$(kv loop_test_added)" = "8" ]'
check "size: test budget EXCEEDED when tests > prod" '[ "$(kv test_budget)" = "EXCEEDED" ]'
check "size: lists top counted files"          'printf "%s" "$out" | grep -q "src/a.py"'
check "size: no --since → no budget keys"      '[ -z "$(bash "$DS" --repo "$FS" --base-ref main | sed -n "s/^test_budget=//p")" ]'
out="$(bash "$DS" --repo "$FS" --base-ref main --warn 30)"; rc=$?
check "size: WARN at the warn threshold, exit 0" '[ "$(kv verdict)" = "WARN" ] && [ "$rc" -eq 0 ]'
out="$(bash "$DS" --repo "$FS" --base-ref main --warn 10 --stop 30)"; rc=$?
check "size: STOP at the stop threshold, exit 3" '[ "$(kv verdict)" = "STOP" ] && [ "$rc" -eq 3 ]'
out="$(bash "$DS" --repo "$FS" --base-ref main --warn 10 --stop 0)"; rc=$?
check "size: --stop 0 disables the stop"       '[ "$(kv verdict)" = "WARN" ] && [ "$rc" -eq 0 ]'
out="$(PR_SIZE_EXCLUDE='*.md' bash "$DS" --repo "$FS" --base-ref main)"
check "size: PR_SIZE_EXCLUDE adds a pattern"   '[ "$(kv counted_added)" = "25" ]'
out="$(bash "$DS" --repo "$FS" --base-ref main --exclude 'notes.md' --exclude 'tests/*')"
check "size: --exclude is repeatable"          '[ "$(kv counted_added)" = "13" ]'
check "size: test budget on a prod-heavy loop is OK" '[ "$(bash "$DS" --repo "$FS" --base-ref main --since "$LOOPSTART" --exclude "tests/*" | sed -n "s/^test_budget=//p")" = "OK" ]'
check "size: unresolvable base dies"           '! bash "$DS" --repo "$FS" --base-ref nope 2>/dev/null'
check "size: unresolvable --since dies"        '! bash "$DS" --repo "$FS" --base-ref main --since nope 2>/dev/null'
check "size: non-numeric threshold dies"       '! bash "$DS" --repo "$FS" --base-ref main --warn lots 2>/dev/null'
check "size: not-a-repo dies"                  '! bash "$DS" --repo "$WORK" --base-ref main 2>/dev/null'
# Both refs can resolve individually yet share no merge base (e.g. a shallow
# checkout truncated past the divergence point) — `git diff A...B` then fails
# outright rather than returning nothing. Feeding that failure straight into a
# process substitution used to be invisible to the caller: the while-read loop
# just saw zero lines and reported counted_added=0 / verdict=OK.
UNREL="$WORK/fixture-unrelated"
git init -q -b main "$UNREL" 2>/dev/null || { git init -q "$UNREL"; git -C "$UNREL" checkout -qb main; }
git -C "$UNREL" config user.email t@t; git -C "$UNREL" config user.name t
printf 'a\n' > "$UNREL/a.txt"; git -C "$UNREL" add -A; git -C "$UNREL" commit -qm main-root
git -C "$UNREL" checkout -q --orphan other >/dev/null 2>&1
git -C "$UNREL" rm -rf --cached . -q >/dev/null 2>&1
printf 'b\n' > "$UNREL/b.txt"; git -C "$UNREL" add -A; git -C "$UNREL" commit -qm other-root
check "size: no merge base dies instead of reporting a silent zero" \
  '! bash "$DS" --repo "$UNREL" --base-ref main 2>/dev/null'

echo "== 0.15.0 wiring (rounds across comments, base-ref hand-off, prompt rules) =="
# The CI run on #1155 completed 7 rounds, died on the wall clock, and the next
# run started from PRIOR_ROUNDS=0: the count lived only in a summary that was
# never posted. The progress comment now carries the marker too, and Phase 0
# reads the MAX across every comment.
MULTI="$(printf '<!-- pr-review-loop:rounds 7 -->\nprogress\n<!-- pr-review-loop:rounds 12 -->\n<!-- pr-review-loop:rounds 3 -->\n')"
check "rounds-total takes the max of several markers" '[ "$(printf "%s" "$MULTI" | bash "$HIO" rounds-total "$WORK/nonexistent")" = "12" ]'
check "rounds-total: file still wins when ahead"      '[ "$(printf "%s" "$MULTI" | bash "$HIO" rounds-total "$WORK/rounds-file.txt")" = "13" ]'
if command -v jq >/dev/null 2>&1; then
  printf '%s' '{"comments":[{"body":"<!-- pr-review-loop:rounds 4 -->"},{"body":"<!-- pr-review-loop:progress -->\n<!-- pr-review-loop:rounds 9 -->"},{"body":"chat"}]}' > "$WORK/comments-rounds.json"
  check "rounds-filter + rounds-total read every comment" '[ "$(jq -r "$(bash "$HIO" rounds-filter)" < "$WORK/comments-rounds.json" | bash "$HIO" rounds-total "$WORK/nonexistent")" = "9" ]'
fi
check "refresh-packet writes base-ref.txt"           '[ "$(cat "$PK/base-ref.txt")" = "origin/main" ]'
check "diff-size accepts the packet base ref"        'bash "$DS" --repo "$FS" --base-ref "$(git -C "$FS" rev-parse main)" >/dev/null'
check "test-analyzer: coverage is SUGGESTION by default" 'grep -q "SUGGESTION by default" "$RC/prompt-test-analyzer.txt"'
check "test-analyzer: no test requests for the previous fix" 'grep -q "PREVIOUS round" "$RC/prompt-test-analyzer.txt"'
check "test-analyzer: one IMPORTANT per round after round 0" 'grep -q "ONE IMPORTANT/CRITICAL finding per round" "$RC/prompt-test-analyzer.txt"'
check "packet preamble: coverage-only rule is shared" 'grep -q "COVERAGE-ONLY finding" "$RC/prompt-silent-failure-hunter.txt"'
check "code-reviewer no longer owns coverage gaps" 'grep -q "coverage gaps belong to the test-analyzer" "$RC/prompt-code-reviewer.txt"'

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
