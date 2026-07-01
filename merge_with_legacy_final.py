#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

KEY_FIELDS = ['testcase','run_label','ro_state','config_tag','tuning_param_name','tuning_param_value_bytes','buffer_MiB']
MEASURE_BASES = [
    'loop_count','nvbandwidth_SUM_GBps','system_mem_read_median_GBps','system_mem_read_p95_GBps','system_mem_read_max_GBps',
    'system_mem_write_median_GBps','system_mem_total_median_GBps','target_socket_mem_read_median_GBps',
    'system_pcie_read_median_GBps','system_pcie_read_p95_GBps','system_pcie_read_max_GBps','system_pcie_write_median_GBps',
    'system_pcie_total_median_GBps','system_pcie_total_p95_GBps','nvidia_rxpcie_median_GBps','nvidia_rxpcie_p95_GBps',
    'nvidia_txpcie_median_GBps','nvidia_txpcie_p95_GBps','nvidia_pcie_total_median_GBps','nvidia_pcie_total_p95_GBps',
    'pcm_memory_samples','pcm_pcie_samples','nvidia_dmon_rows','run_seconds'
]
META_FIELDS = [
    'data_source','source_priority','source_file','source_note','source_kind','sweep_root','summary_csv',
    *KEY_FIELDS,
    'repeat_count','statuses','analysis_generated_at','cuda_visible_devices','numa_node','cpu_bind','sample_interval','nvidia_query_interval','nvidia_dmon_interval','pcm_tools',
    'present_in_summary1','present_in_summary2'
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Append legacy final_intel_pcm_summary.csv to current merged nvbandwidth results.')
    parser.add_argument('--current-dir', type=Path, default=Path('combined_results_20260701_021706_with_low_sample_reruns_20260701_053927'))
    parser.add_argument('--legacy-final', type=Path, default=Path('final_intel_pcm_summary.csv'))
    parser.add_argument('--output-dir', type=Path, default=None)
    return parser.parse_args()


def read_csv(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    with path.open(newline='', errors='replace') as f:
        reader = csv.DictReader(f)
        return list(reader), reader.fieldnames or []


def safe_int(x: str | None) -> int:
    try:
        return int(float(str(x or '').strip()))
    except Exception:
        return 0


def pick(row: dict[str, str], *names: str) -> str:
    for name in names:
        val = row.get(name, '')
        if str(val).strip() != '':
            return val
    return ''


def normalize_current_agg(row: dict[str, str], current_agg_path: Path) -> dict[str, str]:
    out = dict(row)
    out.update({
        'data_source': 'current_with_low_sample_reruns',
        'source_priority': '2',
        'source_file': str(current_agg_path),
        'source_note': 'latest full sweep aggregate after low-sample rerun merge; generally 3 repeats per point',
    })
    for base in MEASURE_BASES:
        if f'{base}_mean' not in out and base in row:
            out[f'{base}_mean'] = row.get(base, '')
    return out


def normalize_legacy(row: dict[str, str], legacy_path: Path) -> dict[str, str]:
    out = dict(row)
    out.update({
        'data_source': 'legacy_final_intel_pcm_summary',
        'source_priority': '1',
        'source_file': str(legacy_path),
        'source_note': 'older final_intel_pcm_summary.csv; many points were collected once or from older summary merge',
        'source_kind': 'legacy_final_summary',
        'sweep_root': row.get('sweep_root',''),
        'summary_csv': row.get('summary_csv',''),
        'repeat_count': pick(row, 'source_row_count', 'repeat_count') or ('1' if row.get('present_in_summary1','') or row.get('present_in_summary2','') else ''),
        'statuses': row.get('status',''),
    })
    for base in MEASURE_BASES:
        scalar = row.get(base, '')
        if scalar:
            out.setdefault(f'{base}_mean', scalar)
            out.setdefault(f'{base}_median', scalar)
            out.setdefault(f'{base}_min', scalar)
            out.setdefault(f'{base}_max', scalar)
            out.setdefault(f'{base}_n', pick(row, 'source_row_count') or out.get('repeat_count',''))
        if not out.get(f'{base}_mean') and row.get(base):
            out[f'{base}_mean'] = row.get(base,'')
    return out


def ordered_union(rows: list[dict[str, str]], preferred: list[str]) -> list[str]:
    fields: list[str] = []
    seen: set[str] = set()
    for f in preferred:
        if f not in seen:
            fields.append(f)
            seen.add(f)
    for r in rows:
        for f in r:
            if f not in seen:
                fields.append(f)
                seen.add(f)
    return fields


def write_csv(path: Path, rows: list[dict[str, str]], preferred: list[str]) -> None:
    fields = ordered_union(rows, preferred)
    with path.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    args = parse_args()
    current_dir = args.current_dir
    legacy_path = args.legacy_final
    outdir = args.output_dir or Path(f'all_results_with_legacy_final_{datetime.now().strftime("%Y%m%d_%H%M%S")}')
    outdir.mkdir(parents=True, exist_ok=True)

    current_agg_path = current_dir / 'latest_full_sweep_repeat_aggregate.csv'
    current_rows_path = current_dir / 'latest_full_sweep_rows.csv'

    current_agg, _ = read_csv(current_agg_path)
    current_repeat, _ = read_csv(current_rows_path)
    legacy_rows, _ = read_csv(legacy_path)

    all_point_rows = [normalize_current_agg(r, current_agg_path) for r in current_agg] + [normalize_legacy(r, legacy_path) for r in legacy_rows]
    all_point_rows.sort(key=lambda r: (safe_int(r.get('testcase')), r.get('run_label',''), r.get('tuning_param_name',''), safe_int(r.get('tuning_param_value_bytes')), safe_int(r.get('buffer_MiB')), -safe_int(r.get('source_priority'))))

    key_counts: dict[tuple[str, ...], Counter[str]] = defaultdict(Counter)
    for r in all_point_rows:
        key = tuple(r.get(f,'') for f in KEY_FIELDS)
        key_counts[key][r['data_source']] += 1

    key_summary: list[dict[str, str]] = []
    for key, counts in key_counts.items():
        rec = {f: v for f, v in zip(KEY_FIELDS, key)}
        rec['current_rows'] = str(counts.get('current_with_low_sample_reruns', 0))
        rec['legacy_rows'] = str(counts.get('legacy_final_intel_pcm_summary', 0))
        rec['total_rows'] = str(sum(counts.values()))
        rec['presence'] = 'both' if counts.get('current_with_low_sample_reruns') and counts.get('legacy_final_intel_pcm_summary') else ('current_only' if counts.get('current_with_low_sample_reruns') else 'legacy_only')
        key_summary.append(rec)
    key_summary.sort(key=lambda r: (safe_int(r['testcase']), r['run_label'], r['tuning_param_name'], safe_int(r['tuning_param_value_bytes']), safe_int(r['buffer_MiB'])))

    all_detail_rows: list[dict[str, str]] = []
    for r in current_repeat:
        row = dict(r)
        row['data_source'] = 'current_with_low_sample_reruns_repeat_rows'
        row['source_file'] = str(current_rows_path)
        row['source_note'] = 'repeat-level rows from current merged dataset'
        all_detail_rows.append(row)
    for r in legacy_rows:
        row = normalize_legacy(r, legacy_path)
        row['repeat'] = row.get('repeat','') or 'legacy'
        row['data_source'] = 'legacy_final_intel_pcm_summary_point_rows'
        all_detail_rows.append(row)

    stats = [
        {'dataset': 'current_point_aggregate', 'rows': str(len(current_agg))},
        {'dataset': 'current_repeat_rows', 'rows': str(len(current_repeat))},
        {'dataset': 'legacy_final_point_rows', 'rows': str(len(legacy_rows))},
        {'dataset': 'all_point_rows', 'rows': str(len(all_point_rows))},
        {'dataset': 'all_detail_rows', 'rows': str(len(all_detail_rows))},
    ]
    for presence, count in Counter(r['presence'] for r in key_summary).items():
        stats.append({'dataset': f'key_presence_{presence}', 'rows': str(count)})

    preferred = META_FIELDS + [f'{base}_{stat}' for base in MEASURE_BASES for stat in ['n','mean','median','min','max','stdev','cv']] + MEASURE_BASES
    write_csv(outdir / 'all_point_summary_with_sources.csv', all_point_rows, preferred)
    write_csv(outdir / 'all_detail_rows_with_legacy.csv', all_detail_rows, ['data_source','source_file','source_note','source_kind','testcase','run_label','ro_state','config_tag','tuning_param_name','tuning_param_value_bytes','buffer_MiB','repeat','repeat_count','status','statuses','nvbandwidth_rc','run_seconds','result_dir'])
    write_csv(outdir / 'key_coverage_current_vs_legacy.csv', key_summary, [*KEY_FIELDS,'presence','current_rows','legacy_rows','total_rows'])
    write_csv(outdir / 'source_counts.csv', stats, ['dataset','rows'])

    presence_counts = Counter(r['presence'] for r in key_summary)
    legacy_run_labels = Counter(r.get('run_label','') for r in legacy_rows)
    lines = [
        '# All results including legacy final_intel_pcm_summary',
        '',
        f'- Generated at: `{datetime.now().isoformat(timespec="seconds")}`',
        f'- Current merged base: `{current_dir}`',
        f'- Legacy input: `{legacy_path}`',
        f'- Output directory: `{outdir}`',
        '',
        '## Row counts',
        '',
        '| dataset | rows |',
        '| --- | ---: |',
    ]
    for rec in stats:
        lines.append(f"| {rec['dataset']} | {rec['rows']} |")
    lines += [
        '',
        '## Key coverage',
        '',
        '| presence | point keys |',
        '| --- | ---: |',
    ]
    for key, value in sorted(presence_counts.items()):
        lines.append(f'| {key} | {value} |')
    lines += [
        '',
        '## Notes',
        '',
        '- `all_point_summary_with_sources.csv` is the main all-data point-level table. It appends current aggregate rows and legacy final rows, preserving `data_source`.',
        '- `all_detail_rows_with_legacy.csv` contains current repeat-level rows plus legacy final rows as point-level legacy records. Do not interpret legacy rows as true per-repeat rows unless their source indicates that.',
        '- `key_coverage_current_vs_legacy.csv` shows whether each testcase/run_label/parameter/buffer key exists in current data, legacy data, or both.',
        '- Current data should be preferred for the latest controlled reruns; legacy rows are included for completeness and historical comparison.',
        '',
        '## Legacy run label distribution',
        '',
        '| run_label | rows |',
        '| --- | ---: |',
    ]
    for key, value in legacy_run_labels.most_common():
        lines.append(f'| {key} | {value} |')
    lines += [
        '',
        '## Files',
        '',
        '- `all_point_summary_with_sources.csv`',
        '- `all_detail_rows_with_legacy.csv`',
        '- `key_coverage_current_vs_legacy.csv`',
        '- `source_counts.csv`',
        '- `README.md`',
    ]
    (outdir / 'README.md').write_text('\n'.join(lines) + '\n')

    print(f'Output directory: {outdir}')
    print(f'current aggregate rows: {len(current_agg)}')
    print(f'current repeat rows: {len(current_repeat)}')
    print(f'legacy final rows: {len(legacy_rows)}')
    print(f'all point rows: {len(all_point_rows)}')
    print(f'all detail rows: {len(all_detail_rows)}')
    print(f'key presence: {dict(presence_counts)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
