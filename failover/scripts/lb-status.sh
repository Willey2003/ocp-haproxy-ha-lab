#!/usr/bin/env bash
# One-shot view of the load balancer pair: who holds the VIP, service state,
# keepalived role, and HAProxy's view of every backend server.
#
#   ./lb-status.sh           # once
#   watch -n2 ./lb-status.sh # live, during a test

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
set +o errexit

echo "VIP ${VIP} held by: $(vip_holder)"
echo
for lb in "$LB1" "$LB2"; do
  echo "== ${lb}"
  ssh_lb "$lb" "
    printf '  haproxy:    %s\n' \"\$(systemctl is-active haproxy)\"
    printf '  keepalived: %s\n' \"\$(systemctl is-active keepalived)\"
    f=/var/lib/node_exporter/textfile_collector/keepalived.prom
    if [ -r \$f ]; then
      printf '  vrrp role:  %s\n' \"\$(awk -F'\"' '/^keepalived_vrrp_state_info/ && / 1\$/ {print \$4}' \$f)\"
    fi
  " 2>/dev/null || echo "  ssh failed"
  curl -s --max-time 3 "http://${lb}:${HAPROXY_METRICS_PORT}/metrics" |
    awk '
      $1 ~ /^haproxy_server_status\{/ && $2 == 1 {
        match($1, /proxy="[^"]*"/);  p = substr($1, RSTART + 7, RLENGTH - 8)
        match($1, /server="[^"]*"/); s = substr($1, RSTART + 8, RLENGTH - 9)
        match($1, /state="[^"]*"/);  st = substr($1, RSTART + 7, RLENGTH - 8)
        printf "  %-24s %-14s %s\n", p, s, st
      }' | sort || echo "  metrics endpoint unreachable"
  echo
done
