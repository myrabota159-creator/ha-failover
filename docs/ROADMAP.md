# Roadmap

1. ~~Remove hard-coded values from the working prototype: everything becomes an option or is auto-detected
   (add-on slugs, entity ids, ZHA entry id, network interface, time zone, notify targets, architectures).~~ Done in 0.8.0.
2. ~~**HA Failover Primary** add-on: small HTTP service (token + source address allow-list) that replaces
   the SSH forced-command approach: `snapshot`, `health`, `notify`.~~ Done: HTTPS with a pinned self-signed key,
   standby 0.9.0 uses it.
3. ~~**HA Failover Standby**: setup wizard (pairing token, install required add-ons with `boot: manual`,
   fix the HTTP port), `preflight` check, `drill` mode, blueprints for Zigbee2MQTT / ZHA self-healing.~~
   Done: commands `setup`, `preflight`, `drill` (standby 0.10.0), blueprints in `blueprints/`.
   Pairing stays manual: values from the primary add-on log go into the standby options.
4. Documentation: switch (SNMPv3, trusted hosts), router (no static ARP for the primary address),
   hypervisor / power settings, step-by-step installation.
