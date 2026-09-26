#!/usr/bin/env bash
# Undo setup-infra-ingress.sh: remove taints first (so nothing is evicted),
# unpin routers, then drop the infra label and MachineConfigPool.
#
# Usage: INFRA_NODES="infra-0 infra-1" ./scripts/rollback-infra-ingress.sh
set -euo pipefail
INFRA_NODES="${INFRA_NODES:?set INFRA_NODES}"
read -r -a nodes <<<"${INFRA_NODES}"

for n in "${nodes[@]}"; do
  oc adm taint nodes "$n" node-role.kubernetes.io/infra:NoSchedule- node-role.kubernetes.io/infra:NoExecute- || true
done

oc patch ingresscontroller/default -n openshift-ingress-operator --type=json \
  -p='[{"op":"remove","path":"/spec/nodePlacement"}]' || true
oc -n openshift-ingress rollout status deployment/router-default --timeout=15m

for n in "${nodes[@]}"; do
  oc label node "$n" node-role.kubernetes.io/infra- || true
done
# Nodes fall back to the worker pool; wait before deleting the empty pool.
oc wait mcp/worker --for=condition=Updated=True --timeout=30m
oc delete mcp infra --ignore-not-found
