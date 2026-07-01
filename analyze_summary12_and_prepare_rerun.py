#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


KEY_FIELDS = [
    "testcase",
    "run_label",
    "ro_state",
    "config_tag",
    "tuning_param_name",
    "tuning_param_value_bytes",
    "buffer_MiB",
]

COMPARE_METRICS = [
    "nvbandwidth_SUM_GBps",
    "system_mem_read_p95_GBps",
    "system_pcie_read_p95_GBps",
]

FLOAT_CANDIDATE_COLUMNS = [
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

META_KEEP_FIELDS = [
    "cuda_visible_devices",
    "numa_node",
    "cpu_bind",
    "sample_interval",
    "nvidia_query_interval",
    "nvidia_dmon_interval",
    "pcm_tools",
    "testcase",
    "run_label",
    "ro_state",
    "config_tag",
    "tuning_param_name",
    "tuning_param_value_bytes",
    "buffer_MiB",
]


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
    parser = argparse.ArgumentParser(
        description=(
            "Merge combined_intel_pcm_summary1/2 by pointwise mean, detect abnormal points, "
            "and generate rerun scripts/manifests."
        )
    )
    parser.add_argument("--input1", type=Path, default=Path("combined_intel_pcm_summary1.csv"))
    parser.add_argument("--input2", type=Path, default=Path("combined_intel_pcm_summary2.csv"))
    parser.add_argument("--output-dir", type=Path, default=Path("summary12_analysis"))
    parser.add_argument(
        "--large-diff-threshold",
        type=float,
        default=0.20,
        help="Relative difference threshold (e.g. 0.20 means >=20%%) used to mark large differences between summary1 and summary2.",
    )
    parser.add_argument(
        "--disturbance-ratio-threshold",
        type=float,
        default=0.70,
        help=(
            "Disturbance threshold for pcie_read_p95 << memory_read_p95. "
            "A point is marked when pcie_read_p95 < memory_read_p95 * this ratio."
        ),
    )
    parser.add_argument(
        "--rerun-script",
        type=Path,
        default=Path("rerun_points_from_summary12.sh"),
        help="Path of generated shell script for rerunning selected points.",
    )
    return parser.parse_args()


def read_csv(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    with path.open(newline="", errors="replace") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fields = reader.fieldnames or []
    return rows, fields


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    text = str(value).strip().replace(",", "")
    if text == "":
        return None
    try:
        v = float(text)
    except ValueError:
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def fmt_float(value: float | None, digits: int = 6) -> str:
    if value is None:
        return ""
    return f"{value:.{digits}f}"


def group_rows_by_key(rows: Iterable[dict[str, str]]) -> dict[PointKey, list[dict[str, str]]]:
    grouped: dict[PointKey, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[PointKey.from_row(row)].append(row)
    return grouped


def choose_first_nonempty(rows: list[dict[str, str]], field: str) -> str:
    for row in rows:
        val = row.get(field, "")
        if str(val).strip() != "":
            return val
    return ""


def mean_of_field(rows: list[dict[str, str]], field: str) -> float | None:
    vals = [parse_float(r.get(field, "")) for r in rows]
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    return sum(vals) / len(vals)


def aggregate_source_by_key(
    rows: list[dict[str, str]],
    fields: list[str],
    source_name: str,
) -> dict[PointKey, dict[str, str]]:
    grouped = group_rows_by_key(rows)
    out: dict[PointKey, dict[str, str]] = {}

    numeric_fields = [f for f in FLOAT_CANDIDATE_COLUMNS if f in fields]

    for key, group in grouped.items():
        rec: dict[str, str] = {}
        for kf, value in zip(KEY_FIELDS, key.__dict__.values()):
            rec[kf] = value

        for mf in META_KEEP_FIELDS:
            if mf in fields:
                rec[mf] = choose_first_nonempty(group, mf)

        rec["status"] = choose_first_nonempty(group, "status")
        rec["source"] = source_name
        rec["source_row_count"] = str(len(group))

        for nf in numeric_fields:
            rec[nf] = fmt_float(mean_of_field(group, nf), 6)

        out[key] = rec
    return out


def rel_diff(a: float | None, b: float | None) -> float | None:
    if a is None or b is None:
        return None
    denom = max(abs(a), abs(b), 1e-12)
    return abs(a - b) / denom


def write_csv(path: Path, rows: list[dict[str, str]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def safe_int_text(v: str) -> int:
    try:
        return int(float(v))
    except Exception:
        return 0


def build_rerun_script(rerun_points: list[dict[str, str]], script_path: Path) -> None:
    # Group points to reduce command count.
    grouped_buffers: dict[tuple[str, str, str], set[str]] = defaultdict(set)
    grouped_meta: dict[tuple[str, str, str], dict[str, str]] = {}

    for row in rerun_points:
        testcase = row.get("testcase", "")
        run_label = row.get("run_label", "")
        tname = row.get("tuning_param_name", "")
        tval = row.get("tuning_param_value_bytes", "")
        b = row.get("buffer_MiB", "")
        gkey = (testcase, run_label, f"{tname}:{tval}")
        if b:
            grouped_buffers[gkey].add(b)
        grouped_meta[gkey] = row

    lines: list[str] = []
    lines.append("#!/usr/bin/env bash")
    lines.append("set -euo pipefail")
    lines.append("")
    lines.append("# Auto-generated rerun script from combined_intel_pcm_summary1/2 analysis")
    lines.append("# It reruns only selected abnormal points and saves outputs under rerun_results/<timestamp>/")
    lines.append("SCRIPT_DIR=\"$(cd -- \"$(dirname -- \"${BASH_SOURCE[0]}\")\" && pwd)\"")
    lines.append("cd \"$SCRIPT_DIR\"")
    lines.append("TS=\"$(date +%Y%m%d_%H%M%S)\"")
    lines.append("OUTBASE=\"rerun_results/$TS\"")
    lines.append("mkdir -p \"$OUTBASE\"")
    lines.append("echo \"Rerun outputs will be saved under: $OUTBASE\"")
    lines.append("")

    for (testcase, run_label, tpair), buffers in sorted(
        grouped_buffers.items(),
        key=lambda x: (safe_int_text(x[0][0]), x[0][1], x[0][2]),
    ):
        tname, tval = tpair.split(":", 1)
        meta = grouped_meta[(testcase, run_label, tpair)]
        cuda = meta.get("cuda_visible_devices", "")
        numa = meta.get("numa_node", "")
        cpu_bind = meta.get("cpu_bind", "")
        sample_interval = meta.get("sample_interval", "")
        query_interval = meta.get("nvidia_query_interval", "")
        dmon_interval = meta.get("nvidia_dmon_interval", "")
        pcm_tools = meta.get("pcm_tools", "")

        ordered_buffers = sorted(buffers, key=safe_int_text)
        buffer_text = " ".join(ordered_buffers)

        lines.append(f"echo \"=== testcase={testcase} run_label={run_label} {tname}={tval} buffers=[{buffer_text}] ===\"")
        lines.append("(")
        lines.append(f"  export RUN_LABEL=\"{run_label}_rerun\"")
        lines.append(f"  export BUFFER_SIZES=\"{buffer_text}\"")
        lines.append("  export RETRIES=2")
        if cuda:
            lines.append(f"  export CUDA_VISIBLE_DEVICES=\"{cuda}\"")
        if numa:
            lines.append(f"  export NUMA_NODE=\"{numa}\"")
        if cpu_bind:
            lines.append(f"  export CPU_BIND=\"{cpu_bind}\"")
        if sample_interval:
            lines.append(f"  export SAMPLE_INTERVAL=\"{sample_interval}\"")
        if query_interval:
            lines.append(f"  export NVIDIA_QUERY_INTERVAL=\"{query_interval}\"")
        if dmon_interval:
            lines.append(f"  export NVIDIA_DMON_INTERVAL=\"{dmon_interval}\"")
        if pcm_tools:
            lines.append(f"  export PCM_TOOLS=\"{pcm_tools}\"")

        if testcase == "16":
            lines.append("  export TESTCASE=16")
            lines.append(f"  export SM_COPY_BYTES_LIST=\"{tval}\"")
            lines.append(
                f"  export OUTROOT=\"$OUTBASE/intel_pcm_nvbw_t16_{run_label}_rerun_{tname}_{tval}_$(date +%Y%m%d_%H%M%S)\""
            )
            lines.append("  bash ./sweep_intel_pcm_t16.sh")
        elif testcase == "33":
            lines.append("  export TESTCASE=33")
            lines.append(f"  export PTR_CHASE_LOAD_BYTES_LIST=\"{tval}\"")
            lines.append(
                f"  export OUTROOT=\"$OUTBASE/intel_pcm_nvbw_t33_{run_label}_rerun_{tname}_{tval}_$(date +%Y%m%d_%H%M%S)\""
            )
            lines.append("  bash ./sweep_intel_pcm_t33.sh")
        else:
            lines.append(f"  echo \"[WARN] Unsupported testcase={testcase}; skipped\"")

        lines.append(")")
        lines.append("")

    lines.append("echo \"All rerun commands finished. Outputs in: $OUTBASE\"")

    script_path.write_text("\n".join(lines) + "\n")
    script_path.chmod(0o755)


def main() -> int:
    args = parse_args()
    input1 = args.input1.resolve()
    input2 = args.input2.resolve()

    rows1, fields1 = read_csv(input1)
    rows2, fields2 = read_csv(input2)

    outdir = args.output_dir.resolve()
    outdir.mkdir(parents=True, exist_ok=True)

    agg1 = aggregate_source_by_key(rows1, fields1, "summary1")
    agg2 = aggregate_source_by_key(rows2, fields2, "summary2")

    all_keys = sorted(
        set(agg1.keys()) | set(agg2.keys()),
        key=lambda k: (
            safe_int_text(k.testcase),
            k.run_label,
            k.tuning_param_name,
            safe_int_text(k.tuning_param_value_bytes),
            safe_int_text(k.buffer_MiB),
        ),
    )

    numeric_union_fields = sorted(set(FLOAT_CANDIDATE_COLUMNS) & (set(fields1) | set(fields2)))

    merged_rows: list[dict[str, str]] = []
    diff_rows: list[dict[str, str]] = []
    disturbance_rows: list[dict[str, str]] = []

    for key in all_keys:
        a = agg1.get(key)
        b = agg2.get(key)

        base = dict((a or b or {}))
        base["present_in_summary1"] = "1" if a else "0"
        base["present_in_summary2"] = "1" if b else "0"

        # Mean merge: mean(summary1_mean, summary2_mean) if both exist; else whichever exists.
        for nf in numeric_union_fields:
            va = parse_float(a.get(nf, "") if a else "")
            vb = parse_float(b.get(nf, "") if b else "")
            if va is not None and vb is not None:
                base[nf] = fmt_float((va + vb) / 2.0, 6)
            elif va is not None:
                base[nf] = fmt_float(va, 6)
            elif vb is not None:
                base[nf] = fmt_float(vb, 6)
            else:
                base[nf] = ""

        # Large-diff detection between source1 and source2 (pointwise source means)
        metric_reasons: list[str] = []
        for metric in COMPARE_METRICS:
            va = parse_float(a.get(metric, "") if a else "")
            vb = parse_float(b.get(metric, "") if b else "")
            d = rel_diff(va, vb)
            if d is not None and d >= args.large_diff_threshold:
                metric_reasons.append(f"{metric}_reldiff={d:.3f}")

        if metric_reasons:
            rec = dict(base)
            rec["rerun_reason"] = "large_diff"
            rec["reason_detail"] = ";".join(metric_reasons)
            diff_rows.append(rec)

        # Disturbance detection on merged data: pcie_read_p95 << mem_read_p95
        mem_p95 = parse_float(base.get("system_mem_read_p95_GBps", ""))
        pcie_p95 = parse_float(base.get("system_pcie_read_p95_GBps", ""))
        if mem_p95 is not None and pcie_p95 is not None and mem_p95 > 0:
            ratio = pcie_p95 / mem_p95
            if ratio < args.disturbance_ratio_threshold:
                rec = dict(base)
                rec["pcie_to_mem_p95_ratio"] = f"{ratio:.6f}"
                rec["rerun_reason"] = "pcie_p95_much_lower_than_mem_p95"
                rec["reason_detail"] = (
                    f"pcie_read_p95={pcie_p95:.6f} < mem_read_p95*{args.disturbance_ratio_threshold:.2f} "
                    f"(mem_read_p95={mem_p95:.6f}, ratio={ratio:.3f})"
                )
                disturbance_rows.append(rec)

        merged_rows.append(base)

    # Union rerun points by key with merged reasons
    rerun_map: dict[PointKey, dict[str, str]] = {}
    for src in (diff_rows, disturbance_rows):
        for row in src:
            key = PointKey.from_row(row)
            if key not in rerun_map:
                rerun_map[key] = dict(row)
            else:
                prev = rerun_map[key]
                old_reason = prev.get("rerun_reason", "")
                new_reason = row.get("rerun_reason", "")
                old_detail = prev.get("reason_detail", "")
                new_detail = row.get("reason_detail", "")
                reasons = sorted({x for x in [old_reason, new_reason] if x})
                details = sorted({x for x in [old_detail, new_detail] if x})
                prev["rerun_reason"] = "+".join(reasons)
                prev["reason_detail"] = " | ".join(details)

    rerun_rows = sorted(
        rerun_map.values(),
        key=lambda r: (
            safe_int_text(r.get("testcase", "0")),
            r.get("run_label", ""),
            r.get("tuning_param_name", ""),
            safe_int_text(r.get("tuning_param_value_bytes", "0")),
            safe_int_text(r.get("buffer_MiB", "0")),
        ),
    )

    now_text = datetime.now().isoformat(timespec="seconds")
    for row in merged_rows:
        row["analysis_generated_at"] = now_text
    for row in diff_rows:
        row["analysis_generated_at"] = now_text
    for row in disturbance_rows:
        row["analysis_generated_at"] = now_text
    for row in rerun_rows:
        row["analysis_generated_at"] = now_text

    merged_fields = [
        "analysis_generated_at",
        *KEY_FIELDS,
        *[f for f in META_KEEP_FIELDS if f not in KEY_FIELDS],
        "present_in_summary1",
        "present_in_summary2",
        *numeric_union_fields,
    ]

    diff_fields = merged_fields + ["rerun_reason", "reason_detail"]

    write_csv(outdir / "combined_intel_pcm_summary12_mean.csv", merged_rows, merged_fields)
    write_csv(outdir / "points_large_diff_between_summary1_and_summary2.csv", diff_rows, diff_fields)
    write_csv(outdir / "points_pcie_mem_p95_disturbance.csv", disturbance_rows, diff_fields)
    write_csv(outdir / "points_to_rerun_union.csv", rerun_rows, diff_fields)

    rerun_script = args.rerun_script.resolve()
    build_rerun_script(rerun_rows, rerun_script)

    manifest = outdir / "analysis_manifest.txt"
    manifest.write_text(
        "\n".join(
            [
                f"generated_at={now_text}",
                f"input1={input1}",
                f"input2={input2}",
                f"output_dir={outdir}",
                f"large_diff_threshold={args.large_diff_threshold}",
                f"disturbance_ratio_threshold={args.disturbance_ratio_threshold}",
                f"merged_points={len(merged_rows)}",
                f"large_diff_points={len(diff_rows)}",
                f"disturbance_points={len(disturbance_rows)}",
                f"union_rerun_points={len(rerun_rows)}",
                f"rerun_script={rerun_script}",
            ]
        )
        + "\n"
    )

    print(f"Merged mean CSV: {outdir / 'combined_intel_pcm_summary12_mean.csv'}")
    print(f"Large-diff points: {len(diff_rows)} -> {outdir / 'points_large_diff_between_summary1_and_summary2.csv'}")
    print(f"Disturbance points: {len(disturbance_rows)} -> {outdir / 'points_pcie_mem_p95_disturbance.csv'}")
    print(f"Union rerun points: {len(rerun_rows)} -> {outdir / 'points_to_rerun_union.csv'}")
    print(f"Rerun script: {rerun_script}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
