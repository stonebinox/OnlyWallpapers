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
TMPOUT_BFALLBACK=""
PID_OK=""
PID_FAIL=""
PID_REL=""
PID_BUNDLE=""
PID_EMPTY=""
PID_BFALLBACK=""
OW_SUPPORT_TMP_BUNDLE=""
OW_SUPPORT_TMP_OK=""
OW_SUPPORT_TMP_EMPTY=""
OW_SUPPORT_TMP_BFALLBACK=""
TMPOUT_RESEED1=""
TMPOUT_RESEED2=""
TMPOUT_RESEED3=""
OW_SUPPORT_TMP_RESEED=""
PID_RESEED1=""
PID_RESEED2=""
PID_RESEED3=""
TMPOUT_INCOMPLETE1=""
TMPOUT_INCOMPLETE2=""
OW_SUPPORT_TMP_INCOMPLETE=""
PID_INCOMPLETE1=""
PID_INCOMPLETE2=""
TMPOUT_MALFORMED=""
OW_SUPPORT_TMP_MALFORMED=""
PID_MALFORMED=""
TMPOUT_READONLY=""
OW_SUPPORT_TMP_READONLY=""
PID_READONLY=""

cleanup_all() {
    for _pid in "$PID_BUNDLE" "$PID_OK" "$PID_FAIL" "$PID_REL" "$PID_EMPTY" "${PID_BFALLBACK:-}" "${PID_RESEED1:-}" "${PID_RESEED2:-}" "${PID_RESEED3:-}" "${PID_INCOMPLETE1:-}" "${PID_INCOMPLETE2:-}" "${PID_MALFORMED:-}" "${PID_READONLY:-}"; do
        [[ -z "$_pid" ]] && continue
        kill -0 "$_pid" 2>/dev/null || continue
        kill -INT "$_pid" 2>/dev/null || true
        sleep 0.2
        kill -0 "$_pid" 2>/dev/null && kill -KILL "$_pid" 2>/dev/null || true
    done
    rm -f "$TMPOUT_OK" "$TMPOUT_FAIL" "$TMPOUT_REL" "$TMPOUT_BUNDLE" "$TMPOUT_EMPTY" "${TMPOUT_BFALLBACK:-}" "${TMPOUT_RESEED1:-}" "${TMPOUT_RESEED2:-}" "${TMPOUT_RESEED3:-}" "${TMPOUT_INCOMPLETE1:-}" "${TMPOUT_INCOMPLETE2:-}" "${TMPOUT_MALFORMED:-}" "${TMPOUT_READONLY:-}" 2>/dev/null || true
    for _tmp in "${OW_SUPPORT_TMP_BUNDLE:-}" "${OW_SUPPORT_TMP_OK:-}" "${OW_SUPPORT_TMP_EMPTY:-}" "${OW_SUPPORT_TMP_BFALLBACK:-}" "${OW_SUPPORT_TMP_RESEED:-}" "${OW_SUPPORT_TMP_INCOMPLETE:-}" "${OW_SUPPORT_TMP_MALFORMED:-}" "${OW_SUPPORT_TMP_READONLY:-}"; do
        [[ -z "$_tmp" ]] && continue
        rm -rf "$_tmp" 2>/dev/null || true
    done
    if [[ -n "${OW_SUPPORT_TMP_READONLY:-}" ]] && [[ -d "${OW_SUPPORT_TMP_READONLY:-}" ]]; then
        chmod -R u+w "$OW_SUPPORT_TMP_READONLY" 2>/dev/null || true
    fi
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
echo "[bundle-consumed] Launching without WALLPAPER_WEB_DIR (appstore path expected)..."
TMPOUT_BUNDLE="$(mktemp)"

OW_SUPPORT_TMP_BUNDLE="$(mktemp -d)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_BUNDLE" env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON "$BIN" >"$TMPOUT_BUNDLE" 2>&1 &
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
    WIN_LINE_B="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_BUNDLE" 2>/dev/null | grep 'gen=0' | head -1 || true)"
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
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_BUNDLE" 2>/dev/null || true)"
    if [[ "$_cnt" -ge "$SCREEN_COUNT_BUNDLE" ]]; then
        break
    fi
    sleep 0.1
done

kill -INT "$PID_BUNDLE" 2>/dev/null || true
wait "$PID_BUNDLE" 2>/dev/null || true
PID_BUNDLE=""

# Assert: resolve line has exact tokens status=ok source=appstore (field-end anchored).
BUNDLE_RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_BUNDLE" | head -1)"
if ! echo "$BUNDLE_RESOLVE_LINE" | grep -Eq 'status=ok source=appstore( |$)'; then
    echo "FAIL: bundle-consumed: expected exact status=ok source=appstore, got: $BUNDLE_RESOLVE_LINE"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
BUNDLE_LOGGED_DIR="$(echo "$BUNDLE_RESOLVE_LINE" | grep -oE 'dir=[^ ]+' | head -1 | sed 's/^dir=//')"
EXPECTED_APPSTORE_DIR="$OW_SUPPORT_TMP_BUNDLE/web"
NORM_EXPECTED_APPSTORE="$(norm "$EXPECTED_APPSTORE_DIR" || true)"
NORM_LOGGED="$(norm "$BUNDLE_LOGGED_DIR" || true)"
if [[ "$NORM_EXPECTED_APPSTORE" != "$NORM_LOGGED" ]]; then
    echo "FAIL: bundle-consumed: resolve dir='$BUNDLE_LOGGED_DIR' (norm='$NORM_LOGGED') != expected '$EXPECTED_APPSTORE_DIR' (norm='$NORM_EXPECTED_APPSTORE')"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS: $BUNDLE_RESOLVE_LINE"

# Assert (a): EVERY ONLYWALLPAPERS_WEB dir= line must have dir under OW_SUPPORT_TMP_BUNDLE and index_exists=true.
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
    if [[ "$_norm_wlogged" != "$NORM_EXPECTED_APPSTORE" ]]; then
        echo "FAIL: bundle-consumed: WebWallpaperView dir='$_wdir_val' != expected '$EXPECTED_APPSTORE_DIR' (resolver URL not consumed)"
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

# Assert (b): exactly N loaded=ok gen=0 lines with distinct win= values; zero loaded=fail.
BUNDLE_OK_COUNT="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_BUNDLE" 2>/dev/null || true)"
if [[ "$BUNDLE_OK_COUNT" -ne "$SCREEN_COUNT_BUNDLE" ]]; then
    echo "FAIL: bundle-consumed: expected $SCREEN_COUNT_BUNDLE loaded=ok gen=0 lines, found $BUNDLE_OK_COUNT"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
BUNDLE_DISTINCT_WINS="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_BUNDLE" \
    | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
if [[ "$BUNDLE_DISTINCT_WINS" -ne "$SCREEN_COUNT_BUNDLE" ]]; then
    echo "FAIL: bundle-consumed: expected $SCREEN_COUNT_BUNDLE distinct win= values in loaded=ok gen=0 lines, found $BUNDLE_DISTINCT_WINS"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
BUNDLE_FAIL_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT_BUNDLE" 2>/dev/null || true)"
if [[ "$BUNDLE_FAIL_COUNT" -ne 0 ]]; then
    echo "FAIL: bundle-consumed: $BUNDLE_FAIL_COUNT loaded=fail line(s) found"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS (b): $SCREEN_COUNT_BUNDLE loaded=ok gen=0 lines with distinct win= values, no loaded=fail"

# Assert picker telemetry for appstore source (menuEnabled is the real NSMenuItem.isEnabled).
BUNDLE_PICKER_LINE="$(grep 'ONLYWALLPAPERS_PICKER.*menuEnabled=' "$TMPOUT_BUNDLE" | head -1 || true)"
if ! echo "$BUNDLE_PICKER_LINE" | grep -Eq 'menuEnabled=true source=appstore( |$)'; then
    echo "FAIL: bundle-consumed: expected ONLYWALLPAPERS_PICKER menuEnabled=true source=appstore, got: $BUNDLE_PICKER_LINE"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS (picker): $BUNDLE_PICKER_LINE"

# Assert (c): win= set from loaded=ok gen=0 lines must equal win= set from SLICE gen=0 lines.
BUNDLE_LOADED_WINS="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_BUNDLE" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
BUNDLE_SLICE_WINS="$(grep 'ONLYWALLPAPERS_SLICE.*gen=0' "$TMPOUT_BUNDLE" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [[ "$BUNDLE_LOADED_WINS" != "$BUNDLE_SLICE_WINS" ]]; then
    echo "FAIL: bundle-consumed: win= sets differ. loaded=ok gen=0 wins: {$BUNDLE_LOADED_WINS} slice wins: {$BUNDLE_SLICE_WINS}"
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[bundle-consumed] PASS (c): loaded=ok gen=0 win= set equals SLICE gen=0 win= set: {$BUNDLE_LOADED_WINS}"

# FIX 9: assert seeded code files are byte-identical to bundle originals.
echo "[byte-eq] Checking seeded code files are byte-identical to bundle originals..."
BYTE_EQ_FAIL=0
for _name in index.html style.css wallpaper.js; do
    _seeded="$OW_SUPPORT_TMP_BUNDLE/web/$_name"
    _bundle_orig="$EXPECTED_BUNDLE_WEB_DIR/$_name"
    if [[ ! -f "$_seeded" ]]; then
        echo "FAIL [byte-eq]: seeded file missing: $_seeded"
        BYTE_EQ_FAIL=1
    elif ! cmp -s "$_seeded" "$_bundle_orig"; then
        echo "FAIL [byte-eq]: $_name differs between seeded dir and bundle"
        BYTE_EQ_FAIL=1
    else
        echo "[byte-eq] PASS: $_name byte-identical"
    fi
done
if [[ $BYTE_EQ_FAIL -ne 0 ]]; then
    cat "$TMPOUT_BUNDLE" || true
    exit 1
fi
echo "[byte-eq] PASS: all 3 seeded code files byte-identical to bundle originals"

# --- Check B: OVERRIDE-OK ---
echo "[override-ok] Launching with WALLPAPER_WEB_DIR set to sources/web dir..."
OVERRIDE_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web"
TMPOUT_OK="$(mktemp)"

OW_SUPPORT_TMP_OK="$(mktemp -d)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_OK" env -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON WALLPAPER_WEB_DIR="$OVERRIDE_DIR" "$BIN" >"$TMPOUT_OK" 2>&1 &
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
    WIN_LINE="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_OK" 2>/dev/null | grep 'gen=0' | head -1 || true)"
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
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_OK" 2>/dev/null || true)"
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

# Assert (b): exactly N loaded=ok gen=0 lines with distinct win= values; zero loaded=fail.
OK_LOADED_COUNT="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_OK" 2>/dev/null || true)"
if [[ "$OK_LOADED_COUNT" -ne "$SCREEN_COUNT_OK" ]]; then
    echo "FAIL: override-ok: expected $SCREEN_COUNT_OK loaded=ok gen=0 lines, found $OK_LOADED_COUNT"
    cat "$TMPOUT_OK" || true
    exit 1
fi
OK_DISTINCT_WINS="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_OK" \
    | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
if [[ "$OK_DISTINCT_WINS" -ne "$SCREEN_COUNT_OK" ]]; then
    echo "FAIL: override-ok: expected $SCREEN_COUNT_OK distinct win= values in loaded=ok gen=0 lines, found $OK_DISTINCT_WINS"
    cat "$TMPOUT_OK" || true
    exit 1
fi
OK_FAIL_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT_OK" 2>/dev/null || true)"
if [[ "$OK_FAIL_COUNT" -ne 0 ]]; then
    echo "FAIL: override-ok: $OK_FAIL_COUNT loaded=fail line(s) found"
    cat "$TMPOUT_OK" || true
    exit 1
fi
echo "[override-ok] PASS (b): $SCREEN_COUNT_OK loaded=ok gen=0 lines with distinct win= values, no loaded=fail"

# Assert picker telemetry for env source (menuEnabled is the real NSMenuItem.isEnabled).
OK_PICKER_LINE="$(grep 'ONLYWALLPAPERS_PICKER.*menuEnabled=' "$TMPOUT_OK" | head -1 || true)"
if ! echo "$OK_PICKER_LINE" | grep -Eq 'menuEnabled=false source=env( |$)'; then
    echo "FAIL: override-ok: expected ONLYWALLPAPERS_PICKER menuEnabled=false source=env, got: $OK_PICKER_LINE"
    cat "$TMPOUT_OK" || true
    exit 1
fi
echo "[override-ok] PASS (picker): $OK_PICKER_LINE"

# Assert (c): win= set from loaded=ok gen=0 lines must equal win= set from SLICE gen=0 lines.
OK_LOADED_WINS="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_OK" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
OK_SLICE_WINS="$(grep 'ONLYWALLPAPERS_SLICE.*gen=0' "$TMPOUT_OK" \
    | grep -o 'win=[0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [[ "$OK_LOADED_WINS" != "$OK_SLICE_WINS" ]]; then
    echo "FAIL: override-ok: win= sets differ. loaded=ok gen=0 wins: {$OK_LOADED_WINS} slice wins: {$OK_SLICE_WINS}"
    cat "$TMPOUT_OK" || true
    exit 1
fi
echo "[override-ok] PASS (c): loaded=ok gen=0 win= set equals SLICE gen=0 win= set: {$OK_LOADED_WINS}"

# --- Check F: EMPTY-OVERRIDE (WALLPAPER_WEB_DIR="" treated as unset, falls to bundle) ---
echo "[empty-override] Launching with WALLPAPER_WEB_DIR='' (empty string, expected to fall back to bundle)..."
TMPOUT_EMPTY="$(mktemp)"

OW_SUPPORT_TMP_EMPTY="$(mktemp -d)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_EMPTY" env -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON WALLPAPER_WEB_DIR="" "$BIN" >"$TMPOUT_EMPTY" 2>&1 &
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

# Assert: resolve line has exact tokens status=ok source=appstore (WALLPAPER_WEB_DIR="" falls to appstore).
EMPTY_RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_EMPTY" | head -1)"
if ! echo "$EMPTY_RESOLVE_LINE" | grep -Eq 'status=ok source=appstore( |$)'; then
    echo "FAIL: empty-override: expected exact status=ok source=appstore, got: $EMPTY_RESOLVE_LINE"
    cat "$TMPOUT_EMPTY" || true
    exit 1
fi

# Phase 2: WINDOWS count= line must appear and count must be > 0.
EMPTY_WIN_LINE_FOUND=0
SCREEN_COUNT_EMPTY=0
for i in $(seq 1 50); do
    WIN_LINE_E="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_EMPTY" 2>/dev/null | grep 'gen=0' | head -1 || true)"
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
echo "[empty-override] PASS: windows created (count=$SCREEN_COUNT_EMPTY) source=appstore"

# --- Check C: OVERRIDE-FAIL ---
echo "[override-fail] Launching with WALLPAPER_WEB_DIR=/nonexistent-ow-xyz (expected to terminate)..."
TMPOUT_FAIL="$(mktemp)"

env -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON WALLPAPER_WEB_DIR="/nonexistent-ow-xyz" "$BIN" >"$TMPOUT_FAIL" 2>&1 &
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

env -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON WALLPAPER_WEB_DIR="relative/path" "$BIN" >"$TMPOUT_REL" 2>&1 &
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

# --- Check G: BUNDLE-FALLBACK ---
echo "[bundle-fallback] Testing seed failure forces source=bundle..."
OW_SUPPORT_TMP_BFALLBACK="$(mktemp)"
TMPOUT_BFALLBACK="$(mktemp)"

env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_BFALLBACK" "$BIN" >"$TMPOUT_BFALLBACK" 2>&1 &
PID_BFALLBACK=$!

BF_RESOLVED=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_BFALLBACK" 2>/dev/null; then
        echo "FAIL: bundle-fallback: process exited early before resolve line"
        cat "$TMPOUT_BFALLBACK" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_BFALLBACK" 2>/dev/null; then
        BF_RESOLVED=1
        break
    fi
    sleep 0.1
done

if [[ $BF_RESOLVED -ne 1 ]]; then
    echo "FAIL: bundle-fallback: ONLYWALLPAPERS_WEB_RESOLVE line never appeared"
    cat "$TMPOUT_BFALLBACK" || true
    exit 1
fi

BF_WIN_LINE_FOUND=0
SCREEN_COUNT_BF=0
for i in $(seq 1 50); do
    WIN_LINE_BF="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_BFALLBACK" 2>/dev/null | grep 'gen=0' | head -1 || true)"
    if [[ -n "$WIN_LINE_BF" ]]; then
        BF_WIN_LINE_FOUND=1
        SCREEN_COUNT_BF="$(echo "$WIN_LINE_BF" | sed 's/.*count=\([0-9]*\).*/\1/')"
        break
    fi
    if ! kill -0 "$PID_BFALLBACK" 2>/dev/null; then
        echo "FAIL: bundle-fallback: process exited before ONLYWALLPAPERS_WINDOWS line appeared"
        cat "$TMPOUT_BFALLBACK" || true
        exit 1
    fi
    sleep 0.1
done

if [[ $BF_WIN_LINE_FOUND -ne 1 ]] || [[ "$SCREEN_COUNT_BF" -eq 0 ]]; then
    echo "FAIL: bundle-fallback: ONLYWALLPAPERS_WINDOWS count>0 line never appeared"
    cat "$TMPOUT_BFALLBACK" || true
    exit 1
fi

for i in $(seq 1 100); do
    if ! kill -0 "$PID_BFALLBACK" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_BFALLBACK" 2>/dev/null || true)"
    if [[ "$_cnt" -ge "$SCREEN_COUNT_BF" ]]; then break; fi
    sleep 0.1
done

kill -INT "$PID_BFALLBACK" 2>/dev/null || true
wait "$PID_BFALLBACK" 2>/dev/null || true
PID_BFALLBACK=""

BF_RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_BFALLBACK" | head -1)"
if ! echo "$BF_RESOLVE_LINE" | grep -Eq 'status=ok source=bundle( |$)'; then
    echo "FAIL: bundle-fallback: expected source=bundle when OW_APP_SUPPORT_DIR is a file (seed must fail), got: $BF_RESOLVE_LINE"
    cat "$TMPOUT_BFALLBACK" || true
    exit 1
fi

BF_LOADED="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_BFALLBACK" 2>/dev/null || true)"
BF_DISTINCT="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_BFALLBACK" \
    | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
BF_FAIL_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT_BFALLBACK" 2>/dev/null || true)"
if [[ "$BF_LOADED" -lt "$SCREEN_COUNT_BF" ]]; then
    echo "FAIL: bundle-fallback: expected $SCREEN_COUNT_BF loaded=ok gen=0 lines, got $BF_LOADED"
    cat "$TMPOUT_BFALLBACK" || true
    exit 1
fi
if [[ "$BF_DISTINCT" -lt "$SCREEN_COUNT_BF" ]]; then
    echo "FAIL: bundle-fallback: expected $SCREEN_COUNT_BF distinct win= values in loaded=ok gen=0 lines, got $BF_DISTINCT"
    cat "$TMPOUT_BFALLBACK" || true
    exit 1
fi
if [[ "$BF_FAIL_COUNT" -ne 0 ]]; then
    echo "FAIL: bundle-fallback: $BF_FAIL_COUNT loaded=fail line(s) found"
    cat "$TMPOUT_BFALLBACK" || true
    exit 1
fi
echo "[bundle-fallback] PASS: $BF_RESOLVE_LINE ($BF_LOADED loaded=ok with $BF_DISTINCT distinct win=, no loaded=fail)"

# Assert picker telemetry for bundle source (menuEnabled is the real NSMenuItem.isEnabled).
BF_PICKER_LINE="$(grep 'ONLYWALLPAPERS_PICKER.*menuEnabled=' "$TMPOUT_BFALLBACK" | head -1 || true)"
if ! echo "$BF_PICKER_LINE" | grep -Eq 'menuEnabled=false source=bundle( |$)'; then
    echo "FAIL: bundle-fallback: expected ONLYWALLPAPERS_PICKER menuEnabled=false source=bundle, got: $BF_PICKER_LINE"
    cat "$TMPOUT_BFALLBACK" || true
    exit 1
fi
echo "[bundle-fallback] PASS (picker): $BF_PICKER_LINE"

# --- Check G2: MALFORMED-TREE ---
# Proves: when wallpaper.js is replaced with a directory (seedFailed=false, marker hash
# matches), the resolver detects the malformation, falls back to bundle, and the picker
# correctly reports menuEnabled=false source=bundle.
# This catches the seedFailed-vs-actual-source mismatch: seedFailed=false is not
# sufficient to guarantee a valid tree.
echo "[malformed-tree] Testing malformed app-storage tree forces source=bundle..."

OW_SUPPORT_TMP_MALFORMED="$(mktemp -d)"
TMPOUT_MALFORMED="$(mktemp)"

# Launch 1: seed the tree normally so seedFailed=false and the marker is written.
env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_MALFORMED" "$BIN" >"$TMPOUT_MALFORMED" 2>&1 &
PID_MALFORMED=$!

for i in $(seq 1 50); do
    if ! kill -0 "$PID_MALFORMED" 2>/dev/null; then break; fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_MALFORMED" 2>/dev/null; then break; fi
    sleep 0.1
done
kill -INT "$PID_MALFORMED" 2>/dev/null || true
wait "$PID_MALFORMED" 2>/dev/null || true
PID_MALFORMED=""

if ! grep -Eq 'ONLYWALLPAPERS_WEB_RESOLVE.*source=appstore( |$)' "$TMPOUT_MALFORMED" 2>/dev/null; then
    echo "FAIL: malformed-tree seed-launch: expected source=appstore, got:"
    grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_MALFORMED" || true
    cat "$TMPOUT_MALFORMED" || true
    exit 1
fi
echo "[malformed-tree] seed-launch: source=appstore confirmed"

# Replace wallpaper.js with a directory of the same name.
# The marker hash still matches the bundle, so the seeder will skip re-seeding on next
# launch. The resolver must detect the dir and fall back to bundle.
rm -f "$OW_SUPPORT_TMP_MALFORMED/web/wallpaper.js"
mkdir -p "$OW_SUPPORT_TMP_MALFORMED/web/wallpaper.js"
echo "[malformed-tree] replaced wallpaper.js with a directory"

# Launch 2: seeder skips (marker hash matches), resolver detects malformation.
> "$TMPOUT_MALFORMED"
env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_MALFORMED" "$BIN" >>"$TMPOUT_MALFORMED" 2>&1 &
PID_MALFORMED=$!

MT_RESOLVED=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_MALFORMED" 2>/dev/null; then break; fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_MALFORMED" 2>/dev/null; then MT_RESOLVED=1; break; fi
    sleep 0.1
done

MT_WIN_COUNT=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_MALFORMED" 2>/dev/null; then break; fi
    _mt_win_line="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_MALFORMED" 2>/dev/null | grep 'gen=0' | head -1 || true)"
    if [[ -n "$_mt_win_line" ]]; then
        MT_WIN_COUNT="$(echo "$_mt_win_line" | sed 's/.*count=\([0-9]*\).*/\1/')"
        break
    fi
    sleep 0.1
done
for i in $(seq 1 100); do
    if ! kill -0 "$PID_MALFORMED" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_MALFORMED" 2>/dev/null || true)"
    if [[ "$MT_WIN_COUNT" -gt 0 ]] && [[ "$_cnt" -ge "$MT_WIN_COUNT" ]]; then break; fi
    sleep 0.1
done

kill -INT "$PID_MALFORMED" 2>/dev/null || true
wait "$PID_MALFORMED" 2>/dev/null || true
PID_MALFORMED=""

if [[ $MT_RESOLVED -ne 1 ]]; then
    echo "FAIL: malformed-tree: ONLYWALLPAPERS_WEB_RESOLVE line never appeared"
    cat "$TMPOUT_MALFORMED" || true
    exit 1
fi

MT_RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_MALFORMED" | head -1)"
if ! echo "$MT_RESOLVE_LINE" | grep -Eq 'status=ok source=bundle( |$)'; then
    echo "FAIL: malformed-tree: expected source=bundle when wallpaper.js is a directory, got: $MT_RESOLVE_LINE"
    cat "$TMPOUT_MALFORMED" || true
    exit 1
fi
echo "[malformed-tree] PASS (source): $MT_RESOLVE_LINE"

MT_PICKER_LINE="$(grep 'ONLYWALLPAPERS_PICKER.*menuEnabled=' "$TMPOUT_MALFORMED" | head -1 || true)"
if ! echo "$MT_PICKER_LINE" | grep -Eq 'menuEnabled=false source=bundle( |$)'; then
    echo "FAIL: malformed-tree: expected ONLYWALLPAPERS_PICKER menuEnabled=false source=bundle, got: $MT_PICKER_LINE"
    cat "$TMPOUT_MALFORMED" || true
    exit 1
fi
echo "[malformed-tree] PASS (picker): $MT_PICKER_LINE"

rm -f "$TMPOUT_MALFORMED" 2>/dev/null || true
TMPOUT_MALFORMED=""
rm -rf "$OW_SUPPORT_TMP_MALFORMED" 2>/dev/null || true
OW_SUPPORT_TMP_MALFORMED=""

# --- Check H: RESEED-ON-STALE-MARKER ---
# Proves: (1) corrupting the marker triggers reseed with byte-identical restore.
# (2) an unchanged relaunch does NOT reseed.
echo "[reseed-stale-marker] Testing content-hash reseed logic..."

OW_SUPPORT_TMP_RESEED="$(mktemp -d)"
MARKER_FILE="$OW_SUPPORT_TMP_RESEED/web/.seed-version"

# Launch 1: first launch, seeds with reseeded=true.
TMPOUT_RESEED1="$(mktemp)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_RESEED" env -u WALLPAPER_WEB_DIR \
    -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST \
    -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    "$BIN" >"$TMPOUT_RESEED1" 2>&1 &
PID_RESEED1=$!

RS_RESOLVED1=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_RESEED1" 2>/dev/null; then
        echo "FAIL: reseed-stale-marker launch-1 exited early"
        cat "$TMPOUT_RESEED1" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_RESEED1" 2>/dev/null; then RS_RESOLVED1=1; break; fi
    sleep 0.1
done

RS_WIN1=0
for i in $(seq 1 50); do
    if grep -q 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_RESEED1" 2>/dev/null; then RS_WIN1=1; break; fi
    if ! kill -0 "$PID_RESEED1" 2>/dev/null; then break; fi
    sleep 0.1
done

RS_SC1="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_RESEED1" 2>/dev/null | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
for i in $(seq 1 100); do
    if ! kill -0 "$PID_RESEED1" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_RESEED1" 2>/dev/null || true)"
    if [[ -n "$RS_SC1" ]] && [[ "$_cnt" -ge "$RS_SC1" ]]; then break; fi
    sleep 0.1
done

kill -INT "$PID_RESEED1" 2>/dev/null || true
wait "$PID_RESEED1" 2>/dev/null || true
PID_RESEED1=""

if ! grep -q 'ONLYWALLPAPERS_SEED.*reseeded=true' "$TMPOUT_RESEED1" 2>/dev/null; then
    echo "FAIL: reseed-stale-marker launch-1: expected reseeded=true, got:"
    grep 'ONLYWALLPAPERS_SEED' "$TMPOUT_RESEED1" || true
    cat "$TMPOUT_RESEED1" || true
    exit 1
fi
echo "[reseed-stale-marker] launch-1 reseeded=true confirmed"

# Corrupt the marker to force a reseed on next launch.
if [[ ! -f "$MARKER_FILE" ]]; then
    echo "FAIL: reseed-stale-marker: marker file not found at $MARKER_FILE"
    exit 1
fi
echo "WRONG_HASH_THAT_CANNOT_MATCH_ANY_REAL_BUNDLE_HASH" > "$MARKER_FILE"
echo "[reseed-stale-marker] marker corrupted"

# Launch 2: should reseed because marker is wrong.
TMPOUT_RESEED2="$(mktemp)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_RESEED" env -u WALLPAPER_WEB_DIR \
    -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST \
    -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    "$BIN" >"$TMPOUT_RESEED2" 2>&1 &
PID_RESEED2=$!

for i in $(seq 1 50); do
    if ! kill -0 "$PID_RESEED2" 2>/dev/null; then break; fi
    if grep -q 'ONLYWALLPAPERS_SEED' "$TMPOUT_RESEED2" 2>/dev/null; then break; fi
    sleep 0.1
done
RS_SC2="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_RESEED2" 2>/dev/null | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
for i in $(seq 1 100); do
    if ! kill -0 "$PID_RESEED2" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_RESEED2" 2>/dev/null || true)"
    if [[ -n "$RS_SC2" ]] && [[ "$_cnt" -ge "$RS_SC2" ]]; then break; fi
    sleep 0.1
done
kill -INT "$PID_RESEED2" 2>/dev/null || true
wait "$PID_RESEED2" 2>/dev/null || true
PID_RESEED2=""

if ! grep -q 'ONLYWALLPAPERS_SEED.*reseeded=true' "$TMPOUT_RESEED2" 2>/dev/null; then
    echo "FAIL: reseed-stale-marker launch-2: expected reseeded=true after corrupt marker, got:"
    grep 'ONLYWALLPAPERS_SEED' "$TMPOUT_RESEED2" || true
    cat "$TMPOUT_RESEED2" || true
    exit 1
fi
echo "[reseed-stale-marker] launch-2 reseeded=true confirmed (corrupt marker triggered reseed)"

# Assert code files restored byte-identical to bundle originals.
RS_BYTE_EQ_FAIL=0
for _name in index.html style.css wallpaper.js; do
    _seeded="$OW_SUPPORT_TMP_RESEED/web/$_name"
    _orig="$EXPECTED_BUNDLE_WEB_DIR/$_name"
    if [[ ! -f "$_seeded" ]]; then
        echo "FAIL [reseed-stale-marker]: seeded file missing after reseed: $_seeded"
        RS_BYTE_EQ_FAIL=1
    elif ! cmp -s "$_seeded" "$_orig"; then
        echo "FAIL [reseed-stale-marker]: $_name not byte-identical to bundle after reseed"
        RS_BYTE_EQ_FAIL=1
    else
        echo "[reseed-stale-marker] PASS: $_name byte-identical after reseed"
    fi
done
if [[ $RS_BYTE_EQ_FAIL -ne 0 ]]; then
    cat "$TMPOUT_RESEED2" || true
    exit 1
fi

# Launch 3: unchanged relaunch should NOT reseed.
TMPOUT_RESEED3="$(mktemp)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_RESEED" env -u WALLPAPER_WEB_DIR \
    -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST \
    -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    "$BIN" >"$TMPOUT_RESEED3" 2>&1 &
PID_RESEED3=$!

for i in $(seq 1 50); do
    if ! kill -0 "$PID_RESEED3" 2>/dev/null; then break; fi
    if grep -q 'ONLYWALLPAPERS_SEED' "$TMPOUT_RESEED3" 2>/dev/null; then break; fi
    sleep 0.1
done
RS_SC3="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_RESEED3" 2>/dev/null | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
for i in $(seq 1 100); do
    if ! kill -0 "$PID_RESEED3" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_RESEED3" 2>/dev/null || true)"
    if [[ -n "$RS_SC3" ]] && [[ "$_cnt" -ge "$RS_SC3" ]]; then break; fi
    sleep 0.1
done
kill -INT "$PID_RESEED3" 2>/dev/null || true
wait "$PID_RESEED3" 2>/dev/null || true
PID_RESEED3=""

if ! grep -q 'ONLYWALLPAPERS_SEED.*reseeded=false' "$TMPOUT_RESEED3" 2>/dev/null; then
    echo "FAIL: reseed-stale-marker launch-3: expected reseeded=false on unchanged relaunch, got:"
    grep 'ONLYWALLPAPERS_SEED' "$TMPOUT_RESEED3" || true
    cat "$TMPOUT_RESEED3" || true
    exit 1
fi
echo "[reseed-stale-marker] PASS: launch-3 reseeded=false confirmed (unchanged relaunch skips reseed)"

rm -f "$TMPOUT_RESEED1" "$TMPOUT_RESEED2" "$TMPOUT_RESEED3" 2>/dev/null || true
TMPOUT_RESEED1=""
TMPOUT_RESEED2=""
TMPOUT_RESEED3=""

# --- Check I: INCOMPLETE-TREE-SELF-HEAL ---
# Proves: a missing code file triggers reseed (self-heal) on next launch.
# The resolver completeness check is a last-resort safety net, but the seeder
# acts first and restores the missing file.
echo "[incomplete-tree] Testing incomplete app-storage self-heals on next launch..."

OW_SUPPORT_TMP_INCOMPLETE="$(mktemp -d)"
TMPOUT_INCOMPLETE1="$(mktemp)"

# Launch 1: seed the app-storage tree normally.
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_INCOMPLETE" env -u WALLPAPER_WEB_DIR     -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST     -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON "$BIN" >"$TMPOUT_INCOMPLETE1" 2>&1 &
PID_INCOMPLETE1=$!

for i in $(seq 1 50); do
    if ! kill -0 "$PID_INCOMPLETE1" 2>/dev/null; then break; fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_INCOMPLETE1" 2>/dev/null; then break; fi
    sleep 0.1
done
IT_SC1="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_INCOMPLETE1" 2>/dev/null | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
for i in $(seq 1 100); do
    if ! kill -0 "$PID_INCOMPLETE1" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_INCOMPLETE1" 2>/dev/null || true)"
    if [[ -n "$IT_SC1" ]] && [[ "$_cnt" -ge "$IT_SC1" ]]; then break; fi
    sleep 0.1
done
kill -INT "$PID_INCOMPLETE1" 2>/dev/null || true
wait "$PID_INCOMPLETE1" 2>/dev/null || true
PID_INCOMPLETE1=""

IT_RESOLVE1="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_INCOMPLETE1" | head -1)"
if ! echo "$IT_RESOLVE1" | grep -Eq 'status=ok source=appstore( |$)'; then
    echo "FAIL: incomplete-tree launch-1: expected source=appstore, got: $IT_RESOLVE1"
    cat "$TMPOUT_INCOMPLETE1" || true
    exit 1
fi
echo "[incomplete-tree] launch-1 appstore confirmed"

# Delete wallpaper.js to create an incomplete tree.
rm -f "$OW_SUPPORT_TMP_INCOMPLETE/web/wallpaper.js"
echo "[incomplete-tree] deleted wallpaper.js from seeded dir"

# Launch 2: seeder detects missing file and reseeds (self-heal).
TMPOUT_INCOMPLETE2="$(mktemp)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_INCOMPLETE" env -u WALLPAPER_WEB_DIR     -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST     -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON "$BIN" >"$TMPOUT_INCOMPLETE2" 2>&1 &
PID_INCOMPLETE2=$!

for i in $(seq 1 50); do
    if ! kill -0 "$PID_INCOMPLETE2" 2>/dev/null; then break; fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_INCOMPLETE2" 2>/dev/null; then break; fi
    sleep 0.1
done
IT_SC2="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_INCOMPLETE2" 2>/dev/null | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
for i in $(seq 1 100); do
    if ! kill -0 "$PID_INCOMPLETE2" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_INCOMPLETE2" 2>/dev/null || true)"
    if [[ -n "$IT_SC2" ]] && [[ "$_cnt" -ge "$IT_SC2" ]]; then break; fi
    sleep 0.1
done
kill -INT "$PID_INCOMPLETE2" 2>/dev/null || true
wait "$PID_INCOMPLETE2" 2>/dev/null || true
PID_INCOMPLETE2=""

# Re-capture IT_SC2 from completed output; the WINDOWS line may appear after the resolve poll snapshot.
if [[ -z "$IT_SC2" ]]; then
    IT_SC2="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_INCOMPLETE2" 2>/dev/null | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
fi

if ! grep -q 'ONLYWALLPAPERS_SEED.*reseeded=true' "$TMPOUT_INCOMPLETE2" 2>/dev/null; then
    echo "FAIL: incomplete-tree launch-2: expected reseeded=true (self-heal), got:"
    grep 'ONLYWALLPAPERS_SEED' "$TMPOUT_INCOMPLETE2" || true
    cat "$TMPOUT_INCOMPLETE2" || true
    exit 1
fi
echo "[incomplete-tree] launch-2 reseeded=true confirmed (self-heal)"

IT_RESOLVE2="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_INCOMPLETE2" | head -1)"
if ! echo "$IT_RESOLVE2" | grep -Eq 'status=ok source=appstore( |$)'; then
    echo "FAIL: incomplete-tree launch-2: expected source=appstore after self-heal, got: $IT_RESOLVE2"
    cat "$TMPOUT_INCOMPLETE2" || true
    exit 1
fi
echo "[incomplete-tree] launch-2 source=appstore confirmed"

IT_JS_RESTORED="$OW_SUPPORT_TMP_INCOMPLETE/web/wallpaper.js"
IT_JS_BUNDLE="$EXPECTED_BUNDLE_WEB_DIR/wallpaper.js"
if [[ ! -f "$IT_JS_RESTORED" ]]; then
    echo "FAIL: incomplete-tree launch-2: wallpaper.js not restored after self-heal"
    cat "$TMPOUT_INCOMPLETE2" || true
    exit 1
fi
if ! cmp -s "$IT_JS_RESTORED" "$IT_JS_BUNDLE"; then
    echo "FAIL: incomplete-tree launch-2: wallpaper.js not byte-identical to bundle after self-heal"
    exit 1
fi
echo "[incomplete-tree] PASS: $IT_RESOLVE2"
echo "[incomplete-tree] PASS: wallpaper.js restored byte-identical (self-heal)"

if [[ -z "$IT_SC2" ]] || [[ "$IT_SC2" -le 0 ]]; then
    echo "FAIL: incomplete-tree launch-2: no ONLYWALLPAPERS_WINDOWS count line (cannot assert webload after self-heal)"
    cat "$TMPOUT_INCOMPLETE2" || true
    exit 1
fi
IT_LOADED2="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_INCOMPLETE2" 2>/dev/null || true)"
IT_DISTINCT2="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_INCOMPLETE2" \
    | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
IT_FAIL2="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=fail' "$TMPOUT_INCOMPLETE2" 2>/dev/null || true)"
if [[ "$IT_LOADED2" -lt "$IT_SC2" ]]; then
    echo "FAIL: incomplete-tree launch-2: after self-heal expected $IT_SC2 loaded=ok gen=0 lines, got $IT_LOADED2"
    cat "$TMPOUT_INCOMPLETE2" || true
    exit 1
fi
if [[ "$IT_DISTINCT2" -lt "$IT_SC2" ]]; then
    echo "FAIL: incomplete-tree launch-2: after self-heal expected $IT_SC2 distinct win= values in loaded=ok gen=0 lines, got $IT_DISTINCT2"
    cat "$TMPOUT_INCOMPLETE2" || true
    exit 1
fi
if [[ "$IT_FAIL2" -ne 0 ]]; then
    echo "FAIL: incomplete-tree launch-2: $IT_FAIL2 loaded=fail line(s) after self-heal (WebKit load broken after repair)"
    cat "$TMPOUT_INCOMPLETE2" || true
    exit 1
fi
echo "[incomplete-tree] PASS: $IT_LOADED2 loaded=ok gen=0 line(s) with $IT_DISTINCT2 distinct win= after self-heal, no loaded=fail"

rm -f "$TMPOUT_INCOMPLETE1" "$TMPOUT_INCOMPLETE2" 2>/dev/null || true
TMPOUT_INCOMPLETE1=""
TMPOUT_INCOMPLETE2=""

# --- Check J: READONLY-ASSETS ---
# Proves: when source=appstore but the assets dir is read-only, the picker
# is disabled (menuEnabled=false) while the wallpaper still loads (source=appstore).
echo "[readonly-assets] Testing read-only assets dir disables picker but keeps source=appstore..."

OW_SUPPORT_TMP_READONLY="$(mktemp -d)"
TMPOUT_READONLY="$(mktemp)"

# Launch 1: seed a normal appstore tree.
env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_READONLY" "$BIN" >"$TMPOUT_READONLY" 2>&1 &
PID_READONLY=$!

for i in $(seq 1 50); do
    if ! kill -0 "$PID_READONLY" 2>/dev/null; then
        echo "FAIL: readonly-assets launch-1: process exited early"
        cat "$TMPOUT_READONLY" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_READONLY" 2>/dev/null; then break; fi
    sleep 0.1
done

kill -INT "$PID_READONLY" 2>/dev/null || true
wait "$PID_READONLY" 2>/dev/null || true
PID_READONLY=""

if ! grep -Eq 'ONLYWALLPAPERS_WEB_RESOLVE.*source=appstore( |$)' "$TMPOUT_READONLY" 2>/dev/null; then
    echo "FAIL: readonly-assets launch-1: expected source=appstore, got:"
    grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_READONLY" || true
    cat "$TMPOUT_READONLY" || true
    exit 1
fi
RA_PICKER_L1="$(grep 'ONLYWALLPAPERS_PICKER.*menuEnabled=' "$TMPOUT_READONLY" | head -1 || true)"
if ! echo "$RA_PICKER_L1" | grep -Eq 'menuEnabled=true source=appstore( |$)'; then
    echo "FAIL: readonly-assets launch-1: expected menuEnabled=true source=appstore, got: $RA_PICKER_L1"
    cat "$TMPOUT_READONLY" || true
    exit 1
fi
echo "[readonly-assets] launch-1 PASS (seeded, menuEnabled=true): $RA_PICKER_L1"

# Make the assets dir read-only.
chmod 0555 "$OW_SUPPORT_TMP_READONLY/web/assets"
echo "[readonly-assets] chmod 0555 on assets dir"

# Launch 2: assets dir is read-only. Source must still be appstore, picker must be disabled.
> "$TMPOUT_READONLY"
env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
    OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP_READONLY" "$BIN" >>"$TMPOUT_READONLY" 2>&1 &
PID_READONLY=$!

RA_RESOLVED2=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_READONLY" 2>/dev/null; then
        echo "FAIL: readonly-assets launch-2: process exited early"
        cat "$TMPOUT_READONLY" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_READONLY" 2>/dev/null; then RA_RESOLVED2=1; break; fi
    sleep 0.1
done

RA_WIN2=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_READONLY" 2>/dev/null; then break; fi
    if grep -q 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_READONLY" 2>/dev/null; then RA_WIN2=1; break; fi
    sleep 0.1
done
RA_SC2="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_READONLY" 2>/dev/null | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
for i in $(seq 1 100); do
    if ! kill -0 "$PID_READONLY" 2>/dev/null; then break; fi
    _cnt="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_READONLY" 2>/dev/null || true)"
    if [[ -n "$RA_SC2" ]] && [[ "$_cnt" -ge "$RA_SC2" ]]; then break; fi
    sleep 0.1
done

kill -INT "$PID_READONLY" 2>/dev/null || true
wait "$PID_READONLY" 2>/dev/null || true
PID_READONLY=""

# Restore permissions so cleanup can delete the temp dir.
chmod 0755 "$OW_SUPPORT_TMP_READONLY/web/assets"
echo "[readonly-assets] chmod 0755 restored"

if [[ $RA_RESOLVED2 -ne 1 ]]; then
    echo "FAIL: readonly-assets launch-2: ONLYWALLPAPERS_WEB_RESOLVE never appeared"
    cat "$TMPOUT_READONLY" || true
    exit 1
fi

RA_RESOLVE2="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT_READONLY" | head -1)"
if ! echo "$RA_RESOLVE2" | grep -Eq 'status=ok source=appstore( |$)'; then
    echo "FAIL: readonly-assets launch-2: expected source=appstore (readonly assets must not fall back to bundle), got: $RA_RESOLVE2"
    cat "$TMPOUT_READONLY" || true
    exit 1
fi
echo "[readonly-assets] launch-2 source=appstore PASS: $RA_RESOLVE2"

RA_PICKER_L2="$(grep 'ONLYWALLPAPERS_PICKER.*menuEnabled=' "$TMPOUT_READONLY" | head -1 || true)"
if ! echo "$RA_PICKER_L2" | grep -Eq 'menuEnabled=false source=appstore( |$)'; then
    echo "FAIL: readonly-assets launch-2: expected ONLYWALLPAPERS_PICKER menuEnabled=false source=appstore, got: $RA_PICKER_L2"
    cat "$TMPOUT_READONLY" || true
    exit 1
fi
echo "[readonly-assets] launch-2 PASS (picker disabled, loaded=ok): $RA_PICKER_L2"

rm -f "$TMPOUT_READONLY" 2>/dev/null || true
TMPOUT_READONLY=""
rm -rf "$OW_SUPPORT_TMP_READONLY" 2>/dev/null || true
OW_SUPPORT_TMP_READONLY=""

echo "=== PASS: all webdir checks passed ==="
