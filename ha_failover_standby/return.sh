#!/bin/bash
# One-button return from this node (acting primary) to the real primary.
#   return-to-pi-dry           -> checks and plan only, changes nothing
#   return-to-pi-health        -> read-only probe of the primary side (health + refusal of unknown requests)
#   return-to-pi I-UNDERSTAND  -> standby -> primary port up -> wait for a healthy primary -> unblock + push;
#                                 if the primary is not healthy in time: port down -> resume-primary here + push
# Health comes from the primary's export.sh "health": {"core":..., "checks":{...}, "ready":true|false}.
set -uo pipefail
. /lib.sh
MODE="${1:-}"; CONFIRM="${2:-}"
CORE_WAIT=360; READY_WAIT=720
say(){ echo "$*"; }

rollback(){ # $1 reason
  say "ROLLBACK: $1"
  say "primary port $PIP down"; port_set "$PIP" 2 >/dev/null; sleep 3
  a=$(port_admin "$PIP"); say "port $PIP admin=$a"
  if ! is_down "$a"; then
    say "ERROR: primary port NOT confirmed down; this node stays standby, the primary stays primary. Check by hand."
    notify_bg "$(msg resume_title)" "$(msg return_fail_body "$(local_time)" "$1")" 60
    exit 1
  fi
  for i in $(seq 1 20); do tcp "$PI" "$HA_PORT" || tcp "$PI" "$PORT" || break; sleep 3; done
  /failover.sh resume-primary I-UNDERSTAND "$1"
  exit 1
}

# ---------- checks ----------
if [ "$MODE" = return-to-pi-health ]; then
  say "health: $(pi_health 2>&1)"
  ( umask 077; printf 'Authorization: Bearer wrong-token\n' > /tmp/bad.hdr )
  say "wrong token is refused: $(pi_api GET ping 20 /tmp/bad.hdr 2>&1 | tr '\n' ' ' | head -c 200)"
  rm -f /tmp/bad.hdr
  exit 0
fi
blocked=$( [ -e "$R/BLOCKED" ] && head -c 100 "$R/BLOCKED" || echo no )
holds=$(holds_pi_ip && echo yes || echo no)
pa=$(port_admin "$PIP")
primary=$(ls -1t "$R"/primary-*.tgz 2>/dev/null | head -1)
say "this node holds $PI: $holds; BLOCKED: $blocked; primary port $PIP admin=${pa:-no answer}"
say "last primary-state copy: ${primary:-none}"
problems=""
[ "$holds" = yes ] || problems="$problems node-is-not-primary"
[ "$blocked" != no ] || problems="$problems no-BLOCKED"
[ -n "$pa" ] || problems="$problems switch-SNMP-not-answering"
is_up "$pa" && problems="$problems primary-port-already-up"
if [ "$MODE" = return-to-pi-dry ]; then
  say "plan: standby (this node -> DHCP, its state saved to primary-<ts>.tgz) -> primary port $PIP up"
  say "      -> wait up to ${CORE_WAIT}s for core RUNNING on the primary, then up to ${READY_WAIT}s for its readiness checks"
  say "      -> OK: unblock, push from the primary"
  say "      -> not OK: primary port down, this node resumes as primary with its own latest state, push"
  say "problems:${problems:- none}"
  say "=== RETURN DRY RUN done ==="; exit 0
fi
[ "$MODE" = return-to-pi ] && [ "$CONFIRM" = I-UNDERSTAND ] || { say "ABORT: usage return-to-pi I-UNDERSTAND"; exit 1; }
[ -z "$problems" ] || { say "ABORT:$problems"; exit 1; }

# ---------- return ----------
say "=== RETURN TO PRIMARY started $(date -u +%FT%TZ) ==="
/failover.sh standby I-UNDERSTAND || { say "ABORT: standby failed, see above"; exit 1; }
for i in $(seq 1 24); do holds_pi_ip || break; sleep 5; done
holds_pi_ip && { say "ABORT: this node still holds $PI after standby; primary port stays down"; exit 1; }
say "released $PI; primary port $PIP up"; port_set "$PIP" 1 >/dev/null; sleep 3
a=$(port_admin "$PIP"); say "port $PIP admin=$a"
is_up "$a" || rollback "$(msg reason_port_not_up)"

t0=$(date +%s); h=""
while :; do
  h=$(pi_health 2>/dev/null)
  [ "$(jq -r .core <<<"$h" 2>/dev/null)" = RUNNING ] && break
  [ $(( $(date +%s) - t0 )) -ge $CORE_WAIT ] && rollback "$(msg reason_core_timeout $((CORE_WAIT/60)))"
  sleep 10
done
say "primary core RUNNING after $(( $(date +%s) - t0 ))s: $h"
t1=$(date +%s)
while :; do
  h=$(pi_health 2>/dev/null)
  [ "$(jq -r .ready <<<"$h" 2>/dev/null)" = true ] && break
  [ $(( $(date +%s) - t1 )) -ge $READY_WAIT ] && rollback "$(msg reason_not_ready $((READY_WAIT/60))) ($h)"
  sleep 15
done
say "primary healthy after $(( $(date +%s) - t0 ))s: $h"
rm -f "$R/BLOCKED"; say "BLOCKED removed, replication resumes on the next cycle"
say "push via primary: $(pi_api POST notify-return-ok 60 2>&1 | tr '\n' ' ')"
say "=== RETURN TO PRIMARY done $(date -u +%FT%TZ) ==="
