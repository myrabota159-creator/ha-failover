#!/bin/bash
# HA Failover Primary: create the TLS key and token once, print the pairing data, start the HTTPS API.
set -euo pipefail
umask 077
O=/data/options.json
log(){ echo "[$(date '+%F %T')] $*"; }
if [ ! -s /data/key.pem ] || [ ! -s /data/cert.pem ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36500 \
    -subj "/CN=ha-failover-primary" -keyout /data/key.pem -out /data/cert.pem 2>/dev/null
  log "new TLS key created"
fi
opt_token=$(jq -r '.token // ""' "$O")
if [ -n "$opt_token" ]; then
  printf '%s' "$opt_token" > /data/token
elif [ ! -s /data/token ]; then
  head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > /data/token
  log "new token created"
fi
[ "$(wc -c < /data/token)" -ge 24 ] || { log "ABORT: token shorter than 24 characters"; exit 1; }
pin=$(openssl x509 -in /data/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
log "pairing data for the standby add-on (keep the token secret):"
log "  primary_api_port: $(jq -r '.port' "$O")"
log "  primary_pin: $pin"
if [ "$(jq -r '.show_token // false' "$O")" = true ]; then
  log "  primary_token: $(cat /data/token)"
  log "  (turn show_token off after copying it)"
else
  log "  primary_token: hidden, set show_token: true for one start to see it"
fi
exec python3 -u /server.py
