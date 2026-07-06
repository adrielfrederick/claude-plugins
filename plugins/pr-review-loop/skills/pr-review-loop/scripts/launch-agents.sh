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
# A watchdog-killed agent gets a `WATCHDOG_KILLED` sentinel appended to its
# review file. On completion, <run-dir>/.done is written.
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
: "${AGENT_TIMEOUT_SECONDS:=900}"

die() { echo "launch-agents.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)    RUN_DIR="${2:-}"; shift 2 ;;
    --repo)       REPO="${2:-}"; shift 2 ;;
    --sfh-effort) SFH_EFFORT="${2:-}"; shift 2 ;;
    --add)        ADDONS+=("${2:-}"); shift 2 ;;
    --skip)       SKIP+=("${2:-}"); shift 2 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[ -n "$RUN_DIR" ] || die "--run-dir is required"
[ -n "$REPO" ]    || die "--repo is required"
[ -d "$RUN_DIR" ] || die "run dir not found: $RUN_DIR"
case "$SFH_EFFORT" in high|medium) ;; *) die "--sfh-effort must be high or medium" ;; esac

# Per-role config: "sandbox|model-flag|effort". silent-failure-hunter's effort
# is overridden from --sfh-effort below.
role_config() {
  case "$1" in
    code-reviewer)           echo "--full-auto||medium" ;;
    test-analyzer)           echo "--full-auto||medium" ;;
    silent-failure-hunter)   echo "-s read-only||$SFH_EFFORT" ;;
    type-design-analyzer)    echo "-s read-only|-m gpt-5.4-mini|medium" ;;
    comment-analyzer)        echo "-s read-only|-m gpt-5.4-mini|low" ;;
    code-simplifier)         echo "-s read-only|-m gpt-5.4-mini|low" ;;
    failure-pattern-analyst) echo "-s read-only||medium" ;;
    *)                       return 1 ;;
  esac
}

# ── Assemble the role list: core tier + default failure-pattern-analyst + add-ons ──
CORE=(code-reviewer test-analyzer silent-failure-hunter type-design-analyzer)
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
        kill -TERM "$apid" 2>/dev/null; sleep 5; kill -KILL "$apid" 2>/dev/null
        printf '\nWATCHDOG_KILLED after %ss\n' "$AGENT_TIMEOUT_SECONDS" >> "$RUN_DIR/review-$role.txt"
        break
      fi
      sleep 15
    done
  ) &
  echo "launched $role (sandbox='$sandbox' model='${model:-default}' effort='$effort') pid=$apid"
}

for role in "${ROLES[@]}"; do
  launch "$role"
done

wait
echo "DONE" > "$RUN_DIR/.done"
echo "all agents finished: ${ROLES[*]}"
