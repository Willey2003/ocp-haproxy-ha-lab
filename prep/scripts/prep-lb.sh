#!/usr/bin/env bash
# One-shot prep of a load balancer node (run as root on lb1, then lb2):
# sysctl -> SELinux -> firewalld -> read-only verification.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
install -m 0644 "${here}/sysctl/90-ocp-lb.conf" /etc/sysctl.d/90-ocp-lb.conf
sysctl --system >/dev/null
"${here}/selinux/lb-selinux.sh"
"${here}/firewall/lb-firewalld.sh"
"${here}/scripts/verify-lb-host.sh"
