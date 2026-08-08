#!/usr/bin/env bash
# Run one control-latency trial from the ground node.

set -euo pipefail

DRONE_IP=""
BITRATE_MBPS=0
TRIAL_ID=1
DURATION=120
HZ=50
OUT_DIR="${HOME}/trials"
DRONE_USER="ground"
VIDEO_PORT=5004

usage() {
    cat <<EOF
Usage: $0 --drone IP --bitrate MBPS --trial N [OPTIONS]

Required:
  --drone IP        bat0 IP of the drone node
  --bitrate MBPS    target H.264 bitrate (0 = baseline, no video)
  --trial N         trial number for labeling output

Options:
  --duration SEC    trial duration (default: 120)
  --hz N            control message frequency (default: 50)
  --out DIR         output directory (default: ~/trials)
  --user USER       SSH user on drone (default: ground)
  --port PORT       RTP video port (default: 5004)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --drone)    DRONE_IP="$2"; shift 2 ;;
        --bitrate)  BITRATE_MBPS="$2"; shift 2 ;;
        --trial)    TRIAL_ID="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --hz)       HZ="$2"; shift 2 ;;
        --out)      OUT_DIR="$2"; shift 2 ;;
        --user)     DRONE_USER="$2"; shift 2 ;;
        --port)     VIDEO_PORT="$2"; shift 2 ;;
        *)          echo "Unknown: $1"; usage ;;
    esac
done

[[ -z "$DRONE_IP" ]] && { echo "Error: --drone required"; usage; }

GROUND_IP=$(ip -4 addr show bat0 | grep -oP 'inet \K[\d.]+' || echo "unknown")
TAG="trial_$(printf '%03d' "$TRIAL_ID")_br${BITRATE_MBPS}"
TRIAL_DIR="${OUT_DIR}/${TAG}"
mkdir -p "$TRIAL_DIR"

echo "Orion Mesh trial ${TRIAL_ID}"
echo "  Drone: ${DRONE_USER}@${DRONE_IP}"
echo "  Ground: ${GROUND_IP}"
echo "  Bitrate: ${BITRATE_MBPS} Mbps"
echo "  Duration: ${DURATION}s"
echo "  Control rate: ${HZ} Hz"
echo "  Output: ${TRIAL_DIR}"
echo ""

# Check the link before starting background processes.
echo "[1/6] Checking mesh connectivity..."
if ! ping -c 2 -W 2 "$DRONE_IP" &>/dev/null; then
    echo "  ERROR: Cannot reach drone at ${DRONE_IP}"
    exit 1
fi
echo "  Drone reachable"

echo "[2/6] Checking SSH..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${DRONE_USER}@${DRONE_IP}" "echo ok" &>/dev/null; then
    echo "  ERROR: SSH to ${DRONE_USER}@${DRONE_IP} failed"
    exit 1
fi
echo "  SSH working"

# Track local processes so an interrupted trial can clean up.
PIDS=()

cleanup() {
    echo ""
    echo "[cleanup] Stopping all processes..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true
    done
    ssh "${DRONE_USER}@${DRONE_IP}" \
        "pkill -f 'control_pub' 2>/dev/null; pkill -f 'ffmpeg' 2>/dev/null" \
        2>/dev/null || true
    echo "[cleanup] Done."
}
trap cleanup EXIT

# Start the ground-node CPU logger.
echo "[3/6] Starting CPU monitor..."
orion-cpu_log \
    --duration "$DURATION" \
    --out "${TRIAL_DIR}/cpu.csv" \
    > "${TRIAL_DIR}/cpu_stdout.log" 2>&1 &
PIDS+=($!)
echo "  CPU monitor (PID $!)"

# Start the receiver locally and the transmitter on the drone.
if [[ "$BITRATE_MBPS" != "0" ]]; then
    echo "[4/6] Starting video receiver..."
    orion-video_rx \
        --port "$VIDEO_PORT" \
        --duration "$DURATION" \
        > "${TRIAL_DIR}/video_rx.log" 2>&1 &
    PIDS+=($!)
    echo "  Video RX (PID $!)"

    sleep 2

    echo "  Starting video TX on drone..."
    # Random image data plus matching min/max rates keeps ffmpeg near the
    # requested bitrate. A static test pattern compressed too efficiently.
    ssh "${DRONE_USER}@${DRONE_IP}" "nohup bash -c '
        ffmpeg \
            -re \
            -f lavfi -i \"nullsrc=size=1280x720:rate=30,geq=random(1)*255:128:128\" \
            -c:v libx264 \
            -b:v ${BITRATE_MBPS}M \
            -minrate ${BITRATE_MBPS}M \
            -maxrate ${BITRATE_MBPS}M \
            -bufsize 1M \
            -preset ultrafast \
            -tune zerolatency \
            -g 60 \
            -t ${DURATION} \
            -an \
            -f rtp \"rtp://${GROUND_IP}:${VIDEO_PORT}\" \
            -loglevel warning -stats \
            > /tmp/orion_video_tx.log 2>&1
    ' &>/dev/null &"

    echo "  Video TX started on drone"
else
    echo "[4/6] Baseline; video disabled"
fi

# Start the control publisher on the drone.
echo "[5/6] Starting control publisher on drone..."
ssh "${DRONE_USER}@${DRONE_IP}" "nohup bash -l -c '
    control_pub --ros-args \
        -p hz:=${HZ} -p reliable:=true -p duration:=${DURATION} \
        > /tmp/orion_control_pub.log 2>&1
' &>/dev/null &"

echo "  Control publisher started on drone"
sleep 2

# Start the subscriber on the ground node.
echo "[6/6] Starting control subscriber..."
echo ""
echo "Trial running"
echo ""

control_sub --ros-args \
    -p reliable:=true \
    -p duration:="$DURATION" \
    -p bitrate_label:="$BITRATE_MBPS" \
    -p trial_id:="$TRIAL_ID" \
    -p out_dir:="$TRIAL_DIR" \
    2>&1 | tee "${TRIAL_DIR}/sub_output.log"

# Add average CPU utilization to the trial JSON.
echo ""
if [[ -f "${TRIAL_DIR}/cpu.csv" ]]; then
    CPU_AVG=$(awk -F, 'NR>1 { sum+=$2; n++ } END { printf "%.1f", sum/n }' "${TRIAL_DIR}/cpu.csv")
    echo "Average CPU utilization: ${CPU_AVG}%"

    JSON_FILE=$(ls "${TRIAL_DIR}"/*_results.json 2>/dev/null | head -1)
    if [[ -n "$JSON_FILE" ]]; then
        PYTHON=$(which python3 2>/dev/null || echo "/run/current-system/sw/bin/python3")
        $PYTHON -c "
import json
with open('$JSON_FILE') as f: d = json.load(f)
d['cpu_avg_pct'] = float('$CPU_AVG')
with open('$JSON_FILE', 'w') as f: json.dump(d, f, indent=2)
" 2>/dev/null || true
    fi
fi

echo ""
echo "Trial ${TRIAL_ID} complete. Data saved to: ${TRIAL_DIR}/"
