#!/usr/bin/env bash
# Capture in-pod bootstrap timing from a running multinode job.
# Usage: ./trace_bootstrap.sh <cluster-name-prefix>
#
# Polls pods matching the prefix and prints setup log markers when found.

set -euo pipefail

PREFIX="${1:-multinode-bench}"
CTX="${KUBE_CONTEXT:-kind-skypilot}"

echo "Watching pods matching: $PREFIX (context: $CTX)"
for i in $(seq 1 120); do
  PODS=$(kubectl --context "$CTX" get pods -o name 2>/dev/null | grep "$PREFIX" || true)
  if [[ -n "$PODS" ]]; then
    echo "--- $(date +%H:%M:%S) ---"
    for pod in $PODS; do
      echo "== $pod =="
      kubectl --context "$CTX" exec "${pod#pod/}" -c ray-node -- bash -c '
        for f in /tmp/apt-ssh-setup.log /tmp/runtime-setup.log /tmp/env-setup.log; do
          if [ -f "$f" ]; then
            echo "  $f (last 3 lines):"
            tail -3 "$f" 2>/dev/null | sed "s/^/    /"
          fi
        done
        for m in apt_ssh_setup_complete ray_skypilot_installation_complete env_setup_complete; do
          [ -f /tmp/$m ] && echo "  marker: /tmp/$m exists"
        done
      ' 2>/dev/null || echo "  (pod not ready for exec yet)"
    done
    # Stop once we see rank output in any provision log isn't available here
  fi
  sleep 5
done
