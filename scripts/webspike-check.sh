#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Global PIDs for cleanup
PID=""
TMPOUT=""
CTRL_PID=""
CTRL_TMPOUT=""
CLEAR_PID=""
SIGINT_CLEAN=0

cleanup() {
    for p in "$PID" "$CTRL_PID" "$CLEAR_PID"; do
        if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
            kill -INT "$p" 2>/dev/null || true
            sleep 0.4
            if kill -0 "$p" 2>/dev/null; then
                kill -KILL "$p" 2>/dev/null || true
            fi
            wait "$p" 2>/dev/null || true
        fi
    done
    for f in "$TMPOUT" "$CTRL_TMPOUT"; do
        [[ -n "$f" ]] && rm -f "$f" || true
    done
}
trap cleanup EXIT

sigint_handler() {
    SIGINT_CLEAN=1
    exit 130
}
trap sigint_handler INT

# Dependency checks
for cmd in ffmpeg screencapture pmset; do
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            ffmpeg) echo "MISSING: ffmpeg. Install with: brew install ffmpeg" ;;
            screencapture) echo "MISSING: screencapture (should be built in on macOS)" ;;
            pmset) echo "MISSING: pmset (should be built in on macOS)" ;;
        esac
        exit 1
    fi
done

# FIX 4: Require AC power before doing anything else
echo "[power] Checking power source..."
BATT_OUTPUT="$(pmset -g batt 2>/dev/null || true)"
echo "$BATT_OUTPUT" | head -3
if ! echo "$BATT_OUTPUT" | grep -q "AC Power"; then
    echo "HARD FAIL: not on AC power (acceptance requires AC)"
    exit 1
fi
echo "[power] AC power confirmed"

echo "[power] Power assertions (media/sleep relevant):"
pmset -g assertions 2>/dev/null | grep -iE 'mediaplaying|PreventUserIdleSystemSleep|UserIsActive' || echo "(none matching)"

# Asset generation
WEBSPIKE_BUILD="$REPO_ROOT/.build/webspike"
mkdir -p "$WEBSPIKE_BUILD"

for f in index.html style.css app.js; do
    cp "Sources/OnlyWallpapers/web/webspike/$f" "$WEBSPIKE_BUILD/$f"
done

# FIX 8: Generate bg.mp4 with moving color block.
# The drawbox places a 160x160 lime block at y=ih-260, x=(n*16)%(iw-200).
# Version sentinel forces regen when the asset spec changes.
ASSET_VERSION="v3-colorblock"
ASSET_VERSION_FILE="$WEBSPIKE_BUILD/.asset_version"
NEED_REGEN=0
if [[ ! -f "$WEBSPIKE_BUILD/bg.mp4" ]]; then NEED_REGEN=1; fi
if [[ "$(cat "$ASSET_VERSION_FILE" 2>/dev/null || echo '')" != "$ASSET_VERSION" ]]; then NEED_REGEN=1; fi

if [[ $NEED_REGEN -eq 1 ]]; then
    echo "[asset] Generating bg.mp4 with moving color block..."
    ffmpeg -y \
        -f lavfi -i "color=c=navy:size=1920x1080:rate=30" \
        -t 17.3 \
        -vf "drawtext=text='F%{n}':fontsize=200:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:font=monospace,drawtext=text='%{pts}':fontsize=60:fontcolor=yellow:x=(w-text_w)/2:y=80:font=monospace,drawbox=x=t*90:y=820:w=160:h=160:color=lime@1.0:t=fill" \
        -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
        -an \
        "$WEBSPIKE_BUILD/bg.mp4" 2>&1
    echo "$ASSET_VERSION" > "$ASSET_VERSION_FILE"
    echo "[asset] bg.mp4 generated"
fi

# Build
echo "[build] Building with warnings-as-errors..."
swift build --product OnlyWallpapers -Xswiftc -warnings-as-errors 2>&1
BIN="$(swift build --product OnlyWallpapers --show-bin-path)/OnlyWallpapers"
echo "[build] Binary: $BIN"

SCREEN_COUNT=$(python3 -c "import subprocess; r=subprocess.run(['system_profiler','SPDisplaysDataType'],capture_output=True,text=True); print(r.stdout.count('Resolution:'))" 2>/dev/null || echo "1")
echo "[displays] Detected approximately $SCREEN_COUNT display(s)"

# FIX 7: band_diff: fail closed. Targets the moving-block band (bottom horizontal strip).
# Returns 0 (differ), 1 (identical). Calls exit 2 on any INCONCLUSIVE condition.
band_diff() {
    local img1="$1"
    local img2="$2"

    for img in "$img1" "$img2"; do
        if [[ ! -f "$img" ]] || [[ ! -s "$img" ]]; then
            echo "[band_diff] INCONCLUSIVE: missing or zero-byte file: $img"
            exit 2
        fi
    done

    local w h
    w="$(sips -g pixelWidth "$img1" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    h="$(sips -g pixelHeight "$img1" 2>/dev/null | awk '/pixelHeight/{print $2}')"

    if [[ -z "$w" ]] || [[ -z "$h" ]] || [[ "$w" -le 0 ]] || [[ "$h" -le 0 ]]; then
        echo "[band_diff] INCONCLUSIVE: sips could not read dimensions from $img1"
        exit 2
    fi

    # Target the center vertical band where the large frame-counter digits (F%{n},
    # fontsize=200) are drawn. ffmpeg places them at x=(w-text_w)/2:y=(h-text_h)/2,
    # so for 1080p they occupy roughly y=440-640 (41-59% of height). Using 30-70%
    # gives a comfortable margin and catches every frame change with high contrast.
    # This is more reliable than the moving-block band and works even if the asset
    # was generated without the color block.
    local band_y band_h
    band_y=$(( h * 3 / 10 ))
    band_h=$(( h * 2 / 5 ))
    if [[ $band_h -lt 10 ]]; then band_y=0; band_h=$h; fi

    local crop1="${img1%.png}_band.png"
    local crop2="${img2%.png}_band.png"

    if ! sips -c "$band_h" "$w" --cropOffset "$band_y" 0 "$img1" --out "$crop1" >/dev/null 2>&1; then
        echo "[band_diff] INCONCLUSIVE: sips crop failed on $img1"
        exit 2
    fi
    if ! sips -c "$band_h" "$w" --cropOffset "$band_y" 0 "$img2" --out "$crop2" >/dev/null 2>&1; then
        echo "[band_diff] INCONCLUSIVE: sips crop failed on $img2"
        exit 2
    fi

    for crop in "$crop1" "$crop2"; do
        if [[ ! -f "$crop" ]] || [[ ! -s "$crop" ]]; then
            echo "[band_diff] INCONCLUSIVE: crop output missing or empty: $crop"
            exit 2
        fi
    done

    if cmp -s "$crop1" "$crop2"; then
        return 1
    fi
    return 0
}

# FIX 9: Clear-mode transparency check. Not a hard gate on main liveness result.
run_clear_check() {
    echo ""
    echo "=== CLEAR-MODE CHECK ==="
    local CLEAR_TMPOUT_LOCAL
    CLEAR_TMPOUT_LOCAL="$(mktemp)"

    env -u OW_SPIKE \
        -u OW_WEBSPIKE_ACTIVITY \
        OW_WEBSPIKE=1 \
        OW_WEBSPIKE_CLEAR=1 \
        OW_WEBSPIKE_DIR="$WEBSPIKE_BUILD" \
        "$BIN" >"$CLEAR_TMPOUT_LOCAL" 2>&1 &
    CLEAR_PID=$!
    echo "[clear-mode] PID=$CLEAR_PID"

    local seen=0
    for i in $(seq 1 100); do
        if ! kill -0 "$CLEAR_PID" 2>/dev/null; then break; fi
        if grep -q "OW_WEBSPIKE NATIVE" "$CLEAR_TMPOUT_LOCAL" 2>/dev/null; then seen=1; break; fi
        sleep 0.1
    done

    if [[ $seen -ne 1 ]]; then
        echo "CLEAR-MODE: WARNING: no heartbeat received, skipping capture"
        kill "$CLEAR_PID" 2>/dev/null || true
        wait "$CLEAR_PID" 2>/dev/null || true
        CLEAR_PID=""
        rm -f "$CLEAR_TMPOUT_LOCAL"
        return
    fi

    sleep 1

    local DID
    DID="$(grep 'OW_WEBSPIKE NATIVE' "$CLEAR_TMPOUT_LOCAL" 2>/dev/null | head -1 | grep -oE 'did=[0-9]+' | cut -d= -f2 || echo '')"

    local CLEAR_IMG="/tmp/ow-webspike-clear-$$.png"
    if [[ -n "$DID" ]]; then
        screencapture -D "$DID" "$CLEAR_IMG" 2>/dev/null || screencapture "$CLEAR_IMG" 2>/dev/null || true
    else
        screencapture "$CLEAR_IMG" 2>/dev/null || true
    fi

    kill "$CLEAR_PID" 2>/dev/null || true
    wait "$CLEAR_PID" 2>/dev/null || true
    CLEAR_PID=""
    rm -f "$CLEAR_TMPOUT_LOCAL"

    if [[ ! -f "$CLEAR_IMG" ]] || [[ ! -s "$CLEAR_IMG" ]]; then
        echo "CLEAR-MODE: could not capture (TCC denied or no screens)"
        return
    fi

    local W H
    W="$(sips -g pixelWidth "$CLEAR_IMG" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    H="$(sips -g pixelHeight "$CLEAR_IMG" 2>/dev/null | awk '/pixelHeight/{print $2}')"

    local VARIED="unknown"
    if [[ -n "$W" ]] && [[ -n "$H" ]] && [[ "$W" -gt 0 ]] && [[ "$H" -gt 0 ]]; then
        local IW=$(( W / 4 ))
        local IH=$(( H / 10 ))
        local IX=$(( W / 4 ))
        local IY1=$(( H / 3 ))
        local IY2=$(( H * 2 / 3 ))
        local STRIP1="/tmp/ow-clear-strip1-$$.png"
        local STRIP2="/tmp/ow-clear-strip2-$$.png"
        sips -c "$IH" "$IW" --cropOffset "$IY1" "$IX" "$CLEAR_IMG" --out "$STRIP1" 2>/dev/null || true
        sips -c "$IH" "$IW" --cropOffset "$IY2" "$IX" "$CLEAR_IMG" --out "$STRIP2" 2>/dev/null || true
        if [[ -f "$STRIP1" ]] && [[ -s "$STRIP1" ]] && [[ -f "$STRIP2" ]] && [[ -s "$STRIP2" ]]; then
            if cmp -s "$STRIP1" "$STRIP2"; then
                VARIED="no (two interior strips identical, may be uniform)"
            else
                VARIED="yes (two interior strips differ)"
            fi
        fi
        rm -f "$STRIP1" "$STRIP2"
    fi

    echo "CLEAR-MODE: saved $CLEAR_IMG for transparency inspection"
    echo "CLEAR-MODE: interior varied: $VARIED"
}

# Main spike run
run_spike() {
    local label="$1"
    shift
    local extra_env=("$@")

    TMPOUT="$(mktemp)"
    echo "[launch:$label] Starting OW_WEBSPIKE=1..."

    if [[ ${#extra_env[@]} -gt 0 ]]; then
        env -u OW_SPIKE \
            OW_WEBSPIKE=1 \
            OW_WEBSPIKE_DIR="$WEBSPIKE_BUILD" \
            "${extra_env[@]}" \
            "$BIN" >"$TMPOUT" 2>&1 &
    else
        env -u OW_SPIKE \
            -u OW_WEBSPIKE_ACTIVITY \
            OW_WEBSPIKE=1 \
            OW_WEBSPIKE_DIR="$WEBSPIKE_BUILD" \
            "$BIN" >"$TMPOUT" 2>&1 &
    fi
    PID=$!
    echo "[launch:$label] PID=$PID"

    # Wait for first NATIVE heartbeat (up to 20s)
    echo "[baseline:$label] Waiting for first NATIVE heartbeat..."
    local NATIVE_SEEN=0
    for i in $(seq 1 200); do
        if ! kill -0 "$PID" 2>/dev/null; then
            echo "FAIL[$label]: process exited before first heartbeat"
            cat "$TMPOUT" || true
            return 1
        fi
        if grep -q "OW_WEBSPIKE NATIVE" "$TMPOUT" 2>/dev/null; then
            NATIVE_SEEN=1
            break
        fi
        sleep 0.1
    done
    if [[ $NATIVE_SEEN -ne 1 ]]; then
        echo "FAIL[$label]: no NATIVE heartbeat within 20s"
        cat "$TMPOUT" || true
        return 1
    fi
    echo "[baseline:$label] First NATIVE heartbeat seen"

    # Wait for first JS telemetry
    echo "[baseline:$label] Waiting for JS telemetry..."
    local JS_SEEN=0
    for i in $(seq 1 100); do
        if grep -q "OW_WEBSPIKE JS" "$TMPOUT" 2>/dev/null; then
            JS_SEEN=1
            break
        fi
        sleep 0.1
    done
    if [[ $JS_SEEN -ne 1 ]]; then
        echo "WARNING[$label]: no JS telemetry within 10s (continuing)"
    else
        echo "[baseline:$label] JS telemetry seen"
    fi

    # Assert media reaches playing within 15s
    echo "[baseline:$label] Checking media state..."
    local MEDIA_PLAYING=0
    for i in $(seq 1 30); do
        if grep -q "media=playing" "$TMPOUT" 2>/dev/null; then
            MEDIA_PLAYING=1
            break
        fi
        sleep 0.5
    done
    if [[ $MEDIA_PLAYING -ne 1 ]]; then
        echo "WARNING[$label]: media=playing not seen within 15s"
    else
        echo "[baseline:$label] media=playing confirmed"
    fi

    # FIX 1: Parse distinct win= values (one per did=) from NATIVE heartbeats.
    # Give heartbeats a moment to accumulate one per screen (each fires at 1s intervals).
    sleep 2
    ALL_WINS=()
    while IFS= read -r line; do
        ALL_WINS+=("$line")
    done < <(grep 'OW_WEBSPIKE NATIVE' "$TMPOUT" 2>/dev/null | grep -oE 'win=[0-9]+' | sort -u | cut -d= -f2)
    echo "[baseline:$label] Windows detected: ${ALL_WINS[*]:-none}"

    if [[ ${#ALL_WINS[@]} -eq 0 ]]; then
        echo "FAIL[$label]: no windows parsed from heartbeats"
        return 1
    fi

    # FIX A: Check ZORDER ok= per window. The app emits
    # "OW_WEBSPIKE ZORDER win=<n> layer=<l> ok=<true|false>" at startup.
    # This asserts the ACTUAL WindowServer layer is below the desktop-icon level.
    # Keep the level=-2147483623 heartbeat check below as a second gate.
    WIN_ZORDER_OK=()
    ZORDER_FAIL=0
    for i in "${!ALL_WINS[@]}"; do
        local win="${ALL_WINS[$i]}"
        local ZORDER_LINE
        ZORDER_LINE="$(grep "OW_WEBSPIKE ZORDER win=$win " "$TMPOUT" 2>/dev/null | tail -1)"
        local ZORDER_OK_VAL
        ZORDER_OK_VAL="$(echo "$ZORDER_LINE" | grep -oE 'ok=(true|false)' | cut -d= -f2)"
        if [[ "$ZORDER_OK_VAL" == "true" ]]; then
            WIN_ZORDER_OK[$i]=1
        else
            WIN_ZORDER_OK[$i]=0
            ZORDER_FAIL=1
            echo "HARD FAIL[$label]: win=$win z-order not confirmed below icon layer"
        fi
    done

    # FIX 1: Baseline pixel check per window. No full-display fallback as PASS.
    # If screencapture -l fails for a window: INCONCLUSIVE (exit 2), never PASS.
    WIN_BASE_OK=()
    for i in "${!ALL_WINS[@]}"; do
        local win="${ALL_WINS[$i]}"
        local BASE_A="/tmp/ow-webspike-base-a-${label}-${win}.png"
        local BASE_B="/tmp/ow-webspike-base-b-${label}-${win}.png"
        local CAP_OK=0
        if screencapture -l "$win" "$BASE_A" 2>/dev/null; then
            sleep 1
            if screencapture -l "$win" "$BASE_B" 2>/dev/null; then
                CAP_OK=1
            fi
        fi
        if [[ $CAP_OK -ne 1 ]]; then
            echo "INCONCLUSIVE[$label]: screencapture -l $win failed (TCC or permission)"
            exit 2
        fi
        if band_diff "$BASE_A" "$BASE_B"; then
            WIN_BASE_OK[$i]=1
            echo "[baseline:$label] PASS: win=$win baseline band differs (video animating)"
        else
            WIN_BASE_OK[$i]=0
            echo "HARD FAIL[$label]: win=$win baseline band identical (video not animating)"
        fi
    done

    # Snapshot counters and frame count before watch
    local JS_LINES_BEFORE
    JS_LINES_BEFORE="$(grep 'OW_WEBSPIKE JS' "$TMPOUT" 2>/dev/null | wc -l | tr -d ' \t')"
    local NATIVE_LINES_BEFORE
    NATIVE_LINES_BEFORE="$(grep 'OW_WEBSPIKE NATIVE' "$TMPOUT" 2>/dev/null | wc -l | tr -d ' \t')"
    local FRAMES_BEFORE
    FRAMES_BEFORE="$(grep 'OW_WEBSPIKE JS' "$TMPOUT" 2>/dev/null | tail -1 | grep -oE 'presentedFrames=[0-9]+' | head -1 | cut -d= -f2 | tr -d ' \t')"
    [[ -z "$FRAMES_BEFORE" ]] && FRAMES_BEFORE=0

    echo "[occlude:$label] Using ambient occlusion from existing windows (no app launched). Ensure at least one normal window covers the wallpaper."

    # Heartbeat-gap gate scoped to the WATCH interval only.
    # Walk 1s at a time and track when heartbeats arrive.
    # Per-window occ=false sample counts (index-parallel to ALL_WINS).
    WIN_OCC_FALSE=()
    for wi in "${!ALL_WINS[@]}"; do
        WIN_OCC_FALSE[$wi]=0
    done

    echo "[watch:$label] Sleeping 125s (1s steps, gap-monitoring heartbeats)..."
    local PREV_HB_COUNT
    PREV_HB_COUNT="$(grep 'OW_WEBSPIKE NATIVE' "$TMPOUT" 2>/dev/null | wc -l | tr -d ' \t')"
    local LAST_HB_WALL=$SECONDS
    local MAX_HB_GAP=0
    local OCC_FALSE_SEEN=0
    local WEBCONTENT_FAIL=0

    for i in $(seq 1 125); do
        sleep 1
        local CURR_COUNT
        CURR_COUNT="$(grep 'OW_WEBSPIKE NATIVE' "$TMPOUT" 2>/dev/null | wc -l | tr -d ' \t')"
        if [[ $CURR_COUNT -gt $PREV_HB_COUNT ]]; then
            local SINCE=$(( SECONDS - LAST_HB_WALL ))
            if [[ $SINCE -gt $MAX_HB_GAP ]]; then MAX_HB_GAP=$SINCE; fi
            PREV_HB_COUNT=$CURR_COUNT
            LAST_HB_WALL=$SECONDS
        fi
        # Per-window occ=false tracking (occ=false: window is occluded by another window)
        for wi in "${!ALL_WINS[@]}"; do
            if grep 'OW_WEBSPIKE NATIVE' "$TMPOUT" 2>/dev/null | grep "win=${ALL_WINS[$wi]} " | tail -1 | grep -q 'occ=false'; then
                WIN_OCC_FALSE[$wi]=$(( WIN_OCC_FALSE[$wi] + 1 ))
            fi
        done
        if grep -q "OW_WEBSPIKE EVENT=webcontent_terminated" "$TMPOUT" 2>/dev/null; then
            WEBCONTENT_FAIL=1
            break
        fi
    done

    if [[ $WEBCONTENT_FAIL -eq 1 ]]; then
        echo "HARD FAIL[$label]: webcontent_terminated event during watch"
        return 1
    fi

    # Count gap from last heartbeat to end of watch
    local TAIL_GAP=$(( SECONDS - LAST_HB_WALL ))
    if [[ $TAIL_GAP -gt $MAX_HB_GAP ]]; then MAX_HB_GAP=$TAIL_GAP; fi

    echo "[watch:$label] 125s watch complete. max heartbeat gap during watch: ${MAX_HB_GAP}s"

    local HEARTBEAT_GAP_FAIL=0
    if [[ $MAX_HB_GAP -gt 3 ]]; then
        HEARTBEAT_GAP_FAIL=1
        echo "HARD FAIL[$label]: heartbeat gap ${MAX_HB_GAP}s during watch (threshold: 3s)"
    fi

    # Ambient occlusion gate: at least one window must have accumulated >= 30 occ=false
    # samples during the watch. Fewer means the desktop was bare (nothing covering the
    # wallpaper), which makes the end-of-watch pixel diff inconclusive.
    local ANY_OCC_COVERED=0
    for wi in "${!ALL_WINS[@]}"; do
        if [[ "${WIN_OCC_FALSE[$wi]:-0}" -ge 30 ]]; then
            ANY_OCC_COVERED=1
            OCC_FALSE_SEEN=1
            break
        fi
    done
    if [[ $ANY_OCC_COVERED -ne 1 ]]; then
        echo "INCONCLUSIVE: no occlusion observed during the watch. Put any app window over the wallpaper (do not clear your desktop) and rerun."
        exit 2
    fi

    # FIX 5: Assert level and active predicates from last watch-period heartbeat per window.
    # Extract watch-period native lines only.
    local NATIVE_WATCH_LINES
    NATIVE_WATCH_LINES="$(grep 'OW_WEBSPIKE NATIVE' "$TMPOUT" 2>/dev/null | sed -n "$((NATIVE_LINES_BEFORE + 1)),\$p")"

    WIN_LEVEL_OK=()
    WIN_ACTIVE_OK=()
    local LEVEL_FAIL=0
    local ACTIVE_FAIL=0

    for i in "${!ALL_WINS[@]}"; do
        local win="${ALL_WINS[$i]}"
        local LAST_HB
        LAST_HB="$(echo "$NATIVE_WATCH_LINES" | grep "win=$win " | tail -1)"
        if [[ -z "$LAST_HB" ]]; then
            echo "WARNING[$label]: no watch heartbeat found for win=$win"
            WIN_LEVEL_OK[$i]=0
            WIN_ACTIVE_OK[$i]=0
            continue
        fi
        local LVL
        LVL="$(echo "$LAST_HB" | grep -oE 'level=-?[0-9]+' | cut -d= -f2)"
        local ACT
        ACT="$(echo "$LAST_HB" | grep -oE 'active=(true|false)' | cut -d= -f2)"

        if [[ "$LVL" == "-2147483623" ]]; then
            WIN_LEVEL_OK[$i]=1
        else
            WIN_LEVEL_OK[$i]=0
            LEVEL_FAIL=1
            echo "HARD FAIL[$label]: win=$win level=$LVL (expected -2147483623)"
        fi

        if [[ "$ACT" == "false" ]]; then
            WIN_ACTIVE_OK[$i]=1
        else
            WIN_ACTIVE_OK[$i]=0
            ACTIVE_FAIL=1
            echo "HARD FAIL[$label]: win=$win active=$ACT during covered run (expected false)"
        fi
    done

    # RVFC floor: compute before end-of-watch pixel check because occlusion-aware
    # classification uses JS_FRAMES_OK to decide if a stale backing store is expected.
    local FRAMES_AFTER
    FRAMES_AFTER="$(grep 'OW_WEBSPIKE JS' "$TMPOUT" 2>/dev/null | tail -1 | grep -oE 'presentedFrames=[0-9]+' | head -1 | cut -d= -f2 | tr -d ' \t')"
    [[ -z "$FRAMES_AFTER" ]] && FRAMES_AFTER=0
    local FRAMES_DELTA=$(( FRAMES_AFTER - FRAMES_BEFORE ))
    local JS_FRAMES_OK=0
    if [[ $FRAMES_DELTA -ge 1800 ]]; then
        JS_FRAMES_OK=1
    else
        echo "HARD FAIL[$label]: JS presentedFrames delta=$FRAMES_DELTA (required >= 1800 for 125s at 15fps)"
    fi

    # No 10s window with zero new frames (HARD GATE).
    local WATCH_JS_DATA
    WATCH_JS_DATA="$(grep 'OW_WEBSPIKE JS' "$TMPOUT" 2>/dev/null | sed -n "$((JS_LINES_BEFORE + 1)),\$p")"
    local FROZEN_10S
    FROZEN_10S="$(echo "$WATCH_JS_DATA" | awk '
BEGIN { prev_pf = -999; prev_t = -999; frozen_start_t = -999 }
{
    pf = -999; t = -999
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^presentedFrames=/) { split($i, a, "="); pf = a[2]+0 }
        if ($i ~ /^t=/)               { split($i, a, "="); t = a[2]+0 }
    }
    if (pf == -999 || t == -999) next
    if (pf == prev_pf) {
        if (frozen_start_t < 0) frozen_start_t = prev_t
        if (t - frozen_start_t >= 10) { print "FROZEN_10S"; exit }
    } else {
        frozen_start_t = -999
    }
    prev_pf = pf
    prev_t = t
}
' 2>/dev/null || echo '')"
    local FROZEN_OK=1
    if [[ "$FROZEN_10S" == "FROZEN_10S" ]]; then
        FROZEN_OK=0
        echo "HARD FAIL[$label]: 10s zero-frame window detected in JS telemetry during watch"
    fi

    # End-of-watch pixel check per window. Occlusion-aware 3-state classification:
    #   1 = PASS          band differs (video advancing, visible rendering confirmed).
    #   2 = EXPECTED-OCCLUDED  band identical, but window was fully occluded
    #                     (WIN_OCC_FALSE >= 30) AND JS pipeline is live (JS_FRAMES_OK)
    #                     AND media=playing: macOS occlusion culling stops compositing
    #                     a 100%-hidden window, so a stale backing store is normal.
    #   0 = FAIL          band identical while window was not fully occluded
    #                     (visible-but-frozen).
    # No fallback to full-display: if -l fails, INCONCLUSIVE (exit 2).
    WIN_END_OK=()
    local ANY_WIN_END_PASS=0
    local ANY_WIN_END_FAIL=0
    for i in "${!ALL_WINS[@]}"; do
        local win="${ALL_WINS[$i]}"
        local END_A="/tmp/ow-webspike-end-a-${label}-${win}.png"
        local END_B="/tmp/ow-webspike-end-b-${label}-${win}.png"
        local CAP_OK=0
        if screencapture -l "$win" "$END_A" 2>/dev/null; then
            sleep 1
            if screencapture -l "$win" "$END_B" 2>/dev/null; then
                CAP_OK=1
            fi
        fi
        if [[ $CAP_OK -ne 1 ]]; then
            echo "INCONCLUSIVE[$label]: screencapture -l $win failed at end-of-watch (TCC or permission)"
            exit 2
        fi
        if band_diff "$END_A" "$END_B"; then
            WIN_END_OK[$i]=1
            ANY_WIN_END_PASS=1
            echo "[occlude:$label] PASS: win=$win end-of-watch band differs (video advancing)"
        else
            local WIN_OCC_COUNT="${WIN_OCC_FALSE[$i]:-0}"
            if [[ $WIN_OCC_COUNT -ge 30 ]] && [[ $JS_FRAMES_OK -eq 1 ]] && [[ $MEDIA_PLAYING -eq 1 ]]; then
                WIN_END_OK[$i]=2
                echo "FINDING: win=$win backing store stale while fully occluded (expected macOS occlusion culling); video pipeline live per RVFC and media=playing."
            else
                WIN_END_OK[$i]=0
                ANY_WIN_END_FAIL=1
                echo "HARD FAIL[$label]: win=$win visible window frozen (band identical while not occluded)"
            fi
        fi
    done

    # Per-display VERDICT TABLE
    echo ""
    echo "=== VERDICT TABLE [$label] ==="
    printf "%-54s %s\n" "AC power" "PASS"
    for i in "${!ALL_WINS[@]}"; do
        local win="${ALL_WINS[$i]}"
        local END_STATUS
        case "${WIN_END_OK[$i]:-0}" in
            1) END_STATUS="PASS" ;;
            2) END_STATUS="EXPECTED-OCCLUDED" ;;
            *) END_STATUS="FAIL" ;;
        esac
        printf "%-54s %s\n" "baseline band liveness             win=$win" \
            "$([ "${WIN_BASE_OK[$i]:-0}" -eq 1 ] && echo PASS || echo FAIL)"
        printf "%-54s %s\n" "end-of-watch band liveness         win=$win" \
            "$END_STATUS"
        printf "%-54s %s\n" "level=-2147483623                  win=$win" \
            "$([ "${WIN_LEVEL_OK[$i]:-0}" -eq 1 ] && echo PASS || echo FAIL)"
        printf "%-54s %s\n" "z-order below icon layer (ZORDER ok=true) win=$win" \
            "$([ "${WIN_ZORDER_OK[$i]:-0}" -eq 1 ] && echo PASS || echo FAIL)"
        printf "%-54s %s\n" "active=false (covered run)         win=$win" \
            "$([ "${WIN_ACTIVE_OK[$i]:-0}" -eq 1 ] && echo PASS || echo FAIL)"
    done
    printf "%-54s %s\n" "heartbeat gap <= 3s (watch-scoped)" \
        "$([ $MAX_HB_GAP -le 3 ] && echo PASS || echo "FAIL (max=${MAX_HB_GAP}s)")"
    printf "%-54s %s\n" "ambient occ=false (>=30s, at least one win)" \
        "$([ $OCC_FALSE_SEEN -eq 1 ] && echo PASS || echo WARN)"
    printf "%-54s %s\n" "JS frames delta >= 1800 (125s occluded watch)" \
        "$([ $JS_FRAMES_OK -eq 1 ] && echo PASS || echo "FAIL (delta=$FRAMES_DELTA)")"
    printf "%-54s %s\n" "no 10s zero-frame window" \
        "$([ $FROZEN_OK -eq 1 ] && echo PASS || echo FAIL)"
    printf "%-54s %s\n" "media=playing seen" \
        "$([ $MEDIA_PLAYING -eq 1 ] && echo PASS || echo "FAIL (not seen)")"
    printf "%-54s %s\n" "at least one window visible and animating" \
        "$([ $ANY_WIN_END_PASS -eq 1 ] && echo PASS || echo FAIL)"
    echo ""

    # Aggregate: all HARD gates must pass.
    # EXPECTED-OCCLUDED windows (WIN_END_OK=2) are not a fail.
    # At least one window must have a differing end-of-watch band (ANY_WIN_END_PASS=1),
    # proving actual on-glass rendering. Any visible-but-frozen window (WIN_END_OK=0)
    # is a real freeze and hard-fails the run.
    local ALL_PASS=1

    for i in "${!ALL_WINS[@]}"; do
        if [[ "${WIN_BASE_OK[$i]:-0}" -ne 1 ]]; then ALL_PASS=0; fi
        if [[ "${WIN_LEVEL_OK[$i]:-0}" -ne 1 ]]; then ALL_PASS=0; fi
        if [[ "${WIN_ZORDER_OK[$i]:-0}" -ne 1 ]]; then ALL_PASS=0; fi
        if [[ "${WIN_ACTIVE_OK[$i]:-0}" -ne 1 ]]; then ALL_PASS=0; fi
    done

    if [[ $ANY_WIN_END_FAIL -ne 0 ]]; then ALL_PASS=0; fi
    if [[ $ANY_WIN_END_PASS -ne 1 ]]; then ALL_PASS=0; fi
    if [[ $HEARTBEAT_GAP_FAIL -ne 0 ]]; then ALL_PASS=0; fi
    if [[ $JS_FRAMES_OK -ne 1 ]]; then ALL_PASS=0; fi
    if [[ $FROZEN_OK -ne 1 ]]; then ALL_PASS=0; fi
    if [[ $MEDIA_PLAYING -ne 1 ]]; then ALL_PASS=0; fi
    if [[ $LEVEL_FAIL -ne 0 ]]; then ALL_PASS=0; fi
    if [[ $ACTIVE_FAIL -ne 0 ]]; then ALL_PASS=0; fi

    if [[ $ALL_PASS -eq 1 ]]; then
        return 0
    else
        return 1
    fi
}

# Primary run (no activity token, App Nap may apply)
PRIMARY_PASS=0
if run_spike "primary"; then
    PRIMARY_PASS=1
fi

# Kill primary process
if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -INT "$PID" 2>/dev/null || true
    sleep 0.4
    if kill -0 "$PID" 2>/dev/null; then
        kill -KILL "$PID" 2>/dev/null || true
    fi
    wait "$PID" 2>/dev/null || true
fi
PID=""

# Control run if primary failed
CTRL_PASS=0
if [[ $PRIMARY_PASS -ne 1 ]]; then
    echo ""
    echo "=== Primary run FAILED. Running control with OW_WEBSPIKE_ACTIVITY=1 ==="
    CTRL_TMPOUT="$TMPOUT"
    PID=""
    TMPOUT=""
    if run_spike "control" "OW_WEBSPIKE_ACTIVITY=1"; then
        CTRL_PASS=1
    fi
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 0.4
        kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""

    echo ""
    echo "=== TWO-RUN SUMMARY ==="
    printf "%-20s %s\n" "primary (no token)" "$([ $PRIMARY_PASS -eq 1 ] && echo PASS || echo FAIL)"
    printf "%-20s %s\n" "control (token held)" "$([ $CTRL_PASS -eq 1 ] && echo PASS || echo FAIL)"

    if [[ $CTRL_PASS -eq 1 ]] && [[ $PRIMARY_PASS -ne 1 ]]; then
        echo "FINDING: App Nap is suppressing frame presentation. Activity token fixes it."
    fi
fi

# FIX 9: Clear-mode transparency check (informational, does not affect PASS/FAIL)
run_clear_check

# FIX 10: Final verdict. PASS only if every HARD gate passed for every window.
if [[ $PRIMARY_PASS -eq 1 ]]; then
    echo ""
    echo "WEBSPIKE-CHECK: PASS"
    exit 0
else
    echo ""
    echo "WEBSPIKE-CHECK: FAIL"
    exit 1
fi
