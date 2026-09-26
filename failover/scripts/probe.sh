#!/usr/bin/env bash
# Continuously probe the cluster endpoints through the VIP and print CSV:
#   epoch_seconds,target,ok,http_code,latency_seconds
#
# Every request is pinned to the VIP with --resolve, so the probe measures the
# load balancer path even if DNS points somewhere else.
#
#   ./probe.sh > probe.csv        # Ctrl-C to stop
#   ./probe-summary.sh probe.csv

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
set +o errexit

# target|url|expected   (expected: regex for the HTTP code, or "any" = any
# HTTP response, which still proves the path through HAProxy to the router)
TARGETS=(
  "api|https://${API_HOST}:6443/readyz|^200$"
  "mcs|https://${API_INT_HOST}:22623/healthz|^20[04]$"
  "ingress-https|https://${CANARY_HOST}/|^200$"
  "ingress-http|http://${CANARY_HOST}/|any"
)

probe_one() {
  local name=$1 url=$2 expected=$3 host port out code latency ok
  host=${url#*://}; host=${host%%/*}
  port=${host##*:}
  [[ $port == "$host" ]] && { [[ $url == https* ]] && port=443 || port=80; }
  host=${host%%:*}
  out=$(curl -sk -o /dev/null --max-time "$PROBE_TIMEOUT" \
    --resolve "${host}:${port}:${VIP}" \
    -w '%{http_code} %{time_total}' "$url" 2>/dev/null)
  code=${out%% *}; latency=${out##* }
  if [[ $expected == any ]]; then
    [[ $code != 000 ]] && ok=1 || ok=0
  else
    [[ $code =~ $expected ]] && ok=1 || ok=0
  fi
  printf '%s,%s,%s,%s,%s\n' "$(date +%s.%N)" "$name" "$ok" "$code" "$latency"
}

echo "epoch,target,ok,code,latency"
trap 'exit 0' INT TERM
while :; do
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r name url expected <<<"$t"
    probe_one "$name" "$url" "$expected" &
  done
  sleep "$PROBE_INTERVAL"
done
