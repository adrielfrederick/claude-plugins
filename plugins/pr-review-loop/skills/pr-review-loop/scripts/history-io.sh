#!/usr/bin/env bash
#
# history-io.sh — parse the machine-readable blocks the loop embeds in PR
# comments. Kept in a script (not inlined in SKILL.md) so the fiddly awk/sed and
# the in-flight-guard decision are covered by selftest.sh — a silent bug here
# degrades convergence (lost pushback history) or safety (a missed/false marker)
# with no error.
#
#   history-io.sh extract               < comment-body
#       → the history contents between the `pr-review-loop:history` markers
#   history-io.sh marker-host           < marker-comment   → host field
#   history-io.sh marker-epoch          < marker-comment   → epoch field
#   history-io.sh marker-blocks H NOW   < marker-comment
#       → exit 0 if an ACTIVE loop on ANOTHER host holds the marker (caller
#         should abort); exit 1 if safe to proceed (no/own/stale/malformed
#         marker). MARKER_MAX_AGE seconds (default 4500 = 75 min) is the
#         freshness window — a marker older than that is a dead run.
set -u

: "${MARKER_MAX_AGE:=4500}"

parse_host()  { sed -n 's/.*pr-review-loop:running \([^ ]*\) [0-9][0-9]*.*/\1/p' | head -1; }
parse_epoch() { sed -n 's/.*pr-review-loop:running [^ ]* \([0-9][0-9]*\).*/\1/p' | head -1; }

case "${1:-}" in
  extract)
    # Print lines strictly between the opening marker line and the closing
    # `-->` line (both excluded). The opener is anchored to line START so a
    # wrap-up comment that *quotes* the token in prose (e.g. a finding that
    # says "match the `<!-- pr-review-loop:history` opener") can't trigger
    # extraction early — only the real standalone opener line does. The closer
    # must be EXACTLY `-->` on its own line (the writer guarantees that, see
    # SKILL.md Phase 5) — a history line that merely *starts* with `-->` (quoted
    # code, HTML) must not silently truncate everything after it.
    awk '/^<!-- pr-review-loop:history/{f=1;next} /^-->[[:space:]]*$/{f=0;next} f'
    ;;
  history-filter)
    # The jq/gh-`-q` predicate that selects the newest PR comment holding a REAL
    # history block. Single source of truth: SKILL.md Phase 0 passes this to
    # `gh ... -q`, and selftest.sh runs it through `jq` — so the two can't drift.
    # Line-start = preceded by \n OR the very start of the body (a comment that
    # BEGINS with the block has no leading \n and must still be selected);
    # a prose-only mention mid-line is never selected over an older real block.
    # Relies on gh returning comments in ascending creation order (`last` = newest).
    printf '%s' '[.comments[].body | select(startswith("<!-- pr-review-loop:history") or contains("\n<!-- pr-review-loop:history"))] | last // ""'
    ;;
  marker-host)  parse_host ;;
  marker-epoch) parse_epoch ;;
  marker-blocks)
    myhost="${2:-}"; now="${3:-}"
    body="$(cat)"
    mhost="$(printf '%s' "$body" | parse_host)"
    mepoch="$(printf '%s' "$body" | parse_epoch)"
    [ -n "$mhost" ] && [ -n "$mepoch" ] || exit 1   # malformed / no marker → proceed
    [ "$mhost" != "$myhost" ]           || exit 1   # our own marker → proceed
    [ -n "$now" ]                       || exit 1   # no clock → don't false-block
    [ "$(( now - mepoch ))" -lt "$MARKER_MAX_AGE" ] || exit 1   # stale → proceed
    exit 0                                          # fresh, another host → block
    ;;
  *)
    echo "usage: history-io.sh {extract|marker-host|marker-epoch|marker-blocks H NOW}" >&2
    exit 2
    ;;
esac
