#!/usr/bin/env bash
# Verify the DNS records OpenShift needs, against every DNS server in inventory.env.
# Run from any host on the machine network (or the LBs) before starting the install.
# Usage: dns/verify-dns.sh [dns_server ...]   env: DNS_PORT (default 53)
# Exit code is the number of failed checks (0 = ready).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${here}/../inventory.env"
command -v dig >/dev/null || { echo "dig not found: dnf install -y bind-utils" >&2; exit 1; }

servers=("$@"); [[ ${#servers[@]} -eq 0 ]] && servers=("$DNS1_IP" "$DNS2_IP")
port="${DNS_PORT:-53}"
fail=0
ok()  { printf '  \e[32mPASS\e[0m %s\n' "$*"; }
bad() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; fail=$((fail + 1)); }

check_a() { # server name expected_ip
  local got; got="$(dig +short +time=2 +tries=1 -p "$port" @"$1" "$2" A | tail -n1)"
  if [[ "$got" == "$3" ]]; then ok "$2 -> $got"; else bad "$2 -> '${got:-NXDOMAIN}' (want $3)"; fi
}
check_ptr() { # server ip expected_fqdn
  local got; got="$(dig +short +time=2 +tries=1 -p "$port" @"$1" -x "$2" | tail -n1)"
  if [[ "$got" == "$3." ]]; then ok "$2 -> $got"; else bad "$2 -> '${got:-none}' (want $3.)"; fi
}

nodes=(LB1 LB2 BOOTSTRAP MASTER0 MASTER1 MASTER2 INFRA0 INFRA1)
for srv in "${servers[@]}"; do
  echo "== DNS server ${srv}:${port}"
  echo "-- Cluster endpoints (must all be the VIP ${LB_VIP})"
  check_a "$srv" "api.${CLUSTER_DOMAIN}"     "$LB_VIP"
  check_a "$srv" "api-int.${CLUSTER_DOMAIN}" "$LB_VIP"
  # Two random names prove the wildcard, plus the two routes the install needs.
  check_a "$srv" "wildcard-test-$RANDOM.apps.${CLUSTER_DOMAIN}"                "$LB_VIP"
  check_a "$srv" "console-openshift-console.apps.${CLUSTER_DOMAIN}"          "$LB_VIP"
  check_a "$srv" "oauth-openshift.apps.${CLUSTER_DOMAIN}"                    "$LB_VIP"

  echo "-- Node forward and reverse records (A and PTR must agree)"
  for n in "${nodes[@]}"; do
    name_var="${n}_NAME"; ip_var="${n}_IP"
    fqdn="${!name_var}.${CLUSTER_DOMAIN}"
    check_a   "$srv" "$fqdn" "${!ip_var}"
    check_ptr "$srv" "${!ip_var}" "$fqdn"
  done

  echo "-- The VIP must not reverse-resolve to api/api-int/apps"
  vip_ptr="$(dig +short +time=2 +tries=1 -p "$port" @"$srv" -x "$LB_VIP" | tail -n1)"
  if [[ "$vip_ptr" =~ ^(api|api-int|.*apps)\. ]]; then bad "VIP PTR is $vip_ptr"; else ok "VIP PTR is '${vip_ptr:-none}'"; fi
done

echo
if (( fail == 0 )); then echo "DNS is ready for OpenShift."; else echo "${fail} DNS check(s) failed."; fi
exit "$fail"
