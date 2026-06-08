PODKOP_LIB="/usr/lib/podkop"
. "$PODKOP_LIB/helpers.sh"
. "$PODKOP_LIB/sing_box_config_manager.sh"

sing_box_cf_add_dns_server() {
    local config="$1"
    local type="$2"
    local tag="$3"
    local server="$4"
    local domain_resolver="$5"
    local detour="$6"

    local server_address server_port
    server_address=$(url_get_host "$server")
    server_port=$(url_get_port "$server")

    case "$type" in
    udp)
        [ -z "$server_port" ] && server_port=53
        config=$(sing_box_cm_add_udp_dns_server "$config" "$tag" "$server_address" "$server_port" "$domain_resolver" \
            "$detour")
        ;;
    dot)
        [ -z "$server_port" ] && server_port=853
        config=$(sing_box_cm_add_tls_dns_server "$config" "$tag" "$server_address" "$server_port" "$domain_resolver" \
            "$detour")
        ;;
    doh)
        [ -z "$server_port" ] && server_port=443
        local path headers
        path=$(url_get_path "$server")
        headers="" # TODO(ampetelin): implement it if necessary
        config=$(sing_box_cm_add_https_dns_server "$config" "$tag" "$server_address" "$server_port" "$path" "$headers" \
            "$domain_resolver" "$detour")
        ;;
    *)
        log "Unsupported DNS server type: $type. Aborted." "fatal"
        exit 1
        ;;
    esac

    echo "$config"
}

sing_box_cf_add_mixed_inbound_and_route_rule() {
    local config="$1"
    local tag="$2"
    local listen_address="$3"
    local listen_port="$4"
    local outbound="$5"

    config=$(sing_box_cm_add_mixed_inbound "$config" "$tag" "$listen_address" "$listen_port")
    config=$(sing_box_cm_add_route_rule "$config" "" "$tag" "$outbound")

    echo "$config"
}

sing_box_cf_add_proxy_outbound() {
    local config="$1"
    local section="$2"
    local url="$3"
    local udp_over_tcp="$4"

    local tag
    tag=$(get_outbound_tag_by_section "$section")

    sing_box_cf_add_proxy_outbound_with_tag "$config" "$tag" "$url" "$udp_over_tcp"
}

#######################################
# Same as sing_box_cf_add_proxy_outbound, but takes an explicit outbound tag
# instead of deriving it from a section name. Used for sources that contain
# multiple links needing distinct tags (e.g. subscription link lists), where
# get_outbound_tag_by_section's fixed "<section>-out" naming would collide.
#######################################
sing_box_cf_add_proxy_outbound_with_tag() {
    local config="$1"
    local tag="$2"
    local url="$3"
    local udp_over_tcp="$4"

    url=$(url_decode "$url")
    url=$(url_strip_fragment "$url")

    local scheme
    scheme="$(url_get_scheme "$url")"
    case "$scheme" in
    socks4 | socks4a | socks5)
        local host port version userinfo username password

        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        version="${scheme#socks}"
        if [ "$scheme" = "socks5" ]; then
            userinfo=$(url_get_userinfo "$url")
            if [ -n "$userinfo" ]; then
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
            fi
        fi
        config="$(sing_box_cm_add_socks_outbound \
            "$config" \
            "$tag" \
            "$host" \
            "$port" \
            "$version" \
            "$username" \
            "$password" \
            "" \
            "$([ "$udp_over_tcp" == "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
        )"
        ;;
    vless)
        local host port uuid flow packet_encoding
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        uuid=$(url_get_userinfo "$url")
        flow=$(url_get_query_param "$url" "flow")
        packet_encoding=$(url_get_query_param "$url" "packetEncoding")

        config=$(sing_box_cm_add_vless_outbound "$config" "$tag" "$host" "$port" "$uuid" "$flow" "" "$packet_encoding")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        config=$(_add_outbound_transport "$config" "$tag" "$url")
        ;;
    ss)
        local userinfo host port method password

        userinfo=$(url_get_userinfo "$url")
        if ! is_shadowsocks_userinfo_format "$userinfo"; then
            userinfo=$(base64_decode "$userinfo")
            if [ $? -ne 0 ]; then
                log "Cannot decode shadowsocks userinfo or it does not match the expected format. Aborted." "fatal"
                exit 1
            fi
        fi

        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        method="${userinfo%%:*}"
        password="${userinfo#*:}"

        config=$(
            sing_box_cm_add_shadowsocks_outbound \
                "$config" \
                "$tag" \
                "$host" \
                "$port" \
                "$method" \
                "$password" \
                "" \
                "$([ "$udp_over_tcp" == "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
        )
        ;;
    trojan)
        local host port password
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        password=$(url_get_userinfo "$url")

        config=$(sing_box_cm_add_trojan_outbound "$config" "$tag" "$host" "$port" "$password")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        config=$(_add_outbound_transport "$config" "$tag" "$url")
        ;;
    hysteria2 | hy2)
        local host port password obfuscator_type obfuscator_password upload_mbps download_mbps
        host=$(url_get_host "$url")
        port="$(url_get_port "$url")"
        password=$(url_get_userinfo "$url")
        obfuscator_type=$(url_get_query_param "$url" "obfs")
        obfuscator_password=$(url_get_query_param "$url" "obfs-password")
        upload_mbps=$(url_get_query_param "$url" "upmbps")
        download_mbps=$(url_get_query_param "$url" "downmbps")

        config=$(sing_box_cm_add_hysteria2_outbound "$config" "$tag" "$host" "$port" "$password" "$obfuscator_type" \
            "$obfuscator_password" "$upload_mbps" "$download_mbps")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        ;;
    *)
        log "Unsupported proxy $scheme type. Aborted." "fatal"
        exit 1
        ;;
    esac

    echo "$config"
}

_add_outbound_security() {
    local config="$1"
    local outbound_tag="$2"
    local url="$3"

    local security scheme
    security=$(url_get_query_param "$url" "security")
    if [ -z "$security" ]; then
        scheme="$(url_get_scheme "$url")"
        if [ "$scheme" = "hysteria2" ] || [ "$scheme" = "hy2" ]; then
            security="tls"
        fi
    fi

    case "$security" in
    tls | reality)
        local sni insecure alpn fingerprint public_key short_id
        sni=$(url_get_query_param "$url" "sni")
        insecure=$(_get_insecure_query_param_from_url "$url")
        alpn=$(comma_string_to_json_array "$(url_get_query_param "$url" "alpn")")
        fingerprint=$(url_get_query_param "$url" "fp")
        public_key=$(url_get_query_param "$url" "pbk")
        short_id=$(url_get_query_param "$url" "sid")

        config=$(
            sing_box_cm_set_tls_for_outbound \
                "$config" \
                "$outbound_tag" \
                "$sni" \
                "$([ "$insecure" == "1" ] && echo true)" \
                "$([ "$alpn" == "[]" ] && echo null || echo "$alpn")" \
                "$fingerprint" \
                "$public_key" \
                "$short_id"
        )
        ;;
    none) ;;
    *)
        log "Unknown security '$security' detected." "error"
        ;;
    esac

    echo "$config"
}

_get_insecure_query_param_from_url() {
    local url="$1"

    local insecure
    insecure=$(url_get_query_param "$url" "allowInsecure")
    if [ -z "$insecure" ]; then
        insecure=$(url_get_query_param "$url" "insecure")
    fi

    echo "$insecure"
}

_add_outbound_transport() {
    local config="$1"
    local outbound_tag="$2"
    local url="$3"

    local transport
    transport=$(url_get_query_param "$url" "type")
    case "$transport" in
    tcp | raw) ;;
    ws)
        local ws_path ws_host ws_early_data
        ws_path=$(url_get_query_param "$url" "path")
        ws_host=$(url_get_query_param "$url" "host")
        ws_early_data=$(url_get_query_param "$url" "ed")

        config=$(
            sing_box_cm_set_ws_transport_for_outbound "$config" "$outbound_tag" "$ws_path" "$ws_host" "$ws_early_data"
        )
        ;;
    grpc)
        # TODO(ampetelin): Add handling of optional gRPC parameters; example links are needed.
        local grpc_service_name
        grpc_service_name=$(url_get_query_param "$url" "serviceName")

        config=$(
            sing_box_cm_set_grpc_transport_for_outbound "$config" "$outbound_tag" "$grpc_service_name"
        )
        ;;
    xhttp)
        # Mainline sing-box doesn't know this transport ("unknown transport
        # type: xhttp") - only the third-party sing-box-extended fork does.
        # We still build the outbound; callers that add it via a subscription
        # (sing_box_cf_add_subscription_outbounds) run it through `sing-box
        # check` and silently drop it when the running build can't use it.
        local xhttp_path xhttp_host xhttp_mode xhttp_extra
        xhttp_path=$(url_get_query_param "$url" "path")
        xhttp_host=$(url_get_query_param "$url" "host")
        xhttp_mode=$(url_get_query_param "$url" "mode")
        xhttp_extra=$(url_get_query_param "$url" "extra")

        config=$(
            sing_box_cm_set_xhttp_transport_for_outbound "$config" "$outbound_tag" "$xhttp_path" "$xhttp_host" "$xhttp_mode" "$xhttp_extra"
        )
        ;;
    *)
        log "Unknown transport '$transport' detected." "error"
        ;;
    esac

    echo "$config"
}

sing_box_cf_add_json_outbound() {
    local config="$1"
    local section="$2"
    local json_outbound="$3"

    local tag
    tag=$(get_outbound_tag_by_section "$section")

    config=$(sing_box_cm_add_raw_outbound "$config" "$tag" "$json_outbound")

    echo "$config"
}

sing_box_cf_add_interface_outbound() {
    local config="$1"
    local section="$2"
    local interface_name="$3"

    local tag
    tag=$(get_outbound_tag_by_section "$section")

    config=$(sing_box_cm_add_interface_outbound "$config" "$tag" "$interface_name")

    echo "$config"
}

sing_box_cf_proxy_domain() {
    local config="$1"
    local inbound="$2"
    local domain="$3"
    local outbound="$4"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_route_rule "$config" "$tag" "$inbound" "$outbound")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "domain" "$domain")

    echo "$config"
}

sing_box_cf_override_domain_port() {
    local config="$1"
    local domain="$2"
    local port="$3"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_options_route_rule "$config" "$tag")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "domain" "$domain")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "override_port" "$port")

    echo "$config"
}

sing_box_cf_add_single_key_reject_rule() {
    local config="$1"
    local inbound="$2"
    local key="$3"
    local value="$4"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_reject_route_rule "$config" "$tag" "$inbound")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "$key" "$value")

    echo "$config"
}

#######################################
# Parse a downloaded subscription file and add all usable proxy outbounds to
# the configuration. Auto-detects the subscription format (see
# detect_subscription_format) and dispatches to the matching parser:
#   sing-box-json - a sing-box config with an "outbounds" array (default/legacy format)
#   link-list     - a base64 blob of newline-separated proxy URLs, returned by
#                   some providers (e.g. Remnawave) for v2rayN-like User-Agents,
#                   and the only way to reach servers using XHTTP transport
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   section: string, the UCI section name
#   subscription_path: string, path to the downloaded subscription file
# Outputs:
#   Writes updated JSON configuration to stdout
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS (comma-separated list of tags)
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS_JSON (JSON array of tags, ASCII-escaped)
#   Sets global variable SUBSCRIPTION_OUTBOUND_NAMES (newline-separated list of display names)
#######################################
sing_box_cf_add_subscription_outbounds() {
    local config="$1"
    local section="$2"
    local subscription_path="$3"

    SUBSCRIPTION_OUTBOUND_TAGS=""
    SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_NAMES=""
    SING_BOX_CF_LAST_CONFIG="$config"

    if [ ! -f "$subscription_path" ]; then
        log "Subscription file not found: $subscription_path" "error"
        echo "$config"
        return 1
    fi

    case "$(detect_subscription_format "$subscription_path")" in
    link-list)
        _sing_box_cf_add_subscription_outbounds_from_link_list "$config" "$section" "$subscription_path"
        ;;
    xray-config-list)
        _sing_box_cf_add_subscription_outbounds_from_xray_config_list "$config" "$section" "$subscription_path"
        ;;
    *)
        _sing_box_cf_add_subscription_outbounds_from_json "$config" "$section" "$subscription_path"
        ;;
    esac
}

#######################################
# Parse a sing-box subscription JSON and add all proxy outbounds to the configuration.
# Filters out non-proxy types (selector, urltest, direct, dns, block).
# Uses 'tag' field (or 'remark' if present) as display name for each outbound.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   section: string, the UCI section name
#   subscription_json_path: string, path to the downloaded subscription JSON file
# Outputs:
#   Writes updated JSON configuration to stdout
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS (comma-separated list of tags)
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS_JSON (JSON array of tags, ASCII-escaped)
#   Sets global variable SUBSCRIPTION_OUTBOUND_NAMES (newline-separated list of display names)
#######################################
_sing_box_cf_add_subscription_outbounds_from_json() {
    local config="$1"
    local section="$2"
    local subscription_json_path="$3"

    # Extract proxy outbounds from subscription JSON
    # Filter out non-proxy types: selector, urltest, direct, dns, block
    local outbounds_count
    outbounds_count=$(jq -r '[.outbounds[] | select(
        .type != "selector" and
        .type != "urltest" and
        .type != "direct" and
        .type != "dns" and
        .type != "block"
    )] | length' "$subscription_json_path" 2>/dev/null)

    if [ -z "$outbounds_count" ] || [ "$outbounds_count" -eq 0 ]; then
        log "No proxy outbounds found in subscription JSON" "error"
        echo "$config"
        return 1
    fi

    log "Found $outbounds_count proxy outbounds in subscription" "info"

    local i=1
    local added_count=0
    local outbound_json display_name outbound_tag outbound_type outbound_tls_enabled preferred_tag base_tag tag_suffix

    while [ "$i" -le "$outbounds_count" ]; do
        # Extract the i-th proxy outbound as raw JSON
        outbound_json=$(jq -c "[.outbounds[] | select(
            .type != \"selector\" and
            .type != \"urltest\" and
            .type != \"direct\" and
            .type != \"dns\" and
            .type != \"block\"
        )][$i - 1]" "$subscription_json_path" 2>/dev/null)

        if [ -z "$outbound_json" ] || [ "$outbound_json" = "null" ]; then
            i=$((i + 1))
            continue
        fi

        # Get display name: prefer remark, then tag, then fallback
        display_name=$(echo "$outbound_json" | jq -r '.remark // .tag // "server-'"$i"'"' 2>/dev/null)

        outbound_type=$(echo "$outbound_json" | jq -r '.type // ""' 2>/dev/null)
        outbound_tls_enabled=$(echo "$outbound_json" | jq -r '.tls.enabled // false' 2>/dev/null)

        # sing-box does not support top-level tls field for shadowsocks outbound.
        if [ "$outbound_type" = "shadowsocks" ] && [ "$outbound_tls_enabled" = "true" ]; then
            log "Skip unsupported Shadowsocks outbound with tls: '$display_name'" "warn"
            i=$((i + 1))
            continue
        fi

        # Keep original tag from the subscription for dashboard readability.
        preferred_tag=$(echo "$outbound_json" | jq -r '.tag // .remark // "server-'"$i"'"' 2>/dev/null)
        if [ -z "$preferred_tag" ] || [ "$preferred_tag" = "null" ]; then
            preferred_tag="server-$i"
        fi

        base_tag="$preferred_tag"
        outbound_tag="$base_tag"
        tag_suffix=1
        while printf '%s' "$config" | jq -e --arg tag "$outbound_tag" '.outbounds[]? | select(.tag == $tag)' > /dev/null 2>&1; do
            outbound_tag="${base_tag}-$tag_suffix"
            tag_suffix=$((tag_suffix + 1))
        done

        # Remove tag from raw outbound (it will be set by sing_box_cm_add_raw_outbound)
        local clean_outbound
        clean_outbound=$(echo "$outbound_json" | jq -c 'del(.tag) | del(.remark)' 2>/dev/null)

        local updated_config
        updated_config=$(sing_box_cm_add_raw_outbound "$config" "$outbound_tag" "$clean_outbound" 2>/dev/null)
        if [ -z "$updated_config" ]; then
            log "Skip invalid outbound from subscription: '$display_name'" "warn"
            i=$((i + 1))
            continue
        fi

        # Validate against current sing-box version and skip unsupported outbounds.
        local validation_tmp
        validation_tmp="$(mktemp)"
        sing_box_cm_save_config_to_file "$updated_config" "$validation_tmp"
        if ! sing-box -c "$validation_tmp" check > /dev/null 2>&1; then
            rm -f "$validation_tmp"
            log "Skip unsupported outbound for current sing-box: '$display_name'" "warn"
            i=$((i + 1))
            continue
        fi
        rm -f "$validation_tmp"

        config="$updated_config"

        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS="$outbound_tag"
        else
            SUBSCRIPTION_OUTBOUND_TAGS="$SUBSCRIPTION_OUTBOUND_TAGS,$outbound_tag"
        fi

        # Keep a JSON representation to avoid Unicode corruption in shell string processing.
        SUBSCRIPTION_OUTBOUND_TAGS_JSON=$(
            printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -ac --arg tag "$outbound_tag" '. + [$tag]' 2>/dev/null
        )
        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
        fi

        if [ -z "$SUBSCRIPTION_OUTBOUND_NAMES" ]; then
            SUBSCRIPTION_OUTBOUND_NAMES="$display_name"
        else
            SUBSCRIPTION_OUTBOUND_NAMES="$(printf '%s\n%s' "$SUBSCRIPTION_OUTBOUND_NAMES" "$display_name")"
        fi

        added_count=$((added_count + 1))
        i=$((i + 1))
    done

    log "Added $added_count subscription outbounds for section '$section'" "info"
    SING_BOX_CF_LAST_CONFIG="$config"

    echo "$config"
}

#######################################
# Parse a "Happ-format" subscription - a JSON array where each element is a
# complete Xray-core client config with its own "outbounds" array and a
# "remarks" display name (see is_xray_config_list_subscription) - and add the
# proxy outbound from each entry to the configuration. This is the only known
# format in which some panels (e.g. Remnawave) include Hysteria2 servers; their
# sing-box-json and link-list subscription variants omit Hysteria2 entirely,
# regardless of which User-Agent is used to fetch them.
# Uses each entry's "remarks" as the outbound tag/display name, falling back
# to "server-<n>" when missing.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   section: string, the UCI section name
#   subscription_path: string, path to the downloaded subscription file
# Outputs:
#   Writes updated JSON configuration to stdout
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS (comma-separated list of tags)
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS_JSON (JSON array of tags, ASCII-escaped)
#   Sets global variable SUBSCRIPTION_OUTBOUND_NAMES (newline-separated list of display names)
#######################################
_sing_box_cf_add_subscription_outbounds_from_xray_config_list() {
    local config="$1"
    local section="$2"
    local subscription_path="$3"

    local entries_count
    entries_count=$(jq -r '. | length' "$subscription_path" 2>/dev/null)

    if [ -z "$entries_count" ] || [ "$entries_count" -eq 0 ]; then
        log "No server entries found in subscription server list" "error"
        echo "$config"
        return 1
    fi

    log "Found $entries_count server entries in subscription server list" "info"

    local i=0
    local added_count=0
    local entry_json display_name proxy_outbound_json base_tag outbound_tag tag_suffix updated_config validation_tmp

    while [ "$i" -lt "$entries_count" ]; do
        entry_json=$(jq -c ".[$i]" "$subscription_path" 2>/dev/null)
        i=$((i + 1))

        [ -n "$entry_json" ] && [ "$entry_json" != "null" ] || continue

        # Each entry carries a full Xray client config (own inbounds/outbounds);
        # pick the first proxy outbound we know how to convert and ignore the
        # rest (typically "direct"/"block" helper outbounds).
        proxy_outbound_json=$(printf '%s' "$entry_json" |
            jq -c '[.outbounds[]? | select(.protocol == "vless" or .protocol == "hysteria")][0] // empty' 2>/dev/null)

        display_name=$(printf '%s' "$entry_json" | jq -r ".remarks // \"server-$i\"" 2>/dev/null)
        [ -n "$display_name" ] && [ "$display_name" != "null" ] || display_name="server-$i"

        if [ -z "$proxy_outbound_json" ]; then
            log "Skip subscription server with no supported proxy outbound: '$display_name'" "warn"
            continue
        fi

        base_tag="$display_name"
        outbound_tag="$base_tag"
        tag_suffix=1
        while printf '%s' "$config" | jq -e --arg tag "$outbound_tag" '.outbounds[]? | select(.tag == $tag)' > /dev/null 2>&1; do
            outbound_tag="${base_tag}-$tag_suffix"
            tag_suffix=$((tag_suffix + 1))
        done

        updated_config=$(_sing_box_cf_convert_xray_outbound_to_sing_box "$config" "$outbound_tag" "$proxy_outbound_json" 2>/dev/null)
        if [ -z "$updated_config" ]; then
            log "Skip unsupported subscription server: '$display_name'" "warn"
            continue
        fi

        # Validate against current sing-box capabilities (e.g. XHTTP transport
        # requires sing-box-extended) and skip outbounds it cannot run - the
        # same safety net used for the other subscription formats.
        validation_tmp="$(mktemp)"
        sing_box_cm_save_config_to_file "$updated_config" "$validation_tmp"
        if ! sing-box -c "$validation_tmp" check > /dev/null 2>&1; then
            rm -f "$validation_tmp"
            log "Skip unsupported subscription server for current sing-box: '$display_name'" "warn"
            continue
        fi
        rm -f "$validation_tmp"

        config="$updated_config"

        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS="$outbound_tag"
        else
            SUBSCRIPTION_OUTBOUND_TAGS="$SUBSCRIPTION_OUTBOUND_TAGS,$outbound_tag"
        fi

        # Keep a JSON representation to avoid Unicode corruption in shell string processing.
        SUBSCRIPTION_OUTBOUND_TAGS_JSON=$(
            printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -ac --arg tag "$outbound_tag" '. + [$tag]' 2>/dev/null
        )
        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
        fi

        if [ -z "$SUBSCRIPTION_OUTBOUND_NAMES" ]; then
            SUBSCRIPTION_OUTBOUND_NAMES="$display_name"
        else
            SUBSCRIPTION_OUTBOUND_NAMES="$(printf '%s\n%s' "$SUBSCRIPTION_OUTBOUND_NAMES" "$display_name")"
        fi

        added_count=$((added_count + 1))
    done

    log "Added $added_count subscription outbounds for section '$section'" "info"
    SING_BOX_CF_LAST_CONFIG="$config"

    echo "$config"
}

#######################################
# Converts a single Xray-core proxy outbound (as found inside a "Happ-format"
# subscription entry, see _sing_box_cf_add_subscription_outbounds_from_xray_config_list)
# into a sing-box outbound identified by $tag and appends it to $config.
# Supports:
#   - vless over tcp/raw/ws/grpc/xhttp, with reality or tls security
#   - hysteria v2 -> sing-box hysteria2 (other versions are not supported by sing-box)
# Outputs the updated config and returns 0 on success; outputs nothing and
# returns 1 for unsupported protocols/transports or malformed entries, so the
# caller can skip the server the same way it skips invalid links/outbounds from
# the other subscription formats.
#######################################
_sing_box_cf_convert_xray_outbound_to_sing_box() {
    local config="$1"
    local tag="$2"
    local outbound_json="$3"

    local protocol
    protocol=$(printf '%s' "$outbound_json" | jq -r '.protocol // ""' 2>/dev/null)

    case "$protocol" in
    vless)
        local address port uuid flow network
        address=$(printf '%s' "$outbound_json" | jq -r '.settings.vnext[0].address // ""' 2>/dev/null)
        port=$(printf '%s' "$outbound_json" | jq -r '.settings.vnext[0].port // ""' 2>/dev/null)
        uuid=$(printf '%s' "$outbound_json" | jq -r '.settings.vnext[0].users[0].id // ""' 2>/dev/null)
        flow=$(printf '%s' "$outbound_json" | jq -r '.settings.vnext[0].users[0].flow // ""' 2>/dev/null)
        network=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.network // ""' 2>/dev/null)

        [ -n "$address" ] && [ -n "$port" ] && [ -n "$uuid" ] || return 1

        case "$network" in
        tcp | raw | "" | ws | grpc | xhttp) ;;
        *)
            log "Skip vless outbound '$tag' with unsupported transport '$network'" "warn"
            return 1
            ;;
        esac

        config=$(sing_box_cm_add_vless_outbound "$config" "$tag" "$address" "$port" "$uuid" "$flow" "" "")
        config=$(_xray_set_outbound_security_for_outbound "$config" "$tag" "$outbound_json")
        config=$(_xray_set_outbound_transport_for_outbound "$config" "$tag" "$outbound_json")
        ;;
    hysteria)
        local version address port auth sni alpn
        version=$(printf '%s' "$outbound_json" | jq -r '.settings.version // .streamSettings.hysteriaSettings.version // ""' 2>/dev/null)
        if [ "$version" != "2" ]; then
            log "Skip Hysteria outbound '$tag': only Hysteria2 (version 2) is supported" "warn"
            return 1
        fi

        address=$(printf '%s' "$outbound_json" | jq -r '.settings.address // ""' 2>/dev/null)
        port=$(printf '%s' "$outbound_json" | jq -r '.settings.port // ""' 2>/dev/null)
        auth=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.hysteriaSettings.auth // ""' 2>/dev/null)

        [ -n "$address" ] && [ -n "$port" ] && [ -n "$auth" ] || return 1

        config=$(sing_box_cm_add_hysteria2_outbound "$config" "$tag" "$address" "$port" "$auth" "" "" "" "")

        # Deliberately NOT propagating streamSettings.tlsSettings.fingerprint
        # here. sing-box-extended (and presumably mainline) rejects a Hysteria2
        # (QUIC) outbound configured with a uTLS fingerprint - "unsupported
        # usage for uTLS" - confirmed live on-router: the connection fails
        # before a single packet reaches the server. uTLS fingerprinting
        # emulates a TCP+TLS ClientHello; QUIC has its own TLS 1.3 stack and
        # gains nothing from it.
        sni=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.tlsSettings.serverName // ""' 2>/dev/null)
        alpn=$(printf '%s' "$outbound_json" | jq -c '.streamSettings.tlsSettings.alpn // null' 2>/dev/null)
        config=$(sing_box_cm_set_tls_for_outbound "$config" "$tag" "$sni" "" "$alpn" "" "" "")
        ;;
    *)
        return 1
        ;;
    esac

    echo "$config"
}

_xray_set_outbound_security_for_outbound() {
    local config="$1"
    local tag="$2"
    local outbound_json="$3"

    local security
    security=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.security // ""' 2>/dev/null)

    case "$security" in
    reality)
        local sni fingerprint public_key short_id
        sni=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.realitySettings.serverName // ""' 2>/dev/null)
        fingerprint=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.realitySettings.fingerprint // ""' 2>/dev/null)
        public_key=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.realitySettings.publicKey // ""' 2>/dev/null)
        short_id=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.realitySettings.shortId // ""' 2>/dev/null)

        config=$(sing_box_cm_set_tls_for_outbound "$config" "$tag" "$sni" "" "null" "$fingerprint" "$public_key" "$short_id")
        ;;
    tls)
        local sni fingerprint alpn insecure
        sni=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.tlsSettings.serverName // ""' 2>/dev/null)
        fingerprint=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.tlsSettings.fingerprint // ""' 2>/dev/null)
        alpn=$(printf '%s' "$outbound_json" | jq -c '.streamSettings.tlsSettings.alpn // null' 2>/dev/null)
        insecure=$(printf '%s' "$outbound_json" | jq -r 'if .streamSettings.tlsSettings.allowInsecure == true then "1" else "" end' 2>/dev/null)

        config=$(sing_box_cm_set_tls_for_outbound "$config" "$tag" "$sni" "$([ "$insecure" = "1" ] && echo true)" "$alpn" "$fingerprint" "" "")
        ;;
    none | "") ;;
    *)
        log "Unknown security '$security' in subscription outbound '$tag'" "warn"
        ;;
    esac

    echo "$config"
}

_xray_set_outbound_transport_for_outbound() {
    local config="$1"
    local tag="$2"
    local outbound_json="$3"

    local network
    network=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.network // ""' 2>/dev/null)

    case "$network" in
    tcp | raw | "") ;;
    ws)
        local ws_path ws_host
        ws_path=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.wsSettings.path // ""' 2>/dev/null)
        ws_host=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.wsSettings.host // ""' 2>/dev/null)

        config=$(sing_box_cm_set_ws_transport_for_outbound "$config" "$tag" "$ws_path" "$ws_host" "")
        ;;
    grpc)
        local grpc_service_name
        grpc_service_name=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.grpcSettings.serviceName // ""' 2>/dev/null)

        config=$(sing_box_cm_set_grpc_transport_for_outbound "$config" "$tag" "$grpc_service_name")
        ;;
    xhttp)
        # Mainline sing-box doesn't know this transport - only the third-party
        # sing-box-extended fork does. We still build the outbound; the caller
        # runs it through `sing-box check` and silently drops it when the
        # running build can't use it (same as for link-list subscriptions).
        local xhttp_path xhttp_host xhttp_mode xhttp_extra
        xhttp_path=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.xhttpSettings.path // ""' 2>/dev/null)
        xhttp_host=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.xhttpSettings.host // ""' 2>/dev/null)
        xhttp_mode=$(printf '%s' "$outbound_json" | jq -r '.streamSettings.xhttpSettings.mode // ""' 2>/dev/null)
        xhttp_extra=$(printf '%s' "$outbound_json" | jq -c '.streamSettings.xhttpSettings.extra // null' 2>/dev/null)

        config=$(sing_box_cm_set_xhttp_transport_for_outbound "$config" "$tag" "$xhttp_path" "$xhttp_host" "$xhttp_mode" "$xhttp_extra")
        ;;
    esac

    echo "$config"
}

#######################################
# Parse a base64 link-list subscription (newline-separated proxy URLs, e.g.
# "vless://...#<percent-encoded display name>") and add all usable proxy
# outbounds to the configuration. This is the format some providers (e.g.
# Remnawave) return for v2rayN-like User-Agents - see get_subscription_user_agent -
# and it's the only way to reach servers using XHTTP transport, since those
# aren't included in the sing-box JSON variant of the same subscription.
# Uses the link's fragment (display name) as the outbound tag, falling back
# to "server-<n>" when a link has no fragment.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   section: string, the UCI section name
#   subscription_link_list_path: string, path to the downloaded subscription file
# Outputs:
#   Writes updated JSON configuration to stdout
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS (comma-separated list of tags)
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS_JSON (JSON array of tags, ASCII-escaped)
#   Sets global variable SUBSCRIPTION_OUTBOUND_NAMES (newline-separated list of display names)
#######################################
_sing_box_cf_add_subscription_outbounds_from_link_list() {
    local config="$1"
    local section="$2"
    local subscription_link_list_path="$3"

    local links_count
    links_count=$(count_usable_subscription_links "$subscription_link_list_path")

    if [ -z "$links_count" ] || [ "$links_count" -eq 0 ]; then
        log "No usable proxy links found in subscription link list" "error"
        echo "$config"
        return 1
    fi

    log "Found $links_count proxy links in subscription" "info"

    local decoded_tmp
    decoded_tmp="$(mktemp)"
    decode_subscription_link_list "$subscription_link_list_path" > "$decoded_tmp"

    local i=0
    local added_count=0
    local link fragment display_name base_tag outbound_tag tag_suffix updated_config validation_tmp

    while IFS= read -r link; do
        i=$((i + 1))

        printf '%s\n' "$link" | grep -qE "$SUBSCRIPTION_LINK_SCHEME_REGEX" || continue

        # The display name lives in the URL fragment (after '#'), percent-encoded UTF-8.
        fragment="${link#*#}"
        if [ "$fragment" != "$link" ] && [ -n "$fragment" ]; then
            display_name="$(url_decode "$fragment")"
        else
            display_name=""
        fi
        [ -n "$display_name" ] || display_name="server-$i"

        base_tag="$display_name"
        outbound_tag="$base_tag"
        tag_suffix=1
        while printf '%s' "$config" | jq -e --arg tag "$outbound_tag" '.outbounds[]? | select(.tag == $tag)' > /dev/null 2>&1; do
            outbound_tag="${base_tag}-$tag_suffix"
            tag_suffix=$((tag_suffix + 1))
        done

        updated_config=$(sing_box_cf_add_proxy_outbound_with_tag "$config" "$outbound_tag" "$link" "0" 2>/dev/null)
        if [ -z "$updated_config" ]; then
            log "Skip invalid subscription link: '$display_name'" "warn"
            continue
        fi

        # Validate against current sing-box capabilities (e.g. XHTTP transport
        # requires sing-box-extended) and skip outbounds it cannot run - the
        # same safety net used for the raw sing-box JSON subscription format.
        validation_tmp="$(mktemp)"
        sing_box_cm_save_config_to_file "$updated_config" "$validation_tmp"
        if ! sing-box -c "$validation_tmp" check > /dev/null 2>&1; then
            rm -f "$validation_tmp"
            log "Skip unsupported subscription link for current sing-box: '$display_name'" "warn"
            continue
        fi
        rm -f "$validation_tmp"

        config="$updated_config"

        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS="$outbound_tag"
        else
            SUBSCRIPTION_OUTBOUND_TAGS="$SUBSCRIPTION_OUTBOUND_TAGS,$outbound_tag"
        fi

        # Keep a JSON representation to avoid Unicode corruption in shell string processing.
        SUBSCRIPTION_OUTBOUND_TAGS_JSON=$(
            printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -ac --arg tag "$outbound_tag" '. + [$tag]' 2>/dev/null
        )
        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
        fi

        if [ -z "$SUBSCRIPTION_OUTBOUND_NAMES" ]; then
            SUBSCRIPTION_OUTBOUND_NAMES="$display_name"
        else
            SUBSCRIPTION_OUTBOUND_NAMES="$(printf '%s\n%s' "$SUBSCRIPTION_OUTBOUND_NAMES" "$display_name")"
        fi

        added_count=$((added_count + 1))
    done < "$decoded_tmp"
    rm -f "$decoded_tmp"

    log "Added $added_count subscription outbounds for section '$section'" "info"
    SING_BOX_CF_LAST_CONFIG="$config"

    echo "$config"
}
