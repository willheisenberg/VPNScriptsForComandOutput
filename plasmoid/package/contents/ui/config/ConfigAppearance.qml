import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: root

    property alias cfg_flagSizePercent: flagSize.value

    Kirigami.FormLayout {
        anchors.fill: parent

        QQC2.SpinBox {
            id: flagSize

            Kirigami.FormData.label: i18n("Flaggengröße:")

            from: 80
            to: 220
            stepSize: 10
            editable: true

            textFromValue: function(value) {
                return `${value} %`
            }

            valueFromText: function(text) {
                const parsed = parseInt(text, 10)
                return Number.isNaN(parsed) ? 100 : parsed
            }
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Vorschau:")
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                text: "󰒘"
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: Kirigami.Units.iconSizes.smallMedium
            }

            QQC2.Label {
                text: "🇩🇪"
                font.pixelSize: Math.round(Kirigami.Units.iconSizes.smallMedium * (flagSize.value / 100))
            }
        }
    }
}
