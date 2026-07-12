#!/usr/bin/env bash
# Benchmark: sky jobs launch → all ranks print run: output
#
# Usage:
#   ./examples/multinode-bench/benchmark.sh [trials]
#   NUM_NODES=4 ./examples/multinode-bench/benchmark.sh 3
#   ./examples/multinode-bench/run_scale_benchmark.sh   # 2, 4, 8 nodes sequentially
#
# Metrics: wall clock, rank spread, network probes (PyPI/Anaconda), provision
# stage timings, Miniconda re-download detection, cluster launch time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JOB_YAML="${JOB_YAML:-$SCRIPT_DIR/job.yaml}"
NUM_TRIALS="${1:-3}"
NUM_NODES="${NUM_NODES:-2}"
BENCHMARK_VARIANT="${BENCHMARK_VARIANT:-control}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results/run_$(date +%Y%m%d_%H%M%S)}"
CSV="$RESULTS_DIR/summary.csv"
NETWORK_LOG="$RESULTS_DIR/network_baseline.txt"

mkdir -p "$RESULTS_DIR"

kubectl config use-context kind-skypilot >/dev/null 2>&1 || true

export SKYPILOT_DEV=1
export SKYPILOT_DISABLE_USAGE_COLLECTION=1
export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.org/simple/}"
unset SKYPILOT_DEBUG

# Control forces legacy SSH for Skylet control RPCs; optimized uses the
# managed-Kubernetes auto-gRPC path plus fresh-cluster launch guards.
case "$BENCHMARK_VARIANT" in
  control)
    export SKYPILOT_ENABLE_GRPC=0
    ;;
  optimized)
    unset SKYPILOT_ENABLE_GRPC
    ;;
  *)
    echo "Unknown BENCHMARK_VARIANT=$BENCHMARK_VARIANT (expected control or optimized)" >&2
    exit 1
    ;;
esac

echo "Results dir: $RESULTS_DIR"
echo "Trials: $NUM_TRIALS | num_nodes: $NUM_NODES | variant: $BENCHMARK_VARIANT"
echo ""

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
GIT_DIRTY=$(git -C "$REPO_ROOT" status --porcelain | grep -q . && echo yes || echo no)
BENCHMARK_SHA=$(shasum -a 256 "$0" | awk '{print $1}')
{
  echo "git_sha=$GIT_SHA"
  echo "git_dirty=$GIT_DIRTY"
  echo "benchmark_sha=$BENCHMARK_SHA"
  echo "variant=$BENCHMARK_VARIANT"
  echo "num_nodes=$NUM_NODES"
  echo "started_at=$(date -Iseconds)"
} > "$RESULTS_DIR/metadata.env"

# One-time network baseline for this run (helps interpret trial variance).
probe_url() {
  local url="$1"
  local label="$2"
  local t
  t=$(curl -sf -o /dev/null -w '%{time_total}' --connect-timeout 5 --max-time 15 "$url" 2>/dev/null) || t="fail"
  echo "$label,$t"
}

{
  echo "# Network probe at run start: $(date -Iseconds)"
  probe_url "https://pypi.org/simple/" "pypi_simple"
  probe_url "https://repo.anaconda.com/miniconda/" "anaconda_repo"
  probe_url "https://us-docker.pkg.dev/v2/" "gcp_artifact_registry"
} | tee "$NETWORK_LOG"
echo ""

TMP_JOB="$RESULTS_DIR/job.yaml"
python3 - "$JOB_YAML" "$TMP_JOB" "$NUM_NODES" <<'PY'
import sys, yaml
src, dst, num_nodes = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src) as f:
    doc = yaml.safe_load(f)
doc['num_nodes'] = num_nodes
with open(dst, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False)
PY

CSV_HEADER="trial,variant,num_nodes,job_id,job_name,git_sha,git_dirty,benchmark_sha,image,image_id,t_cli_return_sec,t_first_rank_sec,t_all_ranks_sec,t_post_rank_sec,t_rank_spread_sec,t_pending_sec,t_starting_to_rank_sec,t_provision_to_driver_sec,t_autodown_sec,t_add_job_sec,t_queue_job_sec,t_ray_init_sec,t_placement_group_sec,t_rank_discovery_sec,t_driver_to_first_rank_sec,ranks_found,ranks_missing,pypi_sec,anaconda_sec,t_runtime_bootstrap_sec,t_wheel_sec,t_cluster_launch_sec,miniconda_downloaded,apt_skipped,pods_pending_max,status"
echo "$CSV_HEADER" > "$CSV"

now_epoch() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

probe_trial_network() {
  local out="$1"
  {
    probe_url "https://pypi.org/simple/" "pypi"
    probe_url "https://repo.anaconda.com/miniconda/" "anaconda"
  } > "$out"
}

for trial in $(seq 1 "$NUM_TRIALS"); do
  TRIAL_DIR="$RESULTS_DIR/trial_${trial}"
  mkdir -p "$TRIAL_DIR"
  JOB_NAME="multinode-bench-n${NUM_NODES}-t${trial}-$(date +%H%M%S)"

  echo "=== Trial $trial / $NUM_TRIALS (num_nodes=$NUM_NODES): $JOB_NAME ==="

  probe_trial_network "$TRIAL_DIR/network_probe.txt"

  T_LAUNCH=$(now_epoch)
  echo "$T_LAUNCH" > "$TRIAL_DIR/t_launch.epoch"

  python3 - "$TRIAL_DIR/pod_snapshots.jsonl" <<'PY' &
import json
import subprocess
import sys
import time

with open(sys.argv[1], 'a', buffering=1) as output:
    while True:
        result = subprocess.run(
            ['kubectl', 'get', 'pods', '-A', '-o', 'json'],
            capture_output=True,
            text=True,
            check=False)
        if result.returncode == 0:
            try:
                payload = json.loads(result.stdout)
                items = []
                for pod in payload.get('items', []):
                    statuses = {
                        status.get('name'): status.get('imageID', '')
                        for status in pod.get('status',
                                              {}).get('containerStatuses', [])
                    }
                    containers = pod.get('spec', {}).get('containers', [])
                    items.append({
                        'name': pod['metadata']['name'],
                        'phase': pod.get('status', {}).get('phase', ''),
                        'containers': [{
                            'name': container.get('name', ''),
                            'image': container.get('image', ''),
                            'image_id': statuses.get(container.get('name'), ''),
                        } for container in containers],
                    })
                output.write(
                    json.dumps({
                        'epoch': time.time(),
                        'items': items,
                    },
                               separators=(',', ':')) + '\n')
            except (KeyError, TypeError, ValueError):
                pass
        time.sleep(0.25)
PY
  POD_WATCHER_PID=$!

  set +e
  sky jobs launch -y -n "$JOB_NAME" "$TMP_JOB" 2>&1 | tee "$TRIAL_DIR/launch.log"
  LAUNCH_RC=${PIPESTATUS[0]}
  set -e

  T_DONE=$(now_epoch)
  echo "$T_DONE" > "$TRIAL_DIR/t_done.epoch"
  kill "$POD_WATCHER_PID" 2>/dev/null || true
  wait "$POD_WATCHER_PID" 2>/dev/null || true

  if [[ "$LAUNCH_RC" -ne 0 ]]; then
    echo "$trial,$NUM_NODES,LAUNCH_FAILED,$JOB_NAME,,,,,,,,,,,,FAILED" >> "$CSV"
    echo "  Launch failed (rc=$LAUNCH_RC)"
    continue
  fi

  JOB_ID=$(grep -oE 'Managed Job ID: [0-9]+' "$TRIAL_DIR/launch.log" | tail -1 | awk '{print $4}')
  [[ -z "$JOB_ID" ]] && JOB_ID=$(grep -oE 'Job ID: [0-9]+' "$TRIAL_DIR/launch.log" | tail -1 | awk '{print $3}')

  sky jobs logs "$JOB_ID" 2>&1 | tee "$TRIAL_DIR/job.log" || true
  sky jobs logs --controller "$JOB_ID" 2>&1 | tee "$TRIAL_DIR/controller.log" || true
  cp "$HOME/.sky/api_server/server.log" "$TRIAL_DIR/api_server.log" 2>/dev/null || true
  cp "$HOME/sky_logs/managed_jobs/submit-job-${JOB_ID}.log" \
    "$TRIAL_DIR/submit.log" 2>/dev/null || true
  CONTROLLER_UUID=$(grep -oE 'From controller [^ ]+' \
    "$TRIAL_DIR/controller.log" | tail -1 | awk '{print $3}' || true)
  if [[ -n "$CONTROLLER_UUID" ]]; then
    cp "$HOME/sky_logs/jobs_controller/controller_${CONTROLLER_UUID}.log" \
      "$TRIAL_DIR/controller_manager.log" 2>/dev/null || true
  fi

  # Cluster name for provision logs (e.g. multinode-bench-n4-t1-140646-23)
  CLUSTER_NAME=$(grep -oE 'Cluster launched: [^.]+' "$TRIAL_DIR/launch.log" 2>/dev/null | tail -1 | awk '{print $3}' || true)
  [[ -z "$CLUSTER_NAME" ]] && CLUSTER_NAME=$(grep -oE 'Running on cluster: [^ ]+' "$TRIAL_DIR/controller.log" 2>/dev/null | tail -1 | awk '{print $4}' || true)
  [[ -z "$CLUSTER_NAME" ]] && CLUSTER_NAME=$(grep -oE 'Cluster launched: [^.]+' "$TRIAL_DIR/controller.log" 2>/dev/null | tail -1 | awk '{print $3}' || true)

  if [[ -n "$CLUSTER_NAME" ]]; then
    sky logs --provision "$CLUSTER_NAME" 2>&1 | tee "$TRIAL_DIR/provision.log" || true
    # Managed jobs may tear down the cluster before `sky logs --provision`
    # runs. In local consolidation mode, recover the retained server-side log.
    if ! grep -q "Start: internal_file_mounts" "$TRIAL_DIR/provision.log"; then
      PROVISION_LOG=$(python3 - "$CLUSTER_NAME" "$T_LAUNCH" <<'PY'
import glob
import os
import sys

cluster, launched_at = sys.argv[1], float(sys.argv[2])
matches = []
for path in glob.glob(os.path.expanduser('~/sky_logs/sky-*/provision.log')):
    try:
        if os.path.getmtime(path) < launched_at:
            continue
        with open(path, errors='replace') as f:
            if cluster in f.read():
                matches.append(path)
    except OSError:
        pass
print(max(matches, key=os.path.getmtime) if matches else '')
PY
)
      [[ -n "$PROVISION_LOG" ]] && cp "$PROVISION_LOG" "$TRIAL_DIR/provision.log"
    fi
  else
    : > "$TRIAL_DIR/provision.log"
  fi

  python3 - "$TRIAL_DIR" "$NUM_NODES" "$T_LAUNCH" "$T_DONE" "$trial" "$JOB_ID" "$JOB_NAME" "$CSV" "$BENCHMARK_VARIANT" "$GIT_SHA" "$GIT_DIRTY" "$BENCHMARK_SHA" <<'PY'
import json
import pathlib
import re
import sys

trial_dir = pathlib.Path(sys.argv[1])
num_nodes = int(sys.argv[2])
t_launch, t_done = float(sys.argv[3]), float(sys.argv[4])
trial, job_id, job_name, csv_path = sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
variant, git_sha, git_dirty, benchmark_sha = sys.argv[9:13]

def read(path):
    p = trial_dir / path
    return p.read_text(errors='replace') if p.exists() else ''

launch = read('launch.log')
job_log = read('job.log')
controller = read('controller.log')
provision = read('provision.log')
api_server = read('api_server.log')
submit = read('submit.log')
controller_manager = read('controller_manager.log')
combined = '\n'.join([
    launch, job_log, controller, provision, api_server, submit,
    controller_manager
])

# Logs can repeat when output is collected through multiple commands. Retain
# one epoch per structured phase and write the raw timeline for inspection.
phase_pattern = re.compile(
    r'SKYPILOT_LAUNCH_PHASE name=([a-z_]+).*?epoch=([0-9.]+)')
phases = {}
for name, epoch in phase_pattern.findall(combined):
    epoch = float(epoch)
    if t_launch <= epoch <= t_done:
        phases.setdefault(name, epoch)
with open(trial_dir / 'phase_timestamps.csv', 'w') as f:
    f.write('phase,epoch\n')
    for name, epoch in sorted(phases.items(), key=lambda item: item[1]):
        f.write(f'{name},{epoch:.6f}\n')

def phase_delta(start, end):
    if start not in phases or end not in phases:
        return ''
    return phases[end] - phases[start]

# Rank timestamps
pattern = re.compile(r'\[rank (\d+)\] started at ([0-9.]+)')
ranks = {}
for m in pattern.finditer(combined):
    ranks[int(m.group(1))] = float(m.group(2))

with open(trial_dir / 'rank_timestamps.txt', 'w') as f:
    for r in sorted(ranks):
        f.write(f'{r} {ranks[r]}\n')

expected = set(range(num_nodes))
found = set(ranks.keys())
missing = sorted(expected - found)
r0 = ranks.get(0)
rN = ranks.get(num_nodes - 1)
t_cli_return = t_done - t_launch
if ranks:
    t_first_rank = min(ranks.values()) - t_launch
    t_all_ranks = max(ranks.values()) - t_launch
    t_post_rank = t_done - max(ranks.values())
    t_rank_spread = max(ranks.values()) - min(ranks.values())
else:
    t_first_rank = t_all_ranks = t_post_rank = t_rank_spread = ''

status = 'SUCCEEDED' if 'SUCCEEDED' in combined and len(missing) == 0 else (
    'FAILED' if 'FAILED' in combined or len(missing) > 0 else 'UNKNOWN')

# Network probes (per-trial)
pypi_sec = anaconda_sec = ''
net = read('network_probe.txt')
for line in net.splitlines():
    if line.startswith('pypi,'):
        pypi_sec = line.split(',', 1)[1]
    elif line.startswith('anaconda,'):
        anaconda_sec = line.split(',', 1)[1]

# Provision stage timings
def extract_secs(pattern, text):
    m = re.search(pattern, text)
    return m.group(1) if m else ''

t_runtime = extract_secs(
    r'Ray and skypilot dependencies installation completed in (\d+) secs', provision)
t_wheel = extract_secs(
    r'Skypilot wheel installation completed in (\d+) secs', provision)
t_cluster = extract_secs(
    r'Cluster launch completed in ([0-9.]+)s', controller)
if not t_cluster:
    t_cluster = extract_secs(
        r'Cluster launch completed in ([0-9.]+)s', launch)

miniconda_dl = 'yes' if re.search(
    r'^\+ curl .*Miniconda3', provision, re.I | re.M) else 'no'
apt_skipped = 'yes' if re.search(
    r'^All required packages already installed', provision, re.M) else 'no'

# Pod watcher data captures transient scheduling and immutable runtime identity.
pods_pending_max = 0
image = image_id = ''
for line in read('pod_snapshots.jsonl').splitlines():
    try:
        snapshot = json.loads(line)
    except ValueError:
        continue
    benchmark_pods = [
        pod for pod in snapshot.get('items', [])
        if pod.get('name', '').startswith('multinode-bench')
    ]
    pods_pending_max = max(
        pods_pending_max,
        sum(pod.get('phase') == 'Pending' for pod in benchmark_pods))
    for pod in benchmark_pods:
        for container in pod.get('containers', []):
            if container.get('name') == 'ray-node':
                image = container.get('image', image)
                image_id = container.get('image_id', image_id)

t_pending = phase_delta('queue_committed', 'starting_committed')
t_starting_to_rank = (
    min(ranks.values()) - phases['starting_committed']
    if ranks and 'starting_committed' in phases else '')
if 'provision_return' in phases:
    if 'driver_entry' in phases:
        t_provision_to_driver = phases['driver_entry'] - phases['provision_return']
    elif 'user_tasks_submitted' in phases:
        # Remote driver_entry lives on the worker cluster and may be torn down
        # before logs are collected; user task submission is a stable proxy.
        t_provision_to_driver = (
            phases['user_tasks_submitted'] - phases['provision_return'])
    else:
        t_provision_to_driver = ''
else:
    t_provision_to_driver = ''
t_autodown = phase_delta('autodown_start', 'autodown_end')
t_add_job = phase_delta('add_job_start', 'add_job_end')
t_queue_job = phase_delta('queue_job_start', 'queue_job_end')
t_ray_init = phase_delta('ray_init_start', 'ray_init_end')
t_placement_group = phase_delta('ray_init_end', 'placement_group_ready')
t_rank_discovery = phase_delta('rank_discovery_start', 'rank_discovery_end')
t_driver_to_first_rank = (
    min(ranks.values()) - phases['driver_entry']
    if ranks and 'driver_entry' in phases else '')

def metric(value):
    return f'{value:.3f}' if value != '' else ''

with open(csv_path, 'a') as f:
    f.write(','.join([
        str(trial), variant, str(num_nodes), str(job_id), job_name,
        git_sha, git_dirty, benchmark_sha, image, image_id,
        f'{t_cli_return:.1f}',
        f'{t_first_rank:.1f}' if t_first_rank != '' else '',
        f'{t_all_ranks:.1f}' if t_all_ranks != '' else '',
        f'{t_post_rank:.1f}' if t_post_rank != '' else '',
        f'{t_rank_spread}' if t_rank_spread != '' else '',
        metric(t_pending), metric(t_starting_to_rank),
        metric(t_provision_to_driver), metric(t_autodown),
        metric(t_add_job), metric(t_queue_job), metric(t_ray_init),
        metric(t_placement_group), metric(t_rank_discovery),
        metric(t_driver_to_first_rank),
        str(len(found)),
        ';'.join(map(str, missing)) if missing else '',
        pypi_sec, anaconda_sec,
        t_runtime, t_wheel, t_cluster,
        miniconda_dl, apt_skipped,
        str(pods_pending_max),
        status,
    ]) + '\n')

all_ranks_display = f'{t_all_ranks:.1f}s' if t_all_ranks != '' else 'n/a'
post_rank_display = f'{t_post_rank:.1f}s' if t_post_rank != '' else 'n/a'
print(f'  status={status} all_ranks={all_ranks_display} '
      f'cli_return={t_cli_return:.1f}s post_rank={post_rank_display} '
      f'ranks={sorted(found)} missing={missing}')
print(f'  network: pypi={pypi_sec}s anaconda={anaconda_sec}s | bootstrap={t_runtime}s wheel={t_wheel}s cluster={t_cluster}s')
print(f'  internet_flags: miniconda_dl={miniconda_dl} apt_skipped={apt_skipped}')
print(f'  phases: pending={metric(t_pending)}s '
      f'provision_to_driver={metric(t_provision_to_driver)}s '
      f'add_job={metric(t_add_job)}s queue_job={metric(t_queue_job)}s '
      f'driver_to_rank={metric(t_driver_to_first_rank)}s')
PY

  echo ""
  sleep 3
done

echo ""
echo "Done. Summary: $CSV"
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
