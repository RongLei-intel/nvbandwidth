#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from datetime import datetime
from pathlib import Path


CORE_COLUMNS = [
    'data_source',
    'system',
    'testcase',
    'run_label',
    'ro_state',
    'config_tag',
    'tuning_param_name',
    'tuning_param_value_bytes',
    'buffer_MiB',
    'repeat_count',
    'statuses',
    'source_kind',
    'source_file',
    'source_note',
    'loop_count',
    'nvbandwidth_gbps',
    'memory_read_gbps',
    'memory_gbps',
    'pcie_read_gbps',
    'pcie_gbps',
    'gpu_pcie_gbps',
    'target_socket_mem_read_gbps',
    'pcm_memory_samples',
    'pcm_pcie_samples',
    'nvidia_dmon_rows',
    'run_seconds',
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Create a compact merged summary with only the core bandwidth metrics.')
    parser.add_argument('--input', type=Path, default=Path('all_results_with_legacy_final_and_amd_20260701_061047/all_point_summary_with_sources_and_system.csv'))
    parser.add_argument('--output', type=Path, default=None)
    return parser.parse_args()


def read_csv(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    with path.open(newline='', errors='replace') as f:
        reader = csv.DictReader(f)
        return list(reader), reader.fieldnames or []


def pick(row: dict[str, str], *names: str) -> str:
    for name in names:
        val = row.get(name, '')
        if str(val).strip() != '':
            return val
    return ''


def convert_row(row: dict[str, str]) -> dict[str, str]:
    is_amd = pick(row, 'system') == 'amd'
    testcase = pick(row, 'testcase')
    tuning_name = pick(row, 'tuning_param_name')
    tuning_value = pick(row, 'tuning_param_value_bytes')
    if is_amd:
        if testcase == '33':
            tuning_name = tuning_name or ('ptr_chase_load_bytes' if pick(row, 'ptr_chase_load_bytes') else tuning_name)
            tuning_value = tuning_value or pick(row, 'ptr_chase_load_bytes')
        else:
            tuning_name = tuning_name or ('sm_copy_bytes' if pick(row, 'sm_copy_bytes') else tuning_name)
            tuning_value = tuning_value or pick(row, 'sm_copy_bytes')
    return {
        'data_source': pick(row, 'data_source'),
        'system': pick(row, 'system'),
        'testcase': pick(row, 'testcase'),
        'run_label': pick(row, 'run_label'),
        'ro_state': pick(row, 'ro_state'),
        'config_tag': pick(row, 'config_tag'),
        'tuning_param_name': tuning_name,
        'tuning_param_value_bytes': tuning_value,
        'buffer_MiB': pick(row, 'buffer_MiB'),
        'repeat_count': pick(row, 'repeat_count'),
        'statuses': pick(row, 'statuses', 'status'),
        'source_kind': pick(row, 'source_kind'),
        'source_file': pick(row, 'source_file'),
        'source_note': pick(row, 'source_note'),
        'loop_count': pick(row, 'loop_count_mean', 'loop_count'),
        'nvbandwidth_gbps': pick(row, 'nvbandwidth_SUM_GBps_mean', 'nvbandwidth_SUM_GBps'),
        'memory_read_gbps': pick(row, 'system_mem_read_median_GBps_mean', 'system_mem_read_median_GBps'),
        'memory_gbps': pick(row, 'system_mem_total_median_GBps_mean', 'system_mem_total_median_GBps'),
        'pcie_read_gbps': pick(row, 'system_pcie_read_median_GBps_mean', 'system_pcie_read_median_GBps'),
        'pcie_gbps': pick(row, 'system_pcie_total_median_GBps_mean', 'system_pcie_total_median_GBps'),
        'gpu_pcie_gbps': pick(row, 'nvidia_pcie_total_median_GBps_mean', 'nvidia_pcie_total_median_GBps'),
        'target_socket_mem_read_gbps': pick(row, 'target_socket_mem_read_median_GBps_mean', 'target_socket_mem_read_median_GBps'),
        'pcm_memory_samples': pick(row, 'pcm_memory_samples_mean', 'pcm_memory_samples'),
        'pcm_pcie_samples': pick(row, 'pcm_pcie_samples_mean', 'pcm_pcie_samples'),
        'nvidia_dmon_rows': pick(row, 'nvidia_dmon_rows_mean', 'nvidia_dmon_rows'),
        'run_seconds': pick(row, 'run_seconds_mean', 'run_seconds'),
    }


def main() -> int:
    args = parse_args()
    input_path = args.input
    output_path = args.output or input_path.with_name('all_point_summary_compact.csv')

    rows, _ = read_csv(input_path)
    compact_rows = [convert_row(r) for r in rows]

    with output_path.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=CORE_COLUMNS, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(compact_rows)

    readme_path = output_path.with_name('README_compact.md')
    readme = [
        '# Compact merged summary',
        '',
        f'- Generated at: `{datetime.now().isoformat(timespec="seconds")}`',
        f'- Input: `{input_path}`',
        f'- Output: `{output_path}`',
        '',
        '## Kept columns',
        '',
        '- identifiers: `system`, `testcase`, `run_label`, `ro_state`, `config_tag`, `tuning_param_name`, `tuning_param_value_bytes`, `buffer_MiB`',
        '- provenance: `data_source`, `source_kind`, `source_file`, `source_note`',
        '- case/self-run values: `loop_count`, `repeat_count`, `statuses`, `run_seconds`',
        '- core bandwidths: `memory_read_gbps`, `memory_gbps`, `pcie_read_gbps`, `pcie_gbps`, `gpu_pcie_gbps`',
        '- supporting counters: `pcm_memory_samples`, `pcm_pcie_samples`, `nvidia_dmon_rows`',
        '',
        '## Metric mapping',
        '',
        '- `memory_gbps` uses `system_mem_total_median_GBps`',
        '- `pcie_gbps` uses `system_pcie_total_median_GBps`',
        '- `memory_read_gbps` uses `system_mem_read_median_GBps`',
        '- `pcie_read_gbps` uses `system_pcie_read_median_GBps`',
        '- `gpu_pcie_gbps` uses `nvidia_pcie_total_median_GBps`',
    ]
    readme_path.write_text('\n'.join(readme) + '\n')

    print(f'Input rows: {len(rows)}')
    print(f'Output: {output_path}')
    print(f'Readme: {readme_path}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())