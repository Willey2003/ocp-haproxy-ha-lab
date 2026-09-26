# Prep: DNS, firewall and SELinux

Everything the load balancers and the network need **before** HAProxy, keepalived
and the OpenShift install. All IPs and names are placeholders in
[`inventory.env`](inventory.env); change them there once and every script follows.

## Lab layout (placeholders)

| Role | Name | IP |
|---|---|---|
| Virtual IP (keepalived) | `lb-vip` | 192.168.100.10 |
| Load balancers | `lb1`, `lb2` | .11, .12 |
| DNS primary / secondary | `ns1`, `ns2` | .5, .6 |
| Bootstrap (install only) | `bootstrap` | .20 |
| Masters | `master0-2` | .21-.23 |
| Infra (routers) | `infra0-1` | .31-.32 |

Cluster domain: `ocp.lab.example.com`. Management network: `10.10.0.0/24`.

## 1. DNS

OpenShift needs three names, all pointing at the **VIP**, never at a single LB:

| Record | Points to | Used for |
|---|---|---|
| `api.ocp.lab.example.com` | VIP | `oc`, console, external API clients (6443) |
| `api-int.ocp.lab.example.com` | VIP | nodes: internal API (6443) and Machine Config Server (22623) |
| `*.apps.ocp.lab.example.com` | VIP | console, OAuth, every Route (80/443) |

Every node also needs matching **A and PTR** records; RHCOS takes its hostname from
the PTR. etcd SRV records are not needed on OpenShift 4.4+.

```bash
dns/render-zones.sh            # renders dns/out/*, validates with named-checkzone
# copy to the DNS primary as the script prints, then:
dns/verify-dns.sh              # checks every record on ns1 and ns2; exit 0 = ready
```

If you run split-horizon DNS, publish `api-int` only in the internal view.
After the install finishes, delete the `bootstrap` records and remove the
bootstrap backend from HAProxy.

## 2. Load balancer hosts (lb1 and lb2)

Run on each LB as root (RHEL 9):

```bash
scripts/prep-lb.sh             # sysctl, SELinux, firewalld, then verify
scripts/verify-lb-host.sh      # read-only re-check any time
```

### Kernel (`sysctl/90-ocp-lb.conf`)
`net.ipv4.ip_nonlocal_bind=1` lets HAProxy on the backup LB bind the VIP it does
not hold yet, so failover needs no HAProxy restart. Also raises accept backlogs.

### Firewall (`firewall/lb-firewalld.sh`)

| Port | What | Allowed from |
|---|---|---|
| 6443/tcp | Kubernetes API | anyone who can reach the zone |
| 22623/tcp | Machine Config Server | `MACHINE_CIDR` only (it serves node ignition, incl. secrets) |
| 80, 443/tcp | Ingress | anyone who can reach the zone |
| 9000/tcp | HAProxy stats page | `MGMT_CIDR` only |
| 8405/tcp | HAProxy Prometheus exporter | `MGMT_CIDR` only |
| VRRP (IP proto 112) | keepalived adverts | lb1 and lb2 only |

Ports are grouped into named firewalld services (`ocp-api`, `ocp-mcs`,
`haproxy-admin`) so `firewall-cmd --list-all` reads clearly. Set `RESTRICT_SSH=1`
to also limit SSH to the management network (confirm your own access first).

### SELinux (`selinux/lb-selinux.sh`)
SELinux stays **Enforcing**. HAProxy may only use ports labelled for it, so:

* `MODE=ports` (default, least privilege): labels 6443, 22623, 9000, 8405 and 1936
  (router health checks) as `http_port_t`. 80/443 already are.
* `MODE=boolean`: `setsebool -P haproxy_connect_any on`, which is what the
  OpenShift UPI docs show. Simpler but lets HAProxy use any port.

It also restores file contexts on `/etc/haproxy` and `/etc/keepalived` and prints
any recent AVC denials. If a keepalived track script is denied, check
`ausearch -m AVC -c keepalived` before reaching for a boolean.

## Cluster node ports (for reference)

HAProxy talks to the nodes on 6443 and 22623 (masters, bootstrap) and 80, 443 and
1936 (infra router health). RHCOS nodes manage their own host firewall; if a
network firewall sits between LBs and nodes, allow those ports from the two LB IPs.
