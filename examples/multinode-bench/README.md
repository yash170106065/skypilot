# Multi-node managed-job launch benchmark

Reproduce the take-home launch numbers from a clean machine.

**Branches**

| Branch | Contents |
|--------|----------|
| `f/launch-speedup-core` | Bootstrap path fix (~2–3× launch) |
| `f/launch-speedup-all` | Core + controller wakeup + launch-path guards |

**Results table:** [RESULTS.md](RESULTS.md)

## Prerequisites

- macOS or Linux with Docker
- Python 3.11, [`uv`](https://github.com/astral-sh/uv)
- `kubectl`, `kind` (or an existing Kubernetes context)
- ~8+ CPU / 16+ GB RAM recommended for 4-node kind

## 1. Clone and install

```bash
git clone <your-private-fork-url> skypilot
cd skypilot
git checkout f/launch-speedup-core   # or f/launch-speedup-all

uv venv --seed --python 3.11
source .venv/bin/activate
uv pip install -e ".[kubernetes]"
uv pip install -r requirements-dev.txt   # optional

export SKYPILOT_DEV=1
export SKYPILOT_DISABLE_USAGE_COLLECTION=1
export PIP_INDEX_URL=https://pypi.org/simple/
```

## 2. Kubernetes (kind)

```bash
# Create kind cluster if needed
sky local up
kubectl config use-context kind-skypilot

# ~/.sky/config.yaml — allow the context:
# kubernetes:
#   allowed_contexts:
#     - kind-skypilot

sky check k8s
```

## 3. Start API server (consolidation / managed jobs)

```bash
sky api stop || true
sky api start --deploy
sky api status
```

Restart the API server after every branch checkout so the controller loads that code.

## 4. Run the launch benchmark (4 nodes, 3 trials)

```bash
NUM_NODES=4 BENCHMARK_VARIANT=optimized \
  ./examples/multinode-bench/benchmark.sh 3
```

Primary metric in `summary.csv`: **`t_all_ranks_sec`**
(launch → slowest rank’s `[rank N] started at …` line).

Stock baseline (same machine, same image):

```bash
git checkout master   # or upstream/master
sky api stop && sky api start --deploy
NUM_NODES=4 BENCHMARK_VARIANT=control \
  ./examples/multinode-bench/benchmark.sh 3
```

## 5. Recovery bonus (optional)

```bash
NUM_NODES=4 VARIANT=optimized \
  ./examples/multinode-bench/run_recovery_bonus.sh
```

Deletes one worker pod mid-run and records delete → RUNNING-again.

## 6. Compare to checked-in numbers

| Metric | Stock median | Optimized median | File |
|--------|--------------|------------------|------|
| Launch `t_all_ranks_sec` | 137.7s | 46.5s | [RESULTS.md](RESULTS.md) |
| Recovery delete→RUNNING | 400.0s | 93.5s | [RESULTS.md](RESULTS.md) |

Side-by-side CSVs under `results/`.

## Files

| File | Purpose |
|------|---------|
| `job.yaml` | Multi-node echo workload |
| `job-recovery.yaml` | Long-running job for delete-pod recovery |
| `benchmark.sh` | Launch timing trials → `summary.csv` |
| `run_recovery_bonus.sh` | Recovery timing harness |
| `RESULTS.md` | Headline tables from our runs |

## Notes

- Do **not** use CLI return time as the primary metric; ~23–26s of post-rank cleanup inflates it.
- Keep the same container image digest across A/B runs (`image_id` in `summary.csv`).
- `miniconda_downloaded=yes` on stock vs `no` on optimized is the main bootstrap signal.
