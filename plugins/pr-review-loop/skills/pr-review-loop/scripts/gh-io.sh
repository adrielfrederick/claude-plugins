#!/usr/bin/env bash
#
# gh-io.sh — the loop's WRITE path to GitHub: post a comment, delete a comment,
# and reconcile the end-of-loop state. Every call retries with backoff, and each
# attempt tries REST first then falls back to GraphQL.
#
# Why this exists: on 2026-07-16 a GitHub "Partially Degraded Service" incident
# 5xx'd the REST API while GraphQL stayed up the whole time. Two review-loop
# runs on reduction#10 completed their review rounds and then silently lost BOTH
# end-of-loop writes — the "Automated Review Summary" was never posted and the
# "🔒 pr-review-loop running" marker was never removed — while the Actions run
# still reported success. Those calls were single-shot `gh pr comment` /
# `gh api -X DELETE` inlined in SKILL.md prose: nothing retried, nothing failed
# loudly, and both orphaned locks had to be deleted by hand (via GraphQL, which
# was working all along). Keeping the write path here makes the retry, the
# fallback, and the exit semantics testable (selftest.sh) instead of prose the
# model re-improvises every round.
#
# Usage:
#   gh-io.sh post-comment      --repo O/R --pr N --body-file F [--id-file F]
#       → stdout "<databaseId> <nodeId>". --id-file persists the same pair, so a
#         later fresh shell (Phase 5) can delete the comment without re-reading
#         it — the node id is captured HERE because resolving it later needs the
#         very REST endpoint that goes down during an incident.
#   gh-io.sh delete-comment    --repo O/R --cid ID [--node NODE] [--id-file F]
#       → exit 0 on delete or already-gone (404). --id-file is removed on success.
#   gh-io.sh newest-comment-id --repo O/R --pr N
#       → stdout the newest comment's databaseId (0 if none). The baseline
#         `reconcile --after` uses to scope its summary check to THIS run.
#   gh-io.sh reconcile         --repo O/R --pr N [--id-file F] [--after ID]
#       → removes a leftover in-flight marker and asserts the summary landed.
#         Exit 1 with ::error:: annotations if either invariant was broken.
#
# Env:
#   GH_IO_ATTEMPTS  attempts per operation (default 5)
#   GH_IO_BACKOFF   first inter-attempt sleep in seconds, doubling (default 2)
set -u

: "${GH_IO_ATTEMPTS:=5}"
: "${GH_IO_BACKOFF:=2}"

die() { echo "gh-io.sh: $*" >&2; exit 1; }
log() { echo "gh-io.sh: $*" >&2; }

# gh's built-in `--jq` can't be used everywhere (it is rejected alongside
# --slurp), so the comment reshaping below shells out to a real jq. Check it up
# front: a missing jq must not surface as an unparseable-body warning that reads
# like a GitHub outage.
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH. Install: https://cli.github.com/"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH. Install: https://jqlang.github.io/jq/"

# The marker/summary tokens the loop embeds in its comments. Single source of
# truth: SKILL.md writes them, reconcile reads them back.
MARKER_TOKEN="pr-review-loop:running"
SUMMARY_TOKEN="pr-review-loop:summary"

# ── retry ───────────────────────────────────────────────────────────────────
# Run "$@" until it succeeds or GH_IO_ATTEMPTS is exhausted. The operation
# functions below each try REST and then GraphQL *within a single attempt*, so a
# REST-down/GraphQL-up incident — the exact 2026-07-16 shape — is resolved on
# attempt 1 without waiting out a single backoff. The backoff is what covers a
# transient blip that takes both down for a moment; it is deliberately bounded
# (~62s at the defaults), because no sleep schedule outlasts a 30-minute
# incident. The fallback is the load-bearing part, not the retry.
with_retry() {
  local i=1 delay="$GH_IO_BACKOFF"
  while :; do
    if "$@"; then return 0; fi
    if [ "$i" -ge "$GH_IO_ATTEMPTS" ]; then
      log "all $GH_IO_ATTEMPTS attempts failed: $1"
      return 1
    fi
    log "attempt $i/$GH_IO_ATTEMPTS failed ($1); retrying in ${delay}s"
    sleep "$delay"
    i=$((i + 1)); delay=$((delay * 2))
  done
}

# A degraded GitHub can answer with an HTML error page or a proxy banner, which
# `gh api` may hand back without a non-zero exit. Never trust the exit code
# alone — every id this script emits is shape-checked as a bare integer, so an
# HTML body can't be persisted as a comment id and silently break the deletion.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

split_repo() {
  OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
  [ -n "$OWNER" ] && [ -n "$NAME" ] && [ "$OWNER" != "$REPO" ] \
    || die "--repo must be OWNER/REPO (got: $REPO)"
}

# ── post-comment ────────────────────────────────────────────────────────────
post_rest() {
  local out
  out="$(gh api -X POST "repos/$REPO/issues/$PR/comments" \
    -F "body=@$BODY_FILE" --jq '"\(.id) \(.node_id)"' 2>&1)" || { log "REST post failed: $out"; return 1; }
  is_num "${out%% *}" || { log "REST post returned a non-numeric id (degraded API?): ${out:0:120}"; return 1; }
  POSTED="$out"
}

post_graphql() {
  local subject out
  subject="$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){id}}}' \
    -f o="$OWNER" -f r="$NAME" -F n="$PR" \
    --jq '.data.repository.pullRequest.id' 2>&1)" || { log "GraphQL subject lookup failed: $subject"; return 1; }
  # A partial GraphQL response carries the error alongside `data: null` and still
  # exits 0, so --jq prints the string "null" — posting to that subject id would
  # fail confusingly. Require a real node id (they are opaque but never empty or
  # "null"), and retry instead.
  case "$subject" in ''|null) log "GraphQL subject lookup returned no PR id (degraded API?)"; return 1 ;; esac
  out="$(gh api graphql \
    -f query='mutation($id:ID!,$body:String!){addComment(input:{subjectId:$id,body:$body}){commentEdge{node{databaseId id}}}}' \
    -f id="$subject" -F "body=@$BODY_FILE" \
    --jq '"\(.data.addComment.commentEdge.node.databaseId) \(.data.addComment.commentEdge.node.id)"' 2>&1)" \
    || { log "GraphQL post failed: $out"; return 1; }
  is_num "${out%% *}" || { log "GraphQL post returned a non-numeric id: ${out:0:120}"; return 1; }
  POSTED="$out"
}

post_once() { post_rest || post_graphql; }

# ── delete-comment ──────────────────────────────────────────────────────────
del_rest() {
  local out
  out="$(gh api -X DELETE "repos/$REPO/issues/comments/$CID" 2>&1)" && return 0
  # Already gone is the goal state, not a failure — a retry that races the
  # first attempt's success must not turn a clean delete into a hard error.
  case "$out" in *"Not Found"*|*"HTTP 404"*) log "comment $CID already gone (404)"; return 0 ;; esac
  log "REST delete failed: $out"; return 1
}

del_graphql() {
  local out
  [ -n "${NODE:-}" ] || { log "no node id known for comment $CID — cannot use the GraphQL fallback"; return 1; }
  out="$(gh api graphql \
    -f query='mutation($id:ID!){deleteIssueComment(input:{id:$id}){clientMutationId}}' \
    -f id="$NODE" 2>&1)" && return 0
  case "$out" in *"Could not resolve"*|*"NOT_FOUND"*) log "comment $CID already gone (GraphQL)"; return 0 ;; esac
  log "GraphQL delete failed: $out"; return 1
}

del_once() { del_rest || del_graphql; }

# ── comment listing (reconcile) ─────────────────────────────────────────────
# GraphQL FIRST here, inverting the order used by the write paths above: it
# returns the newest 100 in one request (`last:100`), whereas the REST endpoint
# only pages oldest-first and has no direction knob — so REST needs --paginate
# to reach the newest comment, which is the one we care about. GraphQL also
# happens to be the API that survived the incident this script exists for.
list_graphql() {
  local out
  out="$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){comments(last:100){nodes{databaseId id body}}}}}' \
    -f o="$OWNER" -f r="$NAME" -F n="$PR" \
    --jq '[.data.repository.pullRequest.comments.nodes[] | {databaseId, id, body}]' 2>&1)" \
    || { log "GraphQL comment list failed: $out"; return 1; }
  case "$out" in '['*) COMMENTS="$out"; return 0 ;; esac
  log "GraphQL comment list returned a non-JSON body (degraded API?): ${out:0:120}"; return 1
}

list_rest() {
  local out
  # `gh api --slurp` is rejected when combined with `--jq`, so slurp the raw
  # pages and reshape with jq here. --paginate is required: the REST endpoint
  # pages oldest-first with no direction parameter, so on a long PR the newest
  # comment — the summary we are looking for — is only on the last page.
  out="$(gh api --paginate --slurp "repos/$REPO/issues/$PR/comments?per_page=100" 2>&1)" \
    || { log "REST comment list failed: $out"; return 1; }
  out="$(printf '%s' "$out" | jq -c '[.[][] | {databaseId: .id, id: .node_id, body: .body}]' 2>&1)" \
    || { log "REST comment list returned an unparseable body (degraded API?): ${out:0:120}"; return 1; }
  case "$out" in '['*) COMMENTS="$out"; return 0 ;; esac
  log "REST comment list returned a non-JSON body (degraded API?): ${out:0:120}"; return 1
}

list_once() { list_graphql || list_rest; }

# ── argument parsing ────────────────────────────────────────────────────────
CMD="${1:-}"; shift || true
REPO=""; PR=""; BODY_FILE=""; ID_FILE=""; CID=""; NODE=""; AFTER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --pr)        PR="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --id-file)   ID_FILE="${2:-}"; shift 2 ;;
    --cid)       CID="${2:-}"; shift 2 ;;
    --node)      NODE="${2:-}"; shift 2 ;;
    --after)     AFTER="${2:-}"; shift 2 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

case "$CMD" in
  post-comment)
    [ -n "$REPO" ] || die "--repo is required"
    is_num "$PR"   || die "--pr must be a number (got: ${PR:-empty})"
    [ -s "$BODY_FILE" ] || die "--body-file is required and must be non-empty: ${BODY_FILE:-unset}"
    split_repo
    POSTED=""
    with_retry post_once || die "could not post the comment to $REPO#$PR via REST or GraphQL"
    # Persist BEFORE printing: the id file is what a later fresh shell (and the
    # workflow's reconcile step) reads to find this comment. Writing it here,
    # inside the same operation that posted, closes the window where a comment
    # exists on the PR that nothing knows the id of — an orphan by construction.
    if [ -n "$ID_FILE" ]; then
      printf '%s\n' "$POSTED" > "$ID_FILE" \
        || die "posted comment $POSTED but could not write --id-file $ID_FILE — delete the comment by hand"
    fi
    printf '%s\n' "$POSTED"
    ;;

  delete-comment)
    [ -n "$REPO" ] || die "--repo is required"
    # Accept the "<databaseId> <nodeId>" pair straight out of an --id-file.
    if [ -z "$CID" ] && [ -n "$ID_FILE" ] && [ -f "$ID_FILE" ]; then
      read -r CID NODE < "$ID_FILE" || true
    fi
    is_num "$CID" || die "--cid must be a number (got: ${CID:-empty})"
    split_repo
    with_retry del_once || die "could not delete comment $CID on $REPO via REST or GraphQL"
    # A plain `[ -n "$ID_FILE" ] && rm -f …` here would leak its false test as
    # this script's exit status when no --id-file was passed, reporting a
    # successful delete as a failure.
    if [ -n "$ID_FILE" ]; then rm -f "$ID_FILE"; fi
    ;;

  newest-comment-id)
    [ -n "$REPO" ] || die "--repo is required"
    is_num "$PR"   || die "--pr must be a number (got: ${PR:-empty})"
    split_repo
    COMMENTS=""
    with_retry list_once || die "could not list comments on $REPO#$PR via GraphQL or REST"
    printf '%s\n' "$(printf '%s' "$COMMENTS" | jq -r '[.[].databaseId] | max // 0')"
    ;;

  reconcile)
    # The independent, model-proof check that the loop actually finished. The
    # skill tries hard to post the summary and drop the marker; this asserts it
    # happened. Run it from CI with `if: always()` — `claude --print` exits 0
    # whenever the model produced text, so without this a loop that lost its
    # end-of-loop writes reports a green run over a locked PR (reduction#10).
    [ -n "$REPO" ] || die "--repo is required"
    is_num "$PR"   || die "--pr must be a number (got: ${PR:-empty})"
    is_num "$AFTER" || die "--after must be a number (got: $AFTER)"
    split_repo
    COMMENTS=""
    with_retry list_once || die "could not list comments on $REPO#$PR via GraphQL or REST"

    PROBLEMS=0

    # 1. A marker still on the PR is a lock the loop failed to release. Remove
    #    it here so it can't false-block the next run for its 75-minute
    #    freshness window, and report it — a silent cleanup would hide the bug.
    #    Match on the token in the body rather than trusting --id-file blindly:
    #    if that file ever pointed at the wrong comment, this refuses to delete
    #    it instead of destroying a human's comment.
    leftover="$(printf '%s' "$COMMENTS" \
      | jq -r --arg t "$MARKER_TOKEN" '[.[] | select(.body | contains($t))] | last // empty | "\(.databaseId) \(.id)"')"
    if [ -n "$leftover" ]; then
      CID="${leftover%% *}"; NODE="${leftover##* }"
      echo "::error title=pr-review-loop lock left behind::The loop finished without removing its in-flight marker (comment $CID) on $REPO#$PR. Removing it now. The loop's own end-of-loop cleanup failed — check the run log for gh-io.sh errors."
      if with_retry del_once; then
        log "removed the leftover in-flight marker $CID"
        if [ -n "$ID_FILE" ]; then rm -f "$ID_FILE"; fi
      else
        echo "::error title=pr-review-loop lock stuck::Could not remove the in-flight marker (comment $CID) on $REPO#$PR via REST or GraphQL. Delete it by hand or the next loop on this PR is blocked for ~75 minutes."
      fi
      PROBLEMS=1
    fi

    # 2. No summary newer than the pre-loop baseline means Phase 5 never landed
    #    its wrap-up. Comment ids are monotonic, so `> --after` scopes this to
    #    THIS run without depending on clocks agreeing between the runner and
    #    GitHub. --after 0 (no baseline) degrades to "any summary ever", which
    #    is weaker but never false-alarms.
    summaries="$(printf '%s' "$COMMENTS" \
      | jq -r --arg t "$SUMMARY_TOKEN" --argjson a "$AFTER" \
        '[.[] | select(.databaseId > $a) | select(.body | contains($t))] | length')"
    if [ "$summaries" = "0" ]; then
      echo "::error title=pr-review-loop summary missing::The loop never posted its Automated Review Summary to $REPO#$PR (no comment newer than id $AFTER carries the $SUMMARY_TOKEN marker). The review rounds may have run — check the uploaded transcripts artifact — but the verdict was not published."
      PROBLEMS=1
    fi

    [ "$PROBLEMS" -eq 0 ] || exit 1
    log "reconcile clean: summary posted, no marker left behind."
    ;;

  *)
    die "usage: gh-io.sh {post-comment|delete-comment|newest-comment-id|reconcile} [flags] (see the header)"
    ;;
esac
