#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== package-app: building OnlyWallpapers.app ==="

echo "[build] swift build -c release --product OnlyWallpapers -Xswiftc -warnings-as-errors"
swift build -c release --product OnlyWallpapers -Xswiftc -warnings-as-errors
echo "[build] PASS"

BIN_PATH="$(swift build -c release --product OnlyWallpapers --show-bin-path)"
echo "[bin] BIN_PATH=$BIN_PATH"

APP="$REPO_ROOT/dist/OnlyWallpapers.app"
echo "[app] Target: $APP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN_PATH/OnlyWallpapers" "$APP/Contents/MacOS/OnlyWallpapers"
echo "[app] Copied binary to Contents/MacOS/OnlyWallpapers"

cp -R "$BIN_PATH/OnlyWallpapers_OnlyWallpapers.bundle" "$APP/OnlyWallpapers_OnlyWallpapers.bundle"
echo "[app] Copied resource bundle to app root (Bundle.module resolves via Bundle.main.bundleURL)"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.onlywallpapers.OnlyWallpapers</string>
    <key>CFBundleExecutable</key>
    <string>OnlyWallpapers</string>
    <key>CFBundleName</key>
    <string>OnlyWallpapers</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "[plist] Written $APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
echo "[plist] PASS: plutil lint ok"

echo ""
echo "Built: $APP"
echo "=== PASS: OnlyWallpapers.app assembled ==="
