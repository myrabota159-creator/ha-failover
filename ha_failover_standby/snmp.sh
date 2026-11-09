#!/bin/bash
# SNMPv3 port control on the managed switch (IF-MIB ifAdminStatus 1=up 2=down; ifIndex = port number).
#   snmp-test                 -> read state of the primary port and the test port, changes nothing
#   port-test I-UNDERSTAND    -> disable the TEST port, verify, enable it again, verify
#   pi-port-up I-UNDERSTAND   -> enable the primary port again (only if this node does not hold the primary address)
set -uo pipefail
. /lib.sh
MODE="${1:-}"; CONFIRM="${2:-}"
[ -n "$SW" ] && [ -n "$U" ] || { echo "ABORT: switch_host / snmp_user not set in add-on options"; exit 1; }
[ -n "$A" ] && [ -n "$X" ] || { echo "ABORT: snmp_auth_pass / snmp_priv_pass not set in add-on options"; exit 1; }
[ "${PIP:-0}" != 0 ] || { echo "ABORT: primary_switch_port not set"; exit 1; }
get(){ snmpget "${SNMP[@]}" "$SW" "$1" 2>&1; }
port_state(){ # $1 port -> "admin oper descr"
  echo "port $1: admin=$(get 1.3.6.1.2.1.2.2.1.7.$1) oper=$(get 1.3.6.1.2.1.2.2.1.8.$1) descr=$(get 1.3.6.1.2.1.2.2.1.2.$1)"
}
case "$MODE" in
snmp-test)
  echo "switch $SW, user $U, primary port $PIP, test port ${TP:-not set}"
  port_state "$PIP"; [ "${TP:-0}" != 0 ] && port_state "$TP" ;;
port-test)
  [ "$CONFIRM" = "I-UNDERSTAND" ] || { echo "ABORT: confirmation word missing"; exit 1; }
  [ "${TP:-0}" != 0 ] || { echo "ABORT: test_switch_port not set"; exit 1; }
  [ "$TP" != "$PIP" ] || { echo "ABORT: test port equals primary port"; exit 1; }
  before=$(get 1.3.6.1.2.1.2.2.1.8.$TP)
  echo "test port $TP before: $(port_state "$TP")"
  is_down "$before" || { echo "ABORT: test port $TP has link ($before), not free"; exit 1; }
  echo "set port $TP down: $(port_set "$TP" 2)"; sleep 2
  echo "after down: $(port_state "$TP")"
  echo "set port $TP up: $(port_set "$TP" 1)"; sleep 2
  echo "after up: $(port_state "$TP")"
  echo "primary port unchanged: $(port_state "$PIP")" ;;
pi-port-up)
  [ "$CONFIRM" = "I-UNDERSTAND" ] || { echo "ABORT: confirmation word missing"; exit 1; }
  holds_pi_ip && { echo "ABORT: this node holds $PI, run standby first"; exit 1; }
  echo "before: $(port_state "$PIP")"
  echo "set port $PIP up: $(port_set "$PIP" 1)"; sleep 3
  echo "after: $(port_state "$PIP")" ;;
*) echo "usage: snmp-test | port-test I-UNDERSTAND | pi-port-up I-UNDERSTAND" ;;
esac
