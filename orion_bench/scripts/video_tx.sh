#!/usr/bin/env bash
# Stream H.264 video at a controlled target bitrate.
#
# Uses ffmpeg with a synthetic test pattern (no camera needed) for
# reproducible, precise bitrate control.  For real camera, use --camera.
#
# Usage:
#   ./video_tx.sh --bitrate 4 --dest 10.23.X.Y          # 4 Mbps test pattern
#   ./video_tx.sh --bitrate 8 --dest 10.23.X.Y --camera  # 8 Mbps from Pi cam
#   ./video_tx.sh --bitrate 0 --dest 10.23.X.Y           # no-op (baseline)

set -euo pipefail

BITRATE_MBPS=0
DEST_IP=""
PORT=5004
DURATION=120
USE_CAMERA=false
RESOLUTION="1280x720"
FPS=30

usage() {
    echo "Usage: $0 --bitrate MBPS --dest IP [--port PORT] [--duration SEC] [--camera] [--res WxH] [--fps N]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --bitrate)  BITRATE_MBPS="$2"; shift 2 ;;
        --dest)     DEST_IP="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --camera)   USE_CAMERA=true; shift ;;
        --res)      RESOLUTION="$2"; shift 2 ;;
        --fps)      FPS="$2"; shift 2 ;;
        *)          usage ;;
    esac
done

[[ -z "$DEST_IP" ]] && { echo "Error: --dest required"; usage; }

# Baseline: no video, just sleep
if [[ "$BITRATE_MBPS" == "0" ]]; then
    echo "[video_tx] Baseline (0 Mbps); video disabled"
    sleep "$DURATION"
    exit 0
fi

BITRATE_BPS=$((BITRATE_MBPS * 1000000))
# CBR: set bitrate = maxrate = bufsize for constant rate
BITRATE_STR="${BITRATE_MBPS}M"

echo "[video_tx] Streaming H.264 to ${DEST_IP}:${PORT}"
echo "  Bitrate:    ${BITRATE_MBPS} Mbps"
echo "  Resolution: ${RESOLUTION}"
echo "  FPS:        ${FPS}"
echo "  Duration:   ${DURATION}s"
echo "  Source:     $(if $USE_CAMERA; then echo 'Pi camera'; else echo 'test pattern'; fi)"

if $USE_CAMERA; then
    # Pi camera via v4l2 (libcamera-vid pipes to ffmpeg, or use v4l2 directly)
    # Adjust /dev/video0 if needed
    INPUT_ARGS=(-f v4l2 -input_format yuv420p -video_size "$RESOLUTION" -framerate "$FPS" -i /dev/video0)
else
    # The default test pattern does not require camera hardware.
    INPUT_ARGS=(-f lavfi -i "testsrc=duration=${DURATION}:size=${RESOLUTION}:rate=${FPS}")
fi

exec ffmpeg \
    "${INPUT_ARGS[@]}" \
    -c:v libx264 \
    -b:v "$BITRATE_STR" \
    -maxrate "$BITRATE_STR" \
    -bufsize "$BITRATE_STR" \
    -preset ultrafast \
    -tune zerolatency \
    -g "$((FPS * 2))" \
    -t "$DURATION" \
    -an \
    -f rtp "rtp://${DEST_IP}:${PORT}" \
    -loglevel warning \
    -stats
