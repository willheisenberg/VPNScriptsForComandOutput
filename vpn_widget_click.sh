#!/usr/bin/env bash
# Show full IP/VPN info as KDE notification (WireGuard + NetworkManager)
# Original logic preserved + Morocco-safe fallback

# --- detect WireGuard endpoint ---
endpoint_ip=$(wg show all endpoints 2>/dev/null | awk '{print $3}' | head -n1)

# --- detect NetworkManager VPN ---
nm_vpn_iface=$(nmcli -t -f TYPE,DEVICE con show --active 2>/dev/null \
    | awk -F: '$1=="vpn" || $1=="wireguard" {print $2; exit}')

# --- choose API depending on VPN state ---
if [[ -n "$endpoint_ip" || -n "$nm_vpn_iface" ]]; then
    vpn_state="active"

    # --- clean endpoint: remove brackets + port safely ---
    if [[ "$endpoint_ip" =~ ^\[([0-9a-fA-F:]+)\](:[0-9]+)?$ ]]; then
        endpoint_ip_clean="${BASH_REMATCH[1]}"
    elif [[ "$endpoint_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?$ ]]; then
        endpoint_ip_clean="${BASH_REMATCH[1]}"
    else
        endpoint_ip_clean="${endpoint_ip%%:*}"
    fi

    # --- API selection based on address type (UNCHANGED LOGIC) ---
    if [[ "$endpoint_ip_clean" == *:* ]]; then
        url="https://ipapi.co/${endpoint_ip_clean}/json"
        api="ipapi"
        curl_opts=""
    elif [[ "$endpoint_ip_clean" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        url="https://ipinfo.io/${endpoint_ip_clean}/json"
        api="ipinfo"
        curl_opts=""
    else
        url="https://ipapi.co/json"
        api="ipapi"
        curl_opts="-4"
    fi
else
    vpn_state="inactive"
    url="https://ipapi.co/json"
    curl_opts="-4"
    api="ipapi"
fi

# --- fetch data ---
json=$(curl $curl_opts -fsS --max-time 5 "$url" 2>/dev/null)

# --- HARD VALIDATION ---
if ! jq -e '.ip // .query // .address' >/dev/null 2>&1 <<<"$json"; then
    if [[ "$vpn_state" == "active" ]]; then
        # VPN active but endpoint lookup failed → fallback to public IPv4
        json=$(curl -4 -fsS --max-time 5 https://ipapi.co/json 2>/dev/null)
        api="ipapi"
    else
        # Non-VPN fallback
        json=$(curl -4 -fsS --max-time 5 https://ipwho.is/ 2>/dev/null)
        api="ipapi"
    fi
fi

# --- parse depending on API ---
if [[ "$api" == "ipinfo" ]]; then
    ip=$(jq -r '.ip // "?"' <<<"$json")
    city=$(jq -r '.city // "Unknown"' <<<"$json")
    region=$(jq -r '.region // "Unknown"' <<<"$json")
    country_name=$(jq -r '.country // "Unknown"' <<<"$json")
    country_code=$(jq -r '.country // "XX"' <<<"$json")
    org=$(jq -r '.org // "Unknown"' <<<"$json")
    loc=$(jq -r '.loc // "?,?"' <<<"$json")
    lat=${loc%%,*}
    lon=${loc##*,}
    postal=$(jq -r '.postal // "N/A"' <<<"$json")
else
    ip=$(jq -r '.ip // "?"' <<<"$json")
    city=$(jq -r '.city // "Unknown"' <<<"$json")
    region=$(jq -r '.region // "Unknown"' <<<"$json")
    country_name=$(jq -r '.country_name // .country // "Unknown"' <<<"$json")
    country_code=$(jq -r '.country // .country_code // "XX"' <<<"$json")
    org=$(jq -r '.org // "Unknown"' <<<"$json")
    postal=$(jq -r '.postal // "N/A"' <<<"$json")
    lat=$(jq -r '.latitude // "?"' <<<"$json")
    lon=$(jq -r '.longitude // "?"' <<<"$json")
fi

# --- generate flag ---
if [[ ${#country_code} -eq 2 ]]; then
    flag=$(python3 -c "cc='$country_code'.upper(); print(chr(127397+ord(cc[0])) + chr(127397+ord(cc[1])))")
else
    flag="$country_code"
fi

# --- Nerd Font icons ---
if [[ "$vpn_state" == "active" ]]; then
    vpn_icon="󰦝"
else
    vpn_icon="󰒘"
fi

# --- KDE notification ---
notify-send "${vpn_icon} Public IP Info ${flag}" \
"IP: $ip
Location: $city, $region, $country_name ($postal)
ISP: $org
Coordinates: $lat,$lon
VPN: ${vpn_state^^}" \
-i network-wireless
