# KDE Plasma VPN Status

Dieses Projekt installiert ein echtes **Plasma-6-Widget**, das du direkt ins KDE-Panel hinzufügen kannst.

## Was das Widget macht

- zeigt **VPN-Status** direkt im Panel
- zeigt **Landesflagge** und nutzt die echte Plasma-Widget-Integration
- öffnet beim Klick ein **Detail-Popup** mit IP, Provider, Endpoint und Standort
- nutzt eine **gemeinsame Backend-Logik** direkt im Plasmoid-Paket
- verwendet mehrere **Geo-IP-Fallbacks**, damit die Ländererkennung deutlich robuster ist
- unterscheidet zwischen **Full Tunnel** und **Split Tunnel**

## Warum die alte Version unzuverlässig war

Die bisherige Implementierung hat je nach Fall die **WireGuard-Endpoint-IP** statt der tatsächlichen Exit-IP verwendet. Das ist bei manchen VPN-Setups zwar brauchbar, aber nicht sauber, und einige Geo-IP-Dienste liefern in bestimmten Regionen oder bei einzelnen Providern unvollständige Daten. Das neue Backend fragt deshalb mehrere Anbieter ab und trennt klar zwischen:

- öffentlicher Route
- VPN-Endpoint
- angezeigter Herkunft der Standortdaten

## Installation

```bash
git clone https://github.com/willheisenberg/VPNScriptsForComandOutput
cd VPNScriptsForComandOutput
chmod +x install.sh
./install.sh
```

Danach:

1. Rechtsklick auf das KDE-Panel
2. `Widgets hinzufügen`
3. Nach `VPN Status` suchen
4. Widget ins Panel ziehen

## Aufbau

Das Widget ist jetzt in sich geschlossen:

- QML-UI unter `plasmoid/package/contents/ui/`
- Backend-Script unter `plasmoid/package/contents/bin/vpn_widget_backend.sh`

Es gibt keine separaten Legacy-Wrapper mehr.
