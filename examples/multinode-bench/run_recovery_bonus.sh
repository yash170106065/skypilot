#!/usr/bin/env bash
# Timed recovery: launch long-running N-node job, delete one worker, measure.
# Does NOT block on sky jobs logs (that hangs while run: is sleeping).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB_YAML="${JOB_YAML:-$SCRIPT_DIR/job-recovery.yaml}"
NUM_NODES="${NUM_NODES:-4}"
VARIANT="${VARIANT:-baseline}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results/recovery_${VARIANT}_$(date +%Y%m%d_%H%M%S)}"
NAMESPACE="${NAMESPACE:-default}"
TIMEOUT_RUNNING_SEC="${TIMEOUT_RUNNING_SEC:-900}"
TIMEOUT_RECOVERY_SEC="${TIMEOUT_RECOVERY_SEC:-900}"

mkdir -p "$RESULTS_DIR"
export SKYPILOT_DEV=1 SKYPILOT_DISABLE_USAGE_COLLECTION=1
export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.org/simple/}"
unset SKYPILOT_DEBUG

kubectl config use-context kind-skypilot >/dev/null 2>&1 || true

JOB_NAME="recovery-${VARIANT}-$(date +%H%M%S)"
sed "s/^num_nodes:.*/num_nodes: ${NUM_NODES}/" "$JOB_YAML" >"$RESULTS_DIR/job.yaml"
{
  echo "variant=$VARIANT"
  echo "num_nodes=$NUM_NODES"
  echo "git_sha=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "started_at=$(date -Iseconds)"
} >"$RESULTS_DIR/metadata.env"

echo "Results: $RESULTS_DIR | variant=$VARIANT | nodes=$NUM_NODES"
date +%s.%N >"$RESULTS_DIR/t_launch.epoch"

sky jobs launch -y --async -n "$JOB_NAME" --num-nodes "$NUM_NODES" \
  "$RESULTS_DIR/job.yaml" >"$RESULTS_DIR/launch.log" 2>&1

sleep 4
JOB_ID=$(sky jobs queue -a 2>/dev/null | awk -v n="$JOB_NAME" '$0 ~ n {print $1; exit}')
echo "JOB_ID=$JOB_ID" | tee "$RESULTS_DIR/job_id.txt"
[[ -n "$JOB_ID" ]] || { echo "Failed to resolve job id"; exit 1; }

job_status() {
  python3 - "$JOB_ID" <<'PY'
import subprocess, sys
jid = sys.argv[1]
out = subprocess.check_output(["sky", "jobs", "queue", "-a"], text=True, stderr=subprocess.STDOUT)
for line in out.splitlines():
    parts = line.split()
    if parts and parts[0] == jid:
        for i, tok in enumerate(parts):
            if tok in {"PENDING","SUBMITTED","STARTING","RUNNING","RECOVERING","SUCCEEDED","FAILED","CANCELLED","CANCELLING"}:
                rec = parts[i-1] if i and parts[i-1].isdigit() else ""
                print(f"{tok} {rec}")
                raise SystemExit
print("UNKNOWN")
PY
}

echo "Waiting for RUNNING..."
deadline=$(($(date +%s) + TIMEOUT_RUNNING_SEC))
status=""
while (( $(date +%s) < deadline )); do
  read -r status rec <<<"$(job_status)"
  echo "$(date -Iseconds) status=$status recoveries=${rec:-}" | tee -a "$RESULTS_DIR/status_timeline.txt"
  case "$status" in
    RUNNING) break ;;
    FAILED|CANCELLED) echo "Terminal before RUNNING"; exit 1 ;;
  esac
  sleep 5
done
[[ "$status" == "RUNNING" ]] || { echo "Timeout waiting for RUNNING"; exit 1; }
date +%s.%N >"$RESULTS_DIR/t_running.epoch"

# Brief settle; do NOT follow logs
sleep 10
kubectl get pods -n "$NAMESPACE" -o wide | tee "$RESULTS_DIR/pods_before.txt"
WORKER_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers \
  | awk -v n="$JOB_NAME" 'index($1,n) && $1 ~ /worker/ {print $1; exit}')
[[ -n "$WORKER_POD" ]] || { echo "No worker pod found"; exit 1; }

echo "Deleting worker $WORKER_POD"
echo "$WORKER_POD" >"$RESULTS_DIR/deleted_pod.txt"
date +%s.%N >"$RESULTS_DIR/t_delete.epoch"
kubectl delete pod -n "$NAMESPACE" "$WORKER_POD" --wait=false | tee "$RESULTS_DIR/delete.log"

echo "Watching recovery..."
saw_rec=0
deadline=$(($(date +%s) + TIMEOUT_RECOVERY_SEC))
while (( $(date +%s) < deadline )); do
  read -r status rec <<<"$(job_status)"
  echo "$(date -Iseconds) status=$status recoveries=${rec:-}" | tee -a "$RESULTS_DIR/status_timeline.txt"
  if [[ "$status" == "RECOVERING" && "$saw_rec" -eq 0 ]]; then
    saw_rec=1
    date +%s.%N >"$RESULTS_DIR/t_recovering.epoch"
  fi
  if [[ "$status" == "RUNNING" && "$saw_rec" -eq 1 ]]; then
    date +%s.%N >"$RESULTS_DIR/t_running_again.epoch"
    echo "Back to RUNNING (recoveries=${rec:-})"
    sky jobs cancel -y "$JOB_ID" >"$RESULTS_DIR/cancel.log" 2>&1 || true
  fi
  if [[ "$status" == "SUCCEEDED" || "$status" == "FAILED" || "$status" == "CANCELLED" ]]; then
    date +%s.%N >"$RESULTS_DIR/t_done.epoch"
    echo "$status" >"$RESULTS_DIR/final_status.txt"
    break
  fi
  sleep 5
done

python3 - <<PY
from pathlib import Path
root = Path("$RESULTS_DIR")
def ep(n):
    p = root/n
    return float(p.read_text().strip()) if p.exists() else None
def d(a,b):
    return f"{b-a:.1f}" if a is not None and b is not None else ""
t_launch, t_run = ep("t_launch.epoch"), ep("t_running.epoch")
t_del, t_rec = ep("t_delete.epoch"), ep("t_recovering.epoch")
t_again, t_done = ep("t_running_again.epoch"), ep("t_done.epoch")
final = (root/"final_status.txt").read_text().strip() if (root/"final_status.txt").exists() else ""
rows = [
    ("variant", "$VARIANT"),
    ("job_id", "$JOB_ID"),
    ("t_launch_to_running_sec", d(t_launch, t_run)),
    ("t_delete_to_recovering_sec", d(t_del, t_rec)),
    ("t_recovering_to_running_again_sec", d(t_rec, t_again)),
    ("t_delete_to_running_again_sec", d(t_del, t_again)),
    ("t_delete_to_terminal_sec", d(t_del, t_done)),
    ("saw_recovering", "1" if t_rec else "0"),
    ("final_status", final),
    ("deleted_pod", (root/"deleted_pod.txt").read_text().strip() if (root/"deleted_pod.txt").exists() else ""),
]
(root/"summary.csv").write_text("metric,value\n" + "\n".join(f"{k},{v}" for k,v in rows) + "\n")
print((root/"summary.csv").read_text())
PY

kubectl get pods -n "$NAMESPACE" | tee "$RESULTS_DIR/pods_after.txt" || true
echo "Done: $RESULTS_DIR"
