#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== package-app: building OnlyWallpapers.app ==="

echo "[build] swift build -c release --arch arm64 --arch x86_64 --product OnlyWallpapers -Xswiftc -warnings-as-errors"
swift build -c release --arch arm64 --arch x86_64 --product OnlyWallpapers -Xswiftc -warnings-as-errors
echo "[build] PASS"

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --product OnlyWallpapers --show-bin-path)"
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
    <key>NSLocationUsageDescription</key>
    <string>OnlyWallpapers uses your approximate location to determine local sunrise and sunset times and fetch current weather conditions for adaptive wallpaper tinting. Coordinates are rounded to 2 decimal places before any network request.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>OnlyWallpapers uses your approximate location to determine local sunrise and sunset times and fetch current weather conditions for adaptive wallpaper tinting. Coordinates are rounded to 2 decimal places before any network request.</string>
</dict>
</plist>
PLIST

echo "[plist] Written $APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
echo "[plist] PASS: plutil lint ok"

echo "[universal] Verifying binary is universal (arm64 + x86_64)..."
LIPO_ARCHS="$(lipo -archs "$APP/Contents/MacOS/OnlyWallpapers")"
echo "[universal] lipo -archs: $LIPO_ARCHS"
if echo "$LIPO_ARCHS" | grep -qw "x86_64" && echo "$LIPO_ARCHS" | grep -qw "arm64"; then
    echo "[universal] PASS: binary contains both x86_64 and arm64"
else
    echo "[universal] FAIL: expected both x86_64 and arm64, got: $LIPO_ARCHS"
    exit 1
fi

echo ""
echo "Built: $APP"
echo "=== PASS: OnlyWallpapers.app assembled (universal binary: arm64 + x86_64) ==="
