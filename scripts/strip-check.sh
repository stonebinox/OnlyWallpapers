#!/usr/bin/env bash
# strip-check (ow-blz.9): the bg.mp4 slot always holds a VIDEO-ONLY file, video bitstream untouched.
#   1  selftests: strip-* and migrate-* checks (OW_SELFTEST)
#   2  migration: a temp store whose bg.mp4 has audio is stripped at launch (migrate=stripped, reload under a new
#      source revision), a second launch skips (migrate=skipped) and leaves the file byte-identical
#   3  choose path (OW_VIDEO_TEST copy hook, the same copyVideoFile as the Choose video menu item): an audio clip lands
#      video-only, a video-only clip is copied byte for byte (no strip line)
#   4  the 4K60 fixture with audio (the user's clip profile): strip timing, packet sizes and flags identical, rotation kept
# Never touches the real app storage: every app run uses a temp OW_APP_SUPPORT_DIR. No visible windows are needed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# This gate REQUIRES ffmpeg and ffprobe (fixtures and bitstream fingerprints). OW_SELFTEST alone skips its ffmpeg-based
# checks when ffmpeg is absent, so a machine without it must fail here, loudly, instead of passing silently.
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
for tool in ffmpeg ffprobe python3 shasum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: strip-check requires '$tool' on PATH (or /usr/local/bin, /opt/homebrew/bin); install it (brew install ffmpeg) and rerun"; exit 1; }
done

WORK="$(mktemp -d)"
PID=""
cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 0.4
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

PASSES=0
FAILS=0
ok() { echo "STRIP_ASSERT pass $1"; PASSES=$((PASSES + 1)); }
bad() { echo "STRIP_ASSERT FAIL $1"; FAILS=$((FAILS + 1)); }
assert() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "[strip-check] building..."
swift build > "$WORK/build.out" 2>&1 || { tail -20 "$WORK/build.out"; echo "FAIL: swift build"; exit 1; }
BIN="$(swift build --show-bin-path 2>/dev/null)/OnlyWallpapers"
[[ -x "$BIN" ]] || { echo "FAIL: binary missing"; exit 1; }

wait_for() { # file pattern timeout_s
    local i=0
    while (( i < $3 * 10 )); do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}
start_app() { # outfile support_dir extra env...
    local out="$1" support="$2"; shift 2
    env -u WALLPAPER_WEB_DIR -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_SELFTEST \
        OW_SUPPRESS_FIRST_RUN=1 OW_APP_SUPPORT_DIR="$support" "$@" "$BIN" > "$out" 2>&1 &
    PID=$!
}
stop_app() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        local i=0
        while kill -0 "$PID" 2>/dev/null && (( i < 30 )); do sleep 0.1; i=$((i + 1)); done
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""
}
n_audio() { ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | grep -c . || true; }
n_streams() { ffprobe -v error -show_entries stream=index -of csv=p=0 "$1" | grep -c . || true; }
# Compressed video fingerprint: codec, size, the rotation side data, and for EVERY video packet its size, keyframe flag and
# the SHA-256 of its payload bytes (so a re-encode with the same size and frame count cannot pass).
vfp() {
    { ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height:stream_side_data=rotation -of default=nw=1 "$1"
      ffprobe -v error -select_streams v:0 -show_packets -show_data_hash sha256 -show_entries packet=size,flags,data_hash -of csv=p=0 "$1"; } | shasum | cut -d' ' -f1
}
vdur() { ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=nw=1:nk=1 "$1"; }
vframes() { ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$1"; }
dur_close() { python3 -I -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= 1.0/float(sys.argv[3]) else 1)' "$1" "$2" "$3"; }

# --- Fixtures ---
CLIP_AUDIO="$WORK/clip-audio.mp4"
CLIP_VIDEO="$WORK/clip-video.mp4"
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=640x360:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 4 \
    -c:v libx264 -pix_fmt yuv420p -g 15 -c:a aac -shortest -movflags +faststart "$CLIP_AUDIO" || { echo "FAIL: ffmpeg audio clip"; exit 1; }
ffmpeg -y -loglevel error -f lavfi -i "smptebars=size=640x360:rate=30" -t 3 \
    -c:v libx264 -pix_fmt yuv420p -g 15 -an -movflags +faststart "$CLIP_VIDEO" || { echo "FAIL: ffmpeg video clip"; exit 1; }
SRC_FP="$(vfp "$CLIP_AUDIO")"

# Falsifiability of the identity check: a re-encode with the same resolution and frame count must NOT match.
CLIP_REENC="$WORK/clip-reenc.mp4"
ffmpeg -y -loglevel error -i "$CLIP_AUDIO" -map 0:v -c:v libx264 -crf 30 -pix_fmt yuv420p -g 15 -an -movflags +faststart "$CLIP_REENC" || { echo "FAIL: ffmpeg re-encode"; exit 1; }

assert "identity-check-same-frame-count-and-size-as-reencode" "[[ \$(vframes '$CLIP_REENC') == \$(vframes '$CLIP_AUDIO') && \$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 '$CLIP_REENC') == \$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 '$CLIP_AUDIO') ]]"
assert "identity-check-fails-for-reencode" "[[ \$(vfp '$CLIP_REENC') != '$SRC_FP' ]]"
assert "identity-check-stable-for-pure-remux" "[[ \$(ffmpeg -y -loglevel error -i '$CLIP_AUDIO' -map 0:v -c copy -f mp4 '$WORK/remux.mp4' && vfp '$WORK/remux.mp4') == '$SRC_FP' ]]"

# --- (1) selftests ---
echo "[strip-check] (1) selftests"
OW_SELFTEST=1 "$BIN" > "$WORK/selftest.out" 2>&1
ST_LINES="$(grep -E 'SELFTEST name=(strip|migrate)-' "$WORK/selftest.out")"
ST_PASS="$(printf '%s\n' "$ST_LINES" | grep -c 'result=pass' || true)"
ST_FAIL="$(printf '%s\n' "$ST_LINES" | grep -c 'result=fail' || true)"
echo "[strip-check] selftests strip/migrate: pass=$ST_PASS fail=$ST_FAIL; $(grep 'SELFTEST summary' "$WORK/selftest.out")"
assert "selftests-strip-migrate-no-failures" "[[ $ST_FAIL -eq 0 && $ST_PASS -ge 20 ]]"
assert "selftests-all-no-failures" "grep -q 'SELFTEST summary passed=[0-9]* failed=0 skipped=0' '$WORK/selftest.out'"

# --- (2) migration ---
echo "[strip-check] (2) launch migration in a temp store"
SUP="$WORK/support-mig"
# First launch seeds the web dir (no bg.mp4 in the bundle copy is required), then we plant an audio clip as the user's bg.mp4.
start_app "$WORK/mig0.out" "$SUP"
wait_for "$WORK/mig0.out" "ONLYWALLPAPERS_READY" 20 || bad "migration-seed-launch-ready"
stop_app
mkdir -p "$SUP/web/assets"
cp "$CLIP_AUDIO" "$SUP/web/assets/bg.mp4"
assert "migration-planted-slot-has-audio" "[[ \$(n_audio '$SUP/web/assets/bg.mp4') -ge 1 ]]"
# OW_SYNC_TEST makes every window log a sample line (rev, paused, currentTime) so the SAME instance that migrates is checked.
start_app "$WORK/mig1.out" "$SUP" OW_SYNC_TEST=1
wait_for "$WORK/mig1.out" "ONLYWALLPAPERS_VIDEO migrate=" 30 || bad "migration-logged-outcome"
wait_for "$WORK/mig1.out" "ONLYWALLPAPERS_VIDEO reload views=" 15 || bad "migration-reload-after-strip"
sleep 6
stop_app
: > "$WORK/mig1.marks"
python3 -I scripts/sync-check-analyze.py "$WORK/mig1.out" "$WORK/mig1.marks" --checks migrated --rev 1 --dur-a 4 --min-windows 1 --label migration > "$WORK/mig1.analysis" 2>&1
grep 'SYNC_ASSERT' "$WORK/mig1.analysis"
assert "migration-every-window-applied-rev-1" "grep -q 'SYNC_ASSERT pass migrated-every-window-on-rev-1 ' '$WORK/mig1.analysis'"
assert "migration-every-window-playing-on-rev-1" "grep -q 'SYNC_ASSERT pass migrated-every-window-playing' '$WORK/mig1.analysis' && grep -q 'SYNC_ASSERT pass migrated-windows-sampled' '$WORK/mig1.analysis'"
SLOT="$SUP/web/assets/bg.mp4"
assert "migration-logged-stripped" "grep -q 'ONLYWALLPAPERS_VIDEO migrate=stripped' '$WORK/mig1.out'"
assert "migration-logged-strip-done" "grep -qE 'ONLYWALLPAPERS_VIDEO strip=done audio_tracks_removed=1 other_tracks_removed=0 bytes_in=[0-9]+ bytes_out=[0-9]+ ms=[0-9]+' '$WORK/mig1.out'"
assert "migration-slot-has-no-audio" "[[ \$(n_audio '$SLOT') -eq 0 && \$(n_streams '$SLOT') -eq 1 ]]"
assert "migration-video-bitstream-identical" "[[ \$(vfp '$SLOT') == '$SRC_FP' ]]"
assert "migration-no-partial-left" "[[ -z \$(ls '$SUP/web/assets' | grep '\\.partial\$') ]]"
assert "migration-reload-bumps-source-rev" "grep 'ONLYWALLPAPERS_SESSION' '$WORK/mig1.out' | tail -1 | grep -q 'rev=1'"
SHA1="$(shasum "$SLOT" | cut -d' ' -f1)"
start_app "$WORK/mig2.out" "$SUP"
wait_for "$WORK/mig2.out" "ONLYWALLPAPERS_VIDEO migrate=" 30 || bad "migration-second-launch-logged"
sleep 1
stop_app
assert "migration-second-launch-skipped" "grep -q 'ONLYWALLPAPERS_VIDEO migrate=skipped' '$WORK/mig2.out' && ! grep -q 'strip=done' '$WORK/mig2.out'"
assert "migration-second-launch-file-unchanged" "[[ \$(shasum '$SLOT' | cut -d' ' -f1) == '$SHA1' ]]"
assert "migration-second-launch-no-reload" "! grep -q 'ONLYWALLPAPERS_VIDEO reload views=' '$WORK/mig2.out'"

# --- (3) choose path via the copy hook ---
echo "[strip-check] (3) choose path (copy hook)"
SUP="$WORK/support-choose"
SRC_FILE="$WORK/copy-src.txt"; : > "$SRC_FILE"
start_app "$WORK/ch.out" "$SUP" OW_VIDEO_TEST=1 OW_VIDEO_TEST_SRC_FILE="$SRC_FILE"
wait_for "$WORK/ch.out" "ONLYWALLPAPERS_READY" 20 || bad "choose-launch-ready"
choose() { # clip log_marker_count_before
    local before; before="$(grep -c 'ONLYWALLPAPERS_VIDEO slot=ok' "$WORK/ch.out" || true)"
    printf '%s' "$1" > "$SRC_FILE"
    kill -USR2 "$PID"
    local i=0
    while (( i < 600 )); do
        [[ "$(grep -c 'ONLYWALLPAPERS_VIDEO slot=ok' "$WORK/ch.out" || true)" -gt "$before" ]] && break
        sleep 0.1; i=$((i + 1))
    done
    wait_for "$WORK/ch.out" "ONLYWALLPAPERS_VIDEO reload views=" 10
    sleep 0.5
}
CHSLOT="$SUP/web/assets/bg.mp4"
rm -f "$CHSLOT"
choose "$CLIP_AUDIO"
assert "choose-audio-clip-stripped-logged" "grep -qE 'ONLYWALLPAPERS_VIDEO strip=done audio_tracks_removed=1 other_tracks_removed=0 bytes_in=[0-9]+ bytes_out=[0-9]+ ms=[0-9]+' '$WORK/ch.out'"
assert "choose-audio-clip-slot-video-only" "[[ \$(n_audio '$CHSLOT') -eq 0 && \$(n_streams '$CHSLOT') -eq 1 && \$(vfp '$CHSLOT') == '$SRC_FP' ]]"
assert "choose-audio-clip-reloaded" "grep -q 'ONLYWALLPAPERS_VIDEO reload views=' '$WORK/ch.out'"
STRIPS_BEFORE="$(grep -c 'strip=done' "$WORK/ch.out" || true)"
choose "$CLIP_VIDEO"
assert "choose-video-only-clip-copied-byte-for-byte" "cmp -s '$CLIP_VIDEO' '$CHSLOT'"
assert "choose-video-only-clip-not-stripped" "[[ \$(grep -c 'strip=done' '$WORK/ch.out' || true) -eq $STRIPS_BEFORE ]]"
assert "choose-no-partial-left" "[[ -z \$(ls '$SUP/web/assets' | grep '\\.partial\$') ]]"
stop_app

# --- (4) the 4K60 fixture with audio ---
echo "[strip-check] (4) 4K60 H.264 fixture with an AAC track (the user's clip profile)"
FIX_DIR="${TMPDIR:-/tmp}"
FIX_4K="${FIX_DIR%/}/ow-sync-fixture-4k60-v1.mp4"
FIX_4K_A="${FIX_DIR%/}/ow-sync-fixture-4k60-audio-v1.mp4"
if [[ ! -f "$FIX_4K_A" ]]; then
    if [[ ! -f "$FIX_4K" ]]; then
        ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=3840x2160:rate=60,noise=alls=12:allf=t" -t 18 \
            -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 40M -maxrate 45M -bufsize 80M -g 60 -keyint_min 60 -sc_threshold 0 \
            -an -movflags +faststart "$FIX_4K.part.mp4" && mv "$FIX_4K.part.mp4" "$FIX_4K"
    fi
    ffmpeg -y -loglevel error -i "$FIX_4K" -f lavfi -i "anoisesrc=d=18:c=pink:r=48000:a=0.001" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 128k -shortest -movflags +faststart "$FIX_4K_A.part.mp4" \
        && mv "$FIX_4K_A.part.mp4" "$FIX_4K_A"
fi
if [[ -f "$FIX_4K_A" ]]; then
    ROT="$WORK/fixture-rotated.mp4"
    ffmpeg -y -loglevel error -display_rotation 90 -i "$FIX_4K_A" -c copy -movflags +faststart "$ROT"
    for variant in plain rotated; do
        SRC="$FIX_4K_A"; [[ "$variant" == rotated ]] && SRC="$ROT"
        SUP="$WORK/support-4k-$variant"
        SRC_FILE="$WORK/copy-src-4k.txt"; : > "$SRC_FILE"
        start_app "$WORK/k4-$variant.out" "$SUP" OW_VIDEO_TEST=1 OW_VIDEO_TEST_SRC_FILE="$SRC_FILE"
        wait_for "$WORK/k4-$variant.out" "ONLYWALLPAPERS_READY" 20 || bad "4k-$variant-launch-ready"
        printf '%s' "$SRC" > "$SRC_FILE"
        kill -USR2 "$PID"
        wait_for "$WORK/k4-$variant.out" "ONLYWALLPAPERS_VIDEO slot=ok" 120 || bad "4k-$variant-slot-ok"
        stop_app
        S4="$SUP/web/assets/bg.mp4"
        TIMING="$(grep -oE 'strip=done audio_tracks_removed=[0-9]+ other_tracks_removed=[0-9]+ bytes_in=[0-9]+ bytes_out=[0-9]+ ms=[0-9]+' "$WORK/k4-$variant.out" | tail -1)"
        echo "STRIP_METRIC 4k60-$variant $TIMING"
        assert "4k-$variant-strip-logged" "[[ -n '$TIMING' ]]"
        assert "4k-$variant-no-audio" "[[ \$(n_audio '$S4') -eq 0 && \$(n_streams '$S4') -eq 1 ]]"
        assert "4k-$variant-video-bitstream-identical" "[[ \$(vfp '$S4') == \$(vfp '$SRC') ]]"
        assert "4k-$variant-frame-count-identical" "[[ \$(vframes '$S4') == \$(vframes '$SRC') ]]"
        assert "4k-$variant-duration-within-one-frame" "dur_close \$(vdur '$S4') \$(vdur '$SRC') 60"
    done
    assert "4k-rotated-fixture-is-rotated" "ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of csv=p=0 '$ROT' | grep -q ."
else
    bad "4k-fixture-missing"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
    echo "strip-check PASS: $PASSES assertions passed"
    exit 0
fi
echo "strip-check FAIL: $FAILS failed, $PASSES passed"
exit 1
