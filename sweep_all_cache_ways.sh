#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RESULTS_DIR="$SCRIPT_DIR/nvbw_all_results"
mkdir -p "$RESULTS_DIR"

BUFFER_SIZES=(1 4 8 16 32 64 128 256 512)

declare -A CACHE_WAY_LABELS
CACHE_WAY_LABELS["0xc000"]="2_ways"
CACHE_WAY_LABELS["0xffff"]="16_ways"

HOST_INIT_MODES=(
    "default"
    "cpuinit"
)

CSV_FILE="$RESULTS_DIR/all_results.csv"

# ---------------------------------------------------------------------------
# Parse one JSON log -> long-format CSV rows (appended to CSV_FILE)
# ---------------------------------------------------------------------------
parse_json_to_long_csv() {
    local log_file="$1"
    local cache_msr="$2"
    local cache_label="$3"
    local host_init_cpu="$4"
    local buffer_size="$5"

    python3 - "$log_file" "$cache_msr" "$cache_label" "$host_init_cpu" "$buffer_size" << 'PYEOF'
import sys, json

log_file  = sys.argv[1]
cache_msr = sys.argv[2]
cache_lbl = sys.argv[3]
host_cpu  = sys.argv[4]
buf_size  = sys.argv[5]

def classify_test_type(name):
    if name == "device_local_copy":
        return "Device"
    for kw in ["device_to_device", "all_to_one", "one_to_all"]:
        if kw in name:
            return "P2P"
    return "HostDevice"

def classify_metric_type(name, desc):
    if "latency" in name.lower() or "latency" in desc.lower():
        return "Latency"
    return "Bandwidth"

try:
    with open(log_file, 'r') as f:
        raw = f.read()
    js = raw[ raw.find('{') : raw.rfind('}')+1 ]
    if not js.strip():
        sys.stderr.write(f"[WARN] Empty JSON in {log_file}\n")
        sys.exit(0)
    data = json.loads(js)
    case_idx = 0
    for tc in data.get("nvbandwidth", {}).get("testcases", []):
        if tc.get("status") != "Passed":
            case_idx += 1
            continue
        name = tc.get("name", "")
        desc = tc.get("bandwidth_description", "")
        matrix = tc.get("bandwidth_matrix", [])
        if not matrix:
            case_idx += 1
            continue

        test_type  = classify_test_type(name)
        metric_type = classify_metric_type(name, desc)

        num_rows = len(matrix)
        num_cols = len(matrix[0]) if matrix else 0

        if num_rows == num_cols and num_cols > 0:
            rows_per_sub = num_cols
        elif num_rows == 1:
            rows_per_sub = 1
        elif num_rows % num_cols == 0 and num_rows > num_cols:
            rows_per_sub = num_cols
        else:
            rows_per_sub = 1

        for ri, row in enumerate(matrix):
            sub_idx  = ri // rows_per_sub
            sub_row  = ri % rows_per_sub
            for ci, vs in enumerate(row):
                if vs == "N/A" or vs == "":
                    continue
                try:
                    v = float(vs)
                except (ValueError, TypeError):
                    continue
                print(f'{cache_msr},{cache_lbl},{host_cpu},{buf_size},{case_idx},"{name}","{desc}",{test_type},{metric_type},{sub_idx},{sub_row},{ci},{v:.2f}')

        case_idx += 1

except Exception as e:
    sys.stderr.write(f"[WARN] Parse error {log_file}: {e}\n")
PYEOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "cache_way_msr,cache_way_label,host_init_cpu,buffer_size_mib,case_idx,testcase,description,test_type,metric_type,sub_idx,src_device,dst_device,bandwidth_gbps" > "$CSV_FILE"

total_runs=$((${#BUFFER_SIZES[@]} * ${#HOST_INIT_MODES[@]} * 2))
current_run=0

for cache_msr in "0xc000" "0xffff"; do
    cache_label="${CACHE_WAY_LABELS[$cache_msr]}"

    echo ""
    echo "####################################################################"
    echo "# Setting MSR 0xc8b = $cache_msr ($cache_label)"
    echo "####################################################################"
    wrmsr 0xc8b "$cache_msr" || {
        echo "[ERROR] Failed to set MSR. Retry with sudo." >&2
        exit 1
    }

    for host_init_mode in "${HOST_INIT_MODES[@]}"; do
        extra_args="-j"
        if [[ "$host_init_mode" == "cpuinit" ]]; then
            extra_args="-j --hostInitCpu"
        fi

        for buf in "${BUFFER_SIZES[@]}"; do
            current_run=$((current_run + 1))
            log_name="cache_${cache_label}_${host_init_mode}_b${buf}"
            log_file="$RESULTS_DIR/${log_name}.json"

            echo ""
            echo "===================================================================="
            echo "PROGRESS: run ${current_run}/${total_runs}"
            echo "  cache_way=$cache_label  host_init=$host_init_mode  buffer_size=${buf}MiB"
            echo "  log -> $log_file"
            echo "===================================================================="

            if ./nvbandwidth -b "$buf" $extra_args 2>&1 | tee "$log_file"; then
                parse_json_to_long_csv "$log_file" "$cache_msr" "$cache_label" "$host_init_mode" "$buf" >> "$CSV_FILE"
            else
                echo "[WARN] nvbandwidth returned non-zero exit code, saving log anyway" | tee -a "$log_file"
                parse_json_to_long_csv "$log_file" "$cache_msr" "$cache_label" "$host_init_mode" "$buf" >> "$CSV_FILE" || true
            fi
        done
    done
done

echo ""
echo "####################################################################"
echo "# All runs complete!"
echo "#"
echo "# CSV:   $CSV_FILE"
echo "# Logs:  $RESULTS_DIR/*.json"
echo "####################################################################"
