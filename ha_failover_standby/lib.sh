#!/bin/bash
# Shared helpers for all standby scripts: options, Supervisor API, SNMP, network auto-detection, messages.
# Sourced, never executed. Nothing here changes state.
O=/data/options.json; R=/share/ha_failover; S=$R/snapshots; AUTH_HDR=/data/auth.hdr
opt(){ jq -r "$1 // empty" "$O"; }

PI=$(opt .primary_host); PORT=$(opt .primary_api_port); PORT=${PORT:-8765}; PIN=$(opt .primary_pin); PIN=${PIN#sha256//}
HA_PORT=$(opt .primary_ha_port); HA_PORT=${HA_PORT:-8123}
mapfile -t PI_EXTRA_PORTS < <(jq -r '.primary_extra_ports[]?' "$O")
SW=$(opt .switch_host); PIP=$(opt .primary_switch_port); TP=$(opt .test_switch_port)
U=$(opt .snmp_user); A=$(opt .snmp_auth_pass); X=$(opt .snmp_priv_pass)
SNMP=(-v3 -l authPriv -u "$U" -a "$(opt .snmp_auth_protocol)" -A "$A" -x "$(opt .snmp_priv_protocol)" -X "$X" -t 3 -r 1 -Oqv)
LANGUAGE=$(opt .language); LANGUAGE=${LANGUAGE:-en}

# Managed add-ons: the MQTT broker (slug ending in "mosquitto") starts first, the rest after it.
mapfile -t ADDON_LIST < <(jq -r '.addons[]?' "$O")
BROKER=""; OTHERS=""
for a in "${ADDON_LIST[@]}"; do case "$a" in *mosquitto) BROKER=$a ;; *) OTHERS="$OTHERS $a" ;; esac; done
OTHERS=${OTHERS# }; ADDONS="${BROKER:+$BROKER }$OTHERS"

sv(){ curl -s -m "${SV_TIMEOUT:-30}" -X "$1" -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
        -H "Content-Type: application/json" ${3:+--data "$3"} "http://supervisor/$2"; }
tcp(){ timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
ping1(){ ping -c 1 -W 2 "$1" >/dev/null 2>&1; }
local_time(){ date '+%d.%m %H:%M'; }   # TZ comes from the Supervisor (container env)

# ---------- network ----------
# Interface: option network_interface, otherwise the Supervisor's primary interface.
IFACE=$(opt .network_interface)
[ -n "$IFACE" ] || IFACE=$(sv GET network/info | jq -r '[.data.interfaces[]? | select(.primary)][0].interface // empty' 2>/dev/null)
IFACE=${IFACE:-eth0}
iface_ipv4(){ sv GET "network/interface/$IFACE/info" | jq -c '.data.ipv4 // {}' 2>/dev/null; }
holds_pi_ip(){ iface_ipv4 | jq -e --arg ip "$PI/" '[.address[]? | startswith($ip)] | any' >/dev/null 2>&1; }
# Static settings used when the VM takes over the primary address. Options win; empty / 0 = take from
# the VM's own current (standby, usually DHCP) settings. Prints "cidr gateway dns1,dns2" or fails.
takeover_net(){
  local cur prefix gw dns
  cur=$(iface_ipv4)
  prefix=$(opt .primary_prefix); [ "${prefix:-0}" != 0 ] || prefix=$(jq -r '.address[0] // "" | split("/")[1] // empty' <<<"$cur")
  gw=$(opt .gateway); [ -n "$gw" ] || gw=$(jq -r '.gateway // empty' <<<"$cur")
  dns=$(jq -r '.dns // [] | join(",")' "$O"); [ -n "$dns" ] || dns=$(jq -r '.nameservers // [] | join(",")' <<<"$cur")
  [ -n "$prefix" ] && [ -n "$gw" ] && [ -n "$dns" ] || { echo "cannot detect prefix/gateway/dns (prefix=$prefix gw=$gw dns=$dns)"; return 1; }
  echo "$PI/$prefix $gw $dns"
}
static_body(){ # $1 cidr $2 gw $3 dns csv
  jq -cn --arg c "$1" --arg g "$2" --arg d "$3" '{ipv4:{method:"static", address:[$c], gateway:$g, nameservers:($d|split(","))}}'
}
# Gateway for the watchdog's own network check: option, otherwise the current one.
gateway(){ local g; g=$(opt .gateway); [ -n "$g" ] && echo "$g" || iface_ipv4 | jq -r '.gateway // empty'; }

# ---------- primary probes ----------
pi_alive_ports(){ echo "$HA_PORT $PORT ${PI_EXTRA_PORTS[*]}"; }
# HTTPS API of the HA Failover Primary add-on. The server key is pinned (self-signed certificate, so -k,
# but curl still refuses any other key); the token is read from a 0600 file, never put on the command line.
# pi_api <GET|POST> <path> [timeout] [auth header file]
pi_api(){
  [ -n "$PI" ] && [ -n "$PIN" ] || { echo "primary_host / primary_pin not set" >&2; return 1; }
  curl -sS --fail -k --pinnedpubkey "sha256//$PIN" --connect-timeout 8 -m "${3:-40}" -X "$1" \
    -H "@${4:-$AUTH_HDR}" "https://$PI:$PORT/v1/$2"; }
pi_health(){ pi_api GET health "${1:-40}"; }

# ---------- switch ----------
port_admin(){ snmpget "${SNMP[@]}" "$SW" "1.3.6.1.2.1.2.2.1.7.$1" 2>/dev/null; }
port_oper(){ snmpget "${SNMP[@]}" "$SW" "1.3.6.1.2.1.2.2.1.8.$1" 2>/dev/null; }
port_set(){ snmpset "${SNMP[@]}" "$SW" "1.3.6.1.2.1.2.2.1.7.$1" i "$2" 2>&1; }   # 1 up, 2 down
is_up(){ [ "$1" = up ] || [ "$1" = 1 ]; }
is_down(){ [ "$1" = down ] || [ "$1" = 2 ] || [ "$1" = lowerLayerDown ] || [ "$1" = 7 ]; }

# ---------- messages ----------
# msg <key> [args...]: printf template in the configured language.
msg(){
  local k=$1; shift; local t
  if [ "$LANGUAGE" = ru ]; then case "$k" in
    test_title) t='HA: проверка уведомлений' ;;
    test_body) t='Тестовое сообщение от резервного HA' ;;
    failover_title) t='HA: переключение на резерв' ;;
    failover_body) t='%s %s. HA запущен на резервном узле с тем же адресом. %s Конфигурация из снимка основного от %s. Возврат на основной только вручную.' ;;
    port_off) t='Порт %s на коммутаторе выключен.' ;;
    port_untouched) t='Коммутатор не настроен, порт основного НЕ выключен: не включайте основной, пока работает резерв.' ;;
    reason_silent) t='Основной HA (%s) не отвечал %s с' ;;
    reason_ha_dead) t='Основной узел в сети, но HA на нём не отвечал %s с' ;;
    reason_default) t='Основной HA (%s) не отвечал' ;;
    resume_title) t='HA: возврат на основной не удался' ;;
    resume_body) t='%s %s. Порт основного снова выключен, HA опять работает на резерве с его последним состоянием. Основной нужно проверить.' ;;
    return_fail_body) t='%s %s. Порт основного выключить не удалось, работает основной, резерв в ожидании. Нужна проверка вручную.' ;;
    reason_port_not_up) t='порт основного не включился' ;;
    reason_core_timeout) t='HA на основном не запустился за %s мин' ;;
    reason_not_ready) t='проверки готовности на основном не прошли за %s мин' ;;
    guard_title) t='HA: порт основного снова выключен' ;;
    guard_body) t='%s Порт %s (основной) оказался включён, пока HA работает на резерве (перезагрузка коммутатора?). Сторож выключил его снова.' ;;
    *) t=$k ;;
  esac; else case "$k" in
    test_title) t='HA: notification test' ;;
    test_body) t='Test message from the standby HA' ;;
    failover_title) t='HA: failover to standby' ;;
    failover_body) t='%s %s. HA is running on the standby node with the same address. %s Configuration from the primary snapshot of %s. Return to the primary is manual only.' ;;
    port_off) t='Switch port %s is disabled.' ;;
    port_untouched) t='No switch configured, the primary port is NOT disabled: keep the primary off while the standby runs.' ;;
    reason_silent) t='Primary HA (%s) silent for %s s' ;;
    reason_ha_dead) t='Primary node is on the network, but its HA did not answer for %s s' ;;
    reason_default) t='Primary HA (%s) did not answer' ;;
    resume_title) t='HA: return to primary failed' ;;
    resume_body) t='%s %s. The primary port is disabled again, HA runs on the standby with its latest state. Check the primary.' ;;
    return_fail_body) t='%s %s. Could not disable the primary port: the primary is running, the standby is idle. Check by hand.' ;;
    reason_port_not_up) t='primary port did not come up' ;;
    reason_core_timeout) t='HA on the primary did not start within %s min' ;;
    reason_not_ready) t='readiness checks on the primary did not pass within %s min' ;;
    guard_title) t='HA: primary port disabled again' ;;
    guard_body) t='%s Port %s (primary) was enabled while HA runs on the standby (switch reboot?). The watchdog disabled it again.' ;;
    *) t=$k ;;
  esac; fi
  # shellcheck disable=SC2059
  printf "$t" "$@"
}
notify_bg(){ # $1 title $2 body $3 wait: fire and forget, log goes to notify.log
  ( /notify.sh "$1" "$2" "${3:-900}" 2>&1 | sed -u "s/^/[notify] /" ) </dev/null >/dev/null 2>&1 &
}
