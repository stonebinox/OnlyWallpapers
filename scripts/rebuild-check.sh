#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== rebuild-check ==="

BIN="$(swift build --product OnlyWallpapers --show-bin-path)/OnlyWallpapers"
if [[ ! -x "$BIN" ]]; then
    echo "[build] Building OnlyWallpapers..."
    swift build --product OnlyWallpapers -Xswiftc -warnings-as-errors
fi

# --- Part A: OW_SELFTEST ---
echo "[selftest] Running OW_SELFTEST=1..."
SELFTEST_OUT="$(OW_SELFTEST=1 "$BIN" 2>&1)"
echo "$SELFTEST_OUT"

SELFTEST_FAIL="$(echo "$SELFTEST_OUT" | grep 'ONLYWALLPAPERS_SELFTEST.*result=fail' || true)"
if [ -n "$SELFTEST_FAIL" ]; then
    echo "FAIL: one or more self-test cases failed:"
    echo "$SELFTEST_FAIL"
    exit 1
fi

SELFTEST_PASS_COUNT="$(echo "$SELFTEST_OUT" | grep -c 'ONLYWALLPAPERS_SELFTEST.*result=pass' || true)"
if [ "$SELFTEST_PASS_COUNT" -eq 0 ]; then
    echo "FAIL: no ONLYWALLPAPERS_SELFTEST result=pass lines found"
    exit 1
fi
echo "[selftest] PASS: $SELFTEST_PASS_COUNT case(s) passed"

# --- Part B: inject test (fake-screen T-shape math) ---
echo "[inject] Running fake-screen inject test..."

FAKE_FILE="$(mktemp)"
TMPOUT="$(mktemp)"
TMPOUT_C=""
TMPOUT_D=""
FAKE_FILE_D=""
PID=""
PID_C=""
PID_D=""

cleanup() {
    for _pid in "${PID:-}" "${PID_C:-}" "${PID_D:-}"; do
        [[ -z "$_pid" ]] && continue
        kill -0 "$_pid" 2>/dev/null || continue
        kill -INT "$_pid" 2>/dev/null || true
        sleep 0.4
        kill -0 "$_pid" 2>/dev/null && kill -KILL "$_pid" 2>/dev/null || true
        wait "$_pid" 2>/dev/null || true
    done
    rm -f "$FAKE_FILE" "$TMPOUT" "$TMPOUT_C" "$TMPOUT_D" "$FAKE_FILE_D" 2>/dev/null || true
}
trap cleanup EXIT

# Write initial 2-screen layout: two 1920x1080 side by side
printf '0,0,1920,1080,2.0,1\n1920,0,1920,1080,2.0,2\n' > "$FAKE_FILE"

# FIX 6: unset test/dev env vars so they cannot contaminate the fake-mode gate
OW_FAKE_SCREENS_FILE="$FAKE_FILE" \
    env -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_WEBSPIKE -u OW_SPIKE -u WALLPAPER_WEB_DIR "$BIN" >"$TMPOUT" 2>&1 &
PID=$!
echo "[inject] PID=$PID"

# Wait for ONLYWALLPAPERS_READY
READY=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "FAIL: process exited before READY line"
        cat "$TMPOUT" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_READY' "$TMPOUT" 2>/dev/null; then
        READY=1
        break
    fi
    sleep 0.1
done
if [[ $READY -ne 1 ]]; then
    echo "FAIL: ONLYWALLPAPERS_READY never appeared"
    cat "$TMPOUT" || true
    exit 1
fi

# Wait for initial REBUILD gen=0 reason=initial
REBUILD_INITIAL=0
for i in $(seq 1 30); do
    if grep -q 'ONLYWALLPAPERS_REBUILD gen=0 reason=initial' "$TMPOUT" 2>/dev/null; then
        REBUILD_INITIAL=1
        break
    fi
    sleep 0.1
done
if [[ $REBUILD_INITIAL -ne 1 ]]; then
    echo "FAIL: initial ONLYWALLPAPERS_REBUILD gen=0 reason=initial never appeared"
    cat "$TMPOUT" || true
    exit 1
fi
echo "[inject] initial REBUILD gen=0 confirmed"

# Check 2 SLICE lines gen=0
SLICE0_COUNT="$(grep 'ONLYWALLPAPERS_SLICE.*gen=0' "$TMPOUT" | wc -l | tr -d ' ')"
if [[ "$SLICE0_COUNT" -ne 2 ]]; then
    echo "FAIL: expected 2 SLICE lines gen=0, found $SLICE0_COUNT"
    cat "$TMPOUT" || true
    exit 1
fi
echo "[inject] 2 SLICE lines gen=0 confirmed"

# Rewrite file to T-shape: two 4K side by side above a 1920x1080 at x=1920
# Left 4K: x=0 y=1080 w=3840 h=2160, Right 4K: x=3840 y=1080 w=3840 h=2160
# Bottom 1080p: x=1920 y=0 w=1920 h=1080
printf '0,1080,3840,2160,2.0,1\n3840,1080,3840,2160,2.0,2\n1920,0,1920,1080,2.0,3\n' > "$FAKE_FILE"

# Send SIGUSR1 to trigger scheduleRefresh
kill -USR1 "$PID"

# Wait for REBUILD gen=1 reason=screens-changed
REBUILD1=0
for i in $(seq 1 60); do
    if grep -q 'ONLYWALLPAPERS_REBUILD gen=1 reason=screens-changed' "$TMPOUT" 2>/dev/null; then
        REBUILD1=1
        break
    fi
    sleep 0.1
done
if [[ $REBUILD1 -ne 1 ]]; then
    echo "FAIL: ONLYWALLPAPERS_REBUILD gen=1 reason=screens-changed never appeared"
    cat "$TMPOUT" || true
    exit 1
fi
echo "[inject] REBUILD gen=1 reason=screens-changed confirmed"

# Check 3 SLICE lines gen=1
SLICE1_COUNT="$(grep 'ONLYWALLPAPERS_SLICE.*gen=1' "$TMPOUT" | wc -l | tr -d ' ')"
if [[ "$SLICE1_COUNT" -ne 3 ]]; then
    echo "FAIL: expected 3 SLICE lines gen=1, found $SLICE1_COUNT"
    cat "$TMPOUT" || true
    exit 1
fi
echo "[inject] 3 SLICE lines gen=1 confirmed"

# Check bottom screen offY=2160 in gen=1 SLICE lines
OFFYK="$(grep 'ONLYWALLPAPERS_SLICE.*gen=1' "$TMPOUT" | grep -oE 'offY=[0-9.]+' | grep -v 'offY=0' | head -1 | sed 's/offY=//' || true)"
if [[ -z "$OFFYK" ]]; then
    echo "FAIL: no non-zero offY found in gen=1 SLICE lines (expected 2160 for bottom screen)"
    grep 'ONLYWALLPAPERS_SLICE.*gen=1' "$TMPOUT" || true
    exit 1
fi
# Compare offY with 2160 (allow 0.5 tolerance)
OFFYK_INT="$(printf '%.0f' "$OFFYK" 2>/dev/null || echo "0")"
if [[ "$OFFYK_INT" -ne 2160 ]]; then
    echo "FAIL: bottom screen offY=$OFFYK (expected 2160)"
    grep 'ONLYWALLPAPERS_SLICE.*gen=1' "$TMPOUT" || true
    exit 1
fi
echo "[inject] bottom screen offY=$OFFYK confirmed (expected 2160)"

# Check RETIRE or ADD for the diff (screen did=3 is new, so ADD; did=1,2 survive; no RETIRE expected)
BAD_RETIRE="$(grep 'ONLYWALLPAPERS_RETIRE' "$TMPOUT" | grep -E 'did=1|did=2' || true)"
if [[ -n "$BAD_RETIRE" ]]; then
    echo "FAIL: unexpected RETIRE for surviving displays:"
    echo "$BAD_RETIRE"
    exit 1
fi
echo "[inject] RETIRE/ADD diff consistent (no RETIRE for survivors)"

# --- Coalesce test ---
# Write a third arrangement (different from T-shape) to trigger a real rebuild
printf '0,0,2560,1440,2.0,1\n' > "$FAKE_FILE"

# Send two SIGUSR1 ~50ms apart
BEFORE_COALESCE_COUNT="$(grep -c 'ONLYWALLPAPERS_REBUILD' "$TMPOUT" || true)"
kill -USR1 "$PID"
sleep 0.05
kill -USR1 "$PID"

# Wait for debounce to fire (~0.5s after last signal)
sleep 0.7

AFTER_COALESCE_COUNT="$(grep -c 'ONLYWALLPAPERS_REBUILD' "$TMPOUT" || true)"
NEW_REBUILDS=$((AFTER_COALESCE_COUNT - BEFORE_COALESCE_COUNT))
if [[ "$NEW_REBUILDS" -ne 1 ]]; then
    echo "FAIL: expected exactly 1 new REBUILD from coalesce test, got $NEW_REBUILDS"
    grep 'ONLYWALLPAPERS_REBUILD' "$TMPOUT" || true
    exit 1
fi
echo "[inject] coalesce confirmed: 2 SIGUSR1 produced 1 REBUILD"

# --- No-op test ---
# File is still the single-screen arrangement, which is now committed
BEFORE_NOOP_COUNT="$(grep -c 'ONLYWALLPAPERS_REBUILD' "$TMPOUT" || true)"
kill -USR1 "$PID"
sleep 0.7

# Check for noop
NOOP_LINE="$(grep 'ONLYWALLPAPERS_REBUILD.*reason=noop' "$TMPOUT" | tail -1 || true)"
if [[ -z "$NOOP_LINE" ]]; then
    echo "FAIL: no reason=noop REBUILD appeared after no-change SIGUSR1"
    grep 'ONLYWALLPAPERS_REBUILD' "$TMPOUT" || true
    exit 1
fi
echo "[inject] noop confirmed: $NOOP_LINE"

# --- Clean exit (Part B) ---
echo "[inject] Sending SIGINT..."
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

STATUS=0; wait "$PID" 2>/dev/null || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
    echo "FAIL: process exited with status=$STATUS on SIGINT (expected 0)"
    exit 1
fi
PID=""

echo "[inject] clean exit confirmed"

# --- Part C: real-screens forced recommit (OW_REBUILD_TEST=1) ---
# This proves updateFrame + applyGeometry run on real glass (not fake-mode synthetic rects).
# Fake mode cannot test this path because WindowServer clamps off-glass positions.
echo "[real-recommit] Running OW_REBUILD_TEST=1 forced recommit test..."

TMPOUT_C="$(mktemp)"

# FIX 6: unset fake/selftest env vars; do NOT set OW_FAKE_SCREENS_FILE
env -u OW_FAKE_SCREENS_FILE -u OW_SELFTEST -u OW_WEBSPIKE -u OW_SPIKE \
    OW_REBUILD_TEST=1 \
    WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
    "$BIN" >"$TMPOUT_C" 2>&1 &
PID_C=$!
echo "[real-recommit] PID_C=$PID_C"

# Wait for READY
RC_READY=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID_C" 2>/dev/null; then
        echo "FAIL: [real-recommit] process exited before READY"
        cat "$TMPOUT_C" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_READY' "$TMPOUT_C" 2>/dev/null; then RC_READY=1; break; fi
    sleep 0.1
done
if [[ $RC_READY -ne 1 ]]; then
    echo "FAIL: [real-recommit] ONLYWALLPAPERS_READY never appeared"
    cat "$TMPOUT_C" || true
    exit 1
fi

# Wait for gen=0 reason=initial
RC_INIT=0
for i in $(seq 1 30); do
    if grep -q 'ONLYWALLPAPERS_REBUILD gen=0 reason=initial' "$TMPOUT_C" 2>/dev/null; then RC_INIT=1; break; fi
    sleep 0.1
done
if [[ $RC_INIT -ne 1 ]]; then
    echo "FAIL: [real-recommit] initial REBUILD gen=0 never appeared"
    cat "$TMPOUT_C" || true
    exit 1
fi

# Get real screen count from gen=0 WINDOWS line
RC_SCREEN_COUNT="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT_C" | grep 'gen=0' | head -1 | sed 's/.*count=\([0-9]*\).*/\1/' || true)"
if [[ -z "$RC_SCREEN_COUNT" || "$RC_SCREEN_COUNT" -eq 0 ]]; then
    echo "FAIL: [real-recommit] expected at least 1 real display, got count=${RC_SCREEN_COUNT:-0}"
    cat "$TMPOUT_C" || true
    exit 1
fi
echo "[real-recommit] gen=0 initial: $RC_SCREEN_COUNT real display(s)"

# Wait for gen=0 loaded=ok lines (FIX 5: filter by gen=0)
for i in $(seq 1 80); do
    RC_LOADED="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_C" 2>/dev/null || true)"
    if [[ "$RC_LOADED" -ge "$RC_SCREEN_COUNT" ]]; then break; fi
    sleep 0.1
done
RC_LOADED="$(grep -cE 'ONLYWALLPAPERS_WEB.*loaded=ok.*gen=0( |$)' "$TMPOUT_C" 2>/dev/null || true)"
if [[ "$RC_LOADED" -lt "$RC_SCREEN_COUNT" ]]; then
    echo "FAIL: [real-recommit] expected $RC_SCREEN_COUNT gen=0 loaded=ok lines, got $RC_LOADED"
    cat "$TMPOUT_C" || true
    exit 1
fi
echo "[real-recommit] gen=0 loaded=ok confirmed: $RC_LOADED display(s)"

# Wait for gen=0 applied lines (proof the initial geometry was applied)
for i in $(seq 1 30); do
    RC_APPLIED0="$(grep 'ONLYWALLPAPERS_WEB applied win=' "$TMPOUT_C" | grep -cE 'gen=0( |$)' 2>/dev/null || true)"
    if [[ "$RC_APPLIED0" -ge "$RC_SCREEN_COUNT" ]]; then break; fi
    sleep 0.1
done

# Record gen=0 window numbers from SLICE lines
GEN0_WINS="$(grep 'ONLYWALLPAPERS_SLICE.*gen=0' "$TMPOUT_C" | grep -oE 'win=[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
echo "[real-recommit] gen=0 win= set: {$GEN0_WINS}"

# Send SIGUSR1 to trigger forced recommit
kill -USR1 "$PID_C"

# Wait for REBUILD gen=1 reason=forced
RC_FORCED=0
for i in $(seq 1 60); do
    if grep -q 'ONLYWALLPAPERS_REBUILD gen=1 reason=forced' "$TMPOUT_C" 2>/dev/null; then RC_FORCED=1; break; fi
    sleep 0.1
done
if [[ $RC_FORCED -ne 1 ]]; then
    echo "FAIL: [real-recommit] ONLYWALLPAPERS_REBUILD gen=1 reason=forced never appeared"
    cat "$TMPOUT_C" || true
    exit 1
fi
echo "[real-recommit] gen=1 reason=forced REBUILD confirmed"

# Assert no RETIRE lines (same screens, only update path)
RC_RETIRE="$(grep -c 'ONLYWALLPAPERS_RETIRE' "$TMPOUT_C" 2>/dev/null || true)"
if [[ "$RC_RETIRE" -ne 0 ]]; then
    echo "FAIL: [real-recommit] unexpected RETIRE lines found (same real screens should not retire)"
    grep 'ONLYWALLPAPERS_RETIRE' "$TMPOUT_C" || true
    exit 1
fi
echo "[real-recommit] no RETIRE lines confirmed"

# Assert same window numbers in gen=1 SLICE as gen=0 (no new windows created)
GEN1_WINS="$(grep 'ONLYWALLPAPERS_SLICE.*gen=1' "$TMPOUT_C" | grep -oE 'win=[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [[ "$GEN0_WINS" != "$GEN1_WINS" ]]; then
    echo "FAIL: [real-recommit] window numbers changed after forced recommit (new window created)"
    echo "  gen=0 wins: {$GEN0_WINS}"
    echo "  gen=1 wins: {$GEN1_WINS}"
    cat "$TMPOUT_C" || true
    exit 1
fi
echo "[real-recommit] same window numbers confirmed: {$GEN1_WINS}"

# Wait for gen=1 applied lines (FIX 2: applyGeometry on loaded views fires immediately)
for i in $(seq 1 30); do
    RC_APPLIED1="$(grep 'ONLYWALLPAPERS_WEB applied win=' "$TMPOUT_C" | grep -cE 'gen=1( |$)' 2>/dev/null || true)"
    if [[ "$RC_APPLIED1" -ge "$RC_SCREEN_COUNT" ]]; then break; fi
    sleep 0.1
done

# Applied oracle for gen=1: verify left==-offX and top==-offY from gen=1 SLICE lines
RC_APPLIED_OUT="$(awk '
BEGIN { eps = 0.5; fail = 0; nslice = 0; napplied = 0 }

/^ONLYWALLPAPERS_SLICE / {
    if ($0 !~ /gen=1( |$)/) next
    nslice++
    split($3, a, "="); win = a[2]
    split($7, a, "="); ox = a[2]+0
    split($8, a, "="); oy = a[2]+0
    slice_ox[win] = ox
    slice_oy[win] = oy
    slice_wins[win] = 1
}

/ONLYWALLPAPERS_WEB applied win=/ {
    if ($0 ~ /applied=fail/) next
    if ($0 !~ /gen=1( |$)/) next
    napplied++
    split($3, a, "="); win = a[2]
    split($4, a, "="); l = a[2]+0
    split($5, a, "="); t = a[2]+0
    applied_wins[win] = 1
    applied_l[win] = l
    applied_t[win] = t
}

END {
    if (nslice == 0) { print "FAIL [real-recommit]: no gen=1 SLICE lines found"; exit 1 }
    for (win in slice_wins) {
        if (!(win in applied_wins)) {
            printf "FAIL [real-recommit]: win=%s has gen=1 SLICE but no gen=1 applied line\n", win
            fail = 1
            continue
        }
        exp_left = -slice_ox[win]
        exp_top  = -slice_oy[win]
        diff = applied_l[win] - exp_left; if (diff < 0) diff = -diff
        if (diff > eps) {
            printf "FAIL [real-recommit]: win=%s left=%.4f expected %.4f (=-offX=%.4f)\n", win, applied_l[win], exp_left, slice_ox[win]
            fail = 1
        }
        diff = applied_t[win] - exp_top; if (diff < 0) diff = -diff
        if (diff > eps) {
            printf "FAIL [real-recommit]: win=%s top=%.4f expected %.4f (=-offY=%.4f)\n", win, applied_t[win], exp_top, slice_oy[win]
            fail = 1
        }
    }
    if (!fail) printf "PASS [real-recommit]: gen=1 applied oracle passed for %d display(s)\n", nslice
    exit fail
}
' "$TMPOUT_C")"
RC_AWK_EXIT=$?
echo "$RC_APPLIED_OUT"
if [[ $RC_AWK_EXIT -ne 0 ]] || echo "$RC_APPLIED_OUT" | grep -q "^FAIL"; then
    echo "--- output ---"
    cat "$TMPOUT_C" || true
    exit 1
fi

# Clean exit (Part C)
kill -INT "$PID_C"
RC_GONE=0
for i in $(seq 1 20); do
    sleep 0.05
    if ! kill -0 "$PID_C" 2>/dev/null; then RC_GONE=1; break; fi
done
wait "$PID_C" 2>/dev/null || true
PID_C=""
rm -f "$TMPOUT_C"
TMPOUT_C=""
echo "[real-recommit] clean exit confirmed"

# --- Part D: empty-confirm process tests ---
# Tests the sleep/wake blank path (screens momentarily disappear).
# Uses fake mode: empty fake file = no screens.
echo "[empty-confirm] Running empty-confirm tests (a/b/c)..."

FAKE_FILE_D="$(mktemp)"
TMPOUT_D="$(mktemp)"

# Start with a single non-empty screen so gen=0 commit has new=1
printf '0,0,1920,1080,2.0,1\n' > "$FAKE_FILE_D"
OW_FAKE_SCREENS_FILE="$FAKE_FILE_D" \
    env -u OW_SELFTEST -u OW_REBUILD_TEST -u OW_WEBSPIKE -u OW_SPIKE -u WALLPAPER_WEB_DIR "$BIN" >"$TMPOUT_D" 2>&1 &
PID_D=$!
echo "[empty-confirm] PID_D=$PID_D"

# Wait for initial gen=0 rebuild
for i in $(seq 1 30); do
    if grep -q 'ONLYWALLPAPERS_REBUILD gen=0 reason=initial' "$TMPOUT_D" 2>/dev/null; then break; fi
    sleep 0.1
done
if ! grep -q 'ONLYWALLPAPERS_REBUILD gen=0 reason=initial' "$TMPOUT_D"; then
    echo "FAIL: [empty-confirm] initial REBUILD gen=0 never appeared"
    cat "$TMPOUT_D" || true
    exit 1
fi

# --- Sub-case (a): SIGUSR1 with empty file arms emptyConfirm but does NOT commit within 0.5s ---
BEFORE_EMPTY_A="$(grep -c 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true)"
printf '' > "$FAKE_FILE_D"
kill -USR1 "$PID_D"
sleep 0.5
AFTER_EMPTY_A="$(grep -c 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true)"
if [[ "$AFTER_EMPTY_A" -gt "$BEFORE_EMPTY_A" ]]; then
    echo "FAIL: [empty-confirm] (a) empty commit fired within 0.5s (should be armed, not fired)"
    grep 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true
    exit 1
fi
echo "[empty-confirm] (a) PASS: emptyConfirm armed, no commit within 0.5s"

# --- Sub-case (b): non-empty arrives before confirm fires; must commit non-empty, never new=0 ---
# Wait 2.0s (past the 1.5s confirm delay) to prove the stale emptyConfirm never fires.
printf '0,0,1920,1080,2.0,1\n' > "$FAKE_FILE_D"
BEFORE_REBUILD_B="$(grep -c 'ONLYWALLPAPERS_REBUILD' "$TMPOUT_D" || true)"
kill -USR1 "$PID_D"
sleep 2.0
AFTER_REBUILD_B="$(grep -c 'ONLYWALLPAPERS_REBUILD' "$TMPOUT_D" || true)"
NEW_REBUILDS_B=$((AFTER_REBUILD_B - BEFORE_REBUILD_B))
if [[ "$NEW_REBUILDS_B" -ne 1 ]]; then
    echo "FAIL: [empty-confirm] (b) expected exactly 1 new REBUILD, got $NEW_REBUILDS_B"
    grep 'ONLYWALLPAPERS_REBUILD' "$TMPOUT_D" || true
    exit 1
fi
NEW_REBUILD_LINE_B="$(grep 'ONLYWALLPAPERS_REBUILD' "$TMPOUT_D" | tail -1)"
if echo "$NEW_REBUILD_LINE_B" | grep -q 'new=0'; then
    echo "FAIL: [empty-confirm] (b) the new REBUILD is empty (new=0): $NEW_REBUILD_LINE_B"
    exit 1
fi
TOTAL_EMPTY_AFTER_B="$(grep -c 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true)"
if [[ "$TOTAL_EMPTY_AFTER_B" -gt "$BEFORE_EMPTY_A" ]]; then
    echo "FAIL: [empty-confirm] (b) unexpected empty commit appeared after non-empty override:"
    grep 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true
    exit 1
fi
echo "[empty-confirm] (b) PASS: non-empty commit fired, no empty commit: $NEW_REBUILD_LINE_B"

# --- Sub-case (c): empty stays empty past confirm delay; exactly one new=0 commit fires ---
printf '' > "$FAKE_FILE_D"
BEFORE_EMPTY_C="$(grep -c 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true)"
kill -USR1 "$PID_D"
sleep 2.0
AFTER_EMPTY_C="$(grep -c 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true)"
NEW_EMPTY_C=$((AFTER_EMPTY_C - BEFORE_EMPTY_C))
if [[ "$NEW_EMPTY_C" -ne 1 ]]; then
    echo "FAIL: [empty-confirm] (c) expected exactly 1 empty commit after delay, got $NEW_EMPTY_C"
    grep 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" || true
    exit 1
fi
EMPTY_LINE_C="$(grep 'ONLYWALLPAPERS_REBUILD.*new=0' "$TMPOUT_D" | tail -1)"
echo "[empty-confirm] (c) PASS: empty commit fired: $EMPTY_LINE_C"

# Clean exit (Part D)
kill -INT "$PID_D"
PD_GONE=0
for i in $(seq 1 20); do
    sleep 0.05
    if ! kill -0 "$PID_D" 2>/dev/null; then PD_GONE=1; break; fi
done
wait "$PID_D" 2>/dev/null || true
PID_D=""
rm -f "$FAKE_FILE_D" "$TMPOUT_D"
FAKE_FILE_D=""
TMPOUT_D=""
echo "[empty-confirm] clean exit confirmed"

echo ""
echo "=== PASS: all rebuild checks passed ==="
