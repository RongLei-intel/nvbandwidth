#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
import re
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path

SWEEP_RE = re.compile(r"^intel_pcm_nvbw_t(?P<testcase>\d+)_(?P<run_label>.+?)_sweep")
RUN_LABEL_RE = re.compile(r"^ro_(?P<ro_state>on|off)_(?P<config_tag>c000|ff00)")
KEY_FIELDS = ["testcase", "run_label", "ro_state", "config_tag", "tuning_param_name", "tuning_param_value_bytes", "buffer_MiB"]
NUM_FIELDS = [
    "loop_count", "nvbandwidth_SUM_GBps", "system_mem_read_median_GBps", "system_mem_read_p95_GBps", "system_mem_read_max_GBps",
    "system_mem_write_median_GBps", "system_mem_total_median_GBps", "target_socket_mem_read_median_GBps",
    "system_pcie_read_median_GBps", "system_pcie_read_p95_GBps", "system_pcie_read_max_GBps", "system_pcie_write_median_GBps",
    "system_pcie_total_median_GBps", "system_pcie_total_p95_GBps", "nvidia_rxpcie_median_GBps", "nvidia_rxpcie_p95_GBps",
    "nvidia_txpcie_median_GBps", "nvidia_txpcie_p95_GBps", "nvidia_pcie_total_median_GBps", "nvidia_pcie_total_p95_GBps",
    "pcm_memory_samples", "pcm_pcie_samples", "nvidia_dmon_rows", "run_seconds",
]

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Merge low-sample rerun summaries into an existing combined_results directory.")
    p.add_argument("--base", type=Path, default=Path("combined_results_20260701_021706"), help="Existing combined_results directory.")
    p.add_argument("--rerun-root", type=Path, required=True, help="Rerun output root produced by rerun_low_sample_cases_min15.sh.")
    p.add_argument("--output", type=Path, default=None, help="Output combined directory. Defaults to <base>_with_low_sample_reruns_<timestamp>.")
    p.add_argument("--min-samples", type=float, default=15.0)
    return p.parse_args()

def parse_float(x: str | None) -> float | None:
    if x is None:
        return None
    s = str(x).strip().replace(',', '')
    if not s or s in {'NA','N/A','-','[N/A]'}:
        return None
    try:
        v = float(s)
    except ValueError:
        return None
    return v if math.isfinite(v) else None

def fmt(v: float | None, digits: int = 6) -> str:
    return '' if v is None else f"{v:.{digits}f}"

def safe_int(x: str | None) -> int:
    try:
        return int(float(str(x or '').strip()))
    except Exception:
        return 0

def read_kv(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text(errors='replace').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            out[k.strip()] = v.strip()
    return out

def row_key(row: dict[str, str]) -> tuple[str, ...]:
    return tuple(row.get(f, '') for f in KEY_FIELDS)

def rel(path: Path, root: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except Exception:
        return str(path)

def parse_summary_meta(summary: Path, repo_root: Path) -> dict[str, str]:
    sweep_root = summary.parent
    m = SWEEP_RE.match(sweep_root.name)
    meta = {
        'source_kind': 'low_sample_rerun',
        'sweep_root': rel(sweep_root, repo_root),
        'summary_csv': rel(summary, repo_root),
        'testcase': '', 'run_label': '', 'ro_state': '', 'config_tag': '', 'sweep_timestamp': '',
    }
    if m:
        meta.update(m.groupdict())
    lm = RUN_LABEL_RE.match(meta.get('run_label', ''))
    if lm:
        meta.update(lm.groupdict())
    info_files = sorted(sweep_root.glob('sweep*.info'))
    info = read_kv(info_files[0]) if info_files else {}
    for k in ['cuda_visible_devices','numa_node','cpu_bind','sample_interval','nvidia_query_interval','nvidia_dmon_interval','pcm_tools','retries','small_buffer_max_mib','small_buffer_target_transfer_mib']:
        meta[k] = info.get(k, '')
    if not meta['testcase']:
        meta['testcase'] = info.get('testcase', '')
    meta['sweep_start_time'] = info.get('start_time', '')
    return meta

def normalize_rerun_row(row: dict[str, str], summary: Path, repo_root: Path) -> dict[str, str]:
    out = parse_summary_meta(summary, repo_root)
    out.update(row)
    if row.get('sm_copy_bytes'):
        out['tuning_param_name'] = 'sm_copy_bytes'
        out['tuning_param_value_bytes'] = row.get('sm_copy_bytes', '')
    elif row.get('ptr_chase_load_bytes'):
        out['tuning_param_name'] = 'ptr_chase_load_bytes'
        out['tuning_param_value_bytes'] = row.get('ptr_chase_load_bytes', '')
    out.setdefault('repeat', '1')
    if not out['repeat']:
        out['repeat'] = '1'
    result_dir = out.get('result_dir', '')
    rp = repo_root / result_dir if result_dir else None
    if rp and rp.exists():
        out['result_dir'] = rel(rp, repo_root)
        ri = read_kv(rp / 'run.info')
        out['run_seconds'] = ri.get('run_seconds', '')
        out['run_start_time'] = ri.get('start_time', '')
        out['run_end_time'] = ri.get('end_time', '')
        out['loop_count'] = out.get('loop_count') or ri.get('loop_count', '')
        out['nvbandwidth_rc'] = out.get('nvbandwidth_rc') or ri.get('nvbandwidth_rc', '')
    return out

def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline='', errors='replace') as f:
        return list(csv.DictReader(f))

def write_csv(path: Path, rows: list[dict[str, str]], preferred: list[str]) -> None:
    fields: list[str] = []
    seen: set[str] = set()
    for f in preferred:
        if f not in seen:
            fields.append(f); seen.add(f)
    for r in rows:
        for f in r:
            if f not in seen:
                fields.append(f); seen.add(f)
    with path.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        w.writeheader(); w.writerows(rows)

def aggregate(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    groups: dict[tuple[str, ...], list[dict[str, str]]] = defaultdict(list)
    for r in rows:
        groups[row_key(r)].append(r)
    out: list[dict[str, str]] = []
    for key, group in groups.items():
        base = {f: v for f, v in zip(KEY_FIELDS, key)}
        base['repeat_count'] = str(len(group))
        base['statuses'] = ';'.join(sorted(set(g.get('status','') for g in group)))
        for f in ['source_kind','sweep_root','summary_csv','sweep_start_time','cuda_visible_devices','numa_node','cpu_bind','sample_interval','nvidia_dmon_interval','pcm_tools']:
            base[f] = group[0].get(f, '')
        for nf in NUM_FIELDS:
            vals = [parse_float(g.get(nf, '')) for g in group]
            vals = [v for v in vals if v is not None]
            base[f'{nf}_n'] = str(len(vals))
            base[f'{nf}_mean'] = fmt(statistics.fmean(vals) if vals else None)
            base[f'{nf}_median'] = fmt(statistics.median(vals) if vals else None)
            base[f'{nf}_min'] = fmt(min(vals) if vals else None)
            base[f'{nf}_max'] = fmt(max(vals) if vals else None)
            if len(vals) >= 2:
                mean = statistics.fmean(vals)
                stdev = statistics.stdev(vals)
                base[f'{nf}_stdev'] = fmt(stdev)
                base[f'{nf}_cv'] = fmt(stdev / abs(mean) if abs(mean) > 1e-12 else None)
            else:
                base[f'{nf}_stdev'] = ''
                base[f'{nf}_cv'] = ''
        out.append(base)
    return sorted(out, key=lambda r: (safe_int(r.get('testcase')), r.get('run_label',''), r.get('tuning_param_name',''), safe_int(r.get('tuning_param_value_bytes')), safe_int(r.get('buffer_MiB'))))

def build_anomalies(rows: list[dict[str, str]], agg_rows: list[dict[str, str]], min_samples: float) -> list[dict[str, str]]:
    anomalies: list[dict[str, str]] = []
    def add(row: dict[str, str], severity: str, reason: str, detail: str) -> None:
        rec = {f: row.get(f, '') for f in ['testcase','run_label','ro_state','config_tag','tuning_param_name','tuning_param_value_bytes','buffer_MiB','repeat','result_dir','summary_csv']}
        rec.update({'severity': severity, 'reason': reason, 'detail': detail})
        anomalies.append(rec)
    for r in rows:
        mem = parse_float(r.get('pcm_memory_samples'))
        pcie = parse_float(r.get('pcm_pcie_samples'))
        if mem is not None and mem < min_samples:
            add(r, 'medium', 'low_pcm_memory_samples_after_merge', f'pcm_memory_samples={mem}')
        if pcie is not None and pcie < min_samples:
            add(r, 'medium', 'low_pcm_pcie_samples_after_merge', f'pcm_pcie_samples={pcie}')
        if r.get('status','') not in {'', 'ok'} or r.get('nvbandwidth_rc','') not in {'', '0'}:
            add(r, 'high', 'non_ok_status_or_rc', f"status={r.get('status','')} nvbandwidth_rc={r.get('nvbandwidth_rc','')}")
    for ar in agg_rows:
        if safe_int(ar.get('repeat_count')) != 3:
            add(ar, 'high', 'repeat_count_not_3_after_merge', f"repeat_count={ar.get('repeat_count')}")
    return anomalies

def main() -> int:
    args = parse_args()
    repo_root = Path.cwd().resolve()
    base = args.base.resolve()
    rerun_root = args.rerun_root.resolve()
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output = args.output.resolve() if args.output else repo_root / f'{base.name}_with_low_sample_reruns_{timestamp}'
    output.mkdir(parents=True, exist_ok=True)

    base_rows = read_csv(base / 'latest_full_sweep_rows.csv')
    rerun_summaries = sorted(rerun_root.glob('**/intel_pcm_summary.csv'))
    if not rerun_summaries:
        raise SystemExit(f'No intel_pcm_summary.csv found under {rerun_root}')
    rerun_rows: list[dict[str, str]] = []
    for summary in rerun_summaries:
        for row in read_csv(summary):
            rerun_rows.append(normalize_rerun_row(row, summary, repo_root))

    rerun_keys = {row_key(r) for r in rerun_rows}
    kept_base_rows = [r for r in base_rows if row_key(r) not in rerun_keys]
    merged_rows = kept_base_rows + rerun_rows
    merged_rows.sort(key=lambda r: (safe_int(r.get('testcase')), r.get('run_label',''), r.get('tuning_param_name',''), safe_int(r.get('tuning_param_value_bytes')), safe_int(r.get('buffer_MiB')), safe_int(r.get('repeat'))))
    agg_rows = aggregate(merged_rows)
    anomalies = build_anomalies(merged_rows, agg_rows, args.min_samples)

    preferred = ['source_kind','sweep_root','summary_csv','testcase','run_label','ro_state','config_tag','tuning_param_name','tuning_param_value_bytes','buffer_MiB','repeat','status','nvbandwidth_rc','run_seconds','pcm_memory_samples','pcm_pcie_samples','result_dir']
    write_csv(output / 'latest_full_sweep_rows.csv', merged_rows, preferred)
    write_csv(output / 'latest_full_sweep_repeat_aggregate.csv', agg_rows, KEY_FIELDS + ['repeat_count','statuses'])
    write_csv(output / 'low_sample_rerun_rows.csv', rerun_rows, preferred)
    write_csv(output / 'anomalies_after_low_sample_merge.csv', anomalies, ['severity','reason','detail','testcase','run_label','ro_state','config_tag','tuning_param_name','tuning_param_value_bytes','buffer_MiB','repeat','result_dir','summary_csv'])

    manifest = output / 'merge_manifest.txt'
    manifest.write_text('\n'.join([
        f'generated_at={datetime.now().isoformat(timespec="seconds")}',
        f'base={base}',
        f'rerun_root={rerun_root}',
        f'output={output}',
        f'base_rows={len(base_rows)}',
        f'rerun_summary_files={len(rerun_summaries)}',
        f'rerun_rows={len(rerun_rows)}',
        f'replaced_point_keys={len(rerun_keys)}',
        f'merged_rows={len(merged_rows)}',
        f'aggregated_points={len(agg_rows)}',
        f'anomalies_after_merge={len(anomalies)}',
        f'min_samples={args.min_samples}',
    ]) + '\n')

    report = output / 'README.md'
    report.write_text('\n'.join([
        '# Combined results with low-sample reruns',
        '',
        f'- Base: `{base}`',
        f'- Rerun root: `{rerun_root}`',
        f'- Rerun summary files: `{len(rerun_summaries)}`',
        f'- Rerun rows: `{len(rerun_rows)}`',
        f'- Replaced point keys: `{len(rerun_keys)}`',
        f'- Merged rows: `{len(merged_rows)}`',
        f'- Aggregated points: `{len(agg_rows)}`',
        f'- Remaining low-sample/non-ok anomalies: `{len(anomalies)}`',
        '',
        'Files:',
        '',
        '- `latest_full_sweep_rows.csv`',
        '- `latest_full_sweep_repeat_aggregate.csv`',
        '- `low_sample_rerun_rows.csv`',
        '- `anomalies_after_low_sample_merge.csv`',
        '- `merge_manifest.txt`',
    ]) + '\n')

    print(f'Output: {output}')
    print(f'Rerun summary files: {len(rerun_summaries)}')
    print(f'Rerun rows: {len(rerun_rows)}')
    print(f'Replaced point keys: {len(rerun_keys)}')
    print(f'Merged rows: {len(merged_rows)}')
    print(f'Aggregated points: {len(agg_rows)}')
    print(f'Anomalies after merge: {len(anomalies)}')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
