#!/usr/bin/env bash
# Run 2 → 4 → 8 node trials sequentially with full metrics.
#
# Usage:
#   ./examples/multinode-bench/run_scale_benchmark.sh [trials_per_n]
#   TRIALS=2 ./examples/multinode-bench/run_scale_benchmark.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIALS="${1:-${TRIALS:-3}}"
SCALE_DIR="$SCRIPT_DIR/results/scale_$(date +%Y%m%d_%H%M%S)"
AGG="$SCALE_DIR/aggregate.csv"

mkdir -p "$SCALE_DIR"

echo "Scale benchmark: $TRIALS trials each for N=2,4,8"
echo "Output: $SCALE_DIR"
echo ""

for N in 2 4 8; do
  echo "########################################"
  echo "# NUM_NODES=$N ($TRIALS trials)"
  echo "########################################"
  RESULTS_DIR="$SCALE_DIR/n${N}" \
    NUM_NODES="$N" \
    "$SCRIPT_DIR/benchmark.sh" "$TRIALS"
  cp "$SCALE_DIR/n${N}/summary.csv" "$SCALE_DIR/n${N}_summary.csv"
  echo ""
  sleep 5
done

# Aggregate all runs
python3 - "$SCALE_DIR" "$AGG" <<'PY'
import csv, pathlib, sys
scale_dir = pathlib.Path(sys.argv[1])
agg = pathlib.Path(sys.argv[2])
rows = []
header = None
for n in (2, 4, 8):
    p = scale_dir / f'n{n}' / 'summary.csv'
    if not p.exists():
        continue
    with open(p) as f:
        r = csv.DictReader(f)
        if header is None:
            header = r.fieldnames
        rows.extend(list(r))
if header and rows:
    with open(agg, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=header)
        w.writeheader()
        w.writerows(rows)
    print('Aggregate:', agg)
    # Quick median by num_nodes
    from statistics import median
    for n in (2, 4, 8):
        totals = [float(r['t_total_sec']) for r in rows
                  if r.get('num_nodes') == str(n) and r.get('t_total_sec')]
        if totals:
            print(f'  N={n}: median T_total={median(totals):.1f}s  trials={len(totals)}')
PY

echo ""
echo "All done. See $AGG"
