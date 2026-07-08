import json
import os
import re
from pathlib import Path
from openpyxl import load_workbook

OUT_DIR = Path('/home/ronglei/nvbandwidth/out')
XLSX_PATH = '/home/ronglei/nvbandwidth/all_point_summary_compact.xlsx'

CASE_INFO_RE = re.compile(r'\[ OK \] \S+ loop_count=(\d+)')
DIR_RE = re.compile(r't(\d+)_(kib|mib)_b(\d+)(?:\.\d+)?[Kk]?[Ii]?[Bb]?_(tsmCopyBytes|tptrChaseLoadBytes)(\d+)(?:MiB|KiB)?')
TUNE_MAP = {
    'tsmCopyBytes': 'sm_copy_bytes',
    'tptrChaseLoadBytes': 'ptr_chase_load_bytes',
}
TESTCASE_MAP = {16: 'Sequential', 33: 'Random'}

def parse_case_name(name):
    # name format: t16_mib_b1MiB_tsmCopyBytes4  or  t33_kib_b512KiB_tptrChaseLoadBytes8
    m = re.match(r't(\d+)_(kib|mib)_b(\d+)[A-Za-z]*_(tsmCopyBytes|tptrChaseLoadBytes)(\d+)$', name)
    if not m:
        return None
    testcase = int(m.group(1))
    unit = m.group(2)
    buf_val = int(m.group(3))
    tune_name = m.group(4)
    tune_val = int(m.group(5))

    if unit == 'kib':
        buffer_mib = buf_val / 1024.0
    else:
        buffer_mib = float(buf_val)

    return {
        'testcase': TESTCASE_MAP.get(testcase, f't{testcase}'),
        'buffer_mib': buffer_mib,
        'tuning_param_name': TUNE_MAP.get(tune_name, tune_name),
        'per_load_bytes': tune_val,
    }

def parse_summary(path):
    data = {}
    if not path.exists():
        return data
    text = path.read_text(errors='replace')
    for line in text.splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            data[k.strip()] = v.strip()
    return data

def parse_case_info(path):
    if not path.exists():
        return None, None
    text = path.read_text(errors='replace').strip()
    m = CASE_INFO_RE.search(text)
    if m:
        return 'ok', int(m.group(1))
    if '[ OK ]' in text:
        return 'ok', None
    return None, None

def safe_float(val, default=None):
    if val is None:
        return default
    try:
        f = float(val)
        if str(val).strip() in {'-', 'N/A', '[N/A]', 'NA', 'NOT_FOUND'}:
            return default
        return f
    except (ValueError, TypeError):
        return default

def main():
    wb = load_workbook(XLSX_PATH)
    ws = wb['all_point_summary_compact']

    # Find the header row (row 302 in original, which is row 2 in openpyxl 0-indexed)
    # Actually, let's find it dynamically. Row 302 in the file has the column headers.
    # In openpyxl, rows are 1-indexed.
    header_row = None
    for row in ws.iter_rows(min_row=1, max_row=500, max_col=1, values_only=False):
        val = str(row[0].value or '')
        if val.strip() == 'data_source_name':
            header_row = row[0].row
            break
    if header_row is None:
        # Try alternate header
        for row in ws.iter_rows(min_row=1, max_row=500, max_col=1, values_only=False):
            val = str(row[0].value or '')
            if val.strip() == 'data_source':
                header_row = row[0].row
                break
    if header_row is None:
        print("ERROR: Could not find header row")
        return

    print(f"Header found at row {header_row}")

    # Read headers
    headers = []
    for col in range(1, ws.max_column + 1):
        val = ws.cell(row=header_row, column=col).value
        headers.append(str(val or '').strip())

    print(f"Headers: {headers}")

    # Find last data row
    last_row = header_row
    for row in range(header_row + 1, ws.max_row + 1):
        if ws.cell(row=row, column=1).value is not None:
            last_row = row

    print(f"Last data row: {last_row}")

    # Collect existing (source_file, loop_count) pairs to avoid duplicates
    existing = set()
    for row in range(header_row + 1, last_row + 1):
        sf = str(ws.cell(row=row, column=headers.index('source_file') + 1).value or '')
        lc = str(ws.cell(row=row, column=headers.index('loop_count') + 1).value or '')
        existing.add((sf, lc))

    next_row = last_row + 1
    new_rows = 0
    skipped = 0
    errors = []

    for label_dir in sorted(os.listdir(OUT_DIR)):
        if label_dir not in ('ro_on', 'ro_off'):
            continue
        ro_state = 'on' if label_dir == 'ro_on' else 'off'
        run_label = label_dir

        cases_dir = OUT_DIR / label_dir
        for case_name in sorted(os.listdir(cases_dir)):
            case_path = cases_dir / case_name
            summary_path = case_path / 'summary.txt'
            case_info_path = case_path / 'case.info'

            parsed = parse_case_name(case_name)
            if parsed is None:
                err = f"Could not parse case name: {case_name}"
                print(f"  WARN: {err}")
                errors.append(err)
                continue

            status, loop_count = parse_case_info(case_info_path)
            if status != 'ok':
                err = f"Case not OK: {case_name}"
                print(f"  WARN: {err}")
                errors.append(err)
                continue

            summary = parse_summary(summary_path)
            if not summary:
                err = f"Empty summary for {case_name}"
                print(f"  WARN: {err}")
                errors.append(err)
                continue

            # Check for duplicate
            sf_key = str(summary_path)
            lc_key = str(loop_count) if loop_count else ''
            if (sf_key, lc_key) in existing:
                skipped += 1
                continue

            nv_bw = safe_float(summary.get('nvbandwidth_SUM_GBps'), 0)
            mem_read = safe_float(summary.get('system_total_mem_read_bw_GBps_median'))
            mem_total = safe_float(summary.get('system_total_mem_bw_GBps_median'))
            pcie_read = safe_float(summary.get('system_total_pcie_read_bw_GBps_median'))
            pcie_total = safe_float(summary.get('system_total_pcie_bw_GBps_median'))
            target_mem_read = safe_float(summary.get('target_package_total_mem_read_bw_GBps_median'))
            pcm_samples = safe_float(summary.get('timeseries_samples'), 0)

            row_data = [
                'amd_sweep_current',       # data_source_name
                'amd',                      # system
                parsed['testcase'],         # testcase
                run_label,                  # run_label
                ro_state,                   # ro_state
                'na',                       # config_tag
                parsed['tuning_param_name'],# tuning_param_name
                parsed['per_load_bytes'],   # per_load_bytes
                parsed['buffer_mib'],       # buffer_MiB
                1,                          # repeat_count
                'ok',                       # statuses
                'amd_point_summary',        # source_kind
                str(summary_path),          # source_file
                'AMD sweep per-case result; collected via sweep_config_amd.sh with AMDuProfPcm',  # source_note
                loop_count if loop_count else '',  # loop_count
                nv_bw,                      # nvbandwidth_gbps
                mem_read,                   # memory_read_gbps
                mem_total,                  # memory_gbps
                pcie_read,                  # pcie_read_gbps
                pcie_total,                 # pcie_gbps
                None,                       # gpu_pcie_gbps
                target_mem_read,            # target_socket_mem_read_gbps
                int(pcm_samples) if pcm_samples else None,  # pcm_memory_samples
                int(pcm_samples) if pcm_samples else None,  # pcm_pcie_samples
                None,                       # nvidia_dmon_rows
                None,                       # run_seconds
            ]

            for col_idx, val in enumerate(row_data, start=1):
                ws.cell(row=next_row, column=col_idx, value=val)

            new_rows += 1
            next_row += 1

    wb.save(XLSX_PATH)
    print(f"\nDone. Added {new_rows} new rows, skipped {skipped} duplicates, {len(errors)} errors")
    if errors:
        for e in errors[:10]:
            print(f"  {e}")
        if len(errors) > 10:
            print(f"  ... and {len(errors)-10} more")

if __name__ == '__main__':
    main()
