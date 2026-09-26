#!/usr/bin/env bash
# Verify that the routers run only on infra nodes and answer through the
# HAProxy *.apps VIP. Exits non-zero on the first failed check.
#
# Usage:
#   APPS_DOMAIN=apps.ocp.lab.example ./scripts/verify-infra-ingress.sh
#
# Env:
#   APPS_DOMAIN  wildcard apps domain; defaults to the cluster's ingress domain
#   EXPECT_TAINT "true" (default) to require the infra taints
set -euo pipefail

EXPECT_TAINT="${EXPECT_TAINT:-true}"
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')}"
ROUTER_SELECTOR="ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default"
fail=0

pass() { printf '  [PASS] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=1; }

echo "Infra nodes:"
mapfile -t infra < <(oc get nodes -l node-role.kubernetes.io/infra= -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if (( ${#infra[@]} >= 2 )); then pass "${#infra[@]} nodes labelled infra: ${infra[*]}"; else bad "expected >=2 infra nodes, found ${#infra[@]}"; fi

for n in "${infra[@]}"; do
  ready=$(oc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  [[ "$ready" == "True" ]] && pass "$n Ready" || bad "$n not Ready"
  if [[ "$EXPECT_TAINT" == "true" ]]; then
    taints=$(oc get node "$n" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{" "}{end}')
    for t in node-role.kubernetes.io/infra=reserved:NoSchedule node-role.kubernetes.io/infra=reserved:NoExecute; do
      [[ " $taints " == *" $t "* ]] && pass "$n has taint $t" || bad "$n missing taint $t"
    done
  fi
done

echo "MachineConfigPool:"
upd=$(oc get mcp infra -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || true)
deg=$(oc get mcp infra -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)
[[ "$upd" == "True" ]] && pass "mcp/infra Updated" || bad "mcp/infra not Updated (${upd:-missing})"
[[ "$deg" == "False" ]] && pass "mcp/infra not Degraded" || bad "mcp/infra Degraded=${deg:-unknown}"

echo "Router placement:"
mapfile -t router_nodes < <(oc -n openshift-ingress get pods -l "$ROUTER_SELECTOR" \
  --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort)
(( ${#router_nodes[@]} == 2 )) && pass "2 router pods Running" || bad "expected 2 running routers, found ${#router_nodes[@]}"
uniq_count=$(printf '%s\n' "${router_nodes[@]}" | sort -u | grep -c . || true)
(( uniq_count == ${#router_nodes[@]} )) && pass "routers on distinct nodes" || bad "two routers share a node"
for rn in "${router_nodes[@]}"; do
  if printf '%s\n' "${infra[@]}" | grep -qx "$rn"; then pass "router on infra node $rn"; else bad "router on non-infra node $rn"; fi
done

echo "Stray workloads on infra nodes (non-openshift namespaces):"
stray=0
for n in "${infra[@]}"; do
  while read -r ns name; do
    [[ -z "$ns" ]] && continue
    bad "unexpected pod $ns/$name on $n"; stray=1
  done < <(oc get pods -A --field-selector="spec.nodeName=$n,status.phase=Running" \
             -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
           | grep -Ev '^(openshift-|kube-)' || true)
done
(( stray == 0 )) && pass "no application pods on infra nodes"

echo "Router health (port 1936, what HAProxy health-checks):"
for n in "${infra[@]}"; do
  ip=$(oc get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:1936/healthz/ready" || true)
  [[ "$code" == "200" ]] && pass "$n ($ip) /healthz/ready 200" || bad "$n ($ip) /healthz/ready returned ${code:-no answer}"
done

echo "End to end through the *.apps VIP:"
console="console-openshift-console.${APPS_DOMAIN}"
code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "https://${console}/" || true)
[[ "$code" =~ ^(200|302)$ ]] && pass "https://${console} -> ${code}" || bad "https://${console} returned ${code:-no answer}"
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://${console}/" || true)
[[ "$code" =~ ^(200|301|302)$ ]] && pass "http://${console} -> ${code}" || bad "http://${console} returned ${code:-no answer}"

echo "IngressController status:"
avail=$(oc get ingresscontroller/default -n openshift-ingress-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
[[ "$avail" == "True" ]] && pass "ingresscontroller/default Available" || bad "ingresscontroller/default Available=$avail"
co=$(oc get co ingress -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')
[[ "$co" == "False" ]] && pass "clusteroperator/ingress not Degraded" || bad "clusteroperator/ingress Degraded=$co"

echo
if (( fail )); then echo "RESULT: FAILED"; exit 1; fi
echo "RESULT: all checks passed"
