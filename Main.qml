pragma ComponentBehavior: Bound

import QtQuick
// import QtCore
// import QtCore.Private
// import Quickshell

import Quickshell.Io

import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // plugin settings
    property var settings: ({
            caldavURL: pluginData.caldavURL,
            caldavUsername: pluginData.caldavUsername,
            caldavPassword: pluginData.caldavPassword,
            caldavCalendar: pluginData.caldavCalendar,
            caldavCalendars: pluginData.caldavCalendars ? pluginData.caldavCalendars.split(",").map(s => s.trim()) : [pluginData.caldavCalendar],
            refreshInterval: isNaN(Number(pluginData.refreshInterval)) ? 60 : Number(pluginData.refreshInterval) // default to 1 minute
        })

    // data loading
    property var tasksData

    property bool loading: true

    property bool loadDataProcessError: false
    property string loadDataProcessOutput: ""
    property var loadDataTimestamp: 0

    property bool toggleCompleteProcessError: false
    property string toggleCompleteProcessOutput: ""

    // misc.
    property string currentDirectory: {
        return Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "");
    }

    // calander's to filter

    property var calendarFilter: []
    property var calendarFilterInactive: []

    function toggleCalendarFilter(calendar) {
        if (calendar == root.settings.caldavCalendar) {
            root.showToastError("Cannot disable main calendar filter!");
            return;
        }

        if (root.calendarFilter.includes(calendar)) {
            root.calendarFilter = root.calendarFilter.filter(c => c !== calendar);
            root.calendarFilterInactive = root.calendarFilterInactive.concat([calendar]);
        } else {
            root.calendarFilterInactive = root.calendarFilterInactive.filter(c => c !== calendar);
            root.calendarFilter = root.calendarFilter.concat([calendar]);
        }

        pluginService.savePluginData(root.pluginId, 'calendarFilter', root.calendarFilter);
        pluginService.savePluginData(root.pluginId, 'calendarFilterInactive', root.calendarFilterInactive);

        root.loadData();
    }

    function showToastError(message) {
        ToastService.showError("Tasks Plugin: " + message);
    }

    // loadSettings
    function loadSettings() {
        if (!pluginData) {
            root.showToastError("Failed to load plugin settings!");
            return;
        }

        if (!pluginData.caldavURL || !pluginData.caldavUsername || !pluginData.caldavPassword || !pluginData.caldavCalendar || isNaN(Number(pluginData.refreshInterval)) || Number(pluginData.refreshInterval) <= 0) {
            root.showToastError("Please fill in all required settings!");
            return;
        }

        root.settings = {
            caldavURL: pluginData.caldavURL,
            caldavUsername: pluginData.caldavUsername,
            caldavPassword: pluginData.caldavPassword,
            caldavCalendar: pluginData.caldavCalendar,
            caldavCalendars: pluginData.caldavCalendars ? pluginData.caldavCalendars.split(",").map(s => s.trim()) : [pluginData.caldavCalendar],
            refreshInterval: isNaN(Number(pluginData.refreshInterval)) ? 60 : Number(pluginData.refreshInterval) // default to 1 minute
        };

        root.calendarFilter = pluginService.loadPluginData(root.pluginId, 'calendarFilter') || [pluginData.caldavCalendar];
        root.calendarFilterInactive = pluginService.loadPluginData(root.pluginId, 'calendarFilterInactive') || [pluginData.caldavCalendars];
    }

    Process {
        id: loadDataProcess

        stdout: SplitParser {
            onRead: data => {
                root.loadDataProcessOutput += data + "\n";
            }
        }
        onStarted: () => {
            root.loading = true;
            root.loadDataProcessError = false;
            root.loadDataProcessOutput = "";

            loadDataProcess.running = true;
        }
        onExited: () => {
            try {
                var json = JSON.parse(root.loadDataProcessOutput.trim());

                if (json && json.success) {
                    root.tasksData = json.data || {};
                    root.loading = false;
                    root.loadDataTimestamp = Date.now();
                } else {
                    throw new Error(json && json.message ? json.message : "Failed to load tasks data!");
                }
            } catch (e) {
                console.log("JSON parse error:", e);
                console.log("Raw output:", root.loadDataProcessOutput);

                root.showToastError(e.message);

                root.loadDataProcessError = true;
            }

            loadDataProcess.running = false;
        }
    }

    function loadData() {
        if (loadDataProcess.running) {
            return;
        }

        loadDataProcess.command = ["python3", root.currentDirectory + "main.py", "load", root.settings.caldavURL, root.settings.caldavUsername, root.settings.caldavPassword, root.calendarFilter.join(","), "0"];
        loadDataProcess.running = true;
    }

    Timer {
        id: refreshTimer
        interval: root.settings.refreshInterval * 1000
        running: false
        repeat: true
        onTriggered: {
            root.loadSettings();
            root.loadData();
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => {
            root.loadSettings();
            root.loadData();
            refreshTimer.running = true;
        });
    }

    Process {
        id: toggleCompleteProcess

        stdout: SplitParser {
            onRead: data => {
                root.toggleCompleteProcessOutput += data + "\n";
            }
        }
        onStarted: () => {
            root.loading = true;
            root.toggleCompleteProcessError = false;
            root.toggleCompleteProcessOutput = "";

            toggleCompleteProcess.running = true;
        }
        onExited: () => {
            try {
                var json = JSON.parse(root.toggleCompleteProcessOutput.trim());

                if (json && json.success) {
                    root.loadData();
                } else {
                    throw new Error(json && json.message ? json.message : "Failed to toggle task completion!");
                }
            } catch (e) {
                console.log("JSON parse error:", e);
                console.log("Raw output:", root.toggleCompleteProcessOutput);
                root.showToastError(e.message);
            }

            toggleCompleteProcess.running = false;
        }
    }

    function toggleComplete(task) {
        if (!task || !task.uid) {
            root.showToastError("Unable to update task: missing UID");
            return;
        }

        if (toggleCompleteProcess.running) {
            return;
        }

        toggleCompleteProcess.command = ["python3", root.currentDirectory + "main.py", "toggle_complete", root.settings.caldavURL, root.settings.caldavUsername, root.settings.caldavPassword, task.calendar, task.uid, "0"];
        toggleCompleteProcess.running = true;
    }

    horizontalBarPill: Component {
        Row {
            padding: Theme.spacingXS

            // current task
            StyledText {
                visible: !root.loading && root.tasksData != null && root.tasksData.currentTask != null
                text: root.tasksData != null && root.tasksData.currentTask != null ? ((root.tasksData.completeCount / root.tasksData.totalCount) * 100).toFixed(0) + "% - " + Qt.formatDateTime(root.tasksData.currentTask.due, "hh:mm") + " : " + root.tasksData.currentTask.summary : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            // loading text
            StyledText {
                visible: root.loading
                text: "Loading..."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: !root.loading && root.tasksData && root.tasksData.tasks ? root.tasksData.tasks.length <= 0 : false
                text: "Nothing to do..."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "task_alt"
                size: Theme.fontSizeMedium
                color: Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn

            headerText: "Tasks"
            detailsText: "Your upcoming tasks"
            showCloseButton: true

            Row {
                height: popoutColumn.detailsHeight
                width: parent.width - Theme.spacingS

                Row {
                    visible: !root.loading && root.calendarFilter && root.calendarFilter.length > 0
                    width: parent.width - (Theme.spacingS * 2)
                    spacing: Theme.spacingXS
                    anchors.left: parent.left
                    padding: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                        id: calendarFilterRepeater
                        model: root.calendarFilter.concat(root.calendarFilterInactive)

                        StyledRect {
                            id: calendarPill
                            width: calendarPillText.width + (Theme.spacingS * 2)
                            height: 20
                            color: active ? Theme.surfaceVariantText : "transparent"
                            border.width: 1
                            border.color: active ? "transparent" : Theme.surfaceVariantText
                            radius: Theme.cornerRadius

                            required property var modelData

                            property bool active: root.calendarFilter.includes(modelData)

                            StyledText {
                                id: calendarPillText
                                height: 20
                                text: calendarPill.modelData
                                font.pixelSize: Theme.fontSizeSmall
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.verticalCenter: parent.verticalCenter
                                color: calendarPill.active ? Theme.onPrimary : Theme.surfaceVariantText

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.toggleCalendarFilter(calendarPill.modelData);
                                    }
                                }
                            }
                        }
                    }
                }

                StyledText {
                    id: refreshTimestampText
                    text: "Updated: " + Qt.formatDateTime(new Date(root.loadDataTimestamp), "hh:mm")
                    font.pixelSize: Theme.fontSizeSmall * 0.8
                    font.family: "monospace"
                    color: Theme.surfaceVariantText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - popoutColumn.headerHeight - popoutColumn.detailsHeight - Theme.spacingXL

                // loading text
                StyledText {
                    visible: root.loading
                    text: "Loading..."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // no tasks text
                StyledText {
                    visible: !root.loading && root.tasksData && root.tasksData.tasks ? root.tasksData.tasks.length <= 0 : false
                    text: "Nothing to do..."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // scrollable tasks list
                Flickable {
                    visible: !root.loading && root.tasksData && root.tasksData.tasks ? root.tasksData.tasks.length > 0 : false
                    anchors.fill: parent
                    contentWidth: parent.width
                    contentHeight: tasksGroupColumn.height
                    clip: true

                    // main column
                    Column {
                        id: tasksGroupColumn
                        width: parent.width
                        padding: Theme.spacingS
                        spacing: Theme.spacingM

                        // group tasks by due date
                        Repeater {
                            model: root.tasksData.tasks

                            // column for each group
                            Column {
                                id: taskColumn
                                required property var modelData
                                width: parent.width
                                spacing: Theme.spacingS

                                property var groupTasks: modelData

                                // group header with due date
                                StyledText {
                                    width: parent.width
                                    visible: taskColumn.groupTasks.length > 0
                                    text: Qt.formatDateTime(taskColumn.groupTasks[0].due, "ddd, MMM d")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                Repeater {
                                    model: taskColumn.groupTasks

                                    Row {
                                        id: taskRow
                                        required property var modelData
                                        width: tasksGroupColumn.width
                                        height: Theme.fontSizeSmall * 1.1
                                        spacing: Theme.spacingXS

                                        StyledText {
                                            text: taskRow.modelData.summary
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            width: parent.width - detailsRow.width - Theme.spacingXL
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        // task details
                                        Row {
                                            id: detailsRow
                                            spacing: Theme.spacingS
                                            height: parent.height

                                            StyledText {
                                                id: priorityText
                                                text: taskRow.modelData.priority.toString()
                                                font.pixelSize: Theme.fontSizeSmall * 0.8
                                                font.family: "monospace"
                                                color: if (taskRow.modelData.priority == 0)
                                                    Theme.surfaceVariantText
                                                else if (taskRow.modelData.priority == 1)
                                                    '#ff7066'
                                                else if (taskRow.modelData.priority <= 5)
                                                    "#ffb95b"
                                                else if (taskRow.modelData.priority <= 9)
                                                    "#86b7ff"
                                                else
                                                    Theme.surfaceVariantText
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            StyledText {
                                                id: timestampText
                                                text: taskRow.modelData.allDay ? "XX:XX" : Qt.formatDateTime(new Date(taskRow.modelData.due), "hh:mm")
                                                font.pixelSize: Theme.fontSizeSmall * 0.8
                                                font.family: "monospace"
                                                color: Theme.surfaceVariantText
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            // checkbox
                                            StyledRect {
                                                visible: true
                                                width: 10
                                                height: width
                                                radius: 1
                                                color: "transparent"
                                                border.width: 1
                                                border.color: Theme.surfaceVariantText
                                                anchors.verticalCenter: parent.verticalCenter

                                                property bool checked: taskRow.modelData.completed

                                                DankIcon {
                                                    anchors.fill: parent
                                                    anchors.margins: 0
                                                    name: "close"
                                                    size: parent.width
                                                    color: Theme.primary
                                                    visible: parent.checked
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    enabled: !root.loading && !toggleCompleteProcess.running
                                                    onClicked: {
                                                        root.toggleComplete(taskRow.modelData);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 340
    popoutHeight: 400
}
