#!/usr/bin/env bash
# Shared helpers for the failover scripts. Sourced, not executed.
# Variables defined here are used by the scripts that source it.
# shellcheck disable=SC2034

set -o errexit -o nounset -o pipefail

FAILOVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${LAB_ENV:-$FAILOVER_DIR/lab.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy lab.env.example to lab.env and edit it." >&2
  exit 2
fi
# shellcheck source=../lab.env.example
source "$ENV_FILE"

API_HOST="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
API_INT_HOST="api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
CANARY_HOST="canary-openshift-ingress-canary.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
pass() { log "PASS  $*"; }
fail() { log "FAIL  $*"; FAILURES=$((${FAILURES:-0} + 1)); }
die()  { log "ERROR $*"; exit 1; }

ssh_lb() {
  local host=$1; shift
  timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 \
    "${LB_SSH_USER}@${host}" "$@"
}

# Prints LB1 or LB2 for whichever holds the VIP, "none", or "both" (split brain).
vip_holder() {
  local holders=() h
  for h in "$LB1" "$LB2"; do
    if ssh_lb "$h" "ip -o -4 addr show | grep -qw '${VIP}'" 2>/dev/null; then
      holders+=("$h")
    fi
  done
  case ${#holders[@]} in
    0) echo none ;;
    1) echo "${holders[0]}" ;;
    *) echo both ;;
  esac
}

other_lb() { [[ $1 == "$LB1" ]] && echo "$LB2" || echo "$LB1"; }

# UP state (1/0) of one server in one backend, read from an LB's metrics endpoint.
server_up() {
  local lb=$1 backend=$2 server=$3
  curl -s --max-time 3 "http://${lb}:${HAPROXY_METRICS_PORT}/metrics" |
    awk -v p="$backend" -v s="$server" '
      $1 ~ /^haproxy_server_status\{/ && index($1, "proxy=\"" p "\"") &&
      index($1, "server=\"" s "\"") && index($1, "state=\"UP\"") { print $2; found=1 }
      END { if (!found) print "missing" }'
}

# Number of UP servers in a backend.
backend_active() {
  local lb=$1 backend=$2
  curl -s --max-time 3 "http://${lb}:${HAPROXY_METRICS_PORT}/metrics" |
    awk -v p="$backend" '
      $1 ~ /^haproxy_backend_active_servers\{/ && index($1, "proxy=\"" p "\"") { print $2; found=1 }
      END { if (!found) print "missing" }'
}

# wait_for <timeout-seconds> <description> <command...>
wait_for() {
  local timeout=$1 desc=$2; shift 2
  local start=$SECONDS
  log "waiting (<= ${timeout}s): $desc"
  until "$@"; do
    if (( SECONDS - start >= timeout )); then
      fail "timed out after ${timeout}s: $desc"
      return 1
    fi
    sleep 1
  done
  log "  ok after $((SECONDS - start))s: $desc"
}

confirm() {
  [[ ${ASSUME_YES:-0} == 1 ]] && return 0
  read -r -p "$* Type 'yes' to continue: " answer
  [[ $answer == yes ]] || die "aborted"
}

# --- Probe control -----------------------------------------------------------
PROBE_PID=""
start_probe() {
  PROBE_LOG="${RESULTS_DIR}/probe.csv"
  "$FAILOVER_DIR/scripts/probe.sh" >"$PROBE_LOG" &
  PROBE_PID=$!
  log "probe running (pid $PROBE_PID) -> $PROBE_LOG"
  sleep 5
}

stop_probe() {
  if [[ -n $PROBE_PID ]]; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=""
  fi
}

# Prints "<target> <longest outage seconds>" per target, and a table to stderr.
summarize_probe() {
  "$FAILOVER_DIR/scripts/probe-summary.sh" "$PROBE_LOG"
}

# max_outage <target>  -> longest client-visible outage in seconds for that target
max_outage() {
  summarize_probe 2>/dev/null | awk -v t="$1" '$1 == t { print $2 }'
}

# check_outage <target> <limit-seconds>
check_outage() {
  local target=$1 limit=$2 got
  got=$(max_outage "$target")
  got=${got:-0}
  if awk -v g="$got" -v l="$limit" 'BEGIN { exit !(g <= l) }'; then
    pass "$target longest outage ${got}s (limit ${limit}s)"
  else
    fail "$target longest outage ${got}s (limit ${limit}s)"
  fi
}
