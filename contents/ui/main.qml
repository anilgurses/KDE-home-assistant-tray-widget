import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQml.Models
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root
    switchWidth: Kirigami.Units.gridUnit * 24
    switchHeight: Kirigami.Units.gridUnit * 30

    readonly property string baseUrl: String(Plasmoid.configuration.haBaseUrl || "").replace(/\/$/, "")
    readonly property string token: String(Plasmoid.configuration.haToken || "")
    readonly property bool useHassCli: Boolean(Plasmoid.configuration.useHassCli)
    readonly property string hassCliCommand: String(Plasmoid.configuration.hassCliCommand || "")
    readonly property int refreshSeconds: Math.max(5, Number(Plasmoid.configuration.refreshSeconds || 10))

    property string statusText: "Waiting for first sync"
    property bool online: false
    property bool busy: false

    ListModel {
        id: entitiesModel
    }

    // ── Helper functions ───────────────────────────────────────

    function materialColorForState(state) {
        if (state === "on")
            return "#4CAF50";
        if (state === "off")
            return "#9E9E9E";
        if (state === "unavailable" || state === "unknown")
            return "#EF5350";
        return "#03A9F4";
    }

    function friendlyName(entityObj) {
        if (entityObj.attributes && entityObj.attributes.friendly_name)
            return entityObj.attributes.friendly_name;
        return entityObj.entity_id;
    }

    function domainOf(entityId) {
        return entityId.split(".")[0];
    }

    function isNumericState(state) {
        return !isNaN(parseFloat(state)) && isFinite(state);
    }

    function filterEntities(allEntities) {
        var entityFilter = configuredEntities();
        if (entityFilter.length === 0)
            return [];
        var allow = {};
        for (var i = 0; i < entityFilter.length; ++i)
            allow[entityFilter[i]] = true;
        return allEntities.filter(function (e) {
            return allow[e.entity_id] === true;
        });
    }

    function buildModelEntry(entityObj) {
        var domain = domainOf(entityObj.entity_id);
        var attrs = entityObj.attributes || {};
        var stateStr = String(entityObj.state);
        return {
            entityId: entityObj.entity_id,
            name: friendlyName(entityObj),
            state: stateStr,
            color: materialColorForState(stateStr),
            domain: domain,
            numericState: isNumericState(stateStr),
            brightness: (attrs.brightness !== undefined) ? Number(attrs.brightness) : -1,
            position: (attrs.current_position !== undefined) ? Number(attrs.current_position) : -1,
            temperature: (attrs.temperature !== undefined) ? Number(attrs.temperature) : -1,
            percentage: (attrs.percentage !== undefined) ? Number(attrs.percentage) : -1,
            attrMin: (attrs.min !== undefined) ? Number(attrs.min) : 0,
            attrMax: (attrs.max !== undefined) ? Number(attrs.max) : 100,
            attrStep: (attrs.step !== undefined) ? Number(attrs.step) : 1,
            unit: String(attrs.unit_of_measurement || ""),
            history: "[]"
        };
    }

    function reloadModelFromArray(entityArray) {
        entitiesModel.clear();
        for (var i = 0; i < entityArray.length; ++i)
            entitiesModel.append(buildModelEntry(entityArray[i]));
        online = true;
        statusText = "Loaded " + entityArray.length + " entities";
        fetchAllHistory();
    }

    function reloadModelWithSummary(foundEntities, missingIds) {
        var entityFilter = configuredEntities();
        entitiesModel.clear();
        for (var i = 0; i < foundEntities.length; ++i)
            entitiesModel.append(buildModelEntry(foundEntities[i]));
        online = foundEntities.length > 0;
        if (missingIds.length > 0)
            statusText = "Loaded " + foundEntities.length + "/" + entityFilter.length + " entities";
        else
            statusText = "Loaded " + foundEntities.length + " entities";
        fetchAllHistory();
    }

    function setErrorState(message) {
        online = false;
        statusText = message;
    }

    function hostFromBaseUrl() {
        var m = String(baseUrl).match(/^[a-zA-Z]+:\/\/([^\/:?#]+)/);
        if (m && m.length > 1)
            return m[1];
        return String(baseUrl);
    }

    function configuredEntities() {
        return String(Plasmoid.configuration.entityList || "").split(",").map(function (s) {
            return s.trim();
        }).filter(function (s) {
            return s.length > 0;
        });
    }

    // ── API calls ──────────────────────────────────────────────

    function fetchViaApi() {
        var entityFilter = configuredEntities();
        if (!baseUrl || !token) {
            setErrorState("Missing Home Assistant URL/token. Open widget settings.");
            return;
        }
        if (entityFilter.length === 0) {
            entitiesModel.clear();
            setErrorState("No entities configured. Add entity IDs in widget settings.");
            return;
        }

        busy = true;
        var pending = entityFilter.length;
        var found = [];
        var missing = [];
        var hadNetworkError = false;

        function doneOne() {
            pending -= 1;
            if (pending > 0)
                return;
            busy = false;
            if (hadNetworkError && found.length === 0) {
                setErrorState("Could not resolve host or reach: " + hostFromBaseUrl());
                return;
            }
            reloadModelWithSummary(found, missing);
        }

        for (var i = 0; i < entityFilter.length; ++i) {
            (function (entityId) {
                var xhr = new XMLHttpRequest();
                var completed = false;

                function markDone() {
                    if (completed) return true;
                    completed = true;
                    return false;
                }

                xhr.open("GET", baseUrl + "/api/states/" + encodeURIComponent(entityId));
                xhr.timeout = 10000;
                xhr.setRequestHeader("Authorization", "Bearer " + token);
                xhr.setRequestHeader("Content-Type", "application/json");
                xhr.onreadystatechange = function () {
                    if (xhr.readyState !== 4 || markDone()) return;
                    if (xhr.status >= 200 && xhr.status < 300) {
                        try {
                            var parsed = JSON.parse(xhr.responseText);
                            if (parsed && parsed.entity_id)
                                found.push(parsed);
                            else
                                missing.push(entityId);
                        } catch (e) {
                            missing.push(entityId);
                        }
                    } else {
                        if (xhr.status !== 404)
                            hadNetworkError = true;
                        missing.push(entityId);
                    }
                    doneOne();
                };
                xhr.onerror = function () {
                    if (markDone()) return;
                    hadNetworkError = true;
                    doneOne();
                };
                xhr.ontimeout = function () {
                    if (markDone()) return;
                    hadNetworkError = true;
                    doneOne();
                };
                xhr.send();
            })(entityFilter[i]);
        }
    }

    function fetchViaHassCli() {
        var entityFilter = configuredEntities();
        if (!hassCliCommand) {
            setErrorState("hass-cli command is empty");
            return;
        }
        if (entityFilter.length === 0) {
            entitiesModel.clear();
            setErrorState("No entities configured. Add entity IDs in widget settings.");
            return;
        }
        busy = true;
        executableSource.connectSource(hassCliCommand);
    }

    function refresh() {
        if (useHassCli)
            fetchViaHassCli();
        else
            fetchViaApi();
    }

    function callService(entityId, service) {
        if (!baseUrl || !token) {
            setErrorState("Configure URL and token in widget settings");
            return;
        }
        var domain = domainOf(entityId);
        var xhr = new XMLHttpRequest();
        xhr.open("POST", baseUrl + "/api/services/" + domain + "/" + service);
        xhr.setRequestHeader("Authorization", "Bearer " + token);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ entity_id: entityId }));
    }

    function callServiceWithData(entityId, service, data) {
        if (!baseUrl || !token) {
            setErrorState("Configure URL and token in widget settings");
            return;
        }
        var domain = domainOf(entityId);
        var xhr = new XMLHttpRequest();
        xhr.open("POST", baseUrl + "/api/services/" + domain + "/" + service);
        xhr.setRequestHeader("Authorization", "Bearer " + token);
        xhr.setRequestHeader("Content-Type", "application/json");
        var payload = { entity_id: entityId };
        for (var k in data)
            payload[k] = data[k];
        xhr.send(JSON.stringify(payload));
    }

    function toggleEntity(entityId, currentState) {
        var domain = domainOf(entityId);
        if (domain === "light" || domain === "switch" || domain === "input_boolean" || domain === "fan")
            callService(entityId, "toggle");
        else if (domain === "script")
            callService(entityId, "turn_on");
        else if (domain === "button")
            callService(entityId, "press");
        else if (domain === "automation")
            callService(entityId, "trigger");
        else if (domain === "scene")
            callService(entityId, "turn_on");
        else if (currentState === "on")
            callService(entityId, "turn_off");
        else
            callService(entityId, "turn_on");
        Qt.callLater(refresh);
    }

    // ── History fetch for sensor sparklines ─────────────────────

    function fetchAllHistory() {
        if (!baseUrl || !token) return;
        for (var i = 0; i < entitiesModel.count; ++i) {
            var entry = entitiesModel.get(i);
            if (entry.numericState && (entry.domain === "sensor" || entry.domain === "weather"))
                fetchHistory(entry.entityId, i);
        }
    }

    function fetchHistory(entityId, modelIndex) {
        var now = new Date();
        var start = new Date(now.getTime() - 24 * 60 * 60 * 1000);
        var url = baseUrl + "/api/history/period/" + start.toISOString()
            + "?filter_entity_id=" + encodeURIComponent(entityId)
            + "&minimal_response&no_attributes"
            + "&end_time=" + encodeURIComponent(now.toISOString());

        var xhr = new XMLHttpRequest();
        xhr.open("GET", url);
        xhr.timeout = 15000;
        xhr.setRequestHeader("Authorization", "Bearer " + token);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return;
            if (xhr.status >= 200 && xhr.status < 300) {
                try {
                    var parsed = JSON.parse(xhr.responseText);
                    if (Array.isArray(parsed) && parsed.length > 0 && Array.isArray(parsed[0])) {
                        var points = [];
                        for (var j = 0; j < parsed[0].length; ++j) {
                            var val = parseFloat(parsed[0][j].state);
                            if (!isNaN(val))
                                points.push(val);
                        }
                        if (modelIndex < entitiesModel.count
                            && entitiesModel.get(modelIndex).entityId === entityId) {
                            entitiesModel.setProperty(modelIndex, "history", JSON.stringify(points));
                        }
                    }
                } catch (e) { /* ignore parse errors */ }
            }
        };
        xhr.send();
    }

    // ── Data sources ───────────────────────────────────────────

    P5Support.DataSource {
        id: executableSource
        engine: "executable"
        connectedSources: []
        onNewData: function (sourceName, data) {
            busy = false;
            disconnectSource(sourceName);

            var code = Number(data["exit code"] || 1);
            if (code !== 0) {
                setErrorState("hass-cli failed (exit " + code + ")");
                return;
            }
            var stdout = String(data.stdout || "[]");
            try {
                var parsed = JSON.parse(stdout);
                if (!Array.isArray(parsed)) {
                    setErrorState("hass-cli output was not a JSON array");
                    return;
                }
                var filtered = filterEntities(parsed);
                reloadModelFromArray(filtered);
            } catch (e) {
                setErrorState("Failed to parse hass-cli JSON");
            }
        }
    }

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        statusText = "Starting sync...";
        refresh();
    }

    Plasmoid.status: PlasmaCore.Types.PassiveStatus
    Plasmoid.icon: "go-home"
    toolTipMainText: "Home Assistant"
    toolTipSubText: statusText

    // ── Compact representation ─────────────────────────────────

    compactRepresentation: MouseArea {
        implicitWidth: Kirigami.Units.iconSizes.medium
        implicitHeight: implicitWidth
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: "go-home"
        }
    }

    // ── Full representation ────────────────────────────────────

    fullRepresentation: Item {
        implicitWidth: root.switchWidth
        implicitHeight: root.switchHeight

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // Header bar — compact single row
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: "go-home"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }

                PC3.Label {
                    text: "Home Assistant"
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                // Status dot
                Rectangle {
                    width: Kirigami.Units.smallSpacing * 2
                    height: width
                    radius: width / 2
                    color: online ? "#4CAF50" : "#EF5350"
                }

                PC3.ToolButton {
                    icon.name: "view-refresh"
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2
                    implicitHeight: implicitWidth
                    enabled: !busy
                    onClicked: root.refresh()
                    PC3.ToolTip { text: statusText }
                }
                PC3.ToolButton {
                    icon.name: "configure"
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2
                    implicitHeight: implicitWidth
                    onClicked: Plasmoid.internalAction("configure").trigger()
                    PC3.ToolTip { text: "Settings" }
                }
            }

            // Entity grid
            GridView {
                id: grid
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: entitiesModel

                readonly property int columns: Math.max(1, Math.floor(width / (Kirigami.Units.gridUnit * 9)))
                cellWidth: width / columns
                cellHeight: Kirigami.Units.gridUnit * 7
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                    width: grid.cellWidth
                    height: grid.cellHeight

                    Rectangle {
                        id: cardBg
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing / 2
                        radius: 8
                        color: Kirigami.Theme.alternateBackgroundColor
                        border.width: 1
                        border.color: Kirigami.Theme.separatorColor
                        clip: true
                    }

                    // All content anchored inside the card
                    ColumnLayout {
                        anchors {
                            fill: cardBg
                            leftMargin: Kirigami.Units.smallSpacing * 2
                            rightMargin: Kirigami.Units.smallSpacing * 2
                            topMargin: Kirigami.Units.smallSpacing
                            bottomMargin: Kirigami.Units.smallSpacing
                        }
                        spacing: 1

                        // Row 1: name + state dot
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            // Colored state dot
                            Rectangle {
                                width: Kirigami.Units.smallSpacing * 2
                                height: width
                                radius: width / 2
                                color: model.color
                                Layout.alignment: Qt.AlignVCenter
                            }

                            PC3.Label {
                                Layout.fillWidth: true
                                text: model.name
                                font.bold: true
                                font.pointSize: Kirigami.Theme.defaultFont.pointSize
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // Row 2: state text (small)
                        PC3.Label {
                            Layout.fillWidth: true
                            text: {
                                var s = model.state;
                                // Scenes store last-activated ISO timestamp as state — show friendly text
                                if (model.domain === "scene") {
                                    if (/^\d{4}-\d{2}-\d{2}T/.test(s)) {
                                        var d = new Date(s);
                                        if (!isNaN(d.getTime()))
                                            return "Activated " + d.toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"});
                                    }
                                    return "Scene";
                                }
                                if (model.unit)
                                    s += " " + model.unit;
                                return s;
                            }
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            color: Kirigami.Theme.disabledTextColor
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }

                        Item { Layout.fillHeight: true }

                        // Row 3: domain-specific control
                        Loader {
                            id: controlLoader
                            Layout.fillWidth: true
                            Layout.maximumHeight: Kirigami.Units.gridUnit * 3

                            onItemChanged: {
                                if (item)
                                    item.width = Qt.binding(function() { return controlLoader.width; });
                            }

                            sourceComponent: {
                                var d = model.domain;
                                if (d === "light" && model.brightness >= 0)
                                    return lightSliderComponent;
                                if (d === "cover" && model.position >= 0)
                                    return coverSliderComponent;
                                if (d === "fan" && model.percentage >= 0)
                                    return fanSliderComponent;
                                if (d === "input_number")
                                    return inputNumberSliderComponent;
                                if (model.numericState && (d === "sensor" || d === "weather"))
                                    return sparklineComponent;
                                if (d === "sensor" || d === "binary_sensor" || d === "weather")
                                    return readonlyComponent;
                                if (d === "switch" || d === "input_boolean" || d === "light")
                                    return toggleSwitchComponent;
                                if (d === "script" || d === "button" || d === "automation" || d === "scene")
                                    return actionButtonComponent;
                                return fallbackToggleComponent;
                            }

                            property string _entityId: model.entityId
                            property string _state: model.state
                            property string _domain: model.domain
                            property int _brightness: model.brightness
                            property int _position: model.position
                            property int _percentage: model.percentage
                            property real _attrMin: model.attrMin
                            property real _attrMax: model.attrMax
                            property real _attrStep: model.attrStep
                            property string _unit: model.unit
                            property string _history: model.history
                        }
                    }
                }

                QQC2.Label {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 2
                    visible: entitiesModel.count === 0
                    text: online
                        ? (busy ? "Syncing entities..." : "No entities found for configured IDs.")
                        : statusText
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }
    }

    // ── Domain-specific delegate components ─────────────────────

    // Light with brightness slider
    Component {
        id: lightSliderComponent

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PC3.Switch {
                checked: _state === "on"
                onToggled: root.toggleEntity(_entityId, _state)
            }

            PC3.Slider {
                Layout.fillWidth: true
                from: 0; to: 255; stepSize: 1
                value: Math.max(0, _brightness)
                live: false
                onMoved: {
                    root.callServiceWithData(_entityId, "turn_on", { brightness: Math.round(value) });
                    Qt.callLater(root.refresh);
                }
            }

            PC3.Label {
                text: (_brightness >= 0 ? Math.round(_brightness / 255 * 100) : 0) + "%"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                horizontalAlignment: Text.AlignRight
            }
        }
    }

    // Cover with position slider
    Component {
        id: coverSliderComponent

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PC3.Slider {
                Layout.fillWidth: true
                from: 0; to: 100; stepSize: 1
                value: Math.max(0, _position)
                live: false
                onMoved: {
                    root.callServiceWithData(_entityId, "set_cover_position", { position: Math.round(value) });
                    Qt.callLater(root.refresh);
                }
            }

            PC3.Label {
                text: (_position >= 0 ? _position : 0) + "%"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                horizontalAlignment: Text.AlignRight
            }
        }
    }

    // Fan with percentage slider
    Component {
        id: fanSliderComponent

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PC3.Switch {
                checked: _state === "on"
                onToggled: root.toggleEntity(_entityId, _state)
            }

            PC3.Slider {
                Layout.fillWidth: true
                from: 0; to: 100; stepSize: 1
                value: Math.max(0, _percentage)
                live: false
                onMoved: {
                    root.callServiceWithData(_entityId, "set_percentage", { percentage: Math.round(value) });
                    Qt.callLater(root.refresh);
                }
            }

            PC3.Label {
                text: (_percentage >= 0 ? _percentage : 0) + "%"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                horizontalAlignment: Text.AlignRight
            }
        }
    }

    // input_number with configurable range slider
    Component {
        id: inputNumberSliderComponent

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PC3.Slider {
                Layout.fillWidth: true
                from: _attrMin; to: _attrMax; stepSize: _attrStep
                value: {
                    var v = parseFloat(_state);
                    return isNaN(v) ? _attrMin : v;
                }
                live: false
                onMoved: {
                    root.callServiceWithData(_entityId, "set_value", { value: value });
                    Qt.callLater(root.refresh);
                }
            }

            PC3.Label {
                text: _state + (_unit ? " " + _unit : "")
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2.5
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
            }
        }
    }

    // Numeric sensor sparkline — compact
    Component {
        id: sparklineComponent

        Canvas {
            implicitHeight: Kirigami.Units.gridUnit * 2

            property string historyData: _history

            onHistoryDataChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);

                var points;
                try { points = JSON.parse(historyData); } catch (e) { return; }
                if (!Array.isArray(points) || points.length < 2)
                    return;

                var minVal = points[0], maxVal = points[0];
                for (var i = 1; i < points.length; ++i) {
                    if (points[i] < minVal) minVal = points[i];
                    if (points[i] > maxVal) maxVal = points[i];
                }
                var range = maxVal - minVal;
                if (range === 0) range = 1;

                var padY = 2;
                var usableH = height - padY * 2;
                var stepX = width / (points.length - 1);

                var gradient = ctx.createLinearGradient(0, 0, 0, height);
                gradient.addColorStop(0, Qt.rgba(0.01, 0.66, 0.96, 0.25));
                gradient.addColorStop(1, Qt.rgba(0.01, 0.66, 0.96, 0.02));

                ctx.beginPath();
                var firstY = padY + usableH - ((points[0] - minVal) / range) * usableH;
                ctx.moveTo(0, firstY);
                for (var j = 1; j < points.length; ++j) {
                    var y = padY + usableH - ((points[j] - minVal) / range) * usableH;
                    ctx.lineTo(j * stepX, y);
                }
                ctx.lineTo((points.length - 1) * stepX, height);
                ctx.lineTo(0, height);
                ctx.closePath();
                ctx.fillStyle = gradient;
                ctx.fill();

                ctx.beginPath();
                ctx.moveTo(0, firstY);
                for (var k = 1; k < points.length; ++k) {
                    var ly = padY + usableH - ((points[k] - minVal) / range) * usableH;
                    ctx.lineTo(k * stepX, ly);
                }
                ctx.strokeStyle = "#03A9F4";
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }
        }
    }

    // Read-only text sensor (non-numeric states like "Not Charging")
    Component {
        id: readonlyComponent

        Item {
            implicitHeight: 1
        }
    }

    // Toggle switch for switch/input_boolean/light (without brightness)
    Component {
        id: toggleSwitchComponent

        Item {
            implicitHeight: toggleSwitch.implicitHeight

            PC3.Switch {
                id: toggleSwitch
                anchors.right: parent.right
                checked: _state === "on"
                onToggled: root.toggleEntity(_entityId, _state)
            }
        }
    }

    // Action button for script/button/automation
    Component {
        id: actionButtonComponent

        Item {
            implicitHeight: actionBtn.implicitHeight

            PC3.ToolButton {
                id: actionBtn
                anchors.right: parent.right
                icon.name: {
                    if (_domain === "script") return "media-playback-start";
                    if (_domain === "automation") return "system-run";
                    if (_domain === "scene") return "media-playback-start";
                    return "media-playback-start";
                }
                enabled: !root.busy
                onClicked: root.toggleEntity(_entityId, _state)
                PC3.ToolTip { text: _domain === "automation" ? "Trigger" : (_domain === "scene" ? "Activate" : "Run") }
            }
        }
    }

    // Fallback toggle
    Component {
        id: fallbackToggleComponent

        Item {
            implicitHeight: fallbackSwitch.implicitHeight

            PC3.Switch {
                id: fallbackSwitch
                anchors.right: parent.right
                checked: _state === "on"
                onToggled: root.toggleEntity(_entityId, _state)
                enabled: !root.busy
            }
        }
    }
}
