pragma ComponentBehavior: Bound

import QtQuick
import qs.services
import qs.services.deferred

// Plays the sound an output remembers when it becomes the output: headphones in, their preset; out, the speakers'.
// Only a change counts: the output the shell starts on keeps whatever was set by hand.
// An app that brings a sound plays it while it plays, and the sound it replaced comes back once it stops, unless the
// sound was changed by hand in between. The newest app wins; a short pause (a browser drops its stream on pause)
// does not count as stopping.
Item {
    id: root
    readonly property string sink: String(Audio.sink?.name ?? "")
    property string lastSink: ""
    property bool primed: false

    function apply(preset: string): void {
        AudioEngine.hold()
        AudioEngine.applyPreset(preset)
    }

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
        root.before = ""
        root.applied = ""
        root.apply(preset)
    }

    // The remembered apps playing now, in the order they started.
    readonly property var memory: AudioEngine.savedApps
    readonly property var playing: {
        const names = []
        for (const node of Audio.outputAppNodes ?? []) {
            const name = String(node?.properties?.["node.name"] ?? "")
            if (name.length > 0 && root.memory[name] !== undefined && !names.includes(name)) names.push(name)
        }
        return names
    }
    property var order: []
    // What was playing before an app brought its own sound, and the sound it brought.
    property string before: ""
    property string applied: ""

    onPlayingChanged: {
        if (!root.primed) return
        const started = root.playing.filter(name => !root.order.includes(name))
        root.order = root.order.filter(name => root.playing.includes(name)).concat(started)
        if (started.length > 0) {
            stopped.stop()
            const preset = String(root.memory[started[started.length - 1]] ?? "")
            if (preset.length === 0 || preset === AudioEngine.shownActive) return
            if (root.applied.length === 0) root.before = AudioEngine.shownActive
            root.applied = preset
            root.apply(preset)
        } else if (root.order.length > 0) {
            // Another remembered app still plays: its sound takes over.
            const preset = String(root.memory[root.order[root.order.length - 1]] ?? "")
            if (root.applied.length > 0 && preset.length > 0 && preset !== root.applied) {
                root.applied = preset
                root.apply(preset)
            }
        } else if (root.applied.length > 0) {
            stopped.restart()
        }
    }

    Timer {
        id: stopped
        interval: 4000
        onTriggered: {
            if (root.playing.length > 0) return
            // A sound changed by hand while the app played stays.
            if (root.before.length > 0 && AudioEngine.shownActive === root.applied) root.apply(root.before)
            root.before = ""
            root.applied = ""
        }
    }

    Timer {
        interval: 5000
        running: true
        onTriggered: {
            root.lastSink = root.sink
            root.order = root.playing
            root.primed = true
        }
    }
}
