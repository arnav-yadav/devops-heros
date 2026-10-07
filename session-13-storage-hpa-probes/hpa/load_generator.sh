#!/usr/bin/env bash
# ==============================================================================
# Script: load_generator.sh
# Purpose: Drive enough traffic at yatri-backend-service to trigger HPA scaling.
#
# Load is generated from pods INSIDE the cluster. An earlier version drove
# traffic through `kubectl port-forward` from the laptop; that proxies every
# request through the API server, which caps throughput so low that CPU never
# reaches the 50% target and the HPA never scales. In-cluster pods talk to the
# ClusterIP directly and saturate the backend within about a minute.
#
# Usage:
#   bash load_generator.sh [workers]      # default 3
#   bash load_generator.sh 6              # heavier load
# Stop with Ctrl-C (load pods are cleaned up automatically).
# ==============================================================================

set -euo pipefail

WORKERS="${1:-3}"
SERVICE="${SERVICE:-yatri-backend-service}"
PATH_SUFFIX="${PATH_SUFFIX:-/healthz}"
TARGET="http://${SERVICE}${PATH_SUFFIX}"

cleanup() {
  echo ""
  echo "Removing load generator pods..."
  for i in $(seq 1 "$WORKERS"); do
    kubectl delete pod "loadgen-$i" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  echo "Done. Replicas will scale back down after the 5 minute stabilisation window."
}
trap cleanup EXIT INT TERM

echo "=================================================="
echo "      KUBERNETES HPA TRAFFIC LOAD GENERATOR       "
echo "=================================================="
echo "Target        : $TARGET (from inside the cluster)"
echo "Worker pods   : $WORKERS"
echo ""

if ! kubectl get svc "$SERVICE" >/dev/null 2>&1; then
  echo "ERROR: Service '$SERVICE' not found. Apply backend-deployment.yaml and backend-service.yaml first."
  exit 1
fi

for i in $(seq 1 "$WORKERS"); do
  kubectl delete pod "loadgen-$i" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl run "loadgen-$i" --image=busybox:1.36 --restart=Never -- \
    /bin/sh -c "while true; do wget -q -O- $TARGET >/dev/null 2>&1; done" >/dev/null
  echo "  started loadgen-$i"
done

echo ""
echo "Traffic load active. In another terminal, watch it scale:"
echo "    kubectl get hpa -w"
echo "    kubectl get pods -l app=yatri-backend -w"
echo "    kubectl top pods -l app=yatri-backend"
echo ""
echo "Press Ctrl-C to stop generating load."

while true; do
  sleep 10
  kubectl get hpa yatri-backend-hpa --no-headers 2>/dev/null \
    | awk '{printf "  %s  cpu=%-12s replicas=%s\n", strftime("%H:%M:%S"), $4, $7}'
done
