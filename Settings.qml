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

PluginSettings {
    id: root
    pluginId: "tasks"

    function showToastError(message) {
        ToastService.showError("Tasks Plugin", message);
    }

    property string currentDirectory: {
        return Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "");
    }

    Row {
        spacing: Theme.spacingM
        width: parent.width

        StringSetting {
            id: calDavURLSetting
            enabled: !root.loading
            width: (((parent.width - parent.spacing) / 3) * 2)
            settingKey: "caldavURL"
            label: "CalDav URL"
            defaultValue: ""
        }

        StringSetting {
            id: refreshIntervalSetting
            enabled: !root.loading
            width: (((parent.width - parent.spacing) / 3) * 1)
            settingKey: "refreshInterval"
            label: "Refresh Interval (minutes)"
            defaultValue: "1"
        }
    }

    Row {
        spacing: Theme.spacingM
        width: parent.width

        StringSetting {
            id: calDavUsernameSetting
            enabled: !root.loading
            width: (((parent.width - parent.spacing) / 3) * 1)
            settingKey: "caldavUsername"
            label: "CalDav Username"
            defaultValue: ""
        }

        StringSetting {
            id: calDavPasswordSetting
            enabled: !root.loading
            width: (((parent.width - parent.spacing) / 3) * 2)
            settingKey: "caldavPassword"
            label: "CalDav Password"
            defaultValue: ""
        }
    }

    Row {
        spacing: Theme.spacingM
        width: parent.width

        StringSetting {
            id: calDavCalendarSetting
            enabled: !root.loading
            width: (((parent.width - parent.spacing) / 3) * 1)
            settingKey: "caldavCalendar"
            label: "Main CalDav Calendar"
            defaultValue: ""
        }

        StringSetting {
            id: calDavCalendarsSetting
            enabled: !root.loading
            width: (((parent.width - parent.spacing) / 3) * 2)
            settingKey: "caldavCalendars"
            label: "Secondary CalDav Calendars (comma-separated)"
            defaultValue: ""
        }
    }

    DankButton {
        enabled: !root.loading
        width: parent.width
        text: "Validate Settings"
        onClicked: {
            if (root.validateSettings()) {
                ToastService.showInfo("Settings are valid!");
            }
        }
    }

    property bool loading: false
    property string validateProcessOutput: ""

    Process {
        id: validateProcess

        stdout: SplitParser {
            onRead: line => {
                root.validateProcessOutput += line + "\n";
            }
        }

        onStarted: {
            root.loading = true;
            root.validateProcessError = "";
            root.validateProcessOutput = "";

            validateProcess.running = true;
        }

        onExited: (exitCode, exitStatus) => {
            try {
                var json = JSON.parse(root.validateProcessOutput.trim());

                if (json && json.success) {
                    ToastService.showInfo("Settings are valid!");
                } else {
                    throw new Error(json && json.message ? json.message : "Unknown error!");
                }
            } catch (e) {
                root.showToastError("Validation failed: " + e.message);
            }

            root.loading = false;
            root.validateProcessOutput = "";
            validateProcess.running = false;
        }
    }

    function validateSettings() {
        if (!calDavURLSetting.value) {
            root.showToastError("CalDav URL cannot be empty");
            return false;
        }
        if (!calDavUsernameSetting.value) {
            root.showToastError("CalDav Username cannot be empty");
            return false;
        }
        if (!calDavPasswordSetting.value) {
            root.showToastError("CalDav Password cannot be empty");
            return false;
        }
        if (!calDavCalendarSetting.value) {
            root.showToastError("Main CalDav Calendar cannot be empty");
            return false;
        }
        if (isNaN(parseInt(refreshIntervalSetting.value)) || parseInt(refreshIntervalSetting.value) <= 0) {
            root.showToastError("Refresh Interval must be a positive integer");
            return false;
        }

        validateProcess.command = ["python3", root.currentDirectory + "main.py", "validate", calDavURLSetting.value, calDavUsernameSetting.value, calDavPasswordSetting.value, calDavCalendarSetting.value, calDavCalendarsSetting.value, "0"];
        validateProcess.running = true;
    }
}
