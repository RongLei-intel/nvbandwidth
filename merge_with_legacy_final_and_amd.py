#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

KEY_FIELDS = ['system', 'testcase', 'run_label', 'ro_state', 'config_tag', 'tuning_param_name', 'tuning_param_value_bytes', 'buffer_MiB']
MEASURE_BASES = [
    'loop_count', 'nvbandwidth_SUM_GBps', 'system_mem_read_median_GBps', 'system_mem_read_p95_GBps', 'system_mem_read_max_GBps',
    'system_mem_write_median_GBps', 'system_mem_total_median_GBps', 'target_socket_mem_read_median_GBps',
    'system_pcie_read_median_GBps', 'system_pcie_read_p95_GBps', 'system_pcie_read_max_GBps', 'system_pcie_write_median_GBps',
    'system_pcie_total_median_GBps', 'system_pcie_total_p95_GBps', 'nvidia_rxpcie_median_GBps', 'nvidia_rxpcie_p95_GBps',
    'nvidia_txpcie_median_GBps', 'nvidia_txpcie_p95_GBps', 'nvidia_pcie_total_median_GBps', 'nvidia_pcie_total_p95_GBps',
    'pcm_memory_samples', 'pcm_pcie_samples', 'nvidia_dmon_rows', 'run_seconds'
]
META_FIELDS = [
    'data_source', 'source_priority', 'system', 'source_file', 'source_note', 'source_kind', 'sweep_root', 'summary_csv',
    *KEY_FIELDS,
    'repeat_count', 'statuses', 'analysis_generated_at', 'cuda_visible_devices', 'numa_node', 'cpu_bind', 'sample_interval',
    'nvidia_query_interval', 'nvidia_dmon_interval', 'pcm_tools', 'present_in_summary1', 'present_in_summary2'
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Append legacy final_intel_pcm_summary.csv and AMD summary to the current merged nvbandwidth results.')
    parser.add_argument('--current-dir', type=Path, default=Path('combined_results_20260701_021706_with_low_sample_reruns_20260701_053927'))
    parser.add_argument('--legacy-final', type=Path, default=Path('final_intel_pcm_summary.csv'))
    parser.add_argument('--amd-summary', type=Path, default=Path('amd_4groups_summary.csv'))
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
        'source_priority': '3',
        'system': 'intel',
        'source_file': str(current_agg_path),
        'source_note': 'latest full sweep aggregate after low-sample rerun merge; generally 3 repeats per point',
        'source_kind': 'current_point_aggregate',
    })
    for base in MEASURE_BASES:
        if f'{base}_mean' not in out and base in row:
            out[f'{base}_mean'] = row.get(base, '')
    return out


def normalize_legacy(row: dict[str, str], legacy_path: Path) -> dict[str, str]:
    out = dict(row)
    out.update({
        'data_source': 'legacy_final_intel_pcm_summary',
        'source_priority': '2',
        'system': 'intel',
        'source_file': str(legacy_path),
        'source_note': 'older final_intel_pcm_summary.csv; many points were collected once or from older summary merge',
        'source_kind': 'legacy_final_summary',
        'sweep_root': row.get('sweep_root', ''),
        'summary_csv': row.get('summary_csv', ''),
        'repeat_count': pick(row, 'source_row_count', 'repeat_count') or ('1' if row.get('present_in_summary1', '') or row.get('present_in_summary2', '') else ''),
        'statuses': row.get('status', ''),
    })
    for base in MEASURE_BASES:
        scalar = row.get(base, '')
        if scalar:
            out.setdefault(f'{base}_mean', scalar)
            out.setdefault(f'{base}_median', scalar)
            out.setdefault(f'{base}_min', scalar)
            out.setdefault(f'{base}_max', scalar)
            out.setdefault(f'{base}_n', pick(row, 'source_row_count') or out.get('repeat_count', ''))
        if not out.get(f'{base}_mean') and row.get(base):
            out[f'{base}_mean'] = row.get(base, '')
    return out


def normalize_amd(row: dict[str, str], amd_path: Path) -> dict[str, str]:
    out = dict(row)
    testcase = pick(row, 'testcase')
    if testcase == '33':
        tuning_param_name = row.get('tuning_param_name', '') or ('ptr_chase_load_bytes' if row.get('ptr_chase_load_bytes', '').strip() else '')
        tuning_param_value_bytes = pick(row, 'tuning_param_value_bytes', 'ptr_chase_load_bytes')
    else:
        tuning_param_name = row.get('tuning_param_name', '') or ('sm_copy_bytes' if row.get('sm_copy_bytes', '').strip() else '')
        tuning_param_value_bytes = pick(row, 'tuning_param_value_bytes', 'sm_copy_bytes')
    out.update({
        'data_source': 'amd_4groups_summary',
        'source_priority': '1',
        'system': 'amd',
        'source_file': str(amd_path),
        'source_note': 'AMD 4-groups summary merged as point-level rows; no repeat-level breakdown available',
        'source_kind': 'amd_point_summary',
        'sweep_root': row.get('sweep_root', ''),
        'summary_csv': row.get('source_csv', '') or str(amd_path),
        'run_label': row.get('group', '') or row.get('run_label', ''),
        'tuning_param_name': tuning_param_name,
        'tuning_param_value_bytes': tuning_param_value_bytes,
        'repeat_count': '1',
        'statuses': row.get('status', ''),
    })
    for base in MEASURE_BASES:
        scalar = row.get(base, '')
        if scalar:
            out.setdefault(f'{base}_mean', scalar)
            out.setdefault(f'{base}_median', scalar)
            out.setdefault(f'{base}_min', scalar)
            out.setdefault(f'{base}_max', scalar)
            out.setdefault(f'{base}_n', '1')
        if not out.get(f'{base}_mean') and row.get(base):
            out[f'{base}_mean'] = row.get(base, '')
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
    amd_path = args.amd_summary
    outdir = args.output_dir or Path(f'all_results_with_legacy_final_and_amd_{datetime.now().strftime("%Y%m%d_%H%M%S")}')
    outdir.mkdir(parents=True, exist_ok=True)

    current_agg_path = current_dir / 'latest_full_sweep_repeat_aggregate.csv'
    current_rows_path = current_dir / 'latest_full_sweep_rows.csv'

    current_agg, _ = read_csv(current_agg_path)
    current_repeat, _ = read_csv(current_rows_path)
    legacy_rows, _ = read_csv(legacy_path)
    amd_rows, _ = read_csv(amd_path)

    all_point_rows = (
        [normalize_current_agg(r, current_agg_path) for r in current_agg]
        + [normalize_legacy(r, legacy_path) for r in legacy_rows]
        + [normalize_amd(r, amd_path) for r in amd_rows]
    )
    all_point_rows.sort(key=lambda r: (r.get('system', ''), safe_int(r.get('testcase')), r.get('run_label', ''), r.get('tuning_param_name', ''), safe_int(r.get('tuning_param_value_bytes')), safe_int(r.get('buffer_MiB')), -safe_int(r.get('source_priority'))))

    key_counts: dict[tuple[str, ...], Counter[str]] = defaultdict(Counter)
    for r in all_point_rows:
        key = tuple(r.get(f, '') for f in KEY_FIELDS)
        key_counts[key][r['data_source']] += 1

    key_summary: list[dict[str, str]] = []
    for key, counts in key_counts.items():
        rec = {f: v for f, v in zip(KEY_FIELDS, key)}
        rec['current_rows'] = str(counts.get('current_with_low_sample_reruns', 0))
        rec['legacy_rows'] = str(counts.get('legacy_final_intel_pcm_summary', 0))
        rec['amd_rows'] = str(counts.get('amd_4groups_summary', 0))
        rec['total_rows'] = str(sum(counts.values()))
        if counts.get('current_with_low_sample_reruns') and counts.get('legacy_final_intel_pcm_summary') and counts.get('amd_4groups_summary'):
            rec['presence'] = 'all_three'
        elif counts.get('current_with_low_sample_reruns') and counts.get('legacy_final_intel_pcm_summary'):
            rec['presence'] = 'current_and_legacy'
        elif counts.get('current_with_low_sample_reruns'):
            rec['presence'] = 'current_only'
        elif counts.get('legacy_final_intel_pcm_summary'):
            rec['presence'] = 'legacy_only'
        elif counts.get('amd_4groups_summary'):
            rec['presence'] = 'amd_only'
        else:
            rec['presence'] = 'unknown'
        key_summary.append(rec)
    key_summary.sort(key=lambda r: (r.get('system', ''), safe_int(r['testcase']), r['run_label'], r['tuning_param_name'], safe_int(r['tuning_param_value_bytes']), safe_int(r['buffer_MiB'])))

    all_detail_rows: list[dict[str, str]] = []
    for r in current_repeat:
        row = dict(r)
        row['system'] = 'intel'
        row['data_source'] = 'current_with_low_sample_reruns_repeat_rows'
        row['source_file'] = str(current_rows_path)
        row['source_note'] = 'repeat-level rows from current merged dataset'
        all_detail_rows.append(row)
    for r in legacy_rows:
        row = normalize_legacy(r, legacy_path)
        row['repeat'] = row.get('repeat', '') or 'legacy_point'
        row['data_source'] = 'legacy_final_intel_pcm_summary_point_rows'
        all_detail_rows.append(row)
    for r in amd_rows:
        row = normalize_amd(r, amd_path)
        row['repeat'] = row.get('repeat', '') or 'amd_point'
        row['data_source'] = 'amd_4groups_summary_point_rows'
        all_detail_rows.append(row)

    stats = [
        {'dataset': 'current_point_aggregate', 'rows': str(len(current_agg))},
        {'dataset': 'current_repeat_rows', 'rows': str(len(current_repeat))},
        {'dataset': 'legacy_final_point_rows', 'rows': str(len(legacy_rows))},
        {'dataset': 'amd_point_rows', 'rows': str(len(amd_rows))},
        {'dataset': 'all_point_rows', 'rows': str(len(all_point_rows))},
        {'dataset': 'all_detail_rows', 'rows': str(len(all_detail_rows))},
    ]
    for presence, count in Counter(r['presence'] for r in key_summary).items():
        stats.append({'dataset': f'key_presence_{presence}', 'rows': str(count)})

    system_counts = Counter(r.get('system', '') for r in all_point_rows)
    detail_system_counts = Counter(r.get('system', '') for r in all_detail_rows)

    preferred = META_FIELDS + [f'{base}_{stat}' for base in MEASURE_BASES for stat in ['n', 'mean', 'median', 'min', 'max', 'stdev', 'cv']] + MEASURE_BASES
    write_csv(outdir / 'all_point_summary_with_sources_and_system.csv', all_point_rows, preferred)
    write_csv(outdir / 'all_detail_rows_with_legacy_and_amd.csv', all_detail_rows, ['data_source', 'source_file', 'source_note', 'source_kind', 'system', 'testcase', 'run_label', 'ro_state', 'config_tag', 'tuning_param_name', 'tuning_param_value_bytes', 'buffer_MiB', 'repeat', 'repeat_count', 'status', 'statuses', 'nvbandwidth_rc', 'run_seconds', 'result_dir'])
    write_csv(outdir / 'key_coverage_current_vs_legacy_vs_amd.csv', key_summary, [*KEY_FIELDS, 'presence', 'current_rows', 'legacy_rows', 'amd_rows', 'total_rows'])
    write_csv(outdir / 'source_counts.csv', stats, ['dataset', 'rows'])
    write_csv(outdir / 'system_counts.csv', [
        {'dataset': 'all_point_rows', 'system': sys, 'rows': str(count)}
        for sys, count in sorted(system_counts.items())
    ] + [
        {'dataset': 'all_detail_rows', 'system': sys, 'rows': str(count)}
        for sys, count in sorted(detail_system_counts.items())
    ], ['dataset', 'system', 'rows'])

    presence_counts = Counter(r['presence'] for r in key_summary)
    amd_run_labels = Counter(r.get('run_label', '') for r in all_point_rows if r.get('system', '') == 'amd')
    legacy_run_labels = Counter(r.get('run_label', '') for r in legacy_rows)
    lines = [
        '# All results including legacy final_intel_pcm_summary and AMD summary',
        '',
        f'- Generated at: `{datetime.now().isoformat(timespec="seconds")}`',
        f'- Current merged base: `{current_dir}`',
        f'- Legacy input: `{legacy_path}`',
        f'- AMD input: `{amd_path}`',
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
        '## System counts',
        '',
        '| table | system | rows |',
        '| --- | --- | ---: |',
    ]
    for sys, count in sorted(system_counts.items()):
        lines.append(f'| all_point_rows | {sys} | {count} |')
    for sys, count in sorted(detail_system_counts.items()):
        lines.append(f'| all_detail_rows | {sys} | {count} |')
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
        '- `all_point_summary_with_sources_and_system.csv` is the main all-data point-level table. It appends current aggregate rows, legacy final rows, and AMD point rows, and adds a `system` column so Intel and AMD stay separate.',
        '- `all_detail_rows_with_legacy_and_amd.csv` contains current repeat-level rows plus legacy final rows and AMD summary rows as point-level records. Legacy and AMD rows are not true per-repeat rows unless their source indicates otherwise.',
        '- `key_coverage_current_vs_legacy_vs_amd.csv` shows whether each key exists in the current Intel data, legacy Intel data, AMD data, or some combination.',
        '- `system_counts.csv` is a quick sanity check to confirm the Intel and AMD row totals remain distinct.',
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
        '## AMD run label distribution',
        '',
        '| run_label | rows |',
        '| --- | ---: |',
    ]
    for key, value in amd_run_labels.most_common():
        lines.append(f'| {key} | {value} |')
    lines += [
        '',
        '## Files',
        '',
        '- `all_point_summary_with_sources_and_system.csv`',
        '- `all_detail_rows_with_legacy_and_amd.csv`',
        '- `key_coverage_current_vs_legacy_vs_amd.csv`',
        '- `source_counts.csv`',
        '- `system_counts.csv`',
        '- `README.md`',
    ]
    (outdir / 'README.md').write_text('\n'.join(lines) + '\n')

    print(f'Output directory: {outdir}')
    print(f'current aggregate rows: {len(current_agg)}')
    print(f'current repeat rows: {len(current_repeat)}')
    print(f'legacy final rows: {len(legacy_rows)}')
    print(f'amd point rows: {len(amd_rows)}')
    print(f'all point rows: {len(all_point_rows)}')
    print(f'all detail rows: {len(all_detail_rows)}')
    print(f'key presence: {dict(presence_counts)}')
    print(f'system counts: {dict(system_counts)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())