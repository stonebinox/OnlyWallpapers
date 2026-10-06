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

APP_BUNDLE_WEB="$APP/OnlyWallpapers_OnlyWallpapers.bundle/web"
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
if [ "$LSUIElement" = "1" ]; then
    pass "LSUIElement=true (accessory, no Dock icon)"
else
    fail "LSUIElement not true (got: '$LSUIElement')"
fi

CFBundleExecutable="$(defaults read "$APP/Contents/Info" CFBundleExecutable 2>/dev/null || true)"
if [ "$CFBundleExecutable" = "OnlyWallpapers" ]; then
    pass "CFBundleExecutable=OnlyWallpapers"
else
    fail "CFBundleExecutable wrong (got: '$CFBundleExecutable')"
fi

# --- Step 3: standalone run from a temp dir ---
echo "[standalone] Copying .app to temp dir outside repo..."
TMP_DIR=""
APP_PID=""

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
if command -v setsid >/dev/null 2>&1; then
    env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST setsid "$TMP_BIN" >"$TMPOUT" 2>&1 &
else
    env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST "$TMP_BIN" >"$TMPOUT" 2>&1 &
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

# --- Assert READY policy=accessory ---
READY_LINE="$(grep "ONLYWALLPAPERS_READY" "$TMPOUT" | head -1 || true)"
if echo "$READY_LINE" | grep -Eq 'policy=accessory( |$)'; then
    pass "READY policy=accessory: $READY_LINE"
else
    fail "READY missing policy=accessory: $READY_LINE"
fi

# --- Assert WEB_RESOLVE status=ok source=bundle ---
RESOLVE_LINE="$(grep "ONLYWALLPAPERS_WEB_RESOLVE" "$TMPOUT" | head -1 || true)"
if echo "$RESOLVE_LINE" | grep -Eq 'status=ok source=bundle( |$)'; then
    pass "WEB_RESOLVE status=ok source=bundle"
else
    fail "WEB_RESOLVE wrong: $RESOLVE_LINE"
    echo "--- output ---"
    cat "$TMPOUT" || true
    echo ""
    echo "=== FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed ==="
    exit 1
fi

# --- Assert resolve dir is EXACTLY the app's own bundle web dir, not .build ---
RESOLVE_DIR="$(echo "$RESOLVE_LINE" | grep -oE 'dir=[^ ]+' | head -1 | sed 's/^dir=//' || true)"
echo "[standalone] Resolved dir: $RESOLVE_DIR"

norm() { cd "$1" 2>/dev/null && pwd -P; }
EXPECT="$TMP_APP/OnlyWallpapers_OnlyWallpapers.bundle/web"

if echo "$RESOLVE_DIR" | grep -q "/.build/"; then
    fail "Resolve dir contains /.build/ (bundle was not found; fallback to source tree): $RESOLVE_DIR"
else
    NORM_RESOLVE="$(norm "$RESOLVE_DIR" || true)"
    NORM_EXPECT="$(norm "$EXPECT" || true)"
    if [ "$NORM_RESOLVE" = "$NORM_EXPECT" ]; then
        pass "Resolve dir is exactly app bundle web dir: $RESOLVE_DIR"
    else
        fail "Resolve dir mismatch. resolved=$RESOLVE_DIR expect=$EXPECT"
    fi
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

# --- Assert STATUSITEM created=true ---
STATUSITEM_LINE="$(grep "ONLYWALLPAPERS_STATUSITEM" "$TMPOUT" | head -1 || true)"
if echo "$STATUSITEM_LINE" | grep -Eq 'created=true( |$)'; then
    pass "STATUSITEM created=true"
else
    fail "STATUSITEM not created=true: $STATUSITEM_LINE"
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
