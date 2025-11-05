#!/usr/bin/env bash
# Tooltip Hover Script for CommandOutput Widget
# Shows active WireGuard connection name (if any)

# Check if WireGuard interface is active
iface=$(wg show 2>/dev/null | awk '/^interface:/{print $2; exit}')

if [[ -n "$iface" ]]; then
    echo "WireGuard Connection: $iface"
else
    echo "WireGuard: inactive"
fi
