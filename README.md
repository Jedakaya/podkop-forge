# Podkop Forge

> **Форк [podkop-evolution](https://github.com/yandexru45/podkop-evolution) с исправлением обновления подписок через прокси**
>
> Основан на [yandexru45/podkop-evolution](https://github.com/yandexru45/podkop-evolution), который в свою очередь основан на [itdoginfo/podkop](https://github.com/itdoginfo/podkop).

---

# Что исправлено в этом форке

## Обновление подписок через прокси (`download_lists_via_proxy=1`)

**Проблема:** При включённой опции `download_lists_via_proxy` podkop скачивал подписки через sing-box mixed proxy (`127.0.0.1:4534`). `wget` на mbedTLS не может корректно выполнить TLS-рукопожатие через CONNECT-туннель sing-box — соединение обрывалось с ошибкой:

```
ssl_handshake returned: (-0x7280) SSL - The connection indicated an EOF
wget rc=8
```

Podkop работал на устаревшем кэше, обновления не применялись.

**Исправление 1 — curl вместо wget при работе через прокси:**
Во всех функциях скачивания (`download_to_file`, `download_subscription`, `check_subscription_connectivity`) заменили `wget` с env-переменными `http_proxy`/`https_proxy` на `curl -x`, который корректно работает с CONNECT-туннелями. Без прокси по-прежнему используется `wget`.

**Исправление 2 — автоматический fallback на прямое соединение:**
Если подписка недоступна через прокси (например, VLESS-сервер не может достучаться до URL подписки), podkop автоматически повторяет попытку напрямую. Если прямое соединение работает — скачивает без прокси. Это корректно решает ситуацию, когда сам роутер может достучаться до сервера подписки, а VLESS-сервер — нет.

**Исправление 3 — убрать ложный `[error]` при fallback:**
`wait_for_subscription_connectivity` логировал `[error]` после исчерпания попыток через прокси, даже когда далее следует успешный fallback. LuCI показывал красный баннер. Изменён уровень на `[warn]`.

## Ложная ошибка версии sing-box в диагностике

**Проблема:** Страница диагностики ошибочно помечала `sing-box-extended` (и вообще любой sing-box версии 1.13.x и выше) как не прошедший проверку минимальной версии (`>= 1.12.4`). Причина — версии вида `1.13.12-extended-2.4.0` разбирались на `major.minor.patch` как простые числа и сравнивались через цепочку `||`/`&&`, которая в POSIX shell из-за левоассоциативности при таких значениях всегда давала неверный результат.

**Исправление:** Сравнение версии в `check_sing_box` переведено на тот же `sort -V`-based хелпер `is_min_package_version`, что уже используется в остальном коде — он корректно ранжирует и версии `-extended`.

---

# Вещи, которые вам нужно знать перед установкой

- Требуется версия OpenWrt 24.10 или новее.
- Необходимо минимум 25 МБ свободного места на роутере.
- При обновлении **обязательно** [сбрасывайте кэш LuCI](https://podkop.net/docs/clear-browser-cache/).
- При старте программы редактируется конфиг Dnsmasq.
- Podkop редактирует конфиг sing-box. Сохраните ваш конфиг sing-box перед установкой, если он вам нужен.
- Dashboard доступен только по http (из-за особенностей clash api).
- [Если у вас что-то не работает.](https://podkop.net/docs/diagnostics/)
- Если у вас установлен Getdomains, [его следует удалить](https://github.com/itdoginfo/domain-routing-openwrt?tab=readme-ov-file#%D1%81%D0%BA%D1%80%D0%B8%D0%BF%D1%82-%D0%B4%D0%BB%D1%8F-%D1%83%D0%B4%D0%B0%D0%BB%D0%B5%D0%BD%D0%B8%D1%8F).

# Документация
https://podkop.net/

# Установка

Один скрипт для установки и обновления:
```
sh <(wget -O - https://raw.githubusercontent.com/Jedakaya/podkop-forge/refs/heads/main/install.sh)
```

---

# Подписки (Subscription URL)

Из podkop-evolution унаследована базовая возможность указать ссылку подписки от провайдера, интеграция с дашбордом (список серверов из подписки, автоматический выбор лучшего по задержке через URLTest, ручное переключение между серверами). Доработки Podkop Forge поверх этого:

- Кнопка «Update subscription» на дашборде — ручное обновление подписки прямо из веб-интерфейса, без захода в терминал
- Поддержка XHTTP-серверов из подписки
- User-Agent при скачивании подписки по умолчанию — `v2rayN/9.99` вместо классического `singbox/<версия>`: многие провайдеры, включая Remnawave, под этим клиентом отдают больше серверов и форматов, в т.ч. XHTTP. Настраивается опцией `subscription_user_agent` (значение `singbox` вернёт классический формат, либо можно указать произвольный UA)

При выборе типа конфигурации **Subscription** в LuCI:

- Введите URL подписки от вашего провайдера
- Выберите интервал автообновления (от 30 минут до 1 дня)
- Все серверы из подписки автоматически появятся в дашборде
- Автоматический выбор лучшего сервера по задержке (URLTest)
- Ручное переключение между серверами через дашборд

При скачивании подписки отправляются заголовки:
- `User-Agent: v2rayN/9.99` (см. выше)
- `X-HWID` — уникальный идентификатор роутера
- `X-Device-OS: OpenWrt Linux`
- `X-Device-Model` — модель роутера
- `X-Ver-OS` — версия ядра

Пример конфигурации через UCI:
```
uci set podkop.my_sub=section
uci set podkop.my_sub.connection_type='proxy'
uci set podkop.my_sub.proxy_config_type='subscription'
uci set podkop.my_sub.subscription_url='https://your-provider.com/api/sub'
uci set podkop.my_sub.subscription_update_interval='1h'
uci add_list podkop.my_sub.community_lists='russia_inside'
uci commit podkop
```

Ручное обновление подписки:
```
/usr/bin/podkop subscription_update
```

---

# Обновление с версии ниже 0.7.0

Начиная с версии 0.7.0 изменена структура конфига `/etc/config/podkop`. Старые значения несовместимы с новыми.

Скрипт установки обнаружит старую версию и предупредит вас. При обновлении вручную:

1. Забэкапить старый конфиг:
```
mv /etc/config/podkop /etc/config/podkop-070
```
2. Стянуть новый дефолтный конфиг:
```
wget -O /etc/config/podkop https://raw.githubusercontent.com/Jedakaya/podkop-forge/refs/heads/main/podkop/files/etc/config/podkop
```
3. Настроить заново ваш Podkop через LuCI или UCI.
