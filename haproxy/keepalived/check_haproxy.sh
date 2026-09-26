#!/bin/bash
# keepalived VRRP check: healthy only if HAProxy is running AND answering
# its local monitor endpoint (catches a hung process, not just a dead one).
# Exit 0 = healthy, non-zero = keepalived drops this node to FAULT and the
# VIP moves to the peer.
/usr/bin/curl --silent --fail --max-time 2 -o /dev/null http://127.0.0.1:9000/healthz
