#!/bin/bash
# Send a notification through the Home Assistant that runs on this node.
#   notify.sh "<title>" "<message>" [wait_seconds]
# Waits until core is RUNNING and the notify services exist (up to wait_seconds, default 900),
# then calls notify.<target> for each option notify_targets and creates a persistent notification.
set -uo pipefail
. /lib.sh
NLOG=$R/notify.log
out(){ echo "[$(date -u '+%F %T')] $*" | tee -a "$NLOG"; }
TITLE="$1"; MSG="$2"; WAIT="${3:-900}"
code(){ curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" --data "$2" "http://supervisor/core/api/$1"; }
out "start: $TITLE"
mapfile -t TARGETS < <(jq -r '.notify_targets[]?' "$O")
end=$(( $(date +%s) + WAIT ))
while :; do
  missing=""
  if [ "$(sv GET core/api/config | jq -r .state 2>/dev/null)" = RUNNING ]; then
    have=$(sv GET core/api/services | jq -r '.[] | select(.domain=="notify") | .services | keys[]' 2>/dev/null)
    for t in "${TARGETS[@]}"; do grep -qx "$t" <<<"$have" || missing="$missing $t"; done
    [ -z "$missing" ] && break
  else missing=" core"; fi
  [ "$(date +%s)" -ge "$end" ] && { out "notify: waited ${WAIT}s, not ready (missing:$missing), sending what is possible"; break; }
  sleep 15
done
body=$(jq -n --arg t "$TITLE" --arg m "$MSG" '{title:$t, message:$m, data:{priority:"high", ttl:0, channel:"ha_failover"}}')
for t in "${TARGETS[@]}"; do
  c=$(code "services/notify/$t" "$body"); out "notify $t: $( [ "$c" = 200 ] && echo sent || echo "FAILED (HTTP $c)" )"
done
c=$(code services/persistent_notification/create "$(jq -n --arg t "$TITLE" --arg m "$MSG" '{title:$t, message:$m, notification_id:"ha_failover"}')")
out "persistent notification: $( [ "$c" = 200 ] && echo created || echo "FAILED (HTTP $c)" )"
