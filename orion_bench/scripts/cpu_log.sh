#!/usr/bin/env bash
# cpu_log.sh — Sample CPU utilization during a trial.
#
# Reads /proc/stat at 1-second intervals, computes overall CPU%.
# Outputs a CSV and prints the average on exit.
#
# Usage:
#   ./cpu_log.sh --duration 120 --out /home/ground/trials/cpu_trial_007.csv

set -euo pipefail

DURATION=120
OUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --duration) DURATION="$2"; shift 2 ;;
        --out)      OUT_FILE="$2"; shift 2 ;;
        *)          echo "Unknown arg: $1"; exit 1 ;;
    esac
done

read_cpu_total_idle() {
    # Returns "total idle" from /proc/stat first line
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    echo "$total $idle"
}

echo "[cpu_log] Monitoring CPU for ${DURATION}s"

# CSV header
HEADER="elapsed_s,cpu_pct"
[[ -n "$OUT_FILE" ]] && echo "$HEADER" > "$OUT_FILE"

SAMPLES=()
read -r prev_total prev_idle <<< "$(read_cpu_total_idle)"
START=$(date +%s)

for ((i = 1; i <= DURATION; i++)); do
    sleep 1
    read -r curr_total curr_idle <<< "$(read_cpu_total_idle)"

    delta_total=$((curr_total - prev_total))
    delta_idle=$((curr_idle - prev_idle))

    if [[ $delta_total -gt 0 ]]; then
        # CPU% = (1 - idle_delta / total_delta) * 100
        cpu_pct=$(awk "BEGIN { printf \"%.1f\", (1 - $delta_idle / $delta_total) * 100 }")
    else
        cpu_pct="0.0"
    fi

    SAMPLES+=("$cpu_pct")
    [[ -n "$OUT_FILE" ]] && echo "${i},${cpu_pct}" >> "$OUT_FILE"

    # Live output every 10 seconds
    if (( i % 10 == 0 )); then
        echo "  [${i}/${DURATION}s] CPU: ${cpu_pct}%"
    fi

    prev_total=$curr_total
    prev_idle=$curr_idle
done

# Compute average
if [[ ${#SAMPLES[@]} -gt 0 ]]; then
    AVG=$(printf '%s\n' "${SAMPLES[@]}" | awk '{ sum += $1; n++ } END { printf "%.1f", sum/n }')
    echo ""
    echo "[cpu_log] Average CPU: ${AVG}% over ${DURATION}s"
    echo "  Samples: ${#SAMPLES[@]}"
    [[ -n "$OUT_FILE" ]] && echo "  Saved → ${OUT_FILE}"
fi
