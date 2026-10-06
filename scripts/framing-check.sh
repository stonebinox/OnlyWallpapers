#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PID=""
TMPOUT=""
OW_SUPPORT_TMP=""
FAKE_SCREENS=""

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 0.4
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    [[ -n "$TMPOUT" ]] && rm -f "$TMPOUT" || true
    [[ -n "$OW_SUPPORT_TMP" ]] && rm -rf "$OW_SUPPORT_TMP" || true
    [[ -n "$FAKE_SCREENS" ]] && rm -f "$FAKE_SCREENS" || true
}
trap cleanup EXIT

echo "[framing-check] building..."
swift build -c release 2>&1 | tail -5
BINARY="$(swift build -c release --show-bin-path 2>/dev/null)/OnlyWallpapers"

PASS=0
FAIL=0
SKIP=0

launch_real() {
    local support_dir="$1"
    OW_APP_SUPPORT_DIR="$support_dir" OW_FRAMING_TEST=1 "$BINARY" > "$TMPOUT" 2>&1 &
    PID=$!
}

kill_app() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""
}

# Helper: extract integer from a value that may have "px" suffix, rounding to nearest int.
px_int() {
    printf '%.0f' "$(echo "$1" | tr -d 'px' | tr -d ' ')" 2>/dev/null || echo 0
}

# Helper: get stageW from first SLICE line in a file.
get_stageW() {
    grep 'ONLYWALLPAPERS_SLICE' "$1" | head -1 | sed 's/.*stageW=//;s/ .*//'
}

# Helper: get stageH from first SLICE line in a file.
get_stageH() {
    grep 'ONLYWALLPAPERS_SLICE' "$1" | head -1 | sed 's/.*stageH=//;s/ .*//'
}

# Helper: get win_count from last WINDOWS line.
get_win_count() {
    grep 'ONLYWALLPAPERS_WINDOWS' "$1" | tail -1 | sed 's/.*count=//;s/ .*//' 2>/dev/null || echo '0'
}

# Helper: extract FRAMING lines (not FRAMING_MEDIA, not persist= lines).
framing_lines() {
    grep 'ONLYWALLPAPERS_FRAMING' "$1" | grep -v 'FRAMING_MEDIA\|persist=' || true
}

# Helper: tight usedW check. Args: actual_px expected_px label.
check_px() {
    local actual="$1" expected="$2" label="$3"
    local diff=$(( actual - expected ))
    [[ $diff -lt 0 ]] && diff=$(( -diff ))
    if [[ $diff -gt 2 ]]; then
        echo "[$label] FAIL: actual=${actual}px expected=${expected}px diff=${diff}px (tolerance 2px)"
        return 1
    fi
    return 0
}

# --- (a) INJECT: non-default framing injected at load, every view reports it ---
echo "[framing-check] running (a) INJECT..."
OW_SUPPORT_TMP="$(mktemp -d)"
echo '{"zoom":1.5,"panX":0.0,"panY":1.0}' > "$OW_SUPPORT_TMP/config.json"
TMPOUT="$(mktemp)"
launch_real "$OW_SUPPORT_TMP"
sleep 6

win_count=$(get_win_count "$TMPOUT")
inject_framing=$(framing_lines "$TMPOUT")
inject_count=$(echo "$inject_framing" | grep -c . 2>/dev/null || echo 0)
inject_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[inject] SKIP: 0 windows (genuine headless; no display)"
    inject_ok=2
elif [[ $inject_count -eq 0 ]]; then
    echo "[inject] FAIL: $win_count window(s) but zero ONLYWALLPAPERS_FRAMING lines"
else
    inject_ok=1

    # Count must equal win_count.
    if [[ $inject_count -ne $win_count ]]; then
        echo "[inject] FAIL: FRAMING count=$inject_count != win_count=$win_count"
        inject_ok=0
    fi

    # All win= values must be distinct.
    unique_wins=$(echo "$inject_framing" | sed 's/.*win=//;s/ .*//' | sort -u | wc -l | tr -d ' ')
    if [[ $unique_wins -ne $inject_count ]]; then
        echo "[inject] FAIL: duplicate win= values in FRAMING lines (unique=$unique_wins count=$inject_count)"
        inject_ok=0
    fi

    # Per-window: usedW, usedH, objPos, zoom, panY.
    stageW_str=$(get_stageW "$TMPOUT")
    stageH_str=$(get_stageH "$TMPOUT")
    stageW=$(px_int "${stageW_str:-0}")
    stageH=$(px_int "${stageH_str:-0}")
    expected_usedW=$(( stageW * 3 / 2 ))  # round(1.5 * stageW) using integer arithmetic
    expected_usedH=$(( stageH * 3 / 2 ))

    echo "[inject] stageW=$stageW stageH=$stageH expected_usedW=$expected_usedW expected_usedH=$expected_usedH"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        win_val=$(echo "$line" | sed 's/.*win=//;s/ .*//')
        usedW_str=$(echo "$line" | sed 's/.*usedW=//;s/ .*//')
        usedH_str=$(echo "$line" | sed 's/.*usedH=//;s/ .*//')
        objPos=$(echo "$line" | sed 's/.*objPos=//')
        zoom_val=$(echo "$line" | sed 's/.*zoom=//;s/ .*//')
        panY_val=$(echo "$line" | sed 's/.*panY=//;s/ .*//')
        left_val=$(echo "$line" | sed 's/.*left=//;s/ .*//')
        top_val=$(echo "$line" | sed 's/.*top=//;s/ .*//')
        usedW_int=$(px_int "$usedW_str")
        usedH_int=$(px_int "$usedH_str")

        echo "[inject] win=$win_val zoom=$zoom_val panY=$panY_val usedW=${usedW_int}px usedH=${usedH_int}px left=$left_val top=$top_val objPos=$objPos"

        if ! check_px "$usedW_int" "$expected_usedW" "inject win=$win_val usedW"; then inject_ok=0; fi
        if ! check_px "$usedH_int" "$expected_usedH" "inject win=$win_val usedH"; then inject_ok=0; fi

        # objPos: panX=0 -> 50%, panY=1 -> 100%
        if ! echo "$objPos" | grep -q '50%'; then
            echo "[inject] FAIL: win=$win_val objPos X not 50% (got: $objPos)"
            inject_ok=0
        fi
        if ! echo "$objPos" | grep -q '100%'; then
            echo "[inject] FAIL: win=$win_val objPos Y not 100% (got: $objPos)"
            inject_ok=0
        fi

        # Verify actual zoom and panY from __framingApplied.
        if ! echo "$zoom_val" | grep -q '^1\.5'; then
            echo "[inject] FAIL: win=$win_val actual zoom=$zoom_val not 1.5"
            inject_ok=0
        fi
        if ! echo "$panY_val" | grep -q '^1\.'; then
            echo "[inject] FAIL: win=$win_val actual panY=$panY_val not 1.0"
            inject_ok=0
        fi

        # left% = 50*(1-zoom)*(1+panX), top% = 50*(1-zoom)*(1+panY)
        # With zoom=1.5, panX=0.0, panY=1.0: left=-25.0, top=-50.0 (nonzero; zeroing offset must FAIL)
        if ! python3 -c "import sys; l=float('$left_val'); sys.exit(0 if abs(l-(-25.0))<0.5 else 1)" 2>/dev/null; then
            echo "[inject] FAIL: win=$win_val left=$left_val expected~-25.0 (formula 50*(1-zoom)*(1+panX))"
            inject_ok=0
        fi
        if ! python3 -c "import sys; t=float('$top_val'); sys.exit(0 if abs(t-(-50.0))<0.5 else 1)" 2>/dev/null; then
            echo "[inject] FAIL: win=$win_val top=$top_val expected~-50.0 (formula 50*(1-zoom)*(1+panY))"
            inject_ok=0
        fi
    done <<< "$inject_framing"

    # Identity: all views must agree on zoom, usedW, usedH, objPos.
    unique_zooms=$(echo "$inject_framing" | sed 's/.*zoom=//;s/ .*//' | sort -u | wc -l | tr -d ' ')
    unique_usedW=$(echo "$inject_framing" | sed 's/.*usedW=//;s/ .*//' | sort -u | wc -l | tr -d ' ')
    unique_usedH=$(echo "$inject_framing" | sed 's/.*usedH=//;s/ .*//' | sort -u | wc -l | tr -d ' ')
    if [[ $unique_zooms -gt 1 ]] || [[ $unique_usedW -gt 1 ]] || [[ $unique_usedH -gt 1 ]]; then
        echo "[inject] FAIL: identity mismatch across views (zooms=$unique_zooms usedW=$unique_usedW usedH=$unique_usedH unique values)"
        inject_ok=0
    else
        echo "[inject] identity ok: all $inject_count views agree"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $inject_ok -eq 2 ]]; then
    echo "[framing-check] SKIP (a) INJECT"
    SKIP=$((SKIP+1))
elif [[ $inject_ok -eq 1 ]]; then
    echo "[framing-check] PASS (a) INJECT"
    PASS=$((PASS+1))
else
    echo "[framing-check] FAIL (a) INJECT"
    FAIL=$((FAIL+1))
fi

# --- (b) NUDGE: SIGUSR2 calls zoomBy(0.1) (production path: nudge -> writeFraming -> applyFramingToAll) ---
echo "[framing-check] running (b) NUDGE..."
OW_SUPPORT_TMP="$(mktemp -d)"
# panY=0.5 is nonzero so writeFraming that drops/corrupts panX or panY will be caught by the config.json check.
echo '{"zoom":1.5,"panX":0.0,"panY":0.5}' > "$OW_SUPPORT_TMP/config.json"
TMPOUT="$(mktemp)"
launch_real "$OW_SUPPORT_TMP"
sleep 4

win_count=$(get_win_count "$TMPOUT")
nudge_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[nudge] SKIP: 0 windows (genuine headless)"
    nudge_ok=2
else
    # Record output size before nudge.
    pre_nudge_lines=$(wc -l < "$TMPOUT" | tr -d ' ')
    stageW_str=$(get_stageW "$TMPOUT")
    stageW=$(px_int "${stageW_str:-0}")
    expected_usedW=$(echo "$stageW * 16 / 10" | bc)  # round(1.6 * stageW)

    # Nudge: SIGUSR2 calls zoomBy(0.1), going from 1.5 to 1.6 via production path.
    kill -USR2 "$PID" 2>/dev/null || true
    sleep 3

    # Collect post-nudge lines.
    total_lines=$(wc -l < "$TMPOUT" | tr -d ' ')
    added=$((total_lines - pre_nudge_lines))
    if [[ $added -gt 0 ]]; then
        post_output=$(tail -n "$added" "$TMPOUT")
    else
        post_output=""
    fi

    nudge_framing=$(echo "$post_output" | grep 'ONLYWALLPAPERS_FRAMING' | grep -v 'FRAMING_MEDIA\|persist=' || true)
    nudge_distinct_wins=$(echo "$nudge_framing" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    nudge_distinct_count=$(echo "$nudge_distinct_wins" | grep -c . 2>/dev/null || echo 0)

    if [[ $nudge_distinct_count -eq 0 ]]; then
        echo "[nudge] FAIL: no FRAMING lines appeared after SIGUSR2 nudge"
    else
        nudge_ok=1

        # Every window must appear by distinct win=; duplicate telemetry from one view must not mask a missing view.
        if [[ $nudge_distinct_count -ne $win_count ]]; then
            echo "[nudge] FAIL: post-nudge FRAMING distinct win= count=$nudge_distinct_count != win_count=$win_count"
            nudge_ok=0
        fi

        # Per distinct win=: check zoom=1.6, usedW, and live pan readback (panY, objPos, top).
        while IFS= read -r wn; do
            [[ -z "$wn" ]] && continue
            last_line=$(echo "$nudge_framing" | grep "win=${wn}" | tail -1)
            zoom_val=$(echo "$last_line" | sed 's/.*zoom=//;s/ .*//')
            usedW_str=$(echo "$last_line" | sed 's/.*usedW=//;s/ .*//')
            usedW_int=$(px_int "$usedW_str")
            panY_val=$(echo "$last_line" | sed 's/.*panY=//;s/ .*//')
            objPos_val=$(echo "$last_line" | sed 's/.*objPos=//')
            top_val=$(echo "$last_line" | sed 's/.*top=//;s/ .*//')
            echo "[nudge] win=$wn zoom=$zoom_val panY=$panY_val usedW=${usedW_int}px expected=${expected_usedW}px top=$top_val objPos=$objPos_val"
            if ! echo "$zoom_val" | grep -q '^1\.6'; then
                echo "[nudge] FAIL: win=$wn actual zoom=$zoom_val not 1.6"
                nudge_ok=0
            fi
            if ! check_px "$usedW_int" "$expected_usedW" "nudge win=$wn usedW"; then nudge_ok=0; fi
            # panY must still be 0.5 after zoom nudge (runtime apply must not drop pan).
            if ! python3 -c "import sys; p=float('$panY_val'); sys.exit(0 if abs(p-0.5)<0.01 else 1)" 2>/dev/null; then
                echo "[nudge] FAIL: win=$wn live panY=$panY_val not 0.5 (runtime apply dropped pan)"
                nudge_ok=0
            fi
            # objPos Y: 50 + panY*50 = 50 + 0.5*50 = 75%.
            if ! echo "$objPos_val" | grep -q '75%'; then
                echo "[nudge] FAIL: win=$wn objPos Y not 75% for panY=0.5 (got: $objPos_val)"
                nudge_ok=0
            fi
            # top offset: 50*(1-zoom)*(1+panY) = 50*(1-1.6)*(1+0.5) = 50*(-0.6)*1.5 = -45.0
            if ! python3 -c "import sys; t=float('$top_val'); sys.exit(0 if abs(t-(-45.0))<0.5 else 1)" 2>/dev/null; then
                echo "[nudge] FAIL: win=$wn top=$top_val expected~-45.0 (formula 50*(1-1.6)*(1+0.5))"
                nudge_ok=0
            fi
        done <<< "$nudge_distinct_wins"

        # config.json must now have zoom=1.6 AND the original panX=0.0 AND panY=0.5 (all three fields).
        # Float comparison via python3: JSONSerialization may emit 0 (no decimal) for 0.0.
        if ! python3 -c "import json,sys; d=json.load(open('$OW_SUPPORT_TMP/config.json')); sys.exit(0 if abs(float(d.get('zoom',0))-1.6)<0.01 else 1)" 2>/dev/null; then
            stored_zoom=$(python3 -c "import json; print(json.load(open('$OW_SUPPORT_TMP/config.json')).get('zoom','none'))" 2>/dev/null || echo 'none')
            echo "[nudge] FAIL: config.json zoom=$stored_zoom not 1.6 (app's writeFraming must have written it)"
            nudge_ok=0
        else
            echo "[nudge] config.json zoom check ok (1.6)"
        fi
        if ! python3 -c "import json,sys; d=json.load(open('$OW_SUPPORT_TMP/config.json')); sys.exit(0 if abs(float(d.get('panX',999)))<0.01 else 1)" 2>/dev/null; then
            stored_panX=$(python3 -c "import json; print(json.load(open('$OW_SUPPORT_TMP/config.json')).get('panX','missing'))" 2>/dev/null || echo 'none')
            echo "[nudge] FAIL: config.json panX=$stored_panX not 0.0 (writeFraming must preserve panX)"
            nudge_ok=0
        else
            echo "[nudge] config.json panX check ok (0.0)"
        fi
        if ! python3 -c "import json,sys; d=json.load(open('$OW_SUPPORT_TMP/config.json')); sys.exit(0 if abs(float(d.get('panY',999))-0.5)<0.01 else 1)" 2>/dev/null; then
            stored_panY=$(python3 -c "import json; print(json.load(open('$OW_SUPPORT_TMP/config.json')).get('panY','missing'))" 2>/dev/null || echo 'none')
            echo "[nudge] FAIL: config.json panY=$stored_panY not 0.5 (writeFraming must preserve panY)"
            nudge_ok=0
        else
            echo "[nudge] config.json panY check ok (0.5)"
        fi
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $nudge_ok -eq 2 ]]; then
    echo "[framing-check] SKIP (b) NUDGE"
    SKIP=$((SKIP+1))
elif [[ $nudge_ok -eq 1 ]]; then
    echo "[framing-check] PASS (b) NUDGE"
    PASS=$((PASS+1))
else
    echo "[framing-check] FAIL (b) NUDGE"
    FAIL=$((FAIL+1))
fi

# --- (f) ABSENT_DIR: writeFraming creates the dir when OW_APP_SUPPORT_DIR does not exist ---
# Proves createDirectory is called before writing config.json. If removed, write fails and file is absent.
echo "[framing-check] running (f) ABSENT_DIR..."
OW_SUPPORT_TMP="$(mktemp -d)"
ABSENT_DIR="$OW_SUPPORT_TMP/sub/does-not-exist"
# ABSENT_DIR does not exist yet; OW_SUPPORT_TMP is the parent and gets cleaned up on exit.
TMPOUT="$(mktemp)"
OW_APP_SUPPORT_DIR="$ABSENT_DIR" OW_FRAMING_TEST=1 "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 4

win_count=$(get_win_count "$TMPOUT")
absent_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[absent-dir] SKIP: 0 windows (genuine headless)"
    absent_ok=2
else
    # Nudge to trigger writeFraming, which must createDirectory before opening config.json for write.
    kill -USR2 "$PID" 2>/dev/null || true
    sleep 3

    if [[ ! -f "$ABSENT_DIR/config.json" ]]; then
        echo "[absent-dir] FAIL: config.json was NOT created at $ABSENT_DIR (createDirectory missing from writeFraming)"
        absent_ok=0
    else
        absent_ok=1
        stored_zoom=$(python3 -c "import json; print(json.load(open('$ABSENT_DIR/config.json')).get('zoom','none'))" 2>/dev/null || echo 'none')
        echo "[absent-dir] config.json CREATED at absent dir (zoom=$stored_zoom)"
        if ! python3 -c "import json,sys; d=json.load(open('$ABSENT_DIR/config.json')); z=float(d.get('zoom',0)); sys.exit(0 if 1.0<=z<=2.0 else 1)" 2>/dev/null; then
            echo "[absent-dir] FAIL: config.json zoom=$stored_zoom not in [1.0, 2.0]"
            absent_ok=0
        else
            echo "[absent-dir] config.json zoom=$stored_zoom valid (in [1.0, 2.0])"
        fi
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $absent_ok -eq 2 ]]; then
    echo "[framing-check] SKIP (f) ABSENT_DIR"
    SKIP=$((SKIP+1))
elif [[ $absent_ok -eq 1 ]]; then
    echo "[framing-check] PASS (f) ABSENT_DIR"
    PASS=$((PASS+1))
else
    echo "[framing-check] FAIL (f) ABSENT_DIR"
    FAIL=$((FAIL+1))
fi

# --- (c) CLAMP: out-of-range config values clamped by JS applyFraming ---
echo "[framing-check] running (c) CLAMP..."
OW_SUPPORT_TMP="$(mktemp -d)"
echo '{"zoom":0.5,"panX":5,"panY":"bad"}' > "$OW_SUPPORT_TMP/config.json"
TMPOUT="$(mktemp)"
launch_real "$OW_SUPPORT_TMP"
sleep 6

win_count=$(get_win_count "$TMPOUT")
clamp_framing=$(framing_lines "$TMPOUT")
clamp_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[clamp] SKIP: 0 windows (genuine headless)"
    clamp_ok=2
elif [[ -z "$clamp_framing" ]]; then
    echo "[clamp] FAIL: $win_count window(s) but zero ONLYWALLPAPERS_FRAMING lines"
else
    clamp_ok=1
    clamp_distinct_wins=$(echo "$clamp_framing" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    clamp_distinct_count=$(echo "$clamp_distinct_wins" | grep -c . 2>/dev/null || echo 0)
    if [[ $clamp_distinct_count -eq 0 ]]; then
        echo "[clamp] FAIL: no distinct win= found in FRAMING lines"
        clamp_ok=0
    elif [[ $clamp_distinct_count -ne $win_count ]]; then
        echo "[clamp] FAIL: FRAMING distinct win= count=$clamp_distinct_count != win_count=$win_count"
        clamp_ok=0
    fi
    while IFS= read -r wn; do
        [[ -z "$wn" ]] && continue
        clamp_line=$(echo "$clamp_framing" | grep "win=${wn}" | tail -1)
        clamp_zoom=$(echo "$clamp_line" | sed 's/.*zoom=//;s/ .*//')
        clamp_panX=$(echo "$clamp_line" | sed 's/.*panX=//;s/ .*//')
        clamp_panY=$(echo "$clamp_line" | sed 's/.*panY=//;s/ .*//')
        echo "[clamp] win=$wn zoom=$clamp_zoom panX=$clamp_panX panY=$clamp_panY"
        if ! echo "$clamp_zoom" | grep -q '^1\.0'; then
            echo "[clamp] FAIL: win=$wn zoom=$clamp_zoom not clamped to 1.0"
            clamp_ok=0
        fi
        if ! echo "$clamp_panX" | grep -q '^1\.0'; then
            echo "[clamp] FAIL: win=$wn panX=$clamp_panX not clamped to 1.0"
            clamp_ok=0
        fi
        if ! echo "$clamp_panY" | grep -q '^0\.0'; then
            echo "[clamp] FAIL: win=$wn panY=$clamp_panY not defaulted to 0.0"
            clamp_ok=0
        fi
    done <<< "$clamp_distinct_wins"
    [[ $clamp_ok -eq 1 ]] && echo "[clamp] per-window clamped values confirmed on all $clamp_distinct_count window(s)"
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $clamp_ok -eq 2 ]]; then
    echo "[framing-check] SKIP (c) CLAMP"
    SKIP=$((SKIP+1))
elif [[ $clamp_ok -eq 1 ]]; then
    echo "[framing-check] PASS (c) CLAMP"
    PASS=$((PASS+1))
else
    echo "[framing-check] FAIL (c) CLAMP"
    FAIL=$((FAIL+1))
fi

# --- (d) ZOOM_LIVENESS: runtime resize via 10 nudges (1.0 -> 2.0) must keep media=playing on every window ---
echo "[framing-check] running (d) ZOOM_LIVENESS..."
OW_SUPPORT_TMP="$(mktemp -d)"
# Default framing: zoom=1.0. No config.json needed (AppStorageManager defaults to 1.0).
TMPOUT="$(mktemp)"
mp4_path="$REPO_ROOT/Sources/OnlyWallpapers/web/assets/bg.mp4"
if [[ -f "$mp4_path" ]]; then
    OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" OW_FRAMING_TEST=1 WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" "$BINARY" > "$TMPOUT" 2>&1 &
else
    launch_real "$OW_SUPPORT_TMP"
fi
PID=$!
sleep 7

win_count=$(get_win_count "$TMPOUT")
zoom_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[zoom-liveness] SKIP: 0 windows (genuine headless)"
    zoom_ok=2
else
    # Confirm initial media=playing on all loaded windows (from periodic checks at 1.0, 2.5, or 7.5s).
    loaded_wins=$(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT" | sed 's/.*win=//;s/ .*//' | sort -u)
    initial_media_ok=1
    for wn in $loaded_wins; do
        if ! grep -q "ONLYWALLPAPERS_WEB.*win=$wn.*media=playing" "$TMPOUT"; then
            echo "[zoom-liveness] FAIL: win=$wn has no initial media=playing before nudge"
            initial_media_ok=0
        fi
    done

    if [[ $initial_media_ok -eq 0 ]]; then
        echo "[zoom-liveness] FAIL: initial media check failed before resize"
    else
        echo "[zoom-liveness] initial media=playing confirmed on all windows; sending 10 zoom nudges to reach 2.0"

        # Record output size before nudges.
        pre_nudge_lines=$(wc -l < "$TMPOUT" | tr -d ' ')

        # 10 x SIGUSR2 (zoomBy 0.1 each) to go from 1.0 to 2.0 via production path.
        for i in $(seq 1 10); do
            kill -USR2 "$PID" 2>/dev/null || true
            sleep 0.3
        done

        # Wait for all FRAMING_MEDIA lines to appear (each fires 2s after its nudge).
        sleep 4

        total_lines=$(wc -l < "$TMPOUT" | tr -d ' ')
        added=$((total_lines - pre_nudge_lines))
        if [[ $added -gt 0 ]]; then
            post_output=$(tail -n "$added" "$TMPOUT")
        else
            post_output=""
        fi

        zoom_ok=1

        # (a) Loaded window count must equal win_count; a partial set must fail.
        loaded_win_arr=($loaded_wins)
        loaded_count=${#loaded_win_arr[@]}
        if [[ $loaded_count -ne $win_count ]]; then
            echo "[zoom-liveness] FAIL: loaded window count=$loaded_count != win_count=$win_count (partial set)"
            zoom_ok=0
        fi

        # (b) Final FRAMING per distinct win= must show actual zoom=2.0 and usedW==round(2.0*stageW).
        stageW_str=$(get_stageW "$TMPOUT")
        stageW=$(px_int "${stageW_str:-0}")
        expected_usedW_2=$(( stageW * 2 ))
        final_framing=$(echo "$post_output" | grep 'ONLYWALLPAPERS_FRAMING' | grep -v 'FRAMING_MEDIA\|persist=' || true)
        final_distinct_wins=$(echo "$final_framing" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
        final_distinct_count=$(echo "$final_distinct_wins" | grep -c . 2>/dev/null || echo 0)
        echo "[zoom-liveness] stageW=$stageW expected_usedW_2=${expected_usedW_2}px final FRAMING distinct wins=$final_distinct_count"

        if [[ $final_distinct_count -ne $win_count ]]; then
            echo "[zoom-liveness] FAIL: final FRAMING distinct win= count=$final_distinct_count != win_count=$win_count (a single nudge or partial set must not pass)"
            zoom_ok=0
        fi

        while IFS= read -r wn; do
            [[ -z "$wn" ]] && continue
            final_line=$(echo "$final_framing" | grep "win=${wn}" | tail -1)
            actual_zoom=$(echo "$final_line" | sed 's/.*zoom=//;s/ .*//')
            actual_usedW_str=$(echo "$final_line" | sed 's/.*usedW=//;s/ .*//')
            actual_usedW=$(px_int "$actual_usedW_str")
            echo "[zoom-liveness] win=$wn final zoom=$actual_zoom usedW=${actual_usedW}px expected=${expected_usedW_2}px"
            if ! echo "$actual_zoom" | grep -q '^2\.0'; then
                echo "[zoom-liveness] FAIL: win=$wn final zoom=$actual_zoom not 2.0 (must have reached zoom=2.0)"
                zoom_ok=0
            fi
            if ! check_px "$actual_usedW" "$expected_usedW_2" "zoom-liveness win=$wn usedW"; then zoom_ok=0; fi
        done <<< "$final_distinct_wins"

        # (c) Media sampled AT zoom=2: use the last FRAMING_MEDIA line per window (emitted 2s after
        # the final nudge). A video that paused at zoom=2 while an earlier playing line lingers must FAIL.
        for wn in $loaded_wins; do
            last_media_line=$(echo "$post_output" | grep "ONLYWALLPAPERS_FRAMING_MEDIA win=$wn" | tail -1)
            if [[ -z "$last_media_line" ]] || ! echo "$last_media_line" | grep -q "media=playing"; then
                echo "[zoom-liveness] FAIL: win=$wn last FRAMING_MEDIA at zoom=2 is not playing (got: ${last_media_line:-none})"
                zoom_ok=0
            fi
        done
        [[ $zoom_ok -eq 1 ]] && echo "[zoom-liveness] zoom=2.0 reached on all $win_count windows with media=playing confirmed"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $zoom_ok -eq 2 ]]; then
    echo "[framing-check] SKIP (d) ZOOM_LIVENESS"
    SKIP=$((SKIP+1))
elif [[ $zoom_ok -eq 1 ]]; then
    echo "[framing-check] PASS (d) ZOOM_LIVENESS"
    PASS=$((PASS+1))
else
    echo "[framing-check] FAIL (d) ZOOM_LIVENESS"
    FAIL=$((FAIL+1))
fi

# --- (e) HOT_PLUG: newcomer window carries current framing + media=playing ---
echo "[framing-check] running (e) HOT_PLUG..."
mp4_path="$REPO_ROOT/Sources/OnlyWallpapers/web/assets/bg.mp4"
if [[ ! -f "$mp4_path" ]]; then
    echo "[hotplug] SKIP: bg.mp4 not found"
    echo "[framing-check] SKIP (e) HOT_PLUG"
    SKIP=$((SKIP+1))
else
    FAKE_SCREENS="$(mktemp)"
    cat > "$FAKE_SCREENS" <<'SCREENS'
0, 0, 1920, 1080, 2.0, 1
1920, 0, 1920, 1080, 2.0, 2
SCREENS

    OW_SUPPORT_TMP="$(mktemp -d)"
    # panY=1.0 is nonzero so a newcomer that loses pan on hot-plug will be caught.
    echo '{"zoom":1.5,"panX":0.0,"panY":1.0}' > "$OW_SUPPORT_TMP/config.json"
    TMPOUT="$(mktemp)"

    OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" OW_FAKE_SCREENS_FILE="$FAKE_SCREENS" OW_FRAMING_TEST=1 WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" "$BINARY" > "$TMPOUT" 2>&1 &
    PID=$!
    sleep 6

    # Record state before rebuild.
    pre_rebuild_lines=$(wc -l < "$TMPOUT" | tr -d ' ')
    pre_rebuild_framing_text=$(framing_lines "$TMPOUT" || true)
    pre_rebuild_wins=$(echo "$pre_rebuild_framing_text" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
    pre_win_count=$(get_win_count "$TMPOUT")

    # Add a third screen.
    cat > "$FAKE_SCREENS" <<'SCREENS3'
0, 0, 1920, 1080, 2.0, 1
1920, 0, 1920, 1080, 2.0, 2
3840, 0, 1920, 1080, 2.0, 3
SCREENS3
    kill -USR1 "$PID" 2>/dev/null || true
    sleep 8

    # Collect post-rebuild output.
    total_lines=$(wc -l < "$TMPOUT" | tr -d ' ')
    added=$((total_lines - pre_rebuild_lines))
    if [[ $added -gt 0 ]]; then
        post_output=$(tail -n "$added" "$TMPOUT")
    else
        post_output=""
    fi

    post_win_count=$(get_win_count "$TMPOUT")
    post_rebuild_framing=$(echo "$post_output" | grep 'ONLYWALLPAPERS_FRAMING' | grep -v 'FRAMING_MEDIA\|persist=' || true)
    post_rebuild_wins=$(echo "$post_rebuild_framing" | sed 's/.*win=//;s/ .*//' | sort -u || true)

    # Identify newcomer: win= present in post-rebuild FRAMING lines but not in pre-rebuild.
    newcomer_win=""
    for wn in $post_rebuild_wins; do
        if ! echo "$pre_rebuild_wins" | grep -q "^${wn}$"; then
            newcomer_win="$wn"
            break
        fi
    done

    hotplug_ok=0

    if [[ -z "$newcomer_win" ]]; then
        echo "[hotplug] FAIL: no newcomer win= identified in post-rebuild FRAMING lines"
        echo "[hotplug] pre_rebuild_wins=$pre_rebuild_wins post_rebuild_wins=$post_rebuild_wins"
    else
        hotplug_ok=1
        echo "[hotplug] newcomer win=$newcomer_win identified"

        newcomer_line=$(echo "$post_rebuild_framing" | grep "win=${newcomer_win}" | tail -1)
        newcomer_zoom=$(echo "$newcomer_line" | sed 's/.*zoom=//;s/ .*//')
        newcomer_panX=$(echo "$newcomer_line" | sed 's/.*panX=//;s/ .*//')
        newcomer_panY=$(echo "$newcomer_line" | sed 's/.*panY=//;s/ .*//')
        newcomer_usedW=$(echo "$newcomer_line" | sed 's/.*usedW=//;s/ .*//')
        newcomer_usedH=$(echo "$newcomer_line" | sed 's/.*usedH=//;s/ .*//')
        newcomer_left=$(echo "$newcomer_line" | sed 's/.*left=//;s/ .*//')
        newcomer_top=$(echo "$newcomer_line" | sed 's/.*top=//;s/ .*//')
        newcomer_objPos=$(echo "$newcomer_line" | sed 's/.*objPos=//')
        echo "[hotplug] newcomer zoom=$newcomer_zoom panX=$newcomer_panX panY=$newcomer_panY usedW=$newcomer_usedW usedH=$newcomer_usedH left=$newcomer_left top=$newcomer_top objPos=$newcomer_objPos"

        # Newcomer must carry the non-default framing from config (zoom=1.5, panX=0.0, panY=1.0).
        if ! echo "$newcomer_zoom" | grep -q '^1\.5'; then
            echo "[hotplug] FAIL: newcomer zoom=$newcomer_zoom not 1.5 (non-default framing)"
            hotplug_ok=0
        fi
        if ! echo "$newcomer_panX" | grep -q '^0\.0'; then
            echo "[hotplug] FAIL: newcomer panX=$newcomer_panX not 0.0"
            hotplug_ok=0
        fi
        if ! echo "$newcomer_panY" | grep -q '^1\.'; then
            echo "[hotplug] FAIL: newcomer panY=$newcomer_panY not 1.0 (nonzero pan must survive hot-plug)"
            hotplug_ok=0
        fi
        # left% = 50*(1-1.5)*(1+0.0) = -25.0, top% = 50*(1-1.5)*(1+1.0) = -50.0
        if ! python3 -c "import sys; l=float('$newcomer_left'); sys.exit(0 if abs(l-(-25.0))<0.5 else 1)" 2>/dev/null; then
            echo "[hotplug] FAIL: newcomer left=$newcomer_left expected~-25.0 (formula 50*(1-zoom)*(1+panX))"
            hotplug_ok=0
        fi
        if ! python3 -c "import sys; t=float('$newcomer_top'); sys.exit(0 if abs(t-(-50.0))<0.5 else 1)" 2>/dev/null; then
            echo "[hotplug] FAIL: newcomer top=$newcomer_top expected~-50.0 (formula 50*(1-zoom)*(1+panY))"
            hotplug_ok=0
        fi

        # Nudge all windows to force survivors to re-emit FRAMING with the post-rebuild (3-screen) stageW.
        # The canvas grew when the 3rd screen was added; survivors must recalculate usedW on the new stageW.
        # Without a nudge, survivors do not re-emit FRAMING after rebuild, making the identity check vacuous.
        pre_nudge_lines=$(wc -l < "$TMPOUT" | tr -d ' ')
        kill -USR2 "$PID" 2>/dev/null || true
        sleep 3
        nudge_added=$(( $(wc -l < "$TMPOUT" | tr -d ' ') - pre_nudge_lines ))
        if [[ $nudge_added -gt 0 ]]; then
            nudge_output=$(tail -n "$nudge_added" "$TMPOUT")
        else
            nudge_output=""
        fi
        post_nudge_framing=$(echo "$nudge_output" | grep 'ONLYWALLPAPERS_FRAMING' | grep -v 'FRAMING_MEDIA\|persist=' || true)
        nudge_distinct_wins=$(echo "$post_nudge_framing" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
        nudge_distinct_count=$(echo "$nudge_distinct_wins" | grep -c . 2>/dev/null || echo 0)
        echo "[hotplug] post-rebuild nudge: $nudge_distinct_count distinct wins emitted FRAMING (expected $post_win_count)"

        # All post-rebuild windows (newcomer + survivors) must respond to the nudge.
        if [[ $nudge_distinct_count -ne $post_win_count ]]; then
            echo "[hotplug] FAIL: post-nudge FRAMING distinct win= count=$nudge_distinct_count != post_win_count=$post_win_count"
            hotplug_ok=0
        fi

        # Identify survivors in the nudge output (all non-newcomer windows).
        survivor_wins=()
        for wn in $nudge_distinct_wins; do
            if [[ "$wn" != "$newcomer_win" ]]; then
                survivor_wins+=("$wn")
            fi
        done
        echo "[hotplug] survivor windows: ${survivor_wins[*]:-none}"

        if [[ ${#survivor_wins[@]} -eq 0 ]]; then
            echo "[hotplug] FAIL: no survivor windows in post-nudge FRAMING (identity comparison would be vacuous)"
            hotplug_ok=0
        fi

        # Identity: newcomer post-nudge zoom and objPos must match every survivor's post-nudge values.
        # usedW and usedH are intentionally excluded: usedW = zoom * stageW, and existing WKWebViews
        # keep their pre-rebuild stageW (the 2-screen canvas) while the newcomer starts on the 3-screen
        # canvas; the rendered sizes therefore differ by design. zoom and objPos are the logical framing
        # config and are stageW-independent, so they are the correct identity signal.
        newcomer_nudge_line=$(echo "$post_nudge_framing" | grep "win=${newcomer_win}" | tail -1)
        newcomer_nudge_zoom=$(echo "$newcomer_nudge_line" | sed 's/.*zoom=//;s/ .*//')
        newcomer_nudge_panX=$(echo "$newcomer_nudge_line" | sed 's/.*panX=//;s/ .*//')
        newcomer_nudge_panY=$(echo "$newcomer_nudge_line" | sed 's/.*panY=//;s/ .*//')
        newcomer_nudge_usedW=$(echo "$newcomer_nudge_line" | sed 's/.*usedW=//;s/ .*//')
        newcomer_nudge_usedH=$(echo "$newcomer_nudge_line" | sed 's/.*usedH=//;s/ .*//')
        newcomer_nudge_left=$(echo "$newcomer_nudge_line" | sed 's/.*left=//;s/ .*//')
        newcomer_nudge_top=$(echo "$newcomer_nudge_line" | sed 's/.*top=//;s/ .*//')
        newcomer_nudge_objPos=$(echo "$newcomer_nudge_line" | sed 's/.*objPos=//')
        echo "[hotplug] newcomer post-nudge zoom=$newcomer_nudge_zoom panX=$newcomer_nudge_panX panY=$newcomer_nudge_panY left=$newcomer_nudge_left top=$newcomer_nudge_top usedW=$newcomer_nudge_usedW usedH=$newcomer_nudge_usedH objPos=$newcomer_nudge_objPos"

        if [[ ${#survivor_wins[@]} -gt 0 ]]; then
            for wn in "${survivor_wins[@]}"; do
                surv_line=$(echo "$post_nudge_framing" | grep "win=${wn}" | tail -1)
                surv_zoom=$(echo "$surv_line" | sed 's/.*zoom=//;s/ .*//')
                surv_panX=$(echo "$surv_line" | sed 's/.*panX=//;s/ .*//')
                surv_panY=$(echo "$surv_line" | sed 's/.*panY=//;s/ .*//')
                surv_usedW=$(echo "$surv_line" | sed 's/.*usedW=//;s/ .*//')
                surv_usedH=$(echo "$surv_line" | sed 's/.*usedH=//;s/ .*//')
                surv_left=$(echo "$surv_line" | sed 's/.*left=//;s/ .*//')
                surv_top=$(echo "$surv_line" | sed 's/.*top=//;s/ .*//')
                surv_objPos=$(echo "$surv_line" | sed 's/.*objPos=//')
                echo "[hotplug] survivor win=$wn post-nudge zoom=$surv_zoom panX=$surv_panX panY=$surv_panY left=$surv_left top=$surv_top usedW=$surv_usedW usedH=$surv_usedH objPos=$surv_objPos"
                if [[ "$newcomer_nudge_zoom" != "$surv_zoom" ]]; then
                    echo "[hotplug] FAIL: newcomer zoom=$newcomer_nudge_zoom != survivor win=$wn zoom=$surv_zoom"
                    hotplug_ok=0
                fi
                if [[ "$newcomer_nudge_panX" != "$surv_panX" ]]; then
                    echo "[hotplug] FAIL: newcomer panX=$newcomer_nudge_panX != survivor win=$wn panX=$surv_panX"
                    hotplug_ok=0
                fi
                if [[ "$newcomer_nudge_panY" != "$surv_panY" ]]; then
                    echo "[hotplug] FAIL: newcomer panY=$newcomer_nudge_panY != survivor win=$wn panY=$surv_panY"
                    hotplug_ok=0
                fi
                if ! python3 -c "import sys; l1=float('$newcomer_nudge_left'); l2=float('$surv_left'); sys.exit(0 if abs(l1-l2)<0.5 else 1)" 2>/dev/null; then
                    echo "[hotplug] FAIL: newcomer left=$newcomer_nudge_left != survivor win=$wn left=$surv_left"
                    hotplug_ok=0
                fi
                if ! python3 -c "import sys; t1=float('$newcomer_nudge_top'); t2=float('$surv_top'); sys.exit(0 if abs(t1-t2)<0.5 else 1)" 2>/dev/null; then
                    echo "[hotplug] FAIL: newcomer top=$newcomer_nudge_top != survivor win=$wn top=$surv_top"
                    hotplug_ok=0
                fi
                if [[ "$newcomer_nudge_objPos" != "$surv_objPos" ]]; then
                    echo "[hotplug] FAIL: newcomer objPos=$newcomer_nudge_objPos != survivor win=$wn objPos=$surv_objPos"
                    hotplug_ok=0
                fi
            done
            if [[ $hotplug_ok -eq 1 ]]; then
                echo "[hotplug] identity ok: newcomer zoom+panX+panY+left+top+objPos matches all ${#survivor_wins[@]} survivor(s) post-rebuild"
            fi
        fi

        # Newcomer must show media=playing (FRAMING_MEDIA or periodic WEB media line).
        if ! echo "$post_output" | grep -qE "ONLYWALLPAPERS_(FRAMING_MEDIA win=${newcomer_win} media=playing|WEB.*win=${newcomer_win}.*media=playing)"; then
            echo "[hotplug] FAIL: newcomer win=$newcomer_win has no media=playing after hot-plug"
            hotplug_ok=0
        else
            echo "[hotplug] newcomer win=$newcomer_win media=playing confirmed"
        fi

        # Final window count must be greater than initial.
        echo "[hotplug] window count: before=$pre_win_count after=$post_win_count"
        if [[ "$post_win_count" -le "$pre_win_count" ]]; then
            echo "[hotplug] FAIL: window count did not increase ($pre_win_count -> $post_win_count)"
            hotplug_ok=0
        fi
    fi

    if [[ $hotplug_ok -eq 1 ]]; then
        # Crash guard.
        if ! kill -0 "$PID" 2>/dev/null; then
            echo "[hotplug] FAIL: app crashed during rebuild"
            hotplug_ok=0
        fi
    fi

    kill_app
    rm -f "$TMPOUT"; TMPOUT=""
    rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""
    rm -f "$FAKE_SCREENS"; FAKE_SCREENS=""

    if [[ $hotplug_ok -eq 1 ]]; then
        echo "[framing-check] PASS (e) HOT_PLUG"
        PASS=$((PASS+1))
    else
        echo "[framing-check] FAIL (e) HOT_PLUG"
        FAIL=$((FAIL+1))
    fi
fi

echo ""
echo "[framing-check] Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
