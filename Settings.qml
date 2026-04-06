import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "tasks"

    StringSetting {
        settingKey: "caldavURL"
        label: "CalDav URL"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "caldavUsername"
        label: "CalDav Username"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "caldavPassword"
        label: "CalDav Password"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "caldavCalendar"
        label: "CalDav Calendar"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "refreshInterval"
        label: "Refresh Interval (seconds)"
        defaultValue: "60"
    }
}