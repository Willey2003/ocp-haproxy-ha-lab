#!/usr/bin/env bash
# SELinux prep for HAProxy + keepalived. Keeps SELinux ENFORCING.
# Idempotent: safe to re-run. Run as root on lb1 and lb2.
#
# HAProxy (haproxy_t) may only bind/connect to ports labelled for it, and
# 6443, 22623, 9000 and 8405 are not labelled out of the box. Two options:
#   MODE=ports   (default) label just those ports http_port_t. Least privilege.
#   MODE=boolean set haproxy_connect_any=on, which lets HAProxy use ANY port.
#                This is what the OpenShift UPI docs show; simpler, broader.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${here}/../inventory.env"
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
MODE="${MODE:-ports}"

mode="$(getenforce)"
if [[ "$mode" != "Enforcing" ]]; then
  echo "WARNING: SELinux is ${mode}. Production LBs should be Enforcing." >&2
  echo "  Set SELINUX=enforcing in /etc/selinux/config (and relabel if it was Disabled)." >&2
fi

command -v semanage >/dev/null || dnf install -y policycoreutils-python-utils

label_port() { # port
  local port="$1" current
  current="$(semanage port -l | awk -v p="$port" '$2=="tcp" && (","$0",") ~ "[ ,]"p"[,]" {print $1}' | head -n1)"
  if [[ -z "$current" ]]; then
    semanage port -a -t http_port_t -p tcp "$port" && echo "labelled tcp/${port} http_port_t"
  elif [[ "$current" == "http_port_t" ]]; then
    echo "tcp/${port} already http_port_t"
  else
    echo "tcp/${port} is owned by ${current} in base policy; not relabelling." >&2
    echo "  Re-run with MODE=boolean, or move that listener to another port." >&2
    return 1
  fi
}

case "$MODE" in
  ports)
    setsebool -P haproxy_connect_any off
    for p in "$PORT_API" "$PORT_MCS" "$PORT_STATS" "$PORT_METRICS" "$PORT_ROUTER_HEALTH"; do
      label_port "$p"
    done ;;
  boolean)
    setsebool -P haproxy_connect_any on
    echo "haproxy_connect_any=on" ;;
  *) echo "MODE must be ports or boolean" >&2; exit 2 ;;
esac

# Config files copied from elsewhere keep the wrong context; fix them.
for d in /etc/haproxy /etc/keepalived /etc/sysctl.d; do
  [[ -d "$d" ]] && restorecon -R "$d"
done

echo "Recent HAProxy/keepalived AVC denials (should be none):"
ausearch -m AVC,USER_AVC -ts recent -c haproxy 2>/dev/null || true
ausearch -m AVC,USER_AVC -ts recent -c keepalived 2>/dev/null || true
