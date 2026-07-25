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
            apk update
        else
            opkg update
        fi
        rc=$?

        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    fi

    return $rc
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
    sing_box

    /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123

    pkg_list_update || { echo "Packages list update failed"; exit 1; }

    if [ -f "/etc/init.d/podkop" ]; then
        msg "Podkop is already installed. Upgrading..."
        # Packages are downloaded to /tmp (RAM) — no overlay space check needed.
        # pkg_install upgrades in-place; the package manager handles file replacement.
    else
        msg "Installing podkop..."
        check_available_space || exit 1
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
}

REQUIRED_SPACE=15360 # 15MB in KB

# Returns 0 if /overlay has enough free space, 1 otherwise.
# Prints available/required only on failure.
check_available_space() {
    local avail
    avail=$(df /overlay | awk 'NR==2 {print $4}')
    if [ "$avail" -lt "$REQUIRED_SPACE" ]; then
        msg "Недостаточно места на флэш-памяти"
        msg "Доступно: $((avail/1024)) МБ  |  Требуется: $((REQUIRED_SPACE/1024)) МБ"
        return 1
    fi
    return 0
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