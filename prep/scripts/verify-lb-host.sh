#!/usr/bin/env bash
# Read-only check that a load balancer is prepped. Changes nothing.
# Exit code is the number of failed checks (0 = ready).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${here}/inventory.env"
fail=0
ok()  { printf '  PASS %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "-- Kernel"
check "net.ipv4.ip_nonlocal_bind = 1" test "$(sysctl -n net.ipv4.ip_nonlocal_bind)" = 1

echo "-- SELinux"
check "SELinux is Enforcing" test "$(getenforce)" = Enforcing
if [[ "$(getsebool haproxy_connect_any 2>/dev/null)" == *on ]]; then
  ok "haproxy_connect_any=on (MODE=boolean)"
else
  for p in "$PORT_API" "$PORT_MCS" "$PORT_STATS" "$PORT_METRICS" "$PORT_ROUTER_HEALTH"; do
    check "tcp/${p} is http_port_t" bash -c "semanage port -l | awk -v p=$p '\$1==\"http_port_t\" && \$2==\"tcp\" && (\",\"\$0\",\") ~ \"[ ,]\"p\"[,]\"' | grep -q ."
  done
fi

echo "-- firewalld"
zone="$(firewall-cmd --get-zone-of-interface="$LB_IFACE" 2>/dev/null || firewall-cmd --get-default-zone)"
check "firewalld running" firewall-cmd --state
for s in ocp-api http https; do check "service ${s} open in ${zone}" firewall-cmd --zone="$zone" --query-service="$s"; done
check "ocp-mcs NOT open zone-wide" bash -c "! firewall-cmd --zone=$zone --query-service=ocp-mcs"
check "haproxy-admin NOT open zone-wide" bash -c "! firewall-cmd --zone=$zone --query-service=haproxy-admin"
check "MCS limited to ${MACHINE_CIDR}" firewall-cmd --zone="$zone" --query-rich-rule="rule family=\"ipv4\" source address=\"${MACHINE_CIDR}\" service name=\"ocp-mcs\" accept"
check "stats/metrics limited to ${MGMT_CIDR}" firewall-cmd --zone="$zone" --query-rich-rule="rule family=\"ipv4\" source address=\"${MGMT_CIDR}\" service name=\"haproxy-admin\" accept"
for peer in "$LB1_IP" "$LB2_IP"; do
  check "VRRP allowed from ${peer}" firewall-cmd --zone="$zone" --query-rich-rule="rule family=\"ipv4\" source address=\"${peer}\" protocol value=\"vrrp\" accept"
done

echo "-- Name resolution from this LB"
for n in "api" "api-int" "x.apps"; do
  check "${n}.${CLUSTER_DOMAIN} -> ${LB_VIP}" test "$(getent ahostsv4 "${n}.${CLUSTER_DOMAIN}" | awk 'NR==1{print $1}')" = "$LB_VIP"
done

echo
if (( fail == 0 )); then echo "$(hostname -s) is ready for HAProxy + keepalived."; else echo "${fail} check(s) failed."; fi
exit "$fail"
