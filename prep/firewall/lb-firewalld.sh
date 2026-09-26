#!/usr/bin/env bash
# Open exactly the ports the HAProxy + keepalived pair needs, on both LBs.
# Idempotent: safe to re-run. Run as root on lb1 and lb2.
#
#   6443  Kubernetes API           from anywhere in ZONE (clients, nodes)
#   22623 Machine Config Server    from MACHINE_CIDR only (nodes during ignition)
#   80/443 Ingress                 from anywhere in ZONE
#   9000  HAProxy stats page       from MGMT_CIDR only
#   8405  HAProxy Prometheus       from MGMT_CIDR only
#   VRRP  (IP proto 112)           from the two LB addresses only
#
# env: ZONE (default: the zone bound to LB_IFACE, else the default zone)
#      RESTRICT_SSH=1  also limit SSH to MGMT_CIDR (check your own access first!)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${here}/../inventory.env"
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

systemctl enable --now firewalld
fw() { firewall-cmd --permanent "$@" >/dev/null; }

ZONE="${ZONE:-$(firewall-cmd --get-zone-of-interface="$LB_IFACE" 2>/dev/null || firewall-cmd --get-default-zone)}"
echo "Configuring firewalld zone '${ZONE}' (interface ${LB_IFACE})"

# Named services make `firewall-cmd --list-all` readable during an incident.
define_service() { # name description port...
  local name="$1" desc="$2"; shift 2
  if ! firewall-cmd --permanent --get-services | tr ' ' '\n' | grep -qx "$name"; then
    fw --new-service="$name"
  fi
  fw --service="$name" --set-description="$desc"
  for p in "$@"; do fw --service="$name" --add-port="$p"; done
}
define_service ocp-api       "OpenShift Kubernetes API via HAProxy"        "${PORT_API}/tcp"
define_service ocp-mcs       "OpenShift Machine Config Server via HAProxy" "${PORT_MCS}/tcp"
define_service haproxy-admin "HAProxy stats page and Prometheus exporter"  "${PORT_STATS}/tcp" "${PORT_METRICS}/tcp"

# Public-facing endpoints.
fw --zone="$ZONE" --add-service=ocp-api
fw --zone="$ZONE" --add-service=http
fw --zone="$ZONE" --add-service=https

# Source-restricted endpoints: rich rules, never a plain --add-service.
rich() { fw --zone="$ZONE" --add-rich-rule="$1"; }
rich "rule family=ipv4 source address=${MACHINE_CIDR} service name=ocp-mcs accept"
rich "rule family=ipv4 source address=${MGMT_CIDR} service name=haproxy-admin accept"
# Make sure nobody opened them zone-wide earlier.
fw --zone="$ZONE" --remove-service=ocp-mcs 2>/dev/null || true
fw --zone="$ZONE" --remove-service=haproxy-admin 2>/dev/null || true

# keepalived VRRP adverts (multicast 224.0.0.18 or unicast) between the peers.
for peer in "$LB1_IP" "$LB2_IP"; do
  rich "rule family=ipv4 source address=${peer} protocol value=vrrp accept"
done

if [[ "${RESTRICT_SSH:-0}" == "1" ]]; then
  rich "rule family=ipv4 source address=${MGMT_CIDR} service name=ssh accept"
  fw --zone="$ZONE" --remove-service=ssh || true
  echo "SSH now limited to ${MGMT_CIDR}"
fi

firewall-cmd --reload >/dev/null
firewall-cmd --zone="$ZONE" --list-all
