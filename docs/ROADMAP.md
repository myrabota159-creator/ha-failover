# Roadmap

1. Remove hard-coded values from the working prototype: everything becomes an option or is auto-detected
   (add-on slugs, entity ids, ZHA entry id, network interface, time zone, notify targets, architectures).
2. **HA Failover Primary** add-on: small HTTP service (token + source address allow-list) that replaces
   the SSH forced-command approach: `snapshot`, `health`, `notify`.
3. **HA Failover Standby**: setup wizard (pairing token, install required add-ons with `boot: manual`,
   fix the HTTP port), `preflight` check, `drill` mode, blueprints for Zigbee2MQTT / ZHA self-healing.
4. Documentation: switch (SNMPv3, trusted hosts), router (no static ARP for the primary address),
   hypervisor / power settings, step-by-step installation.
