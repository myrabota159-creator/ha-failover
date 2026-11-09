# Blueprints

Self-healing automations that keep Zigbee alive after a network outage or a failover. Useful on the primary
and on the standby (after failover the standby runs the primary's configuration, automations included).

| Blueprint | What it does |
|---|---|
| `automation/ha_failover/zigbee2mqtt_self_heal.yaml` | Restarts the Zigbee2MQTT add-on while its bridge stays disconnected; limited retries, notifications, check after HA start. |
| `automation/ha_failover/zha_self_heal.yaml` | Reloads ZHA while its config entry stays in an error / retry state; limited retries, notifications. |

Import in Home Assistant: Settings > Automations & scenes > Blueprints > Import blueprint, paste the GitHub URL of the file.
