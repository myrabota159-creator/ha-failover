# Changelog

## 0.12.0
- Live watchdog mode switching. The `set-mode off|observe|armed` stdin command
  (and `set-mode default` to clear) changes the watchdog mode **without
  restarting the add-on**. The watchdog re-reads the effective mode every cycle
  from `/share/ha_failover/watchdog_mode`; the add-on option is the fallback when
  that file is absent. The effective mode is shown in `watchdog.json`.

## 0.11.0
- The standby keeps its replication snapshots in its own data folder, separate
  from the earlier prototype.
- Primary add-on log timestamps are shown in local time.

## 0.10.1
- Manual failover now disables the primary's switch port and confirms it is down
  before taking over the address.
- Added the installation and operation guide (English and Russian).

## 0.10.0
- Setup wizard (`setup` / `setup-dry`), read-only `preflight` readiness check and
  `drill` restore drill of the latest snapshot.
- Self-healing blueprints (Zigbee2MQTT / ZHA auto-restart).

## 0.9.0
- Added the companion **HA Failover Primary** add-on; the standby now pulls
  config snapshots over HTTPS (pinned server key + token) instead of SSH.

## 0.8.0
- First working standby add-on and primary export script. All site-specific
  values (addresses, ports, secrets) live in options — nothing hard-coded.
