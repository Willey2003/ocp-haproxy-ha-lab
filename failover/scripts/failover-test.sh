#!/usr/bin/env bash
# Run one failover scenario end to end: precheck, start the probe, break
# something, wait for the expected state, restore, wait for steady state,
# and grade the client-visible outage.
#
#   ./failover-test.sh baseline
#   ./failover-test.sh lb-haproxy-stop
#   ./failover-test.sh lb-keepalived-stop
#   ./failover-test.sh lb-crash
#   ./failover-test.sh vrrp-block
#   ./failover-test.sh master-reboot <node> [--hard]
#   ./failover-test.sh infra-reboot  <node> [--hard]
#   ./failover-test.sh router-pod-delete <node>
#
# Add --yes to skip the confirmation prompt. See ../RUNBOOK.md for what each
# scenario proves and how to run it by hand.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

SCENARIO=${1:-}; [[ -n $SCENARIO ]] || usage; shift
NODE=""; HARD=0
for arg in "$@"; do
  case $arg in
    --hard) HARD=1 ;;
    --yes)  ASSUME_YES=1 ;;
    -*)     usage ;;
    *)      NODE=$arg ;;
  esac
done

RESULTS_DIR="$FAILOVER_DIR/results/$(date +%Y%m%d-%H%M%S)-${SCENARIO}"
mkdir -p "$RESULTS_DIR"
exec > >(tee -a "$RESULTS_DIR/summary.txt") 2>&1
FAILURES=0
RESTORE_CMDS=()

restore() {
  local cmd
  for cmd in "${RESTORE_CMDS[@]}"; do
    log "restore: $cmd"
    eval "$cmd" || log "restore step failed: $cmd"
  done
  RESTORE_CMDS=()
}
cleanup() { restore; stop_probe; }
trap cleanup EXIT

# --- Prechecks ---------------------------------------------------------------
lb_steady() {
  local holder
  holder=$(vip_holder)
  [[ $holder == "$LB1" || $holder == "$LB2" ]] || return 1
  for lb in "$LB1" "$LB2"; do
    [[ $(ssh_lb "$lb" "systemctl is-active haproxy keepalived" | sort -u) == active ]] || return 1
  done
}

backends_full() {
  local lb=$1
  [[ $(backend_active "$lb" "$HAPROXY_API_BACKEND")   -ge $EXPECTED_MASTERS ]] 2>/dev/null &&
  [[ $(backend_active "$lb" "$HAPROXY_MCS_BACKEND")   -ge $EXPECTED_MASTERS ]] 2>/dev/null &&
  [[ $(backend_active "$lb" "$HAPROXY_HTTPS_BACKEND") -ge $EXPECTED_INFRA ]]   2>/dev/null &&
  [[ $(backend_active "$lb" "$HAPROXY_HTTP_BACKEND")  -ge $EXPECTED_INFRA ]]   2>/dev/null
}

cluster_healthy() {
  local ready bad
  ready=$(oc get nodes --no-headers | awk '$2 == "Ready"' | wc -l)
  [[ $ready -ge $((EXPECTED_MASTERS + EXPECTED_INFRA)) ]] || { log "  only $ready nodes Ready"; return 1; }
  bad=$(oc get co etcd kube-apiserver ingress --no-headers | awk '$3 != "True" || $5 != "False"')
  [[ -z $bad ]] || { log "  unhealthy operators:"; echo "$bad"; return 1; }
}

routers_ready() {
  local ready
  ready=$(oc -n openshift-ingress get deploy router-default -o jsonpath='{.status.readyReplicas}')
  [[ ${ready:-0} -ge $EXPECTED_INFRA ]]
}

precheck() {
  log "precheck"
  lb_steady || die "LB pair not steady (VIP holder: $(vip_holder)). Run lb-status.sh."
  for lb in "$LB1" "$LB2"; do
    backends_full "$lb" || die "HAProxy on $lb does not see every backend server UP. Run lb-status.sh."
  done
  "$FAILOVER_DIR/scripts/lb-status.sh" >"$RESULTS_DIR/lb-status-before.txt" 2>&1 || true
}

node_role_is() {
  local node=$1 role=$2
  oc get node "$node" -o jsonpath='{.metadata.labels}' | grep -q "node-role.kubernetes.io/${role}"
}

# --- Actions -----------------------------------------------------------------
node_exec() {
  local node=$1; shift
  timeout 60 oc debug "node/$node" -q -- chroot /host sh -c "$*" || true
}

crash_node_cmd='echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger'

node_ready() { oc get node "$1" --no-headers 2>/dev/null | awk '{ exit !($2 == "Ready") }'; }
node_not_ready() { ! node_ready "$1"; }
holder_is() { [[ $(vip_holder) == "$1" ]]; }
holder_is_not() { local h; h=$(vip_holder); [[ $h != "$1" && $h != none && $h != both ]]; }
holder_is_both() { [[ $(vip_holder) == both ]]; }
active_eq() { [[ $(backend_active "$1" "$2") == "$3" ]]; }

finish() {
  local limit=$1; shift
  sleep 10
  stop_probe
  "$FAILOVER_DIR/scripts/lb-status.sh" >"$RESULTS_DIR/lb-status-after.txt" 2>&1 || true
  log "probe summary:"
  summarize_probe >/dev/null
  local t
  for t in "$@"; do check_outage "$t" "$limit"; done
  if (( FAILURES == 0 )); then
    log "RESULT: PASS  ($RESULTS_DIR)"
  else
    log "RESULT: FAIL  ($FAILURES check(s) failed, see $RESULTS_DIR)"
    exit 1
  fi
}

# vrrp_rule add|remove [extra firewall-cmd args] on the standby LB, in the
# firewalld zone of LB_IFACE (the same zone prep/firewall/lb-firewalld.sh uses).
vrrp_rule() {
  local action=$1; shift
  ssh_lb "$STANDBY" "zone=\$(sudo firewall-cmd --get-zone-of-interface=${LB_IFACE} 2>/dev/null || sudo firewall-cmd --get-default-zone);
    sudo firewall-cmd --zone=\$zone --${action}-rich-rule='rule protocol value=\"vrrp\" drop' $*"
}

ALL_TARGETS=(api mcs ingress-https ingress-http)

# --- Scenarios ---------------------------------------------------------------
case $SCENARIO in
  baseline)
    precheck
    cluster_healthy || fail "cluster not healthy"
    start_probe
    log "probing for 60s with nothing broken"
    sleep 60
    finish 0 "${ALL_TARGETS[@]}"
    ;;

  lb-haproxy-stop|lb-keepalived-stop|lb-crash)
    precheck
    HOLDER=$(vip_holder); STANDBY=$(other_lb "$HOLDER")
    log "VIP holder is $HOLDER, standby is $STANDBY"
    case $SCENARIO in
      lb-haproxy-stop)
        confirm "Stop haproxy on $HOLDER (the VIP holder)?"
        start_probe
        RESTORE_CMDS+=("ssh_lb $HOLDER 'sudo systemctl start haproxy'")
        log "stopping haproxy on $HOLDER"
        ssh_lb "$HOLDER" "sudo systemctl stop haproxy" ;;
      lb-keepalived-stop)
        confirm "Stop keepalived on $HOLDER (the VIP holder)?"
        start_probe
        RESTORE_CMDS+=("ssh_lb $HOLDER 'sudo systemctl start keepalived'")
        log "stopping keepalived on $HOLDER"
        ssh_lb "$HOLDER" "sudo systemctl stop keepalived" ;;
      lb-crash)
        confirm "Crash-reboot $HOLDER with sysrq (no clean shutdown)?"
        start_probe
        log "crashing $HOLDER"
        ssh_lb "$HOLDER" "sudo sh -c '$crash_node_cmd'" || true ;;
    esac
    wait_for "$WAIT_TIMEOUT" "VIP moves to $STANDBY" holder_is "$STANDBY" || true
    sleep 20
    restore
    if [[ $SCENARIO == lb-crash ]]; then
      wait_for 600 "$HOLDER back with haproxy and keepalived active" \
        bash -c "ssh -o BatchMode=yes -o ConnectTimeout=5 ${LB_SSH_USER}@${HOLDER} 'systemctl is-active haproxy keepalived' >/dev/null" || true
    fi
    wait_for "$WAIT_TIMEOUT" "LB pair steady again" lb_steady || true
    log "VIP now on $(vip_holder) (moves back to $HOLDER only if keepalived preempts)"
    finish "$MAX_VIP_FAILOVER_OUTAGE" "${ALL_TARGETS[@]}"
    ;;

  vrrp-block)
    precheck
    HOLDER=$(vip_holder); STANDBY=$(other_lb "$HOLDER")
    confirm "Drop VRRP on $STANDBY for 90s? Both LBs will claim the VIP (split brain) until it expires."
    start_probe
    log "dropping inbound VRRP on $STANDBY for 90s (firewalld removes the rule itself)"
    vrrp_rule add --timeout=90
    RESTORE_CMDS+=("vrrp_rule remove || true")
    if wait_for 30 "both LBs hold the VIP (split brain reproduced)" holder_is_both; then
      pass "split brain reproduced; KeepalivedSplitBrain should fire within 1m"
    fi
    log "holding 60s so the alert can fire; check Alertmanager now"
    sleep 60
    restore
    wait_for "$WAIT_TIMEOUT" "exactly one VIP holder again" lb_steady || true
    # A split brain causes ARP flapping; this scenario reports the outage but
    # grades only that the pair recovers.
    finish 9000 "${ALL_TARGETS[@]}"
    ;;

  master-reboot|infra-reboot)
    [[ -n $NODE ]] || usage
    if [[ $SCENARIO == master-reboot ]]; then
      node_role_is "$NODE" master || die "$NODE is not a master"
      BACKENDS=("$HAPROXY_API_BACKEND" "$HAPROXY_MCS_BACKEND"); FULL=$EXPECTED_MASTERS
    else
      node_role_is "$NODE" infra || die "$NODE is not an infra node"
      routers_ready || die "router-default does not have $EXPECTED_INFRA ready replicas"
      BACKENDS=("$HAPROXY_HTTPS_BACKEND" "$HAPROXY_HTTP_BACKEND"); FULL=$EXPECTED_INFRA
    fi
    precheck
    cluster_healthy || die "cluster not healthy; never take a node down on a degraded cluster"
    HOLDER=$(vip_holder)
    if (( HARD )); then
      confirm "Crash-reboot $NODE with sysrq (ungraceful)?"
    else
      confirm "Drain and reboot $NODE?"
    fi
    start_probe
    RESTORE_CMDS+=("oc adm uncordon $NODE")
    if (( HARD )); then
      log "crashing $NODE"
      node_exec "$NODE" "$crash_node_cmd"
    else
      log "draining $NODE"
      oc adm drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=600s
      log "rebooting $NODE"
      node_exec "$NODE" "systemctl reboot"
    fi
    for b in "${BACKENDS[@]}"; do
      wait_for "$WAIT_TIMEOUT" "HAProxy marks $NODE down in $b" active_eq "$HOLDER" "$b" $((FULL - 1)) || true
    done
    wait_for "$WAIT_TIMEOUT" "$NODE NotReady" node_not_ready "$NODE" || true
    wait_for "$NODE_WAIT_TIMEOUT" "$NODE Ready again" node_ready "$NODE" || true
    restore
    for b in "${BACKENDS[@]}"; do
      wait_for "$NODE_WAIT_TIMEOUT" "HAProxy marks $NODE up in $b" active_eq "$HOLDER" "$b" "$FULL" || true
    done
    [[ $SCENARIO == infra-reboot ]] && { wait_for "$WAIT_TIMEOUT" "routers ready" routers_ready || true; }
    wait_for "$NODE_WAIT_TIMEOUT" "cluster operators healthy" cluster_healthy || true
    finish "$MAX_BACKEND_LOSS_OUTAGE" "${ALL_TARGETS[@]}"
    ;;

  router-pod-delete)
    [[ -n $NODE ]] || usage
    routers_ready || die "router-default does not have $EXPECTED_INFRA ready replicas"
    precheck
    POD=$(oc -n openshift-ingress get pods -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
      --field-selector "spec.nodeName=$NODE" -o name | head -1)
    [[ -n $POD ]] || die "no router pod on $NODE"
    confirm "Delete $POD on $NODE?"
    start_probe
    log "deleting $POD"
    oc -n openshift-ingress delete "$POD" --wait=false
    wait_for "$WAIT_TIMEOUT" "routers ready again" routers_ready || true
    wait_for "$WAIT_TIMEOUT" "HAProxy sees both routers" active_eq "$(vip_holder)" "$HAPROXY_HTTPS_BACKEND" "$EXPECTED_INFRA" || true
    finish "$MAX_BACKEND_LOSS_OUTAGE" "${ALL_TARGETS[@]}"
    ;;

  *) usage ;;
esac
