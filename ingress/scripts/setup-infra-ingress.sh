#!/usr/bin/env bash
# Turn two nodes into dedicated infra nodes and move the OpenShift routers
# onto them, in an order that never leaves the cluster without a router:
#
#   1. label infra nodes          (node-role.kubernetes.io/infra="")
#   2. create the infra MCP       (and wait for it to be Updated)
#   3. pin routers to infra       (nodeSelector + tolerations, wait for rollout)
#   4. taint infra nodes          (NoSchedule + NoExecute, evicts other pods)
#
# Tainting last matters: NoExecute evicts anything without a toleration, so
# the routers must already tolerate it before the taint lands.
#
# Usage:
#   INFRA_NODES="infra-0.ocp.lab.example infra-1.ocp.lab.example" \
#     ./scripts/setup-infra-ingress.sh
#
# Env:
#   INFRA_NODES  space-separated node names (required)
#   TAINT        "true" (default) or "false" to skip step 4
#   DRY_RUN      "true" to print commands without running them
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/../manifests"
INFRA_NODES="${INFRA_NODES:?set INFRA_NODES to the two infra node names}"
TAINT="${TAINT:-true}"
DRY_RUN="${DRY_RUN:-false}"

run() {
  echo "+ $*"
  if [[ "${DRY_RUN}" != "true" ]]; then
    "$@"
  fi
}

log() { printf '\n=== %s ===\n' "$*"; }

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
oc whoami >/dev/null || { echo "not logged in to the cluster" >&2; exit 1; }

read -r -a nodes <<<"${INFRA_NODES}"
if (( ${#nodes[@]} < 2 )); then
  echo "warning: fewer than 2 infra nodes; ingress will not be highly available" >&2
fi
for n in "${nodes[@]}"; do
  oc get node "${n}" >/dev/null
done

log "1/4 Labelling infra nodes"
for n in "${nodes[@]}"; do
  run oc label node "${n}" node-role.kubernetes.io/infra="" --overwrite
done

log "2/4 Creating infra MachineConfigPool"
run oc apply -f "${MANIFESTS}/00-infra-machineconfigpool.yaml"
if [[ "${DRY_RUN}" != "true" ]]; then
  # Moving nodes into the new pool can reboot them one at a time.
  echo "waiting for mcp/infra to report Updated (can take a while if nodes reboot)"
  sleep 15
  oc wait mcp/infra --for=condition=Updated=True --timeout=30m
  oc get mcp infra
fi

log "3/4 Pinning default IngressController to infra nodes"
run oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=merge --patch-file="${MANIFESTS}/10-ingresscontroller-infra-placement.yaml"
if [[ "${DRY_RUN}" != "true" ]]; then
  sleep 10
  oc -n openshift-ingress rollout status deployment/router-default --timeout=15m
  oc -n openshift-ingress get pods -o wide -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default
fi

if [[ "${TAINT}" == "true" ]]; then
  log "4/4 Tainting infra nodes"
  for n in "${nodes[@]}"; do
    run oc adm taint nodes "${n}" \
      node-role.kubernetes.io/infra=reserved:NoSchedule \
      node-role.kubernetes.io/infra=reserved:NoExecute --overwrite
  done
else
  log "4/4 Skipping taints (TAINT=${TAINT})"
fi

log "Done. Run scripts/verify-infra-ingress.sh to check the result."
