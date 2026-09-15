import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    readonly property bool verticalPanel: [
        PlasmaCore.Types.LeftEdge,
        PlasmaCore.Types.RightEdge,
    ].includes(Plasmoid.location)

    property bool loading: false
    property string errorText: ""
    readonly property string glyphFontFamily: "JetBrainsMono Nerd Font Mono"
    readonly property real flagSizeFactor: Math.max(0.8, Number(Plasmoid.configuration.flagSizePercent || 100) / 100.0)
    readonly property string backendPath: decodeURIComponent(
        Qt.resolvedUrl("../bin/vpn_widget_backend.sh").toString().replace("file://", "")
    )
    property var state: ({
        vpn_active: false,
        full_tunnel: false,
        status_label: "VPN Status",
        status_detail: "Noch keine Daten",
        vpn_name: "",
        display_country_name: "",
        display_country_code: "",
        display_org: "",
        public_ip: "",
        public_ipv4: "",
        public_ipv6: "",
        display_source: "",
        display_lat: "",
        display_lon: "",
        display_postal: "",
        display_city: "",
        display_region: "",
        location_text: "",
        flag: "??",
        icon_name: "network-wireless",
        icon_symbol: "󰒘",
        vpn_iface: "",
        default_iface: "",
        endpoint_ip: "",
        route: {
            summary: "",
        },
        endpoint: {
            summary: "",
        },
        updated_at: "",
    })

    Plasmoid.title: i18n("VPN Status")
    Plasmoid.icon: state.icon_name || "network-wireless"
    Plasmoid.status: state.vpn_active ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    Plasmoid.busy: loading

    preferredRepresentation: compactRepresentation
    activationTogglesExpanded: false
    hideOnWindowDeactivate: true
    switchWidth: Kirigami.Units.gridUnit * 18
    switchHeight: Kirigami.Units.gridUnit * 18
    toolTipMainText: state.vpn_active && state.vpn_name ? i18n("VPN: %1", state.vpn_name) : (state.status_label || i18n("VPN Status"))
    toolTipSubText: [
        state.vpn_active ? (state.full_tunnel ? i18n("Full Tunnel") : i18n("Split Tunnel")) : "",
        displayLocationText(),
        state.public_ip ? i18n("IP: %1", state.public_ip) : i18n("IP: unbekannt"),
        state.vpn_iface || state.default_iface ? i18n("Interface: %1", state.vpn_iface || state.default_iface) : "",
        errorText,
    ].filter(Boolean).join("\n")

    ExecUtil {
        id: executor
    }

    // A stuck backend must not stall the cheap change detection, so the
    // fingerprint probe gets its own queue.
    ExecUtil {
        id: prober

        timeoutMs: 10000
        maxQueueLength: 1
    }

    property string networkFingerprint: ""

    Timer {
        // ~19ms of local work per tick, no network traffic at all.
        interval: 3000
        running: true
        repeat: true
        onTriggered: root.probeNetwork()
    }

    function probeNetwork() {
        prober.exec(
            "if [ -x " + shellQuote(backendPath) + " ]; then " +
                shellQuote(backendPath) + " --fingerprint" +
            "; fi",
            function(stdout, exitCode) {
                const fingerprint = String(stdout).trim()

                if (exitCode !== 0 || !fingerprint) {
                    return
                }
                if (root.networkFingerprint === fingerprint) {
                    return
                }

                const first = root.networkFingerprint === ""
                root.networkFingerprint = fingerprint

                // Interfaces, default routes or the WireGuard peer changed:
                // recompute now instead of waiting for the next timer tick.
                if (!first) {
                    root.refresh(false, true)
                }
            }
        )
    }

    function backendEnvironment() {
        return [
            ["VPN_WIDGET_IPGEO_KEY", Plasmoid.configuration.ipgeoKey],
            ["VPN_WIDGET_IPINFO_TOKEN", Plasmoid.configuration.ipinfoToken],
            ["VPN_WIDGET_IPAPI_KEY", Plasmoid.configuration.ipapiKey],
        ].filter(entry => entry[1])
         .map(entry => entry[0] + "=" + shellQuote(String(entry[1]).trim()))
         .join(" ")
    }

    function backendCommand(force, skipStateCache) {
        const environment = backendEnvironment()
        let command = (environment ? environment + " " : "") + shellQuote(backendPath) + " --json"

        if (force) {
            command += " --force"
        } else if (skipStateCache) {
            command += " --no-cache"
        }

        command = "if [ -x " + shellQuote(backendPath) + " ]; then " +
            command +
            "; else echo \"vpn_widget_backend.sh is not installed inside the plasmoid package\" >&2; exit 127; fi"
        return command
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\"'\"'") + "'"
    }

    function providerText(providerName) {
        switch (providerName) {
        case "ipwho":
            return "ipwho.is"
        case "ipgeo":
            return "ipgeolocation.io"
        case "ipapi":
            return "ipapi.co"
        case "ipinfo":
            return "ipinfo.io"
        default:
            return providerName || i18n("unbekannt")
        }
    }

    function sourceText(sourceName) {
        switch (sourceName) {
        case "vpn-endpoint":
            return i18n("VPN-Endpoint")
        case "public-route":
            return i18n("Öffentliche Route")
        default:
            return sourceName || i18n("Unbekannt")
        }
    }

    function displayLocationText() {
        if (!state.location_text || state.location_text === "Unknown") {
            return i18n("Standort unbekannt")
        }

        return state.location_text
    }

    function refresh(force, skipStateCache) {
        loading = true

        executor.exec(backendCommand(force, skipStateCache), function(stdout, exitCode, exitStatus, stderr) {
            loading = false

            if (exitCode !== 0 || exitStatus !== 0) {
                errorText = stderr ? stderr.trim() : i18n("Backend konnte nicht ausgeführt werden.")
                return
            }

            try {
                state = JSON.parse(stdout.trim())
                errorText = ""
            } catch (error) {
                errorText = i18n("Antwort vom Backend ist ungültig.")
            }
        })
    }

    Component.onCompleted: {
        refresh(false)
        probeNetwork()
    }
    onExpandedChanged: {
        if (expanded) {
            refresh(false)
        }
    }

    compactRepresentation: MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Loader {
            anchors.centerIn: parent
            sourceComponent: root.verticalPanel ? verticalCompact : horizontalCompact
        }
    }

    component SectionHeader: PlasmaComponents3.Label {
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.5
        font.bold: true
        opacity: 0.6
        elide: Text.ElideRight
    }

    component InfoRow: RowLayout {
        id: infoRow

        property string label: ""
        property string value: ""
        property bool wrapAnywhere: false

        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        PlasmaComponents3.Label {
            text: infoRow.label
            opacity: 0.7
            Layout.alignment: Qt.AlignLeft | Qt.AlignTop
        }

        PlasmaComponents3.Label {
            text: infoRow.value
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignRight | Qt.AlignTop
            horizontalAlignment: Text.AlignRight
            wrapMode: infoRow.wrapAnywhere ? Text.WrapAnywhere : Text.WordWrap
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        id: fullRep

        readonly property string tunnelText: root.state.full_tunnel
            ? i18n("Full Tunnel")
            : i18n("Split Tunnel")
        readonly property string endpointSummary: root.state.endpoint.summary
            && root.state.endpoint.summary !== "Unknown"
            ? root.state.endpoint.summary
            : ""
        readonly property string routeSummary: root.state.route.summary
            && root.state.route.summary !== "Unknown"
            ? root.state.route.summary
            : ""

        collapseMarginsHint: true

        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        Layout.preferredHeight: mainLayout.implicitHeight + Kirigami.Units.gridUnit * 2
        Layout.minimumWidth: Layout.preferredWidth
        Layout.maximumWidth: Layout.preferredWidth
        Layout.minimumHeight: Layout.preferredHeight
        Layout.maximumHeight: Layout.preferredHeight

        PlasmaComponents3.ScrollView {
            id: scrollView
            anchors.fill: parent
            contentWidth: availableWidth
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            ColumnLayout {
                id: mainLayout

                readonly property int sideMargin: Kirigami.Units.gridUnit

                x: sideMargin
                y: Kirigami.Units.gridUnit
                width: scrollView.availableWidth - sideMargin * 2
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.largeSpacing

                    PlasmaComponents3.Label {
                        text: root.state.icon_symbol || "󰒘"
                        font.family: root.glyphFontFamily
                        font.pixelSize: Kirigami.Units.iconSizes.medium
                        Layout.alignment: Qt.AlignVCenter
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: root.state.status_label || i18n("VPN Status")
                            font.bold: true
                            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
                            elide: Text.ElideRight
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents3.Label {
                                text: [
                                    root.state.flag,
                                    root.state.vpn_active ? root.state.vpn_name : "",
                                ].filter(Boolean).join("  ")
                                opacity: 0.7
                                elide: Text.ElideRight
                            }

                            PlasmaComponents3.Label {
                                text: "·"
                                opacity: 0.4
                                visible: root.state.vpn_active
                            }

                            PlasmaComponents3.Label {
                                text: fullRep.tunnelText
                                // Split tunnel means most traffic bypasses the VPN — worth flagging.
                                color: root.state.full_tunnel
                                    ? Kirigami.Theme.positiveTextColor
                                    : Kirigami.Theme.neutralTextColor
                                visible: root.state.vpn_active
                                elide: Text.ElideRight
                            }

                            Item {
                                Layout.fillWidth: true
                            }
                        }
                    }

                    QQC2.ToolButton {
                        icon.name: "view-refresh"
                        display: QQC2.AbstractButton.IconOnly
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: root.refresh(true)

                        QQC2.ToolTip.text: i18n("Aktualisieren")
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                    }
                }

                PlasmaExtras.PlaceholderMessage {
                    Layout.fillWidth: true
                    visible: root.errorText.length > 0
                    iconName: "network-error"
                    text: root.errorText
                }

                SectionHeader {
                    text: i18n("Adresse")
                }

                InfoRow {
                    label: i18n("IPv4")
                    value: root.state.public_ipv4 || i18n("n/a")
                    wrapAnywhere: true
                }

                InfoRow {
                    label: i18n("IPv6")
                    value: root.state.public_ipv6 || i18n("n/a")
                    wrapAnywhere: true
                }

                SectionHeader {
                    text: root.state.display_source === "vpn-endpoint"
                        ? i18n("Standort (VPN-Endpoint)")
                        : i18n("Standort (öffentliche Route)")
                }

                InfoRow {
                    label: i18n("Ort")
                    value: root.displayLocationText()
                }

                InfoRow {
                    label: i18n("Provider")
                    value: root.state.display_org || i18n("n/a")
                }

                InfoRow {
                    label: i18n("Koordinaten")
                    value: (root.state.display_lat || root.state.display_lon)
                        ? `${root.state.display_lat}, ${root.state.display_lon}`
                        : i18n("n/a")
                }

                InfoRow {
                    label: i18n("PLZ")
                    value: root.state.display_postal || i18n("n/a")
                }

                InfoRow {
                    // The fallback chain can hand back a different city, so name
                    // the service the numbers above actually came from.
                    label: i18n("Datenquelle")
                    value: root.providerText(root.state.display_provider)
                    visible: !!root.state.display_provider
                }

                SectionHeader {
                    text: i18n("Tunnel")
                }

                InfoRow {
                    label: i18n("Verbindung")
                    value: root.state.vpn_name
                    // Redundant whenever NetworkManager names the connection after the device.
                    visible: root.state.vpn_active
                        && !!root.state.vpn_name
                        && root.state.vpn_name !== root.state.vpn_iface
                }

                InfoRow {
                    label: i18n("Interface")
                    value: root.state.vpn_iface || root.state.default_iface || i18n("n/a")
                    wrapAnywhere: true
                }

                InfoRow {
                    label: i18n("Endpoint")
                    value: root.state.endpoint_ip
                    wrapAnywhere: true
                    visible: !!root.state.endpoint_ip
                }

                InfoRow {
                    label: i18n("Endpoint-Standort")
                    value: fullRep.endpointSummary
                    visible: !!fullRep.endpointSummary
                        && fullRep.endpointSummary !== root.state.location_text
                }

                InfoRow {
                    label: i18n("Routen-Standort")
                    value: fullRep.routeSummary
                    visible: !!fullRep.routeSummary
                        && fullRep.routeSummary !== root.state.location_text
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.largeSpacing
                    text: root.state.updated_at
                        ? i18n("Zuletzt aktualisiert: %1", root.state.updated_at)
                        : ""
                    visible: text.length > 0
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    opacity: 0.5
                    elide: Text.ElideRight
                }
            }
        }
    }

    Component {
        id: horizontalCompact

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                text: root.state.icon_symbol || "󰒘"
                font.family: root.glyphFontFamily
                font.pixelSize: Kirigami.Units.iconSizes.smallMedium
            }

            PlasmaComponents3.Label {
                text: root.state.flag || "??"
                font.pointSize: Kirigami.Theme.defaultFont.pointSize
                font.pixelSize: Math.round(Kirigami.Units.iconSizes.smallMedium * root.flagSizeFactor)
            }
        }
    }

    Component {
        id: verticalCompact

        ColumnLayout {
            spacing: 0

            PlasmaComponents3.Label {
                Layout.alignment: Qt.AlignHCenter
                text: root.state.icon_symbol || "󰒘"
                font.family: root.glyphFontFamily
                font.pixelSize: Kirigami.Units.iconSizes.smallMedium
            }

            PlasmaComponents3.Label {
                Layout.alignment: Qt.AlignHCenter
                text: root.state.flag || "??"
                font.pixelSize: Math.max(
                    10,
                    Math.round((Kirigami.Units.iconSizes.smallMedium - 2) * root.flagSizeFactor)
                )
            }
        }
    }
}
