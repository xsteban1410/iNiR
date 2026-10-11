pragma ComponentBehavior: Bound

import QtQuick
import qs.services
import qs.services.deferred

// Plays the sound an output remembers when it becomes the output: headphones in, their preset; out, the speakers'.
// Only a change counts: the output the shell starts on keeps whatever was set by hand.
Item {
    id: root
    readonly property string sink: String(Audio.sink?.name ?? "")
    property string lastSink: ""
    property bool primed: false

    onSinkChanged: {
        if (!root.primed) {
            root.lastSink = root.sink
            return
        }
        if (root.sink.length === 0 || root.sink === root.lastSink)
            return
        root.lastSink = root.sink
        const preset = String(AudioEngine.savedDevices[root.sink] ?? "")
        if (preset.length === 0)
            return
        AudioEngine.hold()
        AudioEngine.applyPreset(preset)
    }

    Timer {
        interval: 5000
        running: true
        onTriggered: {
            root.lastSink = root.sink
            root.primed = true
        }
    }
}
