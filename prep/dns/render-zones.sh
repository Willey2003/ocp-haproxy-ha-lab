#!/usr/bin/env bash
# Render BIND zone files from inventory.env and validate them.
# Usage: dns/render-zones.sh [output_dir]   (default: dns/out)
# Needs: envsubst (gettext), and optionally named-checkzone (bind-utils/bind).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Export everything inventory.env defines so envsubst can see it.
set -a
# shellcheck source=/dev/null
source "${here}/../inventory.env"
set +a
out="${1:-${here}/out}"
mkdir -p "$out"

last_octet() { echo "${1##*.}"; }
export SERIAL="${SERIAL:-$(date +%Y%m%d)01}"
for v in DNS1 DNS2 LB1 LB2 BOOTSTRAP MASTER0 MASTER1 MASTER2 INFRA0 INFRA1; do
  ip_var="${v}_IP"; export "${v}_OCTET=$(last_octet "${!ip_var}")"
done
LB_VIP_OCTET="$(last_octet "$LB_VIP")"; export LB_VIP_OCTET

# Only substitute our own variables, so BIND's $TTL / $ORIGIN survive rendering.
vars="\${SERIAL} \${LB_VIP_OCTET}"
while IFS= read -r name; do vars+=" \${${name}}"; done \
  < <(grep -v '^[[:space:]]*#' "${here}/../inventory.env" | grep -oE '[A-Z][A-Z0-9_]*=' | tr -d '=')
for v in DNS1 DNS2 LB1 LB2 BOOTSTRAP MASTER0 MASTER1 MASTER2 INFRA0 INFRA1; do
  vars+=" \${${v}_OCTET}"
done

render() { envsubst "$vars" < "$1" > "$2"; echo "rendered $2"; }
render "${here}/bind/db.cluster.zone.tmpl" "${out}/db.${CLUSTER_DOMAIN}"
render "${here}/bind/db.reverse.zone.tmpl" "${out}/db.${REVERSE_ZONE}"
render "${here}/bind/named.conf.ocp.tmpl"  "${out}/ocp-zones.conf"

if command -v named-checkzone >/dev/null; then
  named-checkzone "$CLUSTER_DOMAIN" "${out}/db.${CLUSTER_DOMAIN}"
  named-checkzone "$REVERSE_ZONE"   "${out}/db.${REVERSE_ZONE}"
else
  echo "named-checkzone not found; install bind to validate before deploying" >&2
fi
cat <<MSG

Install on the DNS primary:
  sudo cp ${out}/db.* /var/named/ && sudo chown root:named /var/named/db.* && sudo chmod 640 /var/named/db.*
  sudo restorecon -Rv /var/named
  sudo cp ${out}/ocp-zones.conf /etc/named/ocp-zones.conf && sudo restorecon -v /etc/named/ocp-zones.conf
  sudo named-checkconf && sudo systemctl reload named
MSG
