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

import "."

PluginComponent {
    id: root

    function logError() {
        var argumentsArray = Array.from(arguments);

        var toast = argumentsArray.pop(-1);
        var message = argumentsArray.join(" ");

        console.error('pluginId > ' + root.pluginId + ': ' + message);
        if (toast)
            ToastService.showError("Tasks: " + message);
    }

    function getPriorityColor(priority) {
        if (priority <= 0)
            return Theme.surfaceVariantText;
        else if (priority == 1)
            return '#ff7066';
        else if (priority <= 5)
            return "#ffb95b";
        else if (priority <= 9)
            return "#86b7ff";
        else
            return Theme.surfaceVariantText;
    }

    // plugin settings
    property var settings: ({})

    // constants
    property var constants: {
        caldavCreds: [];
        helper: [];
    }

    property bool initzialized: false

    property FileView dataFile: FileView {
        id: dataFile
        path: ""
        blockWrites: true
        atomicWrites: true

        onLoaded: {
            try {
                var data = JSON.parse(text());
                var currentVersion = root.pluginService.loadedPlugins.tasks.version;
                if (data.version && data.version !== currentVersion) {
                    root.tasksData = {};
                    root.calendarFilter = [pluginData.caldavCalendar];
                    root.calendarFilterInactive = [];
                    root.showCompleted = false;
                    root.saveDataFile();
                } else {
                    root.tasksData = data.tasksData || {};
                    root.calendarFilter = data.calendarFilter || [pluginData.caldavCalendar];
                    root.calendarFilterInactive = data.calendarFilterInactive || [];
                    root.showCompleted = data.showCompleted || false;
                }
            } catch (e) {
                root.logError("Failed to parse tasks data file:", e);
            }
            helperProcess.loadData();
        }

        onLoadFailed: {
            console.log("[Tasks] No existing data file, starting fresh");
            helperProcess.loadData();
        }
    }

    function saveDataFile() {
        if (!dataFile.path)
            return;
        dataFile.setText(JSON.stringify({
            version: root.pluginService.loadedPlugins.tasks.version,
            tasksData: root.tasksData || {},
            calendarFilter: root.calendarFilter,
            calendarFilterInactive: root.calendarFilterInactive,
            showCompleted: root.showCompleted
        }, null, 2));
    }

    // loadSettings
    function loadSettings(hardClear = false) {
        if (!pluginData) {
            root.logError("Failed to load plugin settings!", true);
            return;
        }

        if (!pluginData.caldavURL || !pluginData.caldavUsername || !pluginData.caldavPassword || !pluginData.caldavCalendar) {
            root.logError("Please fill in all required settings!", true);
            return;
        }

        root.settings = {
            caldavURL: pluginData.caldavURL,
            caldavUsername: pluginData.caldavUsername,
            caldavPassword: pluginData.caldavPassword,
            caldavCalendar: pluginData.caldavCalendar,
            caldavCalendars: pluginData.caldavCalendars ? pluginData.caldavCalendars.split(",").map(s => s.trim()) : [pluginData.caldavCalendar],
            caldavSSLVerify: pluginData.caldavSSLVerify !== undefined ? pluginData.caldavSSLVerify : false,
            shiftDueTimeDelta: isNaN(Number(pluginData.shiftDueTimeDelta)) ? 15 : Number(pluginData.shiftDueTimeDelta) // default to 15 minutes
            ,
            refreshInterval: isNaN(Number(pluginData.refreshInterval)) ? 1 : Number(pluginData.refreshInterval) // default to 1 minute
        };

        root.constants.caldavCreds = [root.settings.caldavURL, root.settings.caldavUsername, root.settings.caldavPassword];

        if (!root.initzialized || hardClear) {
            root.constants.helper = ["python3", Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "") + "main.py"];
            root.totalCalendarCount = root.settings.caldavCalendars.length + 1;

            if (!dataFile.path) {
                root.calendarFilter = [pluginData.caldavCalendar];
                root.calendarFilterInactive = [];
                dataFile.path = pluginService.pluginDirectory + "/tasks_data.json";
            }

            root.initzialized = true;
        }

        if (hardClear) {
            root.tasksData = {};
            root.calendarFilter = [pluginData.caldavCalendar];
            root.calendarFilterInactive = [];
            root.showCompleted = false;
            root.saveDataFile();
        }

        if (root.totalCalendarCount != root.settings.caldavCalendars.length + 1 || hardClear) {
            root.calendarFilter = [root.settings.caldavCalendar];
            root.calendarFilterInactive = root.settings.caldavCalendars;
            root.saveDataFile();
        }
    }

    // data loading
    property var tasksData
    property bool loading: false
    property var loadDataTimestamp: 0

    // helperProcess
    Process {
        id: helperProcess

        property string output: ""
        property var json: ({})

        property var onComplete: null

        stdout: SplitParser {
            onRead: data => {
                helperProcess.output += data + "\n";
            }
        }

        onStarted: () => {
            root.loading = true;

            helperProcess.output = "";
            helperProcess.json = {};
            helperProcess.running = true;
        }

        onExited: () => {
            try {
                var json = JSON.parse(output.trim());

                helperProcess.json = json || {};
            } catch (e) {
                root.logError("JSON parse error:", e);
                root.logError("Raw output:", output);
            }

            running = false;
            root.loading = false;

            if (helperProcess.onComplete) {
                helperProcess.onComplete();
            }

            if (!helperProcess.json.success) {
                root.logError(helperProcess.json.message || "Unknown error from helper process!", true);
                root.logError("error when running process:", helperProcess.command.join(" "));
                // throw new Error(helperProcess.json.message || "Unknown error from helper process!");
            }
        }

        function _preCheck() {
            if (root.loading || helperProcess.running) {
                root.logError("Please wait for the current operation to finish!", true);
                return false;
            }
            return true;
        }

        function _wrapCommandDefaults(command) {
            var mode = command[0];
            var modeArgs = command.slice(1);

            return root.constants.helper.concat([mode]).concat(root.constants.caldavCreds).concat(modeArgs).concat([root.settings.caldavSSLVerify ? "1" : "0"]).concat(["0"]);
        }

        function run(commmand, onComplete = null) {
            root.loading = true;
            helperProcess.onComplete = onComplete;
            helperProcess.command = _wrapCommandDefaults(commmand);
            helperProcess.running = true;
        }

        function loadData() {
            if (!_preCheck()) {
                return;
            }

            helperProcess.run(["load", root.calendarFilter.join(","), root.prioritySteps[root.priorityStepIndex]], () => {
                try {
                    root.tasksData = helperProcess.json.data;
                } catch (e) {
                    root.logError("Error processing helper process output:", e);
                    return;
                }

                root.loadDataTimestamp = Date.now();

                root.saveDataFile();
            });
        }

        function toggleComplete(task) {
            if (!_preCheck()) {
                return;
            }

            if (!task || !task.uid) {
                return;
            }

            helperProcess.run(["toggle_complete", task.calendar, task.uid], helperProcess.loadData);
        }

        function addTask(summary) {
            if (!_preCheck()) {
                return;
            }

            if (!summary || summary.trim() === "") {
                return;
            }

            helperProcess.run(["add_task", root.settings.caldavCalendar, summary.trim()], helperProcess.loadData);
        }

        function shiftTaskDueTime(task, forward = false, onComplete = helperProcess.loadData) {
            if (!_preCheck()) {
                return;
            }

            if (!task || !task.uid) {
                root.logError("Unable to update task: missing UID");
                return;
            }

            helperProcess.run(["shift_due_timestamp", task.calendar, task.uid, root.settings.shiftDueTimeDelta, forward ? "1" : "0"], onComplete);
        }
    }

    Timer {
        id: refreshTimer
        interval: (root.settings.refreshInterval * 60) * 1000
        running: true
        repeat: true
        onTriggered: {
            root.loadSettings();
            helperProcess.loadData();
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => {
            root.loadSettings();
            refreshTimer.running = true;
        });
    }

    // filters
    property bool showCompleted: false
    property var prioritySteps: [0, 1, 5, 9, -1]
    property int priorityStepIndex: 4

    property int totalCalendarCount: 0
    property var calendarFilter: []
    property var calendarFilterInactive: []

    function toggleCalendarFilter(calendar) {
        if (calendar == root.settings.caldavCalendar) {
            root.logError("Cannot disable main calendar filter!", true);
            return;
        }

        if (root.calendarFilter.includes(calendar)) {
            root.calendarFilter = root.calendarFilter.filter(c => c !== calendar);
            root.calendarFilterInactive = root.calendarFilterInactive.concat([calendar]);
        } else {
            root.calendarFilterInactive = root.calendarFilterInactive.filter(c => c !== calendar);
            root.calendarFilter = root.calendarFilter.concat([calendar]);
        }

        root.saveDataFile();

        helperProcess.loadData();
    }

    function cyclePriorityFilter() {
        root.priorityStepIndex += 1;
        if (root.priorityStepIndex >= root.prioritySteps.length) {
            root.priorityStepIndex = 0;
        }

        root.tasksData.tasks = root.tasksData.tasks;

        helperProcess.loadData();
    }

    horizontalBarPill: Component {
        Row {
            padding: Theme.spacingXS

            // current task
            StyledText {
                visible: root.tasksData != null && root.tasksData.currentTask != null
                text: root.tasksData != null && root.tasksData.currentTask != null ? ((root.tasksData.completeCount / root.tasksData.totalCount) * 100).toFixed(0) + "% - " + (root.tasksData.currentTask.allDay ? "" : Qt.formatDateTime(root.tasksData.currentTask.due, "hh:mm") + " : ") + root.tasksData.currentTask.summary : ""
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
            spacing: Theme.spacingXS

            DankTooltipV2 {
                id: tooltip
            }

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

                    StyledRect {
                        id: completedPill
                        width: 20
                        height: 20
                        color: root.showCompleted ? Theme.surfaceVariantText : "transparent"
                        border.width: 1
                        border.color: Theme.surfaceVariantText
                        radius: Theme.cornerRadius

                        DankIcon {
                            anchors.centerIn: parent
                            name: "check"
                            size: 14
                            color: root.showCompleted ? Theme.onPrimary : Theme.surfaceVariantText
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                root.showCompleted = !root.showCompleted;
                                root.saveDataFile();
                            }
                            onEntered: tooltip.show(root.showCompleted ? "Hide completed" : "Show completed", completedPill)
                            onExited: tooltip.hide()
                        }
                    }

                    StyledRect {
                        id: priorityPill
                        width: 20
                        height: 20
                        color: root.getPriorityColor(root.prioritySteps[root.priorityStepIndex])
                        border.width: 1
                        border.color: root.getPriorityColor(root.prioritySteps[root.priorityStepIndex])
                        radius: Theme.cornerRadius

                        property bool active: true

                        StyledText {
                            id: priorityPillText
                            height: 20
                            text: root.prioritySteps[root.priorityStepIndex] < 0 ? "*" : root.prioritySteps[root.priorityStepIndex].toString()
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.onPrimary
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: !root.loading
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                            onClicked: {
                                root.cyclePriorityFilter();
                            }
                            onEntered: tooltip.show("Priority filter (click to cycle)", priorityPill)
                            onExited: tooltip.hide()
                        }
                    }

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
                                text: root.totalCalendarCount >= 3 && !hoverHandler.hovered ? calendarPill.modelData.substring(0, 3) + "..." : calendarPill.modelData
                                font.pixelSize: Theme.fontSizeSmall
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.verticalCenter: parent.verticalCenter
                                color: calendarPill.active ? Theme.onPrimary : Theme.surfaceVariantText
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: !root.loading
                                hoverEnabled: true
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                                onClicked: {
                                    root.toggleCalendarFilter(calendarPill.modelData);
                                }
                                onEntered: {
                                    hoverHandler.hovered = true;
                                    tooltip.show("Toggle calendar: " + calendarPill.modelData, calendarPill);
                                }
                                onExited: {
                                    hoverHandler.hovered = false;
                                    tooltip.hide();
                                }
                            }

                            QtObject {
                                id: hoverHandler
                                property bool hovered: false
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
                        text: Qt.formatDateTime(new Date(root.loadDataTimestamp), "hh:mm ~ ") + root.settings.refreshInterval + "m"
                        font.pixelSize: Theme.fontSizeSmall * 0.8
                        font.family: "monospace"
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        width: refreshIcon.width
                        height: width
                        border.width: 0
                        radius: Theme.cornerRadius

                        color: "transparent"
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            id: refreshIcon
                            name: "refresh"
                            size: Theme.fontSizeSmall
                            color: Theme.primary

                            MouseArea {
                                id: refreshIconMouseArea
                                anchors.fill: parent
                                enabled: !root.loading
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor

                                onClicked: {
                                    root.loadSettings();
                                    helperProcess.loadData();
                                }
                                onPressAndHold: {
                                    ToastService.showInfo("Clearing cached data...");
                                    root.loadSettings(true);
                                    helperProcess.loadData();
                                }

                                onEntered: tooltip.show("Hold to reset!", refreshButton)
                                onExited: tooltip.hide()
                            }
                        }
                    }
                }
            }

            // add task input
            Row {
                id: addTaskRow
                width: parent.width - Theme.spacingS * 2
                height: addTaskInput.height + Theme.spacingS
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingXS

                Rectangle {
                    width: parent.width
                    height: addTaskInput.height
                    color: Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.15)
                    radius: Theme.cornerRadius
                    anchors.verticalCenter: parent.verticalCenter

                    TextInput {
                        id: addTaskInput
                        width: parent.width - Theme.spacingS * 2
                        anchors.centerIn: parent
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        padding: Theme.spacingXS
                        clip: true

                        property string placeholderText: "Add a new task..."

                        Text {
                            text: addTaskInput.placeholderText
                            font.pixelSize: addTaskInput.font.pixelSize
                            color: Theme.surfaceVariantText
                            visible: !addTaskInput.text && !addTaskInput.activeFocus
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Keys.onReturnPressed: {
                            if (addTaskInput.text.trim() !== "") {
                                helperProcess.addTask(addTaskInput.text);
                                addTaskInput.text = "";
                            }
                        }
                    }
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - popoutColumn.headerHeight - popoutColumn.detailsHeight - addTaskRow.height - Theme.spacingXL

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
                        spacing: Theme.spacingL

                        // group tasks by due date
                        Repeater {
                            model: root.tasksData.tasks

                            // column for each group
                            Column {
                                id: taskColumn
                                required property var modelData
                                width: parent.width
                                spacing: Theme.spacingXS

                                property var groupTasks: root.showCompleted ? modelData : modelData.filter(t => !t.completed)

                                // group header with due date
                                StyledText {
                                    width: parent.width
                                    visible: taskColumn.groupTasks.length > 0
                                    text: Qt.formatDateTime(taskColumn.groupTasks[0].due, "ddd, MMM d")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    font.bold: true
                                    font.weight: Font.Bold
                                }

                                Repeater {
                                    model: taskColumn.groupTasks

                                    Row {
                                        id: taskRow
                                        width: tasksGroupColumn.width
                                        height: Theme.fontSizeMedium * 1.1
                                        spacing: Theme.spacingXS

                                        required property var modelData
                                        property bool isChild: !!taskRow.modelData.parentUid
                                        property real indent: isChild ? Theme.spacingL : 0

                                        Item {
                                            width: taskRow.indent
                                            height: 1
                                            visible: taskRow.isChild
                                        }

                                        StyledText {
                                            text: taskRow.modelData.summary
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.strikeout: taskRow.modelData.completed
                                            color: Theme.surfaceText
                                            opacity: taskRow.modelData.completed ? 0.4 : 1.0
                                            elide: Text.ElideRight
                                            width: parent.width - detailsRow.width - Theme.spacingL - Theme.spacingXS - taskRow.indent - (taskRow.isChild ? Theme.spacingXS : 0)
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        // task details
                                        Row {
                                            id: detailsRow
                                            spacing: Theme.spacingS
                                            height: parent.height

                                            property var detailsFontSize: Theme.fontSizeSmall * 0.8

                                            // due time with shift buttons (hidden for all-day tasks)
                                            Row {
                                                id: timestampRow
                                                visible: !taskRow.modelData.allDay
                                                padding: Theme.spacingXS
                                                spacing: Theme.spacingS
                                                height: parent.height

                                                StyledText {
                                                    id: timestampShiftDown
                                                    text: '-'
                                                    font.pixelSize: detailsRow.detailsFontSize
                                                    font.family: "monospace"
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        enabled: !root.loading
                                                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                                                        onClicked: {
                                                            helperProcess.shiftTaskDueTime(taskRow.modelData, false);
                                                        }
                                                    }
                                                }

                                                StyledText {
                                                    id: timestampText
                                                    text: Qt.formatDateTime(new Date(taskRow.modelData.due), "hh:mm")
                                                    font.pixelSize: detailsRow.detailsFontSize
                                                    font.family: "monospace"
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }

                                                StyledText {
                                                    id: timestampShiftUp
                                                    text: '+'
                                                    font.pixelSize: detailsRow.detailsFontSize
                                                    font.family: "monospace"
                                                    color: Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        enabled: !root.loading
                                                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                                                        onClicked: {
                                                            helperProcess.shiftTaskDueTime(taskRow.modelData, true);
                                                        }
                                                    }
                                                }
                                            }

                                            StyledText {
                                                id: priorityText
                                                text: taskRow.modelData.priority.toString()
                                                font.pixelSize: detailsRow.detailsFontSize
                                                font.family: "monospace"
                                                color: root.getPriorityColor(taskRow.modelData.priority)
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            // checkbox
                                            StyledRect {
                                                id: checkbox
                                                width: detailsRow.detailsFontSize
                                                height: width
                                                radius: 1
                                                color: "transparent"
                                                border.width: 1
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
                                                    enabled: !root.loading
                                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                                                    onClicked: {
                                                        helperProcess.toggleComplete(taskRow.modelData);
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
