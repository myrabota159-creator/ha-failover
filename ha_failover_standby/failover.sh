#!/bin/bash
# Manual failover of the standby node to the primary role.
#   dry-run                -> checks and plan only, changes nothing
#   failover I-UNDERSTAND  -> real failover (aborts if the primary answers anything)
#   standby-dry            -> checks and plan for returning this node to standby, changes nothing
#   standby I-UNDERSTAND   -> return this node to standby: stop everything, restore its own config, DHCP
#   unblock-dry / unblock I-UNDERSTAND -> remove BLOCKED once the primary is primary again
#   resume-primary I-UNDERSTAND [reason] -> (used by return.sh) primary role again from the latest primary-<ts>.tgz
set -uo pipefail
. /lib.sh
SV_TIMEOUT=600
MODE="${1:-}"; CONFIRM="${2:-}"
W=""
api(){ sv "$@"; }
say(){ echo "$*"; }
fail(){ echo "ABORT: $*"; [ -n "$W" ] && rm -rf "$W"; exit 1; }

check_pi(){ # returns 0 if the primary is completely silent
  local alive="" p
  [ -n "$PI" ] || { say "primary_host not set"; return 1; }
  ping -c 2 -W 2 "$PI" >/dev/null 2>&1 && alive="$alive ping"
  for p in $(pi_alive_ports); do tcp "$PI" "$p" && alive="$alive $p"; done
  if [ -n "$alive" ]; then say "primary $PI ANSWERS:$alive"; return 1; fi
  say "primary $PI silent (ping, $(pi_alive_ports))"; return 0
}

prepare(){ # extract the latest snapshot into $W and print a summary
  [ -e "$S/latest.tar" ] || fail "no snapshot"
  SNAP=$(readlink -f "$S/latest.tar")
  W=$(mktemp -d "$R/.work.XXXXXX")
  tar -xf "$SNAP" -C "$W" || fail "cannot extract $SNAP"
  gzip -t "$W/config.tgz" || fail "config.tgz corrupt"
  local created age
  created=$(cat "$W/created_utc"); echo "$created" > "$R/.last_created"; age=$(( ($(date +%s) - $(date -d "$created" +%s)) / 60 ))
  say "snapshot: $(basename "$SNAP"), created $created, age ${age} min, $(( $(stat -c %s "$SNAP")/1024 )) KiB"
  say "core version: snapshot $(jq -r .data.version "$W/core.json"), this node $(api GET core/info | jq -r .data.version)"
}

addon_report(){
  local a pv st vv
  for a in $ADDONS; do
    if [ ! -s "$W/addons/$a.json" ]; then say "addon $a: NOT in snapshot (not installed on the primary?)"; continue; fi
    pv=$(jq -r .data.version "$W/addons/$a.json")
    st=$(api GET "addons/$a/info" | jq -r '.data | "\(.version) \(.state) boot=\(.boot)"')
    vv=${st%% *}
    say "addon $a: primary $pv (boot $(jq -r .data.boot "$W/addons/$a.json")), here $st $( [ "$pv" = "$vv" ] && echo OK || echo VERSION-MISMATCH )"
  done
}

mqtt_report(){
  tar -xzOf "$W/config.tgz" homeassistant/.storage/core.config_entries \
   | jq -r '.data.entries[] | select(.domain=="mqtt") | "mqtt entry \(.entry_id): broker=\(.data.broker) port=\(.data.port) user=\(.data.username) password=\(if .data.password then "set" else "none" end)"'
  say "mqtt service here now: $(api GET services/mqtt | jq -c '{result, host:.data.host, user:.data.username}')"
}

custom_report(){
  tar -xzOf "$W/config.tgz" --wildcards 'homeassistant/custom_components/*/manifest.json' 2>/dev/null \
   | jq -r 'select(.requirements and (.requirements|length>0)) | "custom \(.domain): needs \(.requirements|join(", "))"'
  say "(custom integrations with requirements need internet on first start: pip packages are not replicated)"
}

net_report(){
  say "network $IFACE now: $(iface_ipv4 | jq -c '{method, address, gateway, nameservers}')"
  if n=$(takeover_net); then set -- $n; say "planned: static $1 gw $2 dns $3"; else say "PROBLEM: $n"; fi
}

restore_snapshot_addons(){ # options/network of each managed add-on from the snapshot
  local a body
  for a in $ADDONS; do
    [ -s "$W/addons/$a.json" ] || { say "options $a: not in snapshot, left as is"; continue; }
    body=$(jq -c '{options: .data.options, network: .data.network}' "$W/addons/$a.json")
    say "options $a: $(api POST "addons/$a/options" "$body" | jq -r '.result + " " + (.message // "")')"
  done
}

boot_watchdog_from(){ # $1 = function that prints add-on info JSON for slug $2
  local a bw
  for a in $ADDONS; do
    bw=$("$1" "$a" 2>/dev/null | jq -c '{boot: .data.boot, watchdog: .data.watchdog}' 2>/dev/null)
    [ -n "$bw" ] && api POST "addons/$a/options" "$bw" >/dev/null
  done
}
info_from_work(){ cat "$W/addons/$1.json"; }
info_from_latest(){ tar -xOf "$(readlink -f "$S/latest.tar")" "./addons/$1.json"; }

switch_ready(){ [ -n "$SW" ] && [ -n "$U" ] && [ -n "$A" ] && [ -n "$X" ] && [ "${PIP:-0}" != 0 ]; }
isolate_primary(){ # disable the primary port and confirm it; sets PORT_MSG. Returns 1 if it cannot be confirmed.
  local a o i
  if ! switch_ready; then say "WARNING: switch not configured, primary port NOT disabled"; PORT_MSG=$(msg port_untouched); return 0; fi
  a=$(port_admin "$PIP"); o=$(port_oper "$PIP")
  if ! is_down "$a"; then say "disable primary port $PIP: $(port_set "$PIP" 2 | tr '\n' ' ')"; fi
  for i in 1 2 3 4 5; do
    a=$(port_admin "$PIP"); o=$(port_oper "$PIP"); say "port $PIP: admin=$a oper=$o"
    if is_down "$a" && is_down "$o"; then PORT_MSG=$(msg port_off "$PIP"); return 0; fi
    sleep 2
  done
  return 1
}

take_address(){ # $1 cidr $2 gw $3 dns
  say "network $IFACE -> static $1: $(api POST "network/interface/$IFACE/update" "$(static_body "$1" "$2" "$3")" | jq -c .)"
}

start_broker(){ [ -n "$BROKER" ] && say "start $BROKER: $(api POST "addons/$BROKER/start" | jq -r .result)"; }
start_others(){ local a; for a in $OTHERS; do say "start $a: $(api POST "addons/$a/start" | jq -r .result)"; done; }

case "$MODE" in
dry-run)
  say "=== DRY RUN, nothing will be changed ==="
  check_pi || say "(in a real failover this would ABORT here)"
  prepare; addon_report; mqtt_report; custom_report; net_report
  say "free space: $(df -h /homeassistant | awk 'NR==2{print $4}') on /homeassistant"
  say "BLOCKED now: $( [ -e "$R/BLOCKED" ] && echo yes || echo no )"
  if switch_ready; then say "switch: primary port $PIP admin=$(port_admin "$PIP") oper=$(port_oper "$PIP") (will be disabled and confirmed first)"
  else say "switch: NOT configured, the primary port will not be disabled"; fi
  say "plan: disable + confirm primary port -> BLOCKED -> stop core+add-ons -> save /homeassistant to $R/standby-<ts>.tgz -> wipe and extract snapshot"
  say "      -> add-on options from primary -> start ${BROKER:-(no broker)} -> patch mqtt entry with local broker credentials"
  say "      -> static address of the primary -> start ${OTHERS:-(no other add-ons)}, boot/watchdog as on primary -> start core"
  rm -rf "$W"; say "=== DRY RUN done ===" ;;
failover)
  [ "$CONFIRM" = "I-UNDERSTAND" ] || fail "confirmation word missing"
  REASON="${3:-}"
  say "=== FAILOVER started $(date -u +%FT%TZ) ==="
  check_pi || fail "primary is alive, refusing"
  NET=$(takeover_net) || fail "$NET"
  isolate_primary || fail "primary port $PIP not confirmed down, nothing changed"
  check_pi || fail "primary answers after its port was disabled (another path?), nothing else changed; port $PIP stays down, enable it with pi-port-up"
  echo "failover $(date -u +%FT%TZ)" > "$R/BLOCKED"
  prepare; addon_report
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  say "stop core: $(api POST core/stop | jq -r .result)"
  for a in $ADDONS; do api POST "addons/$a/stop" >/dev/null; done
  say "save standby config"; tar -C / -czf "$R/standby-$ts.tgz" homeassistant || fail "cannot save standby config"
  say "restore snapshot"
  find /homeassistant -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -C / -xzf "$W/config.tgz" || fail "extract failed (standby copy: $R/standby-$ts.tgz)"
  for f in "$W"/db/*.db; do [ -e "$f" ] && cp "$f" "/homeassistant/$(basename "$f")" && say "database $(basename "$f") restored"; done
  restore_snapshot_addons
  start_broker
  # no waiting: the Supervisor mqtt service may only appear after core starts; HA then logs in with the primary's user
  svc=$(api GET services/mqtt)
  if [ -n "$BROKER" ] && [ "$(echo "$svc" | jq -r .result)" = ok ]; then
    F=/homeassistant/.storage/core.config_entries
    jq --arg u "$(echo "$svc" | jq -r .data.username)" --arg p "$(echo "$svc" | jq -r .data.password)" --arg pi "$PI" \
      '(.data.entries[] | select(.domain=="mqtt" and (.data.broker=="core-mosquitto" or .data.broker=="localhost" or .data.broker==$pi)) | .data) |= (.username=$u | .password=$p)' \
      "$F" > "$F.tmp" && mv "$F.tmp" "$F" && say "mqtt entry credentials replaced with the local broker ones"
  else
    say "mqtt service not ready (or no broker managed), mqtt entry left as is"
  fi
  set -- $NET; take_address "$1" "$2" "$3"
  start_others
  boot_watchdog_from info_from_work
  say "start core: $(api POST core/start | jq -r .result)"
  rm -rf "$W"
  say "=== FAILOVER done $(date -u +%FT%TZ); standby copy $R/standby-$ts.tgz; replication BLOCKED ==="
  snap_local=$(date -d "$(cat "$R/.last_created" 2>/dev/null)" '+%d.%m %H:%M' 2>/dev/null || echo "?")
  notify_bg "$(msg failover_title)" "$(msg failover_body "$(local_time)" "${REASON:-$(msg reason_default "$PI")}" "$PORT_MSG" "$snap_local")" 900 ;;
resume-primary)
  # Return to the primary failed: take the primary role again with THIS node's own latest state
  # (primary-<ts>.tgz saved by standby), not with the older snapshot. Called by return.sh after the port was disabled.
  [ "$CONFIRM" = "I-UNDERSTAND" ] || fail "confirmation word missing"
  REASON="${3:-}"
  say "=== RESUME PRIMARY started $(date -u +%FT%TZ) ==="
  check_pi || fail "primary is alive, refusing"
  NET=$(takeover_net) || fail "$NET"
  PR=$(ls -1t "$R"/primary-*.tgz 2>/dev/null | head -1)
  [ -n "$PR" ] || fail "no primary-*.tgz to resume from"
  tar -tzf "$PR" >/dev/null 2>&1 || fail "$PR is corrupt"
  echo "resume-primary $(date -u +%FT%TZ)" > "$R/BLOCKED"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  say "stop core: $(api POST core/stop | jq -r .result)"
  for a in $ADDONS; do api POST "addons/$a/stop" >/dev/null; done
  say "save standby config"; tar -C / -czf "$R/standby-$ts.tgz" homeassistant || fail "cannot save standby config"
  say "restore $(basename "$PR")"
  find /homeassistant -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -C / -xzf "$PR" || fail "extract of $PR failed (standby copy: $R/standby-$ts.tgz)"
  start_broker
  set -- $NET; take_address "$1" "$2" "$3"
  start_others
  boot_watchdog_from info_from_latest
  say "start core: $(api POST core/start | jq -r .result)"
  say "=== RESUME PRIMARY done $(date -u +%FT%TZ); primary role again with $(basename "$PR"); replication BLOCKED ==="
  notify_bg "$(msg resume_title)" "$(msg resume_body "$(local_time)" "$REASON")" 900 ;;
standby-dry|standby)
  if [ "$MODE" = standby ]; then
    [ "$CONFIRM" = "I-UNDERSTAND" ] || fail "confirmation word missing"
    say "=== STANDBY started $(date -u +%FT%TZ) ==="
  else
    say "=== STANDBY DRY RUN, nothing will be changed ==="
  fi
  SB=$(ls -1t "$R"/standby-*.tgz 2>/dev/null | head -1)
  if [ -n "$SB" ]; then
    say "standby copy: $(basename "$SB"), $(( $(stat -c %s "$SB")/1024 )) KiB, $(tar -tzf "$SB" 2>/dev/null | wc -l) entries"
  else
    say "standby copy: NONE (exists only after a failover)"
    [ "$MODE" = standby ] && fail "no standby copy, nothing to restore"
  fi
  say "network $IFACE now: $(iface_ipv4 | jq -c '{method, address}')"
  say "core: $(api GET core/info | jq -r '.data.version')"
  for a in $ADDONS; do say "addon $a: $(api GET "addons/$a/info" | jq -r '.data | "\(.state) boot=\(.boot) watchdog=\(.watchdog)"')"; done
  say "BLOCKED: $( [ -e "$R/BLOCKED" ] && head -c 100 "$R/BLOCKED" || echo no) (stays until 'unblock')"
  if [ "$MODE" = standby-dry ]; then
    say "plan: stop core -> stop ${OTHERS:+$OTHERS }${BROKER}; boot manual, watchdog off"
    say "      -> save current /homeassistant to $R/primary-<ts>.tgz (changes made while this node was primary)"
    say "      -> wipe and restore the standby copy -> network DHCP -> start core"
    say "      -> then power on the primary; after it is checked: unblock"
    say "=== STANDBY DRY RUN done ==="
    exit 0
  fi
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  say "stop core: $(api POST core/stop | jq -r .result)"
  for a in $OTHERS $BROKER; do
    say "stop $a: $(api POST "addons/$a/stop" | jq -r .result)"
    api POST "addons/$a/options" '{"boot":"manual","watchdog":false}' >/dev/null
  done
  say "save primary-state config"; tar -C / -czf "$R/primary-$ts.tgz" homeassistant || fail "cannot save current config, nothing wiped"
  find /homeassistant -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -C / -xzf "$SB" || fail "restore of $SB failed; current config saved in $R/primary-$ts.tgz"
  say "network $IFACE -> DHCP: $(api POST "network/interface/$IFACE/update" '{"ipv4":{"method":"auto"}}' | jq -c .)"
  say "start core: $(api POST core/start | jq -r .result)"
  say "=== STANDBY done $(date -u +%FT%TZ); primary-state copy $R/primary-$ts.tgz; now power on the primary, then unblock ===" ;;
unblock-dry|unblock)
  [ "$MODE" = unblock ] && { [ "$CONFIRM" = "I-UNDERSTAND" ] || fail "confirmation word missing"; }
  say "addresses on $IFACE: $(iface_ipv4 | jq -r '.address[]?' | tr '\n' ' ')"
  holds_pi_ip && fail "this node still holds $PI, run standby first"
  tcp "$PI" "$PORT" && tcp "$PI" "$HA_PORT" || fail "primary does not answer on $PORT and $HA_PORT yet"
  say "primary answers on $PORT and $HA_PORT"
  say "BLOCKED: $( [ -e "$R/BLOCKED" ] && head -c 100 "$R/BLOCKED" || echo no)"
  if [ "$MODE" = unblock ]; then rm -f "$R/BLOCKED"; say "BLOCKED removed, replication resumes on the next cycle"
  else say "=== UNBLOCK DRY RUN done, nothing changed ==="; fi ;;
*) say "usage: dry-run | failover I-UNDERSTAND | standby-dry | standby I-UNDERSTAND | unblock-dry | unblock I-UNDERSTAND | resume-primary I-UNDERSTAND" ;;
esac
