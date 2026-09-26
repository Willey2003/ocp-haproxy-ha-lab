#!/bin/bash
# Install the LB-side monitoring pieces on one HAProxy/keepalived node (RHEL 9).
# Run as root on each LB, after haproxy/ and prep/ are in place:
#
#   sudo ./install.sh <scrape-source-cidr> [<cidr> ...]
#
# Pass every network Prometheus scrapes from: the management network for the
# bastion Prometheus, and the machine network for in-cluster monitoring (pods
# leave the cluster with their node's IP). For this lab:
#
#   sudo ./install.sh 10.10.0.0/24 192.168.100.0/24
#
# What it does:
#   1. node_exporter (pinned release, checksum-verified) with the textfile
#      and systemd collectors, on :9100
#   2. the VRRP-state metrics hook, labelled so keepalived may run it
#   3. firewalld: 9100 and 8405 open to the given CIDRs only
#   4. checks HAProxy's exporter (frontend prometheus in haproxy.cfg) answers
#
# It does not edit haproxy/keepalived/notify.sh; add the line shown in
# notify-metrics.sh to it yourself.

set -euo pipefail

(( $# >= 1 )) || { sed -n '4,9p' "$0" >&2; exit 2; }
SCRAPE_CIDRS=("$@")
NODE_EXPORTER_VERSION=${NODE_EXPORTER_VERSION:-1.9.1}
HERE=$(cd "$(dirname "$0")" && pwd)
# Same zone choice as prep/firewall/lb-firewalld.sh.
LB_IFACE=${LB_IFACE:-ens192}
ZONE=${ZONE:-$(firewall-cmd --get-zone-of-interface="$LB_IFACE" 2>/dev/null || firewall-cmd --get-default-zone)}

echo "== node_exporter ${NODE_EXPORTER_VERSION}"
if ! /usr/local/bin/node_exporter --version 2>&1 | grep -q "version ${NODE_EXPORTER_VERSION}"; then
  tmp=$(mktemp -d)
  base="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}"
  tarball="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
  curl -fsSL -o "$tmp/sha256sums.txt" "$base/sha256sums.txt"
  (cd "$tmp" && grep " ${tarball}\$" sha256sums.txt | sha256sum -c -)
  tar -xzf "$tmp/$tarball" -C "$tmp"
  install -m 0755 "$tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
  restorecon -v /usr/local/bin/node_exporter
  rm -rf "$tmp"
fi
id node_exporter &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin node_exporter
install -d -m 0755 /var/lib/node_exporter/textfile_collector
install -m 0644 "$HERE/node_exporter.service" /etc/systemd/system/node_exporter.service
systemctl daemon-reload
systemctl enable --now node_exporter
systemctl restart node_exporter

echo "== VRRP state metrics hook"
install -d -m 0755 /usr/local/libexec/keepalived
install -m 0755 "$HERE/notify-metrics.sh" /usr/local/libexec/keepalived/notify-metrics.sh
# keepalived runs notify scripts in a confined domain; this type lets the
# hook write the metrics file.
semanage fcontext -a -t keepalived_unconfined_script_exec_t '/usr/local/libexec/keepalived(/.*)?' 2>/dev/null ||
  semanage fcontext -m -t keepalived_unconfined_script_exec_t '/usr/local/libexec/keepalived(/.*)?'
restorecon -Rv /usr/local/libexec/keepalived
if ! grep -q notify-metrics.sh /etc/keepalived/notify.sh 2>/dev/null; then
  echo "   ACTION: add this line to /etc/keepalived/notify.sh before 'exit 0', then restart keepalived:"
  echo '     /usr/local/libexec/keepalived/notify-metrics.sh "$@"'
fi

echo "== firewalld (zone ${ZONE}): 9100 and 8405 from ${SCRAPE_CIDRS[*]}"
for cidr in "${SCRAPE_CIDRS[@]}"; do
  for port in 9100 8405; do
    rule="rule family=ipv4 source address=${cidr} port port=${port} protocol=tcp accept"
    firewall-cmd --permanent --zone="$ZONE" --query-rich-rule="$rule" >/dev/null ||
      firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$rule"
  done
done
firewall-cmd --reload

echo "== check"
curl -fsS http://127.0.0.1:8405/metrics | grep -c '^haproxy_server_status' | xargs echo "   haproxy_server_status series:"
curl -fsS http://127.0.0.1:9100/metrics | grep -E '^node_systemd_unit_state\{name="(haproxy|keepalived).service",state="active"' || true
ls -l /var/lib/node_exporter/textfile_collector/
