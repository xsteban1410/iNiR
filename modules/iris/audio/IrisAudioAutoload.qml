pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.services
import qs.services.deferred

// Plays the sound an output remembers when it becomes the output: headphones in, their preset; out, the speakers'.
// Only a change counts: the output the shell starts on keeps whatever was set by hand.
// An app that brings a sound plays it while it plays, and the sound it replaced comes back once it stops, unless the
// sound was changed by hand in between. The newest app wins; a short pause (a browser drops its stream on pause)
// does not count as stopping.
// A tuned output follows the output too: a port changing on the same sink (headphones in or out) counts as a change.
// A tuned microphone follows the microphones' ports the same way (a headset in or out).
Item {
    id: root
    readonly property string sink: AudioEngine.outputSink
    readonly property bool tunes: AudioEngine.autoOutput && AudioEngine.savedFollow && AudioEngine.savedOutputs.length > 0
    readonly property bool tunesMic: AudioEngine.autoMic && AudioEngine.savedMicFollow && AudioEngine.savedInputs.length > 0
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
        // The tuned output first: a remembered built-in sound is then shaped to it.
        if (root.tunes) {
            AudioEngine.hold()
            AudioEngine.follow(root.sink, "output")
        }
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

    // A port is a card's: plugging headphones in changes the card, not the sink. A card also changes with its volume,
    // so the sink's active port is read and only a new one counts.
    property string lastPort: ""
    property bool portKnown: false
    property string lastMicPorts: ""
    property bool micPortsKnown: false
    Process {
        running: root.tunes || root.tunesMic
        command: ["pactl", "subscribe"]
        stdout: SplitParser {
            onRead: line => {
                if (line.indexOf("'change' on card") >= 0) portSettled.restart()
            }
        }
    }
    Timer {
        id: portSettled
        interval: 600
        onTriggered: {
            if (root.tunes && !portRead.running) portRead.running = true
            if (root.tunesMic && !micPortRead.running) micPortRead.running = true
        }
    }
    // The microphones' ports, every hardware one: which of them EasyEffects records from is the helper's to say.
    Process {
        id: micPortRead
        command: ["pactl", "-f", "json", "list", "sources"]
        stdout: StdioCollector { id: micPortText }
        onExited: {
            let ports = ""
            try {
                ports = JSON.parse(micPortText.text).filter(s => !String(s.name).startsWith("easyeffects")
                    && !String(s.name).endsWith(".monitor")).map(s => `${s.name}:${s.active_port ?? ""}`).join(",")
            } catch (e) {
                return
            }
            const changed = root.micPortsKnown && ports !== root.lastMicPorts
            root.lastMicPorts = ports
            root.micPortsKnown = true
            if (!changed || !root.primed) return
            AudioEngine.hold()
            AudioEngine.follow("", "input")
        }
    }
    Process {
        id: portRead
        command: ["pactl", "-f", "json", "list", "sinks"]
        stdout: StdioCollector { id: portText }
        onExited: {
            let port = ""
            try {
                port = String(JSON.parse(portText.text).find(s => s.name === root.sink)?.active_port ?? "")
            } catch (e) {
                return
            }
            const changed = root.portKnown && port !== root.lastPort
            root.lastPort = port
            root.portKnown = true
            if (!changed || !root.primed || root.sink.length === 0) return
            AudioEngine.hold()
            AudioEngine.follow(root.sink, "output")
        }
    }

    Timer {
        interval: 5000
        running: true
        onTriggered: {
            root.lastSink = root.sink
            if (root.tunes) portRead.running = true
            if (root.tunesMic) micPortRead.running = true
            root.order = root.playing
            root.primed = true
        }
    }
}
