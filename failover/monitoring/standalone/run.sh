#!/usr/bin/env bash
# Runs Prometheus, Alertmanager and blackbox_exporter with podman on a host
# outside the cluster. Re-run to pick up config changes.
#
#   ./run.sh          # start or restart
#   ./run.sh stop
#
# UIs: Prometheus :9090, Alertmanager :9093. Open them to your admin network
# only (firewall-cmd --add-port=9090/tcp --add-port=9093/tcp for the lab).
set -euo pipefail
cd "$(dirname "$0")"
MON=$(cd .. && pwd)

PROMETHEUS_IMAGE=${PROMETHEUS_IMAGE:-quay.io/prometheus/prometheus:v3.5.0}
ALERTMANAGER_IMAGE=${ALERTMANAGER_IMAGE:-quay.io/prometheus/alertmanager:v0.28.1}
BLACKBOX_IMAGE=${BLACKBOX_IMAGE:-quay.io/prometheus/blackbox-exporter:v0.27.0}

for c in lb-prometheus lb-alertmanager lb-blackbox; do
  podman rm -f "$c" >/dev/null 2>&1 || true
done
[[ ${1:-} == stop ]] && exit 0

podman volume exists lb-prometheus-data || podman volume create lb-prometheus-data >/dev/null

# Host networking so the containers reach the LBs and the VIP exactly as the
# host does, and Prometheus finds Alertmanager and blackbox on 127.0.0.1.
podman run -d --name lb-blackbox --network host --restart always \
  -v "$PWD/blackbox.yml:/etc/blackbox_exporter/config.yml:ro,Z" \
  "$BLACKBOX_IMAGE"

podman run -d --name lb-alertmanager --network host --restart always \
  -v "$PWD/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro,Z" \
  "$ALERTMANAGER_IMAGE"

podman run -d --name lb-prometheus --network host --restart always \
  -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml:ro,Z" \
  -v "$MON/rules:/etc/prometheus/rules:ro,z" \
  -v lb-prometheus-data:/prometheus:Z \
  "$PROMETHEUS_IMAGE" \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=15d

sleep 3
podman ps --filter name=lb- --format '{{.Names}}\t{{.Status}}'
echo "Prometheus targets: http://$(hostname -f):9090/targets"
