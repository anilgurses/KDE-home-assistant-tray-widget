import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: root

    property alias cfg_haBaseUrl: haBaseUrl.text
    property alias cfg_haToken: haToken.text
    property string cfg_entityList
    property alias cfg_refreshSeconds: refreshSeconds.value
    property alias cfg_useHassCli: useHassCli.checked
    property alias cfg_hassCliCommand: hassCliCommand.text
    property string cfg_haBaseUrlDefault
    property string cfg_haTokenDefault
    property string cfg_entityListDefault
    property int cfg_refreshSecondsDefault
    property bool cfg_useHassCliDefault
    property string cfg_hassCliCommandDefault

    implicitWidth: Kirigami.Units.gridUnit * 26
    implicitHeight: Kirigami.Units.gridUnit * 30

    property bool discoverBusy: false
    property string discoverStatus: ""
    property string filterText: ""

    ListModel {
        id: discoveredModel
    }

    // Parse the comma-separated entity list into a JS object map
    function selectedMapFromConfig() {
        var map = {};
        var parts = String(cfg_entityList || "").split(",");
        for (var i = 0; i < parts.length; ++i) {
            var id = parts[i].trim();
            if (id.length > 0)
                map[id] = true;
        }
        return map;
    }

    // Count currently selected entities
    function selectedCount() {
        var parts = String(cfg_entityList || "").split(",");
        var count = 0;
        for (var i = 0; i < parts.length; ++i) {
            if (parts[i].trim().length > 0)
                count++;
        }
        return count;
    }

    // Toggle a single entity in/out of the config list
    function toggleEntity(entityId, checked) {
        var map = selectedMapFromConfig();
        if (checked)
            map[entityId] = true;
        else
            delete map[entityId];

        var keys = [];
        for (var k in map)
            keys.push(k);
        keys.sort();
        cfg_entityList = keys.join(",");
    }

    // Check if an entity is currently selected
    function isSelected(entityId) {
        var map = selectedMapFromConfig();
        return map[entityId] === true;
    }

    function discoverEntities() {
        var baseUrl = String(haBaseUrl.text || "").replace(/\/$/, "");
        var token = String(haToken.text || "");
        if (!baseUrl || !token) {
            discoverStatus = "Set Home Assistant URL and token first.";
            return;
        }

        discoverBusy = true;
        discoverStatus = "Discovering...";

        var xhr = new XMLHttpRequest();
        xhr.open("GET", baseUrl + "/api/states");
        xhr.timeout = 10000;
        xhr.setRequestHeader("Authorization", "Bearer " + token);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4)
                return;
            discoverBusy = false;
            if (xhr.status < 200 || xhr.status >= 300) {
                discoverStatus = "Failed: HTTP " + xhr.status;
                return;
            }
            try {
                var parsed = JSON.parse(xhr.responseText);
                var rows = [];
                for (var i = 0; i < parsed.length; ++i) {
                    var e = parsed[i];
                    var eid = String(e.entity_id || "");
                    rows.push({
                        entityId: eid,
                        name: String((e.attributes && e.attributes.friendly_name) ? e.attributes.friendly_name : eid),
                        domain: eid.split(".")[0]
                    });
                }
                rows.sort(function (a, b) {
                    return a.entityId.localeCompare(b.entityId);
                });

                discoveredModel.clear();
                for (var j = 0; j < rows.length; ++j)
                    discoveredModel.append(rows[j]);

                discoverStatus = "Found " + rows.length + " entities";
            } catch (e) {
                discoverStatus = "Failed: invalid JSON";
            }
        };
        xhr.onerror = function () {
            discoverBusy = false;
            discoverStatus = "Failed: network error";
        };
        xhr.ontimeout = function () {
            discoverBusy = false;
            discoverStatus = "Failed: timeout";
        };
        xhr.send();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        // ── Connection settings ──────────────────────────

        Kirigami.FormLayout {
            Layout.fillWidth: true

            QQC2.TextField {
                id: haBaseUrl
                Kirigami.FormData.label: "URL:"
                Layout.fillWidth: true
                placeholderText: "http://homeassistant.local:8123"
            }

            QQC2.TextField {
                id: haToken
                Kirigami.FormData.label: "Token:"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: "Long-lived access token"
            }

            QQC2.SpinBox {
                id: refreshSeconds
                Kirigami.FormData.label: "Refresh (s):"
                from: 5; to: 300; stepSize: 1
            }
        }

        // ── Entity discovery ─────────────────────────────

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: discoverBusy ? "Discovering..." : "Discover Entities"
                icon.name: "system-search"
                enabled: !discoverBusy
                onClicked: root.discoverEntities()
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: discoverStatus ? discoverStatus : (selectedCount() + " entities selected")
                color: Kirigami.Theme.disabledTextColor
                elide: Text.ElideRight
            }
        }

        // Search filter
        QQC2.TextField {
            Layout.fillWidth: true
            placeholderText: "Filter entities..."
            visible: discoveredModel.count > 0
            onTextChanged: root.filterText = text.toLowerCase()
        }

        // Entity list
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: discoveredModel
            clip: true
            spacing: 0
            boundsBehavior: Flickable.StopAtBounds

            QQC2.ScrollBar.vertical: QQC2.ScrollBar {
                active: true
            }

                delegate: QQC2.CheckDelegate {
                    id: checkDelegate
                    required property int index
                    required property string entityId
                    required property string name
                    required property string domain

                    width: ListView.view.width

                    // Filter visibility
                    visible: {
                        if (!root.filterText)
                            return true;
                        return entityId.toLowerCase().indexOf(root.filterText) >= 0
                            || name.toLowerCase().indexOf(root.filterText) >= 0;
                    }
                    height: visible ? implicitHeight : 0

                    checked: root.isSelected(entityId)
                    text: name

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        // Domain badge
                        Rectangle {
                            radius: 3
                            color: Kirigami.Theme.alternateBackgroundColor
                            border.width: 1
                            border.color: Kirigami.Theme.separatorColor
                            implicitWidth: domainLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                            implicitHeight: domainLabel.implicitHeight + 2
                            Layout.alignment: Qt.AlignVCenter

                            QQC2.Label {
                                id: domainLabel
                                anchors.centerIn: parent
                                text: checkDelegate.domain
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                color: Kirigami.Theme.disabledTextColor
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            QQC2.Label {
                                Layout.fillWidth: true
                                text: checkDelegate.name
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: checkDelegate.entityId
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                color: Kirigami.Theme.disabledTextColor
                                elide: Text.ElideRight
                            }
                        }
                    }

                    onToggled: root.toggleEntity(entityId, checked)
                }
            }

        // ── Advanced section ─────────────────────────────

        QQC2.CheckBox {
            id: useHassCli
            text: "Use hass-cli for reading state (advanced)"
        }

        QQC2.TextField {
            id: hassCliCommand
            Layout.fillWidth: true
            visible: useHassCli.checked
            placeholderText: "hass-cli state list --output json"
        }
    }
}
