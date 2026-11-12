# Examples

| Example | What it does |
|---|---|
| `watchdog_mode_switch/` | Dropdown on the standby's own Home Assistant that changes the watchdog mode live (`set-mode`, no add-on restart), a sensor with the effective mode and state from `watchdog.json`, and a dashboard. Installation steps are in the comments of `package.yaml` and `dashboard.yaml`. |

The switch lives in the standby's own configuration, which is used while the standby waits on its own address.
After a failover the standby runs the primary's configuration, the switch is not there, and the watchdog is
`blocked` anyway; send `set-mode` from Developer tools > Actions if needed.

## Русский

| Пример | Что делает |
|---|---|
| `watchdog_mode_switch/` | Список на собственном HA резерва, который меняет режим сторожа сразу (`set-mode`, без перезапуска дополнения), датчик фактического режима и состояния из `watchdog.json` и панель. Как установить, написано в комментариях `package.yaml` и `dashboard.yaml`. |

Переключатель находится в собственной конфигурации резерва, она работает, пока резерв ждёт на своём адресе.
После переключения на резерве работает конфигурация основного, переключателя там нет, а сторож всё равно
в состоянии `blocked`; при необходимости отправьте `set-mode` из Инструментов разработчика > Действия.
