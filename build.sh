#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
OUTPUT_APP="$SOURCE_DIR/Project Center.app"
PC_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/project-center-build.XXXXXX")"
STAGED_APP="$PC_BUILD_DIR/Project Center.app"
MODULE_CACHE="/tmp/project-center-module-cache"

cleanup() {
    rm -rf "$PC_BUILD_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$MODULE_CACHE"

env \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
    xcrun swiftc -O -target arm64-apple-macosx13.0 -framework AppKit \
    "$SOURCE_DIR/main.swift" \
    -o "$STAGED_APP/Contents/MacOS/ProjectCenter"

cp "$SOURCE_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$SOURCE_DIR/projects.json" "$STAGED_APP/Contents/Resources/projects.json"
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$STAGED_APP" >/dev/null
codesign --verify --deep --strict "$STAGED_APP"

# Replace the local artifact only after a complete, signed build succeeds.
rm -rf "$OUTPUT_APP"
mv "$STAGED_APP" "$OUTPUT_APP"

print "Built: $OUTPUT_APP"
