# Podkop Forge — заметки для Claude

Форк itdoginfo/podkop (через yandexru45/podkop-evolution). GitHub: `Jedakaya/podkop-forge`, ветка `main`.
Целевая платформа — OpenWrt (router "Asus", aarch64), shell — `/bin/ash` (POSIX/busybox, без bashизмов).

## Где что искать

- `README.md`, раздел **«Что исправлено в этом форке»** — журнал доработок поверх апстрима с описанием проблемы и фикса. Перед расследованием бага сначала проверь, не описан ли он уже там.
- `podkop/files/usr/bin/podkop` — основной скрипт (start/stop/reload/restart, диспетчер команд, генерация конфига sing-box, list_update, subscription_update). Большой файл (~3700+ строк) — используй Grep по именам функций, не читай целиком.
- `podkop/files/etc/init.d/podkop` — procd init-скрипт: `start_service`, `service_triggers` (BadWAN-мониторинг через `procd_add_interface_trigger`, `config.change` триггер на `restart`).
- `podkop/files/usr/lib/constants.sh` — все константы (теги sing-box, порты, имена nft-таблиц/сетов, версии).
- `podkop/files/usr/lib/logging.sh` — `log()`/`echolog()`/`nolog()`.
- `podkop/files/usr/lib/nft.sh`, `sing_box_config_manager.sh`, `sing_box_config_facade.sh`, `rulesets.sh`, `helpers.sh` — вспомогательные библиотеки, подключаются из `usr/bin/podkop`.

## Известные механизмы (чтобы не переоткрывать каждый раз)

- **Lifecycle lock (с v0.7.43):** `acquire_lifecycle_lock()` в `usr/bin/podkop` — `flock` на `/var/run/podkop.lock` (fd 9), сериализует `start`/`stop`/`restart`/`reload`/`subscription_update`. Решает гонку между стартовым `podkop start` (procd) и BadWAN-триггером `podkop reload` при поднятии WAN на загрузке (см. README). Фоновая `list_update &` наследует fd 9 — лок держится до её завершения.
- **`shutdown_correctly`** (`podkop.settings.shutdown_correctly`, UCI) — `0` после успешного `start()`, `1` после `stop()`. Гейтит `dnsmasq_configure`/`dnsmasq_restore`.
- **Хеш конфига sing-box** — генерируется временный `/etc/sing-box/config.json`, его хеш сравнивается с текущим («Current» vs «Temporary» в логах). При совпадении — «sing-box configuration is unchanged», sing-box не перезапускается.
- **BadWAN-мониторинг** (`enable_badwan_interface_monitoring`, `badwan_monitored_interfaces`, `badwan_reload_delay`) — намеренно оставлен включённым (самолечение при проблемах с WAN), не отключать как «фикс».

## Git-конвенции этого репозитория

- Коммиты — **на русском**, формат `тип: описание` (`fix:`, `feat:`, `документация:` и т.п.).
- **Без** `Co-Authored-By` трейлера — пользователь явно просил коммитить без соавторства.
- Релизы — аннотированные теги `vX.Y.Z`, инкремент patch-версии на каждый релиз, пушатся вместе с `main`.
