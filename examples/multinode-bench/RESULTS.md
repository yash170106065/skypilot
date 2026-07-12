# Results table

Environment: local `kind` cluster (`kind-skypilot`), 4 CPU nodes, stock SkyPilot K8s image
`us-docker.pkg.dev/sky-dev-465/skypilotk8s/skypilot@sha256:26cfaecb…`.
Primary metric: **`t_all_ranks_sec`** = `sky jobs launch` → slowest rank’s first `run:` echo.

## Launch (4 nodes, 3 trials each)

| Side | Trial | `t_all_ranks_sec` | Bootstrap (`t_runtime_bootstrap_sec`) | Miniconda re-download | Git |
|------|-------|-------------------|----------------------------------------|-----------------------|-----|
| Stock master | 1 | 109.3 | 64 | yes | `c803f77d1` |
| Stock master | 2 | **137.7** (median) | 48 | yes | `c803f77d1` |
| Stock master | 3 | 165.2 | 60 | yes | `c803f77d1` |
| Optimized | 1 | 46.5 | 10 | no | `1594439d6` |
| Optimized | 2 | **43.8** | 5 | no | `1594439d6` |
| Optimized | 3 | 46.8 | 10 | no | `1594439d6` |

| | Master median | Optimized median | Speedup |
|--|---------------|------------------|---------|
| `t_all_ranks_sec` | 137.7s | 46.5s | **2.96×** (−66%) |
| Bootstrap | ~60s | ~10s | **~6×** |

CSV: [`results/master_vs_optimized_n4_comparison.csv`](results/master_vs_optimized_n4_comparison.csv)

Raw trial directories:

- [`results/master_n4_20260711_200512/`](results/master_n4_20260711_200512/)
- [`results/optimized_n4_20260711_201521/`](results/optimized_n4_20260711_201521/)

## Recovery bonus (delete one worker mid-run)

| Side | Job | Delete → RECOVERING | Delete → RUNNING again | Speedup |
|------|-----|---------------------|------------------------|---------|
| Stock master | 74 | 54.2s | **400.0s** | — |
| Optimized | 73 | 37.8s | **93.5s** | **4.26×** (−76%) |

CSV: [`results/recovery_baseline_vs_optimized.csv`](results/recovery_baseline_vs_optimized.csv)

## Branch mapping

| Branch | What it contains | Expected vs stock |
|--------|------------------|-------------------|
| `f/launch-speedup-core` | Bootstrap path fix only | ~2–3× launch (dominates the win) |
| `f/launch-speedup-all` | Core + controller wakeup + fresh-cluster / gRPC guards | Full measured stack (~2.96× launch; recovery ~4×) |

Numbers above were measured with the full stack vs stock master. Re-run on each branch to reproduce; core alone should capture nearly all of the launch win.
