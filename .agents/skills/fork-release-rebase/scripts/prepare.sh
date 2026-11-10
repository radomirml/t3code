#!/usr/bin/env bash
# Saves backup refs, makes a scratch worktree at the new tag and tries every fork
# branch there. A clean branch lands as <branch>-rb; a conflict is reported and
# aborted. Branches themselves are not moved.
#   prepare.sh <tag> [worktree-dir]
set -euo pipefail

tag=${1:?usage: prepare.sh <tag> [worktree-dir]}
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(git -C "$here" worktree list --porcelain | sed -n '1s/^worktree //p')
wt=${2:-"$(dirname "$repo")/t3code-rebase-${tag}"}
g() { git -C "$repo" "$@"; }

g fetch -q upstream --tags
g fetch -q upstream main
g rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || { echo "no tag $tag" >&2; exit 1; }
old=$(g describe --tags --abbrev=0 --match 'v*' --exclude '*-*' monitor)
echo "monitor is on $old; target $tag"
[ "$old" = "$tag" ] && { echo "already on $tag"; exit 0; }

mapfile -t rows < <(grep -vE '^\s*(#|$)' "$here/branches.txt" | awk '{print $1" "$2}')

echo "== backups (backup/pre-$tag/*)"
for b in monitor $(printf '%s\n' "${rows[@]}" | cut -d' ' -f1); do
  g rev-parse -q --verify "refs/heads/$b" >/dev/null || { echo "skip $b: no such branch"; continue; }
  if g rev-parse -q --verify "refs/heads/backup/pre-$tag/$b" >/dev/null; then
    echo "keep backup/pre-$tag/$b (exists)"
  else
    g branch "backup/pre-$tag/$b" "$b" && echo "saved backup/pre-$tag/$b"
  fi
done

if [ ! -e "$wt" ]; then
  g worktree add -q --detach "$wt" "$tag"
fi
echo "== trial in $wt"
w() { git -C "$wt" "$@"; }
for row in "${rows[@]}"; do
  read -r b base <<<"$row"
  g rev-parse -q --verify "refs/heads/$b" >/dev/null || { echo "SKIP     $b (no branch)"; continue; }
  [ "$base" = pr ] && { echo "SKIP     $b (open PR, not rebased)"; continue; }
  if [ "$base" = tag ]; then onto=$tag; from=$old; else onto=upstream/main; from=$(g merge-base "$b" upstream/main); fi
  if [ -z "$(g rev-list "$from..$b")" ]; then echo "SKIP     $b (no commits over $from)"; continue; fi
  w checkout -q --detach "$onto"
  if err=$(w cherry-pick "$from..$b" 2>&1); then
    w branch -f "$b-rb" HEAD
    echo "OK       $b -> $b-rb $(w rev-parse --short HEAD)"
  else
    files=$(w diff --name-only --diff-filter=U | tr '\n' ' ')
    if [ -n "$files" ]; then echo "CONFLICT $b: $files"; else echo "FAILED   $b: $(grep -m1 -E '^(fatal|error):' <<<"$err")"; fi
    w cherry-pick --abort 2>/dev/null || true
  fi
done
w checkout -q --detach "$tag"
echo "== monitor commits over $old (rebuild monitor from these)"
g log --oneline --reverse "$old..monitor"
