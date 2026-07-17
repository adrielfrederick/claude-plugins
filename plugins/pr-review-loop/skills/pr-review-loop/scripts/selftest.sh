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

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
