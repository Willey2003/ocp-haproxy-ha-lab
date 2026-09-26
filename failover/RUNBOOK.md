# Failover test runbook

Each test breaks one thing on purpose, measures what a client sees through the
VIP, and puts it back. Run them in the order below: every test assumes the one
before it passed.

`scripts/failover-test.sh <scenario>` automates each test. The manual steps
are listed too, so you can run a test by hand or understand what the script
does.

## Before you start

- Run everything from a bastion outside the cluster that has `oc` logged in
  as `cluster-admin`, SSH keys for both LBs, and passwordless `sudo` there.
- `cp lab.env.example lab.env` and edit it. The defaults match `haproxy/`
  and `prep/inventory.env`; backend names must match the `backend` sections
  in `haproxy.cfg`.
- Install the LB metrics on both LBs (`monitoring/lb/install.sh`, see the
  README) and add its line to `/etc/keepalived/notify.sh`. The test scripts
  read HAProxy state from the metrics endpoint on :8405, so the bastion must
  be in `MGMT_CIDR` or another network `install.sh` opened.
- Keep a second terminal open on `watch -n2 scripts/lb-status.sh` and a
  browser on Alertmanager, so you see the change as it happens.
- Never run a node test on a degraded cluster. The script refuses to, but if
  you run a test by hand, check `oc get nodes` and `oc get co` first.

### Settings the tests depend on

`haproxy/` in this repo already sets all of these. If you change that config,
keep them, or the tests below will fail for reasons that have nothing to do
with the cluster.

| Setting (in `haproxy/`) | Why it matters |
|---|---|
| keepalived `track_script chk_haproxy`, `interval 2`, `fall 2` | Moves the VIP off a node whose HAProxy is down, in about 4 to 6 seconds. Without it T1 fails. |
| `advert_int 1` | A crashed holder is detected after about 3 × advert_int. |
| API backend `http-check` on `/readyz` over TLS | The API server fails `/readyz` before it shuts down, so a graceful master reboot drains with no client errors. A plain TCP check keeps sending requests to a dying API server. |
| Ingress backends `check port 1936` on `/healthz/ready` | A TCP check on 443 stays green when the node is up but the router pod is gone. |
| `default-server inter 2s fall 2 rise 3` | A dead backend keeps receiving new connections for about `inter × fall` = 4s. |
| `option redispatch`, `retries 3` | A connection to a dead server is retried on a healthy one instead of failing. |
| `stats socket ... level admin` | Needed for the drain commands at the end of this runbook. |

The MCS backend uses a plain TCP check. That is fine for MCS, which only
serves Ignition to booting nodes, but it means a graceful master reboot can
show a brief `mcs` blip in T5 that the API does not.

## Pass criteria

| Test | What must hold |
|---|---|
| T0 Baseline | Zero failed requests for 60s. |
| T1–T3 LB failover | VIP moves to the standby. Longest outage per endpoint ≤ `MAX_VIP_FAILOVER_OUTAGE` (default 10s; expect about 1s for T2, 4–6s for T1, 3–4s for T3). `KeepalivedFailover` fires. |
| T4 Split brain | Both LBs claim the VIP, `KeepalivedSplitBrain` fires within about 1 minute, and the pair recovers to one holder by itself. |
| T5–T6 Master loss | API and MCS stay up through the other two masters. Longest outage ≤ `MAX_BACKEND_LOSS_OUTAGE` (default 10s). Graceful reboot should show 0s. `HAProxyServerDown` fires for the crash. |
| T7–T8 Infra loss | Ingress stays up through the other infra node, same limit. |
| T9 Router pod | Ingress stays up; expect 0s. |

The probe sends one request per endpoint every `PROBE_INTERVAL` seconds, pinned
to the VIP with `curl --resolve`: `api` (`:6443/readyz`), `mcs`
(`api-int:22623/healthz`), `ingress-https` (the ingress canary route) and
`ingress-http` (port 80, any response). Results land in
`results/<time>-<scenario>/` with the raw `probe.csv`, the LB state before and
after, and `summary.txt`.

---

## T0 Baseline

Proves the probe and the metrics work before anything is broken.

```bash
scripts/failover-test.sh baseline
```

By hand: `scripts/probe.sh > probe.csv`, wait a minute, Ctrl-C, then
`scripts/probe-summary.sh probe.csv`. Every target must show 0 failed.

## T1 HAProxy dies on the VIP holder

Proves keepalived notices a dead HAProxy and hands the VIP over.

```bash
scripts/failover-test.sh lb-haproxy-stop
```

By hand:

1. On the VIP holder: `sudo systemctl stop haproxy`.
2. After two failed `chk_haproxy` runs (about 4 seconds) the holder goes to
   FAULT, the standby logs `Entering MASTER STATE`
   (`journalctl -u keepalived -f`, or `journalctl -t keepalived-notify`) and
   `ip -4 addr show ens192` on it shows the VIP.
3. `sudo systemctl start haproxy` on the first LB. With preemption (the
   keepalived default), the VIP moves back, which is a second short failover.
   With `nopreempt`, it stays put.

If the VIP does not move, check that `track_script { chk_haproxy }` is in
the `vrrp_instance` and that `/etc/keepalived/check_haproxy.sh` fails when
HAProxy is stopped.

## T2 keepalived dies on the VIP holder

Proves the standby takes over when VRRP adverts stop.

```bash
scripts/failover-test.sh lb-keepalived-stop
```

By hand: `sudo systemctl stop keepalived` on the holder, watch the standby take
the VIP, then start it again. A clean stop sends a priority-0 advert, so this
is the fastest failover of the three.

## T3 The VIP holder crashes

The real "kill a node" test: no clean shutdown, no goodbye advert.

```bash
scripts/failover-test.sh lb-crash
```

By hand: power the VM off from the hypervisor, or on the LB run
`echo 1 | sudo tee /proc/sys/kernel/sysrq; echo b | sudo tee /proc/sysrq-trigger`.
The standby takes over after about 3 × `advert_int`. `LBMetricsDown` and
`KeepalivedFailover` should fire. Wait for the LB to boot and confirm haproxy
and keepalived are enabled and come back by themselves.

## T4 Split brain

Proves monitoring catches the failure mode keepalived cannot fix by itself:
both nodes up, but VRRP adverts not getting through.

```bash
scripts/failover-test.sh vrrp-block
```

The script adds a firewalld rich rule on the standby that drops VRRP for 90
seconds; firewalld removes it by itself even if the script dies. Both LBs then
claim the VIP, clients flap between them as ARP caches update, and
`KeepalivedSplitBrain` should fire. After the rule expires the lower-priority
node returns to BACKUP.

By hand:

```bash
sudo firewall-cmd --add-rich-rule='rule protocol value="vrrp" drop' --timeout=90
```

Run it in the zone of the VIP interface (`firewall-cmd
--get-zone-of-interface=ens192`), which is where `prep/firewall/lb-firewalld.sh`
allows VRRP from the peer. firewalld evaluates drop rules before accept rules,
so the drop wins. If you ever allow VRRP with a direct rule instead, the
direct rule wins and nothing happens; block it at the hypervisor then.

## T5 A master reboots gracefully

Proves planned maintenance on a master is invisible to clients.

```bash
scripts/failover-test.sh master-reboot <master-node>
```

By hand:

```bash
oc adm cordon <node>
oc adm drain <node> --ignore-daemonsets --delete-emptydir-data --force
oc debug node/<node> -- chroot /host systemctl reboot
# wait for Ready
oc adm uncordon <node>
```

Watch `lb-status.sh`: the node goes DOWN in the API and MCS backends before
the reboot finishes, because `/readyz` fails first. Expect a 0s outage. If
you see errors, the API backend is using a TCP check (see the settings
table).

**Only ever one master at a time.** Two masters down loses etcd quorum and the
API goes read-only or down. The script checks that every node is Ready and
the etcd and kube-apiserver operators are healthy before it starts.

## T6 A master crashes

```bash
scripts/failover-test.sh master-reboot <master-node> --hard
```

By hand: power the VM off, or
`oc debug node/<node> -- chroot /host sh -c 'echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger'`.

Connections already on that master break, and new ones may hit it until
HAProxy marks it DOWN (about `inter × fall`). `option redispatch` limits the
damage. Expect a short blip within the limit, `HAProxyServerDown` firing after
2 minutes if the node is still down, and etcd recovering by itself after the
node returns. Afterwards, confirm with `oc get co etcd kube-apiserver`.

## T7 An infra node reboots gracefully

```bash
scripts/failover-test.sh infra-reboot <infra-node>
```

Draining evicts the router pod. With only two infra nodes and routers pinned
to them, the evicted router stays Pending until the node returns; one router
carries all ingress traffic meanwhile. The ingress backends in HAProxy drop to
one server, then return to two. Expect 0s outage.

## T8 An infra node crashes

```bash
scripts/failover-test.sh infra-reboot <infra-node> --hard
```

As T6, for ingress. Existing HTTP connections to that router break; new ones
move to the other router once HAProxy marks the node DOWN.

## T9 A router pod dies

Proves HAProxy checks the router, not just the node.

```bash
scripts/failover-test.sh router-pod-delete <infra-node>
```

By hand:
`oc -n openshift-ingress delete pod -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default --field-selector spec.nodeName=<node>`.

The router drains gracefully and a new pod starts on the same node. If
HAProxy never shows the server DOWN during the restart, the ingress check is a
plain TCP check; that is harmless here but will miss a router that is stuck
rather than stopped.

---

## Planned maintenance on a backend

To take one server out of HAProxy by hand without touching the node, use the
runtime API on both LBs (the socket path is the `stats socket` line in
`haproxy.cfg`):

```bash
echo "set server api_backend/master0 state drain" | sudo socat stdio /var/lib/haproxy/stats
# ... work ...
echo "set server api_backend/master0 state ready" | sudo socat stdio /var/lib/haproxy/stats
```

Do the same for `machine_config_backend/master0`, or for an infra node,
`ingress_https_backend/infra0` and `ingress_http_backend/infra0`. The stats
page on :9000 has the same controls.

`drain` lets existing connections finish and sends no new ones. The change is
lost when HAProxy restarts.

## Recording results

Copy this table into your change or lab notes after each round.

| Date | Test | VIP holder before → after | Longest outage (api / mcs / https / http) | Alerts seen | Result |
|---|---|---|---|---|---|
| | T0 | | | none | |
| | T1 | | | KeepalivedFailover | |
| | T2 | | | KeepalivedFailover | |
| | T3 | | | LBMetricsDown, KeepalivedFailover | |
| | T4 | | | KeepalivedSplitBrain | |
| | T5 | | | HAProxyServerDown while the node is down | |
| | T6 | | | HAProxyServerDown | |
| | T7 | | | HAProxyServerDown while the node is down | |
| | T8 | | | HAProxyServerDown | |
| | T9 | | | none expected | |
