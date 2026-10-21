#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== package-check ==="

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# --- Step 1: build the app ---
echo "[build] Running scripts/package-app.sh..."
"$REPO_ROOT/scripts/package-app.sh"
echo "[build] PASS: package-app.sh succeeded"

APP="$REPO_ROOT/dist/OnlyWallpapers.app"

# --- Step 2: structure asserts ---
echo "[struct] Checking .app structure..."

if [ -x "$APP/Contents/MacOS/OnlyWallpapers" ]; then
    pass "binary exists and is executable: $APP/Contents/MacOS/OnlyWallpapers"
else
    fail "binary missing or not executable: $APP/Contents/MacOS/OnlyWallpapers"
fi

LIPO_ARCHS="$(lipo -archs "$APP/Contents/MacOS/OnlyWallpapers" 2>/dev/null || true)"
if echo "$LIPO_ARCHS" | grep -qw "x86_64" && echo "$LIPO_ARCHS" | grep -qw "arm64"; then
    pass "binary is universal (lipo -archs: $LIPO_ARCHS)"
else
    fail "binary is NOT universal (lipo -archs: $LIPO_ARCHS); expected both x86_64 and arm64"
fi

APP_BUNDLE_WEB="$APP/Contents/Resources/OnlyWallpapers_OnlyWallpapers.bundle/Contents/Resources/web"
for _asset in index.html style.css wallpaper.js; do
    if [ -f "$APP_BUNDLE_WEB/$_asset" ]; then
        pass "app bundle web/$_asset exists"
    else
        fail "app bundle web/$_asset missing: $APP_BUNDLE_WEB/$_asset"
    fi
done

if [ -f "$APP/Contents/Info.plist" ]; then
    pass "Info.plist exists"
else
    fail "Info.plist missing: $APP/Contents/Info.plist"
fi

if plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    pass "Info.plist is valid XML plist"
else
    fail "Info.plist failed plutil lint"
fi

LSUIElement="$(defaults read "$APP/Contents/Info" LSUIElement 2>/dev/null || true)"
if [ "$LSUIElement" = "1" ] || [ "$LSUIElement" = "true" ]; then
    fail "LSUIElement is true (app would have no Dock icon): '$LSUIElement'"
else
    pass "LSUIElement not true (regular app with a Dock icon; got: '${LSUIElement:-<absent>}')"
fi

ICON_KEY="$(defaults read "$APP/Contents/Info" CFBundleIconFile 2>/dev/null || true)"
if [ -n "$ICON_KEY" ]; then
    pass "CFBundleIconFile=$ICON_KEY"
else
    fail "CFBundleIconFile missing from Info.plist"
fi
if [ -n "$ICON_KEY" ] && [ -f "$APP/Contents/Resources/${ICON_KEY%.icns}.icns" ]; then
    pass "icon file exists in app: Contents/Resources/${ICON_KEY%.icns}.icns"
else
    fail "icon file named by CFBundleIconFile ('$ICON_KEY') missing in $APP/Contents/Resources"
fi
if cmp -s "$REPO_ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; then
    pass "app icon is byte-identical to packaging/AppIcon.icns"
else
    fail "app icon differs from (or is missing vs) packaging/AppIcon.icns"
fi

CFBundleExecutable="$(defaults read "$APP/Contents/Info" CFBundleExecutable 2>/dev/null || true)"
if [ "$CFBundleExecutable" = "OnlyWallpapers" ]; then
    pass "CFBundleExecutable=OnlyWallpapers"
else
    fail "CFBundleExecutable wrong (got: '$CFBundleExecutable')"
fi

# FIX 7: assert both location plist keys are present.
NSLocUsage="$(defaults read "$APP/Contents/Info" NSLocationUsageDescription 2>/dev/null || true)"
if [[ -n "$NSLocUsage" ]]; then
    pass "NSLocationUsageDescription present: ${NSLocUsage:0:60}..."
else
    fail "NSLocationUsageDescription missing or empty in Info.plist"
fi

NSLocWhenInUse="$(defaults read "$APP/Contents/Info" NSLocationWhenInUseUsageDescription 2>/dev/null || true)"
if [[ -n "$NSLocWhenInUse" ]]; then
    pass "NSLocationWhenInUseUsageDescription present: ${NSLocWhenInUse:0:60}..."
else
    fail "NSLocationWhenInUseUsageDescription missing or empty in Info.plist"
fi

# --- Step 2b: release packaging asserts (ow-t4r.1, ow-t4r.3) ---
echo "[release] Checking black default, identity, signature, zip..."
VERSION_EXPECT="$(grep -E '^VERSION=' "$REPO_ROOT/scripts/package-app.sh" | head -1 | sed -E 's/^VERSION="([^"]*)".*/\1/')"
BUILD_EXPECT="$(grep -E '^BUILD_NUMBER=' "$REPO_ROOT/scripts/package-app.sh" | head -1 | sed -E 's/^BUILD_NUMBER="([^"]*)".*/\1/')"

MP4_FOUND="$(find "$APP" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.m4v' \) 2>/dev/null)"
if [ -z "$MP4_FOUND" ]; then
    pass "packaged app contains NO video files (black default)"
else
    fail "packaged app contains video files: $MP4_FOUND"
fi

BUNDLE_ID_GOT="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
if [ "$BUNDLE_ID_GOT" = "com.anoopsanthanam.onlywallpapers" ]; then
    pass "CFBundleIdentifier=$BUNDLE_ID_GOT"
else
    fail "CFBundleIdentifier wrong (got: '$BUNDLE_ID_GOT')"
fi

SHORT_VER="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
if [ -n "$VERSION_EXPECT" ] && [ "$SHORT_VER" = "$VERSION_EXPECT" ]; then
    pass "CFBundleShortVersionString=$SHORT_VER (matches package-app.sh VERSION)"
else
    fail "CFBundleShortVersionString wrong (got: '$SHORT_VER', expected '$VERSION_EXPECT')"
fi

BUILD_VER="$(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || true)"
if [[ "$BUILD_VER" =~ ^[0-9]+$ ]] && [ "$BUILD_VER" = "$BUILD_EXPECT" ]; then
    pass "CFBundleVersion=$BUILD_VER (matches package-app.sh BUILD_NUMBER)"
else
    fail "CFBundleVersion wrong (got: '$BUILD_VER', expected '$BUILD_EXPECT')"
fi

COPYRIGHT="$(defaults read "$APP/Contents/Info" NSHumanReadableCopyright 2>/dev/null || true)"
if [ "$COPYRIGHT" = "Copyright (c) 2026 Anoop Santhanam" ]; then
    pass "NSHumanReadableCopyright=$COPYRIGHT"
else
    fail "NSHumanReadableCopyright wrong (got: '$COPYRIGHT')"
fi

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    pass "ad-hoc signature verifies (codesign --verify --deep --strict)"
else
    fail "codesign --verify --deep --strict failed on $APP"
fi
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
    pass "signature is ad-hoc"
else
    fail "signature is not ad-hoc"
fi

ZIP="$REPO_ROOT/dist/OnlyWallpapers-$VERSION_EXPECT.zip"
if [ -f "$ZIP" ]; then
    pass "zip exists: $ZIP"
else
    fail "zip missing: $ZIP"
fi
if [ -f "$ZIP.sha256" ]; then
    pass "sha256 file exists: $ZIP.sha256"
    WANT_SUM="$(cut -d' ' -f1 "$ZIP.sha256")"
    GOT_SUM="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    if [ -n "$WANT_SUM" ] && [ "$WANT_SUM" = "$GOT_SUM" ]; then
        pass "zip checksum matches sha256 file ($GOT_SUM)"
    else
        fail "zip checksum mismatch (file: $WANT_SUM, actual: $GOT_SUM)"
    fi
else
    fail "sha256 file missing: $ZIP.sha256"
fi

LATEST_ZIP="$REPO_ROOT/dist/OnlyWallpapers.zip"
if [ -f "$LATEST_ZIP" ]; then
    pass "unversioned zip exists: $LATEST_ZIP"
else
    fail "unversioned zip missing: $LATEST_ZIP"
fi
if [ -f "$LATEST_ZIP.sha256" ]; then
    pass "unversioned sha256 file exists: $LATEST_ZIP.sha256"
    WANT_SUM="$(cut -d' ' -f1 "$LATEST_ZIP.sha256")"
    GOT_SUM="$(shasum -a 256 "$LATEST_ZIP" | cut -d' ' -f1)"
    if [ -n "$WANT_SUM" ] && [ "$WANT_SUM" = "$GOT_SUM" ]; then
        pass "unversioned zip checksum matches sha256 file ($GOT_SUM)"
    else
        fail "unversioned zip checksum mismatch (file: $WANT_SUM, actual: $GOT_SUM)"
    fi
else
    fail "unversioned sha256 file missing: $LATEST_ZIP.sha256"
fi
if cmp -s "$ZIP" "$LATEST_ZIP"; then
    pass "unversioned zip is byte-identical to the versioned zip"
else
    fail "unversioned zip differs from the versioned zip"
fi
if (cd "$REPO_ROOT/dist" && shasum -a 256 -c "OnlyWallpapers.zip.sha256" >/dev/null 2>&1); then
    pass "shasum -c verifies OnlyWallpapers.zip.sha256"
else
    fail "shasum -c failed for OnlyWallpapers.zip.sha256"
fi

# Quarantine simulation: signature must still verify; spctl rejection is EXPECTED (unsigned/ad-hoc).
Q_DIR="$(mktemp -d)"
cp -R "$APP" "$Q_DIR/OnlyWallpapers.app"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$Q_DIR/OnlyWallpapers.app"
if xattr -p com.apple.quarantine "$Q_DIR/OnlyWallpapers.app" >/dev/null 2>&1 \
   && codesign --verify --deep --strict "$Q_DIR/OnlyWallpapers.app" 2>/dev/null; then
    pass "quarantined copy still passes codesign --verify"
else
    fail "quarantined copy failed codesign --verify (or xattr not applied)"
fi
SPCTL_RC=0
SPCTL_OUT="$(spctl --assess --type execute -v "$Q_DIR/OnlyWallpapers.app" 2>&1)" || SPCTL_RC=$?
echo "[spctl] exit=$SPCTL_RC output: $(echo "$SPCTL_OUT" | tr '\n' ' ')"
if [ "$SPCTL_RC" -ne 0 ]; then
    pass "spctl rejects the ad-hoc signed, non-notarized, quarantined copy as expected (exit $SPCTL_RC)"
else
    fail "spctl unexpectedly ACCEPTED the ad-hoc signed, non-notarized, quarantined copy (exit 0): $SPCTL_OUT"
fi
# Q_DIR is kept: the quarantine-cleared copy is launched below (after the launch helpers exist).

# --- Step 3: standalone run from a temp dir ---
echo "[standalone] Copying .app to temp dir outside repo..."
TMP_DIR=""
APP_PID=""

PKG_OW_SUPPORT_TMP=""
cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -INT "$APP_PID" 2>/dev/null || true
        kill -TERM -"$APP_PID" 2>/dev/null || true
        sleep 0.4
        pkill -P "$APP_PID" 2>/dev/null || true
        kill -KILL -"$APP_PID" 2>/dev/null || true
        kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    [[ -n "$PKG_OW_SUPPORT_TMP" ]] && rm -rf "$PKG_OW_SUPPORT_TMP" || true
    [[ -n "${Q_DIR:-}" ]] && rm -rf "$Q_DIR" || true
    [[ -n "${Q_STORE:-}" ]] && rm -rf "$Q_STORE" || true
    [[ -n "${ACT_STORE:-}" ]] && rm -rf "$ACT_STORE" || true
}
trap cleanup EXIT

TMP_DIR="$(mktemp -d)"
cp -R "$APP" "$TMP_DIR/OnlyWallpapers.app"
TMP_APP="$TMP_DIR/OnlyWallpapers.app"
TMP_BIN="$TMP_APP/Contents/MacOS/OnlyWallpapers"

echo "[standalone] Temp app: $TMP_APP"

TMPOUT="$(mktemp)"
# mktemp gives us a file; move it under TMP_DIR so cleanup catches it
mv "$TMPOUT" "$TMP_DIR/stdout.txt"
TMPOUT="$TMP_DIR/stdout.txt"

# Change cwd to outside the repo so the app cannot accidentally find source-tree files
cd "$TMP_DIR"
PKG_OW_SUPPORT_TMP="$(mktemp -d)"
if command -v setsid >/dev/null 2>&1; then
    OW_APP_SUPPORT_DIR="$PKG_OW_SUPPORT_TMP" env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON setsid "$TMP_BIN" >"$TMPOUT" 2>&1 &
else
    OW_APP_SUPPORT_DIR="$PKG_OW_SUPPORT_TMP" env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON "$TMP_BIN" >"$TMPOUT" 2>&1 &
fi
APP_PID=$!
echo "[standalone] PID=$APP_PID"

# --- Poll for ONLYWALLPAPERS_READY (up to 8s) ---
READY=0
for i in $(seq 1 80); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "FAIL: standalone app exited before emitting READY line"
        cat "$TMPOUT" || true
        FAIL_COUNT=$((FAIL_COUNT + 1))
        APP_PID=""
        break
    fi
    if grep -q "ONLYWALLPAPERS_READY" "$TMPOUT" 2>/dev/null; then
        READY=1
        break
    fi
    sleep 0.1
done

if [ $READY -ne 1 ]; then
    echo "FAIL: ONLYWALLPAPERS_READY never appeared"
    cat "$TMPOUT" || true
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo ""
    echo "=== FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed ==="
    exit 1
fi

# --- Poll for WEB_RESOLVE (up to 8s) ---
RESOLVED=0
for i in $(seq 1 80); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    if grep -q "ONLYWALLPAPERS_WEB_RESOLVE" "$TMPOUT" 2>/dev/null; then
        RESOLVED=1
        break
    fi
    sleep 0.1
done

# --- Assert READY policy=regular ---
READY_LINE="$(grep "ONLYWALLPAPERS_READY" "$TMPOUT" | head -1 || true)"
if echo "$READY_LINE" | grep -Eq 'policy=regular( |$)'; then
    pass "READY policy=regular: $READY_LINE"
else
    fail "READY missing policy=regular: $READY_LINE"
fi

# --- Assert WEB_RESOLVE status=ok source=appstore ---
RESOLVE_LINE="$(grep "ONLYWALLPAPERS_WEB_RESOLVE" "$TMPOUT" | head -1 || true)"
if echo "$RESOLVE_LINE" | grep -Eq 'status=ok source=appstore( |$)'; then
    pass "WEB_RESOLVE status=ok source=appstore"
else
    fail "WEB_RESOLVE wrong (expected source=appstore): $RESOLVE_LINE"
    echo "--- output ---"
    cat "$TMPOUT" || true
    echo ""
    echo "=== FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed ==="
    exit 1
fi

# --- Assert byte equality of seeded code files vs app bundle originals (FIX 9) ---
APP_BUNDLE_WEB="$TMP_APP/Contents/Resources/OnlyWallpapers_OnlyWallpapers.bundle/Contents/Resources/web"
echo "[byte-eq] Checking seeded code files are byte-identical to app bundle originals..."
PKG_BYTE_EQ_FAIL=0
for _name in index.html style.css wallpaper.js; do
    _seeded="$PKG_OW_SUPPORT_TMP/web/$_name"
    _bundle_orig="$APP_BUNDLE_WEB/$_name"
    if [[ ! -f "$_seeded" ]]; then
        fail "byte-eq: seeded file missing: $_seeded"
        PKG_BYTE_EQ_FAIL=1
    elif [[ ! -f "$_bundle_orig" ]]; then
        fail "byte-eq: app bundle original missing: $_bundle_orig"
        PKG_BYTE_EQ_FAIL=1
    elif ! cmp -s "$_seeded" "$_bundle_orig"; then
        fail "byte-eq: $_name differs between seeded and app bundle"
        PKG_BYTE_EQ_FAIL=1
    else
        pass "byte-eq: $_name byte-identical to app bundle"
    fi
done
if [[ $PKG_BYTE_EQ_FAIL -ne 0 ]]; then
    echo "--- output ---"
    cat "$TMPOUT" || true
    echo "=== FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed ==="
    exit 1
fi

# --- Assert resolve dir is under PKG_OW_SUPPORT_TMP (app-storage temp), not .build ---
# dir= is the last field and the path may contain spaces: take everything after it.
RESOLVE_DIR="$(printf '%s\n' "$RESOLVE_LINE" | sed -n 's/^.* dir=//p' | head -1 || true)"
echo "[standalone] Resolved dir: $RESOLVE_DIR"

norm() { cd "$1" 2>/dev/null && pwd -P; }
EXPECT_APPSTORE="$PKG_OW_SUPPORT_TMP/web"

if printf '%s\n' "$RESOLVE_DIR" | grep -qF "/.build/"; then
    fail "Resolve dir contains /.build/ (source tree, not appstore): $RESOLVE_DIR"
elif [[ "$RESOLVE_DIR" == "$PKG_OW_SUPPORT_TMP"* ]]; then
    pass "Resolve dir is under app-storage temp dir: $RESOLVE_DIR"
    SEED_LINE="$(grep 'ONLYWALLPAPERS_SEED' "$TMPOUT" | head -1 || true)"
    if echo "$SEED_LINE" | grep -q 'status=ok'; then
        # source= is followed by dest=; the paths may contain spaces, so split on the field labels.
        SEED_SRC="$(printf '%s\n' "$SEED_LINE" | sed -n 's/^.* source=\(.*\) dest=.*$/\1/p' | head -1 || true)"
        if [[ "$SEED_SRC" == "$TMP_APP/"* ]]; then
            pass "SEED source path is inside temp .app bundle (not .build)"
        else
            if printf '%s\n' "$SEED_SRC" | grep -qF "/.build/"; then
                fail "SEED source contains /.build/ (should be inside the .app bundle): $SEED_LINE"
            else
                pass "SEED source is not from .build: $SEED_LINE"
            fi
        fi
    else
        fail "SEED line missing or not status=ok: $SEED_LINE"
    fi
else
    fail "Resolve dir is not under PKG_OW_SUPPORT_TMP. resolved=$RESOLVE_DIR expect=$EXPECT_APPSTORE"
fi

# --- Poll for WINDOWS count ---
WIN_LINE=""
for i in $(seq 1 50); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    WIN_LINE="$(grep "ONLYWALLPAPERS_WINDOWS count=" "$TMPOUT" 2>/dev/null | head -1 || true)"
    if [ -n "$WIN_LINE" ]; then
        break
    fi
    sleep 0.1
done

SCREEN_COUNT=0
if [ -n "$WIN_LINE" ]; then
    SCREEN_COUNT="$(echo "$WIN_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')"
fi

if [ "$SCREEN_COUNT" -gt 0 ]; then
    pass "WINDOWS count=$SCREEN_COUNT (>0, gate requirement met)"
else
    fail "WINDOWS count=0 or line missing (gate requires at least one display)"
    echo "--- output ---"
    cat "$TMPOUT" || true
    echo ""
    echo "=== FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed ==="
    exit 1
fi

# --- Poll for STATUSITEM created=true (up to 3s) ---
STATUSITEM_LINE=""
for i in $(seq 1 30); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    STATUSITEM_LINE="$(grep "ONLYWALLPAPERS_STATUSITEM" "$TMPOUT" | head -1 || true)"
    if [ -n "$STATUSITEM_LINE" ]; then break; fi
    sleep 0.1
done
if echo "$STATUSITEM_LINE" | grep -Eq 'created=true( |$)'; then
    pass "STATUSITEM created=true"
else
    fail "STATUSITEM not created=true: $STATUSITEM_LINE"
fi
if echo "$STATUSITEM_LINE" | grep -Eq 'about=true( |$)'; then
    pass "STATUSITEM menu contains About item (about=true)"
else
    fail "STATUSITEM menu missing About item: $STATUSITEM_LINE"
fi

# --- Poll for N loaded=ok lines (up to 10s) ---
echo "[standalone] Polling for $SCREEN_COUNT ONLYWALLPAPERS_WEB loaded=ok lines..."
WEB_OK=0
for i in $(seq 1 100); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    WEB_OK_COUNT="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT" 2>/dev/null || true)"
    if [ "$WEB_OK_COUNT" -ge "$SCREEN_COUNT" ]; then
        WEB_OK=1
        break
    fi
    sleep 0.1
done

if [ $WEB_OK -ne 1 ]; then
    WEB_OK_COUNT="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT" 2>/dev/null || true)"
    fail "Expected $SCREEN_COUNT loaded=ok gen=0 lines, got $WEB_OK_COUNT within 10s"
    echo "--- output ---"
    cat "$TMPOUT" || true
    echo ""
    echo "=== FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed ==="
    exit 1
fi

# --- Fresh install with no video: seeded assets dir must hold no video (black default) ---
if [ -z "$(find "$PKG_OW_SUPPORT_TMP/web/assets" -type f \( -iname '*.mp4' -o -iname '*.mov' \) 2>/dev/null)" ]; then
    pass "fresh install seeded NO video into app storage (black wallpaper)"
else
    fail "fresh install unexpectedly has a video in app storage"
fi
if grep -q "ONLYWALLPAPERS_FIRSTRUN" "$TMPOUT" 2>/dev/null; then
    fail "first-run alert appeared under test env (would block gates)"
else
    pass "first-run alert suppressed under test env"
fi

# --- Assert zero loaded=fail ---
FAIL_WEB="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT" 2>/dev/null || true)"
if [ "$FAIL_WEB" -eq 0 ]; then
    pass "No loaded=fail lines"
else
    fail "$FAIL_WEB loaded=fail line(s) found"
fi

# --- Assert N distinct win= values in loaded=ok gen=0 lines ---
DISTINCT_WINS="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT" \
    | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
if [ "$DISTINCT_WINS" -ge "$SCREEN_COUNT" ]; then
    pass "$SCREEN_COUNT loaded=ok gen=0 lines with $DISTINCT_WINS distinct win= values"
else
    fail "Expected $SCREEN_COUNT distinct win= values in loaded=ok gen=0 lines, found $DISTINCT_WINS"
fi

# --- No-video path: the app must be quiet (no JS errors, no media errors) ---
# Media probes: ONLYWALLPAPERS_MEDIA at +2.0s and media=<state> t=2.5 after load.
echo "[novideo] Waiting for media diagnostics (no video installed)..."
for i in $(seq 1 100); do
    kill -0 "$APP_PID" 2>/dev/null || break
    NV_MEDIA_N="$(grep -c 'ONLYWALLPAPERS_MEDIA win=' "$TMPOUT" 2>/dev/null || true)"
    NV_STATE_N="$(grep -cE 'ONLYWALLPAPERS_WEB screen=.* media=[a-z]+ t=2\.5' "$TMPOUT" 2>/dev/null || true)"
    if [ "$NV_MEDIA_N" -ge "$SCREEN_COUNT" ] && [ "$NV_STATE_N" -ge "$SCREEN_COUNT" ]; then break; fi
    sleep 0.1
done
if [ "$NV_MEDIA_N" -ge "$SCREEN_COUNT" ]; then
    pass "no-video: MEDIA diagnostic logged for all $SCREEN_COUNT screen(s)"
else
    fail "no-video: expected $SCREEN_COUNT ONLYWALLPAPERS_MEDIA lines, got $NV_MEDIA_N"
fi
NV_JS="$(grep 'ONLYWALLPAPERS_JS' "$TMPOUT" 2>/dev/null || true)"
if [ -z "$NV_JS" ]; then
    pass "no-video: no JS error/rejection/console.error logged"
else
    fail "no-video: JS errors logged: $NV_JS"
fi
NV_MEDIA_ERR="$(grep 'ONLYWALLPAPERS_MEDIA win=' "$TMPOUT" | grep -v 'error=none' || true)"
if [ -z "$NV_MEDIA_ERR" ]; then
    pass "no-video: no media element error (error=none on every screen)"
else
    fail "no-video: media error reported: $NV_MEDIA_ERR"
fi
# Expected quiet state: NETWORK_NO_SOURCE (3), nothing loaded (readyState 0), no current source.
NV_MEDIA_BAD="$(grep 'ONLYWALLPAPERS_MEDIA win=' "$TMPOUT" | grep -vE 'networkState=3 readyState=0 error=none currentSrc=none' || true)"
if [ -z "$NV_MEDIA_BAD" ]; then
    pass "no-video: video element in the quiet no-source state (networkState=3 readyState=0 currentSrc=none)"
else
    fail "no-video: video element not in the quiet no-source state: $NV_MEDIA_BAD"
fi
# WebKit's page-level playback state is informational: it reports 'playing' even with no source.
echo "[novideo] info: WebKit playback states: $(grep -oE 'media=[a-z]+ t=[0-9.]+' "$TMPOUT" | sort | uniq -c | tr '\n' ';')"
NV_NOISE="$(grep -iE 'error|exception|fatal|crash|terminated|failed to' "$TMPOUT" | grep -vE '^ONLYWALLPAPERS_MEDIA win=[0-9]+ .*error=none' || true)"
if [ -z "$NV_NOISE" ]; then
    pass "no-video: no error/exception/crash text anywhere in the app output"
else
    fail "no-video: error text in app output: $NV_NOISE"
fi

# --- SIGINT and confirm clean exit ---
echo "[standalone] Sending SIGINT..."
kill -INT "$APP_PID"
kill -TERM -"$APP_PID" 2>/dev/null || true
GONE=0
for i in $(seq 1 20); do
    sleep 0.05
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        GONE=1
        break
    fi
done

pkill -P "$APP_PID" 2>/dev/null || true
kill -KILL -"$APP_PID" 2>/dev/null || true
kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true

if [ $GONE -ne 1 ]; then
    fail "Process did not exit within 1s of SIGINT"
else
    STATUS=0; wait "$APP_PID" 2>/dev/null || STATUS=$?
    if [ "$STATUS" -eq 0 ]; then
        pass "Process exited cleanly (status=0) on SIGINT"
    else
        fail "Process exited with status=$STATUS on SIGINT (expected 0)"
    fi
fi
APP_PID=""

# --- Assert no orphaned app processes ---
sleep 0.2
if pgrep -f "$TMP_BIN" >/dev/null 2>&1; then
    fail "Orphaned app process after teardown (pgrep matched $TMP_BIN)"
else
    pass "No orphaned app process after teardown"
fi

# --- First-run lifecycle + About gate (ow-t4r) ---
echo "[firstrun] Launching packaged app with OW_FIRSTRUN_TEST=1 and OW_ABOUT_TEST=1..."
FR_STORE="$(mktemp -d)"
FR_OUT1="$TMP_DIR/firstrun1.txt"
FR_OUT2="$TMP_DIR/firstrun2.txt"

stop_app() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -INT "$APP_PID" 2>/dev/null || true
        sleep 0.4
        pkill -P "$APP_PID" 2>/dev/null || true
        kill -KILL -"$APP_PID" 2>/dev/null || true
        kill -KILL "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    APP_PID=""
}

# launch_app <outfile> [VAR=val ...]
launch_app() {
    local out="$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
            OW_APP_SUPPORT_DIR="${LAUNCH_STORE:-$FR_STORE}" "$@" setsid "${LAUNCH_BIN:-$TMP_BIN}" >"$out" 2>&1 &
    else
        env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
            OW_APP_SUPPORT_DIR="${LAUNCH_STORE:-$FR_STORE}" "$@" "${LAUNCH_BIN:-$TMP_BIN}" >"$out" 2>&1 &
    fi
    APP_PID=$!
}

launch_app "$FR_OUT1" OW_FIRSTRUN_TEST=1 OW_ABOUT_TEST=1

# About check fires ~3.5s after launch, after the first-run alert (shown ~1s, auto-dismissed ~1s later).
for i in $(seq 1 100); do
    kill -0 "$APP_PID" 2>/dev/null || break
    grep -q "ONLYWALLPAPERS_ABOUT_CHECK" "$FR_OUT1" 2>/dev/null && break
    sleep 0.1
done
sleep 0.3

if grep -q "ONLYWALLPAPERS_FIRSTRUN shown=true" "$FR_OUT1"; then
    pass "first launch (OW_FIRSTRUN_TEST=1) logs FIRSTRUN shown=true"
else
    fail "first launch did not log FIRSTRUN shown=true"
fi
if grep -q "ONLYWALLPAPERS_FIRSTRUN dismissed=true" "$FR_OUT1"; then
    pass "first-run alert auto-dismissed in test mode"
else
    fail "first-run alert was not dismissed (modal still blocking)"
fi
FR_SCREENS="$(grep -o 'ONLYWALLPAPERS_WINDOWS count=[0-9]*' "$FR_OUT1" | head -1 | sed 's/.*count=//' || true)"
FR_WEB_OK="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$FR_OUT1" 2>/dev/null || true)"
FR_WEB_FAIL="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$FR_OUT1" 2>/dev/null || true)"
if [ -n "$FR_SCREENS" ] && [ "$FR_SCREENS" -gt 0 ] && [ "$FR_WEB_OK" -ge "$FR_SCREENS" ] && [ "$FR_WEB_FAIL" -eq 0 ]; then
    pass "wallpaper loaded ok on all $FR_SCREENS screen(s) with first-run alert dismissed (ok=$FR_WEB_OK fail=$FR_WEB_FAIL)"
else
    fail "wallpaper load after first-run dismissal wrong (screens=$FR_SCREENS ok=$FR_WEB_OK fail=$FR_WEB_FAIL)"
fi
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "app still running after first-run dismissal"
else
    fail "app exited during first-run dismissal"
fi
if grep -Eq '"firstRunHintShown" *: *true' "$FR_STORE/config.json" 2>/dev/null; then
    pass "config.json contains firstRunHintShown true"
else
    fail "config.json missing firstRunHintShown true: $(cat "$FR_STORE/config.json" 2>/dev/null || echo '<none>')"
fi

ABOUT_LINE="$(grep 'ONLYWALLPAPERS_ABOUT_CHECK' "$FR_OUT1" | head -1 || true)"
if echo "$ABOUT_LINE" | grep -Eq 'visible=true( |$)'; then
    pass "About panel window visible via menu item action"
else
    fail "About panel not visible: '$ABOUT_LINE'"
fi
VERSION_RE="${VERSION_EXPECT//./\\.}"
if echo "$ABOUT_LINE" | grep -Eq "version=${VERSION_RE}( |\$)"; then
    pass "About panel version=$VERSION_EXPECT"
else
    fail "About version wrong: '$ABOUT_LINE'"
fi
if echo "$ABOUT_LINE" | grep -Eq 'credits_links=2( |$)'; then
    pass "About credits contain 2 links"
else
    fail "About credits_links wrong: '$ABOUT_LINE'"
fi
stop_app

echo "[firstrun] Second launch, same store..."
launch_app "$FR_OUT2" OW_FIRSTRUN_TEST=1
for i in $(seq 1 60); do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.1
done
if grep -q "ONLYWALLPAPERS_READY" "$FR_OUT2" && ! grep -q "ONLYWALLPAPERS_FIRSTRUN shown=true" "$FR_OUT2"; then
    pass "second launch with same store does not show the first-run hint"
else
    fail "second launch showed the hint again or never became ready"
fi
stop_app
rm -rf "$FR_STORE"

# --- Rendered-pixel gate (ow-t4r.1): snapshot every web view, black default must be black ---
# snapshot_launch <outfile> <store> [VAR=val ...]: launch with OW_SNAPSHOT_TEST=1, wait for one SNAPSHOT line per screen.
snapshot_launch() {
    local out="$1" store="$2"; shift 2
    LAUNCH_STORE="$store" launch_app "$out" OW_SNAPSHOT_TEST=1 "$@"
    for i in $(seq 1 150); do
        kill -0 "$APP_PID" 2>/dev/null || break
        [ "$(grep -c 'ONLYWALLPAPERS_SNAPSHOT screen=' "$out" 2>/dev/null || true)" -ge "$SCREEN_COUNT" ] && break
        sleep 0.1
    done
    stop_app
}
# snapshot_max <outfile>: prints the highest max= across all SNAPSHOT lines.
snapshot_max() {
    grep 'ONLYWALLPAPERS_SNAPSHOT screen=' "$1" | sed -n 's/.* max=\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1
}

echo "[snapshot] Black-default launch with OW_SNAPSHOT_TEST=1..."
SNAP_STORE="$(mktemp -d)"
SNAP_OUT="$TMP_DIR/snapshot-black.txt"
snapshot_launch "$SNAP_OUT" "$SNAP_STORE"
SNAP_N="$(grep -c 'ONLYWALLPAPERS_SNAPSHOT screen=' "$SNAP_OUT" 2>/dev/null || true)"
SNAP_DISTINCT="$(grep 'ONLYWALLPAPERS_SNAPSHOT screen=' "$SNAP_OUT" | grep -o 'screen=[0-9]*' | sort -u | wc -l | tr -d ' ')"
if [ "$SNAP_N" -eq "$SCREEN_COUNT" ] && [ "$SNAP_DISTINCT" -eq "$SCREEN_COUNT" ]; then
    pass "snapshot: exactly one SNAPSHOT line per screen ($SNAP_N for $SCREEN_COUNT screen(s))"
else
    fail "snapshot: expected $SCREEN_COUNT distinct SNAPSHOT lines, got $SNAP_N lines / $SNAP_DISTINCT screens"
fi
SNAP_BAD_SIZE="$(grep 'ONLYWALLPAPERS_SNAPSHOT screen=' "$SNAP_OUT" | grep -vE ' w=[1-9][0-9]* h=[1-9][0-9]* ' || true)"
if [ "$SNAP_N" -gt 0 ] && [ -z "$SNAP_BAD_SIZE" ]; then
    pass "snapshot: every snapshot has nonzero size"
else
    fail "snapshot: zero-size or missing snapshot: ${SNAP_BAD_SIZE:-<no SNAPSHOT lines>}"
fi
SNAP_BLACK_MAX="$(snapshot_max "$SNAP_OUT")"
if [ -n "$SNAP_BLACK_MAX" ] && [ "$SNAP_BLACK_MAX" -le 8 ]; then
    pass "snapshot: black-default wallpaper renders black on every screen (max channel $SNAP_BLACK_MAX <= 8)"
else
    fail "snapshot: black-default wallpaper is NOT black (max channel '${SNAP_BLACK_MAX:-none}')"
    grep 'ONLYWALLPAPERS_SNAPSHOT' "$SNAP_OUT" || true
fi

# Falsifiability: a non-black fixture must be detected, proving the gate can fail.
echo "[snapshot] Falsifiability launch with a white-background fixture..."
SNAP_FIX="$(mktemp -d)"
cp -R "$SNAP_STORE/web/." "$SNAP_FIX/"
printf '\nhtml,body,#stage{background:#fff !important}\n' >> "$SNAP_FIX/style.css"
SNAP_FIX_STORE="$(mktemp -d)"
SNAP_FIX_OUT="$TMP_DIR/snapshot-white.txt"
snapshot_launch "$SNAP_FIX_OUT" "$SNAP_FIX_STORE" WALLPAPER_WEB_DIR="$SNAP_FIX"
SNAP_WHITE_MAX="$(snapshot_max "$SNAP_FIX_OUT")"
if [ -n "$SNAP_WHITE_MAX" ] && [ "$SNAP_WHITE_MAX" -gt 8 ]; then
    pass "snapshot falsifiability: non-black fixture detected (max channel $SNAP_WHITE_MAX > 8)"
else
    fail "snapshot falsifiability: white fixture NOT detected (max channel '${SNAP_WHITE_MAX:-none}'); the gate cannot fail"
    grep 'ONLYWALLPAPERS_SNAPSHOT' "$SNAP_FIX_OUT" || true
fi
rm -rf "$SNAP_STORE" "$SNAP_FIX" "$SNAP_FIX_STORE"

# --- Dock activation: windows must keep the desktop level after activate + simulated reopen ---
echo "[activate] Launching with OW_ACTIVATE_TEST=1..."
ACT_STORE="$(mktemp -d)"
ACT_OUT="$TMP_DIR/activate.txt"
LAUNCH_STORE="$ACT_STORE" launch_app "$ACT_OUT" OW_ACTIVATE_TEST=1
for i in $(seq 1 120); do
    kill -0 "$APP_PID" 2>/dev/null || break
    grep -q "ONLYWALLPAPERS_ACTIVATE_CHECK" "$ACT_OUT" 2>/dev/null && break
    sleep 0.1
done
ACT_LINE="$(grep 'ONLYWALLPAPERS_ACTIVATE_CHECK' "$ACT_OUT" | head -1 || true)"
ACT_WINS="$(echo "$ACT_LINE" | sed -n 's/.*windows=\([0-9]*\).*/\1/p')"
ACT_OK="$(echo "$ACT_LINE" | sed -n 's/.*desktop_ok=\([0-9]*\).*/\1/p')"
echo "[activate] $ACT_LINE"
if [ -n "$ACT_WINS" ] && [ "$ACT_WINS" -gt 0 ] && [ "$ACT_WINS" = "$ACT_OK" ]; then
    pass "after activate + reopen, all $ACT_WINS wallpaper window(s) keep desktop level, click-through, below icons, not key, on screen"
else
    fail "activation check wrong (windows=$ACT_WINS desktop_ok=$ACT_OK): $ACT_LINE"
    grep 'ONLYWALLPAPERS_ACTIVATE_WINDOW' "$ACT_OUT" || true
fi
if echo "$ACT_LINE" | grep -Eq 'reopen_handled=false( |$)'; then
    pass "Dock reopen is not handled by AppKit (no window brought forward)"
else
    fail "reopen_handled not false: $ACT_LINE"
fi
ACT_LEVELS="$(grep 'ONLYWALLPAPERS_ACTIVATE_WINDOW' "$ACT_OUT" | grep -c 'level_ok=true below_icons=true click_through=true not_key=true on_screen=true visible=true active_space=true' || true)"
if [ "$ACT_LEVELS" = "$ACT_WINS" ] && [ "$ACT_LEVELS" -gt 0 ]; then
    pass "every ACTIVATE_WINDOW line reports level_ok/below_icons/click_through/not_key/on_screen/active_space all true ($ACT_LEVELS)"
else
    fail "ACTIVATE_WINDOW lines wrong (ok=$ACT_LEVELS of $ACT_WINS)"
fi
ACT_DISTINCT="$(grep 'ONLYWALLPAPERS_ACTIVATE_WINDOW' "$ACT_OUT" | sed -n 's/.*win=\([0-9]*\).*/\1/p' | sort -u | wc -l | tr -d ' ')"
if [ "$SCREEN_COUNT" -gt 0 ] && [ "$ACT_DISTINCT" = "$SCREEN_COUNT" ]; then
    pass "ACTIVATE_WINDOW records cover every screen ($ACT_DISTINCT distinct win= for $SCREEN_COUNT screen(s))"
else
    fail "ACTIVATE_WINDOW distinct windows ($ACT_DISTINCT) != screen count ($SCREEN_COUNT)"
fi
stop_app
rm -rf "$ACT_STORE"; ACT_STORE=""

# --- Quarantine path: clear quarantine, then really launch the copy ---
echo "[quarantine] Clearing quarantine and launching the copy..."
Q_APP="$Q_DIR/OnlyWallpapers.app"
xattr -dr com.apple.quarantine "$Q_APP"
Q_LEFT="$(xattr -rl "$Q_APP" 2>/dev/null | grep -c 'com.apple.quarantine' || true)"
Q_LEFT_FILES="$(find "$Q_APP" -exec sh -c 'xattr -p com.apple.quarantine "$1" >/dev/null 2>&1 && echo "$1"' _ {} \; | wc -l | tr -d ' ')"
if [ "$Q_LEFT" = "0" ] && [ "$Q_LEFT_FILES" = "0" ]; then
    pass "no quarantine xattr remains on any file after xattr -dr"
else
    fail "quarantine xattr remains (xattr -rl hits=$Q_LEFT, files=$Q_LEFT_FILES)"
fi
if codesign --verify --deep --strict "$Q_APP" 2>/dev/null; then
    pass "quarantine-cleared copy passes codesign --verify"
else
    fail "quarantine-cleared copy failed codesign --verify"
fi
Q_STORE="$(mktemp -d)"
Q_OUT="$TMP_DIR/quarantine.txt"
LAUNCH_BIN="$Q_APP/Contents/MacOS/OnlyWallpapers" LAUNCH_STORE="$Q_STORE" launch_app "$Q_OUT"
for i in $(seq 1 100); do
    kill -0 "$APP_PID" 2>/dev/null || break
    Q_WIN_LINE="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$Q_OUT" 2>/dev/null | head -1 || true)"
    if [ -n "$Q_WIN_LINE" ]; then
        Q_SCREENS="$(echo "$Q_WIN_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')"
        [ "$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$Q_OUT" 2>/dev/null || true)" -ge "$Q_SCREENS" ] && break
    fi
    sleep 0.1
done
Q_SCREENS="${Q_SCREENS:-0}"
Q_OK="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$Q_OUT" 2>/dev/null || true)"
Q_FAIL="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$Q_OUT" 2>/dev/null || true)"
if [ "$Q_SCREENS" -gt 0 ] && [ "$Q_OK" -ge "$Q_SCREENS" ] && [ "$Q_FAIL" -eq 0 ]; then
    pass "quarantine-cleared copy reached loaded=ok on all $Q_SCREENS screen(s) (fail=$Q_FAIL)"
else
    fail "quarantine-cleared copy did not load (screens=$Q_SCREENS ok=$Q_OK fail=$Q_FAIL)"
    cat "$Q_OUT" || true
fi
Q_PID="$APP_PID"
kill -INT "$Q_PID" 2>/dev/null || true
Q_GONE=0
for i in $(seq 1 40); do
    if ! kill -0 "$Q_PID" 2>/dev/null; then Q_GONE=1; break; fi
    sleep 0.05
done
if [ $Q_GONE -eq 1 ]; then
    Q_STATUS=0; wait "$Q_PID" 2>/dev/null || Q_STATUS=$?
    if [ "$Q_STATUS" -eq 0 ]; then
        pass "quarantine-cleared copy terminated cleanly (status=0)"
    else
        fail "quarantine-cleared copy exited with status=$Q_STATUS"
    fi
    APP_PID=""
else
    fail "quarantine-cleared copy did not exit within 2s of SIGINT"
    stop_app
fi
rm -rf "$Q_STORE" "$Q_DIR"; Q_STORE=""; Q_DIR=""

echo ""
if [ $FAIL_COUNT -eq 0 ]; then
    echo "=== PASS: all $PASS_COUNT checks passed ==="
else
    echo "--- full output ---"
    cat "$TMPOUT" || true
    echo ""
    echo "=== FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed ==="
    exit 1
fi
