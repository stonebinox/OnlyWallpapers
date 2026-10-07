#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PID=""
TMPOUT=""
OW_SUPPORT_TMP=""
FIXTURE_FILE=""

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 0.4
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    [[ -n "$TMPOUT" ]] && rm -f "$TMPOUT" || true
    [[ -n "$OW_SUPPORT_TMP" ]] && rm -rf "$OW_SUPPORT_TMP" || true
    [[ -n "$FIXTURE_FILE" ]] && rm -f "$FIXTURE_FILE" || true
}
trap cleanup EXIT

echo "[lightning-check] building..."
swift build -c release 2>&1 | tail -5
BINARY="$(swift build -c release --show-bin-path 2>/dev/null)/OnlyWallpapers"

PASS=0
FAIL=0
SKIP=0
WINDOW_VERIFIED=0

kill_app() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""
}

get_win_count() {
    grep 'ONLYWALLPAPERS_WINDOWS' "$1" | tail -1 | sed 's/.*count=//;s/ .*//' 2>/dev/null || echo '0'
}

# --- (a) ACTIVE: OW_WGT_TEST=1, lightning effect registered, frames advance, pixels sampled ---
echo "[lightning-check] running (a) ACTIVE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_WGT_TEST=1 \
  OW_OVERLAY_TEST=1 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 12

win_count=$(get_win_count "$TMPOUT")
active_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[active] SKIP: 0 windows (genuine headless)"
    active_ok=2
else
    WINDOW_VERIFIED=1
    active_ok=1

    # Collect ONLYWALLPAPERS_STORM lines
    storm_out=$(grep 'ONLYWALLPAPERS_STORM ' "$TMPOUT" | grep -v STORM_PIXEL || true)
    storm_wins=$(printf '%s\n' "$storm_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    storm_win_count=$(printf '%s\n' "$storm_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ "$storm_win_count" -eq 0 ]]; then
        echo "[active] FAIL: no ONLYWALLPAPERS_STORM lines"
        active_ok=0
    else
        echo "[active] STORM lines found for $storm_win_count window(s)"
    fi

    if [[ "$storm_win_count" -ne "$win_count" ]]; then
        echo "[active] FAIL: storm lines from $storm_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
        active_ok=0
    fi

    # Per-window: active=true effect=registered
    while IFS= read -r wnum; do
        [[ -z "$wnum" ]] && continue
        win_storm=$(printf '%s\n' "$storm_out" | grep "win=${wnum} " | tail -1 || true)

        if ! printf '%s' "$win_storm" | grep -q 'active=true'; then
            echo "[active] FAIL: win=$wnum active!=true in: $win_storm"
            active_ok=0
        else
            echo "[active] win=$wnum: active=true (ok)"
        fi

        if ! printf '%s' "$win_storm" | grep -q 'effect=registered'; then
            echo "[active] FAIL: win=$wnum effect!=registered in: $win_storm"
            active_ok=0
        else
            echo "[active] win=$wnum: effect=registered (ok)"
        fi

        # Overlay frames advanced (from ONLYWALLPAPERS_OVERLAY lines)
        overlay_lines=$(grep "ONLYWALLPAPERS_OVERLAY.*win=${wnum} " "$TMPOUT" || true)
        first_frames=$(printf '%s\n' "$overlay_lines" | head -1 | grep -oE 'frames=[0-9]+' | sed 's/frames=//' || echo "0")
        last_frames=$(printf '%s\n' "$overlay_lines" | tail -1 | grep -oE 'frames=[0-9]+' | sed 's/frames=//' || echo "0")
        overlay_line_count=$(printf '%s\n' "$overlay_lines" | grep -c . 2>/dev/null || echo 0)
        if [[ "$overlay_line_count" -ge 2 && "$last_frames" -gt "$first_frames" ]]; then
            echo "[active] win=$wnum: overlay frames advanced $first_frames -> $last_frames (ok)"
        else
            echo "[active] FAIL: win=$wnum overlay frames did not advance (first=$first_frames last=$last_frames lines=$overlay_line_count)"
            active_ok=0
        fi

        # Pixel sampling: ONLYWALLPAPERS_STORM_PIXEL
        pixel_line=$(grep "ONLYWALLPAPERS_STORM_PIXEL.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$pixel_line" ]]; then
            echo "[active] FAIL: win=$wnum no ONLYWALLPAPERS_STORM_PIXEL line"
            active_ok=0
        elif printf '%s' "$pixel_line" | grep -q 'unavailable'; then
            echo "[active] FAIL: win=$wnum STORM_PIXEL unavailable"
            active_ok=0
        else
            maxA=$(printf '%s' "$pixel_line" | grep -oE 'maxRenderedAlpha=[0-9]+' | sed 's/maxRenderedAlpha=//' || echo "0")
            postIdle=$(printf '%s' "$pixel_line" | grep -oE 'postFlashIdleAlpha=-?[0-9]+' | sed 's/postFlashIdleAlpha=//' || echo "-1")
            if [[ "$maxA" -le 0 ]]; then
                echo "[active] FAIL: win=$wnum maxRenderedAlpha=$maxA (flash did not draw visible pixels)"
                active_ok=0
            else
                echo "[active] win=$wnum: maxRenderedAlpha=$maxA (ok, flash drew pixels)"
            fi
            if [[ "$postIdle" -eq -1 ]]; then
                echo "[active] FAIL: win=$wnum postFlashIdleAlpha never sampled (idle frame after flash+idle cycle not observed)"
                active_ok=0
            elif [[ "$postIdle" -ne 0 ]]; then
                echo "[active] FAIL: win=$wnum postFlashIdleAlpha=$postIdle (canvas dirty after flash, ghost overlay regression)"
                active_ok=0
            else
                echo "[active] win=$wnum: postFlashIdleAlpha=0 (ok, canvas clear after flash)"
            fi
        fi

        # media=playing
        if grep -qE "ONLYWALLPAPERS_(WEB|FRAMING_MEDIA).*win=${wnum}.*media=playing" "$TMPOUT"; then
            echo "[active] win=$wnum: media=playing confirmed"
        else
            echo "[active] FAIL: win=$wnum media=playing not found"
            active_ok=0
        fi
    done <<< "$storm_wins"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $active_ok -eq 2 ]]; then
    echo "[lightning-check] SKIP (a) ACTIVE"
    SKIP=$((SKIP+1))
elif [[ $active_ok -eq 1 ]]; then
    echo "[lightning-check] PASS (a) ACTIVE"
    PASS=$((PASS+1))
else
    echo "[lightning-check] FAIL (a) ACTIVE"
    FAIL=$((FAIL+1))
fi

# --- (b) INACTIVE: no OW_WGT_TEST, no storm weather ---
echo "[lightning-check] running (b) INACTIVE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_WGT_TEST \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
inert_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[inactive] SKIP: 0 windows (genuine headless)"
    inert_ok=2
else
    WINDOW_VERIFIED=1
    inert_ok=1

    storm_out=$(grep 'ONLYWALLPAPERS_STORM ' "$TMPOUT" | grep -v STORM_PIXEL || true)
    storm_wins=$(printf '%s\n' "$storm_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)

    storm_win_count=$(printf '%s\n' "$storm_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$storm_wins" ]]; then
        echo "[inactive] FAIL: no ONLYWALLPAPERS_STORM lines (expected active=false effect=none)"
        inert_ok=0
    else
        if [[ "$storm_win_count" -ne "$win_count" ]]; then
            echo "[inactive] FAIL: storm lines from $storm_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            inert_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_storm=$(printf '%s\n' "$storm_out" | grep "win=${wnum} " | tail -1 || true)
            if printf '%s' "$win_storm" | grep -q 'active=false'; then
                echo "[inactive] win=$wnum: active=false (ok)"
            else
                echo "[inactive] FAIL: win=$wnum active!=false in: $win_storm"
                inert_ok=0
            fi
            if printf '%s' "$win_storm" | grep -q 'effect=none'; then
                echo "[inactive] win=$wnum: effect=none (ok)"
            else
                echo "[inactive] FAIL: win=$wnum effect!=none in: $win_storm"
                inert_ok=0
            fi
        done <<< "$storm_wins"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $inert_ok -eq 2 ]]; then
    echo "[lightning-check] SKIP (b) INACTIVE"
    SKIP=$((SKIP+1))
elif [[ $inert_ok -eq 1 ]]; then
    echo "[lightning-check] PASS (b) INACTIVE"
    PASS=$((PASS+1))
else
    echo "[lightning-check] FAIL (b) INACTIVE"
    FAIL=$((FAIL+1))
fi

write_storm_fixture() {
    local path="$1"
    cat > "$path" << 'FIXTURE_EOF'
{"latitude":37.77,"longitude":-122.42,"utc_offset_seconds":-25200,"timezone":"America/Los_Angeles","current_units":{"time":"unixtime","interval":"seconds","weather_code":"wmo code","cloud_cover":"%","precipitation":"mm","is_day":""},"current":{"time":1728388800,"interval":900,"weather_code":95,"cloud_cover":100,"precipitation":5.0,"is_day":1},"daily_units":{"time":"unixtime","sunrise":"unixtime","sunset":"unixtime"},"daily":{"time":[1728302400],"sunrise":[1728325200],"sunset":[1728368400]}}
FIXTURE_EOF
}

write_clear_fixture() {
    local path="$1"
    cat > "$path" << 'FIXTURE_EOF'
{"latitude":37.77,"longitude":-122.42,"utc_offset_seconds":-25200,"timezone":"America/Los_Angeles","current_units":{"time":"unixtime","interval":"seconds","weather_code":"wmo code","cloud_cover":"%","precipitation":"mm","is_day":""},"current":{"time":1728388800,"interval":900,"weather_code":0,"cloud_cover":0,"precipitation":0.0,"is_day":1},"daily_units":{"time":"unixtime","sunrise":"unixtime","sunset":"unixtime"},"daily":{"time":[1728302400],"sunrise":[1728325200],"sunset":[1728368400]}}
FIXTURE_EOF
}

# --- (c) STORM-WEATHER fixture: weather_code=95 via OW_MOOD_FAKE_RESPONSE_FILE -> active=true effect=registered ---
echo "[lightning-check] running (c) STORM-WEATHER..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"
FIXTURE_FILE="$(mktemp)"
write_storm_fixture "$FIXTURE_FILE"
# Seed config.json with lat/lon so effectiveLatLon() returns a value and triggers the fetch path.
mkdir -p "$OW_SUPPORT_TMP"
printf '{"lat":37.77,"lon":-122.42}' > "$OW_SUPPORT_TMP/config.json"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_WGT_TEST \
  OW_MOOD_FAKE_RESPONSE_FILE="$FIXTURE_FILE" \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 8

win_count=$(get_win_count "$TMPOUT")
storm_weather_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[storm-weather] SKIP: 0 windows (genuine headless)"
    storm_weather_ok=2
else
    WINDOW_VERIFIED=1
    storm_weather_ok=1
    storm_out=$(grep 'ONLYWALLPAPERS_STORM ' "$TMPOUT" | grep -v STORM_PIXEL || true)
    storm_wins=$(printf '%s\n' "$storm_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)

    storm_win_count=$(printf '%s\n' "$storm_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$storm_wins" ]]; then
        echo "[storm-weather] FAIL: no ONLYWALLPAPERS_STORM lines"
        storm_weather_ok=0
    else
        if [[ "$storm_win_count" -ne "$win_count" ]]; then
            echo "[storm-weather] FAIL: storm lines from $storm_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            storm_weather_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_storm=$(printf '%s\n' "$storm_out" | grep "win=${wnum} " | tail -1 || true)
            if ! printf '%s' "$win_storm" | grep -q 'active=true'; then
                echo "[storm-weather] FAIL: win=$wnum active!=true: $win_storm"
                storm_weather_ok=0
            else
                echo "[storm-weather] win=$wnum: active=true (ok)"
            fi
            if ! printf '%s' "$win_storm" | grep -q 'effect=registered'; then
                echo "[storm-weather] FAIL: win=$wnum effect!=registered: $win_storm"
                storm_weather_ok=0
            else
                echo "[storm-weather] win=$wnum: effect=registered (ok)"
            fi
        done <<< "$storm_wins"
    fi
fi

kill_app
rm -f "$TMPOUT" "$FIXTURE_FILE"; TMPOUT=""; FIXTURE_FILE=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $storm_weather_ok -eq 2 ]]; then
    echo "[lightning-check] SKIP (c) STORM-WEATHER"
    SKIP=$((SKIP+1))
elif [[ $storm_weather_ok -eq 1 ]]; then
    echo "[lightning-check] PASS (c) STORM-WEATHER"
    PASS=$((PASS+1))
else
    echo "[lightning-check] FAIL (c) STORM-WEATHER"
    FAIL=$((FAIL+1))
fi

# --- (d) NON-STORM-WEATHER fixture: weather_code=0 via OW_MOOD_FAKE_RESPONSE_FILE -> active=false effect=none ---
echo "[lightning-check] running (d) NON-STORM-WEATHER..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"
FIXTURE_FILE="$(mktemp)"
write_clear_fixture "$FIXTURE_FILE"
mkdir -p "$OW_SUPPORT_TMP"
printf '{"lat":37.77,"lon":-122.42}' > "$OW_SUPPORT_TMP/config.json"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_WGT_TEST \
  OW_MOOD_FAKE_RESPONSE_FILE="$FIXTURE_FILE" \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
non_storm_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[non-storm-weather] SKIP: 0 windows (genuine headless)"
    non_storm_ok=2
else
    WINDOW_VERIFIED=1
    non_storm_ok=1
    storm_out=$(grep 'ONLYWALLPAPERS_STORM ' "$TMPOUT" | grep -v STORM_PIXEL || true)
    storm_wins=$(printf '%s\n' "$storm_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)

    storm_win_count=$(printf '%s\n' "$storm_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$storm_wins" ]]; then
        echo "[non-storm-weather] FAIL: no ONLYWALLPAPERS_STORM lines (expected active=false effect=none)"
        non_storm_ok=0
    else
        if [[ "$storm_win_count" -ne "$win_count" ]]; then
            echo "[non-storm-weather] FAIL: storm lines from $storm_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            non_storm_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_storm=$(printf '%s\n' "$storm_out" | grep "win=${wnum} " | tail -1 || true)
            if ! printf '%s' "$win_storm" | grep -q 'active=false'; then
                echo "[non-storm-weather] FAIL: win=$wnum active!=false: $win_storm"
                non_storm_ok=0
            else
                echo "[non-storm-weather] win=$wnum: active=false (ok)"
            fi
            if ! printf '%s' "$win_storm" | grep -q 'effect=none'; then
                echo "[non-storm-weather] FAIL: win=$wnum effect!=none: $win_storm"
                non_storm_ok=0
            else
                echo "[non-storm-weather] win=$wnum: effect=none (ok)"
            fi
        done <<< "$storm_wins"
    fi
fi

kill_app
rm -f "$TMPOUT" "$FIXTURE_FILE"; TMPOUT=""; FIXTURE_FILE=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $non_storm_ok -eq 2 ]]; then
    echo "[lightning-check] SKIP (d) NON-STORM-WEATHER"
    SKIP=$((SKIP+1))
elif [[ $non_storm_ok -eq 1 ]]; then
    echo "[lightning-check] PASS (d) NON-STORM-WEATHER"
    PASS=$((PASS+1))
else
    echo "[lightning-check] FAIL (d) NON-STORM-WEATHER"
    FAIL=$((FAIL+1))
fi

# --- (e) JS envelope readback: window.__wgtFlashAlpha shape verified via native evaluateJavaScript ---
echo "[lightning-check] running (e) JS-ENVELOPE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_WGT_TEST=1 \
  OW_WGT_ENVELOPE_TEST=1 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
envelope_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[js-envelope] SKIP: 0 windows (genuine headless)"
    envelope_ok=2
else
    WINDOW_VERIFIED=1
    envelope_ok=1
    env_lines=$(grep 'ONLYWALLPAPERS_WGT_ENVELOPE' "$TMPOUT" || true)
    if [[ -z "$env_lines" ]]; then
        echo "[js-envelope] FAIL: no ONLYWALLPAPERS_WGT_ENVELOPE lines"
        envelope_ok=0
    else
        # t=0 should be ~0.0
        r0=$(printf '%s\n' "$env_lines" | grep 'elapsedMs=0 ' | head -1 | grep -oE 'result=[0-9.]+' | sed 's/result=//' || echo "none")
        # t=10 should be in the rise phase (> 0, < peak)
        r10=$(printf '%s\n' "$env_lines" | grep 'elapsedMs=10 ' | head -1 | grep -oE 'result=[0-9.]+' | sed 's/result=//' || echo "none")
        # t=20 should be ~peak (0.7)
        r20=$(printf '%s\n' "$env_lines" | grep 'elapsedMs=20 ' | head -1 | grep -oE 'result=[0-9.]+' | sed 's/result=//' || echo "none")
        # t=21 should be < peak but > 0
        r21=$(printf '%s\n' "$env_lines" | grep 'elapsedMs=21 ' | head -1 | grep -oE 'result=[0-9.]+' | sed 's/result=//' || echo "none")
        # t=140 should be 0.0
        r140=$(printf '%s\n' "$env_lines" | grep 'elapsedMs=140 ' | head -1 | grep -oE 'result=[0-9.]+' | sed 's/result=//' || echo "none")
        # t=200 should be 0.0 (post-burst)
        r200=$(printf '%s\n' "$env_lines" | grep 'elapsedMs=200 ' | head -1 | grep -oE 'result=[0-9.]+' | sed 's/result=//' || echo "none")

        echo "[js-envelope] t=0 result=$r0 t=10 result=$r10 t=20 result=$r20 t=21 result=$r21 t=140 result=$r140 t=200 result=$r200"

        # t=0 must be < 0.05
        if awk "BEGIN{exit !($r0 < 0.05)}" 2>/dev/null; then
            echo "[js-envelope] t=0: near-zero (ok)"
        else
            echo "[js-envelope] FAIL: t=0 result=$r0 expected < 0.05"
            envelope_ok=0
        fi
        # t=10 must be > 0 (early rise) and < t=20 (below peak)
        if awk "BEGIN{exit !($r10 > 0.0 && $r10 < $r20)}" 2>/dev/null; then
            echo "[js-envelope] t=10: early-rise > 0 and < peak (ok)"
        else
            echo "[js-envelope] FAIL: t=10 result=$r10 expected > 0 and < t=20 result=$r20"
            envelope_ok=0
        fi
        # t=20 must be >= 0.65 (near peak=0.7)
        if awk "BEGIN{exit !($r20 >= 0.65)}" 2>/dev/null; then
            echo "[js-envelope] t=20: near-peak (ok)"
        else
            echo "[js-envelope] FAIL: t=20 result=$r20 expected >= 0.65"
            envelope_ok=0
        fi
        # t=21 must be < t=20 (decay started)
        if awk "BEGIN{exit !($r21 < $r20)}" 2>/dev/null; then
            echo "[js-envelope] t=21 < t=20: decay started (ok)"
        else
            echo "[js-envelope] FAIL: t=21 result=$r21 should be < t=20 result=$r20"
            envelope_ok=0
        fi
        # t=140 must be 0.0
        if awk "BEGIN{exit !($r140 == 0.0)}" 2>/dev/null; then
            echo "[js-envelope] t=140: zero (ok)"
        else
            echo "[js-envelope] FAIL: t=140 result=$r140 expected 0.0"
            envelope_ok=0
        fi
        # t=200 must be 0.0 (post-burst)
        if awk "BEGIN{exit !($r200 == 0.0)}" 2>/dev/null; then
            echo "[js-envelope] t=200: zero post-burst (ok)"
        else
            echo "[js-envelope] FAIL: t=200 result=$r200 expected 0.0 (post-burst tail not clearing)"
            envelope_ok=0
        fi
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $envelope_ok -eq 2 ]]; then
    echo "[lightning-check] SKIP (e) JS-ENVELOPE"
    SKIP=$((SKIP+1))
elif [[ $envelope_ok -eq 1 ]]; then
    echo "[lightning-check] PASS (e) JS-ENVELOPE"
    PASS=$((PASS+1))
else
    echo "[lightning-check] FAIL (e) JS-ENVELOPE"
    FAIL=$((FAIL+1))
fi

# --- (f) REDUCED-MOTION: storm active + OW_WGT_REDUCED_MOTION=1 -> effect=none ---
echo "[lightning-check] running (f) REDUCED-MOTION..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_WGT_TEST=1 \
  OW_WGT_REDUCED_MOTION=1 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
rm_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[reduced-motion] SKIP: 0 windows (genuine headless)"
    rm_ok=2
else
    WINDOW_VERIFIED=1
    rm_ok=1
    storm_out=$(grep 'ONLYWALLPAPERS_STORM ' "$TMPOUT" | grep -v STORM_PIXEL || true)
    storm_wins=$(printf '%s\n' "$storm_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)

    storm_win_count=$(printf '%s\n' "$storm_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$storm_wins" ]]; then
        echo "[reduced-motion] FAIL: no ONLYWALLPAPERS_STORM lines"
        rm_ok=0
    else
        if [[ "$storm_win_count" -ne "$win_count" ]]; then
            echo "[reduced-motion] FAIL: storm lines from $storm_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            rm_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_storm=$(printf '%s\n' "$storm_out" | grep "win=${wnum} " | tail -1 || true)
            if ! printf '%s' "$win_storm" | grep -q 'active=true'; then
                echo "[reduced-motion] FAIL: win=$wnum active!=true (storm should be active but suppressed by reduced-motion): $win_storm"
                rm_ok=0
            else
                echo "[reduced-motion] win=$wnum: active=true (ok, storm active)"
            fi
            if ! printf '%s' "$win_storm" | grep -q 'effect=none'; then
                echo "[reduced-motion] FAIL: win=$wnum effect!=none (reduced motion should suppress lightning): $win_storm"
                rm_ok=0
            else
                echo "[reduced-motion] win=$wnum: effect=none (ok, lightning suppressed by reduced-motion)"
            fi
        done <<< "$storm_wins"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $rm_ok -eq 2 ]]; then
    echo "[lightning-check] SKIP (f) REDUCED-MOTION"
    SKIP=$((SKIP+1))
elif [[ $rm_ok -eq 1 ]]; then
    echo "[lightning-check] PASS (f) REDUCED-MOTION"
    PASS=$((PASS+1))
else
    echo "[lightning-check] FAIL (f) REDUCED-MOTION"
    FAIL=$((FAIL+1))
fi

# --- (g) STORM->INACTIVE TRANSITION: unregister path verified ---
echo "[lightning-check] running (g) STORM-INACTIVE-TRANSITION..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_WGT_TEST=1 \
  OW_WGT_STORM_TOGGLE_TEST=1 \
  OW_OVERLAY_TEST=1 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
transition_ok=0

win_count=$(get_win_count "$TMPOUT")
TOGGLE_SENT=0
for i in $(seq 1 40); do
    sleep 0.5
    wc_now=$(get_win_count "$TMPOUT")
    [[ "$wc_now" -gt 0 ]] && win_count=$wc_now
    pixel_line=$(grep "ONLYWALLPAPERS_STORM_PIXEL" "$TMPOUT" | tail -1 || true)
    if [[ -n "$pixel_line" ]]; then
        maxA=$(printf '%s' "$pixel_line" | grep -oE 'maxRenderedAlpha=[0-9]+' | sed 's/maxRenderedAlpha=//' || echo "0")
        if [[ "$maxA" -gt 0 ]]; then
            echo "[storm-inactive] flash+idle observed (maxRenderedAlpha=$maxA), sending SIGUSR2"
            kill -SIGUSR2 "$PID" 2>/dev/null || true
            TOGGLE_SENT=1
            break
        fi
    fi
done

if [[ "$win_count" -eq 0 ]]; then
    echo "[storm-inactive] SKIP: 0 windows (genuine headless)"
    transition_ok=2
elif [[ $TOGGLE_SENT -eq 0 ]]; then
    echo "[storm-inactive] FAIL: no flash+idle observed before timeout (cannot test transition)"
    transition_ok=0
else
    WINDOW_VERIFIED=1
    transition_ok=1
    for i in $(seq 1 20); do
        sleep 0.5
        toggle_count=$(grep -c "ONLYWALLPAPERS_STORM_TOGGLE win=" "$TMPOUT" 2>/dev/null || echo 0)
        canvas_count=$(grep -c "ONLYWALLPAPERS_STORM_CANVAS_IDLE" "$TMPOUT" 2>/dev/null || echo 0)
        if [[ "$toggle_count" -ge "$win_count" && "$canvas_count" -ge "$win_count" ]]; then
            break
        fi
    done

    toggle_lines=$(grep "ONLYWALLPAPERS_STORM_TOGGLE win=" "$TMPOUT" || true)
    toggle_wins=$(printf '%s\n' "$toggle_lines" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    toggle_win_count=$(printf '%s\n' "$toggle_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ "$toggle_win_count" -ne "$win_count" ]]; then
        echo "[storm-inactive] FAIL: toggle readback from $toggle_win_count window(s), expected $win_count"
        transition_ok=0
    fi

    while IFS= read -r wnum; do
        [[ -z "$wnum" ]] && continue
        tline=$(printf '%s\n' "$toggle_lines" | grep "win=${wnum} " | tail -1 || true)
        if ! printf '%s' "$tline" | grep -q 'effect=none'; then
            echo "[storm-inactive] FAIL: win=$wnum effect!=none after toggle: $tline"
            transition_ok=0
        else
            echo "[storm-inactive] win=$wnum: effect=none after toggle (ok)"
        fi
        cline=$(grep "ONLYWALLPAPERS_STORM_CANVAS_IDLE.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$cline" ]]; then
            echo "[storm-inactive] FAIL: win=$wnum no STORM_CANVAS_IDLE line"
            transition_ok=0
        else
            idleA=$(printf '%s' "$cline" | grep -oE 'idleAlpha=-?[0-9]+' | sed 's/idleAlpha=//' || echo "-1")
            if [[ "$idleA" -ne 0 ]]; then
                echo "[storm-inactive] FAIL: win=$wnum canvas not cleared after toggle (idleAlpha=$idleA)"
                transition_ok=0
            else
                echo "[storm-inactive] win=$wnum: canvas cleared after toggle (ok)"
            fi
        fi
    done <<< "$toggle_wins"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $transition_ok -eq 2 ]]; then
    echo "[lightning-check] SKIP (g) STORM-INACTIVE-TRANSITION"
    SKIP=$((SKIP+1))
elif [[ $transition_ok -eq 1 ]]; then
    echo "[lightning-check] PASS (g) STORM-INACTIVE-TRANSITION"
    PASS=$((PASS+1))
else
    echo "[lightning-check] FAIL (g) STORM-INACTIVE-TRANSITION"
    FAIL=$((FAIL+1))
fi

echo ""
if [[ $WINDOW_VERIFIED -eq 0 && $SKIP -gt 0 ]]; then
    echo "[lightning-check] ALL-SKIPPED: no integration sub-check verified windows (PASS=$PASS FAIL=$FAIL SKIP=$SKIP)"
    exit 1
fi
echo "[lightning-check] Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
