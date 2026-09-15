#!/usr/bin/env bash
# Shared backend for the Plasma widget.

set -uo pipefail

MODE="json"
FORCE_REFRESH=0
SKIP_STATE_CACHE=0

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
        --fingerprint)
            MODE="fingerprint"
            ;;
        --force)
            FORCE_REFRESH=1
            ;;
        --no-cache)
            # Recompute local VPN state, but keep the cached geo answers: a
            # tunnel going up or down does not change where the public IP is.
            SKIP_STATE_CACHE=1
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

# Internal record separator. Must not be IFS whitespace: bash collapses runs
# of spaces/tabs/newlines into one delimiter, which silently drops empty middle
# fields and shifts every later field left.
RS=$'\x1f'

# ipwho.is answers in English by default, which yields oddities like
# "Land Berlin" next to an otherwise German UI.
GEO_LANG="${VPN_WIDGET_GEO_LANG:-de}"

# Optional API credentials, passed in by the widget from its config page.
# Every provider also works without one, just at a much lower quota.
IPINFO_TOKEN="${VPN_WIDGET_IPINFO_TOKEN:-}"
IPGEO_KEY="${VPN_WIDGET_IPGEO_KEY:-}"
IPAPI_KEY="${VPN_WIDGET_IPAPI_KEY:-}"

LOCK_STALE_SECS="${VPN_WIDGET_LOCK_STALE:-60}"
LOCK_HELD=0
trap 'release_lock' EXIT INT TERM

# Geo lookups hit third-party APIs, so they get a much longer TTL than the
# local VPN state. Invalidation is driven by the network fingerprint below,
# not by this timeout alone.
GEO_TTL="${VPN_WIDGET_GEO_TTL:-600}"
GEO_CACHE_DIR=""
GEO_NET_KEY=""

if [[ -n "$CACHE_DIR" ]]; then
    GEO_CACHE_DIR="$CACHE_DIR/geo"
    mkdir -p "$GEO_CACHE_DIR" 2>/dev/null || GEO_CACHE_DIR=""
fi

have_command() {
    command -v "$1" >/dev/null 2>&1
}

is_ipv4() {
    [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
    [[ "${1:-}" == *:* ]]
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

    # Deliberately no truncation: cutting "Germany" to GE yields Georgia and
    # "Austria" to AU yields Australia, and both pass is_country_code, so a
    # schema change at a provider would silently show the wrong flag. Reject
    # anything that is not already alpha-2 and let the caller try the next
    # provider instead.
    is_country_code "$code" || return 0

    printf '%s' "$code"
}

# ipinfo.io only returns a code, and the panel should still read "Germany"
# rather than "DE". iso-codes ships with most distributions; when it is
# missing the caller falls back to the bare code.
country_name_from_code() {
    local code="${1:-}"
    local db="/usr/share/iso-codes/json/iso_3166-1.json"
    local name=""

    is_country_code "$code" || return 0
    [[ -r "$db" ]] || return 0
    have_command jq || return 0

    name="$(jq -r --arg c "$code" '
        ."3166-1"[]
        | select(.alpha_2 == $c)
        | (.common_name // .name // empty)
    ' "$db" 2>/dev/null | head -n1)"

    [[ -n "$name" && "$name" != "null" ]] || return 0
    printf '%s' "$name"
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

break_stale_lock() {
    [[ -n "$LOCK_DIR" ]] || return 0
    [[ -d "$LOCK_DIR" ]] || return 0

    local modified now
    modified="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || printf '0')"
    now="$(date +%s)"

    # A run killed while holding the lock would otherwise block every refresh forever.
    if (( now - modified >= LOCK_STALE_SECS )); then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

acquire_lock() {
    [[ -n "$LOCK_DIR" ]] || return 1

    break_stale_lock

    local _attempt
    for _attempt in $(seq 1 50); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            LOCK_HELD=1
            return 0
        fi
        sleep 0.1
    done

    break_stale_lock
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        return 0
    fi

    return 1
}

release_lock() {
    [[ -n "$LOCK_DIR" ]] || return 0
    [[ "$LOCK_HELD" -eq 1 ]] || return 0
    LOCK_HELD=0
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

fetch_url() {
    local family="${1:-auto}"
    shift

    have_command curl || return 1

    local -a family_args=()
    case "$family" in
        4)
            family_args=(-4)
            ;;
        6)
            family_args=(-6)
            ;;
    esac

    curl \
        --silent \
        --show-error \
        --fail \
        --location \
        --connect-timeout 2 \
        --max-time 4 \
        --header 'Accept: application/json' \
        "${family_args[@]}" \
        "$@" 2>/dev/null
}

parse_ipwho_record() {
    local json="${1:-}"
    [[ -n "$json" ]] || return 1

    jq -r '
        select(type == "object")
        | select(.ip | type == "string")
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
        | map(tostring | gsub("[\u0000-\u001f]"; " "))
        | join("\u001f")
    ' <<<"$json" 2>/dev/null
}

parse_ipapi_record() {
    local json="${1:-}"
    [[ -n "$json" ]] || return 1

    jq -r '
        select(type == "object")
        | select(.ip | type == "string")
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
        | map(tostring | gsub("[\u0000-\u001f]"; " "))
        | join("\u001f")
    ' <<<"$json" 2>/dev/null
}

parse_ipinfo_record() {
    local json="${1:-}"
    [[ -n "$json" ]] || return 1

    jq -r '
        select(type == "object")
        | select(.ip | type == "string")
        | [
            (.ip // ""),
            (.city // ""),
            (.region // ""),
            (""),
            (.country // ""),
            (.org // ""),
            ((.loc // "") | split(",") | .[0] // ""),
            ((.loc // "") | split(",") | .[1] // ""),
            (.postal // "")
        ]
        | map(tostring | gsub("[\u0000-\u001f]"; " "))
        | join("\u001f")
    ' <<<"$json" 2>/dev/null
}

# A cheap summary of everything that decides where our traffic leaves from:
# interfaces, both default routes, and the WireGuard peer endpoints. Costs
# about 10ms, so the widget can poll it often, and any change here means the
# cached geo answers are stale — including a Mullvad server switch, which
# keeps the same device and source address but changes the peer endpoint.
network_fingerprint() {
    {
        ip -o link show 2>/dev/null
        ip -4 route show default 2>/dev/null
        ip -6 route show default 2>/dev/null
        have_command wg && wg show all endpoints 2>/dev/null
    } | cksum | cut -d' ' -f1
}

geo_net_key() {
    if [[ -z "$GEO_NET_KEY" ]]; then
        GEO_NET_KEY="$(network_fingerprint)"
        [[ -n "$GEO_NET_KEY" ]] || GEO_NET_KEY="none"
    fi

    printf '%s' "$GEO_NET_KEY"
}

geo_cache_file() {
    local mode="$1" target="${2:-}" family="${3:-auto}"
    local scope="" key=""

    # Endpoint lookups are keyed by the address itself, so they stay valid
    # across networks; "current" lookups only make sense per network.
    case "$mode" in
        current*)
            scope="$(geo_net_key)"
            ;;
        *)
            scope="any"
            ;;
    esac

    key="$(printf '%s_%s_%s_%s' "$mode" "$target" "$family" "$scope" | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s' "$GEO_CACHE_DIR" "$key"
}

query_geo_record() {
    local mode="$1"
    local target="${2:-}"
    local family="${3:-auto}"
    local file="" record="" modified="" now=""

    if [[ -z "$GEO_CACHE_DIR" ]]; then
        query_geo_record_live "$mode" "$target" "$family"
        return
    fi

    file="$(geo_cache_file "$mode" "$target" "$family")"

    if [[ "$FORCE_REFRESH" -eq 0 && -s "$file" ]]; then
        modified="$(stat -c %Y "$file" 2>/dev/null || printf '0')"
        now="$(date +%s)"
        if (( now - modified < GEO_TTL )); then
            cat "$file"
            return 0
        fi
    fi

    record="$(query_geo_record_live "$mode" "$target" "$family")"

    if [[ -n "$record" ]]; then
        if printf '%s\n' "$record" >"$file.tmp.$$" 2>/dev/null; then
            mv -f "$file.tmp.$$" "$file" 2>/dev/null || rm -f "$file.tmp.$$" 2>/dev/null
        fi
        printf '%s\n' "$record"
        return 0
    fi

    # Every provider failed (offline, rate limited). A stale answer beats none.
    if [[ -s "$file" ]]; then
        cat "$file"
        return 0
    fi

    return 1
}

# ipgeolocation.io v3 nests everything under .location; v2 was flat, so accept
# both shapes.
parse_ipgeo_record() {
    local json="${1:-}"
    [[ -n "$json" ]] || return 1

    jq -r '
        select(type == "object")
        | select(.ip | type == "string")
        | [
            (.ip // ""),
            (.location.city // .city // ""),
            (.location.state_prov // .state_prov // ""),
            (.location.country_name // .country_name // ""),
            (.location.country_code2 // .country_code2 // ""),
            (.asn.organization // .company.name // .isp // .organization // ""),
            ((.location.latitude // .latitude // "") | tostring),
            ((.location.longitude // .longitude // "") | tostring),
            (.location.zipcode // .zipcode // "")
        ]
        | map(tostring | gsub("[\u0000-\u001f]"; " "))
        | join("\u001f")
    ' <<<"$json" 2>/dev/null
}

query_geo_record_live() {
    local mode="$1"
    local target="${2:-}"
    local family="${3:-auto}"
    local provider=""
    local url=""
    local json=""
    local record=""
    local candidate=""
    local ip city region country_name country_code org lat lon postal

    local -a providers=(ipwho)
    [[ -n "$IPGEO_KEY" ]] && providers+=(ipgeo)
    # ipinfo.io stays last: its free tier answers country-level only.
    providers+=(ipapi ipinfo)

    for provider in "${providers[@]}"; do
        case "$provider" in
            ipwho)
                if [[ "$mode" == "current" || "$mode" == "current4" || "$mode" == "current6" ]]; then
                    url="https://ipwho.is/"
                else
                    url="https://ipwho.is/${target}"
                fi
                url="${url}?fields=ip,city,region,country,country_code,postal,latitude,longitude,connection"
                [[ -n "$GEO_LANG" ]] && url="${url}&lang=${GEO_LANG}"
                json="$(fetch_url "$family" "$url" || true)"
                record="$(parse_ipwho_record "$json" || true)"
                ;;
            ipgeo)
                url="https://api.ipgeolocation.io/v3/ipgeo?apiKey=${IPGEO_KEY}"
                if [[ "$mode" != "current" && "$mode" != "current4" && "$mode" != "current6" ]]; then
                    url="${url}&ip=${target}"
                fi
                json="$(fetch_url "$family" "$url" || true)"
                record="$(parse_ipgeo_record "$json" || true)"
                ;;
            ipapi)
                if [[ "$mode" == "current" || "$mode" == "current4" || "$mode" == "current6" ]]; then
                    url="https://ipapi.co/json/"
                else
                    url="https://ipapi.co/${target}/json/"
                fi
                [[ -n "$IPAPI_KEY" ]] && url="${url}?key=${IPAPI_KEY}"
                json="$(fetch_url "$family" "$url" || true)"
                record="$(parse_ipapi_record "$json" || true)"
                ;;
            ipinfo)
                if [[ "$mode" == "current" || "$mode" == "current4" || "$mode" == "current6" ]]; then
                    url="https://ipinfo.io/json"
                else
                    url="https://ipinfo.io/${target}/json"
                fi
                [[ -n "$IPINFO_TOKEN" ]] && url="${url}?token=${IPINFO_TOKEN}"
                json="$(fetch_url "$family" "$url" || true)"
                record="$(parse_ipinfo_record "$json" || true)"
                ;;
        esac

        [[ -n "$record" ]] || continue

        IFS="$RS" read -r ip city region country_name country_code org lat lon postal <<<"$record"
        country_code="$(normalize_country_code "$country_code")"

        if [[ -z "$candidate" && -n "$ip" ]]; then
            candidate="$provider$RS$ip$RS$city$RS$region$RS$country_name$RS$country_code$RS$org$RS$lat$RS$lon$RS$postal"
        fi

        if is_country_code "$country_code"; then
            printf '%s\n' \
                "$provider$RS$ip$RS$city$RS$region$RS$country_name$RS$country_code$RS$org$RS$lat$RS$lon$RS$postal"
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
            | awk -F: -v rs="$RS" '$2=="vpn" || $2=="wireguard" { print $1 rs $2 rs $3 }'
    )

    ((${#entries[@]} > 0)) || return 1

    for entry in "${entries[@]}"; do
        IFS="$RS" read -r name type device <<<"$entry"
        if [[ -n "$device" && "$device" == "$default_iface" ]]; then
            printf '%s%s%s%s%s\n' "$name" "$RS" "$type" "$RS" "$device"
            return 0
        fi
    done

    for entry in "${entries[@]}"; do
        IFS="$RS" read -r name type device <<<"$entry"
        if [[ -n "$device" ]]; then
            printf '%s%s%s%s%s\n' "$name" "$RS" "$type" "$RS" "$device"
            return 0
        fi
    done

    IFS="$RS" read -r name type device <<<"${entries[0]}"
    printf '%s%s%s%s%s\n' "$name" "$RS" "$type" "$RS" "$device"
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
            printf '%s%swireguard%s%s\n' "$iface" "$RS" "$RS" "$iface"
            return 0
        fi
    done

    printf '%s%swireguard%s%s\n' "${wg_ifaces[0]}" "$RS" "$RS" "${wg_ifaces[0]}"
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
    local endpoint_ip route_record route4_record route6_record endpoint_record
    local route_provider route_ip route_city route_region route_country_name route_country_code route_org route_lat route_lon route_postal
    local route4_provider route4_ip route4_city route4_region route4_country_name route4_country_code route4_org route4_lat route4_lon route4_postal
    local route6_provider route6_ip route6_city route6_region route6_country_name route6_country_code route6_org route6_lat route6_lon route6_postal
    local endpoint_provider endpoint_geo_ip endpoint_city endpoint_region endpoint_country_name endpoint_country_code endpoint_org endpoint_lat endpoint_lon endpoint_postal
    local display_provider display_ip display_city display_region display_country_name display_country_code display_org display_lat display_lon display_postal display_source
    local vpn_mode status_label status_detail icon_name icon_symbol flag location_text summary updated_at
    local route_summary route4_summary route6_summary endpoint_summary detail_text public_ip public_ipv4 public_ipv6
    local mullvad_state=unknown

    default_iface="$(get_default_interface)"
    vpn_active=0
    vpn_backend="inactive"
    vpn_name=""
    vpn_type=""
    vpn_iface=""
    full_tunnel=0
    endpoint_ip=""

    # Connection names routinely contain spaces, so split on the tab the
    # choose_* helpers emit rather than on any whitespace.
    if IFS="$RS" read -r vpn_name vpn_type vpn_iface < <(choose_nm_vpn "$default_iface" 2>/dev/null); then
        vpn_active=1
        vpn_backend="networkmanager"
    elif IFS="$RS" read -r vpn_name vpn_type vpn_iface < <(choose_wireguard_vpn "$default_iface" 2>/dev/null); then
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
    route4_provider=""
    route4_ip=""
    route4_city=""
    route4_region=""
    route4_country_name=""
    route4_country_code=""
    route4_org=""
    route4_lat=""
    route4_lon=""
    route4_postal=""
    route6_provider=""
    route6_ip=""
    route6_city=""
    route6_region=""
    route6_country_name=""
    route6_country_code=""
    route6_org=""
    route6_lat=""
    route6_lon=""
    route6_postal=""

    if [[ -n "$route_record" ]]; then
        IFS="$RS" read -r route_provider route_ip route_city route_region route_country_name route_country_code route_org route_lat route_lon route_postal <<<"$route_record"
        route_country_code="$(normalize_country_code "$route_country_code")"
    fi

    if is_ipv4 "$route_ip"; then
        route4_provider="$route_provider"
        route4_ip="$route_ip"
        route4_city="$route_city"
        route4_region="$route_region"
        route4_country_name="$route_country_name"
        route4_country_code="$route_country_code"
        route4_org="$route_org"
        route4_lat="$route_lat"
        route4_lon="$route_lon"
        route4_postal="$route_postal"
    elif is_ipv6 "$route_ip"; then
        route6_provider="$route_provider"
        route6_ip="$route_ip"
        route6_city="$route_city"
        route6_region="$route_region"
        route6_country_name="$route_country_name"
        route6_country_code="$route_country_code"
        route6_org="$route_org"
        route6_lat="$route_lat"
        route6_lon="$route_lon"
        route6_postal="$route_postal"
    fi

    if [[ -z "$route4_ip" ]]; then
        route4_record="$(query_geo_record current4 "" 4 || true)"
        if [[ -n "$route4_record" ]]; then
            IFS="$RS" read -r route4_provider route4_ip route4_city route4_region route4_country_name route4_country_code route4_org route4_lat route4_lon route4_postal <<<"$route4_record"
            route4_country_code="$(normalize_country_code "$route4_country_code")"
        fi
    fi

    if [[ -z "$route6_ip" && -n "$route4_ip" ]]; then
        route6_record="$(query_geo_record current6 "" 6 || true)"
        if [[ -n "$route6_record" ]]; then
            IFS="$RS" read -r route6_provider route6_ip route6_city route6_region route6_country_name route6_country_code route6_org route6_lat route6_lon route6_postal <<<"$route6_record"
            route6_country_code="$(normalize_country_code "$route6_country_code")"
        fi
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
            IFS="$RS" read -r endpoint_provider endpoint_geo_ip endpoint_city endpoint_region endpoint_country_name endpoint_country_code endpoint_org endpoint_lat endpoint_lon endpoint_postal <<<"$endpoint_record"
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

    public_ipv4="$route4_ip"
    public_ipv6="$route6_ip"
    public_ip="${public_ipv4:-${route_ip:-$public_ipv6}}"
    location_text="$(join_with_comma "$display_city" "$display_region" "$display_country_name")"

    if [[ -z "$display_country_name" && -n "$display_country_code" ]]; then
        display_country_name="$(country_name_from_code "$display_country_code")"
        [[ -n "$display_country_name" ]] || display_country_name="$display_country_code"
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
    route4_summary="$(join_with_comma "$route4_city" "$route4_region" "$route4_country_name")"
    route6_summary="$(join_with_comma "$route6_city" "$route6_region" "$route6_country_name")"
    endpoint_summary="$(join_with_comma "$endpoint_city" "$endpoint_region" "$endpoint_country_name")"

    detail_text="Verbindung: ${vpn_name:-n/a}
IPv4: ${public_ipv4:-n/a}
IPv6: ${public_ipv6:-n/a}
Bevorzugte IP: ${public_ip:-?}
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
        --arg route4_provider "$route4_provider" \
        --arg route4_ip "$route4_ip" \
        --arg route4_city "$route4_city" \
        --arg route4_region "$route4_region" \
        --arg route4_country_name "$route4_country_name" \
        --arg route4_country_code "$route4_country_code" \
        --arg route4_org "$route4_org" \
        --arg route4_lat "$route4_lat" \
        --arg route4_lon "$route4_lon" \
        --arg route4_postal "$route4_postal" \
        --arg route4_summary "$route4_summary" \
        --arg route6_provider "$route6_provider" \
        --arg route6_ip "$route6_ip" \
        --arg route6_city "$route6_city" \
        --arg route6_region "$route6_region" \
        --arg route6_country_name "$route6_country_name" \
        --arg route6_country_code "$route6_country_code" \
        --arg route6_org "$route6_org" \
        --arg route6_lat "$route6_lat" \
        --arg route6_lon "$route6_lon" \
        --arg route6_postal "$route6_postal" \
        --arg route6_summary "$route6_summary" \
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
        --arg public_ipv4 "$public_ipv4" \
        --arg public_ipv6 "$public_ipv6" \
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
            public_ipv4: $public_ipv4,
            public_ipv6: $public_ipv6,
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
            route4: {
                provider: $route4_provider,
                ip: $route4_ip,
                city: $route4_city,
                region: $route4_region,
                country_name: $route4_country_name,
                country_code: $route4_country_code,
                org: $route4_org,
                lat: $route4_lat,
                lon: $route4_lon,
                postal: $route4_postal,
                summary: $route4_summary
            },
            route6: {
                provider: $route6_provider,
                ip: $route6_ip,
                city: $route6_city,
                region: $route6_region,
                country_name: $route6_country_name,
                country_code: $route6_country_code,
                org: $route6_org,
                lat: $route6_lat,
                lon: $route6_lon,
                postal: $route6_postal,
                summary: $route6_summary
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

    if [[ "$FORCE_REFRESH" -eq 0 && "$SKIP_STATE_CACHE" -eq 0 ]] && cache_is_fresh; then
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

    if [[ "$FORCE_REFRESH" -eq 0 && "$SKIP_STATE_CACHE" -eq 0 ]] && cache_is_fresh; then
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
            (.status_label + (if .vpn_active and (.vpn_name | length) > 0 then " (" + .vpn_name + ")" else "" end) + (if .full_tunnel then " (Full Tunnel)" elif .vpn_active then " (Split Tunnel)" else "" end)),
            ("Land: " + (
                if (.display_country_name | length) > 0 then .display_country_name
                elif (.display_country_code | length) > 0 then .display_country_code
                else "Unbekannt"
                end
            )),
            ("IPv4: " + (if (.public_ipv4 | length) > 0 then .public_ipv4 else "n/a" end)),
            ("IPv6: " + (if (.public_ipv6 | length) > 0 then .public_ipv6 else "n/a" end)),
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

# Cheap enough to poll every few seconds; never touches the network.
if [[ "$MODE" == "fingerprint" ]]; then
    network_fingerprint
    exit 0
fi

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
