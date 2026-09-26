# OpenShift HAProxy HA lab

A production-grade external load balancer for a Red Hat OpenShift cluster
with 3 master nodes and 2 infra nodes: a pair of HAProxy nodes sharing a
keepalived virtual IP, fronting the API and Machine Config Server on the
masters and the `*.apps` ingress routers on the infra nodes.

```
   clients / nodes
         |
   DNS: api, api-int, *.apps  ->  VIP 192.168.100.10
         |
   +-----+------+   VRRP   +------------+
   | lb1 (.11)  |<-------->| lb2 (.12)  |    HAProxy + keepalived
   +-----+------+          +------------+
         |
   6443 / 22623 -> master0-2 (.21-.23)
   80 / 443     -> infra0-1  (.31-.32)   OpenShift routers pinned here
```

All addresses are lab placeholders on `192.168.100.0/24`, cluster
`ocp.lab.example.com`. `prep/inventory.env` is the single list of them.

## Layout

| Directory | What it holds | Step |
|-----------|---------------|------|
| [`haproxy/`](haproxy/) | HAProxy config, keepalived pair, check/notify scripts, sysctl, validation | 1. Load balancer pair |
| [`prep/`](prep/) | Inventory, DNS zones (api, api-int, *.apps), firewalld rules, SELinux settings for the LBs | 2. DNS, firewall, SELinux |
| [`ingress/`](ingress/) | Infra node labels and taints, infra MachineConfigPool, router pinning | 3. Ingress on infra nodes |
| `failover/` | Failover runbook tests, HAProxy metrics scraping and alerts | 4. Failover and monitoring |

## Order of operations

1. **Prep** (`prep/`): fill in `inventory.env`, create the DNS records,
   apply firewalld and SELinux settings on both LBs.
2. **Load balancers** (`haproxy/`): install HAProxy and keepalived on lb1
   and lb2, confirm the VIP is up and the stats page shows backends.
   For a fresh install, enable the bootstrap backend lines until
   bootstrap completes.
3. **Ingress** (`ingress/`): dedicate the infra nodes and move the routers
   onto them. The HAProxy ingress health checks (`:1936/healthz/ready`)
   go green once routers run there.
4. **Failover and monitoring** (`failover/`): run the kill tests and wire
   up metrics and alerts.

## Quick check

```bash
./haproxy/validate.sh          # haproxy -c and keepalived -t on the configs
```

## Requirements

- 2 RHEL 9 VMs for the load balancers on the same L2 segment as the VIP
- OpenShift 4.x cluster (UPI or platform `none`/agent-based with a
  user-managed load balancer)
- DNS you control for the cluster domain
