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

# Info.plist is forbidden in all Swift files.
HITS_FORBIDDEN="$(grep -rnE 'Info\.plist' Sources/ --include='*.swift' || true)"
if [ -n "$HITS_FORBIDDEN" ]; then echo "FAIL: Info.plist reference found in Sources/"; echo "$HITS_FORBIDDEN"; exit 1; fi

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

# --- Step 8c: web file shape guards (shape-only; not a playback gate; TCC-free) ---
echo "[shape] Checking web file structure..."
WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web"
SHAPE_FAIL=0

check_contains() {
    local file="$1" pattern="$2" label="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL [shape]: $label not found in $file"
        SHAPE_FAIL=1
    fi
}

check_contains "$WEB_DIR/index.html" 'id="bg"'           'id="bg"'
check_contains "$WEB_DIR/index.html" 'muted'              'muted attribute'
check_contains "$WEB_DIR/index.html" 'loop'               'loop attribute'
check_contains "$WEB_DIR/index.html" 'playsinline'        'playsinline attribute'
check_contains "$WEB_DIR/index.html" 'src="assets/bg\.mp4"' 'src="assets/bg.mp4"'
check_contains "$WEB_DIR/index.html" '<canvas'            '<canvas element'
check_contains "$WEB_DIR/index.html" 'wallpaper\.js'      'wallpaper.js reference'
check_contains "$WEB_DIR/index.html" 'style\.css'         'style.css reference'
check_contains "$WEB_DIR/style.css"  'object-fit'         'object-fit in style.css'
check_contains "$WEB_DIR/style.css"  'filter'             'filter in style.css'
check_contains "$WEB_DIR/style.css"  '#bg'                '#bg in style.css'
check_contains "$WEB_DIR/wallpaper.js" 'video\.play'      'video.play in wallpaper.js'
check_contains "$WEB_DIR/wallpaper.js" '__wallpaper'       '__wallpaper in wallpaper.js'
check_contains "$WEB_DIR/wallpaper.js" 'stage\.style'      'stage.style in wallpaper.js'
check_contains "$WEB_DIR/style.css"    'position.*fixed'   'position: fixed in style.css'

if [[ $SHAPE_FAIL -ne 0 ]]; then
    exit 1
fi
echo "[shape] PASS: all web file shape guards satisfied"

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
OW_SUPPORT_TMP=""
# NON-BLOCKING 1: combine both cleanup actions in one trap so a failure still kills PID.
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
    [[ -n "$OW_SUPPORT_TMP" ]] && rm -rf "$OW_SUPPORT_TMP" || true
}
trap cleanup EXIT

# --- Step 3: launch binary in background ---
echo "[launch] Starting $BIN..."
OW_SUPPORT_TMP="$(mktemp -d)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON "$BIN" >"$TMPOUT" 2>&1 &
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

# --- Step 6b: verify web dir resolved from appstore (no env override) ---
echo "[resolve] Checking ONLYWALLPAPERS_WEB_RESOLVE status=ok source=appstore..."
RESOLVE_LINE="$(grep 'ONLYWALLPAPERS_WEB_RESOLVE' "$TMPOUT" | head -1 || true)"
if [ -z "$RESOLVE_LINE" ]; then
    echo "FAIL: ONLYWALLPAPERS_WEB_RESOLVE line never appeared"
    echo "--- output ---"
    cat "$TMPOUT" || true
    exit 1
fi
if ! echo "$RESOLVE_LINE" | grep -Eq 'status=ok source=appstore( |$)'; then
    echo "FAIL: expected status=ok source=appstore, got: $RESOLVE_LINE"
    echo "--- output ---"
    cat "$TMPOUT" || true
    exit 1
fi
echo "[resolve] PASS: $RESOLVE_LINE"

# --- Step 7a: verify WallpaperWindow placement (default run only) ---
echo "[windows] Checking ONLYWALLPAPERS_WINDOWS count line..."
WINDOWS_LINE="$(grep "ONLYWALLPAPERS_WINDOWS count=" "$TMPOUT" | grep 'gen=0' | head -1 || true)"
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
        WEB_OK_COUNT="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT" 2>/dev/null || true)"
        if [ "$WEB_OK_COUNT" -ge "$SCREEN_COUNT" ]; then
            WEB_OK=1
            break
        fi
        sleep 0.1
    done

    if [ "$WEB_OK" -ne 1 ]; then
        echo "FAIL: expected $SCREEN_COUNT ONLYWALLPAPERS_WEB loaded=ok gen=0 line(s), got fewer within 8s"
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

    # Verify N distinct win= values in loaded=ok gen=0 lines (poll a bit more to let stragglers arrive).
    # win= is always unique per window; screen= names can collide on identical monitors.
    DISTINCT_OK=0
    for i in $(seq 1 20); do
        DISTINCT_WINS_WEB="$(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT" \
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
        echo "FAIL: expected $SCREEN_COUNT distinct win= value(s) in loaded=ok gen=0 lines, found $DISTINCT_WINS_WEB"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    # (b) Parse frame=WxH from every loaded=ok gen=0 line; require W > 100 and H > 100.
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
    done < <(grep -E 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT")
    if [ "$FRAME_BAD" -ne 0 ]; then
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    echo "[webload] PASS: $SCREEN_COUNT loaded=ok gen=0 line(s) with distinct win= values, no loaded=fail, all frames >100x100"
fi

# --- Step 7d: geometry oracle (SLICE lines) ---
echo "[geo] Checking ONLYWALLPAPERS_SLICE geometry oracle..."
if [ "$SCREEN_COUNT" -eq 0 ]; then
    echo "[geo] PASS: count=0, no SLICE assertions needed"
else
    # Poll up to 2s for SLICE lines (emitted synchronously in build(), should already be present by now).
    for i in $(seq 1 20); do
        SLICE_COUNT="$(grep "^ONLYWALLPAPERS_SLICE " "$TMPOUT" 2>/dev/null | grep -c 'gen=0' || true)"
        if [ "$SLICE_COUNT" -ge "$SCREEN_COUNT" ]; then
            break
        fi
        sleep 0.1
    done

    GEO_OUT="$(awk '
BEGIN { n = 0; sc = 0; eps = 0.5; fail = 0 }

/^ONLYWALLPAPERS_WINDOWS count=/ {
    if ($0 !~ /gen=0( |$)/) next
    split($2, a, "="); n = int(a[2])
}

/^ONLYWALLPAPERS_SLICE / {
    if ($0 !~ /gen=0( |$)/) next
    sc++
    split($2, a, "="); did = a[2]
    split($3, a, "="); win = a[2]
    split($4, a, "="); split(a[2], b, ","); fx=b[1]+0; fy=b[2]+0; fw=b[3]+0; fh=b[4]+0
    split($5, a, "="); sw = a[2]+0
    split($6, a, "="); sh = a[2]+0
    split($7, a, "="); ox = a[2]+0
    split($8, a, "="); oy = a[2]+0
    did_arr[sc] = did
    win_arr[sc] = win
    fx_arr[sc] = fx; fy_arr[sc] = fy; fw_arr[sc] = fw; fh_arr[sc] = fh
    sw_arr[sc] = sw; sh_arr[sc] = sh
    ox_arr[sc] = ox; oy_arr[sc] = oy
    slice_lines[sc] = $0
    dids[did]++
    if (sc == 1) {
        ref_sw = sw; ref_sh = sh
        union_minX = fx; union_minY = fy; union_maxX = fx+fw; union_maxY = fy+fh
    } else {
        if (fx < union_minX) union_minX = fx
        if (fy < union_minY) union_minY = fy
        if (fx+fw > union_maxX) union_maxX = fx+fw
        if (fy+fh > union_maxY) union_maxY = fy+fh
    }
}

/ONLYWALLPAPERS_WEB.*loaded=ok/ {
    if ($0 !~ /gen=0( |$)/) next
    webwin = ""; webframe = ""
    for (i = NF; i >= 1; i--) {
        if ($i ~ /^win=/ && webwin == "") { split($i, a, "="); webwin = a[2] }
        if ($i ~ /^frame=/ && webframe == "") { webframe = $i }
    }
    if (webwin != "" && webframe != "") {
        split(webframe, a, "="); split(a[2], b, "x"); web_w[webwin] = b[1]+0; web_h[webwin] = b[2]+0
    }
}

END {
    if (sc != n) { printf "FAIL [geo]: expected %d SLICE lines, found %d\n", n, sc; fail = 1 }
    ndids = 0; for (d in dids) ndids++
    if (ndids != n) { printf "FAIL [geo]: expected %d distinct did= values, found %d\n", n, ndids; fail = 1 }
    if (sc == 0) { if (!fail) print "PASS [geo]: N=0, no SLICE assertions needed"; exit fail }
    for (i = 1; i <= sc; i++) {
        diff = sw_arr[i] - ref_sw; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: stageW mismatch slice %d: %.4f vs %.4f: %s\n", i, sw_arr[i], ref_sw, slice_lines[i]; fail = 1 }
        diff = sh_arr[i] - ref_sh; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: stageH mismatch slice %d: %.4f vs %.4f: %s\n", i, sh_arr[i], ref_sh, slice_lines[i]; fail = 1 }
    }
    union_w = union_maxX - union_minX; union_h = union_maxY - union_minY
    diff = ref_sw - union_w; if (diff < 0) diff = -diff
    if (diff > eps) { printf "FAIL [geo]: stageW %.4f != recomputed union_w %.4f\n", ref_sw, union_w; fail = 1 }
    diff = ref_sh - union_h; if (diff < 0) diff = -diff
    if (diff > eps) { printf "FAIL [geo]: stageH %.4f != recomputed union_h %.4f\n", ref_sh, union_h; fail = 1 }
    min_ox = ox_arr[1]; min_oy = oy_arr[1]
    for (i = 1; i <= sc; i++) {
        expected_ox = fx_arr[i] - union_minX
        expected_oy = union_maxY - (fy_arr[i] + fh_arr[i])
        diff = ox_arr[i] - expected_ox; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: slice %d offX %.4f != expected %.4f: %s\n", i, ox_arr[i], expected_ox, slice_lines[i]; fail = 1 }
        diff = oy_arr[i] - expected_oy; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: slice %d offY %.4f != expected %.4f (union_maxY=%.4f fy=%.4f fh=%.4f): %s\n", i, oy_arr[i], expected_oy, union_maxY, fy_arr[i], fh_arr[i], slice_lines[i]; fail = 1 }
        if (ox_arr[i] < min_ox) min_ox = ox_arr[i]
        if (oy_arr[i] < min_oy) min_oy = oy_arr[i]
    }
    diff = min_ox; if (diff < 0) diff = -diff
    if (diff > eps) { printf "FAIL [geo]: min(offX) = %.4f, expected 0\n", min_ox; fail = 1 }
    diff = min_oy; if (diff < 0) diff = -diff
    if (diff > eps) { printf "FAIL [geo]: min(offY) = %.4f, expected 0\n", min_oy; fail = 1 }
    if (n == 1) {
        diff = sw_arr[1] - fw_arr[1]; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: N=1 stageW %.4f != frame_w %.4f\n", sw_arr[1], fw_arr[1]; fail = 1 }
        diff = sh_arr[1] - fh_arr[1]; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: N=1 stageH %.4f != frame_h %.4f\n", sh_arr[1], fh_arr[1]; fail = 1 }
        diff = ox_arr[1]; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: N=1 offX %.4f != 0\n", ox_arr[1]; fail = 1 }
        diff = oy_arr[1]; if (diff < 0) diff = -diff
        if (diff > eps) { printf "FAIL [geo]: N=1 offY %.4f != 0\n", oy_arr[1]; fail = 1 }
    }
    for (i = 1; i <= sc; i++) {
        win = win_arr[i]
        if (win in web_w) {
            diff = fw_arr[i] - web_w[win]; if (diff < 0) diff = -diff
            if (diff > eps) { printf "FAIL [geo]: win=%s SLICE frame_w=%.4f != web frame_w=%d: %s\n", win, fw_arr[i], web_w[win], slice_lines[i]; fail = 1 }
            diff = fh_arr[i] - web_h[win]; if (diff < 0) diff = -diff
            if (diff > eps) { printf "FAIL [geo]: win=%s SLICE frame_h=%.4f != web frame_h=%d: %s\n", win, fh_arr[i], web_h[win], slice_lines[i]; fail = 1 }
        } else {
            printf "FAIL [geo]: win=%s from SLICE has no loaded=ok web line\n", win; fail = 1
        }
    }
    if (!fail) printf "PASS [geo]: geometry oracle passed for %d display(s)\n", n
    exit fail
}
' "$TMPOUT")"
    GEO_EXIT=$?
    echo "$GEO_OUT"
    if [ $GEO_EXIT -ne 0 ] || echo "$GEO_OUT" | grep -q "^FAIL"; then
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi
fi

# --- Step 7e: applied oracle (geometry injected AND applied by wallpaper.js) ---
echo "[applied] Checking ONLYWALLPAPERS_WEB applied lines (up to 3s)..."
if [ "$SCREEN_COUNT" -eq 0 ]; then
    echo "[applied] PASS: count=0, no applied assertions needed"
else
    # Poll up to 3s for N applied lines.
    for i in $(seq 1 30); do
        APPLIED_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB applied win=' "$TMPOUT" 2>/dev/null || true)"
        if [ "$APPLIED_COUNT" -ge "$SCREEN_COUNT" ]; then
            break
        fi
        sleep 0.1
    done

    # Hard fail on any applied=fail line before running awk.
    FAIL_APPLIED="$(grep 'ONLYWALLPAPERS_WEB applied win=' "$TMPOUT" | grep 'applied=fail' || true)"
    if [ -n "$FAIL_APPLIED" ]; then
        echo "FAIL: applied=fail found in applied lines:"
        echo "$FAIL_APPLIED"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi

    APPLIED_OUT="$(awk '
BEGIN { n = 0; eps = 0.5; fail = 0 }

/^ONLYWALLPAPERS_WINDOWS count=/ {
    if ($0 !~ /gen=0( |$)/) next
    split($2, a, "="); n = int(a[2])
}

/^ONLYWALLPAPERS_SLICE / {
    if ($0 !~ /gen=0( |$)/) next
    split($3, a, "="); win = a[2]
    split($5, a, "="); sw = a[2]+0
    split($6, a, "="); sh = a[2]+0
    split($7, a, "="); ox = a[2]+0
    split($8, a, "="); oy = a[2]+0
    slice_exists[win] = 1
    slice_ox[win] = ox
    slice_oy[win] = oy
    slice_sw[win] = sw
    slice_sh[win] = sh
}

/ONLYWALLPAPERS_WEB applied win=/ {
    if ($0 ~ /applied=fail/) next
    if ($0 !~ /gen=0( |$)/) next
    split($3, a, "="); win = a[2]
    split($4, a, "="); l = a[2]+0
    split($5, a, "="); t = a[2]+0
    split($6, a, "="); w = a[2]+0
    split($7, a, "="); h = a[2]+0
    applied_wins[win] = 1
    applied_l[win] = l
    applied_t[win] = t
    applied_w[win] = w
    applied_h[win] = h
}

END {
    napplied = 0
    for (w in applied_wins) napplied++
    if (napplied < n) {
        printf "FAIL [applied]: expected %d distinct applied win= lines, found %d\n", n, napplied
        fail = 1
    }
    for (win in applied_wins) {
        if (!(win in slice_exists)) {
            printf "FAIL [applied]: applied win=%s has no matching SLICE line\n", win
            fail = 1
            continue
        }
        exp_left = -slice_ox[win]
        exp_top  = -slice_oy[win]
        exp_w    = slice_sw[win]
        exp_h    = slice_sh[win]

        diff = applied_l[win] - exp_left; if (diff < 0) diff = -diff
        if (diff > eps) {
            printf "FAIL [applied]: win=%s left=%.4f expected %.4f (=-offX=%.4f)\n", win, applied_l[win], exp_left, slice_ox[win]
            fail = 1
        }
        diff = applied_t[win] - exp_top; if (diff < 0) diff = -diff
        if (diff > eps) {
            printf "FAIL [applied]: win=%s top=%.4f expected %.4f (=-offY=%.4f)\n", win, applied_t[win], exp_top, slice_oy[win]
            fail = 1
        }
        diff = applied_w[win] - exp_w; if (diff < 0) diff = -diff
        if (diff > eps) {
            printf "FAIL [applied]: win=%s width=%.4f expected %.4f (=stageW)\n", win, applied_w[win], exp_w
            fail = 1
        }
        diff = applied_h[win] - exp_h; if (diff < 0) diff = -diff
        if (diff > eps) {
            printf "FAIL [applied]: win=%s height=%.4f expected %.4f (=stageH)\n", win, applied_h[win], exp_h
            fail = 1
        }
    }
    if (!fail) printf "PASS [applied]: geometry applied for %d display(s)\n", n
    exit fail
}
' "$TMPOUT")"
    APPLIED_EXIT=$?
    echo "$APPLIED_OUT"
    if [ $APPLIED_EXIT -ne 0 ] || echo "$APPLIED_OUT" | grep -q "^FAIL"; then
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi
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
