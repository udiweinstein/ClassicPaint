#!/bin/bash
# Builds ClassicPaint.app — requires only the Xcode Command Line Tools (xcode-select --install)
set -e
cd "$(dirname "$0")"
NAME="ClassicPaint"
APP="build/$NAME.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Compiling…"
# Universal binary: runs on Apple Silicon and Intel Macs
swiftc -O -target arm64-apple-macos11.0 -framework Cocoa -o "build/$NAME-arm64" Sources/ClassicPaint/*.swift
swiftc -O -target x86_64-apple-macos11.0 -framework Cocoa -o "build/$NAME-x86_64" Sources/ClassicPaint/*.swift
lipo -create "build/$NAME-arm64" "build/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
rm -f "build/$NAME-arm64" "build/$NAME-x86_64"
cp Info.plist "$APP/Contents/Info.plist"

echo "▸ Making icon…"
if "$APP/Contents/MacOS/$NAME" --make-icon build/icon.png; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "  (icon skipped)"
fi

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
rm -rf build/AppIcon.iconset build/icon.png
# Ready-to-share archive
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "📦 Share: build/$NAME.zip"
echo "✅ Done: $APP"
echo "   Run:  open $APP      (or drag it into /Applications)"
