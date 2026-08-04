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
#
# manifest.txt is the agents' AUTHORITATIVE file list (prompts/_packet.txt tells
# them to read it rather than guess paths), so any file that reaches diff.patch
# but not the manifest is a file the review never sees — it reads as unchanged.
# 0.9.1 fixed one instance of that by swapping `ls` for `ls -A`; the same class
# then recurred on a MIXED diff (.github/workflows/ci.yml + pyproject.toml
# reported files=1). Hence the two rules below, which close the class rather
# than another instance of it:
#   - path handling must survive EVERY form git emits (dot-dirs, spaces,
#     C-quoted non-ASCII, renames, binary, mode-only, flatten collisions), and
#   - the three counts (diff.patch headers / manifest entries / files/ splits)
#     are cross-checked and a mismatch hard-fails. Silence was the whole bug.
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

# Per-file split — eliminates output-truncation re-read loops. manifest.txt is
# emitted by awk itself, in diff order: `ls` (even `ls -A`) round-trips the
# names through the filesystem and back, which is what silently dropped
# dot-leading entries, and it re-sorts by locale collation for no benefit.
rm -rf "$PACKET/files"; mkdir -p "$PACKET/files"
: > "$PACKET/manifest.txt"   # must exist even if the split yields nothing
awk -v outdir="$PACKET/files" -v manifest="$PACKET/manifest.txt" '
  # Git C-quotes a path holding non-ASCII, a quote, or a control char:
  #   diff --git "a/caf\303\251.py" "b/caf\303\251.py"
  # Strip the wrapper but KEEP the escapes as literal text — un-escaping could
  # put a newline back into a name manifest.txt lists one-per-line.
  function unwrap(p) {
    if (substr(p, 1, 1) == "\"" && substr(p, length(p), 1) == "\"")
      p = substr(p, 2, length(p) - 2)
    return p
  }
  # `--- `/`+++ ` gain a trailing TAB when the path contains a space. A literal
  # tab inside a path is always C-quoted, so the first tab is never content.
  function detab(p)    { sub(/\t.*$/, "", p);  return p }
  function deprefix(p) { sub(/^[ab]\//, "", p); return p }

  # Last resort: the `diff --git` header itself (binary and mode-only changes
  # carry no ---/+++ lines).
  function from_header(h,   rest, n, L, P) {
    rest = substr(h, 12)                       # past "diff --git "
    if (substr(rest, 1, 1) == "\"") {
      # `"a/P" "b/P"`. C-quoting escapes every embedded quote, so the `" "`
      # seam between the halves occurs exactly once.
      n = index(rest, "\" \"")
      if (n == 0) return ""
      P = substr(rest, n + 3); sub(/"$/, "", P)
      return deprefix(P)
    }
    # `a/P b/P` with P identical, so length(rest) = 2 + len(P) + 1 + 2 + len(P).
    # Halves differ only for renames/copies, which always carry a `rename to`/
    # `copy to` line resolved before we get here. This arithmetic is the only
    # parse that survives spaces in P — the old `$4` field split silently
    # returned "dir" for `a/sub dir/x.txt b/sub dir/x.txt`.
    L = (length(rest) - 5) / 2
    if (L > 0 && substr(rest, 1, 2) == "a/" && substr(rest, 3 + L, 3) == " b/")
      return substr(rest, 3, L)
    return ""
  }

  function open_out(   p, name, k, i) {
    p = ""
    if      (plus  != "" && plus  != "/dev/null") p = deprefix(unwrap(detab(plus)))
    else if (rto   != "")                         p = unwrap(rto)
    else if (minus != "" && minus != "/dev/null") p = deprefix(unwrap(detab(minus)))
    if (p == "") p = from_header(hdr)
    gsub(/\//, "__", p)
    gsub(/[[:cntrl:]]/, "_", p)                # keep manifest.txt line-oriented
    # Never drop a block we could not name: a synthetic name still gets the
    # hunks in front of the agents, and keeps the counts honest.
    if (p == "") p = "unparsed-" (++unparsed)
    name = p ".patch"; k = 1
    # Distinct paths can flatten to the same name (a/b__c.py vs a__b/c.py).
    # Merging two files into one patch would hide one of them.
    while (name in used) { k++; name = p "~" k ".patch" }
    used[name] = 1
    print name > manifest
    if (out != "") close(out)
    out = outdir "/" name
    for (i = 1; i <= nb; i++) print buf[i] > out
    nb = 0; collecting = 0
  }
  function finish() { if (collecting) open_out() }

  /^diff --git / {
    finish()
    hdr = $0; nb = 0; rto = ""; plus = ""; minus = ""; collecting = 1
    buf[++nb] = $0
    next
  }
  collecting {
    buf[++nb] = $0
    if      (substr($0, 1, 10) == "rename to ") rto   = substr($0, 11)
    else if (substr($0, 1, 8)  == "copy to ")   rto   = substr($0, 9)
    else if (substr($0, 1, 4)  == "+++ ")       plus  = substr($0, 5)
    else if (substr($0, 1, 4)  == "--- ")       minus = substr($0, 5)
    # The header ends at the first hunk/binary marker; the body then streams
    # straight through instead of being buffered. Only header lines are read
    # for names, so a removed body line rendering as "--- foo" cannot confuse
    # the resolver.
    if ($0 ~ /^@@ / || $0 ~ /^GIT binary patch/ || $0 ~ /^Binary files /) open_out()
    next
  }
  out { print > out }
  END { finish(); if (out != "") close(out) }
' "$PACKET/diff.patch"

# Self-check. These three counts describe the same set of files; if they
# disagree the packet is lying about its own contents, and the failure mode is
# silent under-reporting, so hard-fail instead of printing a smaller number.
HDRS=$(grep -c '^diff --git ' "$PACKET/diff.patch" || true)
MANI=$(wc -l < "$PACKET/manifest.txt" | tr -d ' ')
SPLITS=$(find "$PACKET/files" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')
[ "$HDRS" -gt 0 ] \
  || die "diff.patch has no 'diff --git' headers — gh returned something that is not a patch; refusing to build a vacuous packet"
[ "$HDRS" -eq "$MANI" ] && [ "$MANI" -eq "$SPLITS" ] \
  || die "packet split inconsistent: diff.patch has $HDRS file headers, manifest.txt lists $MANI, files/ holds $SPLITS — agents read manifest.txt as the file list, so a mismatch means files go silently unreviewed"

git -C "$REPO" diff "$BASE_REF"...HEAD -U30 > "$PACKET/diff-wide.patch"
git -C "$REPO" diff --stat "$BASE_REF"...HEAD > "$PACKET/changed-files.txt"

echo "packet refreshed: base=$BASE_REF files=$HDRS"
