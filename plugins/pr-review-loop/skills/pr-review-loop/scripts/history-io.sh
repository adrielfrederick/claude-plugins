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
#   history-io.sh rounds-parse          < comment-body
#       → the lifetime round count from a `pr-review-loop:rounds N` marker;
#         empty if absent or malformed
#   history-io.sh rounds-total [FILE]   < comment-bodies
#       → max(FILE's count, every marker's count), or 0 — the PR's lifetime
#         review-round total. stdin may hold MANY comment bodies (Phase 0 joins
#         them all): the summary AND the per-round progress comment carry the
#         marker, so a run killed mid-loop still counts. See the note below.
#   history-io.sh rounds-filter
#       → the jq expression Phase 0 passes to `gh pr view -q` to get every
#         comment body joined by newlines (input for rounds-total).
set -u

: "${MARKER_MAX_AGE:=4500}"

parse_host()  { sed -n 's/.*pr-review-loop:running \([^ ]*\) [0-9][0-9]*.*/\1/p' | head -1; }
parse_epoch() { sed -n 's/.*pr-review-loop:running [^ ]* \([0-9][0-9]*\).*/\1/p' | head -1; }

# ── Fix budget: the PR's LIFETIME review-round count ────────────────────────
# `ITERATION` resets to 0 in Phase 0 of EVERY run, so `MAX_ITERATIONS` bounds a
# RUN, not a PR — removing and re-adding the `review` label hands the loop a
# fresh budget, and a PR that never converges grinds on indefinitely, one run at
# a time. f1-predictions#623 took 13 rounds across two runs; neither run reached
# 10, so nothing stopped it, and both died on the workflow wall clock having
# posted no verdict at all.
#
# The count therefore has to outlive the run. It is carried in TWO places with
# different failure modes, and `rounds-total` takes the max:
#   - a local file under $PR_ROOT — survives re-runs on a long-lived runner, but
#     dies with the container.
#   - a `pr-review-loop:rounds N` marker in the PR's newest summary comment —
#     survives a redeploy or a move to a different host, but not a deleted or
#     hand-edited comment.
# Max rather than "prefer one", because either source can be legitimately absent
# and the failure that matters is UNDERCOUNTING: that silently hands back budget
# the PR has already spent, which is the exact bug this exists to close.
# MAX of every marker on stdin, not the first: since 0.15.0 the progress
# comment carries the marker too (rewritten every round), so a run that dies
# mid-loop still leaves its round count on the PR — the CI run on
# f1-predictions#1155 completed 7 rounds, posted no summary, and the next run
# started from PRIOR_ROUNDS=0. Phase 0 now feeds every comment body in at once.
# Anchored to a full, standalone marker line — line START through the closing
# `-->`, AND end-of-line (only trailing whitespace allowed) — same discipline
# as the history opener/closer above. A trailing `.*` instead of an end anchor
# is not enough: a comment that BEGINS with a real-looking marker and then
# continues in prose on the same line ("<!-- pr-review-loop:rounds 999 -->
# quoted from the previous summary") would still match and poison the count.
parse_rounds() { sed -n 's/^<!-- pr-review-loop:rounds \([0-9][0-9]*\) -->[[:space:]]*$/\1/p' | sort -n | tail -1; }

# Digits-only, bounded read. Anything else in the file (empty, a stray newline,
# a half-written value from a killed run) reads as 0 rather than erroring — a
# corrupt counter must not take the loop down, and 0 is the safe direction here
# because the PR-resident marker still carries the real total.
read_rounds_file() {
  local f="${1:-}" n=""
  [ -n "$f" ] && [ -r "$f" ] || { printf '0'; return 0; }
  n="$(tr -dc '0-9' < "$f" 2>/dev/null | head -c 9)"
  printf '%s' "${n:-0}"
}

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
  rounds-parse) parse_rounds ;;
  rounds-filter)
    # Same anchoring discipline as history-filter: only comment bodies that
    # actually HOLD a standalone rounds-marker line (line start, or right after
    # a newline) are joined in — a comment that merely mentions the token in
    # prose is excluded before it ever reaches parse_rounds.
    printf '%s' '[.comments[].body | select(startswith("<!-- pr-review-loop:rounds ") or contains("\n<!-- pr-review-loop:rounds "))] | join("\n")'
    ;;
  rounds-total)
    # stdin is optional here: on the fast path (local file present) the caller
    # may pipe in nothing at all, and an absent marker is not an error.
    pr_n="$(parse_rounds)"
    [ -n "$pr_n" ] || pr_n=0
    file_n="$(read_rounds_file "${2:-}")"
    if [ "$pr_n" -gt "$file_n" ]; then printf '%s\n' "$pr_n"; else printf '%s\n' "$file_n"; fi
    ;;
  *)
    echo "usage: history-io.sh {extract|history-filter|marker-host|marker-epoch|marker-blocks H NOW|rounds-parse|rounds-filter|rounds-total [FILE]}" >&2
    exit 2
    ;;
esac
