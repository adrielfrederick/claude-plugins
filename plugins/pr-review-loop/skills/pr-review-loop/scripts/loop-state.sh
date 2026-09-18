#!/usr/bin/env bash
#
# loop-state.sh — the loop's counters and its exit decision, kept in a file and
# computed by a script, never re-derived by the model from memory.
#
# Why: on f1-predictions#1155 (2026-09-17) every cap the skill defines failed
# for a different reason, and all of them were prose the model had to remember:
#   - MAX_ITERATIONS fired at 10 and the driver started "run 2" itself, quoting
#     the skill's own line that a fresh run resets the per-run cap.
#   - MAX_PR_ROUNDS (12) should have stopped that second run after two rounds;
#     the transcript never evaluates the total once — Phase 4 step 3a was just
#     skipped in a 17-round context.
#   - FIX_INDUCED_ROUNDS was never mentioned in 17 rounds, though the last four
#     matched its definition exactly.
# The PR ended with 24 review rounds and 1,825 added test lines against 1,172
# added production lines. Counters that live "in your conversation" do not
# survive a long context; counters in a file do, and a decision printed by a
# script is one the model obeys rather than re-litigates.
#
# Usage:
#   loop-state.sh init --state F --rounds-file F --prior-rounds N
#                      [--max-iterations 10] [--max-pr-rounds 12]
#                      [--max-fix-induced 3] [--timeout 3600]
#       Creates the state file. Refuses to overwrite one (a run is initialised
#       once; a second `init` in the same run dir is the "start run 2 myself"
#       mistake this script exists to close).
#   loop-state.sh get  --state F KEY          → the value (derived keys below)
#   loop-state.sh set  --state F KEY VALUE    → for the few model-owned keys
#   loop-state.sh show --state F              → every key
#   loop-state.sh triage --state F --criticals N --findings N \
#                        --fix-induced N --coverage-only N [--scoped 0|1]
#       Called after Phase 2 aggregation, BEFORE any fix. Prints
#         FIX                                       — address the findings
#         EXIT NEEDS_HUMAN_REVIEW diminishing-returns — stop; hand the list over
#       The exit fires when the round is not round 0, has no CRITICAL, and every
#       finding is fix-induced or coverage-only. That is the tail-chasing
#       signature: each round hardens the previous round's hardening. Nothing is
#       counted here; the caller records the round with `round-end --forced-exit`.
#   loop-state.sh round-end --state F --criticals N --findings N \
#                        --fix-induced N --coverage-only N --pushed-back N \
#                        --fixed N --code-changed 0|1 --fix-class tests|docs|prod \
#                        --scoped 0|1 [--all-watchdog-killed] \
#                        [--forced-exit STATUS:reason]
#       Called once per round from Phase 4. Advances the counters, persists the
#       PR's lifetime round count to --rounds-file, and prints ONE line:
#         CONTINUE scoped=0|1 severity_floor=0|1 sfh_effort=high|medium
#         EXIT <STATUS> <reason>
#       Unless --forced-exit is given, requires --fixed + --pushed-back to
#       equal --findings exactly (every finding fixed or explicitly declined —
#       none silently dropped) and --fixed to be 0 when --code-changed is 0
#       (a fix without a code change is a contradiction).
#   loop-state.sh validation-fix --state F --fix-class tests|docs|prod
#       After the CLEAN-gate full validation failed and a fix was pushed: sets
#       the next round's type from the fix class without counting a round.
#
# Finding buckets (every finding lands in exactly one):
#   substantive   — about the PR's own code, or a real bug a fix introduced
#   fix-induced   — "the previous round's fix could also handle X": an edge
#                   case of a fix, not a bug in it (the packet already tells
#                   reviewers this is drift)
#   coverage-only — asks for a test and names no bug in current code
# --fix-induced and --coverage-only are therefore disjoint counts.
#
# Exit decision order in round-end (first match wins):
#   1. --forced-exit                       → EXIT as given (triage / caller)
#   2. every agent watchdog-killed         → EXIT CODEX_DEGRADED
#   3. no code change AND 0 CRITICAL       → EXIT CLEAN (classic, scoped-clean
#                                            and clean-on-pushback are all this)
#   4. no code change AND a CRITICAL       → EXIT NEEDS_HUMAN_REVIEW
#                                            critical-declined (a standoff on a
#                                            CRITICAL is a human's call)
#   5. wall clock                          → EXIT TIMED_OUT
#   6. ITERATION >= MAX_ITERATIONS         → EXIT MAX_ITERATIONS_REACHED
#   7. PR_ROUNDS_TOTAL >= MAX_PR_ROUNDS    → EXIT FIX_BUDGET_EXHAUSTED pr-rounds
#   8. FIX_INDUCED_ROUNDS >= MAX           → EXIT FIX_BUDGET_EXHAUSTED fix-induced
#   9. otherwise                           → CONTINUE
# CLEAN sits above the caps: a round that converged is CLEAN even if it was the
# last one the budget allowed. The caller still runs the full-validation gate
# before honouring a CLEAN (SKILL.md Phase 4).
#
# Removed relative to 0.14.0: the "CONSECUTIVE_CLEAN_ROUNDS >= 3 ⇒ CLEAN" exit.
# It could fire on a round that changed code, shipping fixes no reviewer had
# seen — the exact thing the 0.7.0 note forbids. The streak still drives the
# severity floor and the silent-failure-hunter effort.
set -u

die() { echo "loop-state.sh: $*" >&2; exit 1; }
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

STATE=""
# Keys are stored in plain variables ST_<KEY> (macOS ships bash 3.2, which has
# no associative arrays). KEYS is the closed set the file may hold.
KEYS="ITERATION START_TIME PRIOR_ROUNDS PR_ROUNDS_TOTAL CONSECUTIVE_CLEAN_ROUNDS FIX_INDUCED_ROUNDS SEVERITY_FLOOR_ACTIVE SCOPED_NEXT LAST_FIX_CLASS LAST_FIX_BASE_SHA MAX_ITERATIONS MAX_PR_ROUNDS MAX_FIX_INDUCED_ROUNDS TIMEOUT_SECONDS ROUNDS_FILE EXIT_STATUS EXIT_REASON"
known_key() { case " $KEYS " in *" $1 "*) return 0;; *) return 1;; esac; }
sget() { local n="ST_$1"; printf '%s' "${!n-}"; }
sset() { known_key "$1" || die "internal: unknown key $1"; printf -v "ST_$1" '%s' "$2"; }

load() {
  [ -n "$STATE" ] || die "--state is required"
  [ -f "$STATE" ] || die "state file not found: $STATE (run 'loop-state.sh init' in Phase 0)"
  local k v
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    case "$k" in \#*) continue;; esac
    known_key "$k" || die "corrupt state file $STATE: unknown key '$k'"
    sset "$k" "$v"
  done < "$STATE"
}

save() {
  local tmp="$STATE.tmp" k
  # No caller checks save's exit status (there's no `set -e`), so a swallowed
  # write/mv failure here would let round-end print CONTINUE/EXIT while the
  # counters it just decided on were never persisted — exactly the class of
  # silent-failure this script exists to replace ("counters in a file... a
  # decision the model obeys", see the header). die loudly instead.
  {
    echo "# pr-review-loop state — written by loop-state.sh; do not edit by hand"
    for k in $KEYS; do printf '%s=%s\n' "$k" "$(sget "$k")"; done
  } > "$tmp" || die "failed to write state to $tmp"
  mv "$tmp" "$STATE" || die "failed to persist state: mv $tmp -> $STATE"
}

req_num() { is_num "${2:-}" || die "$1 must be a non-negative integer (got '${2:-}')"; }

write_rounds_file() {
  local f; f="$(sget ROUNDS_FILE)"
  [ -n "$f" ] || return 0
  mkdir -p "$(dirname "$f")" || die "failed to create directory for rounds file: $(dirname "$f")"
  printf '%s\n' "$(sget PR_ROUNDS_TOTAL)" > "$f" || die "failed to write rounds file: $f"
}
sfh_effort() { [ "$(sget CONSECUTIVE_CLEAN_ROUNDS)" -ge 1 ] && echo medium || echo high; }

cmd="${1:-}"; shift || true

# ── argument parsing shared by the subcommands ─────────────────────────────
PRIOR=""; MAXI=10; MAXPR=12; MAXFI=3; TIMEOUT=3600; ROUNDS_FILE=""
CRIT=""; FIND=""; FIXI=""; COV=""; PUSHED=""; FIXED=""; CODE=""; CLASS=""; SCOPED=0; WDK=0; FORCED=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --state)         STATE="${2:-}"; shift 2 ;;
    --rounds-file)   ROUNDS_FILE="${2:-}"; shift 2 ;;
    --prior-rounds)  PRIOR="${2:-}"; shift 2 ;;
    --max-iterations) MAXI="${2:-}"; shift 2 ;;
    --max-pr-rounds) MAXPR="${2:-}"; shift 2 ;;
    --max-fix-induced) MAXFI="${2:-}"; shift 2 ;;
    --timeout)       TIMEOUT="${2:-}"; shift 2 ;;
    --criticals)     CRIT="${2:-}"; shift 2 ;;
    --findings)      FIND="${2:-}"; shift 2 ;;
    --fix-induced)   FIXI="${2:-}"; shift 2 ;;
    --coverage-only) COV="${2:-}"; shift 2 ;;
    --pushed-back)   PUSHED="${2:-}"; shift 2 ;;
    --fixed)         FIXED="${2:-}"; shift 2 ;;
    --code-changed)  CODE="${2:-}"; shift 2 ;;
    --fix-class)     CLASS="${2:-}"; shift 2 ;;
    --scoped)        SCOPED="${2:-}"; shift 2 ;;
    --all-watchdog-killed) WDK=1; shift ;;
    --forced-exit)   FORCED="${2:-}"; shift 2 ;;
    --*)             die "unknown argument: $1" ;;
    *)               POS+=("$1"); shift ;;
  esac
done

case "$cmd" in
  init)
    [ -n "$STATE" ] || die "--state is required"
    [ ! -e "$STATE" ] || die "state file already exists: $STATE — a run is initialised once. If the previous run of this loop exited on a cap, this session is done: a new run needs a human re-label / re-invocation, not a second init."
    [ -n "$ROUNDS_FILE" ] || die "--rounds-file is required (the PR-lifetime round counter, \$PR_ROOT/rounds-total)"
    req_num --prior-rounds "$PRIOR"
    req_num --max-iterations "$MAXI"; req_num --max-pr-rounds "$MAXPR"
    req_num --max-fix-induced "$MAXFI"; req_num --timeout "$TIMEOUT"
    [ "$MAXI" -gt 0 ] && [ "$MAXPR" -gt 0 ] && [ "$MAXFI" -gt 0 ] && [ "$TIMEOUT" -gt 0 ] \
      || die "every cap must be > 0"
    mkdir -p "$(dirname "$STATE")"
    sset ITERATION 0; sset START_TIME "$(date +%s)"; sset PRIOR_ROUNDS "$PRIOR"
    sset PR_ROUNDS_TOTAL "$PRIOR"; sset CONSECUTIVE_CLEAN_ROUNDS 0; sset FIX_INDUCED_ROUNDS 0
    sset SEVERITY_FLOOR_ACTIVE 0; sset SCOPED_NEXT 0; sset LAST_FIX_CLASS prod; sset LAST_FIX_BASE_SHA ""
    sset MAX_ITERATIONS "$MAXI"; sset MAX_PR_ROUNDS "$MAXPR"; sset MAX_FIX_INDUCED_ROUNDS "$MAXFI"
    sset TIMEOUT_SECONDS "$TIMEOUT"; sset ROUNDS_FILE "$ROUNDS_FILE"; sset EXIT_STATUS ""; sset EXIT_REASON ""
    save
    if [ "$PRIOR" -ge "$MAXPR" ]; then
      echo "loop-state.sh: WARNING — this PR has already had $PRIOR rounds (budget $MAXPR); the first round-end will exit FIX_BUDGET_EXHAUSTED." >&2
    fi
    echo "state initialised: $STATE (prior_rounds=$PRIOR max_iterations=$MAXI max_pr_rounds=$MAXPR max_fix_induced=$MAXFI timeout=${TIMEOUT}s)"
    ;;

  get)
    load
    key="${POS[0]:-}"; [ -n "$key" ] || die "get needs a KEY"
    case "$key" in
      # Derived keys — computed, never stored, so they cannot go stale.
      ROUNDS_INCLUDING_CURRENT) echo $(( $(sget PRIOR_ROUNDS) + $(sget ITERATION) + 1 )) ;;
      SFH_EFFORT) sfh_effort ;;
      ELAPSED_SECONDS) echo $(( $(date +%s) - $(sget START_TIME) )) ;;
      *) known_key "$key" || die "unknown key: $key"; printf '%s\n' "$(sget "$key")" ;;
    esac
    ;;

  set)
    load
    key="${POS[0]:-}"; val="${POS[1]:-}"
    [ -n "$key" ] || die "set needs KEY VALUE"
    case "$key" in
      LAST_FIX_CLASS) case "$val" in tests|docs|prod) ;; *) die "LAST_FIX_CLASS must be tests|docs|prod";; esac ;;
      LAST_FIX_BASE_SHA) [[ "$val" =~ ^[0-9a-f]{7,40}$ ]] || die "LAST_FIX_BASE_SHA must be a hex SHA" ;;
      *) die "'$key' is not model-settable — counters are advanced by round-end only" ;;
    esac
    sset "$key" "$val"; save
    ;;

  show)
    load
    for k in $KEYS; do printf '%s=%s\n' "$k" "$(sget "$k")"; done
    ;;

  triage)
    load
    req_num --criticals "$CRIT"; req_num --findings "$FIND"
    req_num --fix-induced "$FIXI"; req_num --coverage-only "$COV"
    [ "$CRIT" -le "$FIND" ] || die "--criticals ($CRIT) exceeds --findings ($FIND): criticals are a subset of findings"
    [ $(( FIXI + COV )) -le "$FIND" ] || die "--fix-induced + --coverage-only ($((FIXI + COV))) exceeds --findings ($FIND): the buckets are disjoint, classify each finding once"
    case "$SCOPED" in 0|1) ;; *) die "--scoped must be 0 or 1";; esac
    # Round 0 has no previous fix to chase, and a coverage-only round 0 is
    # answered by the Phase 3 decline rules, not by stopping. A scoped verify
    # reviews only a tests/docs delta, so its findings are about that fix by
    # construction — they are cheap to address and escalate normally.
    if [ "$(sget ITERATION)" -ge 1 ] && [ "$SCOPED" = "0" ] && [ "$CRIT" -eq 0 ] \
       && [ "$FIND" -gt 0 ] && [ $(( FIXI + COV )) -ge "$FIND" ]; then
      echo "EXIT NEEDS_HUMAN_REVIEW diminishing-returns"
    else
      echo "FIX"
    fi
    ;;

  validation-fix)
    load
    # Only meaningful right after a CLEAN: the full-validation gate ran, failed,
    # and a fix was pushed. The CLEAN is void (the fix is unreviewed), so clear
    # it and let the next round-end decide afresh. No round is counted.
    case "$(sget EXIT_STATUS)" in
      CLEAN|"") ;;
      *) die "validation-fix only follows a CLEAN exit (this run exited $(sget EXIT_STATUS))" ;;
    esac
    case "$CLASS" in tests|docs) sset SCOPED_NEXT 1 ;; prod) sset SCOPED_NEXT 0 ;; *) die "--fix-class must be tests|docs|prod";; esac
    sset LAST_FIX_CLASS "$CLASS"; sset EXIT_STATUS ""; sset EXIT_REASON ""; save
    echo "CONTINUE scoped=$(sget SCOPED_NEXT) severity_floor=$(sget SEVERITY_FLOOR_ACTIVE) sfh_effort=$(sfh_effort)"
    ;;

  round-end)
    load
    [ -z "$(sget EXIT_STATUS)" ] || die "this run already exited $(sget EXIT_STATUS) ($(sget EXIT_REASON)) — no further rounds. A new run needs a human re-label / re-invocation."
    req_num --criticals "$CRIT"; req_num --findings "$FIND"
    req_num --fix-induced "$FIXI"; req_num --coverage-only "$COV"; req_num --pushed-back "$PUSHED"
    req_num --fixed "$FIXED"
    [ "$CRIT" -le "$FIND" ] || die "--criticals ($CRIT) exceeds --findings ($FIND): criticals are a subset of findings"
    [ $(( FIXI + COV )) -le "$FIND" ] || die "--fix-induced + --coverage-only exceeds --findings: the buckets are disjoint"
    case "$CODE" in 0|1) ;; *) die "--code-changed must be 0 or 1";; esac
    case "$CLASS" in tests|docs|prod) ;; *) die "--fix-class must be tests|docs|prod";; esac
    case "$SCOPED" in 0|1) ;; *) die "--scoped must be 0 or 1";; esac
    # An empty change set must not vacuously count as "all tests" (SKILL.md Phase 3 step 7).
    if [ "$CODE" = "0" ] && [ "$CLASS" != "prod" ]; then CLASS=prod; fi
    # Every finding must be accounted for — fixed, or explicitly pushed back
    # with reasoning (SKILL.md Phase 3: agree/partially agree/disagree; no
    # finding is left silently unaddressed). A round-changed=1 round used to be
    # unchecked here: it could fix one of two findings, drop the other, and
    # still reach CLEAN once a later review came back empty — the second
    # finding was never fixed OR declined. Skipped under --forced-exit:
    # triage's diminishing-returns exit hands the list to a human without
    # engaging with each finding individually, by design.
    if [ -z "$FORCED" ]; then
      { [ "$CODE" = "1" ] || [ "$FIXED" -eq 0 ]; } || die "--code-changed 0 but --fixed ($FIXED) > 0: a fix requires a code change"
      [ $(( FIXED + PUSHED )) -eq "$FIND" ] || die "--fixed ($FIXED) + --pushed-back ($PUSHED) != --findings ($FIND): every finding must be fixed or explicitly declined"
    fi

    # ── advance the counters ──
    it=$(( $(sget ITERATION) + 1 )); sset ITERATION "$it"
    total=$(( $(sget PRIOR_ROUNDS) + it )); sset PR_ROUNDS_TOTAL "$total"
    streak="$(sget CONSECUTIVE_CLEAN_ROUNDS)"
    if [ "$CRIT" -gt 0 ]; then
      streak=0
    elif [ "$SCOPED" = "0" ]; then
      streak=$(( streak + 1 ))
    fi   # a scoped round with 0 CRITICAL leaves the streak unchanged (not full-batch evidence)
    sset CONSECUTIVE_CLEAN_ROUNDS "$streak"
    if [ "$FIND" -gt 0 ] && [ $(( FIXI + COV )) -ge "$FIND" ]; then
      sset FIX_INDUCED_ROUNDS $(( $(sget FIX_INDUCED_ROUNDS) + 1 ))
    else
      sset FIX_INDUCED_ROUNDS 0
    fi
    if [ "$streak" -ge 2 ]; then sset SEVERITY_FLOOR_ACTIVE 1; else sset SEVERITY_FLOOR_ACTIVE 0; fi
    sset LAST_FIX_CLASS "$CLASS"
    # Next round's type: a scoped round that surfaced a finding always escalates
    # to a full batch; a tests/docs-only fix after a CRITICAL-free round earns a
    # scoped verify; anything else is a full batch.
    if [ "$SCOPED" = "1" ] && [ "$FIND" -gt 0 ]; then
      sset SCOPED_NEXT 0
    elif [ "$CRIT" -eq 0 ] && { [ "$CLASS" = "tests" ] || [ "$CLASS" = "docs" ]; }; then
      sset SCOPED_NEXT 1
    else
      sset SCOPED_NEXT 0
    fi

    # ── decide ──
    status=""; reason=""
    now="$(date +%s)"; elapsed=$(( now - $(sget START_TIME) ))
    if [ -n "$FORCED" ]; then
      status="${FORCED%%:*}"; reason="${FORCED#*:}"; [ "$reason" != "$FORCED" ] || reason="forced"
    elif [ "$WDK" = "1" ]; then
      status=CODEX_DEGRADED; reason="every agent watchdog-killed"
    elif [ "$CODE" = "0" ] && [ "$CRIT" -eq 0 ]; then
      status=CLEAN; reason="no code change and no CRITICAL"
    elif [ "$CODE" = "0" ]; then
      status=NEEDS_HUMAN_REVIEW; reason="critical-declined"
    elif [ "$elapsed" -ge "$(sget TIMEOUT_SECONDS)" ]; then
      status=TIMED_OUT; reason="${elapsed}s >= $(sget TIMEOUT_SECONDS)s"
    elif [ "$it" -ge "$(sget MAX_ITERATIONS)" ]; then
      status=MAX_ITERATIONS_REACHED; reason="$it rounds this run"
    elif [ "$total" -ge "$(sget MAX_PR_ROUNDS)" ]; then
      status=FIX_BUDGET_EXHAUSTED; reason="pr-rounds $total >= $(sget MAX_PR_ROUNDS) (prior $(sget PRIOR_ROUNDS) + this run $it)"
    elif [ "$(sget FIX_INDUCED_ROUNDS)" -ge "$(sget MAX_FIX_INDUCED_ROUNDS)" ]; then
      status=FIX_BUDGET_EXHAUSTED; reason="fix-induced streak $(sget FIX_INDUCED_ROUNDS) >= $(sget MAX_FIX_INDUCED_ROUNDS)"
    fi
    if [ -n "$status" ]; then sset EXIT_STATUS "$status"; sset EXIT_REASON "$reason"; fi
    save
    write_rounds_file
    if [ -n "$status" ]; then
      echo "EXIT $status $reason"
    else
      echo "CONTINUE scoped=$(sget SCOPED_NEXT) severity_floor=$(sget SEVERITY_FLOOR_ACTIVE) sfh_effort=$(sfh_effort)"
    fi
    ;;

  *)
    echo "usage: loop-state.sh {init|get|set|show|triage|round-end|validation-fix} --state F ..." >&2
    exit 2
    ;;
esac
