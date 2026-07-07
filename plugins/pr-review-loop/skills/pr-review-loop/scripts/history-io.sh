#!/usr/bin/env bash
#
# history-io.sh — parse the machine-readable blocks the loop embeds in PR
# comments. Kept in a script (not inlined in SKILL.md) so the fiddly awk/sed is
# covered by selftest.sh — a silent parse bug here degrades convergence (lost
# pushback history / a missed in-flight marker) with no error.
#
#   history-io.sh extract        < comment-body   → the history contents between
#                                                    the `pr-review-loop:history`
#                                                    HTML-comment markers
#   history-io.sh marker-host    < marker-comment  → the host from a running-marker
#   history-io.sh marker-epoch   < marker-comment  → the epoch from a running-marker
set -u

case "${1:-}" in
  extract)
    # Print lines strictly between the opening `<!-- pr-review-loop:history`
    # line and the closing `-->` line (both excluded). Anything before/after
    # (the visible wrap-up text) is dropped.
    awk '/pr-review-loop:history/{f=1;next} /^-->/{f=0;next} f'
    ;;
  marker-host)
    sed -n 's/.*pr-review-loop:running \([^ ]*\) [0-9][0-9]*.*/\1/p' | head -1
    ;;
  marker-epoch)
    sed -n 's/.*pr-review-loop:running [^ ]* \([0-9][0-9]*\).*/\1/p' | head -1
    ;;
  *)
    echo "usage: history-io.sh {extract|marker-host|marker-epoch}" >&2
    exit 2
    ;;
esac
