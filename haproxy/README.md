# HAProxy + keepalived load balancer pair

Two RHEL 9 VMs (`lb1`, `lb2`) run identical HAProxy configs and share one
virtual IP through keepalived (VRRP). Whichever node holds the VIP carries
all traffic; if HAProxy on it dies or hangs, the VIP moves to the peer in
about 4 seconds.

```
                 api / api-int / *.apps  ->  VIP 192.168.100.10
                                   |
               +-------------------+-------------------+
               |  lb1 .11 (MASTER, prio 150)           |  lb2 .12 (BACKUP, prio 100)
               |  haproxy + keepalived                 |  haproxy + keepalived
               +-------------------+-------------------+
          6443 / 22623             |              80 / 443
   +--------------+--------------+ | +----------------+----------------+
 master0 .21   master1 .22   master2 .23        infra0 .31        infra1 .32
```

## What is load balanced

| Port  | Frontend          | Backends               | Health check                                  |
|-------|-------------------|------------------------|-----------------------------------------------|
| 6443  | Kubernetes API    | 3 masters (+bootstrap) | HTTPS `GET /readyz` expects 200               |
| 22623 | Machine Config    | 3 masters (+bootstrap) | TCP connect                                   |
| 443   | Ingress HTTPS     | 2 infra nodes          | `GET /healthz/ready` on router port 1936      |
| 80    | Ingress HTTP      | 2 infra nodes          | `GET /healthz/ready` on router port 1936      |
| 9000  | Stats page        | local                  | `/stats` (basic auth)                         |
| 8405  | Prometheus metrics| local                  | `/metrics`                                    |
| 8081  | LB liveness (127.0.0.1 only) | local       | `/healthz`, used by keepalived                |

Checks run every 2s; a server is marked down after 2 failures and back up
after 3 passes. Ingress is TLS passthrough (the routers terminate TLS) with
source-IP affinity. The API and ingress backends keep established tunnels
open for up to 1 hour so `oc` watches and websockets are not cut.

## Files

| File | Goes to | Notes |
|------|---------|-------|
| `haproxy.cfg` | `/etc/haproxy/haproxy.cfg` on both LBs | identical on both |
| `keepalived/keepalived-lb1.conf` | `/etc/keepalived/keepalived.conf` on lb1 | MASTER |
| `keepalived/keepalived-lb2.conf` | `/etc/keepalived/keepalived.conf` on lb2 | BACKUP |
| `keepalived/check_haproxy.sh` | `/etc/keepalived/` on both | VRRP health check |
| `keepalived/notify.sh` | `/etc/keepalived/` on both | logs state changes to the journal |
| `sysctl/90-haproxy.conf` | `/etc/sysctl.d/` on both | lets the standby bind the VIP |
| `validate.sh` | run locally | `haproxy -c` + `keepalived -t` |

## Before you deploy: replace placeholders

These match `../prep/inventory.env`, the lab's single source of truth.

| Placeholder | Where | Meaning |
|-------------|-------|---------|
| `192.168.100.10` | haproxy.cfg, keepalived | VIP |
| `192.168.100.11` / `.12` | keepalived | lb1 / lb2 node IPs |
| `192.168.100.20` | haproxy.cfg (commented) | bootstrap node |
| `192.168.100.21-23` | haproxy.cfg | master0-2 |
| `192.168.100.31-32` | haproxy.cfg | infra0-1 |
| `ens192` | keepalived | NIC on the node network |
| `virtual_router_id 51` | keepalived | unique per L2 segment |
| `auth_pass Ch4ngeMe` | keepalived | VRRP password (max 8 chars) |
| `admin:changeme` | haproxy.cfg | stats page login |

A quick way to swap the lab subnet for yours:

```bash
sed -i 's/192\.168\.100\./10.10.20./g' haproxy.cfg keepalived/*.conf
```

## Install (on each LB, as root)

```bash
dnf install -y haproxy keepalived curl policycoreutils-python-utils

# configs
install -m 644 haproxy.cfg /etc/haproxy/haproxy.cfg
install -m 644 keepalived/keepalived-lb1.conf /etc/keepalived/keepalived.conf   # lb2: keepalived-lb2.conf
install -m 755 keepalived/check_haproxy.sh keepalived/notify.sh /etc/keepalived/
install -m 644 sysctl/90-haproxy.conf /etc/sysctl.d/ && sysctl --system

# SELinux: let HAProxy bind 6443/22623/9000/8405/8081 and connect to any backend
# port, and let keepalived run the check/notify scripts unconfined.
# (The full SELinux prep lives in ../prep/selinux/.)
setsebool -P haproxy_connect_any 1
chcon -t keepalived_unconfined_script_exec_t /etc/keepalived/check_haproxy.sh /etc/keepalived/notify.sh

haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable --now haproxy keepalived
```

Firewall: the LBs need 6443, 22623, 80 and 443/tcp open to clients, 9000
and 8405/tcp open to the management network, and VRRP (IP protocol 112)
allowed between lb1 and lb2. The full rules are in `../prep/firewall/`.
Minimal version if you are testing without that step:

```bash
firewall-cmd --permanent --add-port={6443,22623,80,443,9000,8405}/tcp
firewall-cmd --permanent --add-rich-rule='rule protocol value="vrrp" accept'
firewall-cmd --reload
```

## Install-time bootstrap node

During a fresh OpenShift install, uncomment the two `server bootstrap`
lines in `haproxy.cfg` and reload. After
`openshift-install wait-for bootstrap-complete` succeeds, comment them out
again and `systemctl reload haproxy`.

## Verify

```bash
ip -br addr show ens192                 # VIP present on exactly one LB
curl -s http://127.0.0.1:8081/healthz    # 200 while HAProxy is alive
curl -su admin:changeme http://<vip>:9000/stats
curl -s http://<lb>:8405/metrics | head
echo "show servers state" | socat stdio /var/lib/haproxy/stats
journalctl -t keepalived-notify          # VRRP state changes
oc get --raw /readyz --server https://api.<cluster>.<domain>:6443
```

## Operating notes

- Reload HAProxy without dropping connections: `systemctl reload haproxy`.
- Drain a master before maintenance:
  `echo "disable server api_backend/master0" | socat stdio /var/lib/haproxy/stats`
  (or use the stats page, logged in).
- lb1 is preferred (priority 150) and takes the VIP back when it recovers.
  To avoid that extra flip, set `state BACKUP` on both and add `nopreempt`.
