import csv
from collections import defaultdict
from statistics import mean, stdev, median

CSV = "/home/ronglei/nvbandwidth/nvbw_all_results/all_results.csv"

rows = []
with open(CSV, newline='') as f:
    for r in csv.DictReader(f):
        r['buffer_size_mib'] = int(r['buffer_size_mib'])
        r['case_idx'] = int(r['case_idx'])
        r['sub_idx'] = int(r['sub_idx'])
        r['src_device'] = int(r['src_device'])
        r['dst_device'] = int(r['dst_device'])
        r['bandwidth_gbps'] = float(r['bandwidth_gbps'])
        rows.append(r)

def filter_rows(rows, **conds):
    return [r for r in rows if all(r[k] == v for k, v in conds.items())]

def pct(a, b):
    return (a - b) / b * 100 if b else 0

print("=" * 80)
print("ANOMALY ANALYSIS REPORT (grouped by topology)")
print("=" * 80)

# --- Identify GPU topology groups by P2P bandwidth ---
# Get a representative P2P test to cluster GPUs
scope = filter_rows(rows, testcase='device_to_device_memcpy_read_ce', sub_idx=0, buffer_size_mib=512)
# Build a matrix: src->dst bandwidth
p2p_mat = defaultdict(dict)
for r in scope:
    p2p_mat[r['src_device']][r['dst_device']] = r['bandwidth_gbps']

# Find GPU clustering: GPUs that have high bandwidth between them are in same group
num_gpus = max(r['src_device'] for r in rows) + 1
print(f"\nTopology: {num_gpus} GPUs")
print("P2P bandwidth matrix (GB/s) at 512MiB:")
print("     " + "".join(f"  GPU{i}  " for i in range(num_gpus)))
for src in range(num_gpus):
    vals = [p2p_mat[src].get(dst, 0) for dst in range(num_gpus)]
    print(f"GPU{src}: " + " ".join(f"{v:8.1f}" if v > 0 else "     N/A" for v in vals))

# Identify groups by bandwidth threshold
hi_bw = max(max(vals.values()) if vals else 0 for vals in p2p_mat.values())
lo_bw = min(min(vals.values()) if vals else 0 for vals in p2p_mat.values())
threshold = (hi_bw + lo_bw) / 2
groups = {}
for src in range(num_gpus):
    for dst in range(num_gpus):
        if src >= dst:
            continue
        bw = p2p_mat[src].get(dst, 0)
        if bw > 0:
            typ = "HIGH" if bw > threshold else "LOW"
            if typ == "HIGH":
                groups.setdefault(src, set()).add(dst)
                groups.setdefault(dst, set()).add(src)

# Cluster
from collections import deque
visited = set()
clusters = []
for g in range(num_gpus):
    if g in visited:
        continue
    cluster = set()
    q = deque([g])
    while q:
        n = q.popleft()
        if n in visited:
            continue
        visited.add(n)
        cluster.add(n)
        for neighbor in groups.get(n, set()):
            if neighbor not in visited:
                q.append(neighbor)
    if cluster:
        clusters.append(sorted(cluster))

print(f"\nDetected {len(clusters)} NUMA/PCIe groups: {clusters}")

# --- 1. HostDevice: per-GPU grouped analysis ---
print("\n" + "=" * 80)
print("### 1. HostDevice: GPU performance by NUMA group ###")
hd = filter_rows(rows, test_type='HostDevice', metric_type='Bandwidth', sub_idx=0, buffer_size_mib=512, host_init_cpu='default', cache_way_label='2_ways')
gpu_data = defaultdict(lambda: defaultdict(list))
for r in hd:
    gpu_data[r['testcase']][r['dst_device']].append(r['bandwidth_gbps'])

print(f"{'Testcase':<45} " + "  ".join(f"Grp{i}({','.join(map(str,c))})" for i, c in enumerate(clusters)))
for tc, devs in sorted(gpu_data.items()):
    cluster_avgs = []
    for ci, cluster in enumerate(clusters):
        vals = [v for g in cluster for v in devs.get(g, [])]
        cluster_avgs.append(mean(vals) if vals else 0)
    print(f"  {tc:<43} " + "  ".join(f"{v:8.2f}" for v in cluster_avgs))

# Flag: intra-cluster variance > 5%
print(f"\n### 1b. Intra-group outliers (>5% from group mean) ###")
for tc, devs in sorted(gpu_data.items()):
    for ci, cluster in enumerate(clusters):
        vals = {g: mean(devs[g]) for g in cluster if g in devs}
        if len(vals) < 2:
            continue
        avg = mean(vals.values())
        for g, v in vals.items():
            if abs(pct(v, avg)) > 5:
                print(f"  {tc}  Group{ci} GPU{g}: {v:.2f} GB/s (group avg {avg:.2f}, {pct(v,avg):+.1f}%)")

# --- 2. P2P: intra-group vs cross-group bandwidth ---
print("\n" + "=" * 80)
print("### 2. P2P: Intra-group vs Cross-group bandwidth (512MiB) ###")
scope = filter_rows(rows, testcase='device_to_device_memcpy_read_ce', sub_idx=0, buffer_size_mib=512)
intra_vals = []
cross_vals = []
for r in scope:
    src_grp = next((i for i, c in enumerate(clusters) if r['src_device'] in c), -1)
    dst_grp = next((i for i, c in enumerate(clusters) if r['dst_device'] in c), -1)
    if src_grp == dst_grp:
        intra_vals.append(r['bandwidth_gbps'])
    else:
        cross_vals.append(r['bandwidth_gbps'])

if intra_vals and cross_vals:
    print(f"  Intra-group: {mean(intra_vals):.1f} ± {stdev(intra_vals):.1f} GB/s (range: {min(intra_vals):.1f}-{max(intra_vals):.1f})")
    print(f"  Cross-group: {mean(cross_vals):.1f} ± {stdev(cross_vals):.1f} GB/s (range: {min(cross_vals):.1f}-{max(cross_vals):.1f})")
    print(f"  Cross/Intra ratio: {mean(cross_vals)/mean(intra_vals):.3f}")

# P2P variance within same-group pairs
print(f"\n### 2b. P2P intra-group pair variance ###")
p2p_all = filter_rows(rows, test_type='P2P', metric_type='Bandwidth')
for tc in sorted(set(r['testcase'] for r in p2p_all)):
    scope = filter_rows(p2p_all, testcase=tc, sub_idx=0, buffer_size_mib=512)
    for ci, cluster in enumerate(clusters):
        vals = {}
        for r in scope:
            if r['src_device'] in cluster and r['dst_device'] in cluster and r['src_device'] != r['dst_device']:
                pair = (r['src_device'], r['dst_device'])
                vals[pair] = r['bandwidth_gbps']
        if len(vals) >= 3:
            avg = mean(vals.values())
            outliers = {p: v for p, v in vals.items() if abs(pct(v, avg)) > 10}
            if outliers:
                for (s, d), v in outliers.items():
                    print(f"  {tc} Group{ci} GPU{s}->GPU{d}: {v:.2f} GB/s (group avg {avg:.2f}, {pct(v,avg):+.1f}%)")

# --- 3. P2P SM Read/Write asymmetry ---
print("\n" + "=" * 80)
print("### 3. P2P SM: Read vs Write asymmetry (512MiB) ###")
for ci, cluster in enumerate(clusters):
    read_scope = filter_rows(rows, testcase='device_to_device_memcpy_read_sm', sub_idx=0, buffer_size_mib=512)
    write_scope = filter_rows(rows, testcase='device_to_device_memcpy_write_sm', sub_idx=0, buffer_size_mib=512)
    ratios = []
    read_dict = {}
    write_dict = {}
    for r in read_scope:
        if r['src_device'] in cluster and r['dst_device'] in cluster:
            read_dict[(r['src_device'], r['dst_device'])] = r['bandwidth_gbps']
    for r in write_scope:
        if r['src_device'] in cluster and r['dst_device'] in cluster:
            write_dict[(r['src_device'], r['dst_device'])] = r['bandwidth_gbps']
    for pair, rv in read_dict.items():
        if pair in write_dict and rv > 0:
            ratios.append((pair[0], pair[1], rv, write_dict[pair], rv / write_dict[pair]))
    avgr = mean(r[4] for r in ratios) if ratios else 0
    print(f"  Group{ci}: avg read/write ratio = {avgr:.3f} (expected ~1.0)")
    for s, d, rv, wv, rt in ratios:
        if abs(rt - 1.0) > 0.15:
            print(f"    GPU{s}->GPU{d}: read={rv:.1f} write={wv:.1f} ratio={rt:.3f}")

# --- 4. Bidirectional efficiency ---
print("\n" + "=" * 80)
print("### 4. P2P Bidirectional efficiency: total vs 2x unidirectional (512MiB) ###")
for engine in ['ce', 'sm']:
    for direction in ['read', 'write']:
        uni_tc = f'device_to_device_memcpy_{direction}_{engine}'
        bi_tc = f'device_to_device_bidirectional_memcpy_{direction}_{engine}'
        uni = filter_rows(rows, testcase=uni_tc, sub_idx=0, buffer_size_mib=512)
        bi = filter_rows(rows, testcase=bi_tc, sub_idx=2, buffer_size_mib=512)
        ratios = []
        bi_dict = {(r['src_device'], r['dst_device']): r['bandwidth_gbps'] for r in bi}
        for r in uni:
            pair = (r['src_device'], r['dst_device'])
            if pair in bi_dict and r['bandwidth_gbps'] > 0:
                ratios.append(bi_dict[pair] / r['bandwidth_gbps'])
        if ratios:
            print(f"  {engine} {direction}: avg bi/uni = {mean(ratios):.2f} (expected ~2.0, range {min(ratios):.2f}-{max(ratios):.2f})")

# --- 5. Buffer size scaling: HostDevice ---
print("\n" + "=" * 80)
print("### 5. HostDevice: bandwidth vs buffer size by testcase ###")
for tc in sorted(set(r['testcase'] for r in rows if r['test_type'] == 'HostDevice' and r['metric_type'] == 'Bandwidth')):
    scope = filter_rows(rows, testcase=tc, sub_idx=0, host_init_cpu='default', cache_way_label='2_ways')
    buf_avgs = defaultdict(list)
    for r in scope:
        buf_avgs[r['buffer_size_mib']].append(r['bandwidth_gbps'])
    avgs = {b: mean(vals) for b, vals in buf_avgs.items()}
    sorted_b = sorted(avgs.keys())
    # Check for regressions (>10% drop at larger buffer)
    regs = []
    for i in range(len(sorted_b) - 1):
        if avgs[sorted_b[i+1]] < avgs[sorted_b[i]] * 0.90:
            regs.append(f"{sorted_b[i]}->{sorted_b[i+1]}: {avgs[sorted_b[i]]:.1f}->{avgs[sorted_b[i+1]]:.1f}")
    if regs:
        print(f"  {tc}: regressions: {', '.join(regs)}")
    else:
        print(f"  {tc}: no regressions (range: {avgs[sorted_b[0]]:.1f} @{sorted_b[0]}MiB -> {avgs[sorted_b[-1]]:.1f} @{sorted_b[-1]}MiB)")

# --- 6. Latency analysis ---
print("\n" + "=" * 80)
print("### 6. Latency by GPU group ###")
for tc in sorted(set(r['testcase'] for r in rows if r['metric_type'] == 'Latency')):
    scope = filter_rows(rows, testcase=tc, sub_idx=0, buffer_size_mib=512)
    print(f"\n  {tc}:")
    for ci, cluster in enumerate(clusters):
        vals = []
        for r in scope:
            if r['dst_device'] in cluster:
                vals.append(r['bandwidth_gbps'])
        if vals:
            print(f"    Group{ci} ({','.join(map(str,cluster))}): {mean(vals):.0f} ± {stdev(vals):.0f} ns")

# --- 7. Cache way & hostInitCpu impact (combined) ---
print("\n" + "=" * 80)
print("### 7. Cache way & hostInitCpu impact (>5% diff) ###")
for tc in sorted(set(r['testcase'] for r in rows)):
    for buf in [64, 512]:
        scope = filter_rows(rows, testcase=tc, sub_idx=0, buffer_size_mib=buf)
        if not scope:
            continue
        # Compare 2w_default vs all other configs
        d2 = [r['bandwidth_gbps'] for r in scope if r['cache_way_label'] == '2_ways' and r['host_init_cpu'] == 'default']
        d16 = [r['bandwidth_gbps'] for r in scope if r['cache_way_label'] == '16_ways' and r['host_init_cpu'] == 'default']
        c2 = [r['bandwidth_gbps'] for r in scope if r['cache_way_label'] == '2_ways' and r['host_init_cpu'] == 'cpuinit']
        c16 = [r['bandwidth_gbps'] for r in scope if r['cache_way_label'] == '16_ways' and r['host_init_cpu'] == 'cpuinit']
        for label, vals in [("2w_default", d2), ("16w_default", d16), ("2w_cpuinit", c2), ("16w_cpuinit", c16)]:
            if not vals:
                continue
            others = []
            for l2, v2 in [("2w_default", d2), ("16w_default", d16), ("2w_cpuinit", c2), ("16w_cpuinit", c16)]:
                if l2 != label and v2:
                    others.extend(v2)
            if others and vals:
                a1, a2 = mean(vals), mean(others)
                if max(abs(a1), abs(a2)) > 0 and abs(pct(a1, a2)) > 10:
                    print(f"  {tc} buf={buf}MiB  {label}: {a1:.2f} vs others avg {a2:.2f} ({pct(a1,a2):+.1f}%)")

# --- 8. hostInitCpu impact ---
print("\n" + "=" * 80)
print("### 8. hostInitCpu impact (>5% diff) ###")
for test_type in ['HostDevice', 'P2P']:
    for mt in ['Bandwidth', 'Latency']:
        scope = filter_rows(rows, test_type=test_type, metric_type=mt, sub_idx=0, buffer_size_mib=512)
        for tc in sorted(set(r['testcase'] for r in scope)):
            tc_scope = filter_rows(scope, testcase=tc)
            defaults = [r['bandwidth_gbps'] for r in tc_scope if r['host_init_cpu'] == 'default']
            cpuinits = [r['bandwidth_gbps'] for r in tc_scope if r['host_init_cpu'] == 'cpuinit']
            if defaults and cpuinits:
                d, c = mean(defaults), mean(cpuinits)
                if max(abs(d), abs(c)) > 0 and abs(pct(c, d)) > 5:
                    print(f"  [{test_type}] [{mt}] {tc}: default={d:.2f} cpuinit={c:.2f} ({pct(c,d):+.1f}%)")

# --- 9. Bidirectional CE: HostDevice split pattern ---
print("\n" + "=" * 80)
print("### 9. Bidirectional CE: GPU split pattern (2 GPUs underperforming) ###")
for tc in ['all_to_host_bidirectional_memcpy_ce', 'host_to_all_bidirectional_memcpy_ce']:
    scope = filter_rows(rows, testcase=tc, sub_idx=0, buffer_size_mib=64, cache_way_label='2_ways', host_init_cpu='default')
    per_gpu = defaultdict(list)
    for r in scope:
        per_gpu[r['dst_device']].append(r['bandwidth_gbps'])
    avgs = {g: mean(vals) for g, vals in per_gpu.items()}
    sorted_gpus = sorted(avgs.keys())
    all_avg = mean(avgs.values())
    print(f"\n  {tc} @64MiB:")
    for g in sorted_gpus:
        flag = " <<< LOW" if avgs[g] < all_avg * 0.85 else ""
        flag = " <<< HIGH" if avgs[g] > all_avg * 1.15 else flag
        print(f"    GPU{g}: {avgs[g]:.2f} GB/s (avg {all_avg:.2f}){flag}")

print("\n" + "=" * 80)
print("DONE")
