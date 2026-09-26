#!/bin/bash
# Offline syntax check of every config in this directory.
# Run on a workstation or an LB before copying files into /etc.
set -euo pipefail
cd "$(dirname "$0")"

echo "== haproxy.cfg"
haproxy -c -f haproxy.cfg

# keepalived -t checks that the interface and scripts exist on this host.
# Test a temp copy that points at the scripts in this repo and, when the
# configured NIC is missing (e.g. validating on a laptop), at this host's
# first ARP-capable interface. The scripts are copied into the temp dir so
# keepalived's script-security check (no writable parent dirs) passes.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
install -m 755 keepalived/*.sh "$tmp/"
for n in lb1 lb2; do
  cfg="keepalived/keepalived-$n.conf"
  echo "== $cfg"
  iface=$(awk '$1=="interface"{print $2; exit}' "$cfg")
  use_if=$iface
  if ! ip link show "$iface" >/dev/null 2>&1; then
    use_if=$(ip -o link show | awk -F': ' '!/NOARP|LOOPBACK/ && /link\/ether/ {sub(/@.*/,"",$2); print $2; exit}')
    echo "   ($iface not on this host, testing with $use_if)"
  fi
  sed -e "s/\b$iface\b/$use_if/g" -e "s#/etc/keepalived/#$tmp/#g" "$cfg" > "$tmp/$n.conf"
  keepalived -t -l -D -f "$tmp/$n.conf"
done
echo "All configs valid."
