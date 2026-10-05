#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== OnlyWallpapers smoke-run ==="

# --- Step 8: scope guard (run before build to catch forbidden symbols early) ---
echo "[scope] Checking Sources tree for forbidden identifiers..."
HITS="$(grep -rnE 'NSWindow|WKWebView|WKWebViewConfiguration|didChangeScreenParametersNotification|Info\.plist' Sources/ --include='*.swift' || true)"
if [ -n "$HITS" ]; then echo "FAIL: forbidden symbol(s) in Sources/"; echo "$HITS"; exit 1; fi
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
"$BIN" >"$TMPOUT" 2>&1 &
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

# --- Step 7: verify SIGINT causes clean exit within ~1s ---
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
