#!/bin/bash
# Records the keepalived VRRP state as Prometheus metrics for the
# node_exporter textfile collector.
#
# install.sh puts it at /usr/local/libexec/keepalived/notify-metrics.sh.
# haproxy/keepalived/notify.sh (the notify script keepalived.conf already
# names) must pass its arguments on, with this line before its exit:
#
#     /usr/local/libexec/keepalived/notify-metrics.sh "$@"
#
# Arguments, as keepalived passes them to notify scripts:
#     INSTANCE|GROUP <name> MASTER|BACKUP|FAULT|STOP <priority>

TYPE=$1 NAME=$2 STATE=$3 PRIORITY=${4:-0}
DIR=/var/lib/node_exporter/textfile_collector
STATE_DIR=/var/lib/keepalived-notify

[ "$TYPE" = INSTANCE ] || exit 0
mkdir -p "$STATE_DIR" "$DIR"

# One small state file per instance, so several instances can share the output.
printf '%s %s %s\n' "$STATE" "$PRIORITY" "$(date +%s)" >"${STATE_DIR}/${NAME}"

tmp=$(mktemp "${DIR}/.keepalived.prom.XXXXXX")
{
  echo '# HELP keepalived_vrrp_master 1 if this node is VRRP MASTER for the instance (holds the VIP).'
  echo '# TYPE keepalived_vrrp_master gauge'
  echo '# HELP keepalived_vrrp_state_info Current VRRP state of the instance; the series with value 1 is current.'
  echo '# TYPE keepalived_vrrp_state_info gauge'
  echo '# HELP keepalived_vrrp_priority Priority reported at the last transition.'
  echo '# TYPE keepalived_vrrp_priority gauge'
  echo '# HELP keepalived_vrrp_last_transition_timestamp_seconds Time of the last VRRP state change.'
  echo '# TYPE keepalived_vrrp_last_transition_timestamp_seconds gauge'
  for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    inst=$(basename "$f")
    read -r st prio ts <"$f"
    echo "keepalived_vrrp_master{vrrp_instance=\"${inst}\"} $([ "$st" = MASTER ] && echo 1 || echo 0)"
    for s in MASTER BACKUP FAULT STOP; do
      echo "keepalived_vrrp_state_info{vrrp_instance=\"${inst}\",state=\"${s}\"} $([ "$st" = "$s" ] && echo 1 || echo 0)"
    done
    echo "keepalived_vrrp_priority{vrrp_instance=\"${inst}\"} ${prio}"
    echo "keepalived_vrrp_last_transition_timestamp_seconds{vrrp_instance=\"${inst}\"} ${ts}"
  done
} >"$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "${DIR}/keepalived.prom"
