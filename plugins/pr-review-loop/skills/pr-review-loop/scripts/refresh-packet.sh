#!/usr/bin/env bash
#
# refresh-packet.sh — resolve the PR's base ref and (re)generate the diff
# artifacts in the review packet. Called once in Phase 0.5 and again at the top
# of EVERY round (Phase 1 Step 0): Claude pushes fixup commits between rounds,
# so the artifacts must track the current PR head. Previously this lived as
# prose bash in SKILL.md — the per-round refresh was a comment pointing back at
# Phase 0.5, and base-ref resolution had zero test coverage.
#
# Base-ref resolution: --base is the BARE branch name from `gh pr view` (e.g.
# "main"). On a laptop it exists as a local branch; in a CI/runner head-only
# checkout it must resolve via origin/<base> or an explicit fetch. Hard-fails
# rather than silently producing an empty packet.
#
# Usage:
#   refresh-packet.sh --repo <path> --packet <dir> --pr <number> --base <bare-branch>
#
# Writes into <packet>/: diff.patch, files/*.patch (per-file splits, slashes →
# __), manifest.txt, diff-wide.patch, changed-files.txt. Idempotent — stale
# files/ splits from the previous round are removed, not merged over.
set -euo pipefail

REPO=""
PACKET=""
PR_NUMBER=""
BASE=""

die() { echo "refresh-packet.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --packet) PACKET="${2:-}"; shift 2 ;;
    --pr)     PR_NUMBER="${2:-}"; shift 2 ;;
    --base)   BASE="${2:-}"; shift 2 ;;
    *)        die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ]      || die "--repo is required"
[ -n "$PACKET" ]    || die "--packet is required"
[ -n "$PR_NUMBER" ] || die "--pr is required"
[ -n "$BASE" ]      || die "--base is required"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"
mkdir -p "$PACKET"

# Resolve the bare base name fresh each call (laptop: local branch; runner:
# origin/<base> or fetch). FETCH_HEAD is safe here because the loop never runs
# another fetch between this resolution and the diffs below.
if git -C "$REPO" rev-parse -q --verify "refs/heads/$BASE" >/dev/null 2>&1; then
  BASE_REF="$BASE"
elif git -C "$REPO" rev-parse -q --verify "refs/remotes/origin/$BASE" >/dev/null 2>&1; then
  BASE_REF="origin/$BASE"
else
  git -C "$REPO" fetch --no-tags origin "$BASE" >/dev/null 2>&1 \
    && BASE_REF=FETCH_HEAD \
    || die "cannot resolve base ref '$BASE' — no local/remote ref and fetch failed"
fi

# Full PR diff. Empty means the PR has no diffable changes (or gh mis-answered)
# — either way an empty packet would produce a vacuous "clean" review; refuse.
(cd "$REPO" && gh pr diff "$PR_NUMBER") > "$PACKET/diff.patch"
[ -s "$PACKET/diff.patch" ] || die "gh pr diff $PR_NUMBER produced an empty diff — refusing to build an empty packet"

# Per-file split — eliminates output-truncation re-read loops.
rm -rf "$PACKET/files"; mkdir -p "$PACKET/files"
awk -v outdir="$PACKET/files" '
  /^diff --git / { if (out) close(out); f=$4; sub(/^b\//,"",f); gsub(/\//,"__",f); out=outdir "/" f ".patch" }
  out { print > out }
' "$PACKET/diff.patch"
# manifest.txt: exact per-file patch names, so agents read the right files
# instead of guessing paths or running `find` (the PR 470 token sink).
ls "$PACKET/files" > "$PACKET/manifest.txt"

git -C "$REPO" diff "$BASE_REF"...HEAD -U30 > "$PACKET/diff-wide.patch"
git -C "$REPO" diff --stat "$BASE_REF"...HEAD > "$PACKET/changed-files.txt"

echo "packet refreshed: base=$BASE_REF files=$(wc -l < "$PACKET/manifest.txt" | tr -d ' ')"
