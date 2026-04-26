#!/usr/bin/env bash
# Shared backend for the Plasma widget.

set -uo pipefail

MODE="json"
FORCE_REFRESH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            MODE="json"
            ;;
        --panel)
            MODE="panel"
            ;;
        --tooltip)
            MODE="tooltip"
            ;;
        --notify)
            MODE="notify"
            ;;
        --force)
            FORCE_REFRESH=1
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

CACHE_TTL="${VPN_WIDGET_CACHE_TTL:-20}"
PREFERRED_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/vpn-widget"
CACHE_DIR="$PREFERRED_CACHE_DIR"

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    CACHE_DIR="/tmp/vpn-widget-${USER:-$(id -u)}"
    mkdir -p "$CACHE_DIR" 2>/dev/null || CACHE_DIR=""
fi

if [[ -n "$CACHE_DIR" ]]; then
    CACHE_FILE="$CACHE_DIR/state.json"
    LOCK_DIR="$CACHE_DIR/.lock"
else
    CACHE_FILE=""
    LOCK_DIR=""
fi

have_command() {
    command -v "$1" >/dev/null 2>&1
}

trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_country_code() {
    [[ "${1:-}" =~ ^[A-Za-z]{2}$ ]]
}

normalize_country_code() {
    local code
    code="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
    if ((${#code} > 2)); then
        code="${code:0:2}"
    fi
    printf '%s' "$code"
}

flag_from_country() {
    local code
    code="$(normalize_country_code "$1")"

    if ! is_country_code "$code"; then
        printf '??'
        return
    fi

    if have_command python3; then
        python3 - "$code" <<'PY'
import sys
cc = sys.argv[1].upper()
print(chr(127397 + ord(cc[0])) + chr(127397 + ord(cc[1])), end="")
PY
        return
    fi

    printf '%s' "$code"
}

join_with_comma() {
    local out=""
    local part=""

    for part in "$@"; do
        part="$(trim "$part")"
        [[ -z "$part" || "$part" == "?" || "$part" == "Unknown" ]] && continue
        if [[ -n "$out" ]]; then
            out+=", "
        fi
        out+="$part"
    done

    printf '%s' "${out:-Unknown}"
}

json_bool() {
    if [[ "${1:-0}" == "1" ]]; then
        printf 'true'
    else
        printf 'false'
    fi
}

cache_is_fresh() {
    [[ -n "$CACHE_FILE" ]] || return 1
    [[ -s "$CACHE_FILE" ]] || return 1

    local modified now
    modified="$(stat -c %Y "$CACHE_FILE" 2>/dev/null || printf '0')"
    now="$(date +%s)"
    (( now - modified < CACHE_TTL ))
}

acquire_lock() {
    [[ -n "$LOCK_DIR" ]] || return 1

    local _attempt
    for _attempt in $(seq 1 50); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

release_lock() {
    [[ -n "$LOCK_DIR" ]] || return 0
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

fetch_url() {
    have_command curl || return 1

    curl \
        --silent \
        --show-error \
        --fail \
        --location \
        --connect-timeout 2 \
        --max-time 4 \
        --header 'Accept: application/json' \
        "$@" 2>/dev/null
}

parse_ipwho_record() {
    local json="${1:-}"
    [[ -n "$json" ]] || return 1

    jq -r '
        select(type == "object")
        | select(.ip != null)
        | [
            (.ip // ""),
            (.city // ""),
            (.region // ""),
            (.country // .country_name // ""),
            (.country_code // ""),
            (.connection.isp // .connection.org // .isp // ""),
            ((.latitude // "") | tostring),
            ((.longitude // "") | tostring),
            (.postal // .postal_code // "")
        ]
        | @tsv
    ' <<<"$json" 2>/dev/null
}

parse_ipapi_record() {
    local json="${1:-}"
    [[ -n "$json" ]] || return 1

    jq -r '
        select(type == "object")
        | select(.ip != null)
        | [
            (.ip // ""),
            (.city // ""),
            (.region // ""),
            (.country_name // .country // ""),
            (.country_code // .country // ""),
            (.org // .asn // ""),
            ((.latitude // "") | tostring),
            ((.longitude // "") | tostring),
            (.postal // "")
        ]
        | @tsv
    ' <<<"$json" 2>/dev/null
}

parse_ipinfo_record() {
    local json="${1:-}"
    [[ -n "$json" ]] || return 1

    jq -r '
        select(type == "object")
        | select(.ip != null)
        | [
            (.ip // ""),
            (.city // ""),
            (.region // ""),
            (.country // ""),
            (.country // ""),
            (.org // ""),
            ((.loc // "") | split(",") | .[0] // ""),
            ((.loc // "") | split(",") | .[1] // ""),
            (.postal // "")
        ]
        | @tsv
    ' <<<"$json" 2>/dev/null
}

query_geo_record() {
    local mode="$1"
    local target="${2:-}"
    local provider=""
    local url=""
    local json=""
    local record=""
    local candidate=""
    local ip city region country_name country_code org lat lon postal

    for provider in ipwho ipapi ipinfo; do
        case "$provider" in
            ipwho)
                if [[ "$mode" == "current" ]]; then
                    url="https://ipwho.is/"
                else
                    url="https://ipwho.is/${target}"
                fi
                json="$(fetch_url "$url" || true)"
                record="$(parse_ipwho_record "$json" || true)"
                ;;
            ipapi)
                if [[ "$mode" == "current" ]]; then
                    url="https://ipapi.co/json/"
                else
                    url="https://ipapi.co/${target}/json/"
                fi
                json="$(fetch_url "$url" || true)"
                record="$(parse_ipapi_record "$json" || true)"
                ;;
            ipinfo)
                if [[ "$mode" == "current" ]]; then
                    url="https://ipinfo.io/json"
                else
                    url="https://ipinfo.io/${target}/json"
                fi
                json="$(fetch_url "$url" || true)"
                record="$(parse_ipinfo_record "$json" || true)"
                ;;
        esac

        [[ -n "$record" ]] || continue

        IFS=$'\t' read -r ip city region country_name country_code org lat lon postal <<<"$record"
        country_code="$(normalize_country_code "$country_code")"

        if [[ -z "$candidate" && -n "$ip" ]]; then
            candidate="$provider"$'\t'"$ip"$'\t'"$city"$'\t'"$region"$'\t'"$country_name"$'\t'"$country_code"$'\t'"$org"$'\t'"$lat"$'\t'"$lon"$'\t'"$postal"
        fi

        if is_country_code "$country_code"; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$provider" "$ip" "$city" "$region" "$country_name" "$country_code" "$org" "$lat" "$lon" "$postal"
            return 0
        fi
    done

    [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

get_default_interface() {
    local route=""

    if have_command ip; then
        route="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; ++i) if ($i == "dev") { print $(i + 1); exit }}')"
        if [[ -z "$route" ]]; then
            route="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i = 1; i <= NF; ++i) if ($i == "dev") { print $(i + 1); exit }}')"
        fi
    fi

    printf '%s' "$route"
}

choose_nm_vpn() {
    local default_iface="$1"
    local entries=()
    local entry="" name="" type="" device=""

    have_command nmcli || return 1

    mapfile -t entries < <(
        nmcli -t -f NAME,TYPE,DEVICE con show --active 2>/dev/null \
            | awk -F: '$2=="vpn" || $2=="wireguard" { print $1 "|" $2 "|" $3 }'
    )

    ((${#entries[@]} > 0)) || return 1

    for entry in "${entries[@]}"; do
        IFS='|' read -r name type device <<<"$entry"
        if [[ -n "$device" && "$device" == "$default_iface" ]]; then
            printf '%s\t%s\t%s\n' "$name" "$type" "$device"
            return 0
        fi
    done

    for entry in "${entries[@]}"; do
        IFS='|' read -r name type device <<<"$entry"
        if [[ -n "$device" ]]; then
            printf '%s\t%s\t%s\n' "$name" "$type" "$device"
            return 0
        fi
    done

    IFS='|' read -r name type device <<<"${entries[0]}"
    printf '%s\t%s\t%s\n' "$name" "$type" "$device"
}

choose_wireguard_vpn() {
    local default_iface="$1"
    local wg_ifaces=()
    local iface=""

    have_command wg || return 1

    read -ra wg_ifaces <<<"$(wg show interfaces 2>/dev/null)"
    ((${#wg_ifaces[@]} > 0)) || return 1

    for iface in "${wg_ifaces[@]}"; do
        if [[ "$iface" == "$default_iface" ]]; then
            printf '%s\twireguard\t%s\n' "$iface" "$iface"
            return 0
        fi
    done

    printf '%s\twireguard\t%s\n' "${wg_ifaces[0]}" "${wg_ifaces[0]}"
}

get_wireguard_endpoint() {
    local iface="${1:-}"
    local endpoint=""

    [[ -n "$iface" ]] || return 0
    have_command wg || return 0

    endpoint="$(
        wg show "$iface" endpoints 2>/dev/null \
            | awk '{print $2}' \
            | grep -v '^(none)$' \
            | head -n1
    )"

    if [[ "$endpoint" =~ ^\[([0-9A-Fa-f:]+)\](:[0-9]+)?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$endpoint" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "${endpoint%%:*}"
    fi
}

get_mullvad_state() {
    local mullvad_output=""

    have_command mullvad || return 1

    mullvad_output="$(mullvad status 2>/dev/null || true)"
    if grep -qE '^Connected' <<<"$mullvad_output"; then
        printf 'connected'
        return 0
    fi
    if grep -qE '^Connecting' <<<"$mullvad_output"; then
        printf 'connecting'
        return 0
    fi
    if grep -qE '^Disconnected' <<<"$mullvad_output"; then
        printf 'disconnected'
        return 0
    fi
    printf 'unknown'
}

build_state_json() {
    local default_iface vpn_active vpn_backend vpn_name vpn_type vpn_iface full_tunnel
    local endpoint_ip route_record endpoint_record
    local route_provider route_ip route_city route_region route_country_name route_country_code route_org route_lat route_lon route_postal
    local endpoint_provider endpoint_geo_ip endpoint_city endpoint_region endpoint_country_name endpoint_country_code endpoint_org endpoint_lat endpoint_lon endpoint_postal
    local display_provider display_ip display_city display_region display_country_name display_country_code display_org display_lat display_lon display_postal display_source
    local vpn_mode status_label status_detail icon_name icon_symbol flag location_text summary updated_at
    local route_summary endpoint_summary detail_text public_ip
    local mullvad_state=unknown

    default_iface="$(get_default_interface)"
    vpn_active=0
    vpn_backend="inactive"
    vpn_name=""
    vpn_type=""
    vpn_iface=""
    full_tunnel=0
    endpoint_ip=""

    if read -r vpn_name vpn_type vpn_iface < <(choose_nm_vpn "$default_iface" 2>/dev/null); then
        vpn_active=1
        vpn_backend="networkmanager"
    elif read -r vpn_name vpn_type vpn_iface < <(choose_wireguard_vpn "$default_iface" 2>/dev/null); then
        vpn_active=1
        vpn_backend="wireguard"
    fi

    if [[ -n "$vpn_iface" ]]; then
        endpoint_ip="$(get_wireguard_endpoint "$vpn_iface")"
    fi

    mullvad_state="$(get_mullvad_state || printf 'unknown')"
    if [[ "$vpn_active" -eq 0 && "$mullvad_state" != "disconnected" && "$mullvad_state" != "unknown" ]]; then
        vpn_active=1
        vpn_backend="mullvad"
        vpn_name="Mullvad"
    fi

    if [[ "$vpn_active" -eq 1 ]]; then
        if [[ -n "$vpn_iface" && "$default_iface" == "$vpn_iface" ]]; then
            full_tunnel=1
        elif [[ "$vpn_backend" == "mullvad" && -n "$default_iface" && "$default_iface" =~ ^(wg|tun|tap|ppp) ]]; then
            full_tunnel=1
            vpn_iface="$default_iface"
        fi
    fi

    route_record="$(query_geo_record current || true)"
    route_provider=""
    route_ip=""
    route_city=""
    route_region=""
    route_country_name=""
    route_country_code=""
    route_org=""
    route_lat=""
    route_lon=""
    route_postal=""

    if [[ -n "$route_record" ]]; then
        IFS=$'\t' read -r route_provider route_ip route_city route_region route_country_name route_country_code route_org route_lat route_lon route_postal <<<"$route_record"
        route_country_code="$(normalize_country_code "$route_country_code")"
    fi

    endpoint_provider=""
    endpoint_geo_ip=""
    endpoint_city=""
    endpoint_region=""
    endpoint_country_name=""
    endpoint_country_code=""
    endpoint_org=""
    endpoint_lat=""
    endpoint_lon=""
    endpoint_postal=""

    if [[ -n "$endpoint_ip" ]]; then
        endpoint_record="$(query_geo_record ip "$endpoint_ip" || true)"
        if [[ -n "$endpoint_record" ]]; then
            IFS=$'\t' read -r endpoint_provider endpoint_geo_ip endpoint_city endpoint_region endpoint_country_name endpoint_country_code endpoint_org endpoint_lat endpoint_lon endpoint_postal <<<"$endpoint_record"
            endpoint_country_code="$(normalize_country_code "$endpoint_country_code")"
        fi
    fi

    display_provider="$route_provider"
    display_ip="$route_ip"
    display_city="$route_city"
    display_region="$route_region"
    display_country_name="$route_country_name"
    display_country_code="$route_country_code"
    display_org="$route_org"
    display_lat="$route_lat"
    display_lon="$route_lon"
    display_postal="$route_postal"
    display_source="public-route"

    if [[ "$vpn_active" -eq 1 && "$full_tunnel" -eq 0 && -n "$endpoint_ip" && -n "$endpoint_country_code" ]]; then
        display_provider="$endpoint_provider"
        display_ip="${endpoint_geo_ip:-$endpoint_ip}"
        display_city="$endpoint_city"
        display_region="$endpoint_region"
        display_country_name="$endpoint_country_name"
        display_country_code="$endpoint_country_code"
        display_org="$endpoint_org"
        display_lat="$endpoint_lat"
        display_lon="$endpoint_lon"
        display_postal="$endpoint_postal"
        display_source="vpn-endpoint"
    elif [[ -z "$display_country_code" && -n "$endpoint_country_code" ]]; then
        display_provider="$endpoint_provider"
        display_ip="${endpoint_geo_ip:-$endpoint_ip}"
        display_city="$endpoint_city"
        display_region="$endpoint_region"
        display_country_name="$endpoint_country_name"
        display_country_code="$endpoint_country_code"
        display_org="$endpoint_org"
        display_lat="$endpoint_lat"
        display_lon="$endpoint_lon"
        display_postal="$endpoint_postal"
        display_source="vpn-endpoint"
    fi

    public_ip="$route_ip"
    location_text="$(join_with_comma "$display_city" "$display_region" "$display_country_name")"

    if [[ -z "$display_country_name" && -n "$display_country_code" ]]; then
        display_country_name="$display_country_code"
        location_text="$(join_with_comma "$display_city" "$display_region" "$display_country_name")"
    fi

    if [[ "$vpn_active" -eq 1 ]]; then
        if [[ "$full_tunnel" -eq 1 ]]; then
            vpn_mode="full-tunnel"
            status_label="VPN aktiv"
            status_detail="Exit-IP erkannt"
        else
            vpn_mode="split-tunnel"
            status_label="VPN aktiv"
            status_detail="Standort aus VPN-Endpoint"
        fi
        icon_name="network-vpn"
        icon_symbol="󰦝"
    else
        vpn_mode="inactive"
        status_label="VPN inaktiv"
        status_detail="Normale Verbindung"
        icon_name="network-wireless"
        icon_symbol="󰒘"
    fi

    flag="$(flag_from_country "$display_country_code")"
    summary="$status_label · $flag"
    updated_at="$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"

    route_summary="$(join_with_comma "$route_city" "$route_region" "$route_country_name")"
    endpoint_summary="$(join_with_comma "$endpoint_city" "$endpoint_region" "$endpoint_country_name")"

    detail_text="IP: ${public_ip:-?}
Standort: ${location_text}
Interface: ${vpn_iface:-${default_iface:-?}}
VPN-Modus: ${vpn_mode}
Quelle: ${display_source}
Endpoint: ${endpoint_ip:-n/a}
Provider: ${display_org:-n/a}"

    jq -n \
        --arg updated_at "$updated_at" \
        --arg default_iface "$default_iface" \
        --arg vpn_backend "$vpn_backend" \
        --arg vpn_name "$vpn_name" \
        --arg vpn_type "$vpn_type" \
        --arg vpn_iface "$vpn_iface" \
        --arg vpn_mode "$vpn_mode" \
        --arg mullvad_state "$mullvad_state" \
        --arg endpoint_ip "$endpoint_ip" \
        --arg route_provider "$route_provider" \
        --arg route_ip "$route_ip" \
        --arg route_city "$route_city" \
        --arg route_region "$route_region" \
        --arg route_country_name "$route_country_name" \
        --arg route_country_code "$route_country_code" \
        --arg route_org "$route_org" \
        --arg route_lat "$route_lat" \
        --arg route_lon "$route_lon" \
        --arg route_postal "$route_postal" \
        --arg route_summary "$route_summary" \
        --arg endpoint_provider "$endpoint_provider" \
        --arg endpoint_geo_ip "$endpoint_geo_ip" \
        --arg endpoint_city "$endpoint_city" \
        --arg endpoint_region "$endpoint_region" \
        --arg endpoint_country_name "$endpoint_country_name" \
        --arg endpoint_country_code "$endpoint_country_code" \
        --arg endpoint_org "$endpoint_org" \
        --arg endpoint_lat "$endpoint_lat" \
        --arg endpoint_lon "$endpoint_lon" \
        --arg endpoint_postal "$endpoint_postal" \
        --arg endpoint_summary "$endpoint_summary" \
        --arg display_provider "$display_provider" \
        --arg display_ip "$display_ip" \
        --arg display_city "$display_city" \
        --arg display_region "$display_region" \
        --arg display_country_name "$display_country_name" \
        --arg display_country_code "$display_country_code" \
        --arg display_org "$display_org" \
        --arg display_lat "$display_lat" \
        --arg display_lon "$display_lon" \
        --arg display_postal "$display_postal" \
        --arg display_source "$display_source" \
        --arg flag "$flag" \
        --arg location_text "$location_text" \
        --arg summary "$summary" \
        --arg status_label "$status_label" \
        --arg status_detail "$status_detail" \
        --arg icon_name "$icon_name" \
        --arg icon_symbol "$icon_symbol" \
        --arg detail_text "$detail_text" \
        --arg public_ip "$public_ip" \
        --argjson vpn_active "$(json_bool "$vpn_active")" \
        --argjson full_tunnel "$(json_bool "$full_tunnel")" \
        '{
            updated_at: $updated_at,
            vpn_active: $vpn_active,
            full_tunnel: $full_tunnel,
            vpn_backend: $vpn_backend,
            vpn_name: $vpn_name,
            vpn_type: $vpn_type,
            vpn_iface: $vpn_iface,
            vpn_mode: $vpn_mode,
            mullvad_state: $mullvad_state,
            default_iface: $default_iface,
            endpoint_ip: $endpoint_ip,
            public_ip: $public_ip,
            display_source: $display_source,
            display_provider: $display_provider,
            display_ip: $display_ip,
            display_city: $display_city,
            display_region: $display_region,
            display_country_name: $display_country_name,
            display_country_code: $display_country_code,
            display_org: $display_org,
            display_lat: $display_lat,
            display_lon: $display_lon,
            display_postal: $display_postal,
            location_text: $location_text,
            flag: $flag,
            summary: $summary,
            status_label: $status_label,
            status_detail: $status_detail,
            icon_name: $icon_name,
            icon_symbol: $icon_symbol,
            panel_text: ($icon_symbol + " " + $flag),
            detail_text: $detail_text,
            route: {
                provider: $route_provider,
                ip: $route_ip,
                city: $route_city,
                region: $route_region,
                country_name: $route_country_name,
                country_code: $route_country_code,
                org: $route_org,
                lat: $route_lat,
                lon: $route_lon,
                postal: $route_postal,
                summary: $route_summary
            },
            endpoint: {
                provider: $endpoint_provider,
                ip: $endpoint_geo_ip,
                endpoint_ip: $endpoint_ip,
                city: $endpoint_city,
                region: $endpoint_region,
                country_name: $endpoint_country_name,
                country_code: $endpoint_country_code,
                org: $endpoint_org,
                lat: $endpoint_lat,
                lon: $endpoint_lon,
                postal: $endpoint_postal,
                summary: $endpoint_summary
            }
        }'
}

get_state_json() {
    local state_json=""

    if [[ -z "$CACHE_FILE" ]]; then
        build_state_json
        return 0
    fi

    if [[ "$FORCE_REFRESH" -eq 0 ]] && cache_is_fresh; then
        cat "$CACHE_FILE"
        return 0
    fi

    if ! acquire_lock; then
        if [[ -s "$CACHE_FILE" ]]; then
            cat "$CACHE_FILE"
            return 0
        fi
        build_state_json
        return 0
    fi

    if [[ "$FORCE_REFRESH" -eq 0 ]] && cache_is_fresh; then
        release_lock
        cat "$CACHE_FILE"
        return 0
    fi

    state_json="$(build_state_json)"
    printf '%s\n' "$state_json" >"$CACHE_FILE"
    release_lock
    printf '%s\n' "$state_json"
}

emit_panel() {
    jq -r '.panel_text // "󰒘 ??"'
}

emit_tooltip() {
    jq -r '
        [
            (.status_label + (if .full_tunnel then " (Full Tunnel)" elif .vpn_active then " (Split Tunnel)" else "" end)),
            ("Land: " + (
                if (.display_country_name | length) > 0 then .display_country_name
                elif (.display_country_code | length) > 0 then .display_country_code
                else "Unbekannt"
                end
            )),
            ("IP: " + (if (.public_ip | length) > 0 then .public_ip else "?" end)),
            ("Interface: " + (if (.vpn_iface | length) > 0 then .vpn_iface elif (.default_iface | length) > 0 then .default_iface else "?" end)),
            ("Endpoint: " + (if (.endpoint_ip | length) > 0 then .endpoint_ip else "n/a" end))
        ] | join("\n")
    '
}

emit_notification() {
    local title body icon

    title="$(jq -r '(.status_label // "VPN Status") + " " + (.flag // "??")')"
    body="$(jq -r '.detail_text // "Keine Daten verfügbar."')"
    icon="$(jq -r '.icon_name // "network-wireless"')"

    if have_command notify-send; then
        notify-send "$title" "$body" -i "$icon"
    else
        printf '%s\n\n%s\n' "$title" "$body"
    fi
}

STATE_JSON="$(get_state_json)"

case "$MODE" in
    json)
        printf '%s\n' "$STATE_JSON"
        ;;
    panel)
        emit_panel <<<"$STATE_JSON"
        ;;
    tooltip)
        emit_tooltip <<<"$STATE_JSON"
        ;;
    notify)
        emit_notification <<<"$STATE_JSON"
        ;;
esac
