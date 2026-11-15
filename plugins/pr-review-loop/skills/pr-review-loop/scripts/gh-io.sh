#!/usr/bin/env bash
#
# gh-io.sh — the loop's WRITE path to GitHub: post, edit and delete comments.
# Every call retries with backoff, and each
# attempt tries REST first then falls back to GraphQL.
#
# Why this exists: on 2026-07-16 a GitHub "Partially Degraded Service" incident
# 5xx'd the REST API while GraphQL stayed up the whole time. Two review-loop
# runs on reduction#10 completed their review rounds and then silently lost BOTH
# end-of-loop writes — the "Automated Review Summary" was never posted and the
# "🔒 pr-review-loop running" marker was never removed. Those calls were single-shot `gh pr comment` /
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
#   gh-io.sh edit-comment      --repo O/R --cid ID [--node NODE] [--id-file F] --body-file F
#       → updates an existing comment's body in place. --id-file is read (not
#         written) for the "<databaseId> <nodeId>" pair. Retry + REST→GraphQL
#         fallback, same as post/delete.
#   gh-io.sh delete-comment    --repo O/R --cid ID [--node NODE] [--id-file F]
#       → exit 0 on delete or already-gone (404). --id-file is removed on success.
#
# Env:
#   GH_IO_ATTEMPTS  attempts per operation (default 5)
#   GH_IO_BACKOFF   first inter-attempt sleep in seconds, doubling (default 2)
set -u

: "${GH_IO_ATTEMPTS:=5}"
: "${GH_IO_BACKOFF:=2}"

die() { echo "gh-io.sh: $*" >&2; exit 1; }
log() { echo "gh-io.sh: $*" >&2; }

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH. Install: https://cli.github.com/"

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

# ── edit-comment ───────────────────────────────────────────────────────────
edit_rest() {
  local out
  out="$(gh api -X PATCH "repos/$REPO/issues/comments/$CID" \
    -F "body=@$BODY_FILE" --jq '"\(.id) \(.node_id)"' 2>&1)" || { log "REST edit failed: $out"; return 1; }
  is_num "${out%% *}" || { log "REST edit returned a non-numeric id (degraded API?): ${out:0:120}"; return 1; }
}

edit_graphql() {
  local out
  [ -n "${NODE:-}" ] || { log "no node id known for comment $CID — cannot use the GraphQL fallback"; return 1; }
  out="$(gh api graphql \
    -f query='mutation($id:ID!,$body:String!){updateIssueComment(input:{id:$id,body:$body}){issueComment{databaseId}}}' \
    -f id="$NODE" -F "body=@$BODY_FILE" \
    --jq '.data.updateIssueComment.issueComment.databaseId' 2>&1)" \
    || { log "GraphQL edit failed: $out"; return 1; }
  is_num "$out" || { log "GraphQL edit returned a non-numeric id: ${out:0:120}"; return 1; }
}

edit_once() { edit_rest || edit_graphql; }

# ── argument parsing ────────────────────────────────────────────────────────
CMD="${1:-}"; shift || true
REPO=""; PR=""; BODY_FILE=""; ID_FILE=""; CID=""; NODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --pr)        PR="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --id-file)   ID_FILE="${2:-}"; shift 2 ;;
    --cid)       CID="${2:-}"; shift 2 ;;
    --node)      NODE="${2:-}"; shift 2 ;;
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
    # Persist BEFORE printing: the id file is what a later fresh shell reads to
    # find this comment. Writing it here,
    # inside the same operation that posted, closes the window where a comment
    # exists on the PR that nothing knows the id of — an orphan by construction.
    if [ -n "$ID_FILE" ]; then
      printf '%s\n' "$POSTED" > "$ID_FILE" \
        || die "posted comment $POSTED but could not write --id-file $ID_FILE — delete the comment by hand"
    fi
    printf '%s\n' "$POSTED"
    ;;

  edit-comment)
    [ -n "$REPO" ] || die "--repo is required"
    if [ -z "$CID" ] && [ -n "$ID_FILE" ] && [ -f "$ID_FILE" ]; then
      read -r CID NODE < "$ID_FILE" || true
    fi
    is_num "$CID" || die "--cid must be a number (got: ${CID:-empty})"
    [ -s "$BODY_FILE" ] || die "--body-file is required and must be non-empty: ${BODY_FILE:-unset}"
    split_repo
    with_retry edit_once || die "could not edit comment $CID on $REPO via REST or GraphQL"
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

  *)
    die "usage: gh-io.sh {post-comment|edit-comment|delete-comment} [flags] (see the header)"
    ;;
esac
