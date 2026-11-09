#!/bin/bash
# Runs on the PRIMARY Home Assistant as the SSH forced command for the standby's key, e.g. in authorized_keys:
#   command="sudo /bin/bash /homeassistant/.replica/export.sh \"${SSH_ORIGINAL_COMMAND:-export}\"",restrict ssh-ed25519 AAAA... ha-failover-standby
# Only three exact requests are accepted (the argument is client-controlled and never used as code):
#   export            -> read-only tar stream: config.tgz, addons/*.json, core.json, db/*.db, created_utc
#   health            -> read-only JSON: {"core":..., "checks":{...}, "ready":true|false}
#   notify-return-ok  -> push with a FIXED text to the targets from export.conf ("HA is back on the primary")
# Settings: export.conf next to this script (see export.conf.example). It is parsed, never sourced.
# Temporary: step 2 of the roadmap replaces this with the "HA Failover Primary" add-on (HTTP instead of SSH).
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd); CONF=$HERE/export.conf
T=$(cat /run/s6/container_environment/SUPERVISOR_TOKEN)
REQ="${1:-export}"
api(){ curl -s -m 20 -H "Authorization: Bearer $T" -H "Content-Type: application/json" "$@"; }

CHECKS=(); NOTIFY=(); LANGUAGE=en
if [ -r "$CONF" ]; then
  while read -r key val _; do
    case "$key" in
      check)    [[ "$val" =~ ^zha$|^[a-z_]+\.[a-z0-9_]+=[A-Za-z0-9_.-]+$ ]] && CHECKS+=("$val") ;;
      notify)   [[ "$val" =~ ^[a-z0-9_]+$ ]] && NOTIFY+=("$val") ;;
      language) [[ "$val" =~ ^(en|ru)$ ]] && LANGUAGE=$val ;;
    esac
  done < <(grep -vE '^\s*(#|$)' "$CONF")
fi

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
    else
      want=${c#*=}; ent=${c%%=*}
      got=$(api "http://supervisor/core/api/states/$ent" | jq -r '.state // "?"' 2>/dev/null || echo "?")
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
tar -C "$W" -cf - ./created_utc ./core.json ./addons ./db ./config.tgz
