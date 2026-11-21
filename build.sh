#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/JXL Drop.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
rm -f "$APP/Icon"$'\r'
ARCH="$(uname -m)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jxl-drop-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -parse-as-library -O \
  -target "${ARCH}-apple-macosx13.0" \
  -framework SwiftUI \
  -framework AppKit \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  "$ROOT/JXLDrop.swift" \
  -o "$BUILD_DIR/JXL Drop"
mv "$BUILD_DIR/JXL Drop" "$APP/Contents/MacOS/JXL Drop"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
