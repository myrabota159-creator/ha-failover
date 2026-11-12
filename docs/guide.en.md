# HA Failover: guide

[Русская версия](guide.ru.md)

**Status: work in progress.** The add-ons have not been tested on a clean installation yet.

## 1. How it works

- The **primary** HA runs as usual. The **HA Failover Primary** add-on on it serves configuration snapshots
  and a health report over HTTPS to the standby only.
- The **standby** HA (a VM or a second board) runs an empty Home Assistant. The **HA Failover Standby** add-on
  pulls a snapshot every `interval_minutes` into `/share/ha_failover/snapshots`.
- The standby's watchdog checks the primary every 10 s. When the primary is silent for `watchdog_fail_seconds`
  (or its HA does not answer for `ha_fail_seconds`, if that check is armed), and the standby itself sees
  the gateway, the switch and every `required_hosts` entry, it:
  1. disables the primary's port on the managed switch over SNMPv3 and **checks** that the port is down;
  2. makes sure the primary is still silent;
  3. restores the latest snapshot, takes the primary's IP address, starts the add-ons and Home Assistant;
  4. sends a push and blocks replication (`BLOCKED`).
- Without a confirmed port shutdown there is no failover: two live HAs would fight over relays and Zigbee.
- The return to the primary is manual (one command) and checks the primary's health before it finishes;
  if the primary does not get healthy in time, the standby takes over again with its own latest state.

## 2. Requirements and limits

- Home Assistant OS on both nodes, same network segment, same core version (preflight warns otherwise).
- A managed switch with SNMPv3 write access (IF-MIB `ifAdminStatus`). The primary must reach the network
  **only** through its switch port: no Wi-Fi, no second cable, no other path. Otherwise isolation fails
  (the watchdog then refuses to fail over and enables the port back).
- Zigbee and other radios must be **network** devices (e.g. an Ethernet Zigbee coordinator). A USB stick
  stays with the primary.
- A network coordinator usually accepts one TCP client. The standby add-ons stay stopped (`boot: manual`)
  so the standby never connects to it while waiting. The same applies to ESPHome devices with a failsafe:
  the empty standby HA does not connect to them.
- Not replicated: the recorder database (`home-assistant_v2.db`), so history starts fresh after failover;
  Python packages of custom integrations (they need internet on the first start on the standby).
- Changes made on the standby while it is primary are kept in `/share/ha_failover/primary-<time>.tgz` on the
  standby, but **are not copied back** to the primary on return. Copy them by hand if needed.

## 3. Network

### Switch

1. Create an SNMPv3 user with `authPriv` (SHA + AES, or what the switch supports; older models may only
   have DES). Give it a view that allows **write only** to `1.3.6.1.2.1.2.2.1.7.<primary port>` and read
   to IF-MIB (`1.3.6.1.2.1.2`). Do not keep SNMPv1/v2c communities.
2. Allow SNMP and management only from the standby address (trusted hosts / access profile / ACL).
   Some switches (e.g. D-Link DGS-1210) drop **all** replies to addresses that are not trusted, including
   ping and syslog: add every address that must talk to the switch.
3. Save the configuration, reboot the switch once and check that the SNMPv3 user survived.
4. An SNMP port shutdown is normally **not saved** to the startup configuration: after a switch reboot the
   primary port comes up again. While the standby is primary, its watchdog disables the port again and
   sends a push.
5. Pick a free port for `test_switch_port`: `port-test` disables and enables it to prove that writes work.

### Router and addresses

- Reserve the primary's address outside the DHCP pool (or as a reservation) so no other device gets it while
  the primary is off.
- Do **not** bind the primary's address to its MAC with a static ARP entry or ARP "reply-only" mode: after
  failover the same address answers with the standby's MAC. The standby announces itself when it takes the
  address; most devices update within seconds, some within a few minutes.
- The standby's own address can be a DHCP reservation; on failover it switches to static settings
  (address of the primary, prefix, gateway, DNS taken from its current settings unless set in the options).

## 4. Hypervisor and power (standby as a VM)

- Start the VM automatically with the host, without waiting for a login (Hyper-V: *Automatic start action:
  Always start*; Proxmox: *Start at boot*).
- No sleep or hibernation on the host; schedule host updates and reboots.
- Keep the host clock synchronised; give the VM a static MAC if the hypervisor otherwise may change it
  (DHCP reservations depend on it).
- Put the host, the switch and the router on a UPS: the standby only helps if it outlives the primary.

## 5. Installation

Commands for the standby are sent in Developer tools > Actions:

```yaml
action: hassio.app_stdin        # hassio.addon_stdin with field addon instead of app on older versions
data:
  app: <repository hash>_ha_failover_standby
  input: preflight
```

Results appear in the add-on log. Commands that change something need the word `I-UNDERSTAND`;
every one of them has a `-dry` variant or is preceded by a read-only check.

1. **Repository.** On both nodes: Settings > Add-ons > Add-on store > Repositories, add
   `https://github.com/myrabota159-creator/ha-failover`.
2. **Primary.** Install *HA Failover Primary*. Options: `allowed_sources` = standby address (`a.b.c.d/32`),
   `checks` (e.g. `binary_sensor.zigbee2mqtt_bridge_connection_state=on`, `zha`), `notify_targets`,
   `language`. Set `show_token: true`, start, copy `primary_api_port`, `primary_pin` and `primary_token`
   from the log, then `show_token: false` and restart.
3. **Standby.** Install Home Assistant OS with the same version as the primary, do not add integrations.
   Install *HA Failover Standby* and fill in: `primary_host`, the three pairing values, `addons`
   (slugs as on the primary: the broker plus Zigbee2MQTT, ESPHome and so on), `required_hosts`
   (e.g. the Zigbee coordinator as `host:port`), switch and SNMP settings, `notify_targets`, `language`.
   Leave `watchdog_mode: off`. Start it.
4. Wait for the first snapshot (log line `ok <time>.tar`), then run `return-to-pi-health`: it must show the
   health JSON and a refusal for a wrong token.
5. `setup-dry`, then `setup I-UNDERSTAND`: adds repositories, installs the add-ons, sets them to manual and
   stops them.
6. `snmp-test`, then `port-test I-UNDERSTAND` (free test port only).
7. `notify-test`, `preflight`, `drill`, `dry-run`. Fix every FAIL.
8. Set `watchdog_mode: observe` for a few days and read the log: lines `OBSERVE:` show when an armed watchdog
   would have acted. Then set `watchdog_mode: armed`. Arm `ha_check_mode` separately, only if you want a
   failover when the node answers but HA does not.
   The mode can also be changed without a restart: command `set-mode off|observe|armed`. The choice is kept
   in `/share/ha_failover/watchdog_mode` and overrides the `watchdog_mode` option until `set-mode default`
   is sent. A ready-made switch for the standby's HA: [examples/watchdog_mode_switch](../examples/watchdog_mode_switch).
9. Import the blueprints from `blueprints/` on the primary (they reach the standby with the snapshot).

## 6. Operation

| Situation | What to do |
|---|---|
| Planned work on the primary | `set-mode observe` on the standby first (or the switch from the example), back to `set-mode armed` afterwards. |
| Manual failover | Switch the primary off, then `dry-run`, `failover I-UNDERSTAND`. The failover disables the primary port and confirms it first; without a configured switch it warns and leaves the port alone, then keep the primary off. |
| Back to the primary | Power the primary on (its port is still disabled), then `return-to-pi-dry`, `return-to-pi I-UNDERSTAND`. On success: push from the primary, replication resumes. |
| Return failed | The standby is primary again with its own latest state; check the primary, try again later. |
| Manual undo | `standby I-UNDERSTAND`, then `pi-port-up I-UNDERSTAND`, check the primary, `unblock I-UNDERSTAND`. |

State files on the standby: `/share/ha_failover/status.json` (replication), `watchdog.json` (effective watchdog
mode and state), `watchdog_mode` (mode chosen with `set-mode`), `preflight.json`, `notify.log`.
During the first 300 s after the add-on starts the watchdog evaluates nothing and does not refresh `watchdog.json`.

## 7. Troubleshooting

- **Replication fails with a pin error**: the primary add-on got a new TLS key (fresh install); copy the new
  `primary_pin`.
- **HTTP 403 / connection refused**: the standby address is not in `allowed_sources`.
- **`switch SNMP` in the watchdog state**: wrong SNMP user, protocols, passwords, or the switch does not trust
  the standby address. The watchdog does not blame the primary while it cannot reach the switch.
- **Zigbee2MQTT stays in an error state after a network outage**: use the Zigbee2MQTT blueprint.
