#!/bin/bash
# Called by keepalived on every VRRP state change.
# Args: $1=GROUP|INSTANCE  $2=name  $3=MASTER|BACKUP|FAULT|STOP  $4=priority
# Logs to the journal (tag: keepalived-notify) so failovers are auditable:
#   journalctl -t keepalived-notify
/usr/bin/logger -t keepalived-notify -p daemon.notice \
  "VRRP $1 $2 changed to $3 (priority ${4:-n/a}) on $(hostname -s)"
exit 0
