#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== OnlyWallpapers smoke-run ==="

# --- Step 8: scope guard (run before build to catch forbidden symbols early) ---
echo "[scope] Checking Sources tree for forbidden identifiers..."

# WKWebView and WKWebViewConfiguration are allowed only in WebSpikeWindow.swift and WebWallpaperView.swift.
HITS_WK="$(grep -rnE 'WKWebView|WKWebViewConfiguration' Sources/ --include='*.swift' \
    --exclude='WebSpikeWindow.swift' --exclude='WebWallpaperView.swift' || true)"
if [ -n "$HITS_WK" ]; then echo "FAIL: WKWebView/WKWebViewConfiguration found outside WebSpikeWindow.swift or WebWallpaperView.swift"; echo "$HITS_WK"; exit 1; fi

# didChangeScreenParametersNotification and Info.plist are forbidden in ALL Swift files.
HITS_FORBIDDEN="$(grep -rnE 'didChangeScreenParametersNotification|Info\.plist' Sources/ --include='*.swift' || true)"
if [ -n "$HITS_FORBIDDEN" ]; then echo "FAIL: forbidden symbol(s) in Sources/"; echo "$HITS_FORBIDDEN"; exit 1; fi

# NSWindow is forbidden in all Swift files EXCEPT WallpaperWindow.swift and WebSpikeWindow.swift.
HITS_NSWINDOW="$(grep -rnE '\bNSWindow\b' Sources/ --include='*.swift' \
    --exclude='WallpaperWindow.swift' --exclude='WebSpikeWindow.swift' || true)"
if [ -n "$HITS_NSWINDOW" ]; then echo "FAIL: NSWindow found outside WallpaperWindow.swift or WebSpikeWindow.swift"; echo "$HITS_NSWINDOW"; exit 1; fi

echo "[scope] PASS: no forbidden symbols found"

# --- Step 8b: static setActivationPolicy guard ---
echo "[scope] Checking setActivationPolicy is called exactly once and set to .accessory..."
SAP_COUNT="$(grep -rno 'setActivationPolicy' Sources/ --include='*.swift' | wc -l | tr -d ' ')"
if [ "$SAP_COUNT" != "1" ]; then echo "FAIL: expected exactly one setActivationPolicy call, found $SAP_COUNT"; exit 1; fi
if ! grep -rq 'setActivationPolicy(.accessory)' Sources/ --include='*.swift'; then echo "FAIL: the single setActivationPolicy call is not .accessory"; exit 1; fi
echo "[scope] PASS: setActivationPolicy(.accessory) called exactly once"

# --- Step 9: package structure check ---
echo "[pkg] Checking swift package describe..."
PKG_DESC="$(swift package describe 2>&1)"
if ! echo "$PKG_DESC" | grep -q "OnlyWallpapers"; then
    echo "FAIL: 'swift package describe' does not list OnlyWallpapers"
    echo "$PKG_DESC"
    exit 1
fi
echo "[pkg] PASS: OnlyWallpapers product/target present in package description"

# --- Step 1: build with warnings-as-errors ---
echo "[build] Building with warnings-as-errors..."
swift build --product OnlyWallpapers -Xswiftc -warnings-as-errors
echo "[build] PASS: build succeeded"

# --- Step 2: locate built binary ---
BIN="$(swift build --product OnlyWallpapers --show-bin-path)/OnlyWallpapers"
echo "[bin] Binary path: $BIN"

# --- Launch and poll ---
TMPOUT="$(mktemp)"
cleanup() {
    if [[ -n "${PID:-}" ]]; then
        if kill -0 "$PID" 2>/dev/null; then
            kill -INT "$PID" 2>/dev/null || true
            sleep 0.4
            if kill -0 "$PID" 2>/dev/null; then
                kill -KILL "$PID" 2>/dev/null || true
            fi
        fi
        wait "$PID" 2>/dev/null || true
    fi
    rm -f "$TMPOUT"
}
trap cleanup EXIT

# --- Step 3: launch binary in background ---
echo "[launch] Starting $BIN..."
env -u OW_SPIKE -u OW_WEBSPIKE "$BIN" >"$TMPOUT" 2>&1 &
PID=$!
echo "[launch] PID: $PID"

# --- Step 5: poll up to 5s for ready line ---
echo "[ready] Polling for ONLYWALLPAPERS_READY (up to 5s)..."
READY=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "FAIL: process exited before emitting ready line"
        echo "--- stdout ---"
        cat "$TMPOUT" || true
        exit 1
    fi
    if grep -q "ONLYWALLPAPERS_READY" "$TMPOUT" 2>/dev/null; then
        READY=1
        break
    fi
    sleep 0.1
done

if [[ $READY -ne 1 ]]; then
    echo "FAIL: ready line never appeared within 5s"
    echo "--- stdout ---"
    cat "$TMPOUT" || true
    exit 1
fi

READY_LINE="$(grep "ONLYWALLPAPERS_READY" "$TMPOUT" | head -1)"
echo "[ready] Got: $READY_LINE"

# Confirm policy=accessory (not policy=OTHER:*)
if ! echo "$READY_LINE" | grep -q "policy=accessory"; then
    echo "FAIL: ready line does not show policy=accessory: $READY_LINE"
    exit 1
fi
echo "[ready] PASS: policy=accessory confirmed"

# Confirm process still alive after ready line
if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: process was not alive when ready line was checked"
    exit 1
fi

# --- Step 6: require process to stay alive for ~2s after ready ---
echo "[alive] Verifying process stays alive for 2s after ready..."
sleep 2
if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: process died within 2s of ready line (crash-after-launch)"
    exit 1
fi
echo "[alive] PASS: process still alive after 2s"

# --- Step 7a: verify WallpaperWindow placement (default run only) ---
echo "[windows] Checking ONLYWALLPAPERS_WINDOWS count line..."
WINDOWS_LINE="$(grep "ONLYWALLPAPERS_WINDOWS count=" "$TMPOUT" | head -1 || true)"
if [ -z "$WINDOWS_LINE" ]; then
    echo "FAIL: ONLYWALLPAPERS_WINDOWS count= line not found in output"
    echo "--- output ---"
    cat "$TMPOUT" || true
    exit 1
fi
SCREEN_COUNT="$(echo "$WINDOWS_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')"
echo "[windows] Screen count: $SCREEN_COUNT"

if [ "$SCREEN_COUNT" -eq 0 ]; then
    echo "[windows] PASS: count=0, no window placement assertions needed"
else
    # Poll up to 3s for SCREEN_COUNT ONLYWALLPAPERS_WINDOW lines to appear (asyncAfter 0.5s).
    for i in $(seq 1 30); do
        WINDOW_LINE_COUNT="$(grep -c "^ONLYWALLPAPERS_WINDOW " "$TMPOUT" 2>/dev/null || true)"
        if [ "$WINDOW_LINE_COUNT" -ge "$SCREEN_COUNT" ]; then
            break
        fi
        sleep 0.1
    done

    # Require exactly N lines (>= already broke the poll; re-count to catch both < N and > N).
    WINDOW_LINE_COUNT="$(grep -c "^ONLYWALLPAPERS_WINDOW " "$TMPOUT" 2>/dev/null || true)"
    if [ "$WINDOW_LINE_COUNT" -ne "$SCREEN_COUNT" ]; then
        echo "FAIL: expected exactly $SCREEN_COUNT ONLYWALLPAPERS_WINDOW line(s), found $WINDOW_LINE_COUNT"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    # Require N distinct win= values (win= is always unique; screen= names can collide on identical monitors).
    DISTINCT_WINS="$(grep "^ONLYWALLPAPERS_WINDOW " "$TMPOUT" \
        | grep -o 'win=[0-9]*' \
        | sort -u \
        | wc -l \
        | tr -d ' ')"
    if [ "$DISTINCT_WINS" -ne "$SCREEN_COUNT" ]; then
        echo "FAIL: expected $SCREEN_COUNT distinct win= value(s), found $DISTINCT_WINS (one window may be logging twice)"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    EXPECTED_LEVEL="-2147483623"
    BAD=0
    while IFS= read -r wline; do
        SCREEN_LABEL="$(echo "$wline" | grep -o 'screen=[^ ]*' | head -1)"
        if ! echo "$wline" | grep -q "level=${EXPECTED_LEVEL}"; then
            echo "FAIL: wrong level in $SCREEN_LABEL: $wline"
            BAD=1
        fi
        if ! echo "$wline" | grep -q "zorder_ok=true"; then
            echo "FAIL: zorder_ok not true in $SCREEN_LABEL: $wline"
            BAD=1
        fi
        if ! echo "$wline" | grep -q "mouse=true"; then
            echo "FAIL: mouse not true (click-through not set) in $SCREEN_LABEL: $wline"
            BAD=1
        fi
        if ! echo "$wline" | grep -q "cb_allspaces=true"; then
            echo "FAIL: cb_allspaces not true in $SCREEN_LABEL: $wline"
            BAD=1
        fi
        if ! echo "$wline" | grep -q "cb_stationary=true"; then
            echo "FAIL: cb_stationary not true in $SCREEN_LABEL: $wline"
            BAD=1
        fi
        if ! echo "$wline" | grep -q "cb_ignorescycle=true"; then
            echo "FAIL: cb_ignorescycle not true in $SCREEN_LABEL: $wline"
            BAD=1
        fi
    done < <(grep "^ONLYWALLPAPERS_WINDOW " "$TMPOUT")

    if [ "$BAD" -ne 0 ]; then
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    echo "[windows] PASS: $SCREEN_COUNT window(s) at level=$EXPECTED_LEVEL with zorder_ok=true mouse=true cb_allspaces=true cb_stationary=true cb_ignorescycle=true, all on distinct win= numbers"
fi

# --- Step 7b: verify WKWebView web-load (poll up to 8s for WebKit cold-spawn) ---
echo "[webload] Checking ONLYWALLPAPERS_WEB loaded=ok lines (up to 8s)..."
if [ "$SCREEN_COUNT" -eq 0 ]; then
    echo "[webload] PASS: count=0, no web-load assertions needed"
else
    # (a) Require index_exists=true line to appear; hard-fail if missing or index_exists=false found.
    WEB_DIR_OK=0
    for i in $(seq 1 80); do
        if grep -q 'ONLYWALLPAPERS_WEB dir=.*index_exists=true' "$TMPOUT" 2>/dev/null; then
            WEB_DIR_OK=1
            break
        fi
        sleep 0.1
    done
    if [ "$WEB_DIR_OK" -ne 1 ]; then
        echo "FAIL: ONLYWALLPAPERS_WEB dir=... index_exists=true line never appeared (wrong web dir or missing index.html)"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB dir=.*index_exists=false' "$TMPOUT" 2>/dev/null; then
        echo "FAIL: ONLYWALLPAPERS_WEB index_exists=false found (index.html missing at resolved web dir)"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi
    echo "[webload] PASS: index_exists=true confirmed"

    WEB_OK=0
    for i in $(seq 1 80); do
        WEB_OK_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT" 2>/dev/null || true)"
        if [ "$WEB_OK_COUNT" -ge "$SCREEN_COUNT" ]; then
            WEB_OK=1
            break
        fi
        sleep 0.1
    done

    if [ "$WEB_OK" -ne 1 ]; then
        echo "FAIL: expected $SCREEN_COUNT ONLYWALLPAPERS_WEB loaded=ok line(s), got fewer within 8s"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    # Verify no loaded=fail lines.
    FAIL_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT" 2>/dev/null || true)"
    if [ "$FAIL_COUNT" -ne 0 ]; then
        echo "FAIL: $FAIL_COUNT ONLYWALLPAPERS_WEB loaded=fail line(s) found"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    # Verify N distinct win= values in loaded=ok lines (poll a bit more to let stragglers arrive).
    # win= is always unique per window; screen= names can collide on identical monitors.
    DISTINCT_OK=0
    for i in $(seq 1 20); do
        DISTINCT_WINS_WEB="$(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT" \
            | grep -o 'win=[0-9]*' \
            | sort -u \
            | wc -l \
            | tr -d ' ')"
        if [ "$DISTINCT_WINS_WEB" -ge "$SCREEN_COUNT" ]; then
            DISTINCT_OK=1
            break
        fi
        sleep 0.1
    done
    if [ "$DISTINCT_OK" -ne 1 ]; then
        echo "FAIL: expected $SCREEN_COUNT distinct win= value(s) in loaded=ok lines, found $DISTINCT_WINS_WEB"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    # (b) Parse frame=WxH from every loaded=ok line; require W > 100 and H > 100.
    FRAME_BAD=0
    while IFS= read -r okline; do
        WIN_ID="$(echo "$okline" | grep -o 'win=[0-9]*' | head -1)"
        FRAME="$(echo "$okline" | grep -o 'frame=[0-9]*x[0-9]*' | head -1)"
        if [ -z "$FRAME" ]; then
            echo "FAIL: loaded=ok line for $WIN_ID is missing frame= field: $okline"
            FRAME_BAD=1
            continue
        fi
        W="$(echo "$FRAME" | sed 's/frame=\([0-9]*\)x.*/\1/')"
        H="$(echo "$FRAME" | sed 's/frame=[0-9]*x\([0-9]*\)/\1/')"
        if [ "$W" -le 100 ] || [ "$H" -le 100 ]; then
            echo "FAIL: loaded=ok frame too small for $WIN_ID (${W}x${H}, need >100x100): $okline"
            FRAME_BAD=1
        fi
    done < <(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT")
    if [ "$FRAME_BAD" -ne 0 ]; then
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    echo "[webload] PASS: $SCREEN_COUNT loaded=ok line(s) with distinct win= values, no loaded=fail, all frames >100x100"
fi

# --- Step 7c: verify SIGINT causes clean exit within ~1s ---
echo "[sigint] Sending SIGINT..."
kill -INT "$PID"
GONE=0
for i in $(seq 1 20); do
    sleep 0.05
    if ! kill -0 "$PID" 2>/dev/null; then
        GONE=1
        break
    fi
done

if [[ $GONE -ne 1 ]]; then
    echo "FAIL: process did not exit within 1s of SIGINT"
    exit 1
fi

# Reap the child and verify clean exit status (0). A raw signal kill yields 130.
STATUS=0; wait "$PID" || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    echo "FAIL: SIGINT did not produce a clean exit (status=$STATUS)"
    exit 1
fi

# Clear PID so the trap does not double-handle.
PID=""

echo "[sigint] PASS: process exited cleanly on SIGINT"

echo ""
echo "=== PASS: all smoke checks passed ==="
