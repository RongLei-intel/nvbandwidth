# 往 `all_point_summary_compact.xlsx` 添加新数据

## 文件结构

- `all_point_summary_compact.xlsx` 是汇总表格，核心 sheet 是 **all_point_summary_compact**，为扁平化的单表结构。
- 其他 sheets (`Intel vs AMD Random`, `Random vs Sequential`, `GNR RO`, `amd IO cache` 等) 是数据透视表/图表源，数据写入后需要手动刷新透视表。

## 新增数据的步骤

### 1. 运行 AMD 测试并确保结果在 `out/` 目录下

```bash
# 完整 sweep（含 RO 开关 + 2 轮采集）
sudo bash sweep_config_amd.sh

# 或者只跑某类 testcase（需手动控制 RO 状态）
env RUN_LABEL=ro_on ONLY_TESTCASE=16 bash sweep_amd_all.sh
env RUN_LABEL=ro_off ONLY_TESTCASE=33 bash sweep_amd_all.sh
```

每个 case 的结果存放在 `out/{run_label}/{case_name}/` 目录中，包含：

| 文件 | 内容 |
|------|------|
| `case.info` | 状态 `[ OK ]` + loop_count |
| `summary.txt` | nvbandwidth 带宽 + PCM 解析结果 |
| `run.info` | 运行参数 |
| `nvbandwidth.out` / `nvbandwidth.err` | nvbandwidth 原始输出 |
| `amdprof_pcm.out` / `amdprof_pcm.err` | AMDuProfPcm 原始输出 |

### 2. 确认 `fill_xlsx.py` 脚本逻辑正确

脚本位于项目根目录 `fill_xlsx.py`。

#### 核心映射规则

| JSON/sweep 中的字段 | xlsx 中的列 | 映射方式 |
|---|---|---|
| testcase=16 | `testcase` = `Sequential` | t16 → Sequential（顺序访问） |
| testcase=33 | `testcase` = `Random` | t33 → Random（随机访问） |
| `ro_on` | `ro_state` = `on` | RO enabled |
| `ro_off` | `ro_state` = `off` | RO disabled |
| `tuning_param_name` | `tuning_param_name` | `smCopyBytes` → `sm_copy_bytes` |
| | | `ptrChaseLoadBytes` → `ptr_chase_load_bytes` |
| 目录名中的 tune 值 | `per_load_bytes` | 如 `tsmCopyBytes32` → 32 |
| buffer 大小 | `buffer_MiB` | KiB 转换为 MiB（如 512 KiB → 0.5） |
| | | MiB 直接保留（如 128 MiB → 128） |
| `nvbandwidth_SUM_GBps` | `nvbandwidth_gbps` | nvbandwidth 带宽主数据 |
| `system_total_mem_read_bw_GBps_median` | `memory_read_gbps` | PCM 系统内存读带宽 |
| `system_total_mem_bw_GBps_median` | `memory_gbps` | PCM 系统总内存带宽 |
| `system_total_pcie_read_bw_GBps_median` | `pcie_read_gbps` | PCM 系统 PCIe 读带宽 |
| `system_total_pcie_bw_GBps_median` | `pcie_gbps` | PCM 系统 PCIe 总带宽 |
| `target_package_total_mem_read_bw_GBps_median` | `target_socket_mem_read_gbps` | 目标 socket 内存读带宽 |
| `timeseries_samples` | `pcm_memory_samples` / `pcm_pcie_samples` | PCM 采样数 |
| `[ OK ] case loop_count=N` | `loop_count` | 最终 loop_count |
| `-` | `data_source` | 固定为 `amd_sweep_current` |
| `-` | `system` | 固定为 `amd` |
| `-` | `config_tag` | 固定为 `na`（AMD 无缓存配置 tag） |
| `-` | `repeat_count` | 固定为 `1`（单次运行） |
| `-` | `statuses` | 固定为 `ok` |
| `-` | `source_kind` | 固定为 `amd_point_summary` |

#### 目录名解析格式

```
t{testcase}_{unit}_b{buffer}{unit_suffix}_{tuneName}{tuneValue}
```

示例：
- `t16_mib_b1MiB_tsmCopyBytes4` → testcase=16, unit=MiB, buffer=1, tuneName=tsmCopyBytes, tuneValue=4
- `t33_kib_b512KiB_tptrChaseLoadBytes32` → testcase=33, unit=KiB, buffer=512, tuneName=tptrChaseLoadBytes, tuneValue=32

### 3. 执行添加

```bash
python3 fill_xlsx.py
```

脚本会自动：
1. 读取 xlsx 文件的 `all_point_summary_compact` sheet
2. 遍历 `out/ro_on/` 和 `out/ro_off/` 下所有 case
3. 解析 summary.txt + case.info
4. 跳过已存在的数据（基于 source_file + loop_count 去重）
5. 追加新行到表格末尾
6. 保存 xlsx

### 4. 验证结果

```bash
# 检查新数据行数和内容
python3 -c "
from openpyxl import load_workbook
wb = load_workbook('all_point_summary_compact.xlsx')
ws = wb['all_point_summary_compact']
sources = {}
for row in range(2, ws.max_row + 1):
    ds = str(ws.cell(row=row, column=1).value or '')
    sources[ds] = sources.get(ds, 0) + 1
for k, v in sorted(sources.items()):
    print(f'{k}: {v}')
"
```

### 5. 刷新数据透视表（手动操作）

在 Excel/WPS/LibreOffice 中打开文件，手动刷新所有透视表 sheets：
- **Intel vs AMD Random**
- **Intel vs AMD seq**
- **Random vs Sequential**
- **GNR RO**
- **GNR IO Cache way**
- **GNR IO Cache**
- **amd IO cache**

## 注意事项

### 命名规范

- `fill_xlsx.py` 中的 `data_source` 值需区分数据来源批次。
  - `amd_sweep_current`：当前 sweep 的数据
  - 之前已有 `amd_4groups_summary`, `amd_small_buffer_sweep` 等
  - 新增批次时建议修改 `fill_xlsx.py` 中的 `'amd_sweep_current'` 为新的标识符

### 关键检查点

1. **buffer_MiB 列**：KiB 单位的 buffer 必须转成浮点数（如 512 KiB → 0.5 MiB），不能直接存为整数。
2. **per_load_bytes 列**：t16 对应 `smCopyBytes{N}` 中的 N，t33 对应 `ptrChaseLoadBytes{N}` 中的 N。
3. **testcase 列**：t16 必须是 `Sequential`，t33 必须是 `Random`，不能混淆。
4. **去重逻辑**：基于 `source_file`（summary.txt 路径）+ `loop_count` 两列组合去重。如果 re-run 了同一个 case 且 loop_count 不同，会被视为新数据。
5. **高带宽 case（tune=32）**：nvbandwidth 结果可能 >100 GB/s 甚至 >10000 GB/s。这是正常现象（32字节大拷贝），PCM 的 pcie_read 中位数可能接近 0，不影响数据有效性。

### 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| buffer_MiB 列出现 128 实为 KiB 值 | unit 字段大小写匹配错误 | 检查 `parse_case_name` 中 `unit == 'kib'` 判断 |
| 数据未追加 | 已有相同 source_file + loop_count | 删除老数据行或修改去重逻辑 |
| PCM 数据为 NOT_FOUND | 高带宽 case 完成太快，PCM 未采样到有效点 | 仍会追加，memory/pcie 字段为 None |
| 透视表未更新 | xlsx 中透视表需要手动刷新 | 打开文件后手动刷新或设置自动刷新 |

### 扩展指南

如需添加非 AMD 数据（如 Intel），需要：
1. 修改 `fill_xlsx.py` 中 `system` 字段为 `'intel'`
2. 适配 Intel 的 `config_tag`（如 `c000`、`ff00`）和 `run_label` 格式
3. Intel PCM 数据可能包含 `gpu_pcie_gbps` 和 `nvidia_dmon_rows` 等额外字段
