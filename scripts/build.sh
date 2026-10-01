#!/bin/bash
# Builds and signs Tiler.app (SPEC §6).
#
#   scripts/build.sh [--dev] [--scratch-path <dir>] [--out-dir <dir>]
#
#   --dev             bundle id dev.ninja.tiler.dev, output out/dev/Tiler.app
#                     (default: dev.ninja.tiler, output out/Tiler.app)
#   --scratch-path    SwiftPM scratch directory (default .build)
#   --out-dir         directory that receives Tiler.app (default out, or out/dev with --dev)
#
# Signs with the "ninja-codesign" identity when the keychain has it, so the Accessibility
# grant survives rebuilds; otherwise signs ad hoc and warns. Prints the app path last.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEV=0
SCRATCH=".build"
OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dev) DEV=1 ;;
        --scratch-path)
            [ $# -ge 2 ] || { echo "error: --scratch-path needs a directory" >&2; exit 2; }
            SCRATCH="$2"; shift ;;
        --out-dir)
            [ $# -ge 2 ] || { echo "error: --out-dir needs a directory" >&2; exit 2; }
            OUT_DIR="$2"; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$DEV" = 1 ]; then
    BUNDLE_ID="dev.ninja.tiler.dev"
    OUT_DIR="${OUT_DIR:-$ROOT/out/dev}"
else
    BUNDLE_ID="dev.ninja.tiler"
    OUT_DIR="${OUT_DIR:-$ROOT/out}"
fi
mkdir -p "$OUT_DIR"
APP="$(cd "$OUT_DIR" && pwd)/Tiler.app"
VERSION="1.0.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="ninja-codesign"

echo "==> swift build -c release ($SCRATCH)"
swift build -c release --scratch-path "$SCRATCH" --product Tiler
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Tiler" "$APP/Contents/MacOS/Tiler"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Tiler</string>
    <key>CFBundleExecutable</key>
    <string>Tiler</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Tiler</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing ($BUNDLE_ID)"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "warning: code-signing identity \"$IDENTITY\" not found; signing ad hoc." >&2
    echo "warning: the Accessibility grant will not survive rebuilds (re-grant after each build)." >&2
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"

echo "$APP"
