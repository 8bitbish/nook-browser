#!/usr/bin/env bash
# Build a signed Release Nook.app for this Mac (Apple Silicon) into personal-build/out/Nook.app.
# Follows CLAUDE.md's "Release build you can install and use", with the personal signing identity:
# coverage off, reduced entitlements (absolute path), no injected get-task-allow.
set -euo pipefail
cd "$(dirname "$0")/.."
source personal-build/env.sh

derived="$PWD/build-release"
out="$PWD/personal-build/out"

identities=$(security find-identity -v -p codesigning)
grep -qF "\"$NOOK_PERSONAL_SIGNING_IDENTITY\"" <<<"$identities" ||
  { echo "Signing identity \"$NOOK_PERSONAL_SIGNING_IDENTITY\" missing or untrusted."; exit 12; }

xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -arch arm64 \
  -derivedDataPath "$derived" \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  CODE_SIGN_IDENTITY="$NOOK_PERSONAL_SIGNING_IDENTITY" \
  CODE_SIGN_ENTITLEMENTS="$PWD/personal-build/Nook-personal.entitlements" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  build > "$PWD/personal-build/last-build.log" 2>&1 || true
grep -E "error:|\*\* BUILD" "$PWD/personal-build/last-build.log" | tail -20 || true

app="$derived/Build/Products/Release/Nook.app"
[ -d "$app" ] || { echo "Build produced no Nook.app"; exit 12; }
codesign --verify --deep --strict "$app" || { echo "Signature check failed"; exit 12; }
grep -qxF "Authority=$NOOK_PERSONAL_SIGNING_IDENTITY" <<<"$(codesign -dv --verbose=2 "$app" 2>&1)" ||
  { echo "Not signed by $NOOK_PERSONAL_SIGNING_IDENTITY"; exit 12; }
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow; then
  echo "Build carries get-task-allow"; exit 12
fi

rm -rf "$out" && mkdir -p "$out"
ditto "$app" "$out/Nook.app"
# Stamp the commit so sync.sh can tell what is installed, then re-seal the bundle.
/usr/libexec/PlistBuddy -c "Add :NookPersonalCommit string $(git rev-parse HEAD)" "$out/Nook.app/Contents/Info.plist"
codesign --force --options runtime --timestamp=none --sign "$NOOK_PERSONAL_SIGNING_IDENTITY" \
  --entitlements "$PWD/personal-build/Nook-personal.entitlements" "$out/Nook.app"
codesign --verify --deep --strict "$out/Nook.app" || { echo "Re-sealed app fails verification"; exit 12; }
# Build products are big and disk is tight; the next build starts from the package cache only.
rm -rf "$derived/Build" "$derived/Logs" "$derived/Index.noindex"
echo "Built $(defaults read "$out/Nook.app/Contents/Info" CFBundleShortVersionString) ($(git rev-parse --short HEAD)) -> $out/Nook.app"
