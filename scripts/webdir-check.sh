#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
cd "$REPO_ROOT"

echo "=== webdir-check ==="

# FIX 1: fresh build so hygiene reflects the CURRENT Package.swift, not a stale bundle.
echo "[build] Building OnlyWallpapers (warnings as errors)..."
swift build --product OnlyWallpapers -Xswiftc -warnings-as-errors

BIN_PATH="$(swift build --product OnlyWallpapers --show-bin-path)"
BIN="$BIN_PATH/OnlyWallpapers"

# Gate: binary must already be built.
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: binary not found at $BIN, run swift build first"
    exit 1
fi

# Normalize a directory path by resolving symlinks (for symlinked .build dirs).
norm() { cd "$1" 2>/dev/null && pwd -P; }

# Shared temp file slots and PIDs (all initialized before trap is set).
TMPOUT_OK=""
TMPOUT_FAIL=""
TMPOUT_REL=""
TMPOUT_BUNDLE=""
TMPOUT_EMPTY=""
PID_OK=""
PID_FAIL=""
PID_REL=""
PID_BUNDLE=""
PID_EMPTY=""

cleanup_all() {
    for _pid in "$PID_BUNDLE" "$PID_OK" "$PID_FAIL" "$PID_REL" "$PID_EMPTY"; do
        [[ -z "$_pid" ]] && continue
        kill -0 "$_pid" 2>/dev/null || continue
        kill -INT "$_pid" 2>/dev/null || true
        sleep 0.2
        kill -0 "$_pid" 2>/dev/null && kill -KILL "$_pid" 2>/dev/null || true
    done
    rm -f "$TMPOUT_OK" "$TMPOUT_FAIL" "$TMPOUT_REL" "$TMPOUT_BUNDLE" "$TMPOUT_EMPTY" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- Check A: BUNDLE HYGIENE ---
echo "[hygiene] Checking bundle contains web assets..."
EXPECTED_BUNDLE_WEB_DIR="$BIN_PATH/OnlyWallpapers_OnlyWallpapers.bundle/web"
for _asset in index.html style.css wallpaper.js; do
    if [[ ! -f "$EXPECTED_BUNDLE_WEB_DIR/$_asset" ]]; then
        echo "FAIL: bundle asset not found: $EXPECTED_BUNDLE_WEB_DIR/$_asset"
        exit 1
    fi
done
echo "[hygiene] PASS: index.html, style.css, and wallpaper.js all present in $EXPECTED_BUNDLE_WEB_DIR"

# --- Check E: BUNDLE-CONSUMED ---
echo "[bundle-consumed] Launching without WALLPAPER_WEB_DIR (bundle path expected)..."
TMPOUT_BUNDLE="$(mktemp)"

env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE "$BIN" >"$TMPOUT_BUNDLE" 2>&1 &
PID_BUNDLE=$!

# Phase 1: poll up to 5s for the resolve line.
BUNDLE_RESOLVED=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_BUNDLE" 2>/dev/null; then
        echo "FAIL: bundle-consumed: process exited early before resolve line"
        cat "$TMPOUT_BUNDLE" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_BUNDLE" 2>/dev/null; then
        BUNDLE_RESOLVED=1
        break
    fi
    sleep 0.1
done

if [[ $BUNDLE_RESOLVED -ne 1 ]]; then
    echo "FAIL: bundle-consumed: ONLYWALLPAPERS_WEB_RESOLVE line never appeared"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi

# Phase 2: WINDOWS count= line is REQUIRED and count MUST be > 0.
BUNDLE_WIN_LINE_FOUND=0
SCREEN_COUNT_BUNDLE=0
for i in $(seq 1 50); do
    WIN_LINE_B="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_BUNDLE" 2>/dev/null | head -1 || true)"
    if [[ -n "$WIN_LINE_B" ]]; then
        BUNDLE_WIN_LINE_FOUND=1
        SCREEN_COUNT_BUNDLE="$(echo "$WIN_LINE_B" | sed 's/.*count=\([0-9]*\).*/\1/')"
        break
    fi
    if ! kill -0 "$PID_BUNDLE" 2>/dev/null; then
        echo "FAIL: bundle-consumed: process exited before ONLYWALLPAPERS_WINDOWS line appeared"
        cat "$TMPOUT_BUNDLE" || true
        exit 1
    fi
    sleep 0.1
done

if [[ $BUNDLE_WIN_LINE_FOUND -ne 1 ]]; then
    echo "FAIL: bundle-consumed: ONLYWALLPAPERS_WINDOWS count= line never appeared within 5s"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi

if [[ "$SCREEN_COUNT_BUNDLE" -eq 0 ]]; then
    echo "FAIL: bundle-consumed: gate requires at least one display (count=0)"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi

# Phase 3: wait up to 10s for N loaded=ok lines (N = SCREEN_COUNT_BUNDLE).
for i in $(seq 1 100); do
    if ! kill -0 "$PID_BUNDLE" 2>/dev/null; then
        echo "FAIL: bundle-consumed: process exited before all $SCREEN_COUNT_BUNDLE loaded=ok lines appeared"
        cat "$TMPOUT_BUNDLE" || true
        exit 1
    fi
    _cnt="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_BUNDLE" 2>/dev/null || true)"
    if [[ "$_cnt" -ge "$SCREEN_COUNT_BUNDLE" ]]; then
        break
    fi
    sleep 0.1
done

kill -INT "$PID_BUNDLE" 2>/dev/null || true
wait "$PID_BUNDLE" 2>/dev/null || true
PID_BUNDLE=""

# Assert: resolve line has exact tokens status=ok source=bundle (field-end anchored).
BUNDLE_RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_BUNDLE" | head -1)"
if ! echo "$BUNDLE_RESOLVE_LINE" | grep -Eq 'status=ok source=bundle( |$)'; then
    echo "FAIL: bundle-consumed: expected exact status=ok source=bundle, got: $BUNDLE_RESOLVE_LINE"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
BUNDLE_LOGGED_DIR="$(echo "$BUNDLE_RESOLVE_LINE" | grep -oE 'dir=[^ ]+' | head -1 | sed 's/^dir=//')"
NORM_EXPECTED="$(norm "$EXPECTED_BUNDLE_WEB_DIR" || true)"
NORM_LOGGED="$(norm "$BUNDLE_LOGGED_DIR" || true)"
if [[ "$NORM_EXPECTED" != "$NORM_LOGGED" ]]; then
    echo "FAIL: bundle-consumed: resolve dir='$BUNDLE_LOGGED_DIR' (norm='$NORM_LOGGED') != expected '$EXPECTED_BUNDLE_WEB_DIR' (norm='$NORM_EXPECTED')"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS: $BUNDLE_RESOLVE_LINE"

# Assert (a): EVERY ONLYWALLPAPERS_WEB dir= line must have dir==expected (normalized) and index_exists=true.
BUNDLE_DIR_LINE_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB dir=' "$TMPOUT_BUNDLE" 2>/dev/null || true)"
if [[ "$BUNDLE_DIR_LINE_COUNT" -eq 0 ]]; then
    echo "FAIL: bundle-consumed: no ONLYWALLPAPERS_WEB dir= lines appeared"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
BUNDLE_DIR_BAD=0
while IFS= read -r _wline; do
    _wdir_val="$(echo "$_wline" | grep -oE 'dir=[^ ]+' | head -1 | sed 's/^dir=//')"
    _norm_wlogged="$(norm "$_wdir_val" || true)"
    if [[ "$NORM_EXPECTED" != "$_norm_wlogged" ]]; then
        echo "FAIL: bundle-consumed: WebWallpaperView dir='$_wdir_val' != expected '$EXPECTED_BUNDLE_WEB_DIR' (resolver URL not consumed)"
        BUNDLE_DIR_BAD=1
    fi
    if ! echo "$_wline" | grep -q 'index_exists=true'; then
        echo "FAIL: bundle-consumed: WebWallpaperView line missing index_exists=true: $_wline"
        BUNDLE_DIR_BAD=1
    fi
done < <(grep 'ONLYWALLPAPERS_WEB dir=' "$TMPOUT_BUNDLE" || true)
if [[ "$BUNDLE_DIR_BAD" -ne 0 ]]; then
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS (a): all $BUNDLE_DIR_LINE_COUNT dir= line(s) match expected dir with index_exists=true"

# Assert (b): exactly N loaded=ok lines with distinct win= values; zero loaded=fail.
BUNDLE_OK_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_BUNDLE" 2>/dev/null || true)"
if [[ "$BUNDLE_OK_COUNT" -ne "$SCREEN_COUNT_BUNDLE" ]]; then
    echo "FAIL: bundle-consumed: expected $SCREEN_COUNT_BUNDLE loaded=ok lines, found $BUNDLE_OK_COUNT"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
BUNDLE_DISTINCT_WINS="$(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_BUNDLE" \
    | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
if [[ "$BUNDLE_DISTINCT_WINS" -ne "$SCREEN_COUNT_BUNDLE" ]]; then
    echo "FAIL: bundle-consumed: expected $SCREEN_COUNT_BUNDLE distinct win= values in loaded=ok lines, found $BUNDLE_DISTINCT_WINS"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
BUNDLE_FAIL_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT_BUNDLE" 2>/dev/null || true)"
if [[ "$BUNDLE_FAIL_COUNT" -ne 0 ]]; then
    echo "FAIL: bundle-consumed: $BUNDLE_FAIL_COUNT loaded=fail line(s) found"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS (b): $SCREEN_COUNT_BUNDLE loaded=ok lines with distinct win= values, no loaded=fail"

# Assert (c): win= set from loaded=ok lines must equal win= set from SLICE lines.
BUNDLE_LOADED_WINS="$(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_BUNDLE" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
BUNDLE_SLICE_WINS="$(grep 'ONLYWALLPAPERS_SLICE.*win=' "$TMPOUT_BUNDLE" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [[ "$BUNDLE_LOADED_WINS" != "$BUNDLE_SLICE_WINS" ]]; then
    echo "FAIL: bundle-consumed: win= sets differ. loaded=ok wins: {$BUNDLE_LOADED_WINS} slice wins: {$BUNDLE_SLICE_WINS}"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS (c): loaded=ok win= set equals SLICE win= set: {$BUNDLE_LOADED_WINS}"

# --- Check B: OVERRIDE-OK ---
echo "[override-ok] Launching with WALLPAPER_WEB_DIR set to sources/web dir..."
OVERRIDE_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web"
TMPOUT_OK="$(mktemp)"

env -u OW_SPIKE -u OW_WEBSPIKE WALLPAPER_WEB_DIR="$OVERRIDE_DIR" "$BIN" >"$TMPOUT_OK" 2>&1 &
PID_OK=$!

# Phase 1: poll up to 5s for the resolve line.
RESOLVED=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_OK" 2>/dev/null; then
        echo "FAIL: override-ok process exited early"
        cat "$TMPOUT_OK" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_OK" 2>/dev/null; then
        RESOLVED=1
        break
    fi
    sleep 0.1
done

if [[ $RESOLVED -ne 1 ]]; then
    echo "FAIL: override-ok: ONLYWALLPAPERS_WEB_RESOLVE line never appeared"
    cat "$TMPOUT_OK" || true
    exit 1
fi

# Phase 2: WINDOWS count= line is REQUIRED and count MUST be > 0.
WIN_LINE_FOUND=0
SCREEN_COUNT_OK=0
for i in $(seq 1 50); do
    WIN_LINE="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_OK" 2>/dev/null | head -1 || true)"
    if [[ -n "$WIN_LINE" ]]; then
        WIN_LINE_FOUND=1
        SCREEN_COUNT_OK="$(echo "$WIN_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')"
        break
    fi
    if ! kill -0 "$PID_OK" 2>/dev/null; then
        echo "FAIL: override-ok: resolved env then exited before creating windows"
        cat "$TMPOUT_OK" || true
        exit 1
    fi
    sleep 0.1
done

if [[ $WIN_LINE_FOUND -ne 1 ]]; then
    echo "FAIL: override-ok: ONLYWALLPAPERS_WINDOWS count= line never appeared within 5s"
    cat "$TMPOUT_OK" || true
    exit 1
fi

if [[ "$SCREEN_COUNT_OK" -eq 0 ]]; then
    echo "FAIL: override-ok: gate requires at least one display (count=0)"
    cat "$TMPOUT_OK" || true
    exit 1
fi

# Phase 3: wait up to 10s for N loaded=ok lines (N = SCREEN_COUNT_OK).
for i in $(seq 1 100); do
    if ! kill -0 "$PID_OK" 2>/dev/null; then
        echo "FAIL: override-ok: process exited before all $SCREEN_COUNT_OK loaded=ok lines appeared"
        cat "$TMPOUT_OK" || true
        exit 1
    fi
    _cnt="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_OK" 2>/dev/null || true)"
    if [[ "$_cnt" -ge "$SCREEN_COUNT_OK" ]]; then
        break
    fi
    sleep 0.1
done

kill -INT "$PID_OK" 2>/dev/null || true
wait "$PID_OK" 2>/dev/null || true
PID_OK=""

# Assert: resolve line has exact tokens status=ok source=env (field-end anchored).
RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_OK" | head -1)"
if ! echo "$RESOLVE_LINE" | grep -Eq 'status=ok source=env( |$)'; then
    echo "FAIL: override-ok: expected exact status=ok source=env, got: $RESOLVE_LINE"
    cat "$TMPOUT_OK" || true
    exit 1
fi
RESOLVE_DIR="$(echo "$RESOLVE_LINE" | grep -oE 'dir=[^ ]+' | head -1 | sed 's/^dir=//')"
if [[ "$RESOLVE_DIR" != "$OVERRIDE_DIR" ]]; then
    echo "FAIL: override-ok: resolve dir='$RESOLVE_DIR' != expected '$OVERRIDE_DIR'"
    cat "$TMPOUT_OK" || true
    exit 1
fi
echo "[override-ok] PASS: $RESOLVE_LINE"

# Assert (a): EVERY ONLYWALLPAPERS_WEB dir= line must have dir==OVERRIDE_DIR (exact) and index_exists=true.
OK_DIR_LINE_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB dir=' "$TMPOUT_OK" 2>/dev/null || true)"
if [[ "$OK_DIR_LINE_COUNT" -eq 0 ]]; then
    echo "FAIL: override-ok: no ONLYWALLPAPERS_WEB dir= lines appeared"
    cat "$TMPOUT_OK" || true
    exit 1
fi
OK_DIR_BAD=0
while IFS= read -r _wline; do
    _wdir_val="$(echo "$_wline" | grep -oE 'dir=[^ ]+' | head -1 | sed 's/^dir=//')"
    if [[ "$_wdir_val" != "$OVERRIDE_DIR" ]]; then
        echo "FAIL: override-ok: WebWallpaperView dir='$_wdir_val' != expected '$OVERRIDE_DIR' (resolver URL not consumed)"
        OK_DIR_BAD=1
    fi
    if ! echo "$_wline" | grep -q 'index_exists=true'; then
        echo "FAIL: override-ok: WebWallpaperView line missing index_exists=true: $_wline"
        OK_DIR_BAD=1
    fi
done < <(grep 'ONLYWALLPAPERS_WEB dir=' "$TMPOUT_OK" || true)
if [[ "$OK_DIR_BAD" -ne 0 ]]; then
    cat "$TMPOUT_OK" || true
    exit 1
fi
echo "[override-ok] PASS (a): all $OK_DIR_LINE_COUNT dir= line(s) match expected dir with index_exists=true"

# Assert (b): exactly N loaded=ok lines with distinct win= values; zero loaded=fail.
OK_LOADED_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_OK" 2>/dev/null || true)"
if [[ "$OK_LOADED_COUNT" -ne "$SCREEN_COUNT_OK" ]]; then
    echo "FAIL: override-ok: expected $SCREEN_COUNT_OK loaded=ok lines, found $OK_LOADED_COUNT"
    cat "$TMPOUT_OK" || true
    exit 1
fi
OK_DISTINCT_WINS="$(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_OK" \
    | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
if [[ "$OK_DISTINCT_WINS" -ne "$SCREEN_COUNT_OK" ]]; then
    echo "FAIL: override-ok: expected $SCREEN_COUNT_OK distinct win= values in loaded=ok lines, found $OK_DISTINCT_WINS"
    cat "$TMPOUT_OK" || true
    exit 1
fi
OK_FAIL_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT_OK" 2>/dev/null || true)"
if [[ "$OK_FAIL_COUNT" -ne 0 ]]; then
    echo "FAIL: override-ok: $OK_FAIL_COUNT loaded=fail line(s) found"
    cat "$TMPOUT_OK" || true
    exit 1
fi
echo "[override-ok] PASS (b): $SCREEN_COUNT_OK loaded=ok lines with distinct win= values, no loaded=fail"

# Assert (c): win= set from loaded=ok lines must equal win= set from SLICE lines.
OK_LOADED_WINS="$(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT_OK" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
OK_SLICE_WINS="$(grep 'ONLYWALLPAPERS_SLICE.*win=' "$TMPOUT_OK" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [[ "$OK_LOADED_WINS" != "$OK_SLICE_WINS" ]]; then
    echo "FAIL: override-ok: win= sets differ. loaded=ok wins: {$OK_LOADED_WINS} slice wins: {$OK_SLICE_WINS}"
    cat "$TMPOUT_OK" || true
    exit 1
fi
echo "[override-ok] PASS (c): loaded=ok win= set equals SLICE win= set: {$OK_LOADED_WINS}"

# --- Check F: EMPTY-OVERRIDE (WALLPAPER_WEB_DIR="" treated as unset, falls to bundle) ---
echo "[empty-override] Launching with WALLPAPER_WEB_DIR='' (empty string, expected to fall back to bundle)..."
TMPOUT_EMPTY="$(mktemp)"

env -u OW_SPIKE -u OW_WEBSPIKE WALLPAPER_WEB_DIR="" "$BIN" >"$TMPOUT_EMPTY" 2>&1 &
PID_EMPTY=$!

# Phase 1: poll up to 5s for the resolve line.
EMPTY_RESOLVED=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_EMPTY" 2>/dev/null; then
        echo "FAIL: empty-override: process exited early before resolve line"
        cat "$TMPOUT_EMPTY" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_EMPTY" 2>/dev/null; then
        EMPTY_RESOLVED=1
        break
    fi
    sleep 0.1
done

if [[ $EMPTY_RESOLVED -ne 1 ]]; then
    echo "FAIL: empty-override: ONLYWALLPAPERS_WEB_RESOLVE line never appeared"
    cat "$TMPOUT_EMPTY" || true
    exit 1
fi

# Assert: resolve line has exact tokens status=ok source=bundle.
EMPTY_RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_EMPTY" | head -1)"
if ! echo "$EMPTY_RESOLVE_LINE" | grep -Eq 'status=ok source=bundle( |$)'; then
    echo "FAIL: empty-override: expected exact status=ok source=bundle, got: $EMPTY_RESOLVE_LINE"
    cat "$TMPOUT_EMPTY" || true
    exit 1
fi

# Phase 2: WINDOWS count= line must appear and count must be > 0.
EMPTY_WIN_LINE_FOUND=0
SCREEN_COUNT_EMPTY=0
for i in $(seq 1 50); do
    WIN_LINE_E="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_EMPTY" 2>/dev/null | head -1 || true)"
    if [[ -n "$WIN_LINE_E" ]]; then
        EMPTY_WIN_LINE_FOUND=1
        SCREEN_COUNT_EMPTY="$(echo "$WIN_LINE_E" | sed 's/.*count=\([0-9]*\).*/\1/')"
        break
    fi
    if ! kill -0 "$PID_EMPTY" 2>/dev/null; then
        echo "FAIL: empty-override: process exited before ONLYWALLPAPERS_WINDOWS line appeared"
        cat "$TMPOUT_EMPTY" || true
        exit 1
    fi
    sleep 0.1
done

if [[ $EMPTY_WIN_LINE_FOUND -ne 1 ]]; then
    echo "FAIL: empty-override: ONLYWALLPAPERS_WINDOWS count= line never appeared within 5s"
    cat "$TMPOUT_EMPTY" || true
    exit 1
fi

if [[ "$SCREEN_COUNT_EMPTY" -eq 0 ]]; then
    echo "FAIL: empty-override: gate requires at least one display (count=0)"
    cat "$TMPOUT_EMPTY" || true
    exit 1
fi

kill -INT "$PID_EMPTY" 2>/dev/null || true
wait "$PID_EMPTY" 2>/dev/null || true
PID_EMPTY=""

echo "[empty-override] PASS: $EMPTY_RESOLVE_LINE"
echo "[empty-override] PASS: windows created (count=$SCREEN_COUNT_EMPTY)"

# --- Check C: OVERRIDE-FAIL ---
echo "[override-fail] Launching with WALLPAPER_WEB_DIR=/nonexistent-ow-xyz (expected to terminate)..."
TMPOUT_FAIL="$(mktemp)"

env -u OW_SPIKE -u OW_WEBSPIKE WALLPAPER_WEB_DIR="/nonexistent-ow-xyz" "$BIN" >"$TMPOUT_FAIL" 2>&1 &
PID_FAIL=$!

# Wait up to 5s for the process to exit on its own (it should exit(1) immediately).
EXITED=0
for i in $(seq 1 50); do
    sleep 0.1
    if ! kill -0 "$PID_FAIL" 2>/dev/null; then
        EXITED=1
        break
    fi
done

FAIL_STATUS=0
wait "$PID_FAIL" 2>/dev/null || FAIL_STATUS=$?
PID_FAIL=""

if [[ $EXITED -ne 1 ]]; then
    echo "FAIL: override-fail: process did not exit within 5s"
    cat "$TMPOUT_FAIL" || true
    exit 1
fi

if [[ $FAIL_STATUS -eq 0 ]]; then
    echo "FAIL: override-fail: process exited 0 (expected non-zero)"
    cat "$TMPOUT_FAIL" || true
    exit 1
fi

# Field-end anchored: reason=no-index-extra must NOT pass.
if ! grep -Eq 'ONLYWALLPAPERS_WEB_RESOLVE status=fail source=env reason=no-index( |$)' "$TMPOUT_FAIL"; then
    echo "FAIL: override-fail: expected exact token reason=no-index in ONLYWALLPAPERS_WEB_RESOLVE line"
    cat "$TMPOUT_FAIL" || true
    exit 1
fi

# Assert fail-fast: no windows or WKWebView created before exit(1).
if grep -q 'ONLYWALLPAPERS_WINDOWS' "$TMPOUT_FAIL"; then
    echo "FAIL: override-fail: ONLYWALLPAPERS_WINDOWS appeared (window was created before exit, violates fail-fast contract)"
    cat "$TMPOUT_FAIL" || true
    exit 1
fi
if grep -q 'ONLYWALLPAPERS_WEB ' "$TMPOUT_FAIL"; then
    echo "FAIL: override-fail: ONLYWALLPAPERS_WEB (WebWallpaperView) appeared before exit, violates fail-fast contract"
    cat "$TMPOUT_FAIL" || true
    exit 1
fi

echo "[override-fail] PASS: exited $FAIL_STATUS with expected fail line, no windows created"
FAIL_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE status=fail' "$TMPOUT_FAIL" | head -1)"
echo "[override-fail] Got: $FAIL_LINE"

# --- Check D: OVERRIDE-RELATIVE ---
echo "[override-relative] Launching with WALLPAPER_WEB_DIR=relative/path (expected to terminate)..."
TMPOUT_REL="$(mktemp)"

env -u OW_SPIKE -u OW_WEBSPIKE WALLPAPER_WEB_DIR="relative/path" "$BIN" >"$TMPOUT_REL" 2>&1 &
PID_REL=$!

# Wait up to 5s for the process to exit on its own (it should exit(1) immediately).
REL_EXITED=0
for i in $(seq 1 50); do
    sleep 0.1
    if ! kill -0 "$PID_REL" 2>/dev/null; then
        REL_EXITED=1
        break
    fi
done

REL_STATUS=0
wait "$PID_REL" 2>/dev/null || REL_STATUS=$?
PID_REL=""

if [[ $REL_EXITED -ne 1 ]]; then
    echo "FAIL: override-relative: process did not exit within 5s"
    cat "$TMPOUT_REL" || true
    exit 1
fi

if [[ $REL_STATUS -eq 0 ]]; then
    echo "FAIL: override-relative: process exited 0 (expected non-zero)"
    cat "$TMPOUT_REL" || true
    exit 1
fi

# Field-end anchored: reason=not-absolute-xyz must NOT pass.
if ! grep -Eq 'ONLYWALLPAPERS_WEB_RESOLVE status=fail source=env reason=not-absolute( |$)' "$TMPOUT_REL"; then
    echo "FAIL: override-relative: expected exact token reason=not-absolute in ONLYWALLPAPERS_WEB_RESOLVE line"
    cat "$TMPOUT_REL" || true
    exit 1
fi

# Assert fail-fast: no windows or WKWebView created before exit(1).
if grep -q 'ONLYWALLPAPERS_WINDOWS' "$TMPOUT_REL"; then
    echo "FAIL: override-relative: ONLYWALLPAPERS_WINDOWS appeared (window was created before exit, violates fail-fast contract)"
    cat "$TMPOUT_REL" || true
    exit 1
fi
if grep -q 'ONLYWALLPAPERS_WEB ' "$TMPOUT_REL"; then
    echo "FAIL: override-relative: ONLYWALLPAPERS_WEB (WebWallpaperView) appeared before exit, violates fail-fast contract"
    cat "$TMPOUT_REL" || true
    exit 1
fi

echo "[override-relative] PASS: exited $REL_STATUS with expected fail line, no windows created"
REL_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE status=fail' "$TMPOUT_REL" | head -1)"
echo "[override-relative] Got: $REL_LINE"

echo ""
echo "=== PASS: all webdir checks passed ==="
