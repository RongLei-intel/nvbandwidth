#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

from backfill_small_buffer_from_logs import compute_backfill


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Apply dedicated rerun outputs to merged small-buffer rows.')
    parser.add_argument('--merged-dir', type=Path, required=True)
    parser.add_argument('--repo-root', type=Path, default=Path.cwd())
    return parser.parse_args()


def read_csv(path: Path):
    with path.open(newline='', errors='replace') as f:
        reader = csv.DictReader(f)
        return list(reader), list(reader.fieldnames or [])


def write_csv(path: Path, rows, fields):
    with path.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def set_scalar_stats(row: dict[str, str], base: str, value: str) -> None:
    sval = str(value)
    if base in row:
        row[base] = sval
    for suffix in ('mean', 'median', 'min', 'max'):
        key = f'{base}_{suffix}'
        if key in row:
            row[key] = sval
    nkey = f'{base}_n'
    if nkey in row:
        row[nkey] = '1'
    for suffix in ('stdev', 'cv'):
        key = f'{base}_{suffix}'
        if key in row:
            row[key] = ''


def parse_run_info(run_dir: Path) -> dict[str, str]:
    info = {}
    for line in (run_dir / 'run.info').read_text(errors='replace').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            info[k.strip()] = v.strip()
    return info


def parse_summary(run_dir: Path) -> dict[str, str]:
    text = (run_dir / 'summary.txt').read_text(errors='replace')
    m = re.search(r'\|\s*host_device_bandwidth_sm\s*\|\s*([0-9.]+)\s*\|', text)
    if not m:
        m = re.search(r'\|\s*[^|]+\s*\|\s*([0-9.]+)\s*\|', text)
    nvsum = m.group(1) if m else ''
    dm = re.search(r'## NVIDIA dmon GPU telemetry.*?- Rows: `([0-9]+)`', text, re.S)
    dmon_rows = dm.group(1) if dm else ''
    return {'nvsum': nvsum, 'dmon_rows': dmon_rows}


def main() -> int:
    args = parse_args()
    merged = args.merged_dir
    repo = args.repo_root

    replacements = {
        ('33', 'ptr_chase_load_bytes', '32', '0.03125'): repo / 'intel_small_kib_rerun_fix_20260702_t33_ptr32_32KiB_v2',
        ('33', 'ptr_chase_load_bytes', '32', '0.0625'): repo / 'intel_small_kib_rerun_fix_20260702_t33_ptr32_64KiB_v3',
    }

    point_path = merged / 'all_point_summary_with_sources_and_system.csv'
    detail_path = merged / 'all_detail_rows_with_legacy_and_amd.csv'
    small_path = merged / 'small_buffer_rows.csv'

    point_rows, point_fields = read_csv(point_path)
    detail_rows, detail_fields = read_csv(detail_path)
    small_rows, small_fields = read_csv(small_path)

    def key_from_row(row: dict[str, str]) -> tuple[str, str, str, str]:
        return (
            row.get('testcase', ''),
            row.get('tuning_param_name', ''),
            row.get('tuning_param_value_bytes', ''),
            row.get('buffer_MiB', ''),
        )

    updated_point = 0
    for rows in (point_rows, small_rows):
        for row in rows:
            if row.get('data_source') != 'small_buffer_sweep' or row.get('system') != 'intel':
                continue
            key = key_from_row(row)
            if key not in replacements:
                continue
            run_dir = replacements[key]
            info = parse_run_info(run_dir)
            summary = parse_summary(run_dir)
            backfill = compute_backfill(run_dir)
            rel_summary = str((run_dir / 'summary.txt').relative_to(repo))
            row['source_file'] = rel_summary
            if 'summary_csv' in row:
                row['summary_csv'] = rel_summary
            if 'sweep_root' in row:
                row['sweep_root'] = run_dir.name
            row['source_note'] = 'updated from dedicated rerun with sufficient runtime to capture missing PCM read metrics'
            set_scalar_stats(row, 'loop_count', info.get('loop_count', ''))
            set_scalar_stats(row, 'nvbandwidth_SUM_GBps', summary.get('nvsum', ''))
            set_scalar_stats(row, 'run_seconds', info.get('run_seconds', ''))
            if summary.get('dmon_rows'):
                set_scalar_stats(row, 'nvidia_dmon_rows', summary['dmon_rows'])
            for base, value in backfill.items():
                set_scalar_stats(row, base, value)
            updated_point += 1

    updated_detail = 0
    for row in detail_rows:
        if row.get('data_source') != 'small_buffer_sweep_point_rows' or row.get('system') != 'intel':
            continue
        key = key_from_row(row)
        if key not in replacements:
            continue
        run_dir = replacements[key]
        info = parse_run_info(run_dir)
        summary = parse_summary(run_dir)
        backfill = compute_backfill(run_dir)
        rel_summary = str((run_dir / 'summary.txt').relative_to(repo))
        row['source_file'] = rel_summary
        row['summary_csv'] = rel_summary
        row['result_dir'] = str(run_dir.relative_to(repo))
        row['sweep_root'] = run_dir.name
        row['source_note'] = 'updated from dedicated rerun with sufficient runtime to capture missing PCM read metrics'
        row['status'] = 'ok'
        row['statuses'] = 'ok'
        row['nvbandwidth_rc'] = info.get('nvbandwidth_rc', '0')
        set_scalar_stats(row, 'loop_count', info.get('loop_count', ''))
        set_scalar_stats(row, 'nvbandwidth_SUM_GBps', summary.get('nvsum', ''))
        set_scalar_stats(row, 'run_seconds', info.get('run_seconds', ''))
        if summary.get('dmon_rows'):
            set_scalar_stats(row, 'nvidia_dmon_rows', summary['dmon_rows'])
        for base, value in backfill.items():
            set_scalar_stats(row, base, value)
        updated_detail += 1

    write_csv(point_path, point_rows, point_fields)
    write_csv(detail_path, detail_rows, detail_fields)
    write_csv(small_path, small_rows, small_fields)

    remaining = [
        row for row in point_rows
        if row.get('data_source') == 'small_buffer_sweep'
        and (not row.get('system_mem_read_median_GBps', '').strip() or not row.get('system_pcie_read_median_GBps', '').strip())
    ]
    unresolved = merged / 'unresolved_small_buffer_missing_from_logs.csv'
    fields = ['data_source', 'system', 'testcase', 'run_label', 'tuning_param_name', 'tuning_param_value_bytes', 'buffer_MiB', 'source_file', 'reason']
    with unresolved.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in remaining:
            writer.writerow({
                'data_source': row.get('data_source', ''),
                'system': row.get('system', ''),
                'testcase': row.get('testcase', ''),
                'run_label': row.get('run_label', ''),
                'tuning_param_name': row.get('tuning_param_name', ''),
                'tuning_param_value_bytes': row.get('tuning_param_value_bytes', ''),
                'buffer_MiB': row.get('buffer_MiB', ''),
                'source_file': row.get('source_file', ''),
                'reason': 'still missing after rerun',
            })

    print(f'updated point/small rows: {updated_point}')
    print(f'updated detail rows: {updated_detail}')
    print(f'remaining unresolved: {len(remaining)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
