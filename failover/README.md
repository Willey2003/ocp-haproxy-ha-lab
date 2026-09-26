# Failover testing and monitoring

Proves the HAProxy + keepalived pair in front of the cluster actually fails
over, and alerts you when it cannot.

| Path | What it is |
|---|---|
| [RUNBOOK.md](RUNBOOK.md) | The ten failover tests: what each proves, how to run it, pass criteria, results table |
| `scripts/failover-test.sh` | Runs one test end to end: precheck, probe, break, restore, grade |
| `scripts/probe.sh`, `probe-summary.sh` | Probe api, api-int (MCS) and ingress through the VIP and measure outages |
| `scripts/lb-status.sh` | VIP holder, service state, VRRP role and HAProxy backend state for both LBs |
| `monitoring/lb/` | Installed on each LB: node_exporter and the VRRP-state metrics hook |
| `monitoring/rules/` | Alert rules (source of truth) |
| `monitoring/openshift/` | Scrapes the LBs from OpenShift user workload monitoring, plus the rules as a PrometheusRule |
| `monitoring/standalone/` | Prometheus, Alertmanager and blackbox_exporter in podman on the bastion, probing the VIP from outside |

## Setup

1. **On each LB** (as root), after `prep/` and `haproxy/` are in place. Pass
   every network that scrapes the LBs: the management network for the
   bastion, and the machine network for in-cluster monitoring (pods leave the
   cluster with their node's IP):

   ```bash
   monitoring/lb/install.sh 10.10.0.0/24 192.168.100.0/24
   ```

   Then add this line to `/etc/keepalived/notify.sh`, before `exit 0`, and
   `systemctl restart keepalived`:

   ```bash
   /usr/local/libexec/keepalived/notify-metrics.sh "$@"
   ```

   HAProxy's own exporter is already in `haproxy/haproxy.cfg` (`frontend
   prometheus`, :8405); `install.sh` only opens it to the scrape networks.

2. **In the cluster**, edit the LB IPs in `monitoring/openshift/10-lb-targets.yaml`, then:

   ```bash
   oc apply -f monitoring/openshift/
   ```

   If `cluster-monitoring-config` already exists, merge `enableUserWorkload: true`
   into it instead of applying `00-enable-user-workload-monitoring.yaml`.
   Alerts appear under Observe → Alerting and go to the cluster Alertmanager.

3. **On the bastion**, edit IPs and hostnames in
   `monitoring/standalone/prometheus.yml`, set a receiver in
   `alertmanager.yml`, then `monitoring/standalone/run.sh`.

4. **Run the tests**: `cp lab.env.example lab.env`, edit it, and follow
   [RUNBOOK.md](RUNBOOK.md) starting with `scripts/failover-test.sh baseline`.

## Why two Prometheus setups

The in-cluster one needs nothing extra and shows LB alerts next to everything
else in the console. But it runs on the cluster behind these LBs: if the VIP
is gone, you cannot reach its console, and its Alertmanager may not reach you.
The bastion one watches from outside, probes the VIP the way clients do, and
keeps alerting when the cluster is unreachable. For a lab, the in-cluster one
alone is fine; for production, run both.

## What gets alerted

| Alert | Severity | Fires when |
|---|---|---|
| KeepalivedNoMaster | critical | Neither LB holds the VIP |
| KeepalivedSplitBrain | critical | Both LBs hold the VIP |
| LBServiceNotActive | critical | haproxy or keepalived stopped on an LB |
| HAProxyBackendDown | critical | A backend (API, MCS, ingress) has no healthy server |
| VIPEndpointDown | critical | api, api-int or ingress unreachable through the VIP (bastion only) |
| HAProxyServerDown | warning | A master or infra node fails its health check for 2 minutes |
| KeepalivedFault, KeepalivedFlapping, HAProxyServerFlapping | warning | Something is unstable |
| HAProxyBackendConnectionErrors, HAProxyFrontendSessionsNearLimit | warning | Capacity or connectivity trouble |
| LBMetricsDown | warning | An LB exporter cannot be scraped |
| VIPEndpointSlow, ClusterCertificateExpiringSoon | warning | Slow endpoint, or a cert under 14 days (bastion only) |
| KeepalivedFailover | info | The VIP moved |

A "live MASTER" counts only while `keepalived.service` is active, so a stale
state file left by a killed keepalived cannot hide a missing VIP holder.

After editing `monitoring/rules/lb.rules.yml`, run
`monitoring/render-prometheusrule.sh` to regenerate the OpenShift copy.

## Ports this adds on the LBs

| Port | Service | Open to |
|---|---|---|
| 8405/tcp | HAProxy Prometheus exporter | `MGMT_CIDR` (prep/) plus the networks passed to install.sh |
| 9100/tcp | node_exporter | the networks passed to install.sh |

SELinux stays enforcing. `install.sh` labels `/usr/local/libexec/keepalived`
as `keepalived_unconfined_script_exec_t` so keepalived may run the hook, and
leaves `haproxy_connect_any` as `prep/selinux/lb-selinux.sh` set it.
