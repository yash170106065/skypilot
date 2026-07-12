#!/usr/bin/env bash
# Interleaved control vs optimized four-node managed-job benchmarks.
#
# Usage:
#   ./examples/multinode-bench/run_ab_benchmark.sh [pairs]
#
# Each pair runs one control trial (legacy SSH control path) and one optimized
# trial (auto gRPC + fresh-cluster guards) with identical harness metadata.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAIRS="${1:-7}"
RUN_ID="final_ab_$(date +%Y%m%d_%H%M%S)"
BASE_DIR="$SCRIPT_DIR/results/$RUN_ID"

mkdir -p "$BASE_DIR"

echo "A/B benchmark: $PAIRS interleaved pairs -> $BASE_DIR"
echo "Restart API server if you changed SkyPilot code since the last run:"
echo "  sky api stop && sky api start --deploy"
echo ""

for i in $(seq 1 "$PAIRS"); do
  echo "=== Pair $i / $PAIRS: control ==="
  RESULTS_DIR="$BASE_DIR/control_${i}" \
    NUM_NODES=4 \
    BENCHMARK_VARIANT=control \
    "$SCRIPT_DIR/benchmark.sh" 1

  echo "=== Pair $i / $PAIRS: optimized ==="
  RESULTS_DIR="$BASE_DIR/optimized_${i}" \
    NUM_NODES=4 \
    BENCHMARK_VARIANT=optimized \
    "$SCRIPT_DIR/benchmark.sh" 1

  sleep 5
done

python3 - "$BASE_DIR" <<'PY'
import csv
import statistics as stats
import sys
from pathlib import Path

base = Path(sys.argv[1])
rows = {'control': [], 'optimized': []}
for path in sorted(base.glob('*/summary.csv')):
    variant = path.parent.name.split('_', 1)[0]
    with open(path) as f:
        rows[variant].append(next(csv.DictReader(f)))

for variant in ('control', 'optimized'):
    data = rows[variant]
    print(f'\n{variant} (n={len(data)})')
    for col in [
            't_all_ranks_sec', 't_provision_to_driver_sec', 't_add_job_sec',
            't_queue_job_sec', 't_pending_sec'
    ]:
        vals = [float(d[col]) for d in data if d.get(col)]
        if vals:
            print(f'  {col}: median={stats.median(vals):.3f}s')

out = base / 'ab_summary.csv'
with open(out, 'w', newline='') as f:
    if rows['control']:
        writer = csv.DictWriter(f, fieldnames=rows['control'][0].keys())
        writer.writeheader()
        for variant in ('control', 'optimized'):
            writer.writerows(rows[variant])
print(f'\nWrote {out}')
PY

echo "Done: $BASE_DIR"
