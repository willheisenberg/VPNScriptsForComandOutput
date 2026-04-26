import QtQuick

import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Darstellung")
        icon: "preferences-desktop-color"
        source: "config/ConfigAppearance.qml"
    }
}
