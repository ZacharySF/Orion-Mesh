#!/usr/bin/env bash
# Receive and discard the H.264 RTP stream during a trial.
#
# This just consumes the incoming video to keep the network load active.
# Frames are decoded to /dev/null because the experiment does not display them.
#
# Usage:
#   ./video_rx.sh                          # listen on default port 5004
#   ./video_rx.sh --port 5004 --duration 120

set -euo pipefail

PORT=5004
DURATION=120

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)     PORT="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        *)          echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Generate SDP file for ffmpeg to know the incoming format
SDP_FILE=$(mktemp /tmp/orion_rx_XXXXXX.sdp)
cat > "$SDP_FILE" << EOF
v=0
o=- 0 0 IN IP4 0.0.0.0
s=Orion H.264 Stream
c=IN IP4 0.0.0.0
t=0 0
m=video ${PORT} RTP/AVP 96
a=rtpmap:96 H264/90000
EOF

echo "[video_rx] Receiving H.264 on port ${PORT} for ${DURATION}s"
echo "  SDP: ${SDP_FILE}"

# Timeout slightly longer than duration to handle stream end gracefully
TIMEOUT=$((DURATION + 10))

timeout "$TIMEOUT" ffmpeg \
    -protocol_whitelist file,udp,rtp \
    -i "$SDP_FILE" \
    -f null /dev/null \
    -loglevel warning \
    -stats \
    2>&1 || true

rm -f "$SDP_FILE"
echo "[video_rx] Done."
