#!/bin/bash
# Watchdog: detects that the primary is gone and, in "armed" mode, isolates it (SNMP: port down) and runs failover.
# Modes (option watchdog_mode): off | observe (log only) | armed.
# Level 1: primary counts as DOWN only if ping and all probe ports (HA, SSH, extra) are silent (watchdog_fail_seconds).
# Level 2: primary answers, but its HA does not serve /manifest.json (ha_fail_seconds, mode ha_check_mode).
# Both levels act only if this node itself sees the gateway, the switch (SNMP) and every required_hosts entry,
# and only after the primary port is confirmed down.
set -uo pipefail
. /lib.sh
ST=$R/watchdog.json
MODE=$(opt .watchdog_mode); MODE=${MODE:-off}; LIMIT=$(opt .watchdog_fail_seconds)
HA_MODE=$(opt .ha_check_mode); HA_MODE=${HA_MODE:-observe}; HA_LIMIT=$(opt .ha_fail_seconds)
mapfile -t REQUIRED < <(jq -r '.required_hosts[]?' "$O")   # "host" (ping) or "host:port" (ping or TCP)
STEP=10; GRACE=300
log(){ echo "$*"; }
ha_ok(){ [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$PI:$HA_PORT/manifest.json" 2>/dev/null)" = 200 ]; }
pi_alive(){ local p; ping1 "$PI" && return 0; for p in $(pi_alive_ports); do tcp "$PI" "$p" && return 0; done; return 1; }
vm_net_ok(){ # prints the failing check, returns 1 if this node itself has a problem
  local h p
  [ -n "$GW" ] && { ping1 "$GW" || { echo "gateway $GW"; return 1; }; }
  for h in "${REQUIRED[@]}"; do
    p=""; case "$h" in *:*) p=${h##*:}; h=${h%:*} ;; esac
    ping1 "$h" || { [ -n "$p" ] && tcp "$h" "$p"; } || { echo "required host $h"; return 1; }
  done
  [ -n "$(port_admin "$PIP")" ] || { echo "switch SNMP $SW"; return 1; }
  return 0
}
state(){ jq -n --arg m "$MODE" --arg s "$1" --arg d "$2" --argjson f "$3" --arg t "$(date -u +%FT%TZ)" \
  '{mode:$m, state:$s, detail:$d, pi_silent_seconds:$f, checked_utc:$t}' > "$ST.tmp" && mv "$ST.tmp" "$ST"; }

isolate_and_failover(){ # $1 = human reason (goes into the push); returns after failover or refusal
  log "$1: disabling switch port $PIP"
  port_set "$PIP" 2 >/dev/null
  local ok="" a o i
  for i in 1 2 3 4 5; do sleep 2; a=$(port_admin "$PIP"); o=$(port_oper "$PIP"); log "port $PIP: admin=$a oper=$o"
    if is_down "$a" && is_down "$o"; then ok=1; break; fi
  done
  if [ -z "$ok" ]; then
    log "ERROR: port $PIP not confirmed down, NO failover; retry next round"; state error "port not confirmed down" 0
  elif pi_alive; then
    log "primary answers after port down (another path?), NO failover; enabling port $PIP back"
    port_set "$PIP" 1 >/dev/null
  else
    log "port $PIP confirmed down, starting failover"; state failover "port down, failover running" 0
    /failover.sh failover I-UNDERSTAND "$1" 2>&1 | while IFS= read -r l; do log "[failover] $l"; done
  fi
}

log "start: mode=$MODE, limit ${LIMIT}s; HA check $HA_MODE, limit ${HA_LIMIT}s; grace ${GRACE}s, primary $PI on switch $SW port $PIP"
[ "$MODE" = off ] && { state off "watchdog disabled" 0; exec sleep infinity; }
for v in PI SW U A X; do [ -n "${!v}" ] || { log "option for $v not set, watchdog idle"; state error "incomplete options" 0; exec sleep infinity; }; done
[ "${PIP:-0}" != 0 ] || { log "primary_switch_port not set, watchdog idle"; state error "incomplete options" 0; exec sleep infinity; }
sleep "$GRACE"
GW=$(gateway); log "gateway for own network check: ${GW:-none}, required hosts: ${REQUIRED[*]:-none}"
silent=0; hadead=0; diag_at=-999; last=$(date +%s); prev=""
while true; do
  now=$(date +%s); gap=$((now-last)); last=$now
  if [ "$gap" -gt $((STEP*6)) ] || [ "$gap" -lt 0 ]; then
    log "clock jump or stall (${gap}s between checks), counters reset"; silent=0; hadead=0
  fi
  if [ -e "$R/BLOCKED" ]; then cur="blocked"; silent=0; hadead=0; state blocked "BLOCKED present, watchdog idle" 0
    # While this node holds the primary address, keep the primary port disabled
    # (a switch reboot re-enables it: an SNMP set is usually not saved to the startup config).
    if holds_pi_ip; then
      a=$(port_admin "$PIP")
      if is_up "$a"; then
        log "GUARD: this node holds $PI but switch port $PIP is UP (switch reboot?), disabling it again"
        port_set "$PIP" 2 >/dev/null
        sleep 2; log "GUARD: port $PIP admin=$(port_admin "$PIP") oper=$(port_oper "$PIP")"
        notify_bg "$(msg guard_title)" "$(msg guard_body "$(local_time)" "$PIP")" 60
      elif [ -z "$a" ]; then cur="blocked-noswitch"
      else cur="blocked-guarding"; fi
    fi
  elif pi_alive; then silent=0
    if [ "$HA_MODE" = off ] || ha_ok; then cur="pi-ok"; hadead=0; diag_at=-999; state ok "primary and its HA answer" 0
    else
      hadead=$((hadead+gap)); cur="ha-down"; state ha-down "primary answers, HA does not serve /manifest.json" "$hadead"
      if [ $((hadead - diag_at)) -ge 60 ]; then diag_at=$hadead; log "HA on primary not answering for ${hadead}s; health: $(pi_health 30 2>/dev/null | head -c 300)"; fi
    fi
  elif bad=$(vm_net_ok); then
    hadead=0; silent=$((silent+gap)); cur="pi-silent"; state pi-silent "primary silent, own network fine" "$silent"
  else cur="vm-net:$bad"; silent=0; hadead=0; state vm-network "this node cannot reach $bad; not blaming the primary" 0
  fi
  [ "$cur" != "$prev" ] && log "state: $cur"; prev=$cur
  if [ "$silent" -ge "$LIMIT" ]; then
    if [ "$MODE" != armed ]; then
      log "OBSERVE: primary silent ${silent}s >= ${LIMIT}s, armed mode would now disable port $PIP and fail over"
    else
      isolate_and_failover "$(msg reason_silent "$PI" "$silent")"
    fi
    silent=0
  fi
  if [ "$hadead" -ge "$HA_LIMIT" ]; then
    if ! bad=$(vm_net_ok); then log "HA dead ${hadead}s, but own network problem ($bad): no action"
    elif [ "$MODE" = armed ] && [ "$HA_MODE" = armed ]; then
      isolate_and_failover "$(msg reason_ha_dead "$hadead")"
    else
      log "OBSERVE-HA: HA on primary dead ${hadead}s >= ${HA_LIMIT}s (node answers ping), armed HA check would now disable port $PIP and fail over"
    fi
    hadead=0; diag_at=-999
  fi
  sleep "$STEP"
done
