#!/usr/bin/env bash

# Loader and guard helpers for JSON-driven sweep configuration.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi

SWEEP_CASE_POLICY_JSON_FILE="${SWEEP_CASE_POLICY_JSON_FILE:-$SCRIPT_DIR/sweep_cases.json}"

json_query() {
    local query="$1"
    python3 - "$SWEEP_CASE_POLICY_JSON_FILE" "$query" <<'PY'
import json
import sys

path, query = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

parts = query.split('.') if query else []
value = data
for part in parts:
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=True))
else:
    print(value)
PY
}

json_set_case_loop_count() {
    local case_name="$1"
    local new_loop_count="$2"
    python3 - "$SWEEP_CASE_POLICY_JSON_FILE" "$case_name" "$new_loop_count" <<'PY'
import json
import sys

path, case_name, new_loop_count = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

for case in data.get('cases', []):
    if case.get('name') == case_name:
        case['loopCount'] = new_loop_count
        break
else:
    raise SystemExit(f'case not found: {case_name}')

with open(path, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=2, ensure_ascii=True)
    fh.write('\n')
PY
}

json_expand_cases() {
    python3 - "$SWEEP_CASE_POLICY_JSON_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

cases = data.get('cases', [])
expanded = []
changed = False

for item in cases:
    buffers = item.get('buffers')
    tunes = item.get('tunes')
    if isinstance(buffers, list) and isinstance(tunes, list):
        changed = True
        base = {k: v for k, v in item.items() if k not in {'buffers', 'tunes'}}
        base_name = base.get('name', 'case')
        buffer_unit = base.get('bufferUnit', 'buf')
        tune_arg = base.get('tuneArg', 'tune')
        for buffer in buffers:
            for tune in tunes:
                case = dict(base)
                case['buffer'] = buffer
                case['tune'] = tune
                case['name'] = f'{base_name}_b{buffer}{buffer_unit}_t{tune_arg}{tune}'
                expanded.append(case)
    else:
        expanded.append(item)

if changed:
    data['cases'] = expanded
    with open(path, 'w', encoding='utf-8') as fh:
        json.dump(data, fh, indent=2, ensure_ascii=True)
        fh.write('\n')
else:
    sys.exit(0)
PY
}

json_emit_cases() {
    python3 - "$SWEEP_CASE_POLICY_JSON_FILE" <<'PY'
import json
import os
import sys

path = sys.argv[1]
only_testcase = os.environ.get('ONLY_TESTCASE', '').strip()
if only_testcase and only_testcase not in {'16', '33'}:
    raise SystemExit(f'ONLY_TESTCASE must be 16 or 33, got {only_testcase!r}')

with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

for case in data.get('cases', []):
    if not case.get('enabled', True):
        continue
    if only_testcase and str(case.get('testcase', '')) != only_testcase:
        continue
    fields = [
        case.get('name', ''),
        str(case.get('testcase', '')),
        case.get('bufferUnit', ''),
        str(case.get('buffer', '')),
        case.get('tuneArg', ''),
        case.get('tuneFlag', ''),
        str(case.get('tune', '')),
        str(case.get('loopCount', '')),
    ]
    print('\t'.join(fields))
PY
}

json_emit_collector_defaults() {
    python3 - "$SWEEP_CASE_POLICY_JSON_FILE" <<'PY'
import json
import shlex
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

for key, value in data.get('collectorDefaults', {}).items():
    if value is None:
        continue
    print(f'{key}={shlex.quote(str(value))}')
PY
}

load_case_policy() {
    local section="$1"
    python3 - "$SWEEP_CASE_POLICY_JSON_FILE" "$section" <<'PY'
import json
import shlex
import sys

path, section = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

merged = dict(data.get('global', {}))
merged.update(data.get(section, {}))

mapping = {
    'maxSeconds': 'SWEEP_CASE_MAX_SECONDS',
    'minPcmMemorySamples': 'SWEEP_CASE_MIN_PCM_MEMORY_SAMPLES',
    'minPcmPcieSamples': 'SWEEP_CASE_MIN_PCM_PCIE_SAMPLES',
    'growFactor': 'SWEEP_CASE_GROW_FACTOR',
    'shrinkFactor': 'SWEEP_CASE_SHRINK_FACTOR',
    'maxAttempts': 'SWEEP_CASE_MAX_ATTEMPTS',
    'minLoopCount': 'SWEEP_CASE_MIN_LOOP_COUNT',
    'maxLoopCount': 'SWEEP_CASE_MAX_LOOP_COUNT',
    'bufferSizes': 'SWEEP_CASE_BUFFER_SIZES',
    'smCopyBytesList': 'SWEEP_CASE_SM_COPY_BYTES_LIST',
    'ptrChaseLoadBytesList': 'SWEEP_CASE_PTR_CHASE_LOAD_BYTES_LIST',
    'bufferSizesKib': 'SWEEP_CASE_BUFFER_SIZES_KIB',
}

for json_key, env_key in mapping.items():
    value = merged.get(json_key)
    if value is None:
        continue
    if isinstance(value, list):
        value = ' '.join(str(x) for x in value)
    print(f'{env_key}={shlex.quote(str(value))}')
PY
}

case_guard_warn() {
    local msg="$1"
    printf '\n********************************************************\n'
    printf '*** NVBANDWIDTH CASE WARNING ***\n'
    printf '%s\n' "$msg"
    printf '********************************************************\n\n'
}

case_guard_evaluate() {
    local outdir="$1"
    local current_loop_count="$2"
    local run_rc="${3:-}"
    local case_name="${4:-}"

    python3 - "$outdir" "$current_loop_count" "$run_rc" "$case_name" <<'PY'
from collections import defaultdict
from pathlib import Path
import csv
import math
import os
import statistics
import sys

outdir = Path(sys.argv[1])
try:
    current_loop_count = int(sys.argv[2])
except ValueError:
    current_loop_count = 1
run_rc = sys.argv[3].strip() if len(sys.argv) > 3 else ''
case_name = sys.argv[4].strip() if len(sys.argv) > 4 else ''

max_seconds = int(os.environ.get('SWEEP_CASE_MAX_SECONDS', '120'))
min_mem_samples = int(os.environ.get('SWEEP_CASE_MIN_PCM_MEMORY_SAMPLES', '2'))
min_pcie_samples = int(os.environ.get('SWEEP_CASE_MIN_PCM_PCIE_SAMPLES', '2'))
grow_factor = max(2, int(os.environ.get('SWEEP_CASE_GROW_FACTOR', '2')))
shrink_factor = max(2, int(os.environ.get('SWEEP_CASE_SHRINK_FACTOR', '2')))
min_loop_count = int(os.environ.get('SWEEP_CASE_MIN_LOOP_COUNT', '1'))
max_loop_count = int(os.environ.get('SWEEP_CASE_MAX_LOOP_COUNT', '1000000000'))

def parse_float(value):
    if value is None:
        return None
    text = str(value).strip().replace(',', '')
    if not text or text in {'-', 'N/A', '[N/A]', 'NA'}:
        return None
    try:
        parsed = float(text)
    except ValueError:
        return None
    if math.isnan(parsed) or math.isinf(parsed):
        return None
    return parsed


def median(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return None
    return statistics.median(vals)


def load_run_info():
    info = {}
    path = outdir / 'run.info'
    if not path.exists():
        return info
    for line in path.read_text(errors='replace').splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            info[key.strip()] = value.strip()
    return info


def load_pcm_memory():
    path = outdir / 'pcm-memory.csv'
    metrics = defaultdict(list)
    sample_count = 0
    if not path.exists() or path.stat().st_size == 0:
        return metrics, sample_count
    rows = list(csv.reader(path.open(newline='', errors='replace')))
    if len(rows) < 3:
        return metrics, sample_count
    groups = [cell.strip() for cell in rows[0]]
    names = [cell.strip() for cell in rows[1]]
    for row in rows[2:]:
        if len(row) < 3 or not row[0].strip():
            continue
        sample_has_value = False
        for idx, raw in enumerate(row):
            if idx >= len(names):
                continue
            name = names[idx]
            if not name or name in {'Date', 'Time'}:
                continue
            value = parse_float(raw)
            if value is None:
                continue
            group = groups[idx] if idx < len(groups) else ''
            key = f'{group}.{name}' if group else name
            metrics[key].append(value / 1000.0)
            sample_has_value = True
        if sample_has_value:
            sample_count += 1
    return metrics, sample_count


def load_pcm_pcie():
    path = outdir / 'pcm-pcie.csv'
    totals = defaultdict(list)
    sample_count = 0
    if not path.exists() or path.stat().st_size == 0:
        return totals, sample_count
    samples = []
    current = []
    header = None
    for row in csv.reader(path.open(newline='', errors='replace')):
        if not row:
            continue
        first = row[0].strip()
        if first == 'Skt':
            if current:
                samples.append(current)
                current = []
            header = [cell.strip() for cell in row]
            continue
        if header and first not in {'', '*'}:
            current.append(dict(zip(header, row)))
    if current:
        samples.append(current)
    for sample in samples:
        sample_totals = defaultdict(float)
        for row in sample:
            for key in ['PCIe Rd (B)', 'PCIe Wr (B)']:
                value = parse_float(row.get(key))
                if value is not None:
                    sample_totals[key] += value
        if sample_totals:
            sample_count += 1
            totals['PCIe Rd (B)'].append(sample_totals.get('PCIe Rd (B)', 0.0) / 1e9)
            totals['PCIe Wr (B)'].append(sample_totals.get('PCIe Wr (B)', 0.0) / 1e9)
            totals['PCIe Total (B)'].append((sample_totals.get('PCIe Rd (B)', 0.0) + sample_totals.get('PCIe Wr (B)', 0.0)) / 1e9)
    return totals, sample_count


run_info = load_run_info()
nvbw_rc = (run_info.get('nvbandwidth_rc') or run_info.get('workload_rc') or '').strip()
run_seconds_text = run_info.get('run_seconds', '').strip()
try:
    run_seconds = int(float(run_seconds_text)) if run_seconds_text else None
except ValueError:
    run_seconds = None

if run_rc == '124' or nvbw_rc == '124':
    pass
elif not run_info:
    print('status=fail')
    print('reason=missing run.info')
    sys.exit(0)

if run_rc == '124' or nvbw_rc == '124':
    pass
elif nvbw_rc not in {'', '0'}:
    print('status=fail')
    print(f'reason=nvbandwidth_rc={nvbw_rc}')
    sys.exit(0)

memory, memory_samples = load_pcm_memory()
pcie, pcie_samples = load_pcm_pcie()
mem_read_median = median(memory.get('System.Read', []))
mem_write_median = median(memory.get('System.Write', []))
mem_total_median = median(memory.get('System.Memory', []))

pcie_read_values = pcie.get('PCIe Rd (B)', [])
pcie_write_values = pcie.get('PCIe Wr (B)', [])
pcie_read_max = max(pcie_read_values) if pcie_read_values else None
pcie_write_max = max(pcie_write_values) if pcie_write_values else None

reasons = []
direction = ''

if run_rc == '124' or nvbw_rc == '124':
    reasons.append('timed out at runtime')
    direction = 'shrink'

if run_seconds is None:
    reasons.append('run_seconds missing')
elif run_seconds >= max_seconds:
    reasons.append(f'run_seconds={run_seconds}s>={max_seconds}s')
    direction = 'shrink'

if memory_samples < min_mem_samples:
    reasons.append(f'pcm_memory_samples={memory_samples}<{min_mem_samples}')
if pcie_samples < min_pcie_samples:
    reasons.append(f'pcm_pcie_samples={pcie_samples}<{min_pcie_samples}')

has_mem = (mem_read_median is not None and mem_read_median > 0) or (mem_write_median is not None and mem_write_median > 0)
if not has_mem:
    if mem_read_median is not None:
        reasons.append('system_mem_read_median_GBps=0')
    if mem_write_median is not None:
        reasons.append('system_mem_write_median_GBps=0')
    if mem_read_median is None and mem_write_median is None:
        reasons.append('system_mem_bandwidth_GBps missing')

if mem_total_median is None:
    reasons.append('system_mem_total_median_GBps missing')
elif mem_total_median <= 0:
    reasons.append('system_mem_total_median_GBps=0')

has_pcie = (pcie_read_max is not None and pcie_read_max > 0.001) or (pcie_write_max is not None and pcie_write_max > 0.001)
if not has_pcie:
    if pcie_read_max is not None:
        reasons.append('system_pcie_read_max_GBps<=0.001')
    if pcie_write_max is not None:
        reasons.append('system_pcie_write_max_GBps<=0.001')
    if pcie_read_max is None and pcie_write_max is None:
        reasons.append('system_pcie_bandwidth_GBps missing')

if not reasons:
    print('status=ok')
    sys.exit(0)

if not direction:
    direction = 'grow'

if direction == 'grow':
    next_loop_count = min(max_loop_count, max(min_loop_count, current_loop_count * grow_factor))
else:
    next_loop_count = max(min_loop_count, min(max_loop_count, max(1, current_loop_count // shrink_factor)))

if next_loop_count == current_loop_count:
    print('status=fail')
    print('reason=' + '; '.join(reasons) + '; loop_count_clamped')
else:
    print('status=retry')
    print(f'direction={direction}')
    print(f'next_loop_count={next_loop_count}')
    print('reason=' + '; '.join(reasons))
PY
}
