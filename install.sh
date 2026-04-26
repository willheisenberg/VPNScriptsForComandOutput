#!/usr/bin/env bash
set -e

echo "🔧 VPN Widget Installer for KDE Plasma"
echo "======================================"
echo
echo "This script will install all required dependencies:"
echo "  • WireGuard + NetworkManager"
echo "  • Mullvad VPN CLI (if available)"
echo "  • jq, curl, python3"
echo "  • Emoji/Noto fonts"
echo "  • Nerd Font for shield glyphs"
echo "  • Plasma widget packaging tools"
echo

# --- Locate script directory ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Detect distribution ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    echo "❌ Cannot detect Linux distribution."
    exit 1
fi

# --- Install dependencies ---
echo "📦 Installing dependencies for $DISTRO..."
case "$DISTRO" in
    arch|manjaro|endeavouros)
        sudo pacman -Syu --needed --noconfirm \
            wireguard-tools networkmanager jq curl python3 plasma-workspace || true

        # Nerd Font (choose one, no interactive prompt)
        if ! pacman -Q ttf-jetbrains-mono-nerd &>/dev/null; then
            echo "🖋️ Installing default Nerd Font (ttf-jetbrains-mono-nerd)..."
            sudo pacman -S --noconfirm ttf-jetbrains-mono-nerd || true
        fi

        # Mullvad (AUR)
        if ! command -v mullvad &>/dev/null; then
            echo "🌍 Mullvad not found in repos. Trying to install from AUR..."
            if command -v yay &>/dev/null; then
                yay -S --noconfirm mullvad-vpn
            elif command -v paru &>/dev/null; then
                paru -S --noconfirm mullvad-vpn
            else
                echo "⚠️ Please install Mullvad manually via AUR:"
                echo "   https://aur.archlinux.org/packages/mullvad-vpn"
            fi
        fi
        ;;
    ubuntu|debian|pop|neon)
        sudo apt update
        sudo apt install -y \
            wireguard-tools network-manager jq curl python3 \
            fonts-noto-color-emoji plasma-workspace plasma-widgets-addons || true

        if ! command -v mullvad &>/dev/null; then
            echo "🌍 Installing Mullvad VPN (Debian/Ubuntu package)..."
            wget -qO /tmp/mullvad.deb https://mullvad.net/download/app/deb/latest/
            sudo apt install -y /tmp/mullvad.deb || echo "⚠️ Mullvad install failed."
        fi
        ;;
    fedora)
        sudo dnf install -y \
            wireguard-tools NetworkManager jq curl python3 \
            google-noto-emoji-fonts plasma-workspace || true
        if ! command -v mullvad &>/dev/null; then
            echo "🌍 Installing Mullvad VPN for Fedora..."
            sudo dnf install -y https://mullvad.net/download/app/rpm/latest/ || true
        fi
        ;;
    opensuse*|suse)
        sudo zypper install -y \
            wireguard-tools NetworkManager jq curl python3 \
            google-noto-emoji-fonts plasma5-workspace || true
        ;;
    *)
        echo "⚠️ Unknown distribution: $DISTRO"
        echo "Please install manually: wireguard-tools networkmanager jq curl python3 nerd-fonts plasma-workspace mullvad"
        ;;
esac

# --- Ensure wg show can run without sudo ---
echo "🛠️ Granting wg capabilities..."
if command -v wg &>/dev/null; then
    sudo setcap cap_net_admin,cap_net_raw+ep "$(command -v wg)" || echo "⚠️ setcap failed (may require sudo rights)"
fi

# --- Verify Mullvad installation ---
if command -v mullvad &>/dev/null; then
    echo "✅ Mullvad VPN CLI found: $(mullvad version 2>/dev/null || echo 'version unknown')"
else
    echo "⚠️ Mullvad CLI not found. Install manually: https://mullvad.net/download/app"
fi

# --- Prepare plasmoid package ---
PLASMOID_DIR="$DIR/plasmoid/package"
chmod 755 "$PLASMOID_DIR/contents/bin/vpn_widget_backend.sh"

# --- Clear cached widget state so icon/output updates apply immediately ---
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/vpn-widget" "/tmp/vpn-widget-${USER:-$(id -u)}" 2>/dev/null || true

# --- Install / upgrade the real Plasma widget ---
if command -v kpackagetool6 &>/dev/null; then
    echo "🧩 Installing Plasma widget package..."
    if ! kpackagetool6 -t Plasma/Applet -u "$PLASMOID_DIR" >/dev/null 2>&1; then
        kpackagetool6 -t Plasma/Applet -i "$PLASMOID_DIR"
    fi
else
    echo "⚠️ kpackagetool6 not found. The backend scripts were installed, but the Plasma widget package could not be registered."
fi

# --- Finishing message ---
echo
echo "✅ Installation complete!"
echo
echo "---------------------------------------"
echo "To enable the new widget:"
echo "1️⃣ Right-click the panel → Add Widgets"
echo "2️⃣ Search for: VPN Status"
echo "3️⃣ Add it to the panel"
echo
echo "If the shield icons render as empty boxes, install any Nerd Font and restart Plasma."
echo "---------------------------------------"
echo "🎉 Done! Restart Plasma if needed:"
echo "   kquitapp6 plasmashell && kstart6 plasmashell"
echo
