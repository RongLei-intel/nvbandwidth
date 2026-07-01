#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path
from typing import Iterable


SWEEP_DIR_RE = re.compile(
    r"^intel_pcm_nvbw_t(?P<testcase>\d+)_(?P<run_label>.+)_sweep_(?P<stamp>\d{8}_\d{6})$"
)
RUN_LABEL_RE = re.compile(r"^ro_(?P<ro_state>on|off)_(?P<config_tag>.+)$")


META_FIELDS = [
    "run_id",
    "summary_csv",
    "sweep_root",
    "testcase",
    "run_label",
    "ro_state",
    "config_tag",
    "sweep_timestamp",
    "sweep_start_time",
    "cuda_visible_devices",
    "numa_node",
    "cpu_bind",
    "sample_interval",
    "nvidia_query_interval",
    "nvidia_dmon_interval",
    "pcm_tools",
    "tuning_param_name",
    "tuning_param_value_bytes",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge all per-sweep intel_pcm_summary.csv files into one CSV with clear run metadata."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Repository root to scan. Defaults to this script's directory.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output CSV path. Defaults to <root>/combined_intel_pcm_summary.csv.",
    )
    return parser.parse_args()


def parse_key_value_file(path: Path) -> dict[str, str]:
    info: dict[str, str] = {}
    if not path.exists():
        return info
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        info[key.strip()] = value.strip()
    return info


def pick_sweep_info_file(sweep_root: Path, run_label: str) -> Path | None:
    preferred = sweep_root / f"sweep_{run_label}.info"
    if preferred.exists():
        return preferred
    matches = sorted(sweep_root.glob("sweep*.info"))
    return matches[0] if matches else None


def parse_sweep_dir_name(name: str) -> dict[str, str]:
    match = SWEEP_DIR_RE.match(name)
    if not match:
        return {
            "testcase": "",
            "run_label": "",
            "sweep_timestamp": "",
            "ro_state": "",
            "config_tag": "",
        }

    data = match.groupdict()
    run_label_match = RUN_LABEL_RE.match(data["run_label"])
    if run_label_match:
        data.update(run_label_match.groupdict())
    else:
        data["ro_state"] = ""
        data["config_tag"] = ""
    data["sweep_timestamp"] = data.pop("stamp")
    return data


def discover_summary_csvs(root: Path) -> list[Path]:
    return sorted(root.glob("intel_pcm_nvbw_t*_sweep_*/intel_pcm_summary.csv"))


def ordered_union(rows: Iterable[dict[str, str]]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for row in rows:
        for key in row:
            if key not in seen:
                seen.add(key)
                ordered.append(key)
    return ordered


def normalize_row(
    row: dict[str, str],
    summary_csv: Path,
    repo_root: Path,
) -> dict[str, str]:
    sweep_root = summary_csv.parent
    sweep_meta = parse_sweep_dir_name(sweep_root.name)
    info_file = pick_sweep_info_file(sweep_root, sweep_meta.get("run_label", ""))
    info = parse_key_value_file(info_file) if info_file else {}

    tuning_param_name = ""
    tuning_param_value = ""
    if "sm_copy_bytes" in row and row.get("sm_copy_bytes", ""):
        tuning_param_name = "sm_copy_bytes"
        tuning_param_value = row.get("sm_copy_bytes", "")
    elif "ptr_chase_load_bytes" in row and row.get("ptr_chase_load_bytes", ""):
        tuning_param_name = "ptr_chase_load_bytes"
        tuning_param_value = row.get("ptr_chase_load_bytes", "")

    relative_summary_csv = str(summary_csv.relative_to(repo_root))
    relative_sweep_root = str(sweep_root.relative_to(repo_root))

    merged = dict(row)
    merged.update(
        {
            "run_id": relative_sweep_root,
            "summary_csv": relative_summary_csv,
            "sweep_root": relative_sweep_root,
            "testcase": sweep_meta.get("testcase", info.get("testcase", "")),
            "run_label": sweep_meta.get("run_label", ""),
            "ro_state": sweep_meta.get("ro_state", ""),
            "config_tag": sweep_meta.get("config_tag", ""),
            "sweep_timestamp": sweep_meta.get("sweep_timestamp", ""),
            "sweep_start_time": info.get("start_time", ""),
            "cuda_visible_devices": info.get("cuda_visible_devices", ""),
            "numa_node": info.get("numa_node", ""),
            "cpu_bind": info.get("cpu_bind", ""),
            "sample_interval": info.get("sample_interval", ""),
            "nvidia_query_interval": info.get("nvidia_query_interval", ""),
            "nvidia_dmon_interval": info.get("nvidia_dmon_interval", ""),
            "pcm_tools": info.get("pcm_tools", ""),
            "tuning_param_name": tuning_param_name,
            "tuning_param_value_bytes": tuning_param_value,
        }
    )

    result_dir = merged.get("result_dir", "")
    if result_dir:
        result_path = repo_root / result_dir
        if result_path.exists():
            merged["result_dir"] = str(result_path.relative_to(repo_root))

    return merged


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    output = args.output.resolve() if args.output else root / "combined_intel_pcm_summary.csv"

    summary_csvs = discover_summary_csvs(root)
    if not summary_csvs:
        raise SystemExit(f"No intel_pcm_summary.csv files found under {root}")

    merged_rows: list[dict[str, str]] = []
    source_fields: list[str] = []
    source_seen: set[str] = set()

    for summary_csv in summary_csvs:
        with summary_csv.open(newline="", errors="replace") as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames:
                for field in reader.fieldnames:
                    if field not in source_seen:
                        source_seen.add(field)
                        source_fields.append(field)
            for row in reader:
                merged_rows.append(normalize_row(row, summary_csv, root))

    fieldnames = META_FIELDS + [field for field in source_fields if field not in META_FIELDS]
    for field in ordered_union(merged_rows):
        if field not in fieldnames:
            fieldnames.append(field)

    merged_rows.sort(
        key=lambda row: (
            int(row.get("testcase") or 0),
            row.get("ro_state", ""),
            row.get("config_tag", ""),
            row.get("tuning_param_name", ""),
            int(row.get("tuning_param_value_bytes") or 0),
            int(row.get("buffer_MiB") or 0),
            row.get("run_id", ""),
        )
    )

    with output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(merged_rows)

    print(f"Merged {len(summary_csvs)} summary files into {output}")
    print(f"Row count: {len(merged_rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
