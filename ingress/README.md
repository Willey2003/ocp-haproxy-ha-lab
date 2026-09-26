# Ingress on the infra nodes

Dedicates the two infra nodes to OpenShift ingress and pins the default
router (one replica per infra node) to them, so the external HAProxy pair
sends `*.apps` 80/443 traffic only to `infra-0` and `infra-1`.

```
               *.apps VIP (keepalived)
                        |
              HAProxy :80 / :443  --- health check :1936/healthz/ready
                 /             \
         infra-0                 infra-1
   router-default pod       router-default pod     (HostNetwork)
   label: node-role.kubernetes.io/infra=""
   taint: node-role.kubernetes.io/infra=reserved:NoSchedule,NoExecute
```

## Layout

| Path | What it does |
|------|--------------|
| `manifests/00-infra-machineconfigpool.yaml` | `infra` MachineConfigPool that inherits all worker MachineConfigs, rolling one node at a time |
| `manifests/10-ingresscontroller-infra-placement.yaml` | Merge patch for `ingresscontroller/default`: 2 replicas, infra `nodeSelector`, infra taint tolerations |
| `manifests/20-dns-tolerate-infra.yaml` | Optional: let CoreDNS keep running on the tainted infra nodes |
| `install-time/cluster-ingress-default-ingresscontroller.yaml` | Same placement dropped into `openshift-install` manifests for a fresh install |
| `scripts/setup-infra-ingress.sh` | Label, create MCP, pin routers, then taint, waiting between each step |
| `scripts/verify-infra-ingress.sh` | Checks labels, taints, MCP health, router placement, `:1936` health and the console route through the VIP |
| `scripts/rollback-infra-ingress.sh` | Reverses the setup in a safe order |

## Prerequisites

- Cluster installed (UPI / agent-based) with the default IngressController
  using the `HostNetwork` endpoint strategy, which is the default on bare
  metal and platform `none`.
- `oc` logged in as `cluster-admin`.
- The HAProxy `*.apps` backends point at the two infra node IPs on 80/443
  and health-check `http://<node>:1936/healthz/ready` (see the HAProxy
  config in this repo).

## Apply to a running cluster

```bash
export INFRA_NODES="infra-0.ocp.lab.example infra-1.ocp.lab.example"

# Preview every command first
DRY_RUN=true ./scripts/setup-infra-ingress.sh

./scripts/setup-infra-ingress.sh
./scripts/verify-infra-ingress.sh
```

The order matters. The taints include `NoExecute`, which evicts every pod
that does not tolerate it, so the routers are moved and rolled out with
the tolerations **before** the taint is applied. The router has a
PodDisruptionBudget and the operator rolls HostNetwork routers one at a
time, so HAProxy always has one healthy backend during the move.

Moving the nodes into the `infra` pool may reboot them one at a time if
the rendered config differs; the script waits for `mcp/infra` to report
`Updated` before touching the routers.

### Manual equivalent

```bash
oc label node infra-0 infra-1 node-role.kubernetes.io/infra=""
oc apply -f manifests/00-infra-machineconfigpool.yaml
oc wait mcp/infra --for=condition=Updated=True --timeout=30m

oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=merge --patch-file=manifests/10-ingresscontroller-infra-placement.yaml
oc -n openshift-ingress rollout status deployment/router-default

oc adm taint nodes infra-0 infra-1 \
  node-role.kubernetes.io/infra=reserved:NoSchedule \
  node-role.kubernetes.io/infra=reserved:NoExecute
```

## Apply at install time

After `openshift-install create manifests --dir <install-dir>`:

```bash
cp install-time/cluster-ingress-default-ingresscontroller.yaml <install-dir>/manifests/
```

Then, once the infra nodes have joined, label them, apply the MCP and add
the taints (steps 1, 2 and 4 of the script; step 3 is already done).

## Things to know

- **No separate worker nodes?** With only 3 masters and 2 infra nodes,
  tainting the infra nodes means application pods can only run on the
  masters (the installer makes masters schedulable when there are no
  workers). That is fine for a lab; for real workloads add worker nodes.
  To keep apps allowed on infra nodes, run with `TAINT=false`.
- **Why keep the worker label?** Infra nodes keep
  `node-role.kubernetes.io/worker` so they inherit worker MachineConfigs.
  A node with worker plus one custom role joins the custom pool, so they
  sit in `infra`, not `worker`.
- **Subscriptions.** Nodes labelled infra that only run infrastructure
  components (router, registry, monitoring, logging) do not count toward
  OpenShift subscription cores. Keep application pods off them, which the
  taint enforces and `verify-infra-ingress.sh` checks.
- **DNS.** `dns-default` does not tolerate the infra taint, so CoreDNS
  stops running on infra nodes after tainting. Name resolution still works
  through the DNS service; apply `manifests/20-dns-tolerate-infra.yaml`
  if you want a local CoreDNS pod there.
- **Other infra components.** Registry, monitoring and logging can be moved
  with the same `nodeSelector` and tolerations; they are out of scope here.

## Rollback

```bash
INFRA_NODES="infra-0.ocp.lab.example infra-1.ocp.lab.example" ./scripts/rollback-infra-ingress.sh
```
