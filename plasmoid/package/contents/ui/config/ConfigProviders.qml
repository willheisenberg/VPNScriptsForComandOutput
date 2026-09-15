import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: root

    property alias cfg_ipgeoKey: ipgeoKey.text
    property alias cfg_ipinfoToken: ipinfoToken.text
    property alias cfg_ipapiKey: ipapiKey.text

    Kirigami.FormLayout {
        anchors.fill: parent

        QQC2.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
            text: i18n("Die Standortdaten kommen von ipwho.is, das ohne Schlüssel funktioniert. Die folgenden Anbieter werden nur als Reserve angefragt, wenn ipwho.is nicht antwortet — ohne Schlüssel sind sie schnell am Limit.")
            wrapMode: Text.WordWrap
            opacity: 0.7
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("ipgeolocation.io")
        }

        QQC2.TextField {
            id: ipgeoKey

            Kirigami.FormData.label: i18n("API-Schlüssel:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 20
            echoMode: showIpgeo.checked ? TextInput.Normal : TextInput.Password
            placeholderText: i18n("leer = Anbieter wird übersprungen")
        }

        QQC2.CheckBox {
            id: showIpgeo
            text: i18n("Schlüssel anzeigen")
        }

        QQC2.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
            text: i18n("1000 Abfragen pro Tag kostenlos, mit Stadt, PLZ und Koordinaten. Registrierung ohne Kreditkarte auf ipgeolocation.io, Schlüssel danach im Dashboard.")
            wrapMode: Text.WordWrap
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.6
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("ipinfo.io")
        }

        QQC2.TextField {
            id: ipinfoToken

            Kirigami.FormData.label: i18n("Token:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 20
            echoMode: showIpinfo.checked ? TextInput.Normal : TextInput.Password
            placeholderText: i18n("leer = ohne Token, stark limitiert")
        }

        QQC2.CheckBox {
            id: showIpinfo
            text: i18n("Token anzeigen")
        }

        QQC2.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
            text: i18n("Registrierung ohne Kreditkarte, Token unter ipinfo.io/dashboard/token. Liefert damit weiterhin Stadt, Region, PLZ und Koordinaten. Ohne Token ist der Anbieter nach wenigen Abfragen für den Rest des Tages gesperrt.")
            wrapMode: Text.WordWrap
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.6
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("ipapi.co")
        }

        QQC2.TextField {
            id: ipapiKey

            Kirigami.FormData.label: i18n("API-Schlüssel:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 20
            echoMode: showIpapi.checked ? TextInput.Normal : TextInput.Password
            placeholderText: i18n("leer = ohne Schlüssel, stark limitiert")
        }

        QQC2.CheckBox {
            id: showIpapi
            text: i18n("Schlüssel anzeigen")
        }

        QQC2.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
            text: i18n("Kein Self-Service: ein Testzugang muss per E-Mail von einer Firmenadresse angefragt werden. Der Schlüssel wird als ?key= angehängt — falls die Zugangsdaten etwas anderes vorgeben, muss das im Backend angepasst werden.")
            wrapMode: Text.WordWrap
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.6
        }

        Item {
            Kirigami.FormData.isSection: true
        }

        QQC2.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
            text: i18n("Die Schlüssel werden dem Backend als Umgebungsvariablen übergeben. Andere Prozesse desselben Benutzers können sie damit auslesen.")
            wrapMode: Text.WordWrap
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.6
        }
    }
}
