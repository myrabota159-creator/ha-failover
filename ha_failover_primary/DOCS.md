# HA Failover Primary

**Work in progress.** Install on the primary Home Assistant OS node, next to nothing else: it only serves
data to the **HA Failover Standby** node and never changes anything on this node.

## What it does

A small HTTPS API on `port` (host network):

| Request | Result |
|---|---|
| `GET /v1/snapshot` | tar stream: configuration, settings of installed add-ons, core info, `zigbee.db` (consistent copy) |
| `GET /v1/health` | `{"core": ..., "checks": {...}, "ready": true/false}` |
| `POST /v1/notify-return-ok` | fixed push "back on the primary" to `notify_targets` |
| `GET /v1/ping` | `ok`, to check the pairing |

Every request needs the token, and the connection must come from `allowed_sources`; other sources are dropped
before the TLS handshake. The certificate is self-signed; the standby pins its key (`primary_pin`), so the
snapshot (which contains `secrets.yaml`) is encrypted and only goes to the paired standby.

## Options

| Option | Default | Meaning |
|---|---|---|
| `port` | `8765` | HTTPS port. |
| `allowed_sources` | `[]` | Addresses or networks of the standby, e.g. `192.0.2.46/32`. Empty = refuse everything. |
| `token` | generated | Leave empty to generate a random token once (kept in `/data/token`). |
| `show_token` | `false` | Print the token in the log on the next start; switch off after copying it. |
| `checks` | `[]` | Readiness checks for the return to this node: `<entity_id>=<state>` or `zha`. |
| `notify_targets` | `[]` | Notify services (without `notify.`) for the "back on the primary" push. |
| `language` | `en` | `en` or `ru`. |

## Pairing

1. Install and start this add-on, set `allowed_sources` to the standby address.
2. Set `show_token: true`, restart, copy `primary_api_port`, `primary_pin`, `primary_token` from the log
   into the standby add-on options, then set `show_token: false` and restart.
3. On the standby run the command `return-to-pi-health`: it must show the health JSON and a refusal for a wrong token.

A new TLS key is created only if `/data` is empty (fresh install); then the pin changes and must be copied again.
