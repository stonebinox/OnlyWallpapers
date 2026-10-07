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

echo "[mood-check] building..."
swift build -c release 2>&1 | tail -5
BINARY="$(swift build -c release --show-bin-path 2>/dev/null)/OnlyWallpapers"

# --- STATIC: style.css #bg must declare a filter transition with positive duration ---
echo "[mood-check] checking static CSS transition..."
CSS_FILE="$REPO_ROOT/Sources/OnlyWallpapers/web/style.css"
CSS_TRANS_OK=0
if [[ ! -f "$CSS_FILE" ]]; then
    echo "[static-css] FAIL: style.css not found at $CSS_FILE"
else
    # Extract the #bg rule and look for transition: filter <dur>
    # The rule is on one line in style.css. Match: transition: filter <positive-duration>
    if grep -qE '#bg\b[^}]*\btransition:[^}]*\bfilter\b' "$CSS_FILE"; then
        # Extract the duration value from the transition property
        trans_dur=$(grep -oE 'transition:[^;]+' "$CSS_FILE" | grep 'filter' | grep -oE '[0-9]+(\.[0-9]+)?s' | head -1)
        if [[ -n "$trans_dur" ]]; then
            # Parse duration: strip trailing 's' and check > 0
            dur_val=$(printf '%s' "$trans_dur" | sed 's/s$//')
            ok=$(awk "BEGIN{print($dur_val>0)?1:0}")
            if [[ "$ok" == "1" ]]; then
                echo "[static-css] #bg filter transition present, duration=$trans_dur (positive)"
                CSS_TRANS_OK=1
            else
                echo "[static-css] FAIL: #bg filter transition duration not positive: $trans_dur"
            fi
        else
            echo "[static-css] FAIL: could not parse duration from #bg filter transition"
        fi
    else
        echo "[static-css] FAIL: #bg rule does not declare a filter transition"
    fi
fi

PASS=0
FAIL=0
SKIP=0
WINDOW_VERIFIED=0  # set to 1 when any integration sub-check (a/b/c/d) finds actual windows

if [[ $CSS_TRANS_OK -eq 1 ]]; then
    echo "[mood-check] PASS static-css-transition"
    PASS=$((PASS+1))
else
    echo "[mood-check] FAIL static-css-transition"
    FAIL=$((FAIL+1))
fi

launch_mood() {
    local support_dir="$1"
    local extra_env="${2:-}"
    if [[ -n "$extra_env" ]]; then
        env $extra_env OW_APP_SUPPORT_DIR="$support_dir" OW_MOOD_TEST=1 WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" "$BINARY" > "$TMPOUT" 2>&1 &
    else
        OW_APP_SUPPORT_DIR="$support_dir" OW_MOOD_TEST=1 WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" "$BINARY" > "$TMPOUT" 2>&1 &
    fi
    PID=$!
}

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

mood_lines() {
    grep 'ONLYWALLPAPERS_MOOD win=' "$1" || true
}

mood_applied_lines() {
    grep 'ONLYWALLPAPERS_MOOD_APPLIED win=' "$1" || true
}

# --- (a) HOOK: OW_MOOD_TEST=1 produces mood=hook, no network, ONLYWALLPAPERS_MOOD lines per window ---
echo "[mood-check] running (a) HOOK..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"
launch_mood "$OW_SUPPORT_TMP"
sleep 6

win_count=$(get_win_count "$TMPOUT")
hook_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[hook] SKIP: 0 windows (genuine headless)"
    hook_ok=2
else
    WINDOW_VERIFIED=1
    # Verify mood=hook log line present.
    if ! grep -q 'ONLYWALLPAPERS_MOOD mood=hook' "$TMPOUT"; then
        echo "[hook] FAIL: ONLYWALLPAPERS_MOOD mood=hook line not found"
    else
        echo "[hook] mood=hook confirmed"
        hook_ok=1
    fi

    # Verify zero api.open-meteo.com references in output.
    if grep -q 'api.open-meteo.com' "$TMPOUT"; then
        echo "[hook] FAIL: api.open-meteo.com appeared in output (network call in hook mode)"
        hook_ok=0
    else
        echo "[hook] no api.open-meteo.com in output (correct)"
    fi

    # Collect MOOD win= lines.
    mood_out=$(mood_lines "$TMPOUT")
    # FIX 4c: avoid bash double-zero bug with grep -c + || echo 0
    mood_count=$(printf '%s\n' "$mood_out" | grep -c . || true); mood_count=${mood_count:-0}

    if [[ $hook_ok -eq 1 ]]; then
        if [[ $mood_count -eq 0 ]]; then
            echo "[hook] FAIL: no ONLYWALLPAPERS_MOOD win= lines found"
            hook_ok=0
        else
            # All windows must appear.
            mood_wins=$(printf '%s\n' "$mood_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
            mood_win_count=$(printf '%s\n' "$mood_wins" | grep -c . || true); mood_win_count=${mood_win_count:-0}
            if [[ $mood_win_count -ne $win_count ]]; then
                echo "[hook] FAIL: MOOD win= count=$mood_win_count != win_count=$win_count"
                hook_ok=0
            else
                echo "[hook] MOOD lines for all $win_count window(s) present"
            fi

            # All filter strings must be identical across windows.
            unique_filters=$(printf '%s\n' "$mood_out" | grep ' filter=' | sed 's/.*filter=//;' | sort -u | grep -c . || true); unique_filters=${unique_filters:-0}
            if [[ $unique_filters -ne 1 ]]; then
                echo "[hook] FAIL: filter strings not identical across windows (unique=$unique_filters)"
                hook_ok=0
            else
                filter_val=$(printf '%s\n' "$mood_out" | head -1 | sed 's/.*filter=//')
                echo "[hook] filter identical across all windows: $filter_val"
            fi

            # Filter string must match the 5-function pattern.
            filter_val=$(printf '%s\n' "$mood_out" | head -1 | sed 's/.*filter=//')
            if ! printf '%s\n' "$filter_val" | grep -qE '^brightness\([0-9.]+\) saturate\([0-9.]+\) contrast\([0-9.]+\) hue-rotate\(-?[0-9.]+deg\) sepia\([0-9.]+\)$'; then
                echo "[hook] FAIL: filter does not match 5-function pattern: $filter_val"
                hook_ok=0
            else
                echo "[hook] filter format valid"
            fi
        fi
    fi

    # FIX 4b: DOM readback assertion for test (a) HOOK.
    if [[ $hook_ok -eq 1 ]]; then
        applied_out=$(mood_applied_lines "$TMPOUT")
        applied_count=$(printf '%s\n' "$applied_out" | grep -c . || true); applied_count=${applied_count:-0}
        if [[ $applied_count -eq 0 ]]; then
            echo "[hook] FAIL: no ONLYWALLPAPERS_MOOD_APPLIED win= lines found (DOM readback missing)"
            hook_ok=0
        else
            applied_wins=$(printf '%s\n' "$applied_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
            applied_win_count=$(printf '%s\n' "$applied_wins" | grep -c . || true); applied_win_count=${applied_win_count:-0}
            if [[ $applied_win_count -ne $win_count ]]; then
                echo "[hook] FAIL: MOOD_APPLIED distinct win= count=$applied_win_count != win_count=$win_count"
                hook_ok=0
            else
                echo "[hook] MOOD_APPLIED DOM readback confirmed for all $win_count window(s)"
            fi
            # Parse B/S/C/H/Se from inline= CSS filter for every window; all must be identical.
            hook_tuple_ok=1
            ref_B=""; ref_S=""; ref_C=""; ref_H=""; ref_Se=""
            while IFS= read -r aline; do
                [[ -z "$aline" ]] && continue
                af_inline=$(printf '%s\n' "$aline" | sed 's/.*inline=//')
                if [[ -z "$af_inline" ]]; then
                    echo "[hook] FAIL: inline= field missing in MOOD_APPLIED line: $aline"
                    hook_tuple_ok=0; continue
                fi
                af_B=$(printf '%s\n' "$af_inline" | grep -oE 'brightness\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_S=$(printf '%s\n' "$af_inline" | grep -oE 'saturate\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_C=$(printf '%s\n' "$af_inline" | grep -oE 'contrast\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_H=$(printf '%s\n' "$af_inline" | grep -oE 'hue-rotate\(-?[0-9.]+deg\)' | sed 's/hue-rotate(//;s/deg)//' || echo "")
                af_Se=$(printf '%s\n' "$af_inline" | grep -oE 'sepia\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                if [[ -z "$af_B" || -z "$af_S" || -z "$af_C" || -z "$af_H" || -z "$af_Se" ]]; then
                    echo "[hook] FAIL: could not parse all inline filter components: '$af_inline'"
                    hook_tuple_ok=0; continue
                fi
                if [[ -z "$ref_B" ]]; then
                    ref_B="$af_B"; ref_S="$af_S"; ref_C="$af_C"; ref_H="$af_H"; ref_Se="$af_Se"
                else
                    if [[ "$af_B" != "$ref_B" || "$af_S" != "$ref_S" || "$af_C" != "$ref_C" || "$af_H" != "$ref_H" || "$af_Se" != "$ref_Se" ]]; then
                        echo "[hook] FAIL: inline tuple mismatch across windows: B=$af_B S=$af_S C=$af_C H=$af_H Se=$af_Se vs ref B=$ref_B S=$ref_S C=$ref_C H=$ref_H Se=$ref_Se"
                        hook_tuple_ok=0
                    fi
                fi
            done <<< "$applied_out"
            if [[ $hook_tuple_ok -eq 1 ]]; then
                echo "[hook] MOOD_APPLIED inline B/S/C/H/Se tuple identical across all windows: B=$ref_B S=$ref_S C=$ref_C H=$ref_H Se=$ref_Se"
            else
                hook_ok=0
            fi
        fi
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $hook_ok -eq 2 ]]; then
    echo "[mood-check] SKIP (a) HOOK"
    SKIP=$((SKIP+1))
elif [[ $hook_ok -eq 1 ]]; then
    echo "[mood-check] PASS (a) HOOK"
    PASS=$((PASS+1))
else
    echo "[mood-check] FAIL (a) HOOK"
    FAIL=$((FAIL+1))
fi

# --- (b) BROADCAST: SIGUSR2 in hook mode re-applies mood to all windows ---
echo "[mood-check] running (b) BROADCAST..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"
launch_mood "$OW_SUPPORT_TMP"
sleep 6

win_count=$(get_win_count "$TMPOUT")
bcast_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[broadcast] SKIP: 0 windows (genuine headless)"
    bcast_ok=2
else
    WINDOW_VERIFIED=1
    pre_lines=$(wc -l < "$TMPOUT" | tr -d ' ')

    kill -USR2 "$PID" 2>/dev/null || true
    sleep 3

    total_lines=$(wc -l < "$TMPOUT" | tr -d ' ')
    added=$((total_lines - pre_lines))
    if [[ $added -gt 0 ]]; then
        post_output=$(tail -n "$added" "$TMPOUT")
    else
        post_output=""
    fi

    post_mood=$(printf '%s\n' "$post_output" | grep 'ONLYWALLPAPERS_MOOD win=' || true)
    # FIX 4c: avoid bash double-zero bug
    post_count=$(printf '%s\n' "$post_mood" | grep -c . || true); post_count=${post_count:-0}

    if [[ $post_count -eq 0 ]]; then
        echo "[broadcast] FAIL: no MOOD win= lines after SIGUSR2 broadcast"
    else
        bcast_ok=1
        post_wins=$(printf '%s\n' "$post_mood" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
        post_win_count=$(printf '%s\n' "$post_wins" | grep -c . || true); post_win_count=${post_win_count:-0}
        if [[ $post_win_count -ne $win_count ]]; then
            echo "[broadcast] FAIL: post-broadcast MOOD win= count=$post_win_count != win_count=$win_count"
            bcast_ok=0
        else
            echo "[broadcast] post-broadcast MOOD lines for all $win_count window(s)"
        fi

        unique_filters=$(printf '%s\n' "$post_mood" | grep ' filter=' | sed 's/.*filter=//;' | sort -u | grep -c . || true); unique_filters=${unique_filters:-0}
        if [[ $unique_filters -ne 1 ]]; then
            echo "[broadcast] FAIL: post-broadcast filter not identical across windows"
            bcast_ok=0
        else
            echo "[broadcast] post-broadcast filter identical across all windows"
        fi

        # DOM readback for test (b) BROADCAST: require all windows to report.
        if [[ $bcast_ok -eq 1 ]]; then
            post_applied=$(printf '%s\n' "$post_output" | grep 'ONLYWALLPAPERS_MOOD_APPLIED win=' || true)
            post_applied_count=$(printf '%s\n' "$post_applied" | grep -c . || true); post_applied_count=${post_applied_count:-0}
            if [[ $post_applied_count -eq 0 ]]; then
                echo "[broadcast] FAIL: no MOOD_APPLIED lines after SIGUSR2 (DOM readback missing)"
                bcast_ok=0
            else
                post_applied_wins=$(printf '%s\n' "$post_applied" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
                post_applied_win_count=$(printf '%s\n' "$post_applied_wins" | grep -c . || true); post_applied_win_count=${post_applied_win_count:-0}
                if [[ $post_applied_win_count -ne $win_count ]]; then
                    echo "[broadcast] FAIL: MOOD_APPLIED distinct win= count=$post_applied_win_count != win_count=$win_count"
                    bcast_ok=0
                else
                    echo "[broadcast] MOOD_APPLIED DOM readback confirmed for all $win_count window(s)"
                fi
            fi
        fi
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $bcast_ok -eq 2 ]]; then
    echo "[mood-check] SKIP (b) BROADCAST"
    SKIP=$((SKIP+1))
elif [[ $bcast_ok -eq 1 ]]; then
    echo "[mood-check] PASS (b) BROADCAST"
    PASS=$((PASS+1))
else
    echo "[mood-check] FAIL (b) BROADCAST"
    FAIL=$((FAIL+1))
fi

# --- (c) WEATHER_FIXTURE: OW_MOOD_WEATHER_JSON exercises parse+map with no network ---
echo "[mood-check] running (c) WEATHER_FIXTURE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

# Known storm fixture: nighttime heavy cloud + storm code -> muted filter expected.
FIXTURE='{"current":{"weather_code":95,"cloud_cover":100,"precipitation":5.0,"is_day":0,"time":1728345600},"daily":{"sunrise":[1728367200],"sunset":[1728410400]}}'

OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" OW_MOOD_TEST=1 OW_MOOD_WEATHER_JSON="$FIXTURE" WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
fixture_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[fixture] SKIP: 0 windows (genuine headless)"
    fixture_ok=2
else
    WINDOW_VERIFIED=1
    if grep -q 'ONLYWALLPAPERS_MOOD mood=hook weather=fixture' "$TMPOUT"; then
        echo "[fixture] weather=fixture confirmed"
        fixture_ok=1
    else
        echo "[fixture] FAIL: weather=fixture log line not found"
    fi

    if [[ $fixture_ok -eq 1 ]]; then
        mood_out=$(mood_lines "$TMPOUT")
        if [[ -z "$mood_out" ]]; then
            echo "[fixture] FAIL: no MOOD win= lines"
            fixture_ok=0
        else
            # FIX 4c: avoid bash double-zero bug
            unique_filters=$(printf '%s\n' "$mood_out" | sed 's/.*filter=//;' | sort -u | grep -c . || true); unique_filters=${unique_filters:-0}
            if [[ $unique_filters -ne 1 ]]; then
                echo "[fixture] FAIL: filter not identical across windows"
                fixture_ok=0
            else
                filter_val=$(printf '%s\n' "$mood_out" | head -1 | sed 's/.*filter=//')
                echo "[fixture] fixture filter: $filter_val"
            fi
        fi
    fi

    # FIX 4b: DOM readback for test (c) WEATHER_FIXTURE.
    if [[ $fixture_ok -eq 1 ]]; then
        applied_out=$(mood_applied_lines "$TMPOUT")
        applied_count=$(printf '%s\n' "$applied_out" | grep -c . || true); applied_count=${applied_count:-0}
        if [[ $applied_count -eq 0 ]]; then
            echo "[fixture] FAIL: no MOOD_APPLIED lines found (DOM readback missing)"
            fixture_ok=0
        else
            applied_wins=$(printf '%s\n' "$applied_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
            applied_win_count=$(printf '%s\n' "$applied_wins" | grep -c . || true); applied_win_count=${applied_win_count:-0}
            if [[ $applied_win_count -ne $win_count ]]; then
                echo "[fixture] FAIL: MOOD_APPLIED distinct win= count=$applied_win_count != win_count=$win_count"
                fixture_ok=0
            else
                echo "[fixture] MOOD_APPLIED DOM readback confirmed for all $win_count window(s)"
            fi
            # Assert inline filter in first MOOD_APPLIED line is non-empty and matches 5-function pattern.
            applied_first=$(printf '%s\n' "$applied_out" | head -1)
            inline_filter=$(printf '%s\n' "$applied_first" | sed 's/.*inline=//')
            if [[ -z "$inline_filter" ]]; then
                echo "[fixture] FAIL: inline= field missing in MOOD_APPLIED line"
                fixture_ok=0
            else
                MOOD_RE='^brightness\([0-9.]+\) saturate\([0-9.]+\) contrast\([0-9.]+\) hue-rotate\(-?[0-9.]+deg\) sepia\([0-9.]+\)$'
                if ! printf '%s\n' "$inline_filter" | grep -qE "$MOOD_RE"; then
                    echo "[fixture] FAIL: inline filter does not match 5-function pattern: '$inline_filter'"
                    fixture_ok=0
                else
                    echo "[fixture] inline filter non-empty and format valid: $inline_filter"
                fi
            fi
            # Assert exact storm tuple by parsing from inline= DOM filter for EVERY window.
            # Night + storm(95) + cloud=100 + precip=5: B=0.72 S=0.55 C=1.05 H=-8 Se=0.
            tuple_ok=1
            while IFS= read -r aline; do
                [[ -z "$aline" ]] && continue
                af_inline=$(printf '%s\n' "$aline" | sed 's/.*inline=//')
                if [[ -z "$af_inline" ]]; then
                    echo "[fixture] FAIL: inline= field missing in MOOD_APPLIED line: $aline"
                    tuple_ok=0; continue
                fi
                af_B=$(printf '%s\n' "$af_inline" | grep -oE 'brightness\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_S=$(printf '%s\n' "$af_inline" | grep -oE 'saturate\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_C=$(printf '%s\n' "$af_inline" | grep -oE 'contrast\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_H=$(printf '%s\n' "$af_inline" | grep -oE 'hue-rotate\(-?[0-9.]+deg\)' | sed 's/hue-rotate(//;s/deg)//' || echo "")
                af_Se=$(printf '%s\n' "$af_inline" | grep -oE 'sepia\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                if [[ -z "$af_B" || -z "$af_S" || -z "$af_C" || -z "$af_H" || -z "$af_Se" ]]; then
                    echo "[fixture] FAIL: could not parse inline filter components: '$af_inline'"
                    tuple_ok=0; continue
                fi
                ok=$(awk "BEGIN{b=($af_B>0.7195&&$af_B<0.7205);s=($af_S>0.5495&&$af_S<0.5505);c=($af_C>1.049&&$af_C<1.051);h=($af_H>-8.001&&$af_H<-7.999);se=($af_Se>=-0.001&&$af_Se<0.001);print(b&&s&&c&&h&&se)?1:0}")
                if [[ "$ok" != "1" ]]; then
                    echo "[fixture] FAIL: inline storm tuple mismatch: B=$af_B S=$af_S C=$af_C H=$af_H Se=$af_Se (expected B~0.72 S~0.55 C~1.05 H~-8 Se~0)"
                    tuple_ok=0
                fi
            done <<< "$applied_out"
            if [[ $tuple_ok -eq 1 ]]; then
                echo "[fixture] exact storm tuple verified from inline= for all $applied_win_count window(s)"
            else
                fixture_ok=0
            fi
        fi
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $fixture_ok -eq 2 ]]; then
    echo "[mood-check] SKIP (c) WEATHER_FIXTURE"
    SKIP=$((SKIP+1))
elif [[ $fixture_ok -eq 1 ]]; then
    echo "[mood-check] PASS (c) WEATHER_FIXTURE"
    PASS=$((PASS+1))
else
    echo "[mood-check] FAIL (c) WEATHER_FIXTURE"
    FAIL=$((FAIL+1))
fi

# --- (d) PRODUCTION-FETCH: normal-mode fetch path with OW_MOOD_FAKE_RESPONSE_FILE ---
echo "[mood-check] running (d) PRODUCTION-FETCH..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

# Write a config.json with lat/lon so effectiveLatLon() finds coords without CoreLocation.
LAT_VAL=37.78
LON_VAL=-122.42
printf '{"lat":%s,"lon":%s}' "$LAT_VAL" "$LON_VAL" > "$OW_SUPPORT_TMP/config.json"

# Write the storm fixture to a temp file.
FIXTURE_FILE="$(mktemp)"
printf '%s' '{"current":{"weather_code":95,"cloud_cover":100,"precipitation":5.0,"is_day":0,"time":1728345600},"daily":{"sunrise":[1728367200],"sunset":[1728410400]}}' > "$FIXTURE_FILE"

# Launch WITHOUT OW_MOOD_TEST (normal/noPlist mode) but with OW_MOOD_FAKE_RESPONSE_FILE.
# Unset any ambient OW_MOOD_TEST / OW_MOOD_WEATHER_JSON so hook mode cannot activate.
env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  OW_MOOD_FAKE_RESPONSE_FILE="$FIXTURE_FILE" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!

# Wait long enough for: page load + fetch + mood apply + transition readback (0.5s delay).
sleep 10

win_count=$(get_win_count "$TMPOUT")
prodfetch_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[prodfetch] SKIP: 0 windows (genuine headless)"
    prodfetch_ok=2
else
    WINDOW_VERIFIED=1
    prodfetch_ok=1

    # Assert: fetch url= log line present with rounded coords and timeformat=unixtime.
    fetch_url_line=$(grep 'ONLYWALLPAPERS_MOOD.*fetch url=' "$TMPOUT" | head -1 || true)
    if [[ -z "$fetch_url_line" ]]; then
        echo "[prodfetch] FAIL: no 'fetch url=' log line found"
        prodfetch_ok=0
    else
        echo "[prodfetch] fetch url line: $fetch_url_line"
        if ! printf '%s' "$fetch_url_line" | grep -q 'timeformat=unixtime'; then
            echo "[prodfetch] FAIL: fetch url missing timeformat=unixtime"
            prodfetch_ok=0
        else
            echo "[prodfetch] timeformat=unixtime present in url"
        fi
        # Check rounded coords (2dp): lat=37.78 and lon=-122.42
        if ! printf '%s' "$fetch_url_line" | grep -qE 'latitude=37\.7[0-9]'; then
            echo "[prodfetch] FAIL: fetch url missing expected latitude (rounded 2dp)"
            prodfetch_ok=0
        else
            echo "[prodfetch] latitude rounded coords present"
        fi
        if ! printf '%s' "$fetch_url_line" | grep -qE 'longitude=-122\.4[0-9]'; then
            echo "[prodfetch] FAIL: fetch url missing expected longitude (rounded 2dp)"
            prodfetch_ok=0
        else
            echo "[prodfetch] longitude rounded coords present"
        fi
    fi

    # Assert: weather=ok log line present (fake response parsed successfully).
    if ! grep -q 'ONLYWALLPAPERS_MOOD.*weather=ok' "$TMPOUT"; then
        echo "[prodfetch] FAIL: weather=ok not found (fake response not parsed)"
        prodfetch_ok=0
    else
        echo "[prodfetch] weather=ok confirmed (fake response parsed)"
    fi

    # Assert: weatherCache written into config.json.
    if ! grep -q '"weatherCache"' "$OW_SUPPORT_TMP/config.json" 2>/dev/null; then
        echo "[prodfetch] FAIL: weatherCache not written to config.json"
        prodfetch_ok=0
    else
        echo "[prodfetch] weatherCache written to config.json"
    fi

    # Assert: MOOD_APPLIED inline filter matches storm muted tuple for all windows.
    if [[ $prodfetch_ok -eq 1 ]]; then
        applied_out=$(mood_applied_lines "$TMPOUT")
        applied_count=$(printf '%s\n' "$applied_out" | grep -c . || true); applied_count=${applied_count:-0}
        if [[ $applied_count -eq 0 ]]; then
            echo "[prodfetch] FAIL: no MOOD_APPLIED lines (DOM readback missing)"
            prodfetch_ok=0
        else
            applied_wins=$(printf '%s\n' "$applied_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
            applied_win_count=$(printf '%s\n' "$applied_wins" | grep -c . || true); applied_win_count=${applied_win_count:-0}
            if [[ $applied_win_count -ne $win_count ]]; then
                echo "[prodfetch] FAIL: MOOD_APPLIED distinct win= count=$applied_win_count != win_count=$win_count"
                prodfetch_ok=0
            else
                echo "[prodfetch] MOOD_APPLIED DOM readback confirmed for all $win_count window(s)"
            fi

            # Storm tuple check: assert only the FINAL MOOD_APPLIED line per window matches storm bounds.
            # The app emits an initial time-only mood before the async fake fetch resolves; an earlier
            # line for the same window with a different tuple is tolerated. Only the last one counts.
            # Fixture: cloud=100, precip=5.0, weather_code=95. Sun epochs are stale (2024); today 06:00/18:00 synthesized.
            # New offsets: B in [0.72,0.82] (night-floor to near-noon), S in [0.55,0.59], hue=-8.
            tuple_ok=1
            while IFS= read -r wnum; do
                [[ -z "$wnum" ]] && continue
                # Take the LAST MOOD_APPLIED line for this window (post-fetch value).
                last_aline=$(printf '%s\n' "$applied_out" | grep "win=${wnum} " | tail -1)
                if [[ -z "$last_aline" ]]; then
                    echo "[prodfetch] FAIL: no final MOOD_APPLIED line for window $wnum"
                    tuple_ok=0; continue
                fi
                af_inline=$(printf '%s\n' "$last_aline" | sed 's/.*inline=//')
                if [[ -z "$af_inline" ]]; then
                    echo "[prodfetch] FAIL: inline= field missing in final MOOD_APPLIED line for win=$wnum: $last_aline"
                    tuple_ok=0; continue
                fi
                af_B=$(printf '%s\n' "$af_inline" | grep -oE 'brightness\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_S=$(printf '%s\n' "$af_inline" | grep -oE 'saturate\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_C=$(printf '%s\n' "$af_inline" | grep -oE 'contrast\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                af_H=$(printf '%s\n' "$af_inline" | grep -oE 'hue-rotate\(-?[0-9.]+deg\)' | sed 's/hue-rotate(//;s/deg)//' || echo "")
                af_Se=$(printf '%s\n' "$af_inline" | grep -oE 'sepia\([0-9.]+\)' | grep -oE '[0-9.]+' || echo "")
                if [[ -z "$af_B" || -z "$af_S" || -z "$af_C" || -z "$af_H" || -z "$af_Se" ]]; then
                    echo "[prodfetch] FAIL: could not parse inline filter components for win=$wnum: '$af_inline'"
                    tuple_ok=0; continue
                fi
                ok=$(awk "BEGIN{b=($af_B>=0.719&&$af_B<=0.821);s=($af_S>=0.549&&$af_S<=0.591);c=($af_C>1.049&&$af_C<1.051);h=($af_H>-8.001&&$af_H<-7.999);se=($af_Se>=-0.001&&$af_Se<=0.082);print(b&&s&&c&&h&&se)?1:0}")
                if [[ "$ok" != "1" ]]; then
                    echo "[prodfetch] FAIL: storm tuple check for win=$wnum: B=$af_B S=$af_S C=$af_C H=$af_H Se=$af_Se (need B in [0.719,0.821] S in [0.549,0.591] C~1.05 H~-8 Se in [0,0.082])"
                    tuple_ok=0
                fi
            done <<< "$applied_wins"
            if [[ $tuple_ok -eq 1 ]]; then
                echo "[prodfetch] storm tuple verified from final inline= for all $applied_win_count window(s)"
            else
                prodfetch_ok=0
            fi
        fi
    fi

    # Assert: MOOD_TRANSITION log lines present with filter in transitionProperty and duration > 0.
    if [[ $prodfetch_ok -eq 1 ]]; then
        trans_out=$(grep 'ONLYWALLPAPERS_MOOD_TRANSITION' "$TMPOUT" || true)
        trans_count=$(printf '%s\n' "$trans_out" | grep -c . || true); trans_count=${trans_count:-0}
        if [[ $trans_count -eq 0 ]]; then
            echo "[prodfetch] FAIL: no MOOD_TRANSITION log lines found (transition readback missing)"
            prodfetch_ok=0
        else
            trans_ok=1
            while IFS= read -r tline; do
                [[ -z "$tline" ]] && continue
                tp=$(printf '%s' "$tline" | grep -oE 'transitionProperty=[^ ]+' | sed 's/transitionProperty=//' || echo "")
                td=$(printf '%s' "$tline" | grep -oE 'transitionDuration=[^ ]+' | sed 's/transitionDuration=//' || echo "")
                if [[ -z "$tp" || -z "$td" ]]; then
                    echo "[prodfetch] FAIL: could not parse transitionProperty/transitionDuration from: $tline"
                    trans_ok=0; continue
                fi
                if ! printf '%s' "$tp" | grep -qi 'filter'; then
                    echo "[prodfetch] FAIL: transitionProperty='$tp' does not include 'filter'"
                    trans_ok=0
                fi
                # transitionDuration is like '2s' or '2000ms' or '0s'. Check > 0.
                td_num=$(printf '%s' "$td" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo "0")
                ok_td=$(awk "BEGIN{print($td_num>0)?1:0}")
                if [[ "$ok_td" != "1" ]]; then
                    echo "[prodfetch] FAIL: transitionDuration='$td' is not > 0"
                    trans_ok=0
                fi
            done <<< "$trans_out"
            if [[ $trans_ok -eq 1 ]]; then
                echo "[prodfetch] MOOD_TRANSITION confirmed: transitionProperty contains filter, duration > 0"
            else
                prodfetch_ok=0
            fi
        fi
    fi

    # Positive transport proof: fetchWeather emits transport=fake when using OW_MOOD_FAKE_RESPONSE_FILE
    # and transport=network when using URLSession. Fake must be present; network must be absent.
    transport_fake=$(grep 'ONLYWALLPAPERS_MOOD transport=fake' "$TMPOUT" || true)
    transport_net=$(grep 'ONLYWALLPAPERS_MOOD transport=network' "$TMPOUT" || true)
    if [[ -z "$transport_fake" ]]; then
        echo "[prodfetch] FAIL: transport=fake not found (fake file path not taken)"
        prodfetch_ok=0
    else
        echo "[prodfetch] transport=fake confirmed (fake file path taken)"
    fi
    if [[ -n "$transport_net" ]]; then
        echo "[prodfetch] FAIL: transport=network found (real URLSession call made)"
        prodfetch_ok=0
    else
        echo "[prodfetch] transport=network absent (no real network call)"
    fi
    # Also assert no stray api.open-meteo.com references beyond the expected fetch url= log.
    real_net=$(grep 'api.open-meteo.com' "$TMPOUT" | grep -v 'fetch url=' || true)
    if [[ -n "$real_net" ]]; then
        echo "[prodfetch] FAIL: unexpected api.open-meteo.com reference: $real_net"
        prodfetch_ok=0
    else
        echo "[prodfetch] no stray api.open-meteo.com references"
    fi
fi

kill_app
rm -f "$TMPOUT" "$FIXTURE_FILE" 2>/dev/null || true; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP" 2>/dev/null || true; OW_SUPPORT_TMP=""
FIXTURE_FILE=""

if [[ $prodfetch_ok -eq 2 ]]; then
    echo "[mood-check] SKIP (d) PRODUCTION-FETCH"
    SKIP=$((SKIP+1))
elif [[ $prodfetch_ok -eq 1 ]]; then
    echo "[mood-check] PASS (d) PRODUCTION-FETCH"
    PASS=$((PASS+1))
else
    echo "[mood-check] FAIL (d) PRODUCTION-FETCH"
    FAIL=$((FAIL+1))
fi

echo ""
# If no integration sub-check (a/b/c/d) verified real windows, the gate cannot be validated.
# A crashed or headless launch (0 windows) that skips every assertion must not exit 0.
if [[ $WINDOW_VERIFIED -eq 0 && $SKIP -gt 0 ]]; then
    echo "[mood-check] ALL-SKIPPED: no integration sub-check verified windows (PASS=$PASS FAIL=$FAIL SKIP=$SKIP)"
    exit 1
fi
echo "[mood-check] Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
