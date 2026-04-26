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
        display_country_name: "",
        display_country_code: "",
        display_org: "",
        public_ip: "",
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
    toolTipMainText: state.status_label || i18n("VPN Status")
    toolTipSubText: [
        displayLocationText(),
        state.public_ip ? i18n("IP: %1", state.public_ip) : i18n("IP: unbekannt"),
        state.vpn_iface || state.default_iface ? i18n("Interface: %1", state.vpn_iface || state.default_iface) : "",
        errorText,
    ].filter(Boolean).join("\n")

    ExecUtil {
        id: executor
    }

    Timer {
        interval: 20000
        running: true
        repeat: true
        onTriggered: root.refresh(false)
    }

    function backendCommand(force) {
        let command = shellQuote(backendPath) + " --json"

        if (force) {
            command += " --force"
        }

        command = "if [ -x " + shellQuote(backendPath) + " ]; then " +
            command +
            "; else echo \"vpn_widget_backend.sh is not installed inside the plasmoid package\" >&2; exit 127; fi"
        return command
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\"'\"'") + "'"
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

    function refresh(force) {
        loading = true

        executor.exec(backendCommand(force), function(stdout, exitCode, exitStatus, stderr) {
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

    Component.onCompleted: refresh(false)
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

    fullRepresentation: PlasmaExtras.Representation {
        collapseMarginsHint: true

        PlasmaComponents3.ScrollView {
            anchors.fill: parent

            ColumnLayout {
                width: parent.width
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    PlasmaComponents3.Label {
                        text: root.state.icon_symbol || "󰒘"
                        font.family: root.glyphFontFamily
                        font.pixelSize: Kirigami.Units.iconSizes.large
                        Layout.alignment: Qt.AlignTop
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing / 2

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: root.state.status_label || i18n("VPN Status")
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: [
                                root.state.flag || "??",
                                root.displayLocationText(),
                            ].filter(Boolean).join("  ")
                            wrapMode: Text.WordWrap
                            opacity: 0.8
                        }
                    }

                    QQC2.Button {
                        icon.name: "view-refresh"
                        text: i18n("Aktualisieren")
                        onClicked: root.refresh(true)
                    }
                }

                PlasmaExtras.PlaceholderMessage {
                    Layout.fillWidth: true
                    visible: root.errorText.length > 0
                    iconName: "network-error"
                    text: root.errorText
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: Kirigami.Units.largeSpacing
                    rowSpacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        text: i18n("Öffentliche IP")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.public_ip || "?"
                        wrapMode: Text.WrapAnywhere
                    }

                    PlasmaComponents3.Label {
                        text: i18n("Quelle")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.sourceText(root.state.display_source)
                        wrapMode: Text.WordWrap
                    }

                    PlasmaComponents3.Label {
                        text: i18n("Ort")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.displayLocationText()
                        wrapMode: Text.WordWrap
                    }

                    PlasmaComponents3.Label {
                        text: i18n("Provider")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.display_org || "?"
                        wrapMode: Text.WordWrap
                    }

                    PlasmaComponents3.Label {
                        text: i18n("VPN-Interface")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.vpn_iface || root.state.default_iface || "?"
                        wrapMode: Text.WrapAnywhere
                    }

                    PlasmaComponents3.Label {
                        text: i18n("Endpoint")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.endpoint_ip || i18n("n/a")
                        wrapMode: Text.WrapAnywhere
                    }

                    PlasmaComponents3.Label {
                        text: i18n("Koordinaten")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: (root.state.display_lat || root.state.display_lon)
                            ? `${root.state.display_lat}, ${root.state.display_lon}`
                            : i18n("n/a")
                        wrapMode: Text.WordWrap
                    }

                    PlasmaComponents3.Label {
                        text: i18n("PLZ")
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.display_postal || i18n("n/a")
                        wrapMode: Text.WordWrap
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        text: i18n("Routen-Standort")
                        font.bold: true
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.route.summary && root.state.route.summary !== "Unknown"
                            ? root.state.route.summary
                            : i18n("Keine Daten")
                        wrapMode: Text.WordWrap
                        opacity: 0.8
                    }

                    PlasmaComponents3.Label {
                        text: i18n("VPN-Endpoint-Standort")
                        font.bold: true
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.endpoint.summary && root.state.endpoint.summary !== "Unknown"
                            ? root.state.endpoint.summary
                            : i18n("Keine Daten")
                        wrapMode: Text.WordWrap
                        opacity: 0.8
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.state.updated_at
                            ? i18n("Zuletzt aktualisiert: %1", root.state.updated_at)
                            : ""
                        wrapMode: Text.WordWrap
                        opacity: 0.6
                    }
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
