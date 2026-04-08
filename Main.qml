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
            shiftDueTimeDelta: isNaN(Number(pluginData.shiftDueTimeDelta)) ? 15 : Number(pluginData.shiftDueTimeDelta) // default to 15 minutes
            ,
            refreshInterval: isNaN(Number(pluginData.refreshInterval)) ? 1 : Number(pluginData.refreshInterval) // default to 1 minute
        })

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
            shiftDueTimeDelta: isNaN(Number(pluginData.shiftDueTimeDelta)) ? 15 : Number(pluginData.shiftDueTimeDelta) // default to 15 minutes
            ,
            refreshInterval: isNaN(Number(pluginData.refreshInterval)) ? 1 : Number(pluginData.refreshInterval) // default to 1 minute
        };

        root.totalCalendarCount = root.settings.caldavCalendars.length + 1;

        root.tasksData = pluginService.loadPluginData(root.pluginId, 'tasksData') || {};
        root.calendarFilter = pluginService.loadPluginData(root.pluginId, 'calendarFilter') || [pluginData.caldavCalendar];
        root.calendarFilterInactive = pluginService.loadPluginData(root.pluginId, 'calendarFilterInactive') || [];

        if (root.totalCalendarCount != root.settings.caldavCalendars.length + 1) {
            root.calendarFilter = [root.settings.caldavCalendar];
            root.calendarFilterInactive = root.settings.caldavCalendars;
        }
    }

    // data loading
    property var tasksData
    property bool loading: false
    property var loadDataTimestamp: 0

    // misc.
    property string currentDirectory: {
        return Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "");
    }

    // calander's to filter
    property int totalCalendarCount: 0
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

    Process {
        id: loadDataProcess

        property string output: ""

        stdout: SplitParser {
            onRead: data => {
                loadDataProcess.output += data + "\n";
            }
        }
        onStarted: () => {
            root.loading = true;
            loadDataProcess.output = "";
            loadDataProcess.running = true;
        }
        onExited: () => {
            try {
                var json = JSON.parse(loadDataProcess.output.trim());

                if (json && json.success) {
                    root.tasksData = json.data || {};
                    root.loadDataTimestamp = Date.now();

                    PluginService.savePluginData(root.pluginId, 'tasksData', {});
                    PluginService.savePluginData(root.pluginId, 'tasksData', root.tasksData);
                } else {
                    throw new Error(json && json.message ? json.message : "Failed to load tasks data!");
                }
            } catch (e) {
                console.log("JSON parse error:", e);
                console.log("Raw output:", loadDataProcess.output);

                root.showToastError(e.message);
            }

            root.loading = false;
            loadDataProcess.running = false;
        }
    }

    function loadData() {
        if (loadDataProcess.running || root.loading) {
            return;
        }

        loadDataProcess.command = ["python3", root.currentDirectory + "main.py", "load", root.settings.caldavURL, root.settings.caldavUsername, root.settings.caldavPassword, root.calendarFilter.join(","), "0"];
        loadDataProcess.running = true;
    }

    Timer {
        id: refreshTimer
        interval: root.settings.refreshInterval * 10000
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

        property string output: ""

        stdout: SplitParser {
            onRead: data => {
                toggleCompleteProcess.output += data + "\n";
            }
        }

        onStarted: () => {
            root.loading = true;
            toggleCompleteProcess.output = "";
            toggleCompleteProcess.running = true;
        }

        onExited: () => {
            try {
                var json = JSON.parse(toggleCompleteProcess.output.trim());

                if (!json.success) {
                    throw new Error(json && json.message ? json.message : "Failed to toggle task completion!");
                }
            } catch (e) {
                console.log("JSON parse error:", e);
                console.log("Raw output:", toggleCompleteProcess.output);
                root.showToastError(e.message);
            }

            root.loading = false;
            toggleCompleteProcess.running = false;
        }
    }

    function toggleComplete(task) {
        if (!task || !task.uid) {
            return;
        }

        if (toggleCompleteProcess.running || root.loading) {
            return;
        }

        toggleCompleteProcess.command = ["python3", root.currentDirectory + "main.py", "toggle_complete", root.settings.caldavURL, root.settings.caldavUsername, root.settings.caldavPassword, task.calendar, task.uid, "0"];
        toggleCompleteProcess.running = true;
    }

    Process {
        id: shiftDueTimeProcess

        property string output: ""
        property bool error: false

        stdout: SplitParser {
            onRead: data => {
                shiftDueTimeProcess.output += data + "\n";
            }
        }

        onStarted: () => {
            root.loading = true;
            shiftDueTimeProcess.output = "";
            shiftDueTimeProcess.running = true;
        }

        onExited: () => {
            try {
                var json = JSON.parse(shiftDueTimeProcess.output.trim());

                if (!json.success) {
                    throw new Error(json && json.message ? json.message : "Failed to shift task due time!");
                }
            } catch (e) {
                console.log("JSON parse error:", e);
                console.log("Raw output:", shiftDueTimeProcess.output);
                root.showToastError(e.message);
            }

            root.loading = false;
            shiftDueTimeProcess.running = false;
        }
    }

    function shiftTaskDueTime(task, forward = false) {
        if (!task || !task.uid) {
            root.showToastError("Unable to update task: missing UID");
            return;
        }

        if (shiftDueTimeProcess.running || root.loading) {
            return;
        }

        shiftDueTimeProcess.command = ["python3", root.currentDirectory + "main.py", "shift_due_timestamp", root.settings.caldavURL, root.settings.caldavUsername, root.settings.caldavPassword, task.calendar, task.uid, root.settings.shiftDueTimeDelta, forward ? "1" : "0", "0"];
        shiftDueTimeProcess.running = true;
    }

    horizontalBarPill: Component {
        Row {
            padding: Theme.spacingXS

            // current task
            StyledText {
                visible: root.tasksData != null && root.tasksData.currentTask != null
                text: root.tasksData != null && root.tasksData.currentTask != null ? ((root.tasksData.completeCount / root.tasksData.totalCount) * 100).toFixed(0) + "% - " + Qt.formatDateTime(root.tasksData.currentTask.due, "hh:mm") + " : " + root.tasksData.currentTask.summary : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.tasksData && root.tasksData.tasks ? root.tasksData.tasks.length <= 0 : false
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
                    id: calendarFilterRow
                    visible: root.calendarFilter && root.calendarFilter.length > 0
                    width: parent.width - (Theme.spacingS * 2) - refreshRow.width
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
                                text: root.totalCalendarCount >= 4 ? calendarPill.modelData.substring(0, 3).toUpperCase() : calendarPill.modelData
                                font.pixelSize: Theme.fontSizeSmall
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.verticalCenter: parent.verticalCenter
                                color: calendarPill.active ? Theme.onPrimary : Theme.surfaceVariantText

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        calendarPill.active = !calendarPill.active;
                                        root.toggleCalendarFilter(calendarPill.modelData);
                                    }
                                    cursorShape: enabled || !root.loading ? Qt.PointingHandCursor : Qt.ArrowCursor
                                }
                            }
                        }
                    }
                }

                Row {
                    id: refreshRow
                    width: refreshTimestampText.width + 10 + Theme.spacingS
                    height: parent.height
                    spacing: Theme.spacingS
                    anchors.right: parent.right
                    // anchors.verticalCenter: parent.verticalCenter

                    StyledText {
                        id: refreshTimestampText
                        text: Qt.formatDateTime(new Date(root.loadDataTimestamp), "hh:mm:ss ~ ") + root.settings.refreshInterval + "m"
                        font.pixelSize: Theme.fontSizeSmall * 0.8
                        font.family: "monospace"
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        width: refreshIcon.width
                        height: width
                        color: "transparent"
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            id: refreshIcon
                            name: "refresh"
                            size: Theme.fontSizeSmall
                            color: Theme.primary

                            MouseArea {
                                anchors.fill: parent
                                enabled: !root.loading && !toggleCompleteProcess.running
                                onClicked: {
                                    root.loadSettings();
                                    root.loadData();
                                }
                                cursorShape: enabled || !root.loading ? Qt.PointingHandCursor : Qt.ArrowCursor
                            }
                        }
                    }
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - popoutColumn.headerHeight - popoutColumn.detailsHeight - Theme.spacingXL

                // no tasks text
                StyledText {
                    visible: root.tasksData && root.tasksData.tasks ? root.tasksData.tasks.length <= 0 : false
                    text: "Nothing to do..."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // scrollable tasks list
                Flickable {
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
                                        width: tasksGroupColumn.width
                                        height: Theme.fontSizeSmall * 1.1
                                        spacing: Theme.spacingXS

                                        required property var modelData

                                        StyledText {
                                            text: taskRow.modelData.summary
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            width: parent.width - detailsRow.width - Theme.spacingL - Theme.spacingXS
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

                                            // due time with shift buttons
                                            Row {
                                                id: timestampRow
                                                padding: Theme.spacingXS
                                                spacing: Theme.spacingS
                                                height: parent.height

                                                StyledText {
                                                    id: timestampShiftDown
                                                    text: '-'
                                                    font.pixelSize: Theme.fontSizeSmall * 0.8
                                                    font.family: "monospace"
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        enabled: !root.loading && !shiftDueTimeProcess.running
                                                        onClicked: {
                                                            root.shiftTaskDueTime(taskRow.modelData, false);
                                                            root.loadData();
                                                        }
                                                        cursorShape: enabled || !root.loading ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                    }
                                                }

                                                StyledText {
                                                    id: timestampText
                                                    text: taskRow.modelData.allDay ? "XX:XX" : Qt.formatDateTime(new Date(taskRow.modelData.due), "hh:mm")
                                                    font.pixelSize: Theme.fontSizeSmall * 0.8
                                                    font.family: "monospace"
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }

                                                StyledText {
                                                    id: timestampShiftUp
                                                    text: '+'
                                                    font.pixelSize: Theme.fontSizeSmall * 0.8
                                                    font.family: "monospace"
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        enabled: !root.loading && !shiftDueTimeProcess.running
                                                        onClicked: {
                                                            root.shiftTaskDueTime(taskRow.modelData, true);
                                                            root.loadData();
                                                        }
                                                        cursorShape: enabled || !root.loading ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                    }
                                                }
                                            }

                                            // checkbox
                                            StyledRect {
                                                id: checkbox
                                                width: 10
                                                height: width
                                                radius: 1
                                                // color: completed ? Theme.surfaceVariantText : "transparent"
                                                color: "transparent"
                                                border.width: 1
                                                // border.color: completed ? Theme.success : Theme.error
                                                border.color: Theme.surfaceVariantText
                                                anchors.verticalCenter: parent.verticalCenter

                                                property bool completed: taskRow.modelData.completed

                                                DankIcon {
                                                    id: checkmark
                                                    anchors.fill: parent
                                                    anchors.margins: 0
                                                    name: "check"
                                                    size: parent.width * 0.8
                                                    color: parent.border.color
                                                    visible: checkbox.completed
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    enabled: !root.loading && !toggleCompleteProcess.running
                                                    onClicked: {
                                                        checkbox.completed = !checkbox.completed;
                                                        root.toggleComplete(taskRow.modelData);
                                                        root.loadData();
                                                    }
                                                    cursorShape: enabled || !root.loading ? Qt.PointingHandCursor : Qt.ArrowCursor
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
