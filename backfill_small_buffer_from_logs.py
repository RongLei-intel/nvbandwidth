#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path

POINT_STATS_BASES = [
    'system_mem_read_median_GBps',
    'system_mem_read_p95_GBps',
    'system_mem_read_max_GBps',
    'system_mem_write_median_GBps',
    'system_mem_total_median_GBps',
    'target_socket_mem_read_median_GBps',
    'system_pcie_read_median_GBps',
    'system_pcie_read_p95_GBps',
    'system_pcie_read_max_GBps',
    'system_pcie_write_median_GBps',
    'system_pcie_total_median_GBps',
    'system_pcie_total_p95_GBps',
    'pcm_memory_samples',
    'pcm_pcie_samples',
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Backfill missing small-buffer PCM metrics from raw logs into a merged results directory.')
    parser.add_argument('--merged-dir', type=Path, required=True)
    parser.add_argument('--repo-root', type=Path, default=Path.cwd())
    return parser.parse_args()


def read_csv(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    with path.open(newline='', errors='replace') as f:
        reader = csv.DictReader(f)
        return list(reader), list(reader.fieldnames or [])


def write_csv(path: Path, rows: list[dict[str, str]], fieldnames: list[str]) -> None:
    with path.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def parse_float(value: str | None) -> float | None:
    try:
        s = str(value or '').strip()
        return float(s) if s else None
    except Exception:
        return None


def fmt(value: float | int | None, digits: int = 6) -> str:
    if value is None:
        return ''
    if isinstance(value, int):
        return str(value)
    return f'{value:.{digits}f}'


def percentile95(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, min(len(ordered) - 1, math.ceil(0.95 * len(ordered)) - 1))
    return ordered[idx]


def median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def load_pcm_memory(path: Path) -> dict[str, list[float]]:
    rows = list(csv.reader(path.open(newline='')))
    if len(rows) < 3:
        return {}
    groups = [c.strip() for c in rows[0]]
    names = [c.strip() for c in rows[1]]
    metrics: dict[str, list[float]] = defaultdict(list)
    for row in rows[2:]:
        if len(row) < 3 or not row[0].strip():
            continue
        for i, raw in enumerate(row):
            if i >= len(names):
                continue
            group = groups[i] if i < len(groups) else ''
            name = names[i]
            if not name or name in {'Date', 'Time'}:
                continue
            value = parse_float(raw)
            if value is None:
                continue
            key = f'{group}.{name}' if group else name
            metrics[key].append(value)
    return metrics


def load_pcm_pcie(path: Path) -> dict[str, list[float]]:
    samples: list[list[dict[str, str]]] = []
    current: list[dict[str, str]] = []
    header: list[str] | None = None
    for row in csv.reader(path.open(newline='')):
        if not row:
            continue
        first = row[0].strip()
        if first == 'Skt':
            if current:
                samples.append(current)
                current = []
            header = [c.strip() for c in row]
            continue
        if header and first not in {'', '*'}:
            current.append(dict(zip(header, row)))
    if current:
        samples.append(current)

    totals: dict[str, list[float]] = defaultdict(list)
    per_socket: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for sample in samples:
        sample_totals: dict[str, float] = defaultdict(float)
        for row in sample:
            socket = str(row.get('Skt', '')).strip()
            for key in ['PCIe Rd (B)', 'PCIe Wr (B)']:
                value = parse_float(row.get(key))
                if value is None:
                    continue
                sample_totals[key] += value
                per_socket[socket][key].append(value)
        if sample_totals:
            totals['PCIe Rd (B)'].append(sample_totals.get('PCIe Rd (B)', 0.0))
            totals['PCIe Wr (B)'].append(sample_totals.get('PCIe Wr (B)', 0.0))
            totals['PCIe Total (B)'].append(sample_totals.get('PCIe Rd (B)', 0.0) + sample_totals.get('PCIe Wr (B)', 0.0))
    return {'totals': totals, 'per_socket': per_socket}


def compute_backfill(run_dir: Path) -> dict[str, str]:
    result: dict[str, str] = {}

    mem_path = run_dir / 'pcm-memory.csv'
    if mem_path.exists() and mem_path.stat().st_size > 0:
        mem = load_pcm_memory(mem_path)
        system_read = [v / 1000.0 for v in mem.get('System.Read', [])]
        system_write = [v / 1000.0 for v in mem.get('System.Write', [])]
        system_total = [v / 1000.0 for v in mem.get('System.Memory', [])]
        socket0_read = [v / 1000.0 for v in mem.get('SKT0.Mem Read (MB/s)', [])]
        if system_read:
            result['system_mem_read_median_GBps'] = fmt(median(system_read))
            result['system_mem_read_p95_GBps'] = fmt(percentile95(system_read))
            result['system_mem_read_max_GBps'] = fmt(max(system_read))
            result['pcm_memory_samples'] = str(len(system_read))
        if system_write:
            result['system_mem_write_median_GBps'] = fmt(median(system_write))
        if system_total:
            result['system_mem_total_median_GBps'] = fmt(median(system_total))
        if socket0_read:
            result['target_socket_mem_read_median_GBps'] = fmt(median(socket0_read))

    pcie_path = run_dir / 'pcm-pcie.csv'
    if pcie_path.exists() and pcie_path.stat().st_size > 0:
        parsed = load_pcm_pcie(pcie_path)
        totals = parsed['totals']
        system_read = [v / 1e9 for v in totals.get('PCIe Rd (B)', [])]
        system_write = [v / 1e9 for v in totals.get('PCIe Wr (B)', [])]
        system_total = [v / 1e9 for v in totals.get('PCIe Total (B)', [])]
        if system_read:
            result['system_pcie_read_median_GBps'] = fmt(median(system_read))
            result['system_pcie_read_p95_GBps'] = fmt(percentile95(system_read))
            result['system_pcie_read_max_GBps'] = fmt(max(system_read))
            result['pcm_pcie_samples'] = str(len(system_read))
        if system_write:
            result['system_pcie_write_median_GBps'] = fmt(median(system_write))
        if system_total:
            result['system_pcie_total_median_GBps'] = fmt(median(system_total))
            result['system_pcie_total_p95_GBps'] = fmt(percentile95(system_total))

    return result


def apply_point_stats(row: dict[str, str], backfill: dict[str, str]) -> None:
    for key, value in backfill.items():
        row[key] = value
        n_key = f'{key}_n'
        if n_key in row:
            row[n_key] = '1'
        for suffix in ('mean', 'median', 'min', 'max'):
            stat_key = f'{key}_{suffix}'
            if stat_key in row:
                stat_value = value
                if suffix == 'max' and key == 'system_mem_read_median_GBps':
                    stat_value = backfill.get('system_mem_read_max_GBps', value)
                elif suffix == 'max' and key == 'system_pcie_read_median_GBps':
                    stat_value = backfill.get('system_pcie_read_max_GBps', value)
                elif suffix == 'median' and key == 'system_mem_read_p95_GBps':
                    stat_value = backfill.get('system_mem_read_p95_GBps', value)
                elif suffix == 'median' and key == 'system_pcie_read_p95_GBps':
                    stat_value = backfill.get('system_pcie_read_p95_GBps', value)
                row[stat_key] = stat_value
        for suffix in ('stdev', 'cv'):
            stat_key = f'{key}_{suffix}'
            if stat_key in row:
                row[stat_key] = ''

    for base in ('system_mem_read_median_GBps', 'system_mem_read_p95_GBps', 'system_mem_read_max_GBps', 'system_mem_write_median_GBps', 'system_mem_total_median_GBps', 'target_socket_mem_read_median_GBps', 'system_pcie_read_median_GBps', 'system_pcie_read_p95_GBps', 'system_pcie_read_max_GBps', 'system_pcie_write_median_GBps', 'system_pcie_total_median_GBps', 'system_pcie_total_p95_GBps', 'pcm_memory_samples', 'pcm_pcie_samples'):
        if base not in backfill:
            continue
        row[base] = backfill[base]
        for suffix in ('mean', 'median', 'min', 'max'):
            stat_key = f'{base}_{suffix}'
            if stat_key in row:
                row[stat_key] = backfill[base]
        n_key = f'{base}_n'
        if n_key in row:
            row[n_key] = '1'
        for suffix in ('stdev', 'cv'):
            stat_key = f'{base}_{suffix}'
            if stat_key in row:
                row[stat_key] = ''


def apply_detail_stats(row: dict[str, str], backfill: dict[str, str]) -> None:
    for key, value in backfill.items():
        row[key] = value
        for suffix in ('mean', 'median', 'min', 'max'):
            stat_key = f'{key}_{suffix}'
            if stat_key in row:
                row[stat_key] = value
        n_key = f'{key}_n'
        if n_key in row:
            row[n_key] = '1'
        for suffix in ('stdev', 'cv'):
            stat_key = f'{key}_{suffix}'
            if stat_key in row:
                row[stat_key] = ''


def main() -> int:
    args = parse_args()
    merged_dir = args.merged_dir
    repo_root = args.repo_root

    point_path = merged_dir / 'all_point_summary_with_sources_and_system.csv'
    detail_path = merged_dir / 'all_detail_rows_with_legacy_and_amd.csv'
    small_path = merged_dir / 'small_buffer_rows.csv'

    point_rows, point_fields = read_csv(point_path)
    detail_rows, detail_fields = read_csv(detail_path)
    small_rows, small_fields = read_csv(small_path) if small_path.exists() else ([], [])

    backfill_cache: dict[str, dict[str, str]] = {}
    updated_keys: set[tuple[str, ...]] = set()
    target_sources = {'small_buffer_sweep'}

    def row_key(row: dict[str, str]) -> tuple[str, ...]:
        return (
            row.get('data_source', ''),
            row.get('system', ''),
            row.get('testcase', ''),
            row.get('run_label', ''),
            row.get('tuning_param_name', ''),
            row.get('tuning_param_value_bytes', ''),
            row.get('buffer_MiB', ''),
        )

    point_updates = 0
    for row in point_rows:
        if row.get('data_source') not in target_sources:
            continue
        if row.get('system') != 'intel':
            continue
        if row.get('system_mem_read_median_GBps', '').strip() and row.get('system_pcie_read_median_GBps', '').strip():
            continue
        source_file = row.get('source_file', '').strip()
        if not source_file:
            continue
        run_dir = (repo_root / source_file).parent
        cache_key = str(run_dir)
        if cache_key not in backfill_cache:
            backfill_cache[cache_key] = compute_backfill(run_dir)
        backfill = backfill_cache[cache_key]
        if not backfill:
            continue
        apply_point_stats(row, backfill)
        point_updates += 1
        updated_keys.add(row_key(row))

    detail_updates = 0
    for row in detail_rows:
        if row.get('data_source') != 'small_buffer_sweep_point_rows':
            continue
        key = (
            'small_buffer_sweep',
            row.get('system', ''),
            row.get('testcase', ''),
            row.get('run_label', ''),
            row.get('tuning_param_name', ''),
            row.get('tuning_param_value_bytes', ''),
            row.get('buffer_MiB', ''),
        )
        if key not in updated_keys:
            continue
        source_file = row.get('source_file', '').strip() or row.get('summary_csv', '').strip()
        if not source_file:
            continue
        run_dir = (repo_root / source_file).parent
        backfill = backfill_cache.get(str(run_dir), {})
        if not backfill:
            continue
        apply_detail_stats(row, backfill)
        detail_updates += 1

    small_updates = 0
    for row in small_rows:
        if row.get('data_source') not in target_sources:
            continue
        key = row_key(row)
        if key not in updated_keys:
            continue
        source_file = row.get('source_file', '').strip()
        if not source_file:
            continue
        backfill = backfill_cache.get(str((repo_root / source_file).parent), {})
        if not backfill:
            continue
        apply_point_stats(row, backfill)
        small_updates += 1

    write_csv(point_path, point_rows, point_fields)
    write_csv(detail_path, detail_rows, detail_fields)
    if small_rows:
        write_csv(small_path, small_rows, small_fields)

    print(f'updated point rows: {point_updates}')
    print(f'updated detail rows: {detail_updates}')
    print(f'updated small-buffer rows: {small_updates}')
    print(f'unique run dirs parsed: {len(backfill_cache)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
