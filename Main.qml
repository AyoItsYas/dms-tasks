pragma ComponentBehavior: Bound

import QtQuick
// import Quickshell
import Quickshell.Io
import qs.Common
// import qs.Services
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
            refreshInterval: isNaN(Number(pluginData.refreshInterval)) ? 60 : Number(pluginData.refreshInterval) // default to 1 minute
        })

    // data loading
    property var tasksData
    property bool loading: true
    property bool loadDataProcessError: false
    property string loadDataProcessOutput: ""

    // misc.
    property string currentDirectory: {
        return Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "");
    }

    function loadData() {
        loadDataProcessOutput = "";
        loadDataProcess.command = ["python3", root.currentDirectory + "main.py", "load", root.settings.caldavURL, root.settings.caldavUsername, root.settings.caldavPassword, root.settings.caldavCalendar, "0"];
        loadDataProcess.running = true;
    }

    Process {
        id: loadDataProcess

        stdout: SplitParser {
            onRead: data => {
                root.loadDataProcessOutput += data + "\n";
            }
        }
        onExited: {
            root.loading = false;

            try {
                var json = JSON.parse(root.loadDataProcessOutput.trim());

                root.tasksData = json || {};

                root.loadDataProcessError = false;
            } catch (e) {
                console.log("JSON parse error:", e);
                console.log("Raw output:", root.loadDataProcessOutput);

                root.loadDataProcessError = true;
            }
        }
    }

    Timer {
        interval: root.settings.refreshInterval * 1000
        running: true
        repeat: true
        onTriggered: root.loadData()
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
                                        spacing: Theme.spacingXS

                                        StyledText {
                                            text: taskRow.modelData.summary
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            width: parent.width - detailsRow.implicitWidth - Theme.spacingXL
                                        }

                                        // task details
                                        Row {
                                            id: detailsRow
                                            spacing: Theme.spacingS
                                            height: parent.height

                                            StyledText {
                                                id: timestampText
                                                text: taskRow.modelData.allDay ? "NaN" : Qt.formatDateTime(new Date(taskRow.modelData.due), "hh:mm")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                            }

                                            // checkbox
                                            Rectangle {
                                                width: Theme.fontSizeSmall * 0.70
                                                height: width
                                                radius: 0
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
