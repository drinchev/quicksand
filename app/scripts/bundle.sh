#!/bin/bash
# Build Quicksand.app from this package: a release build of the app and of
# qs-event (the brokers' event-log writer, shipped next to it), wrapped in a minimal bundle (status-bar only, no Dock icon) and signed
# ad hoc for this Mac. Output: app/build/Quicksand.app
#
#   app/scripts/bundle.sh            # build
#   open app/build/Quicksand.app     # run
#
# Install it where sandboxes can't write (it decides who a caller is):
# /Applications or ~/Applications. Extra arguments go to `swift build`
# (e.g. --disable-sandbox when building inside a quicksand sandbox).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APP_DIR/build/Quicksand.app"

swift build -c release --package-path "$APP_DIR" "$@"
BIN_DIR="$(swift build -c release --package-path "$APP_DIR" --show-bin-path "$@")"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$BIN_DIR/Quicksand" "$OUT/Contents/MacOS/Quicksand"
cp "$BIN_DIR/qs-event" "$OUT/Contents/MacOS/qs-event"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.quicksand.app</string>
    <key>CFBundleName</key><string>Quicksand</string>
    <key>CFBundleDisplayName</key><string>Quicksand</string>
    <key>CFBundleExecutable</key><string>Quicksand</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$OUT/Contents/MacOS/qs-event"
codesign --force --sign - "$OUT"
echo "Built $OUT"
