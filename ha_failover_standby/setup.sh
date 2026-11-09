#!/bin/bash
# Setup wizard, readiness check and drill for the standby node.
#   setup-dry              -> what the wizard would do, changes nothing
#   setup I-UNDERSTAND     -> add missing add-on repositories (from the primary snapshot), install missing managed
#                             add-ons, set every managed add-on to boot manual / watchdog off and stop it
#   preflight              -> read-only readiness check: PASS / WARN / FAIL lines, summary in preflight.json
#   drill                  -> read-only restore drill: unpack the latest snapshot into a scratch folder and validate it,
#                             show what the watchdog would decide right now; nothing outside the scratch folder changes
set -uo pipefail
. /lib.sh
SV_TIMEOUT=900
MODE="${1:-}"; CONFIRM="${2:-}"
say(){ echo "$*"; }
NP=0; NW=0; NF=0; FAILS=""; WARNS=""
pass(){ NP=$((NP+1)); say "PASS  $*"; }
warn(){ NW=$((NW+1)); WARNS="$WARNS; $*"; say "WARN  $*"; }
fail(){ NF=$((NF+1)); FAILS="$FAILS; $*"; say "FAIL  $*"; }
latest(){ readlink -f "$S/latest.tar" 2>/dev/null; }
from_latest(){ local l; l=$(latest); [ -n "$l" ] && tar -xOf "$l" "./$1" 2>/dev/null; }

# ---------------------------------------------------------------- setup
setup(){
  local apply=$1 repos have a info inst src
  [ -n "$ADDONS" ] || { say "no managed add-ons in option addons, nothing to do"; return 0; }
  repos=$(from_latest repositories.json); [ -n "$repos" ] || repos='[]'
  [ "$repos" != '[]' ] || say "note: no repositories.json in the latest snapshot (no snapshot yet, or an old primary add-on)"
  have=$(sv GET store/repositories | jq -r '.data[]?.slug')
  for a in $ADDONS; do
    info=$(sv GET "store/addons/$a")
    inst=$(jq -r '.data.installed // empty' <<<"$info")
    if [ -z "$inst" ]; then   # unknown to this store: its repository is missing here
      src=$(jq -r --arg p "${a%%_*}" '.[] | select(.slug==$p) | .source' <<<"$repos" | head -1)
      if [ -z "$src" ]; then say "addon $a: not in the store here and its repository is unknown: add it by hand"; continue; fi
      if grep -qx "${a%%_*}" <<<"$have"; then say "addon $a: repository present but add-on not found (renamed?)"; continue; fi
      if [ "$apply" = 1 ]; then
        say "addon $a: add repository $src: $(sv POST store/repositories "$(jq -cn --arg r "$src" '{repository:$r}')" | jq -r '.result + " " + (.message // "")')"
        sv POST store/reload >/dev/null
        info=$(sv GET "store/addons/$a"); inst=$(jq -r '.data.installed // empty' <<<"$info")
        [ -n "$inst" ] || { say "addon $a: still not in the store after adding the repository"; continue; }
      else
        say "addon $a: would add repository $src"; inst=false
      fi
    fi
    if [ "$inst" != true ]; then
      if [ "$apply" = 1 ]; then
        say "addon $a: install (can take minutes): $(sv POST "store/addons/$a/install" | jq -r '.result + " " + (.message // "")')"
      else say "addon $a: would install"; fi
    fi
    if [ "$apply" = 1 ]; then
      say "addon $a: boot manual, watchdog off: $(sv POST "addons/$a/options" '{"boot":"manual","watchdog":false}' | jq -r .result)"
      [ "$(sv GET "addons/$a/info" | jq -r .data.state)" = started ] && say "addon $a: stop: $(sv POST "addons/$a/stop" | jq -r .result)"
    else
      say "addon $a: $(sv GET "addons/$a/info" | jq -r '.data | "now \(.state // "-") boot=\(.boot // "-") watchdog=\(.watchdog // "-")"' 2>/dev/null), would set boot manual, watchdog off, stopped"
    fi
  done
  say "add-on options (devices, MQTT, ports) are taken from the primary snapshot at failover, not now"
}

# ---------------------------------------------------------------- preflight
preflight(){
  local v l age n p h a o t snap_sz free_kb have bw
  say "=== PREFLIGHT $(date -u +%FT%TZ) ==="
  # options
  for v in primary_host primary_pin primary_token switch_host snmp_user snmp_auth_pass snmp_priv_pass; do
    [ -n "$(opt ".$v")" ] && pass "option $v set" || fail "option $v empty"
  done
  [ "${PIP:-0}" != 0 ] && pass "option primary_switch_port $PIP" || fail "option primary_switch_port not set"
  [ "${TP:-0}" != 0 ] && pass "option test_switch_port $TP" || warn "test_switch_port not set: port-test unavailable"
  [ -n "$ADDONS" ] && pass "managed add-ons: $ADDONS" || warn "no managed add-ons (option addons)"
  # primary API
  if pi_api GET ping 15 >/dev/null 2>/tmp/pf.err; then pass "primary API answers, key pin and token accepted"
  else fail "primary API: $(tr '\n' ' ' </tmp/pf.err | head -c 200)"; fi
  h=$(pi_health 60 2>/dev/null)
  if [ -n "$h" ]; then
    [ "$(jq -r .ready <<<"$h" 2>/dev/null)" = true ] && pass "primary health ready: $h" || warn "primary health not ready: $h"
    [ "$(jq -r '.checks | length' <<<"$h" 2>/dev/null)" != 0 ] || warn "no readiness checks on the primary (option checks): return-to-pi only waits for core"
  fi
  # replication
  l=$(latest)
  if [ -n "$l" ]; then
    age=$(( ($(date +%s) - $(date -d "$(tar -xOf "$l" ./created_utc)" +%s)) / 60 ))
    if [ "$age" -le $(( $(opt .interval_minutes) * 3 )) ]; then pass "latest snapshot $(basename "$l"), ${age} min old"
    else warn "latest snapshot is ${age} min old (interval $(opt .interval_minutes) min)"; fi
    [ "$(jq -r .state "$R/status.json" 2>/dev/null)" = ok ] && pass "last replication ok" || warn "last replication: $(jq -c '{state,message}' "$R/status.json" 2>/dev/null)"
    snap_sz=$(tar -xOf "$l" ./config.tgz | wc -c)
    free_kb=$(df -k /homeassistant | awk 'NR==2{print $4}')
    [ $((free_kb*1024)) -gt $((snap_sz*6)) ] && pass "free space $((free_kb/1024)) MiB" || fail "free space $((free_kb/1024)) MiB is low for a config of $((snap_sz/1048576)) MiB packed"
  else fail "no snapshot yet"; fi
  [ -e "$R/BLOCKED" ] && warn "BLOCKED present: $(head -c 100 "$R/BLOCKED")" || pass "not BLOCKED"
  # add-ons and versions
  [ -n "$l" ] && { p=$(jq -r .data.version <(from_latest core.json)); n=$(sv GET core/info | jq -r .data.version)
    [ "$p" = "$n" ] && pass "core version $n same as primary" || warn "core version here $n, primary $p"; }
  for a in $ADDONS; do
    t=$(sv GET "addons/$a/info")
    if [ "$(jq -r .result <<<"$t")" != ok ] || [ "$(jq -r '.data.version // empty' <<<"$t")" = "" ]; then fail "addon $a not installed here (run setup)"; continue; fi
    [ "$(jq -r .data.boot <<<"$t")" = manual ] && [ "$(jq -r .data.state <<<"$t")" != started ] \
      && pass "addon $a installed, manual, stopped" \
      || { holds_pi_ip && pass "addon $a running (this node is primary now)" || fail "addon $a: boot=$(jq -r .data.boot <<<"$t") state=$(jq -r .data.state <<<"$t"), must be manual and stopped on a standby"; }
    if [ -n "$l" ]; then
      p=$(from_latest "addons/$a.json" | jq -r '.data.version // empty')
      [ -z "$p" ] && warn "addon $a not in the primary snapshot" \
        || { [ "$p" = "$(jq -r .data.version <<<"$t")" ] && pass "addon $a version $p same as primary" || warn "addon $a version here $(jq -r .data.version <<<"$t"), primary $p"; }
    fi
  done
  # network
  if t=$(takeover_net); then pass "takeover network: $t on $IFACE"; else fail "takeover network: $t"; fi
  holds_pi_ip && warn "this node holds $PI now (acting primary)" || pass "this node does not hold $PI"
  GW=$(gateway); [ -n "$GW" ] && { ping1 "$GW" && pass "gateway $GW answers" || fail "gateway $GW silent"; } || fail "no gateway known"
  mapfile -t REQ < <(jq -r '.required_hosts[]?' "$O")
  for h in "${REQ[@]}"; do p=""; case "$h" in *:*) p=${h##*:}; h=${h%:*} ;; esac
    { ping1 "$h" || { [ -n "$p" ] && tcp "$h" "$p"; }; } && pass "required host $h answers" || fail "required host $h silent"; done
  # switch
  if [ -n "$SW" ] && [ -n "$A" ]; then
    a=$(port_admin "$PIP"); o=$(port_oper "$PIP")
    [ -n "$a" ] && pass "switch SNMP answers, primary port $PIP admin=$a oper=$o" || fail "switch $SW does not answer SNMPv3 (user, protocols, passwords, trusted hosts?)"
    if [ -n "$a" ] && ! holds_pi_ip; then is_up "$o" && pass "primary port $PIP has link" || warn "primary port $PIP has no link: wrong port?"; fi
    [ "${TP:-0}" != 0 ] && { o=$(port_oper "$TP"); is_down "$o" && pass "test port $TP free" || warn "test port $TP has link ($o)"; }
  fi
  # notify
  mapfile -t NT < <(jq -r '.notify_targets[]?' "$O")
  if [ "${#NT[@]}" = 0 ]; then warn "no notify_targets: failover only creates a persistent notification"
  else have=$(sv GET core/api/services | jq -r '.[] | select(.domain=="notify") | .services | keys[]' 2>/dev/null)
    for t in "${NT[@]}"; do grep -qx "$t" <<<"$have" && pass "notify.$t exists here" || warn "notify.$t does not exist on this node now (it appears after failover if it exists on the primary)"; done; fi
  # watchdog
  v=$(opt .watchdog_mode); [ "$v" = armed ] && pass "watchdog armed" || warn "watchdog_mode is $v: no automatic failover"
  say "=== PREFLIGHT: $NP pass, $NW warn, $NF fail ==="
  jq -n --argjson p "$NP" --argjson w "$NW" --argjson f "$NF" --arg fl "${FAILS#; }" --arg wl "${WARNS#; }" --arg t "$(date -u +%FT%TZ)" \
    '{pass:$p, warn:$w, fail:$f, fails:$fl, warns:$wl, checked_utc:$t, ready:($f==0)}' > "$R/preflight.json"
}

# ---------------------------------------------------------------- drill
drill(){
  local l created t n sz
  say "=== DRILL $(date -u +%FT%TZ): restore test in a scratch folder, nothing else changes ==="
  l=$(latest); [ -n "$l" ] || { fail "no snapshot"; return; }
  D=$(mktemp -d "$R/.drill.XXXXXX"); trap 'rm -rf "$D"' EXIT   # global D: removed when the script ends
  tar -xf "$l" -C "$D" && pass "snapshot $(basename "$l") unpacks" || { fail "snapshot does not unpack"; return; }
  created=$(cat "$D/created_utc"); pass "created $created"
  mkdir -p "$D/root"
  tar -xzf "$D/config.tgz" -C "$D/root" && pass "config unpacks: $(find "$D/root" -type f | wc -l) files, $(du -sm "$D/root" | cut -f1) MiB" || fail "config.tgz does not unpack"
  for f in configuration.yaml .storage/core.config_entries .storage/core.entity_registry .storage/core.device_registry; do
    [ -s "$D/root/homeassistant/$f" ] && pass "$f present" || fail "$f missing"
  done
  for f in "$D"/root/homeassistant/.storage/core.*; do
    [ -e "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || fail ".storage/$(basename "$f") is not valid JSON"
  done
  pass "core .storage files checked"
  n=$(jq '[.data.entries[]] | length' "$D/root/homeassistant/.storage/core.config_entries" 2>/dev/null)
  say "INFO  $n config entries, $(jq '.data.entities | length' "$D/root/homeassistant/.storage/core.entity_registry" 2>/dev/null) entities"
  for f in "$D"/db/*.db; do
    [ -e "$f" ] || continue
    t=$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>&1 | head -1)
    [ "$t" = ok ] && pass "database $(basename "$f") integrity ok" || fail "database $(basename "$f"): $t"
  done
  for a in $ADDONS; do
    [ -s "$D/addons/$a.json" ] && jq -e .data.options "$D/addons/$a.json" >/dev/null 2>&1 \
      && pass "addon $a settings in snapshot" || fail "addon $a settings missing in snapshot"
  done
  sz=$(du -sk "$D/root" | cut -f1)
  [ $(( $(df -k /homeassistant | awk 'NR==2{print $4}') )) -gt $((sz*2)) ] && pass "room for config + standby copy" || fail "not enough free space for a failover"
  say "--- what the watchdog would decide now ---"
  if ping1 "$PI"; then say "INFO  primary answers ping"; else say "INFO  primary does not answer ping"; fi
  for p in $(pi_alive_ports); do tcp "$PI" "$p" && say "INFO  primary port $p open" || say "INFO  primary port $p closed"; done
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$PI:$HA_PORT/manifest.json")" = 200 ] && say "INFO  primary HA serves /manifest.json" || say "INFO  primary HA does not serve /manifest.json"
  say "INFO  watchdog state: $(jq -c . "$R/watchdog.json" 2>/dev/null || echo none)"
  say "=== DRILL: $NP pass, $NW warn, $NF fail; scratch folder removed ==="
}

case "$MODE" in
setup-dry) say "=== SETUP DRY RUN, nothing will be changed ==="; setup 0; say "=== SETUP DRY RUN done ===" ;;
setup) [ "$CONFIRM" = I-UNDERSTAND ] || { say "ABORT: usage setup I-UNDERSTAND"; exit 1; }
  holds_pi_ip && { say "ABORT: this node holds $PI (acting primary), setup would stop its add-ons"; exit 1; }
  say "=== SETUP started ==="; setup 1; say "=== SETUP done; run preflight ===" ;;
preflight) preflight ;;
drill) drill ;;
*) say "usage: setup-dry | setup I-UNDERSTAND | preflight | drill" ;;
esac
