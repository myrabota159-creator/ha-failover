# HA Failover

**Status: work in progress, not ready for use yet.**

[Русский](#русский) · [English](#english)

## Русский

Горячий резерв для Home Assistant OS: второй HA (виртуальная машина или ещё один одноплатный ПК) постоянно копирует конфигурацию основного, сам замечает его отказ, отрезает основной от сети через управляемый коммутатор и берёт на себя его адрес. Обратно на основной работа возвращается одной кнопкой.

### Что входит

| Дополнение | Куда ставить | Что делает |
|---|---|---|
| **HA Failover Primary** | основной HA | отдаёт резерву снимки конфигурации, состояние здоровья, отправляет уведомления |
| **HA Failover Standby** | резервный HA | копирование, сторож, переключение, возврат, уведомления, проверка готовности и учения |

Настройка сети (коммутатор с SNMPv3, роутер) описана в инструкции в `docs/`.

### Требования

- Home Assistant OS на обоих узлах, в одной сети.
- Управляемый коммутатор с SNMPv3, через который основной узел подключён к сети.
- Координатор Zigbee **сетевой** (например, SLZB-06/MR-серии): USB-координатор на резерв не переедет.

### Установка

Будет описана, когда дополнения будут готовы. Ссылка на репозиторий для HA: `https://github.com/myrabota159-creator/ha-failover`.

## English

Hot standby for Home Assistant OS: a second HA (a virtual machine or another single-board computer) continuously copies the primary's configuration, detects a failure on its own, cuts the primary off the network through a managed switch and takes over its address. Returning to the primary is a single button.

### Contents

| Add-on | Install on | Purpose |
|---|---|---|
| **HA Failover Primary** | primary HA | serves configuration snapshots and health to the standby, sends notifications |
| **HA Failover Standby** | standby HA | replication, watchdog, failover, return, notifications, preflight check and drills |

Network setup (SNMPv3 managed switch, router) is described in `docs/`.

### Requirements

- Home Assistant OS on both nodes, on the same network.
- A managed switch with SNMPv3 that connects the primary to the network.
- A **network** Zigbee coordinator (e.g. SLZB-06/MR series): a USB coordinator cannot move to the standby.

### Installation

Will be described once the add-ons are ready. Repository URL for HA: `https://github.com/myrabota159-creator/ha-failover`.

## License

MIT
