#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox
STAGING_DIR=$(mktemp -d /private/tmp/menumixer.XXXXXX)
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/Menu Mixer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MenuMixer "$APP/Contents/MacOS/MenuMixer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.menumixer.app "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p build
# Sign/package outside the cloud-backed workspace so File Provider metadata
# cannot contaminate the distributable. The ZIP is the verified artifact.
ditto -c -k --norsrc --keepParent "$APP" "$PWD/build/Menu Mixer.zip"
ditto --norsrc "$APP" "$PWD/build/Menu Mixer.app"
xattr -dr com.apple.FinderInfo "$PWD/build/Menu Mixer.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$PWD/build/Menu Mixer.app" 2>/dev/null || true
printf 'Built: %s\nVerified package: %s\n' "$PWD/build/Menu Mixer.app" "$PWD/build/Menu Mixer.zip"
