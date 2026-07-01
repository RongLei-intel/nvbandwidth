# Low-sample rerun plan: minimum 15 PCM samples

Generated from `combined_results_20260701_021706/latest_full_sweep_repeat_aggregate.csv`.

## What will be rerun

The rerun manifest is `low_sample_rerun_manifest_min15.csv`.

It contains 64 low-sample points:

- testcase 16: 24 points
  - `sm_copy_bytes=32`
  - buffers `1 2 4 8 16 32`
  - labels `ro_on_c000`, `ro_off_c000`, `ro_on_ff00`, `ro_off_ff00`
- testcase 33: 40 points
  - `ptr_chase_load_bytes=32`
  - buffers `1 2 4 8 16 32 64 128 256 512`
  - labels `ro_on_c000`, `ro_off_c000`, `ro_on_ff00`, `ro_off_ff00`

Each point keeps `RETRIES=3` by default, so every point is rerun three times.

## How loopCount was chosen

For each point, the script uses the old aggregate runtime and loop count to estimate a longer loop count:

- target run time: about 20 seconds per repeat
- safety factor: 1.25
- PCM interval: 1 second
- goal: at least 15 PCM samples per repeat

The computed value is stored in `target_loop_count` in the manifest.

## Run command

```bash
bash ./rerun_low_sample_cases_min15.sh
```

The output root defaults to:

```text
rerun_low_sample_min15/<timestamp>/
```

You can override it:

```bash
OUTBASE=rerun_low_sample_min15/manual_$(date +%Y%m%d_%H%M%S) bash ./rerun_low_sample_cases_min15.sh
```

## Merge after rerun

After the rerun finishes, merge it into the existing integrated results:

```bash
python3 merge_low_sample_reruns.py --base combined_results_20260701_021706 --rerun-root rerun_low_sample_min15/<timestamp>
```

The merge script creates a new directory named like:

```text
combined_results_20260701_021706_with_low_sample_reruns_<timestamp>/
```

It replaces the original low-sample point keys with the rerun rows, then regenerates:

- `latest_full_sweep_rows.csv`
- `latest_full_sweep_repeat_aggregate.csv`
- `low_sample_rerun_rows.csv`
- `anomalies_after_low_sample_merge.csv`
- `merge_manifest.txt`
- `README.md`

## Notes

- The rerun script applies the RO/MSR states in the same order as `sweep_config.sh`.
- It runs each low-sample buffer as a separate sweep so each buffer can use its own computed `LOOP_COUNT`.
- If any point still has fewer than 15 samples after merge, it will appear in `anomalies_after_low_sample_merge.csv` with `low_pcm_*_samples_after_merge`.
