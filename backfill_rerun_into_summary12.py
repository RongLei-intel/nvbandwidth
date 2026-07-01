#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

KEY_FIELDS = [
    "testcase",
    "run_label",
    "ro_state",
    "config_tag",
    "tuning_param_name",
    "tuning_param_value_bytes",
    "buffer_MiB",
]

NUMERIC_FIELDS = [
    "loop_count",
    "nvbandwidth_SUM_GBps",
    "system_mem_read_median_GBps",
    "system_mem_read_p95_GBps",
    "system_mem_read_max_GBps",
    "system_mem_write_median_GBps",
    "system_mem_total_median_GBps",
    "target_socket_mem_read_median_GBps",
    "system_pcie_read_median_GBps",
    "system_pcie_read_p95_GBps",
    "system_pcie_read_max_GBps",
    "system_pcie_write_median_GBps",
    "system_pcie_total_median_GBps",
    "system_pcie_total_p95_GBps",
    "nvidia_rxpcie_median_GBps",
    "nvidia_rxpcie_p95_GBps",
    "nvidia_txpcie_median_GBps",
    "nvidia_txpcie_p95_GBps",
    "nvidia_pcie_total_median_GBps",
    "nvidia_pcie_total_p95_GBps",
    "pcm_memory_samples",
    "pcm_pcie_samples",
    "nvidia_dmon_rows",
]

CORE_METRICS = [
    "nvbandwidth_SUM_GBps",
    "system_mem_read_p95_GBps",
    "system_pcie_read_p95_GBps",
]

RERUN_DIR_RE = re.compile(
    r"^intel_pcm_nvbw_t(?P<testcase>\d+)_(?P<run_label>.+)_rerun\d*_(?P<tuning_name>sm_copy_bytes|ptr_chase_load_bytes)_(?P<tuning_value>\d+)_(?P<stamp>\d{8}_\d{6})$"
)


@dataclass(frozen=True)
class PointKey:
    testcase: str
    run_label: str
    ro_state: str
    config_tag: str
    tuning_param_name: str
    tuning_param_value_bytes: str
    buffer_MiB: str

    @staticmethod
    def from_row(row: dict[str, str]) -> "PointKey":
        return PointKey(*(row.get(field, "") for field in KEY_FIELDS))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Backfill rerun measurements into summary12 mean table.")
    parser.add_argument("--base", type=Path, default=Path("summary12_analysis/combined_intel_pcm_summary12_mean.csv"))
    parser.add_argument("--rerun-root", type=Path, default=None)
    parser.add_argument("--rerun-points", type=Path, default=Path("summary12_analysis/points_to_rerun_union.csv"))
    parser.add_argument("--output", type=Path, default=Path("summary12_analysis/combined_intel_pcm_summary12_with_rerun.csv"))
    parser.add_argument("--applied-output", type=Path, default=Path("summary12_analysis/rerun_backfill_applied_points.csv"))
    parser.add_argument("--manifest", type=Path, default=Path("summary12_analysis/rerun_backfill_manifest.txt"))
    return parser.parse_args()


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    text = str(value).strip().replace(",", "")
    if not text:
        return None
    try:
        v = float(text)
    except ValueError:
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def fmt_float(value: float | None, digits: int = 6) -> str:
    return "" if value is None else f"{value:.{digits}f}"


def read_csv(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    with path.open(newline="", errors="replace") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        return rows, (reader.fieldnames or [])


def write_csv(path: Path, rows: list[dict[str, str]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def safe_int_text(v: str) -> int:
    try:
        return int(float(v))
    except Exception:
        return 0


def derive_ro_and_config(run_label: str) -> tuple[str, str]:
    m = re.match(r"^ro_(on|off)_(.+)$", run_label)
    if m:
        return m.group(1), m.group(2)
    m2 = re.match(r"^ro_(on|off)$", run_label)
    if m2:
        return m2.group(1), "na"
    return "", ""


def latest_rerun_batch(root: Path) -> Path:
    batches = sorted([p for p in root.iterdir() if p.is_dir()])
    if not batches:
        raise SystemExit(f"No rerun batches found under {root}")
    return batches[-1]


def parse_rerun_context_from_path(summary_csv: Path) -> dict[str, str] | None:
    m = RERUN_DIR_RE.match(summary_csv.parent.name)
    if not m:
        return None
    d = m.groupdict()
    ro_state, config_tag = derive_ro_and_config(d["run_label"])
    return {
        "testcase": d["testcase"],
        "run_label": d["run_label"],
        "ro_state": ro_state,
        "config_tag": config_tag,
        "tuning_param_name": d["tuning_name"],
        "tuning_param_value_bytes": d["tuning_value"],
    }


def load_target_keys(path: Path) -> set[PointKey]:
    if not path.exists():
        return set()
    rows, _ = read_csv(path)
    return {PointKey.from_row(r) for r in rows}


def aggregate_rerun_points(rerun_batch: Path) -> tuple[dict[PointKey, dict[str, str]], dict[PointKey, set[str]]]:
    summary_files = sorted(rerun_batch.glob("**/intel_pcm_summary.csv"))
    grouped_rows: dict[PointKey, list[dict[str, str]]] = defaultdict(list)
    grouped_sources: dict[PointKey, set[str]] = defaultdict(set)

    for path in summary_files:
        ctx = parse_rerun_context_from_path(path)
        if ctx is None:
            continue
        rows, _ = read_csv(path)
        for row in rows:
            if row.get("status", "").strip().lower() not in {"", "ok"}:
                continue
            b = row.get("buffer_MiB", "")
            if not b:
                continue
            key = PointKey(
                testcase=ctx["testcase"],
                run_label=ctx["run_label"],
                ro_state=ctx["ro_state"],
                config_tag=ctx["config_tag"],
                tuning_param_name=ctx["tuning_param_name"],
                tuning_param_value_bytes=ctx["tuning_param_value_bytes"],
                buffer_MiB=str(b),
            )
            grouped_rows[key].append(dict(row))
            grouped_sources[key].add(str(path.parent))

    aggregated: dict[PointKey, dict[str, str]] = {}
    for key, items in grouped_rows.items():
        rec: dict[str, str] = {k: getattr(key, k) for k in KEY_FIELDS}
        for field in NUMERIC_FIELDS:
            vals = [parse_float(it.get(field, "")) for it in items]
            vals = [v for v in vals if v is not None]
            rec[field] = fmt_float(sum(vals) / len(vals), 6) if vals else ""
        aggregated[key] = rec

    return aggregated, grouped_sources


def main() -> int:
    args = parse_args()
    now_text = datetime.now().isoformat(timespec="seconds")

    base_path = args.base.resolve()
    base_rows, base_fields = read_csv(base_path)

    rerun_root = args.rerun_root.resolve() if args.rerun_root else latest_rerun_batch(Path("rerun_results").resolve())
    rerun_agg, rerun_sources = aggregate_rerun_points(rerun_root)

    target_keys = load_target_keys(args.rerun_points.resolve()) if args.rerun_points.exists() else set()
    restrict_to_targets = len(target_keys) > 0

    base_map: dict[PointKey, dict[str, str]] = {PointKey.from_row(r): dict(r) for r in base_rows}
    out_rows: list[dict[str, str]] = []
    applied_rows: list[dict[str, str]] = []

    updated_count = 0
    for key, row in base_map.items():
        if key in rerun_agg and ((not restrict_to_targets) or (key in target_keys)):
            rer = rerun_agg[key]
            old = {m: row.get(m, "") for m in CORE_METRICS}
            for field in NUMERIC_FIELDS:
                if field in row and rer.get(field, "") != "":
                    row[field] = rer[field]

            row["rerun_updated"] = "1"
            row["rerun_batch"] = str(rerun_root)
            srcs = sorted(rerun_sources.get(key, set()))
            row["rerun_source_count"] = str(len(srcs))
            row["rerun_source_dirs"] = " | ".join(srcs)
            row["final_updated_at"] = now_text
            updated_count += 1

            applied_rows.append(
                {
                    **{k: getattr(key, k) for k in KEY_FIELDS},
                    "rerun_batch": str(rerun_root),
                    "old_nvbandwidth_SUM_GBps": old["nvbandwidth_SUM_GBps"],
                    "new_nvbandwidth_SUM_GBps": row.get("nvbandwidth_SUM_GBps", ""),
                    "old_system_mem_read_p95_GBps": old["system_mem_read_p95_GBps"],
                    "new_system_mem_read_p95_GBps": row.get("system_mem_read_p95_GBps", ""),
                    "old_system_pcie_read_p95_GBps": old["system_pcie_read_p95_GBps"],
                    "new_system_pcie_read_p95_GBps": row.get("system_pcie_read_p95_GBps", ""),
                    "final_updated_at": now_text,
                }
            )
        else:
            row.setdefault("rerun_updated", "0")
            row.setdefault("rerun_batch", "")
            row.setdefault("rerun_source_count", "0")
            row.setdefault("rerun_source_dirs", "")
            row.setdefault("final_updated_at", now_text)

        out_rows.append(row)

    appended_count = 0
    for key, rer in rerun_agg.items():
        if key in base_map:
            continue
        if restrict_to_targets and key not in target_keys:
            continue

        ro_state, config_tag = derive_ro_and_config(key.run_label)
        new_row = {field: "" for field in base_fields}
        new_row.update(
            {
                "analysis_generated_at": now_text,
                "testcase": key.testcase,
                "run_label": key.run_label,
                "ro_state": ro_state,
                "config_tag": config_tag,
                "tuning_param_name": key.tuning_param_name,
                "tuning_param_value_bytes": key.tuning_param_value_bytes,
                "buffer_MiB": key.buffer_MiB,
                "present_in_summary1": "0",
                "present_in_summary2": "0",
                "rerun_updated": "1",
                "rerun_batch": str(rerun_root),
                "rerun_source_count": str(len(rerun_sources.get(key, set()))),
                "rerun_source_dirs": " | ".join(sorted(rerun_sources.get(key, set()))),
                "final_updated_at": now_text,
            }
        )
        for field in NUMERIC_FIELDS:
            if field in new_row:
                new_row[field] = rer.get(field, "")
        out_rows.append(new_row)
        appended_count += 1

    out_rows.sort(
        key=lambda r: (
            safe_int_text(r.get("testcase", "0")),
            r.get("run_label", ""),
            r.get("tuning_param_name", ""),
            safe_int_text(r.get("tuning_param_value_bytes", "0")),
            safe_int_text(r.get("buffer_MiB", "0")),
        )
    )

    output_fields = list(base_fields)
    for extra in ["rerun_updated", "rerun_batch", "rerun_source_count", "rerun_source_dirs", "final_updated_at"]:
        if extra not in output_fields:
            output_fields.append(extra)

    write_csv(args.output.resolve(), out_rows, output_fields)

    applied_fields = KEY_FIELDS + [
        "rerun_batch",
        "old_nvbandwidth_SUM_GBps",
        "new_nvbandwidth_SUM_GBps",
        "old_system_mem_read_p95_GBps",
        "new_system_mem_read_p95_GBps",
        "old_system_pcie_read_p95_GBps",
        "new_system_pcie_read_p95_GBps",
        "final_updated_at",
    ]
    write_csv(args.applied_output.resolve(), applied_rows, applied_fields)

    args.manifest.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.manifest.resolve().write_text(
        "\n".join(
            [
                f"generated_at={now_text}",
                f"base={base_path}",
                f"rerun_root={rerun_root}",
                f"rerun_points={args.rerun_points.resolve() if args.rerun_points.exists() else ''}",
                f"restrict_to_rerun_points={1 if restrict_to_targets else 0}",
                f"base_row_count={len(base_rows)}",
                f"rerun_agg_points={len(rerun_agg)}",
                f"updated_points={updated_count}",
                f"appended_points={appended_count}",
                f"output={args.output.resolve()}",
                f"applied_output={args.applied_output.resolve()}",
            ]
        )
        + "\n"
    )

    print(f"Backfill done. updated_points={updated_count}, appended_points={appended_count}")
    print(f"Output: {args.output.resolve()}")
    print(f"Applied details: {args.applied_output.resolve()}")
    print(f"Manifest: {args.manifest.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
