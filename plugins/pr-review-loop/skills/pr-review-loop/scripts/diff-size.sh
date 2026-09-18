#!/usr/bin/env bash
#
# diff-size.sh — how big is this PR, in lines a reviewer actually has to read?
#
# Why: a review packet above ~3,000 added lines does not converge. On
# f1-predictions#1155 a 3,900-line packet fed five reviewers something new every
# round for 24 rounds, growing to 6,000 lines as the fixes landed; the runner's
# 75-minute cap gets about three rounds on a packet that size. The repo's own
# CLAUDE.md said "split before labeling" and was not followed. So the loop now
# measures the packet itself and refuses to start on one it cannot finish.
#
# "Lines a reviewer has to read" excludes artifacts: JSON/CSV/notebooks,
# lockfiles, snapshots, minified/generated code, binaries. A committed
# results/*.json can add 10,000 lines and change nothing about reviewability.
#
# Usage:
#   diff-size.sh --repo <path> --base-ref <ref> [--warn 1500] [--stop 2500]
#                [--since <sha>] [--exclude 'glob:glob:...']
#
# Output (stdout, key=value lines, then a "top counted files" list):
#   counted_added=N        added lines in reviewable files (base-ref...HEAD)
#   excluded_added=M       added lines in artifact files
#   excluded_files=K
#   verdict=OK|WARN|STOP   against --warn / --stop (0 disables a threshold)
#   with --since SHA (the head the loop started from), also:
#   loop_prod_added=P      lines the LOOP has added to production files since SHA
#   loop_test_added=T      lines the LOOP has added to test files since SHA
#   test_budget=OK|EXCEEDED   EXCEEDED once T > P — the fixer then declines
#                             further coverage-only findings (SKILL.md Phase 3)
# Exit: 0 for OK/WARN, 3 for STOP, 1 on error.
#
# Extra exclusions: --exclude or the PR_SIZE_EXCLUDE env var (colon-separated
# shell globs matched against the repo-relative path).
set -u
# No pathname expansion: the exclusion patterns are iterated unquoted so IFS
# can split them, and a pattern like `*.md` must stay a pattern instead of
# expanding against whatever the current directory happens to hold.
set -f

REPO=""; BASE=""; WARN=1500; STOP=2500; SINCE=""; EXTRA="${PR_SIZE_EXCLUDE:-}"
die() { echo "diff-size.sh: $*" >&2; exit 1; }
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:-}"; shift 2 ;;
    --base-ref) BASE="${2:-}"; shift 2 ;;
    --warn)     WARN="${2:-}"; shift 2 ;;
    --stop)     STOP="${2:-}"; shift 2 ;;
    --since)    SINCE="${2:-}"; shift 2 ;;
    --exclude)  EXTRA="${EXTRA:+$EXTRA:}${2:-}"; shift 2 ;;
    *)          die "unknown argument: $1" ;;
  esac
done
[ -n "$REPO" ] || die "--repo is required"
[ -n "$BASE" ] || die "--base-ref is required (refresh-packet.sh writes it to <packet>/base-ref.txt)"
is_num "$WARN" && is_num "$STOP" || die "--warn/--stop must be non-negative integers"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"
git -C "$REPO" rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || die "cannot resolve base ref '$BASE'"
if [ -n "$SINCE" ]; then
  git -C "$REPO" rev-parse -q --verify "$SINCE^{commit}" >/dev/null 2>&1 || die "cannot resolve --since '$SINCE'"
fi

# Artifact patterns. Extension-based and deliberately conservative: YAML, TOML,
# Markdown and SQL are read by reviewers and stay counted. Add project-specific
# ones via --exclude / PR_SIZE_EXCLUDE rather than widening this list.
DEFAULT_EXCLUDE='*.json:*.jsonl:*.ndjson:*.geojson:*.csv:*.tsv:*.svg:*.ipynb:*.lock:*.lock.*:package-lock.json:yarn.lock:pnpm-lock.yaml:poetry.lock:uv.lock:Cargo.lock:Gemfile.lock:composer.lock:go.sum:*.snap:*/__snapshots__/*:__snapshots__/*:*.min.js:*.min.css:*.map:*.golden:*.pb.go:*_pb2.py:*_pb2_grpc.py:*.generated.*:*.g.dart:*.parquet:*.pkl:*.pickle:*.npy:*.npz'
PATTERNS="$DEFAULT_EXCLUDE${EXTRA:+:$EXTRA}"

is_excluded() {   # $1 = repo-relative path
  local p="$1" pat
  local IFS=':'
  for pat in $PATTERNS; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254  # $pat is a glob on purpose
    case "$p" in $pat) return 0;; esac
    case "$p" in */$pat) return 0;; esac   # bare filename patterns match in any dir
  done
  return 1
}
is_test_path() {
  case "$1" in
    tests/*|*/tests/*|test/*|*/test/*|spec/*|*/spec/*|__tests__/*|*/__tests__/*|\
    *_test.*|*.test.*|*.spec.*|test_*|*/test_*|conftest.py|*/conftest.py) return 0;;
    *) return 1;;
  esac
}

# git renames print "dir/{old => new}/file" or "old => new"; take the new name.
normalize() {
  local p="$1"
  case "$p" in
    *"{"*" => "*"}"*) p="$(printf '%s' "$p" | sed -E 's/\{[^}]* => ([^}]*)\}/\1/g; s#//#/#g')" ;;
    *" => "*)         p="${p##* => }" ;;
  esac
  printf '%s' "$p"
}

counted=0; excluded=0; excluded_files=0
TOP="$(mktemp)"; NUMSTAT="$(mktemp)"; trap 'rm -f "$TOP" "$NUMSTAT"' EXIT
# Captured to a file and checked explicitly rather than fed straight into the
# while-read via process substitution: a process substitution's exit status is
# invisible to the calling shell, so a failed `git diff` (e.g. no merge base
# between BASE and HEAD in a shallow checkout, even though both refs resolve)
# would silently read as zero lines and report counted_added=0 / verdict=OK —
# exactly the silent-failure class this script exists to catch in the PR itself.
git -C "$REPO" diff --numstat "$BASE"...HEAD > "$NUMSTAT" || die "git diff --numstat $BASE...HEAD failed — cannot compute PR size"
while IFS=$'\t' read -r add del path; do
  [ -n "$path" ] || continue
  path="$(normalize "$path")"
  if [ "$add" = "-" ]; then            # binary
    excluded_files=$(( excluded_files + 1 )); continue
  fi
  is_num "$add" || continue
  if is_excluded "$path"; then
    excluded=$(( excluded + add )); excluded_files=$(( excluded_files + 1 ))
  else
    counted=$(( counted + add ))
    printf '%s\t%s\n' "$add" "$path" >> "$TOP"
  fi
done < "$NUMSTAT"

verdict=OK
if [ "$STOP" -gt 0 ] && [ "$counted" -ge "$STOP" ]; then verdict=STOP
elif [ "$WARN" -gt 0 ] && [ "$counted" -ge "$WARN" ]; then verdict=WARN; fi

echo "counted_added=$counted"
echo "excluded_added=$excluded"
echo "excluded_files=$excluded_files"
echo "verdict=$verdict"
echo "warn_at=$WARN"
echo "stop_at=$STOP"

if [ -n "$SINCE" ]; then
  lp=0; lt=0
  SINCE_NUMSTAT="$(mktemp)"; trap 'rm -f "$TOP" "$NUMSTAT" "$SINCE_NUMSTAT"' EXIT
  git -C "$REPO" diff --numstat "$SINCE"..HEAD > "$SINCE_NUMSTAT" || die "git diff --numstat $SINCE..HEAD failed — cannot compute the loop's prod/test budget"
  while IFS=$'\t' read -r add del path; do
    [ -n "$path" ] || continue
    path="$(normalize "$path")"
    is_num "$add" || continue
    is_excluded "$path" && continue
    if is_test_path "$path"; then lt=$(( lt + add )); else lp=$(( lp + add )); fi
  done < "$SINCE_NUMSTAT"
  echo "loop_prod_added=$lp"
  echo "loop_test_added=$lt"
  if [ "$lt" -gt "$lp" ]; then echo "test_budget=EXCEEDED"; else echo "test_budget=OK"; fi
fi

echo "top counted files:"
sort -t"$(printf '\t')" -k1,1nr "$TOP" | head -8 | awk -F'\t' '{printf "  %6d  %s\n", $1, $2}'

[ "$verdict" = "STOP" ] && exit 3
exit 0
