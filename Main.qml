import QtQuick
import Quickshell
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

        refreshInterval: isNaN(Number(pluginData.refreshInterval)) ? 60 : Number(pluginData.refreshInterval), // default to 1 minute
    })

    // data loading
    property var data
    property bool loading: true
    property bool loadDataProcessError: false
    property string loadDataProcessOutput: ""

    // misc.
    property string currentDirectory: {
        return Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "");
    }

    function loadData() {
        loadDataProcessOutput = "";
        loadDataProcess.command = [
            "python3",
            root.currentDirectory + "main.py",
            root.settings.caldavURL,
            root.settings.caldavUsername,
            root.settings.caldavPassword,
            root.settings.caldavCalendar,
            "0"
        ];
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

                root.data = json || {};

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
            spacing: Theme.spacingXS

            // current task
            StyledText {
                visible: !root.loading
                text: ((root.data.completeCount / root.data.totalCount) * 100).toFixed(0) + "% - " +Qt.formatDateTime(root.data.currentTask.due, "hh:mm")  + " : " + root.data.currentTask.summary
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
                visible: !root.loading && root.data && root.data.tasks.length <= 0
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
                    visible: !root.loading && root.data && root.data.tasks.length <= 0
                    text: "Nothing to do..."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // tasks list
                Flickable {
                    visible: !root.loading && root.data && root.data.tasks.length > 0
                    anchors.fill: parent
                    contentWidth: parent.width
                    contentHeight: tasksGroupColumn.height
                    clip: true

                    Column {
                        id: tasksGroupColumn
                        width: parent.width
                        padding: Theme.spacingS
                        spacing: Theme.spacingM

                        Repeater {
                            model: root.data.tasks

                            Column {
                                width: tasksGroupColumn.width
                                spacing: Theme.spacingS

                                property var groupTasks: modelData

                                StyledText {
                                    width: parent.width
                                    visible: groupTasks.length > 0
                                    text: Qt.formatDateTime(groupTasks[0].due, "ddd, MMM d")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                Repeater {
                                    model: groupTasks

                                    Row {
                                        width: tasksGroupColumn.width
                                        spacing: Theme.spacingS

                                        StyledText {
                                            text: modelData.summary
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            width: parent.width - timestampText.implicitWidth - ((Theme.spacingS * 2) + Theme.spacingM)
                                        }

                                        StyledText {
                                            id: timestampText
                                            text: modelData.allDay ? "NaN" : Qt.formatDateTime(new Date(modelData.due), "hh:mm")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
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