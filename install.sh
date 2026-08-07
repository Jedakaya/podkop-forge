#!/bin/sh
# shellcheck shell=dash

REPO="https://api.github.com/repos/Jedakaya/podkop-forge/releases/latest"
DOWNLOAD_DIR="/tmp/podkop"
COUNT=3

# Cached flag to switch between ipk or apk package managers
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

msg() {
    printf "\033[32;1m%s\033[0m\n" "$1"
}

pkg_is_installed () {
    local pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # grep -q should work without change based on example from documentation
        # apk list --installed --providers dnsmasq
        # <dnsmasq> dnsmasq-full-2.90-r3 x86_64 {feeds/base/package/network/services/dnsmasq} (GPL-2.0) [installed]
        apk list --installed | grep -q "$pkg_name"
    else
        opkg list-installed | grep -q "$pkg_name"
    fi
}

pkg_remove() {
    local pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # TODO: check --force-depends flag
        # Nothing here: https://openwrt.org/docs/guide-user/additional-software/opkg-to-apk-cheatsheet
        apk del "$pkg_name"
    else
        opkg remove --force-depends "$pkg_name"
    fi
}

pkg_list_update() {
    local out
    local rc

    if [ "$PKG_IS_APK" -eq 1 ]; then
        out=$(apk update 2>&1)
    else
        out=$(opkg update 2>&1)
    fi
    rc=$?
    printf '%s\n' "$out"

    [ $rc -eq 0 ] && return 0

    if printf '%s' "$out" | grep -qi "Operation not permitted"; then
        msg "Похоже на проблему с IPv6 (Operation not permitted). Временно отключаю IPv6 и повторяю..."
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1

        if [ "$PKG_IS_APK" -eq 1 ]; then
            out=$(apk update 2>&1)
        else
            out=$(opkg update 2>&1)
        fi
        rc=$?
        printf '%s
' "$out"

        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    fi

    [ $rc -eq 0 ] && return 0

    # A single unreachable feed is enough to make apk exit non-zero: one TLS
    # reset on the telephony repository aborted the whole install while all
    # ten thousand other packages were indexed just fine. Podkop is installed
    # from a file downloaded separately, so a partial index is not a reason to
    # stop — only a completely unusable one is.
    if pkg_index_is_usable "$out"; then
        msg "Часть репозиториев недоступна, но индекс пакетов пригоден — продолжаем"
        return 0
    fi

    return $rc
}

pkg_index_is_usable() {
    local out="$1"
    local count

    if [ "$PKG_IS_APK" -eq 1 ]; then
        count=$(printf '%s' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) distinct packages available.*//p' | tail -n 1)
        [ -n "$count" ] && [ "$count" -gt 0 ]
        return $?
    fi

    # opkg writes one list file per feed; any of them is enough to resolve deps.
    ls /var/opkg-lists/* >/dev/null 2>&1
}

# Если домены GitHub не резолвятся (например, из-за блокировок DNS),
# добавляем статические записи в /etc/hosts. musl-резолвер OpenWrt
# проверяет /etc/hosts раньше DNS, поэтому это помогает wget сразу,
# без перезапуска dnsmasq (его всё равно перезапускаем для LAN-клиентов).
fix_github_dns() {
    local marker="# podkop-forge: github DNS fallback"
    local host
    local broken=0

    grep -qF "$marker" /etc/hosts 2>/dev/null && return

    for host in raw.githubusercontent.com api.github.com github.com; do
        nslookup "$host" >/dev/null 2>&1 || broken=1
    done

    [ "$broken" -eq 0 ] && return

    msg "Домены GitHub не резолвятся, добавляем записи в /etc/hosts..."

    {
        echo "$marker"
        echo "20.205.243.166 github.com"
        echo "20.205.243.168 api.github.com"
        echo "20.205.243.165 codeload.github.com"
        echo "185.199.108.133 raw.githubusercontent.com"
        echo "185.199.109.133 raw.githubusercontent.com"
        echo "185.199.110.133 raw.githubusercontent.com"
        echo "185.199.111.133 raw.githubusercontent.com"
        echo "185.199.108.133 objects.githubusercontent.com"
        echo "185.199.109.133 objects.githubusercontent.com"
        echo "185.199.108.133 release-assets.githubusercontent.com"
        echo "185.199.109.133 release-assets.githubusercontent.com"
    } >> /etc/hosts

    /etc/init.d/dnsmasq restart >/dev/null 2>&1
}

pkg_install() {
    local pkg_file="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted --upgrade "$pkg_file"
    else
        opkg install "$pkg_file"
    fi
}

# Package-manager scratch space. On most OpenWrt builds /var already points
# into tmpfs, but not on every one of them, and an index or a cached archive
# written to the overlay is exactly the transient write that fails first on a
# nearly full flash. Pinning it to RAM costs nothing and removes the doubt.
prepare_ram_scratch() {
    mkdir -p "$DOWNLOAD_DIR" 2>/dev/null
    export TMPDIR="/tmp"
}

# Frees flash that is pure cache: nothing here is needed to keep the router
# running, and all of it is regenerated on demand. Runs before the package
# lists are refreshed so the fresh index lands in the space just reclaimed.
reclaim_flash_space() {
    local before after freed

    before=$(overlay_free_kb)

    # /var is a tmpfs symlink on OpenWrt, so the apk cache and opkg lists under
    # it cost no flash at all — wiping them frees nothing and forces a full
    # re-download of every package index, which is how one flaky feed started
    # aborting installs. Only the opkg lists that genuinely live on the overlay
    # are removed here.
    rm -rf /usr/lib/opkg/lists/* 2>/dev/null
    rm -rf /usr/lib/opkg/tmp/* 2>/dev/null
    rm -f /var/log/*.old /var/log/*.gz 2>/dev/null
    find /tmp -maxdepth 1 -name 'podkop*.apk' -o -maxdepth 1 -name 'podkop*.ipk' 2>/dev/null | while read -r stale; do
        rm -f "$stale"
    done

    after=$(overlay_free_kb)
    freed=$((after - before))

    if [ "$freed" -gt 0 ]; then
        msg "Освобождено кэша на флэш-памяти: $((freed)) КБ"
    fi
}

ROLLBACK_DIR="/tmp/podkop-rollback"

installed_podkop_version() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2>/dev/null | sed -n 's/^podkop-\([0-9][^ ]*\)-r[0-9]* .*//p' | head -n 1
    else
        opkg list-installed 2>/dev/null | sed -n 's/^podkop - \([0-9][^ ]*\)$//p' | head -n 1
    fi
}

# Everything needed to undo an upgrade is staged in RAM: the config file is
# tiny, and the previous packages are re-downloaded rather than kept on the
# overlay, so a router with a few megabytes free pays nothing for the safety
# net. Nothing here survives a reboot, which is the correct lifetime — the
# rollback is only ever needed within this install session.
backup_before_upgrade() {
    local version asset url

    rm -rf "$ROLLBACK_DIR"
    mkdir -p "$ROLLBACK_DIR" || return 1

    [ -f /etc/config/podkop ] && cp /etc/config/podkop "$ROLLBACK_DIR/podkop.config"

    # The pid is what makes the health check meaningful. Without it "sing-box
    # is running" can simply be the old process that was never restarted, so a
    # broken package would pass as healthy and never be rolled back.
    pgrep sing-box 2>/dev/null | head -n 1 > "$ROLLBACK_DIR/singbox.pid"

    version="$(installed_podkop_version)"
    if [ -z "$version" ]; then
        msg "Не удалось определить установленную версию — откат будет только по конфигу"
        return 0
    fi

    printf '%s' "$version" > "$ROLLBACK_DIR/version"
    msg "Готовлю откат на случай неудачи (текущая версия $version)..."

    for asset in podkop luci-app-podkop; do
        url="https://github.com/Jedakaya/podkop-forge/releases/download/v${version}/${asset}-${version}-r1.apk"
        [ "$PKG_IS_APK" -eq 1 ] || url="https://github.com/Jedakaya/podkop-forge/releases/download/v${version}/${asset}_${version}-r1_all.ipk"

        if ! wget -q -O "$ROLLBACK_DIR/$(basename "$url")" "$url"; then
            rm -f "$ROLLBACK_DIR/$(basename "$url")"
            msg "Пакет $asset $version недоступен — откат будет только по конфигу"
            rm -f "$ROLLBACK_DIR/version"
            return 0
        fi
    done

    return 0
}

# The upgrade is only considered good once podkop is actually serving traffic
# again. "The package installed without an error" is not the same thing, and
# telling the two apart is the entire point of this check.
upgrade_is_healthy() {
    local waited=0 before after

    [ -x /usr/bin/podkop ] || return 1

    before="$(cat "$ROLLBACK_DIR/singbox.pid" 2>/dev/null)"

    while [ "$waited" -lt 60 ]; do
        after="$(pgrep sing-box 2>/dev/null | head -n 1)"

        # A pid that is present and different from the one recorded before the
        # upgrade proves sing-box actually came back up under the new package,
        # rather than simply never having been restarted.
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            return 0
        fi

        sleep 3
        waited=$((waited + 3))
    done

    return 1
}

rollback_upgrade() {
    local version pkg restored=0

    msg ""
    msg "Обновление не заработало — откатываю."

    version="$(cat "$ROLLBACK_DIR/version" 2>/dev/null)"

    if [ -n "$version" ]; then
        for pkg in "$ROLLBACK_DIR"/*.apk "$ROLLBACK_DIR"/*.ipk; do
            [ -f "$pkg" ] || continue
            pkg_install "$pkg" && restored=1
        done
    fi

    if [ -f "$ROLLBACK_DIR/podkop.config" ]; then
        cp "$ROLLBACK_DIR/podkop.config" /etc/config/podkop
        msg "Конфигурация восстановлена из резервной копии"
    fi

    /etc/init.d/podkop restart >/dev/null 2>&1

    if [ "$restored" -eq 1 ]; then
        msg "Откат на версию $version выполнен"
    else
        msg "Пакеты откатить не удалось, восстановлена только конфигурация"
        msg "Резервная копия: $ROLLBACK_DIR/podkop.config"
    fi

    if upgrade_is_healthy; then
        msg "Podkop работает после отката"
    else
        msg "Podkop не поднялся и после отката — смотрите logread | grep podkop"
    fi
}

update_config() {
    printf "\033[48;5;196m\033[1m╔══════════════════════════════════════════════════════════════════════╗\033[0m\n"
    printf "\033[48;5;196m\033[1m║ ! Обнаружена старая версия podkop.                                   ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Если продолжите обновление, вам потребуется настроить Podkop заново. ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Старая конфигурация будет сохранена в /etc/config/podkop-070         ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Подробности: https://github.com/Jedakaya/podkop-forge         ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Точно хотите продолжить?                                             ║\033[0m\n"
    printf "\033[48;5;196m\033[1m╚══════════════════════════════════════════════════════════════════════╝\033[0m\n"

    echo ""

    printf "\033[48;5;196m\033[1m╔══════════════════════════════════════════════════════════════════════╗\033[0m\n"
    printf "\033[48;5;196m\033[1m║ ! Detected old podkop version.                                       ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ If you continue the update, you will need to RECONFIGURE podkop.     ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Your old configuration will be saved to /etc/config/podkop-070       ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Details: https://github.com/Jedakaya/podkop-forge              ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Are you sure you want to continue?                                   ║\033[0m\n"
    printf "\033[48;5;196m\033[1m╚══════════════════════════════════════════════════════════════════════╝\033[0m\n"

    msg "Continue? (yes/no)"

    while true; do
            read -r -p '' CONFIG_UPDATE
            case $CONFIG_UPDATE in

            yes|y|Y)
                mv /etc/config/podkop /etc/config/podkop-070
                wget -O /etc/config/podkop https://raw.githubusercontent.com/Jedakaya/podkop-forge/refs/heads/main/podkop/files/etc/config/podkop
                msg "Podkop config has been reset to default. Your old config saved in /etc/config/podkop-070"
                break
                ;;
            *)
                msg "Exit"
                exit 1
                ;;
        esac
    done
}

main() {
    check_system

    prepare_ram_scratch
    reclaim_flash_space

    sing_box

    /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123

    pkg_list_update || { echo "Packages list update failed"; exit 1; }

    PODKOP_IS_UPGRADE=0
    if [ -f "/etc/init.d/podkop" ]; then
        msg "Podkop is already installed. Upgrading..."
        PODKOP_IS_UPGRADE=1
    else
        msg "Installing podkop..."
    fi

    if command -v curl >/dev/null 2>&1; then
        check_response=$(curl -s "https://api.github.com/repos/Jedakaya/podkop-forge/releases/latest")

        if echo "$check_response" | grep -q 'API rate limit '; then
            msg "You've reached the GitHub rate limit. Repeat in five minutes."
            exit 1
        fi
    fi

    local grep_url_pattern
    if [ "$PKG_IS_APK" -eq 1 ]; then
        grep_url_pattern='https://[^"[:space:]]*\.apk'
    else
        grep_url_pattern='https://[^"[:space:]]*\.ipk'
    fi

    wget -qO- "$REPO" | grep -o "$grep_url_pattern" | while read -r url; do
        filename=$(basename "$url")
        filepath="$DOWNLOAD_DIR/$filename"

        attempt=0
        while [ $attempt -lt $COUNT ]; do
            msg "Download $filename (count $((attempt+1)))..."
            if wget -q -O "$filepath" "$url"; then
                if [ -s "$filepath" ]; then
                    msg "$filename successfully downloaded"
                    break
                fi
            fi
            msg "Download error for $filename. Retrying..."
            rm -f "$filepath"
            attempt=$((attempt+1))
        done

        if [ $attempt -eq $COUNT ]; then
            msg "Failed to download $filename after $COUNT attempts"
        fi
    done

    # Check if any files were downloaded
    if ! ls "$DOWNLOAD_DIR"/*podkop* >/dev/null 2>&1; then
        msg "No packages were downloaded successfully"
        exit 1
    fi

    # Checked here, not before the download: only now is the real size of the
    # packages known, and the archives themselves sit in RAM so they cost no
    # flash. Refusing here still leaves the router exactly as it was, which is
    # the whole point — the old flow could stop halfway through installing.
    reclaim_flash_space
    check_available_space || exit 1

    [ "$PODKOP_IS_UPGRADE" -eq 1 ] && backup_before_upgrade

    for pkg in podkop luci-app-podkop; do
        file=""
        for f in "$DOWNLOAD_DIR"/"$pkg"*; do
            if [ -f "$f" ]; then
                file=$(basename "$f")
                break
            fi
        done
        if [ -n "$file" ]; then
            msg "Installing $file..."
            pkg_install "$DOWNLOAD_DIR/$file"
            sleep 3
        fi
    done

    ru=""
    for f in "$DOWNLOAD_DIR"/luci-i18n-podkop-ru*; do
        if [ -f "$f" ]; then
            ru=$(basename "$f")
            break
        fi
    done
    if [ -n "$ru" ]; then
        if pkg_is_installed luci-i18n-podkop-ru; then
                msg "Upgrading Russian translation..."
                pkg_remove luci-i18n-podkop*
                pkg_install "$DOWNLOAD_DIR/$ru"
        else
            msg "Русский язык интерфейса ставим? y/n (Install the Russian interface language?)"
            while true; do
                read -r -p '' RUS
                case $RUS in
                y)
                    pkg_remove luci-i18n-podkop*
                    pkg_install "$DOWNLOAD_DIR/$ru"
                    break
                    ;;
                n)
                    break
                    ;;
                *)
                    echo "Введите y или n"
                    ;;
                esac
            done
        fi
    fi

    find "$DOWNLOAD_DIR" -type f -name '*podkop*' -exec rm {} \;

    if [ "$PODKOP_IS_UPGRADE" -eq 1 ]; then
        msg "Проверяю, что podkop поднялся после обновления..."
        if upgrade_is_healthy; then
            msg "Podkop работает"
            rm -rf "$ROLLBACK_DIR"
        else
            rollback_upgrade
            exit 1
        fi
    fi
}

overlay_free_kb() {
    df /overlay 2>/dev/null | awk 'NR==2 {print $4}'
}

# Space actually needed for the packages sitting in DOWNLOAD_DIR. Installed
# size exceeds the compressed archive, and the package manager briefly holds
# old and new files at once, so the archive size is doubled with a small
# margin on top. This replaced a flat 15 MB constant that by itself refused
# installs on routers with plenty of room for the ~1 MB podkop actually needs.
required_space_kb() {
    local archives_kb
    archives_kb=$(du -sk "$DOWNLOAD_DIR" 2>/dev/null | awk '{print $1}')
    [ -z "$archives_kb" ] && archives_kb=1024
    echo $((archives_kb * 2 + 1024))
}

# Returns 0 if /overlay has enough free space, 1 otherwise.
check_available_space() {
    local avail required
    avail=$(overlay_free_kb)
    required=$(required_space_kb)

    [ -z "$avail" ] && return 0

    if [ "$avail" -lt "$required" ]; then
        msg "Недостаточно места на флэш-памяти"
        msg "Доступно: $((avail)) КБ  |  Требуется: $((required)) КБ"
        report_flash_usage
        return 1
    fi
    return 0
}

# Printed only when an install is refused: guessing what to delete is the worst
# part of hitting a full overlay, so the script names the biggest candidates
# instead of leaving the user to hunt for them.
report_flash_usage() {
    msg ""
    msg "Что занимает место на /overlay (топ-10):"
    du -sk /overlay/upper/* 2>/dev/null | sort -rn | head -10 | while read -r size path; do
        msg "  $((size)) КБ  $path"
    done
    msg ""
    msg "Установленные пакеты по размеру можно посмотреть так:"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        msg "  apk list --installed --quiet | xargs -n1 apk info --size 2>/dev/null | sort -rn | head"
    else
        msg "  opkg list-installed | cut -d' ' -f1 | xargs -n1 opkg info | grep -A1 ^Package"
    fi
}

# Removes installed podkop packages to free overlay space before upgrade.
# Keeps /etc/config/podkop (opkg/apk preserves conffiles by default).
uninstall_podkop_packages() {
    msg "Останавливаю podkop перед обновлением..."
    /usr/bin/podkop stop 2>/dev/null || true
    sleep 1

    msg "Удаляю старые пакеты podkop чтобы освободить место..."
    for pkg in luci-i18n-podkop-ru luci-app-podkop podkop; do
        if pkg_is_installed "$pkg"; then
            pkg_remove "$pkg" || true
        fi
    done
}

check_system() {
    # Get router model
    MODEL=$(cat /tmp/sysinfo/model)
    msg "Router model: $MODEL"

    # Check OpenWrt version
    openwrt_version=$(cat /etc/openwrt_release | grep DISTRIB_RELEASE | cut -d"'" -f2 | cut -d'.' -f1)
    if [ "$openwrt_version" = "23" ]; then
        msg "OpenWrt 23.05 не поддерживается начиная с podkop 0.5.0"
        msg "Для OpenWrt 23.05 используйте podkop версии 0.4.11 или устанавливайте зависимости и podkop вручную"
        msg "Подробности: https://podkop.net/docs/install/#%d1%83%d1%81%d1%82%d0%b0%d0%bd%d0%be%d0%b2%d0%ba%d0%b0-%d0%bd%d0%b0-2305"
        exit 1
    fi

    if ! nslookup google.com >/dev/null 2>&1; then
        msg "DNS is not working."
        exit 1
    fi

    fix_github_dns

    # Check version
    if command -v podkop > /dev/null 2>&1; then
        local version
        version=$(/usr/bin/podkop show_version 2> /dev/null)
        if [ -n "$version" ]; then
            version=$(echo "$version" | sed 's/^v//')
            local major
            local minor
            local patch
            major=$(echo "$version" | cut -d. -f1)
            minor=$(echo "$version" | cut -d. -f2)
            patch=$(echo "$version" | cut -d. -f3)

            # Compare version: must be >= 0.7.0
            if [ "$major" -gt 0 ] ||
                [ "$major" -eq 0 ] && [ "$minor" -gt 7 ] ||
                [ "$major" -eq 0 ] && [ "$minor" -eq 7 ] && [ "$patch" -ge 0 ]; then
                msg "Podkop version >= 0.7.0"
                break
            else
                msg "Podkop version < 0.7.0"
                update_config
            fi
        else
            msg "Unknown podkop version"
            update_config
        fi
    fi

    if pkg_is_installed https-dns-proxy; then
        msg "Conflicting package detected: https-dns-proxy. Remove?"

        while true; do
                read -r -p '' DNSPROXY
                case $DNSPROXY in

                yes|y|Y)
                    pkg_remove luci-app-https-dns-proxy
                    pkg_remove https-dns-proxy
                    pkg_remove luci-i18n-https-dns-proxy*
                    break
                    ;;
                *)
                    msg "Exit"
                    exit 1
                    ;;
        esac
    done
    fi
}

offer_sing_box_extended() {
    msg "В этом форке XHTTP-транспорт из подписок работает только на sing-box-extended"
    msg "(сторонний форк sing-box с поддержкой XHTTP: https://github.com/shtorm-7/sing-box-extended)."
    msg "Установить/обновить sing-box-extended сейчас? [Y/n]"

    while true; do
        read -r -p '' EXTENDED
        case "$EXTENDED" in
        "" | y | Y | yes | Yes | YES)
            msg "Запускаю установщик sing-box-extended (github.com/EikeiDev/OpenWRT-sing-box-extended)..."
            if wget -qO /tmp/sing-box-extended-install.sh "https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/main/install.sh"; then
                sh /tmp/sing-box-extended-install.sh
                rm -f /tmp/sing-box-extended-install.sh
            else
                msg "Не удалось скачать установщик sing-box-extended. Поставьте вручную: https://github.com/EikeiDev/OpenWRT-sing-box-extended"
            fi
            break
            ;;
        n | N | no | No | NO)
            msg "Пропускаем. Без sing-box-extended XHTTP из подписки будет недоступен (сервера будут пропускаться с warn в логе)."
            break
            ;;
        *)
            echo "Введите y или n"
            ;;
        esac
    done
}

sing_box() {
    if pkg_is_installed "^sing-box"; then
        sing_box_version=$(sing-box version | head -n 1 | awk '{print $3}')

        case "$sing_box_version" in
        *extended*)
            msg "Обнаружен sing-box-extended ($sing_box_version, поддерживает XHTTP) — оставляем как есть."
            return
            ;;
        esac

        required_version="1.12.4"

        if [ "$(printf '%s\n%s\n' "$sing_box_version" "$required_version" | sort -V | head -n 1)" != "$required_version" ]; then
            msg "sing-box version $sing_box_version is older than the required version $required_version."
            msg "Removing old version..."
            service podkop stop
            pkg_remove sing-box
        fi
    fi

    offer_sing_box_extended
}

main