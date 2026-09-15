import QtQuick

import org.kde.plasma.plasma5support as Plasma5Support

Item {
    id: root

    visible: false

    // Guards against a backend that never reports back: without this the queue
    // would stall forever and the widget would silently stop updating.
    property int timeoutMs: 15000
    property int maxQueueLength: 4

    property var queue: []
    property bool running: false

    signal finished(string stdout, int exitCode, int exitStatus, string stderr)

    Plasma5Support.DataSource {
        id: executableSource
        engine: "executable"

        onNewData: function(sourceName, data) {
            if (root.queue.length === 0 || root.queue[0].command !== sourceName) {
                executableSource.disconnectSource(sourceName)
                return
            }

            root.complete(
                sourceName,
                data["stdout"] ?? "",
                Number(data["exit code"] ?? -1),
                Number(data["exit status"] ?? -1),
                data["stderr"] ?? ""
            )
        }
    }

    Timer {
        id: watchdog
        interval: root.timeoutMs
        repeat: false
        onTriggered: {
            if (!root.running || root.queue.length === 0) {
                return
            }

            root.complete(
                root.queue[0].command,
                "",
                -1,
                -1,
                i18n("Backend hat nicht innerhalb von %1 s geantwortet.", Math.round(root.timeoutMs / 1000))
            )
        }
    }

    function exec(command, callback) {
        // Drop the oldest pending entries rather than piling up work that a
        // stuck backend will never drain.
        while (root.queue.length >= root.maxQueueLength) {
            root.queue.shift()
        }

        root.queue.push({
            command: command,
            callback: callback,
        })

        root.runNext()
    }

    function complete(sourceName, stdout, exitCode, exitStatus, stderr) {
        watchdog.stop()
        executableSource.disconnectSource(sourceName)
        root.running = false

        const current = root.queue.shift()

        if (current && current.callback) {
            current.callback(stdout, exitCode, exitStatus, stderr)
        }

        root.finished(stdout, exitCode, exitStatus, stderr)
        root.runNext()
    }

    function runNext() {
        if (root.running || root.queue.length === 0) {
            return
        }

        root.running = true
        watchdog.restart()
        executableSource.connectSource(root.queue[0].command)
    }
}
