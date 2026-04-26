import QtQuick

import org.kde.plasma.plasma5support as Plasma5Support

Item {
    id: root

    visible: false

    property var queue: []
    property bool running: false

    signal finished(string stdout, int exitCode, int exitStatus, string stderr)

    Plasma5Support.DataSource {
        id: executableSource
        engine: "executable"

        onNewData: function(sourceName, data) {
            if (root.queue.length === 0) {
                executableSource.disconnectSource(sourceName)
                return
            }

            const current = root.queue[0]
            if (current.command !== sourceName) {
                return
            }

            executableSource.disconnectSource(sourceName)
            root.running = false

            const stdout = data["stdout"] ?? ""
            const exitCode = Number(data["exit code"] ?? -1)
            const exitStatus = Number(data["exit status"] ?? -1)
            const stderr = data["stderr"] ?? ""

            if (current.callback) {
                current.callback(stdout, exitCode, exitStatus, stderr)
            }

            root.finished(stdout, exitCode, exitStatus, stderr)
            root.queue.shift()
            root.runNext()
        }
    }

    function exec(command, callback) {
        root.queue.push({
            command: command,
            callback: callback,
        })

        root.runNext()
    }

    function runNext() {
        if (root.running || root.queue.length === 0) {
            return
        }

        root.running = true
        executableSource.connectSource(root.queue[0].command)
    }
}
