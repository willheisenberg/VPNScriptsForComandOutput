#!/usr/bin/env bash
# Tooltip Hover Script for CommandOutput Widget
# Shows active WireGuard (non-Mullvad) and Mullvad VPN status

# --- WireGuard Interface (ignore Mullvad internal WG interfaces) ---
iface=$(wg show 2>/dev/null | awk '/^interface:/{print $2}' | grep -vE '^(wg0|mullvad|wg-mullvad|wg0-mullvad)$' | head -n1)

if [[ -n "$iface" ]]; then
    wg_status="WireGuard Connection: $iface"
else
    wg_status="WireGuard: inactive"
fi

# --- Mullvad VPN ---
if command -v mullvad &>/dev/null; then
    mullvad_output=$(mullvad status 2>/dev/null)
    if grep -qE '^Connected' <<< "$mullvad_output"; then
        mullvad_status="Mullvad: active"
    elif grep -qE '^Connecting' <<< "$mullvad_output"; then
        mullvad_status="Mullvad: connecting..."
    elif grep -qE '^Disconnected' <<< "$mullvad_output"; then
        mullvad_status="Mullvad: inactive"
    else
        mullvad_status="Mullvad: unknown"
    fi
else
    mullvad_status="Mullvad: not installed"
fi

# --- Output ---
echo -e "$wg_status\n$mullvad_status"
