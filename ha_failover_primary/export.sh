#!/bin/bash
# Read-only data for the standby, called by server.py (never with client-supplied code):
#   export            -> tar stream: config.tgz, addons/*.json, core.json, repositories.json, db/*.db, created_utc
#   health            -> JSON: {"core":..., "checks":{...}, "ready":true|false}
#   notify-return-ok  -> push with a FIXED text to option notify_targets ("HA is back on the primary")
set -euo pipefail
umask 077
O=/data/options.json
T=$SUPERVISOR_TOKEN
REQ="${1:-}"
api(){ curl -s -m 20 -H "Authorization: Bearer $T" -H "Content-Type: application/json" "$@"; }
mapfile -t CHECKS < <(jq -r '.checks[]?' "$O")
mapfile -t NOTIFY < <(jq -r '.notify_targets[]?' "$O")
LANGUAGE=$(jq -r '.language // "en"' "$O")

case "$REQ" in
health)
  core=$(api http://supervisor/core/api/config | jq -r '.state // "down"' 2>/dev/null || echo down)
  res='{}'; ready=true
  [ "$core" = RUNNING ] || ready=false
  for c in "${CHECKS[@]}"; do
    if [ "$c" = zha ]; then
      want=loaded
      got=$(api -X POST -d '{"template":"{% set e = integration_entities(\"zha\") %}{{ config_entry_attr(config_entry_id(e | first), \"state\") if e else \"none\" }}"}' \
            http://supervisor/core/api/template 2>/dev/null || echo "?")
      got=${got,,}; got=${got#configentrystate.}
    elif [[ "$c" =~ ^[a-z_]+\.[a-z0-9_]+=[A-Za-z0-9_.-]+$ ]]; then
      want=${c#*=}
      got=$(api "http://supervisor/core/api/states/${c%%=*}" | jq -r '.state // "?"' 2>/dev/null || echo "?")
    else
      want=valid; got=invalid-check
    fi
    [ "$got" = "$want" ] || ready=false
    res=$(jq -c --arg k "${c%%=*}" --arg v "$got" '. + {($k): $v}' <<<"$res")
  done
  jq -cn --arg core "$core" --argjson checks "$res" --argjson ready "$ready" '{core:$core, checks:$checks, ready:$ready}'
  exit 0 ;;
notify-return-ok)
  if [ "$LANGUAGE" = ru ]; then
    body='{"title":"HA: работа вернулась на основной","message":"Возврат с резервного узла выполнен, проверки готовности прошли. Резерв снова в ожидании, копирование возобновлено."}'
  else
    body='{"title":"HA: back on the primary","message":"Return from the standby node is done, readiness checks passed. The standby is idle again, replication resumed."}'
  fi
  for t in "${NOTIFY[@]}"; do
    [[ "$t" =~ ^[a-z0-9_]+$ ]] || { echo "$t: invalid name"; continue; }
    echo "$t: HTTP $(api -o /dev/null -w '%{http_code}' -X POST --data "$body" "http://supervisor/core/api/services/notify/$t")"
  done
  exit 0 ;;
export) ;;
*) echo "unknown request" >&2; exit 2 ;;
esac

W=$(mktemp -d /tmp/replica.XXXXXX); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/addons" "$W/db"
for s in $(api http://supervisor/addons | jq -r '.data.addons[]?.slug'); do
  curl -sf -m 30 -H "Authorization: Bearer $T" "http://supervisor/addons/$s/info" > "$W/addons/$s.json"
done
curl -sf -m 30 -H "Authorization: Bearer $T" http://supervisor/core/info > "$W/core.json"
# add-on repositories, so the standby setup can add a missing one before installing an add-on
api http://supervisor/store/repositories | jq -c '[.data[]? | {slug, name, source}]' > "$W/repositories.json"
# SQLite databases that must be copied consistently (ZHA keeps its network in zigbee.db)
for db in zigbee.db; do
  [ -f "/homeassistant/$db" ] && sqlite3 "/homeassistant/$db" ".backup '$W/db/$db'"
done
rc=0
tar -C / -czf "$W/config.tgz" \
  --exclude='homeassistant/home-assistant_v2.db*' --exclude='homeassistant/zigbee.db*' \
  --exclude='homeassistant/home-assistant.log*' --exclude='*.log' --exclude='*.log.[0-9]*' \
  --exclude='homeassistant/tts' --exclude='homeassistant/.cache' --exclude='homeassistant/deps' \
  --exclude='homeassistant/.ha_run.lock' \
  homeassistant || rc=$?
[ "$rc" -le 1 ] || exit "$rc"   # 1 = file changed while reading, acceptable
date -u +%FT%TZ > "$W/created_utc"
tar -C "$W" -cf - ./created_utc ./core.json ./repositories.json ./addons ./db ./config.tgz
