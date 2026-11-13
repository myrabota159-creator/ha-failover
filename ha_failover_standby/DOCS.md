# HA Failover Standby

**Work in progress.** Install on the standby Home Assistant OS node.

## Options

| Option | Default | Meaning |
|---|---|---|
| `primary_host` | — | Address of the primary HA. The standby takes it over on failover. |
| `primary_api_port`, `primary_pin`, `primary_token` | `8765`, —, — | API of the **HA Failover Primary** add-on: copy the values from its log. The pin fixes the server key, so nobody else can pretend to be the primary. |
| `primary_ha_port` | `8123` | HA web port on the primary. |
| `primary_extra_ports` | `[1883]` | More TCP ports that prove the primary is alive. |
| `interval_minutes`, `keep` | `15`, `96` | Snapshot interval and how many snapshots to keep. |
| `addons` | `[core_mosquitto]` | Add-ons taken over on failover (slugs as on the primary). The broker (`*mosquitto`) starts first. Install them here too, with `boot: manual`. |
| `network_interface` | auto | Interface that takes the primary address. Empty = Supervisor's primary interface. |
| `primary_prefix`, `gateway`, `dns` | auto | Static settings used after takeover. Empty / `0` = copied from this node's current settings. |
| `required_hosts` | `[]` | Hosts this node must reach before it blames the primary: `host` (ping) or `host:port` (ping or TCP), e.g. a network Zigbee coordinator. |
| `switch_host` | — | Managed switch with SNMPv3. |
| `primary_switch_port` | — | Switch port (ifIndex) of the primary. |
| `test_switch_port` | — | A free port for `port-test`. |
| `snmp_user`, `snmp_auth_protocol`, `snmp_auth_pass`, `snmp_priv_protocol`, `snmp_priv_pass` | —, `SHA`, —, `AES`, — | SNMPv3 `authPriv` user with write access to the primary port only. Older switches may need `DES`. |
| `watchdog_mode` | `off` | `off`, `observe` (log only) or `armed`. Can be changed live with the `set-mode` command (the file `watchdog_mode` overrides this option until cleared). |
| `watchdog_fail_seconds` | `180` | How long the primary must be silent. |
| `ha_check_mode`, `ha_fail_seconds` | `observe`, `480` | Second level: the node answers, but HA does not. |
| `notify_targets` | `[]` | Notify services (without `notify.`) for failover pushes. |
| `language` | `en` | Language of the pushes: `en` or `ru`. |

## Commands

Send with the action `hassio.addon_stdin` (`addon: <slug>`, `input: "<command>"`):

- `dry-run`, `failover I-UNDERSTAND`
- `standby-dry`, `standby I-UNDERSTAND`, `unblock-dry`, `unblock I-UNDERSTAND`
- `return-to-pi-dry`, `return-to-pi-health`, `return-to-pi I-UNDERSTAND`
- `snmp-test`, `port-test I-UNDERSTAND`, `pi-port-up I-UNDERSTAND`
- `notify-test`
- `set-mode off|observe|armed` (or `set-mode default` to clear): change the watchdog mode live, without restarting the add-on. Writes `/share/ha_failover/watchdog_mode`; the effective mode is reflected in `watchdog.json` (refreshed every 10 s, also during the start grace).
- `setup-dry`, `setup I-UNDERSTAND`: add missing add-on repositories, install the managed add-ons, set them to `boot: manual` and stop them
- `preflight`: read-only readiness check, result also in `/share/ha_failover/preflight.json`
- `drill`: read-only restore drill of the latest snapshot in a scratch folder

State files: `/share/ha_failover/status.json`, `/share/ha_failover/watchdog.json`, `/share/ha_failover/notify.log`.

Once an hour the watchdog reads the primary port over SNMPv3 (read only) and stores the result in `watchdog.json` (`switch_ok`, `switch_checked_utc`, `switch_detail`). If the switch stops answering, a push is sent: without the switch the standby cannot disable the primary port and will not fail over.
