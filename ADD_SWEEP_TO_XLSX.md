# 将 sweep 结果添加到 all_point_summary_compact.xlsx

## 概述

每次跑完 sweep 后，用 `aggregate_intel_sweep_to_xlsx.py` 解析所有 `summary.txt` 并追加到 xlsx。

## 步骤

### 1. 备份

```bash
cp all_point_summary_compact.xlsx all_point_summary_compact.xlsx.bak
```

### 2. 确认数据量

```bash
find <sweep_dir>/ -name summary.txt | wc -l
# 全量 sweep (t16+t33, 4 groups): 464
# 仅 t16 (4 groups): 272
# 仅 t17 (4 groups, buffer only): 48
# 仅 t16 (2 groups): 136
```

### 3. 追加到 xlsx

```bash
python3 aggregate_intel_sweep_to_xlsx.py \
    --root <sweep_dir> \
    --xlsx all_point_summary_compact.xlsx \
    --data-source "intel_sweep_YYYYMMDD_<描述>"
```

- `--root`: sweep 结果根目录
- `--xlsx`: 目标 xlsx 文件（默认 `all_point_summary_compact.xlsx`）
- `--data-source`: **必须换新标签**，用日期+描述区分不同批次

### 4. 验证

```bash
python3 -c "
import openpyxl
wb = openpyxl.load_workbook('all_point_summary_compact.xlsx')
ws = wb['all_point_summary_compact']
print(f'Total rows: {ws.max_row}')
sources = {}
for r in range(2, ws.max_row+1):
    src = ws.cell(row=r, column=1).value
    sources[src] = sources.get(src, 0) + 1
for k,v in sorted(sources.items()):
    print(f'  {k}: {v}')
"
```

确认新 data_source 行数正确，且数值列均为数字格式（非文本）。

### 5. Dry run（可选，预览）

```bash
python3 aggregate_intel_sweep_to_xlsx.py --root <sweep_dir> --dry-run
```

## 列说明

| 列 | 含义 | 数据来源 |
|---|---|---|
| data_source | 批次标签 | 命令行参数 |
| system | 平台 | 固定 "intel" |
| testcase | Sequential / Random | t16/17=Sequential, t33=Random |
| run_label | 完整运行标签 | ro_on_c000 等 |
| ro_state | on / off | |
| io_cache_way | IO cache way 配置 | c000 / ff00（MSR 0xc8b 值） |
| tuning_param_name | sm_copy_bytes / ptr_chase_load_bytes | 空串表示无调参 |
| per_load_bytes | 单次 load/store 宽度 | |
| buffer_MiB | buffer 大小 (MiB) | |
| repeat_count | 重复次数 | 固定 1 |
| statuses | 运行状态 | |
| source_kind | 数据来源类型 | |
| source_file | 源文件路径 | |
| source_note | 备注 | |
| loop_count | 循环次数 | |
| nvbandwidth_gbps | nvbandwidth 实测带宽 | summary.txt |
| memory_read_gbps | PCM System.Read active avg | pcm-memory.csv |
| memory_gbps | PCM System.Memory active avg | pcm-memory.csv |
| pcie_read_gbps | PCM System PCIe Rd active avg | pcm-pcie.csv |
| pcie_write_gbps | PCM System PCIe Wr active avg | pcm-pcie.csv |
| pcie_gbps | PCM System PCIe Total active avg | pcm-pcie.csv |
| gpu_pcie_gbps | dmon GPU rx+tx active avg | nvidia-dmon.out |
| target_socket_mem_read_gbps | 目标 socket 内存读 | pcm-memory.csv (SKT{N}) |
| pcm_memory_samples | PCM 内存采样数 | |
| pcm_pcie_samples | PCM PCIe 采样数 | |
| nvidia_dmon_rows | dmon 行数 | |
| run_seconds | 测试耗时 | |
| hostbuffer_init | host buffer 初始化方式 | cpu = --hostInitCpu, gpu = 默认 |

## 指标说明

### active avg 逻辑

PCM/dmon 的 avg 列（memory_read_gbps, pcie_read_gbps, pcie_write_gbps, pcie_gbps, gpu_pcie_gbps）使用 **active-sample average**：过滤掉低于 `max × 1%` 的空闲采样后计算均值。这样避免了 PCM 在测试前后空闲时段采集的零值稀释有效带宽数据。

### t16/t17 的 PCIe 方向

- **t16 (host→device)**：GPU 从 host 读数据 → CPU 侧 PCIe **Read** 为主，对应 `pcie_read_gbps`
- **t17 (device→host)**：GPU 向 host 写数据 → CPU 侧 PCIe **Write** 为主，对应 `pcie_write_gbps`

## 注意事项

- **不要用 Excel 编辑 xlsx**，Excel 保存后会丢失 openpyxl 追加的行
- **data_source 必须唯一**，每次追加用新标签
- 如果 `out/` 里有个别 case 失败（缺 summary.txt），脚本会跳过并打印 SKIP
- 重新生成 summary.txt（修复脚本后回填旧数据）：
  ```bash
  for d in <sweep_dir>/*/t*/; do
      env SUMMARIZE_ONLY_DIR="$d" SAMPLE_INTERVAL=0.1 bash collect_pcm_nvsmi_nvbw.sh
  done
  ```
