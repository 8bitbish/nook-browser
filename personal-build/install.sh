#!/usr/bin/env bash
# Install personal-build/out.noindex/Nook.app over /Applications/Nook.app, keeping Jake's data.
# Same bundle id (com.gstudios.nook), so the new app reads the same Application Support,
# WebKit data and defaults. Backs those up first and keeps the previous app for rollback.
#   install.sh           refuses while Nook is running
#   install.sh --restart quits Nook, installs, reopens it
set -euo pipefail
cd "$(dirname "$0")/.."
source personal-build/env.sh

new="$PWD/personal-build/out.noindex/Nook.app"
target=/Applications/Nook.app
backups="$HOME/Backups/nook"
stamp=$(date +%Y-%m-%d_%H%M%S)

[ -d "$new" ] || { echo "No build at $new (run personal-build/build.sh)."; exit 1; }
codesign --verify --deep --strict "$new" || { echo "$new fails signature verification."; exit 1; }

running=false
pgrep -qf "$target/Contents/MacOS/Nook" && running=true
if $running; then
  [ "${1:-}" = --restart ] || { echo "Nook is running. Quit it first, or run with --restart."; exit 2; }
  osascript -e 'quit app "Nook"'
  for _ in $(seq 1 30); do pgrep -qf "$target/Contents/MacOS/Nook" || break; sleep 1; done
  pgrep -qf "$target/Contents/MacOS/Nook" && { echo "Nook did not quit."; exit 2; }
fi

# Data backup: tab/space state, history, settings, site data. Keep the last 5.
mkdir -p "$backups/data-$stamp"
ditto "$HOME/Library/Application Support/com.gstudios.nook" "$backups/data-$stamp/Application Support"
[ -d "$HOME/Library/WebKit/com.gstudios.nook" ] &&
  ditto "$HOME/Library/WebKit/com.gstudios.nook" "$backups/data-$stamp/WebKit"
cp "$HOME/Library/Preferences/com.gstudios.nook.plist" "$backups/data-$stamp/" 2>/dev/null || true
ls -d "$backups"/data-* | sort -r | tail -n +6 | while read -r old; do rm -rf "$old"; done

# Previous app, for rollback: ditto "$backups/previous/Nook.app" /Applications/Nook.app
if [ -d "$target" ]; then
  rm -rf "$backups/previous" && mkdir -p "$backups/previous"
  ditto "$target" "$backups/previous/Nook.app"
fi
rm -rf "$target"
ditto "$new" "$target"
echo "Installed $(defaults read "$target/Contents/Info" CFBundleShortVersionString) signed by $NOOK_PERSONAL_SIGNING_IDENTITY. Backup: $backups/data-$stamp"

$running && open -a "$target"
exit 0
