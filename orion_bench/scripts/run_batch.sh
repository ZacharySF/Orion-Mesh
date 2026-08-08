#!/usr/bin/env bash
# run_batch.sh — Fixed version with correct python3 path.

set -euo pipefail

DRONE_IP=""
REPEATS=5
COOLDOWN=30
DURATION=120
HZ=50
OUT_DIR="${HOME}/trials"
DRONE_USER="ground"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BITRATES=(0 1 2 4 6 8 10 12 15)

while [[ $# -gt 0 ]]; do
    case $1 in
        --drone)    DRONE_IP="$2"; shift 2 ;;
        --repeats)  REPEATS="$2"; shift 2 ;;
        --cooldown) COOLDOWN="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --hz)       HZ="$2"; shift 2 ;;
        --out)      OUT_DIR="$2"; shift 2 ;;
        --user)     DRONE_USER="$2"; shift 2 ;;
        *)          echo "Unknown: $1"; exit 1 ;;
    esac
done

[[ -z "$DRONE_IP" ]] && { echo "Error: --drone required"; exit 1; }

TOTAL=$((${#BITRATES[@]} * REPEATS))
TRIAL_NUM=1
PYTHON=$(which python3 2>/dev/null || echo "/run/current-system/sw/bin/python3")

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ORION MESH — BATCH EXPERIMENT                             ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Bitrates:  ${BITRATES[*]} Mbps"
echo "║  Repeats:   ${REPEATS} per condition"
echo "║  Total:     ${TOTAL} trials"
echo "║  Duration:  ${DURATION}s each + ${COOLDOWN}s cooldown"
echo "║  Est. time: $(( TOTAL * (DURATION + COOLDOWN) / 60 )) minutes"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

read -rp "Press Enter to begin (or Ctrl-C to abort)..."
echo ""

FAILED=()
START_TIME=$(date +%s)

for br in "${BITRATES[@]}"; do
    for ((rep = 1; rep <= REPEATS; rep++)); do
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Trial ${TRIAL_NUM}/${TOTAL}  —  ${br} Mbps  (repeat ${rep}/${REPEATS})"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if bash "${SCRIPT_DIR}/run_trial.sh" \
            --drone "$DRONE_IP" \
            --bitrate "$br" \
            --trial "$TRIAL_NUM" \
            --duration "$DURATION" \
            --hz "$HZ" \
            --out "$OUT_DIR" \
            --user "$DRONE_USER"; then
            echo "  ✓ Trial ${TRIAL_NUM} complete"
        else
            echo "  ✗ Trial ${TRIAL_NUM} FAILED"
            FAILED+=("${TRIAL_NUM}:${br}Mbps")
        fi

        TRIAL_NUM=$((TRIAL_NUM + 1))

        if [[ $TRIAL_NUM -le $TOTAL ]]; then
            echo "  Cooling down ${COOLDOWN}s..."
            sleep "$COOLDOWN"
        fi
    done
done

# ── Generate combined CSV summary ──────────────────────────────────────────
SUMMARY="${OUT_DIR}/summary.csv"
echo ""
echo "Generating summary → ${SUMMARY}"

$PYTHON -c "
import json, glob, csv

files = sorted(glob.glob('${OUT_DIR}/trial_*/*_results.json'))
if not files:
    print('No result files found.')
    exit(0)

fields = [
    'trial_id', 'bitrate_target_mbps', 'duration_s',
    'packets_sent', 'packets_received', 'packet_loss_pct',
    'mean_latency_ms', 'median_latency_ms', 'p95_latency_ms',
    'p99_latency_ms', 'max_latency_ms', 'jitter_ms', 'cpu_avg_pct',
]

with open('${SUMMARY}', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
    w.writeheader()
    for path in files:
        with open(path) as jf:
            d = json.load(jf)
            d.setdefault('cpu_avg_pct', '')
            w.writerow(d)

print(f'Merged {len(files)} trial results.')
"

ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  BATCH COMPLETE"
echo "  Total time: $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo "  Trials:     $((TRIAL_NUM - 1))"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "  Failed:     ${FAILED[*]}"
fi
echo "  Summary:    ${SUMMARY}"
echo "════════════════════════════════════════════════════════════════"
