#!/usr/bin/env bash
#
# launch-agents.sh — launch the Codex reviewer batch for one round, each agent
# under a per-agent wall-clock watchdog, all in parallel.
#
# Why a script: the per-agent sandbox/model/effort table and the watchdog were
# previously hand-transcribed into a bash block every round. Two failure modes
# followed — a core-tier agent silently dropped (silent-failure-hunter never
# ran on PR 470), and watchdog/flag drift. Encoding the table here makes the
# core tier unconditional and the watchdog identical every round.
#
# Prompts must already exist at <run-dir>/prompt-<role>.txt (built by
# build-prompts.sh). Each agent writes:
#   <run-dir>/review-<role>.txt   — codex -o output (the findings)
#   <run-dir>/log-<role>.txt      — full stdout/stderr transcript
# A watchdog kill is recorded OUT-OF-BAND in <run-dir>/.watchdog-killed-<role>
# (what the reap loop classifies on — review content is model-controlled, so
# text alone must not be able to spoof the classification) and a human-readable
# `WATCHDOG_KILLED` sentinel is appended to the review file for Step 5's
# reader. On completion, <run-dir>/.done is written.
#
# Usage:
#   launch-agents.sh --run-dir <dir> --repo <path> \
#                    [--sfh-effort high|medium] \
#                    [--add comment-analyzer] [--add code-simplifier] \
#                    [--skip failure-pattern-analyst]
#
# Core tier (code-reviewer, test-analyzer, silent-failure-hunter,
# type-design-analyzer) always runs — there is deliberately no flag to skip a
# core agent. failure-pattern-analyst runs by default; pass
# --skip failure-pattern-analyst when the packet has no failure-patterns.md.
set -u

RUN_DIR=""
REPO=""
SFH_EFFORT="high"
ADDONS=()
SKIP=()
ONLY=""
ONLY_SET=0
: "${AGENT_TIMEOUT_SECONDS:=900}"

die() { echo "launch-agents.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)    RUN_DIR="${2:-}"; shift 2 ;;
    --repo)       REPO="${2:-}"; shift 2 ;;
    --sfh-effort) SFH_EFFORT="${2:-}"; shift 2 ;;
    --add)        ADDONS+=("${2:-}"); shift 2 ;;
    --skip)       SKIP+=("${2:-}"); shift 2 ;;
    --only)       ONLY="${2:-}"; ONLY_SET=1; shift 2 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[ -n "$RUN_DIR" ] || die "--run-dir is required"
[ -n "$REPO" ]    || die "--repo is required"
[ -d "$RUN_DIR" ] || die "run dir not found: $RUN_DIR"
case "$SFH_EFFORT" in high|medium) ;; *) die "--sfh-effort must be high or medium" ;; esac
# A non-numeric timeout would kill the watchdog subshell on arithmetic
# expansion and let the agent run unbounded, with the error invisible.
case "$AGENT_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) die "AGENT_TIMEOUT_SECONDS must be a positive integer (got '$AGENT_TIMEOUT_SECONDS')" ;;
esac

# Per-role config: "sandbox|model-flag|effort". silent-failure-hunter's effort
# is overridden from --sfh-effort below.
role_config() {
  case "$1" in
    code-reviewer)           echo "-s workspace-write||medium" ;;
    test-analyzer)           echo "-s workspace-write||medium" ;;
    silent-failure-hunter)   echo "-s read-only||$SFH_EFFORT" ;;
    type-design-analyzer)    echo "-s read-only|-m gpt-5.4-mini|medium" ;;
    comment-analyzer)        echo "-s read-only|-m gpt-5.4-mini|low" ;;
    code-simplifier)         echo "-s read-only|-m gpt-5.4-mini|low" ;;
    failure-pattern-analyst) echo "-s read-only||medium" ;;
    *)                       return 1 ;;
  esac
}

CORE=(code-reviewer test-analyzer silent-failure-hunter type-design-analyzer)

# ── --only: run EXACTLY the named roles (scoped verify rounds). This is the one
# path that bypasses core-tier enforcement — deliberately, because a scoped
# verify re-checks a tests/docs-only fix on the delta with 2 agents, not the
# full tier. The orchestrator only reaches it via the Phase 4 scoped-verify
# gate (prior round 0 CRITICAL + a tests/docs-only fix); a normal round never
# passes --only, so the core tier stays mandatory there.
if [ "$ONLY_SET" = "1" ]; then
  [ -n "$ONLY" ] || die "--only was given an empty role list"
  [ "${#ADDONS[@]}" -eq 0 ] && [ "${#SKIP[@]}" -eq 0 ] || die "--only cannot be combined with --add/--skip"
  # Reject malformed comma patterns on the RAW string, deterministically — bash
  # `read -a` drops a trailing empty field on some builds, so a trailing comma
  # ("code-reviewer,") could otherwise slip through and silently run one agent.
  case "$ONLY" in
    ,*|*,|*,,*) die "--only has an empty role (leading/trailing/double comma): '$ONLY'" ;;
  esac
  IFS=',' read -r -a ROLES <<< "$ONLY"
  CLEANED=()
  for r in "${ROLES[@]}"; do
    [ -n "$r" ] || die "--only contains an empty role (a stray comma?) — refusing a malformed scoped batch"
    role_config "$r" >/dev/null || die "--only: unknown role '$r'"
    for c in "${CLEANED[@]:-}"; do
      [ "$c" = "$r" ] && die "--only lists '$r' twice — duplicate agents would clobber each other's review/log files"
    done
    CLEANED+=("$r")
  done
  [ "${#CLEANED[@]}" -gt 0 ] || die "--only given but no valid roles"
  ROLES=("${CLEANED[@]}")
  echo "SCOPED verify batch (exact roles, core tier intentionally not enforced): ${ROLES[*]}"
else

# ── Normal round: core tier + default failure-pattern-analyst + add-ons ──
ROLES=("${CORE[@]}" failure-pattern-analyst)

for a in "${ADDONS[@]:-}"; do
  [ -n "$a" ] || continue
  case "$a" in
    comment-analyzer|code-simplifier) ROLES+=("$a") ;;
    *) die "--add expects comment-analyzer or code-simplifier, got '$a'" ;;
  esac
done

# Apply --skip (only non-core roles may be skipped).
for s in "${SKIP[@]:-}"; do
  [ -n "$s" ] || continue
  for c in "${CORE[@]}"; do
    [ "$s" = "$c" ] && die "refusing to skip core-tier agent '$s'"
  done
  NEXT=()
  for r in "${ROLES[@]}"; do
    [ "$r" = "$s" ] || NEXT+=("$r")
  done
  ROLES=("${NEXT[@]}")
done

# De-dupe while preserving order (an add-on already present, etc.).
SEEN=" "
FINAL=()
for r in "${ROLES[@]}"; do
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "
  FINAL+=("$r")
done
ROLES=("${FINAL[@]}")

fi   # end --only vs normal-round assembly

# Pre-flight: every selected role needs a prompt file and a known config.
for role in "${ROLES[@]}"; do
  [ -f "$RUN_DIR/prompt-$role.txt" ] || die "missing prompt: $RUN_DIR/prompt-$role.txt (run build-prompts.sh first)"
  role_config "$role" >/dev/null || die "no config for role '$role'"
done

launch() {
  local role="$1" cfg sandbox model effort
  cfg="$(role_config "$role")"
  sandbox="${cfg%%|*}"; cfg="${cfg#*|}"
  model="${cfg%%|*}"; effort="${cfg##*|}"

  # Locked-down CI containers (e.g. an unprivileged Railway runner) can't create
  # the user namespaces Codex's bubblewrap/landlock sandbox needs, so every
  # codex exec fails at sandbox setup. When the host signals this via
  # CODEX_SANDBOX_UNAVAILABLE, bypass the OS sandbox + approvals for every agent.
  # Safe only because such a runner is a throwaway container (the container is
  # the sandbox) reviewing trusted same-repo PRs. See SKILL.md Phase 1 Step 4.
  if [ -n "${CODEX_SANDBOX_UNAVAILABLE:-}" ]; then
    sandbox="--dangerously-bypass-approvals-and-sandbox"
  fi

  # shellcheck disable=SC2086  # sandbox/model are intentional multi-token flags
  codex exec $sandbox $model \
    -c model_reasoning_summary=concise \
    -c model_reasoning_effort="$effort" \
    -C "$REPO" \
    -o "$RUN_DIR/review-$role.txt" \
    "$(cat "$RUN_DIR/prompt-$role.txt")" > "$RUN_DIR/log-$role.txt" 2>&1 &
  local apid=$!

  # Deadline-based watchdog (NOT `sleep N && kill`): a sleep timer is itself
  # suspended when the machine sleeps and would never fire on a sleep-induced
  # stall; a deadline poll compares wall-clock each tick and kills on the first
  # tick after wake. Bounds the observed 28–167 min codex network stalls that
  # were ~2/3 of all review-loop wall time.
  (
    local deadline=$(( $(date +%s) + AGENT_TIMEOUT_SECONDS ))
    while kill -0 "$apid" 2>/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        # Record the kill BEFORE killing: the reap loop unblocks the instant
        # the agent dies, so an after-kill write would race and be missed,
        # causing a watchdog kill to be misclassified as an AGENT_FAILED crash.
        # The marker FILE is what the reap loop classifies on; the review-file
        # sentinel is only for Step 5's human/Claude reader (review content is
        # model-controlled and must not be able to spoof classification).
        : > "$RUN_DIR/.watchdog-killed-$role"
        printf '\nWATCHDOG_KILLED after %ss\n' "$AGENT_TIMEOUT_SECONDS" >> "$RUN_DIR/review-$role.txt"
        # Kill codex's direct children too — the stall often lives in a spawned
        # helper, which a parent-only TERM would leave running past the
        # deadline. Snapshot child PIDs BEFORE killing the parent (they reparent
        # on its death and pkill -P would then miss them), and kill the parent
        # first so it dies from the signal, not from observing its child exit
        # (an exit-0 there would read as a successful completion). Grandchildren
        # are not chased — best-effort.
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
      sleep 15
    done
  ) &
  local wpid=$!
  # Track BOTH pids: the reap loop joins the watchdog (wpid) before reading its
  # marker, so a watchdog that fires in the same tick the agent exits can't
  # write the marker AFTER the classification check (a TOCTOU that would leave a
  # spurious kill record on a completed review, dropping its findings).
  AGENT_PIDS+=("$role:$apid:$wpid")
  echo "launched $role (sandbox='$sandbox' model='${model:-default}' effort='$effort') pid=$apid"
}

AGENT_PIDS=()
for role in "${ROLES[@]}"; do
  launch "$role"
done

# Reap each agent individually and classify its exit. A codex that fails fast
# (deprecated/rejected flag, missing or untrusted binary, auth error) exits
# non-zero and leaves an EMPTY review file. Without this check, Step 5 reads
# that empty file as "no findings" and the round can exit CLEAN with an agent
# that never actually ran — a false-clean. Distinguish three outcomes:
#   exit 0                            → agent ran to completion
#   non-zero + .watchdog-killed-<role> → expected watchdog kill of a stalled agent
#   non-zero, no marker file           → crash → append AGENT_FAILED, fail the batch
# Classification keys on the watchdog's OUT-OF-BAND marker file, never on
# review content — a review that happens to contain "WATCHDOG_KILLED" text is
# model output, not a kill record.
FAILED=()
for entry in "${AGENT_PIDS[@]}"; do
  role="${entry%%:*}"; rest="${entry#*:}"; pid="${rest%%:*}"; wpid="${rest##*:}"
  agent_rc=0; wait "$pid" || agent_rc=$?
  # Join the watchdog BEFORE inspecting its marker, so the marker file is in its
  # final state (written-or-never) at classification time. The watchdog exits on
  # its own within one poll tick of the agent's death; this bounds the batch's
  # reap overhead to ~one tick, paid once (all watchdogs wind down in parallel).
  wait "$wpid" 2>/dev/null || true
  if [ "$agent_rc" -eq 0 ]; then
    # Exit 0 = the agent completed. If the watchdog ALSO fired (it lost the
    # race — the agent finished inside the same poll tick), its marker and
    # sentinel are spurious: drop both so a successful review isn't read
    # downstream as a partial, watchdog-killed one.
    if [ -f "$RUN_DIR/.watchdog-killed-$role" ]; then
      rm -f "$RUN_DIR/.watchdog-killed-$role"
      grep -v '^WATCHDOG_KILLED' "$RUN_DIR/review-$role.txt" > "$RUN_DIR/review-$role.txt.tmp" || true
      mv "$RUN_DIR/review-$role.txt.tmp" "$RUN_DIR/review-$role.txt"
    fi
    # Exit 0 but an empty review file is anomalous — every persona is told to
    # write at least "No issues found." A codex output-write failure or a CLI
    # behavior change would otherwise be read as a clean "no findings" round.
    if [ ! -s "$RUN_DIR/review-$role.txt" ]; then
      printf '\nAGENT_FAILED exit=0-empty-output\n' >> "$RUN_DIR/review-$role.txt"
      echo "AGENT FAILED: $role exited 0 but produced no review — see log-$role.txt" >&2
      FAILED+=("$role")
    fi
  else
    if [ -f "$RUN_DIR/.watchdog-killed-$role" ]; then
      :   # expected watchdog kill of a stalled agent (marker kept for debugging)
    else
      printf '\nAGENT_FAILED exit=%s\n' "$agent_rc" >> "$RUN_DIR/review-$role.txt"
      echo "AGENT FAILED: $role exited $agent_rc without producing a review — see log-$role.txt" >&2
      FAILED+=("$role")
    fi
  fi
done

# Watchdogs self-exit once their agent is reaped; reap any stragglers.
wait 2>/dev/null || true

echo "DONE" > "$RUN_DIR/.done"
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '%s\n' "${FAILED[@]}" > "$RUN_DIR/.failed"
  echo "agents FAILED (crashed, not watchdog-killed): ${FAILED[*]}" >&2
  exit 3
fi
echo "all agents finished: ${ROLES[*]}"
