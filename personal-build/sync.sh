#!/usr/bin/env bash
# Merge the newest stable upstream Nook release into `personal`, build and sign it, push
# `personal` to the fork, and install it on this Mac (now if Nook is closed, else on --restart).
# No binaries are published: "Nook" is upstream's trademark, and a modified build may only be
# run for yourself (TRADEMARK.md). Re-runnable. Exit codes:
#   1 preflight   10 merge conflicts to resolve   12 build failed   13 push failed
#   0 done (installed, already up to date, or built and waiting for Nook to close)
set -euo pipefail
cd "$(dirname "$0")/.."
source personal-build/env.sh

log_dir="$HOME/Library/Logs/nook-personal-sync"
mkdir -p "$log_dir"
log="$log_dir/$(date +%Y-%m-%d_%H%M%S).log"
exec > >(tee -a "$log") 2>&1

lock=.git/personal-sync.lock
mkdir "$lock" 2>/dev/null || { echo "Another sync is running (remove $lock if stale)."; exit 1; }
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

stage() { printf '\n==> %s\n' "$*"; }
stop() {
  echo "STOPPED ($2): $1"
  echo "Log: $log"
  nook_notify "Nook personal build stopped" "$1"
  exit "$2"
}
unmerged() { git diff --name-only --diff-filter=U; }

stage "Preflight"
[ "$(git branch --show-current)" = personal ] || stop "Not on the personal branch." 1
git config rerere.enabled true
git fetch -q --no-tags upstream '+refs/tags/v*:refs/tags/v*'
upstream_tag=$(nook_latest_upstream_tag)
echo "Newest stable upstream release: $upstream_tag"

stage "Merge"
if [ -f .git/MERGE_HEAD ]; then
  [ -z "$(unmerged)" ] || stop "Unresolved conflicts: $(unmerged | tr '\n' ' ')" 10
  if grep -qE '^\+(<<<<<<<|>>>>>>>) ' <<<"$(git diff --cached)"; then
    stop "Conflict markers are still staged." 10
  fi
  git commit -q --no-edit
  echo "Committed the resolved merge."
elif ! git diff --quiet || ! git diff --cached --quiet; then
  stop "Working tree has uncommitted changes." 1
elif git merge-base --is-ancestor "$upstream_tag" HEAD; then
  echo "Already contains $upstream_tag."
else
  if ! git merge -q --no-ff -m "Merge upstream $upstream_tag into personal" "$upstream_tag"; then
    # rerere may have replayed every earlier resolution; only genuinely new conflicts stop here.
    [ -z "$(unmerged)" ] || stop "Merging $upstream_tag conflicts in: $(unmerged | tr '\n' ' ')" 10
    git commit -q --no-edit
    echo "Merged $upstream_tag using recorded resolutions."
  else
    echo "Merged $upstream_tag cleanly."
  fi
fi

head=$(git rev-parse HEAD)
installed=$(defaults read /Applications/Nook.app/Contents/Info NookPersonalCommit 2>/dev/null || true)
if [ "$installed" = "$head" ]; then
  git push -q origin personal || stop "Pushing personal to the fork failed." 13
  echo "Installed Nook is already $head. Nothing to do."
  exit 0
fi

stage "Build"
personal-build/build.sh || stop "Build failed (personal-build/last-build.log)." 12

stage "Push"
git push -q origin personal || stop "Pushing personal to the fork failed." 13

stage "Install"
if personal-build/install.sh "$@"; then
  echo "Installed Nook from $upstream_tag + personal ($(git rev-parse --short HEAD))."
  nook_notify "Nook personal build installed" "Upstream $upstream_tag plus personal fixes."
else
  echo "Built but not installed: Nook is open. Run personal-build/install.sh --restart when convenient."
  nook_notify "Nook update ready" "Quit Nook, or run install.sh --restart, to install $upstream_tag."
fi
