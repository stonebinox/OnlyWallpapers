#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web/assets"
OUT="$ASSET_DIR/bg.mp4"

if ! command -v ffmpeg &>/dev/null; then
    echo "MISSING: ffmpeg. Install with: brew install ffmpeg"
    exit 1
fi

mkdir -p "$ASSET_DIR"

FONTFILE=""
for f in /System/Library/Fonts/SFNSMono.ttf /System/Library/Fonts/Monaco.ttf /System/Library/Fonts/Helvetica.ttc; do
    if [[ -f "$f" ]]; then
        FONTFILE="$f"
        break
    fi
done

# Moving color box: x=t*90 travels ~540px over 6s; a loop wrap resets to 0 (visible jump).
# drawtext frame counter in the center provides high-contrast per-frame change.
# Comma-in-mod is avoided: timestamp (t) arithmetic is safe in drawbox x= values.
if [[ -n "$FONTFILE" ]]; then
    VF="drawtext=text='F%{n}':fontfile=$FONTFILE:fontsize=180:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2,drawbox=x=t*90:y=ih-240:w=200:h=200:color=lime@1.0:t=fill"
else
    VF="drawbox=x=t*90:y=0:w=200:h=200:color=lime@1.0:t=fill,drawbox=x=t*60:y=ih-200:w=120:h=120:color=red@1.0:t=fill"
fi

echo "[generate-test-bg] Generating $OUT ..."
ffmpeg -y \
    -f lavfi -i "color=c=navy:size=1920x1080:rate=30" \
    -t 6 \
    -vf "$VF" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
    -an \
    "$OUT" 2>&1

if ! command -v ffprobe &>/dev/null; then
    echo "[generate-test-bg] WARNING: ffprobe not found, skipping verification"
    echo "[generate-test-bg] Output: $OUT"
    exit 0
fi

CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null || echo unknown)"
DURATION="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null || echo 0)"
echo "[generate-test-bg] codec=$CODEC duration=${DURATION}s"

if [[ "$CODEC" != "h264" ]]; then
    echo "ERROR: expected h264, got $CODEC"
    exit 1
fi

DUR_INT="${DURATION%.*}"
if [[ "$DUR_INT" -lt 5 ]] || [[ "$DUR_INT" -gt 8 ]]; then
    echo "ERROR: duration ${DURATION}s out of expected range 5-8s"
    exit 1
fi

PIX_FMT="$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null || echo unknown)"
if [[ "$PIX_FMT" != "yuv420p" ]]; then
    echo "ERROR: expected pix_fmt yuv420p, got $PIX_FMT"
    exit 1
fi

AUDIO_STREAMS="$(ffprobe -v error -select_streams a -show_entries stream=index -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$AUDIO_STREAMS" -gt 0 ]]; then
    echo "ERROR: expected no audio streams, found $AUDIO_STREAMS"
    exit 1
fi

echo "[generate-test-bg] PASS: $OUT (h264, yuv420p, no audio, ${DURATION}s)"
