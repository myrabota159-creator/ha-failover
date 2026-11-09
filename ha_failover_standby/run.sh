#!/bin/bash
# HA Failover Standby: pull config snapshots from the primary HA over SSH (forced command on the primary side),
# run the watchdog, and accept manual commands on stdin.
set -uo pipefail
. /lib.sh
INT=$(opt .interval_minutes); KEEP=$(opt .keep)
mkdir -p "$S"; chmod 700 "$R" "$S"
log(){ echo "[$(date '+%F %T')] $*"; }
[ -f "$K" ] || ssh-keygen -q -t ed25519 -N "" -C ha-failover-standby -f "$K"
log "public key (add it on the primary, see primary/README.md): $(cat "$K.pub")"
log "interface $IFACE, managed add-ons: ${ADDONS:-none}, language $LANGUAGE"
missing=""
for v in PI PORT USER_; do [ -n "${!v}" ] || missing="$missing $v"; done
[ -z "$missing" ] || log "WARNING: primary_host / primary_ssh_port / primary_ssh_user not set, replication will fail"
status(){ # $1 ok|error|blocked, $2 message, $3 file, $4 size
  jq -n --arg st "$1" --arg msg "$2" --arg f "${3:-}" --arg sz "${4:-0}" --arg t "$(date -u +%FT%TZ)" \
     --slurpfile prev <( [ -s "$R/status.json" ] && cat "$R/status.json" || echo '{}' ) \
     '($prev[0] // {}) + {state:$st, message:$msg, checked_utc:$t}
      + (if $st=="ok" then {last_ok_utc:$t, last_file:$f, last_size:($sz|tonumber)} else {last_error_utc:$t} end)' \
     > "$R/status.json.tmp" && mv "$R/status.json.tmp" "$R/status.json"
}
replicate_loop(){
while true; do
  if [ -e "$R/BLOCKED" ]; then
    log "BLOCKED present ($(head -c 200 "$R/BLOCKED")), replication skipped"
    status blocked "BLOCKED file present"
  else
    ts=$(date -u +%Y%m%dT%H%M%SZ); tmp="$S/.incoming-$ts.tar"
    if pi_ssh export 900 > "$tmp" 2>/data/last_ssh_err \
       && tar -tf "$tmp" ./created_utc ./config.tgz >/dev/null 2>&1 \
       && tar -xOf "$tmp" ./config.tgz | gzip -t 2>/dev/null; then
      mv "$tmp" "$S/$ts.tar"
      ln -sfn "$ts.tar" "$S/latest.tar"
      sz=$(stat -c %s "$S/$ts.tar")
      ls -1 "$S"/2*.tar 2>/dev/null | head -n -"$KEEP" | xargs -r rm -f
      log "ok $ts.tar $((sz/1024)) KiB, kept $(ls -1 "$S"/2*.tar | wc -l)"
      status ok "snapshot ok" "$ts.tar" "$sz"
    else
      err=$(tail -c 400 /data/last_ssh_err | tr '\n' ' ')
      rm -f "$tmp"
      log "FAILED: ${err:-archive check failed}"
      status error "${err:-archive check failed}"
    fi
  fi
  sleep $((INT*60))
done
}
# Replication runs in the background (its stdin is /dev/null); the foreground reads manual commands
# from stdin (action hassio.addon_stdin / app_stdin), e.g. "dry-run", "failover I-UNDERSTAND".
replicate_loop < /dev/null &
/watchdog.sh < /dev/null 2>&1 | while IFS= read -r l; do log "[watchdog] $l"; done &
while true; do
  while IFS= read -r line; do
    line=${line//$'\r'/}; line=${line#\"}; line=${line%\"}   # the stdin action sends JSON: "cmd"
    [ -n "$line" ] || continue
    log "command received: ${line%% *}"
    case "$line" in
      snmp-*|port-*|pi-port-*) /snmp.sh $line 2>&1 | while IFS= read -r l; do log "[snmp] $l"; done ;;
      return-to-pi*) /return.sh $line 2>&1 | while IFS= read -r l; do log "[return] $l"; done ;;
      notify-test) /notify.sh "$(msg test_title)" "$(msg test_body)" 30 2>&1 | while IFS= read -r l; do log "[notify] $l"; done ;;
      *) /failover.sh $line 2>&1 | while IFS= read -r l; do log "[failover] $l"; done ;;
    esac
  done
  sleep 5   # stdin closed: keep the container alive, replication continues
done
