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

echo "[rain-check] building..."
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

write_rain_fixture() {
    local path="$1"
    cat > "$path" << 'FIXTURE_EOF'
{"latitude":37.77,"longitude":-122.42,"utc_offset_seconds":-25200,"timezone":"America/Los_Angeles","current_units":{"time":"unixtime","interval":"seconds","weather_code":"wmo code","cloud_cover":"%","precipitation":"mm","is_day":"","wind_speed_10m":"km/h","wind_direction_10m":"degrees"},"current":{"time":1728388800,"interval":900,"weather_code":61,"cloud_cover":75,"precipitation":3.5,"is_day":1,"wind_speed_10m":25.0,"wind_direction_10m":270.0},"daily_units":{"time":"unixtime","sunrise":"unixtime","sunset":"unixtime"},"daily":{"time":[1728302400],"sunrise":[1728325200],"sunset":[1728368400]}}
FIXTURE_EOF
}

write_clear_fixture() {
    local path="$1"
    cat > "$path" << 'FIXTURE_EOF'
{"latitude":37.77,"longitude":-122.42,"utc_offset_seconds":-25200,"timezone":"America/Los_Angeles","current_units":{"time":"unixtime","interval":"seconds","weather_code":"wmo code","cloud_cover":"%","precipitation":"mm","is_day":"","wind_speed_10m":"km/h","wind_direction_10m":"degrees"},"current":{"time":1728388800,"interval":900,"weather_code":0,"cloud_cover":0,"precipitation":0.0,"is_day":1,"wind_speed_10m":5.0,"wind_direction_10m":0.0},"daily_units":{"time":"unixtime","sunrise":"unixtime","sunset":"unixtime"},"daily":{"time":[1728302400],"sunrise":[1728325200],"sunset":[1728368400]}}
FIXTURE_EOF
}

# --- (a) ACTIVE: OW_L9W_TEST=1 -> active=true effect=registered, frames advance, pixels drawn ---
echo "[rain-check] running (a) ACTIVE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_L9W_TEST=1 \
  OW_L9W_INTENSITY=0.6 \
  OW_L9W_WINDSTR=0.4 \
  OW_L9W_WINDDIR=270.0 \
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

    rain_out=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins=$(printf '%s\n' "$rain_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    rain_win_count=$(printf '%s\n' "$rain_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ "$rain_win_count" -eq 0 ]]; then
        echo "[active] FAIL: no ONLYWALLPAPERS_RAIN lines"
        active_ok=0
    else
        echo "[active] RAIN lines found for $rain_win_count window(s)"
    fi

    if [[ "$rain_win_count" -ne "$win_count" ]]; then
        echo "[active] FAIL: rain lines from $rain_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
        active_ok=0
    fi

    while IFS= read -r wnum; do
        [[ -z "$wnum" ]] && continue
        win_rain=$(printf '%s\n' "$rain_out" | grep "win=${wnum} " | tail -1 || true)

        if ! printf '%s' "$win_rain" | grep -q 'active=true'; then
            echo "[active] FAIL: win=$wnum active!=true: $win_rain"
            active_ok=0
        else
            echo "[active] win=$wnum: active=true (ok)"
        fi

        if ! printf '%s' "$win_rain" | grep -q 'effect=registered'; then
            echo "[active] FAIL: win=$wnum effect!=registered: $win_rain"
            active_ok=0
        else
            echo "[active] win=$wnum: effect=registered (ok)"
        fi

        # Overlay frames advanced
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

        # Pixel sampling: ONLYWALLPAPERS_RAIN_STATS
        stats_line=$(grep "ONLYWALLPAPERS_RAIN_STATS.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$stats_line" ]]; then
            echo "[active] FAIL: win=$wnum no ONLYWALLPAPERS_RAIN_STATS line"
            active_ok=0
        elif printf '%s' "$stats_line" | grep -q 'unavailable'; then
            echo "[active] FAIL: win=$wnum RAIN_STATS unavailable"
            active_ok=0
        else
            rf=$(printf '%s' "$stats_line" | grep -oE 'frames=[0-9]+' | sed 's/frames=//' || echo "0")
            if [[ "$rf" -ge 3 ]]; then
                echo "[active] win=$wnum: rain frames=$rf (ok)"
            else
                echo "[active] FAIL: win=$wnum rain frames=$rf expected >=3"
                active_ok=0
            fi
            maxRA=$(printf '%s' "$stats_line" | grep -oE 'maxRenderedAlpha=[0-9]+' | sed 's/maxRenderedAlpha=//' || echo "0")
            if [[ "$maxRA" -gt 0 ]]; then
                echo "[active] win=$wnum: maxRenderedAlpha=$maxRA (ok, rain drew pixels)"
            else
                echo "[active] FAIL: win=$wnum maxRenderedAlpha=$maxRA (rain did not draw visible pixels)"
                active_ok=0
            fi
        fi

        # Pixel drawn check via ONLYWALLPAPERS_OVERLAY markerAlpha
        marker_alpha=$(printf '%s\n' "$overlay_lines" | grep -oE 'markerAlpha=[0-9]+' | tail -1 | sed 's/markerAlpha=//' || echo "")
        if [[ -n "$marker_alpha" && "$marker_alpha" -gt 0 ]]; then
            echo "[active] win=$wnum: markerAlpha=$marker_alpha (ok, overlay drawing)"
        fi

        # media=playing
        if grep -qE "ONLYWALLPAPERS_(WEB|FRAMING_MEDIA).*win=${wnum}.*media=playing" "$TMPOUT"; then
            echo "[active] win=$wnum: media=playing confirmed"
        else
            echo "[active] FAIL: win=$wnum media=playing not found"
            active_ok=0
        fi
    done <<< "$rain_wins"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $active_ok -eq 2 ]]; then
    echo "[rain-check] SKIP (a) ACTIVE"
    SKIP=$((SKIP+1))
elif [[ $active_ok -eq 1 ]]; then
    echo "[rain-check] PASS (a) ACTIVE"
    PASS=$((PASS+1))
else
    echo "[rain-check] FAIL (a) ACTIVE"
    FAIL=$((FAIL+1))
fi

# --- (b) INACTIVE: no OW_L9W_TEST, no rain weather -> active=false effect=none ---
echo "[rain-check] running (b) INACTIVE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_L9W_TEST \
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

    rain_out=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins=$(printf '%s\n' "$rain_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    rain_win_count=$(printf '%s\n' "$rain_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$rain_wins" ]]; then
        echo "[inactive] FAIL: no ONLYWALLPAPERS_RAIN lines"
        inert_ok=0
    else
        if [[ "$rain_win_count" -ne "$win_count" ]]; then
            echo "[inactive] FAIL: rain lines from $rain_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            inert_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_rain=$(printf '%s\n' "$rain_out" | grep "win=${wnum} " | tail -1 || true)
            if printf '%s' "$win_rain" | grep -q 'active=false'; then
                echo "[inactive] win=$wnum: active=false (ok)"
            else
                echo "[inactive] FAIL: win=$wnum active!=false: $win_rain"
                inert_ok=0
            fi
            if printf '%s' "$win_rain" | grep -q 'effect=none'; then
                echo "[inactive] win=$wnum: effect=none (ok)"
            else
                echo "[inactive] FAIL: win=$wnum effect!=none: $win_rain"
                inert_ok=0
            fi
        done <<< "$rain_wins"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $inert_ok -eq 2 ]]; then
    echo "[rain-check] SKIP (b) INACTIVE"
    SKIP=$((SKIP+1))
elif [[ $inert_ok -eq 1 ]]; then
    echo "[rain-check] PASS (b) INACTIVE"
    PASS=$((PASS+1))
else
    echo "[rain-check] FAIL (b) INACTIVE"
    FAIL=$((FAIL+1))
fi

# --- (c) RAIN-WEATHER fixture -> active=true effect=registered ---
echo "[rain-check] running (c) RAIN-WEATHER..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"
FIXTURE_FILE="$(mktemp)"
write_rain_fixture "$FIXTURE_FILE"
mkdir -p "$OW_SUPPORT_TMP"
printf '{"lat":37.77,"lon":-122.42}' > "$OW_SUPPORT_TMP/config.json"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_L9W_TEST \
  OW_MOOD_FAKE_RESPONSE_FILE="$FIXTURE_FILE" \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 8

win_count=$(get_win_count "$TMPOUT")
rain_wx_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[rain-weather] SKIP: 0 windows"
    rain_wx_ok=2
else
    WINDOW_VERIFIED=1
    rain_wx_ok=1
    rain_out=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins=$(printf '%s\n' "$rain_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    rain_win_count=$(printf '%s\n' "$rain_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$rain_wins" ]]; then
        echo "[rain-weather] FAIL: no ONLYWALLPAPERS_RAIN lines"
        rain_wx_ok=0
    else
        if [[ "$rain_win_count" -ne "$win_count" ]]; then
            echo "[rain-weather] FAIL: rain lines from $rain_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            rain_wx_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_rain=$(printf '%s\n' "$rain_out" | grep "win=${wnum} " | tail -1 || true)
            if printf '%s' "$win_rain" | grep -q 'active=true'; then
                echo "[rain-weather] win=$wnum: active=true (ok)"
            else
                echo "[rain-weather] FAIL: win=$wnum active!=true: $win_rain"
                rain_wx_ok=0
            fi
            if printf '%s' "$win_rain" | grep -q 'effect=registered'; then
                echo "[rain-weather] win=$wnum: effect=registered (ok)"
            else
                echo "[rain-weather] FAIL: win=$wnum effect!=registered: $win_rain"
                rain_wx_ok=0
            fi
        done <<< "$rain_wins"
    fi
fi

kill_app
rm -f "$TMPOUT" "$FIXTURE_FILE"; TMPOUT=""; FIXTURE_FILE=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $rain_wx_ok -eq 2 ]]; then
    echo "[rain-check] SKIP (c) RAIN-WEATHER"
    SKIP=$((SKIP+1))
elif [[ $rain_wx_ok -eq 1 ]]; then
    echo "[rain-check] PASS (c) RAIN-WEATHER"
    PASS=$((PASS+1))
else
    echo "[rain-check] FAIL (c) RAIN-WEATHER"
    FAIL=$((FAIL+1))
fi

# --- (d) NON-RAIN fixture -> active=false effect=none ---
echo "[rain-check] running (d) NON-RAIN..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"
FIXTURE_FILE="$(mktemp)"
write_clear_fixture "$FIXTURE_FILE"
mkdir -p "$OW_SUPPORT_TMP"
printf '{"lat":37.77,"lon":-122.42}' > "$OW_SUPPORT_TMP/config.json"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_L9W_TEST \
  OW_MOOD_FAKE_RESPONSE_FILE="$FIXTURE_FILE" \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
non_rain_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[non-rain] SKIP: 0 windows"
    non_rain_ok=2
else
    WINDOW_VERIFIED=1
    non_rain_ok=1
    rain_out=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins=$(printf '%s\n' "$rain_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    rain_win_count=$(printf '%s\n' "$rain_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$rain_wins" ]]; then
        echo "[non-rain] FAIL: no ONLYWALLPAPERS_RAIN lines"
        non_rain_ok=0
    else
        if [[ "$rain_win_count" -ne "$win_count" ]]; then
            echo "[non-rain] FAIL: rain lines from $rain_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            non_rain_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_rain=$(printf '%s\n' "$rain_out" | grep "win=${wnum} " | tail -1 || true)
            if printf '%s' "$win_rain" | grep -q 'active=false'; then
                echo "[non-rain] win=$wnum: active=false (ok)"
            else
                echo "[non-rain] FAIL: win=$wnum active!=false: $win_rain"
                non_rain_ok=0
            fi
            if printf '%s' "$win_rain" | grep -q 'effect=none'; then
                echo "[non-rain] win=$wnum: effect=none (ok)"
            else
                echo "[non-rain] FAIL: win=$wnum effect!=none: $win_rain"
                non_rain_ok=0
            fi
        done <<< "$rain_wins"
    fi
fi

kill_app
rm -f "$TMPOUT" "$FIXTURE_FILE"; TMPOUT=""; FIXTURE_FILE=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $non_rain_ok -eq 2 ]]; then
    echo "[rain-check] SKIP (d) NON-RAIN"
    SKIP=$((SKIP+1))
elif [[ $non_rain_ok -eq 1 ]]; then
    echo "[rain-check] PASS (d) NON-RAIN"
    PASS=$((PASS+1))
else
    echo "[rain-check] FAIL (d) NON-RAIN"
    FAIL=$((FAIL+1))
fi

# --- (e) WIND-DIRECTION: east vs west wind -> opposite-sign lastDrawnDx at actual draw site ---
echo "[rain-check] running (e) WIND-DIRECTION..."

# Sub-test: west wind -> positive renderedDx on ALL windows
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_L9W_TEST=1 \
  OW_L9W_INTENSITY=0.6 \
  OW_L9W_WINDSTR=0.8 \
  OW_L9W_WINDDIR=270.0 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 12

win_count_w=$(get_win_count "$TMPOUT")
west_ref_dx=""
west_per_win_ok=1
if [[ "$win_count_w" -gt 0 ]]; then
    WINDOW_VERIFIED=1
    rain_out_w=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins_w=$(printf '%s\n' "$rain_out_w" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    while IFS= read -r wnum; do
        [[ -z "$wnum" ]] && continue
        stats_line=$(grep "ONLYWALLPAPERS_RAIN_STATS.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$stats_line" ]]; then
            echo "[wind-dir] FAIL: win=$wnum no RAIN_STATS line (west)"
            west_per_win_ok=0; continue
        fi
        wdx=$(printf '%s' "$stats_line" | grep -oE 'renderedDx=-?[0-9.]+' | sed 's/renderedDx=//' || echo "")
        if [[ -z "$wdx" ]]; then
            echo "[wind-dir] FAIL: win=$wnum renderedDx missing in: $stats_line"
            west_per_win_ok=0; continue
        fi
        echo "[wind-dir] win=$wnum west (270): renderedDx=$wdx"
        if ! awk "BEGIN{exit !($wdx > 0.0)}" 2>/dev/null; then
            echo "[wind-dir] FAIL: win=$wnum west renderedDx=$wdx not > 0"
            west_per_win_ok=0
        fi
        [[ -z "$west_ref_dx" ]] && west_ref_dx="$wdx"
    done <<< "$rain_wins_w"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

# Sub-test: east wind -> negative renderedDx on ALL windows
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_L9W_TEST=1 \
  OW_L9W_INTENSITY=0.6 \
  OW_L9W_WINDSTR=0.8 \
  OW_L9W_WINDDIR=90.0 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 12

win_count_e=$(get_win_count "$TMPOUT")
east_per_win_ok=1
if [[ "$win_count_e" -gt 0 ]]; then
    WINDOW_VERIFIED=1
    rain_out_e=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins_e=$(printf '%s\n' "$rain_out_e" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    while IFS= read -r wnum; do
        [[ -z "$wnum" ]] && continue
        stats_line=$(grep "ONLYWALLPAPERS_RAIN_STATS.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$stats_line" ]]; then
            echo "[wind-dir] FAIL: win=$wnum no RAIN_STATS line (east)"
            east_per_win_ok=0; continue
        fi
        edx=$(printf '%s' "$stats_line" | grep -oE 'renderedDx=-?[0-9.]+' | sed 's/renderedDx=//' || echo "")
        if [[ -z "$edx" ]]; then
            echo "[wind-dir] FAIL: win=$wnum renderedDx missing in: $stats_line"
            east_per_win_ok=0; continue
        fi
        echo "[wind-dir] win=$wnum east (90): renderedDx=$edx"
        if ! awk "BEGIN{exit !($edx < 0.0)}" 2>/dev/null; then
            echo "[wind-dir] FAIL: win=$wnum east renderedDx=$edx not < 0"
            east_per_win_ok=0
        fi
    done <<< "$rain_wins_e"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

# Sub-test: near-zero wind -> |renderedDx| small (near-vertical)
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_L9W_TEST=1 \
  OW_L9W_INTENSITY=0.6 \
  OW_L9W_WINDSTR=0.03 \
  OW_L9W_WINDDIR=0.0 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 12

win_count_z=$(get_win_count "$TMPOUT")
nearzero_per_win_ok=1
if [[ "$win_count_z" -gt 0 ]]; then
    WINDOW_VERIFIED=1
    rain_out_z=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins_z=$(printf '%s\n' "$rain_out_z" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    while IFS= read -r wnum; do
        [[ -z "$wnum" ]] && continue
        stats_line=$(grep "ONLYWALLPAPERS_RAIN_STATS.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$stats_line" ]]; then
            echo "[wind-dir] FAIL: win=$wnum no RAIN_STATS line (near-zero)"
            nearzero_per_win_ok=0; continue
        fi
        zdx=$(printf '%s' "$stats_line" | grep -oE 'renderedDx=-?[0-9.]+' | sed 's/renderedDx=//' || echo "")
        if [[ -z "$zdx" ]]; then
            echo "[wind-dir] FAIL: win=$wnum renderedDx missing in: $stats_line"
            nearzero_per_win_ok=0; continue
        fi
        echo "[wind-dir] win=$wnum near-zero (0/0.03): renderedDx=$zdx"
        # near-zero wind: |dx| should be much smaller than the west-wind case
        # gust amplitude 0.10 vs wind strength 0.80 -> ratio 0.125; threshold 0.45 is conservative
        if [[ -n "$west_ref_dx" ]]; then
            threshold=$(awk "BEGIN{v=$west_ref_dx; if(v<0) v=-v; print v * 0.45}" 2>/dev/null || echo "")
            if [[ -n "$threshold" ]]; then
                abs_zdx=$(awk "BEGIN{v=$zdx; if(v<0) v=-v; print v}" 2>/dev/null || echo "9999")
                if awk "BEGIN{exit !($abs_zdx <= $threshold)}" 2>/dev/null; then
                    echo "[wind-dir] win=$wnum near-zero |renderedDx|=$abs_zdx <= threshold=$threshold (ok, near-vertical)"
                else
                    echo "[wind-dir] FAIL: win=$wnum near-zero |renderedDx|=$abs_zdx > threshold=$threshold (not near-vertical)"
                    nearzero_per_win_ok=0
                fi
            fi
        fi
    done <<< "$rain_wins_z"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

wind_ok=0
if [[ "$win_count_w" -eq 0 && "$win_count_e" -eq 0 && "$win_count_z" -eq 0 ]]; then
    echo "[wind-dir] SKIP: 0 windows"
    wind_ok=2
elif [[ "$west_per_win_ok" -eq 1 && "$east_per_win_ok" -eq 1 && "$nearzero_per_win_ok" -eq 1 ]]; then
    echo "[wind-dir] PASS: west renderedDx>0 (all windows), east renderedDx<0 (all windows), near-zero small (all windows)"
    wind_ok=1
else
    echo "[wind-dir] FAIL: west_ok=$west_per_win_ok east_ok=$east_per_win_ok nearzero_ok=$nearzero_per_win_ok"
    wind_ok=0
fi

if [[ $wind_ok -eq 2 ]]; then
    echo "[rain-check] SKIP (e) WIND-DIRECTION"
    SKIP=$((SKIP+1))
elif [[ $wind_ok -eq 1 ]]; then
    echo "[rain-check] PASS (e) WIND-DIRECTION"
    PASS=$((PASS+1))
else
    echo "[rain-check] FAIL (e) WIND-DIRECTION"
    FAIL=$((FAIL+1))
fi

# --- (f) REDUCED-MOTION: active rain suppressed ---
echo "[rain-check] running (f) REDUCED-MOTION..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_L9W_TEST=1 \
  OW_L9W_REDUCED_MOTION=1 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
rm_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[reduced-motion] SKIP: 0 windows"
    rm_ok=2
else
    WINDOW_VERIFIED=1
    rm_ok=1
    rain_out=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)
    rain_wins=$(printf '%s\n' "$rain_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    rain_win_count=$(printf '%s\n' "$rain_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ -z "$rain_wins" ]]; then
        echo "[reduced-motion] FAIL: no ONLYWALLPAPERS_RAIN lines"
        rm_ok=0
    else
        if [[ "$rain_win_count" -ne "$win_count" ]]; then
            echo "[reduced-motion] FAIL: rain lines from $rain_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
            rm_ok=0
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_rain=$(printf '%s\n' "$rain_out" | grep "win=${wnum} " | tail -1 || true)
            if printf '%s' "$win_rain" | grep -q 'active=true'; then
                echo "[reduced-motion] win=$wnum: active=true (ok, rain active)"
            else
                echo "[reduced-motion] FAIL: win=$wnum active!=true (rain should be active but suppressed): $win_rain"
                rm_ok=0
            fi
            if printf '%s' "$win_rain" | grep -q 'effect=none'; then
                echo "[reduced-motion] win=$wnum: effect=none (ok, rain suppressed)"
            else
                echo "[reduced-motion] FAIL: win=$wnum effect!=none (reduced motion should suppress rain): $win_rain"
                rm_ok=0
            fi
        done <<< "$rain_wins"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $rm_ok -eq 2 ]]; then
    echo "[rain-check] SKIP (f) REDUCED-MOTION"
    SKIP=$((SKIP+1))
elif [[ $rm_ok -eq 1 ]]; then
    echo "[rain-check] PASS (f) REDUCED-MOTION"
    PASS=$((PASS+1))
else
    echo "[rain-check] FAIL (f) REDUCED-MOTION"
    FAIL=$((FAIL+1))
fi

# --- (g) COEXISTENCE: OW_WGT_TEST=1 + OW_L9W_TEST=1 -> EVERY window has both lightning AND rain registered + both drew pixels ---
echo "[rain-check] running (g) COEXISTENCE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_WGT_TEST=1 \
  OW_L9W_TEST=1 \
  OW_L9W_INTENSITY=0.6 \
  OW_L9W_WINDSTR=0.4 \
  OW_L9W_WINDDIR=270.0 \
  OW_OVERLAY_TEST=1 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 14

win_count=$(get_win_count "$TMPOUT")
coex_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[coexistence] SKIP: 0 windows (genuine headless)"
    coex_ok=2
else
    WINDOW_VERIFIED=1
    coex_ok=1

    # Collect all lines we need
    storm_out=$(grep 'ONLYWALLPAPERS_STORM ' "$TMPOUT" | grep -v STORM_PIXEL || true)
    rain_out=$(grep 'ONLYWALLPAPERS_RAIN ' "$TMPOUT" | grep -v RAIN_STATS || true)

    # Get the window numbers reported by WINDOWS line
    # We assert against ALL win_count windows (not just storm_wins)
    # Use rain lines to find actual window numbers, fall back to sequential numbering
    rain_wins_all=$(printf '%s\n' "$rain_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    storm_wins_all=$(printf '%s\n' "$storm_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)

    # Combine all window numbers seen from either effect
    all_wins=$(printf '%s\n%s\n' "$rain_wins_all" "$storm_wins_all" | sort -u | grep -v '^$' || true)
    all_win_count=$(printf '%s\n' "$all_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ "$all_win_count" -ne "$win_count" ]]; then
        echo "[coexistence] FAIL: effects seen on $all_win_count window(s) but ONLYWALLPAPERS_WINDOWS=$win_count"
        coex_ok=0
    fi

    while IFS= read -r wnum; do
        [[ -z "$wnum" ]] && continue

        # Check lightning registered
        win_storm=$(printf '%s\n' "$storm_out" | grep "win=${wnum} " | tail -1 || true)
        if printf '%s' "$win_storm" | grep -q 'effect=registered'; then
            echo "[coexistence] win=$wnum: lightning registered (ok)"
        else
            echo "[coexistence] FAIL: win=$wnum lightning not registered: $win_storm"
            coex_ok=0
        fi

        # Check rain registered
        win_rain=$(printf '%s\n' "$rain_out" | grep "win=${wnum} " | tail -1 || true)
        if printf '%s' "$win_rain" | grep -q 'effect=registered'; then
            echo "[coexistence] win=$wnum: rain registered (ok)"
        else
            echo "[coexistence] FAIL: win=$wnum rain not registered: $win_rain"
            coex_ok=0
        fi

        # Check lightning drew pixels in the same launch
        storm_pixel=$(grep "ONLYWALLPAPERS_STORM_PIXEL.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$storm_pixel" ]]; then
            echo "[coexistence] FAIL: win=$wnum no STORM_PIXEL line (lightning pixel proof missing)"
            coex_ok=0
        else
            maxA=$(printf '%s' "$storm_pixel" | grep -oE 'maxRenderedAlpha=[0-9]+' | sed 's/maxRenderedAlpha=//' || echo "0")
            if [[ "$maxA" -gt 0 ]]; then
                echo "[coexistence] win=$wnum: lightning maxRenderedAlpha=$maxA (ok)"
            else
                echo "[coexistence] FAIL: win=$wnum lightning maxRenderedAlpha=0 (lightning did not draw pixels)"
                coex_ok=0
            fi
        fi

        # Check rain drew pixels in the same launch
        rain_stats=$(grep "ONLYWALLPAPERS_RAIN_STATS.*win=${wnum} " "$TMPOUT" | tail -1 || true)
        if [[ -z "$rain_stats" ]]; then
            echo "[coexistence] FAIL: win=$wnum no RAIN_STATS line (rain pixel proof missing)"
            coex_ok=0
        else
            rainMaxA=$(printf '%s' "$rain_stats" | grep -oE 'maxRenderedAlpha=[0-9]+' | sed 's/maxRenderedAlpha=//' || echo "0")
            if [[ "$rainMaxA" -gt 0 ]]; then
                echo "[coexistence] win=$wnum: rain maxRenderedAlpha=$rainMaxA (ok)"
            else
                echo "[coexistence] FAIL: win=$wnum rain maxRenderedAlpha=0 (rain did not draw pixels)"
                coex_ok=0
            fi
        fi
    done <<< "$all_wins"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $coex_ok -eq 2 ]]; then
    echo "[rain-check] SKIP (g) COEXISTENCE"
    SKIP=$((SKIP+1))
elif [[ $coex_ok -eq 1 ]]; then
    echo "[rain-check] PASS (g) COEXISTENCE"
    PASS=$((PASS+1))
else
    echo "[rain-check] FAIL (g) COEXISTENCE"
    FAIL=$((FAIL+1))
fi

echo ""
if [[ $WINDOW_VERIFIED -eq 0 && $SKIP -gt 0 ]]; then
    echo "[rain-check] ALL-SKIPPED: no integration sub-check verified windows (PASS=$PASS FAIL=$FAIL SKIP=$SKIP)"
    exit 1
fi
echo "[rain-check] Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
