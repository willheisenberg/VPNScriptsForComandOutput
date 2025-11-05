#!/usr/bin/env bash
# Compact Public IP & VPN Info for KDE Plasma Command Output widget
# Monitors VPN/WireGuard state and updates after change or 5min timeout

MAX_WAIT=300   # seconds (5 minutes)
INTERVAL=2     # polling interval

# --- helper: detect current VPN state (active/inactive) ---
get_vpn_state() {
    if wg show all endpoints 2>/dev/null | grep -q .; then
        echo "active"; return
    fi
    if nmcli -t -f TYPE con show --active 2>/dev/null | grep -Eq 'vpn|wireguard'; then
        echo "active"; return
    fi
    echo "inactive"
}

# --- initial state ---
prev_state=$(get_vpn_state)
prev_ip=$(wg show all endpoints 2>/dev/null | awk '{print $3}' | sed -E 's/^\[?([^]:]+).*/\1/' | head -n1)
elapsed=0

# --- wait loop: exit if state or endpoint changes OR after timeout ---
while (( elapsed < MAX_WAIT )); do
    cur_state=$(get_vpn_state)
    cur_ip=$(wg show all endpoints 2>/dev/null | awk '{print $3}' | sed -E 's/^\[?([^]:]+).*/\1/' | head -n1)
    if [[ "$cur_state" != "$prev_state" || "$cur_ip" != "$prev_ip" ]]; then
        break  # state or endpoint changed → refresh immediately
    fi
    sleep "$INTERVAL"
    ((elapsed+=INTERVAL))
done


# small grace period after state change
sleep 2

# --- detect active endpoints ---
endpoint_ip=$(wg show all endpoints 2>/dev/null | awk '{print $3}' \
    | sed -E 's/^\[?([^]:]+).*/\1/' | head -n1)

nm_vpn_iface=$(nmcli -t -f TYPE,DEVICE con show --active 2>/dev/null \
    | awk -F: '$1=="vpn" || $1=="wireguard" {print $2; exit}')

# --- decide query ---
if [[ -n "$endpoint_ip" ]]; then
    vpn_state="active"
    url="https://ipinfo.io/${endpoint_ip}/json"
    curl_opts=""
elif [[ -n "$nm_vpn_iface" ]]; then
    vpn_state="active"
    url="https://ipinfo.io/json"
    curl_opts="--interface $nm_vpn_iface -4"
else
    vpn_state="inactive"
    url="https://ipinfo.io/json"
    curl_opts="-4"
fi

# --- fetch JSON data safely ---
json=$(curl $curl_opts -fsS --max-time 5 "$url" 2>/dev/null)

# --- fallback if response empty or missing country ---
if [[ -z "$json" ]] || ! jq -e '.country | select(.!=null and .!="")' <<<"$json" >/dev/null; then
    json=$(curl -fsS --max-time 5 https://ipinfo.io/json 2>/dev/null)
fi

# --- fallback if still empty (no internet) ---
if [[ -z "$json" ]]; then
    vpn_icon="󰦝"   # neutral ON symbol (route rebuilding)
    flag="🏴"
    echo "$vpn_icon $flag"
    exit 0
fi

# --- extract country code ---
cc=$(jq -r '.country // "XX"' <<< "$json")

# --- Unicode flag (UTF-8 via Python) ---
if [[ $cc =~ ^[A-Za-z]{2}$ ]]; then
    flag=$(python3 -c "cc='$cc'.upper(); print(chr(127397+ord(cc[0])) + chr(127397+ord(cc[1])))")
else
    flag="🏠"  # fallback for unknown
fi

# --- choose shield icon ---
if [[ "$vpn_state" == "active" ]]; then
    vpn_icon="󰦝"   # Shield ON
else
    vpn_icon="󰒘"   # Shield OFF
fi

# --- Output for Plasma panel ---
echo "$vpn_icon $flag"
