pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

/**
 * The Audio Engine: EasyEffects' output chain with six core effects in front of
 * the user's own chain, the microphone's chain likewise, built-in and user presets.
 * The helper only runs while a surface holds the engine (acquire/release), or for
 * the moment a command or a change of output needs it (hold).
 */
Singleton {
    id: root

    readonly property bool enabled: Config.options?.iris?.audio?.enable ?? true
    property int users: 0
    property int holds: 0
    // A command in flight keeps the helper too: a chain rebuilt or EasyEffects started outlasts a hold.
    readonly property bool live: root.enabled && (root.users > 0 || root.holds > 0 || root.busy)

    property bool ready: false
    property bool installed: false
    property bool running: false
    property bool adopted: false
    property list<string> missing: []
    property list<int> bandCounts: [8, 10, 12, 16, 32]
    property var extraKinds: []
    property var core: []
    property var extras: []
    property string active: ""
    property bool modified: false
    property bool bypass: false
    property bool headroom: true
    property var devices: ({})
    // Sounds apps bring while they play (node.name → preset), and the apps each chain leaves alone.
    property var apps: ({})
    property var excluded: ({ output: [], input: [] })
    property var mic: ({ adopted: false, core: [], active: "", builtins: [] })
    property list<string> builtins: []
    property list<string> presets: []
    property var presetInfo: ({})
    property int pending: 0
    readonly property bool busy: root.pending > 0
    property string error: ""
    property string notice: ""
    property bool starting: false
    // The page the Audio Engine shows, kept across closing it and switching between overlay and window.
    property string lastSection: "presets"
    property var _queue: []

    // What the engine last set, read from its state without running it: the Control Center and the output
    // memory need it while the Audio Engine is closed.
    readonly property string savedActive: String(root._saved?.active ?? "")
    readonly property var savedDevices: root._saved?.devices ?? ({})
    readonly property var savedApps: root._saved?.apps ?? ({})
    // Which apps a chain leaves alone, read from the state like the rest: the Volume page answers without the helper.
    function isExcluded(app: string, pipe: string): bool {
        const own = root.ready ? root.excluded?.[pipe] : root._saved?.pipes?.[pipe]?.blocklist
        return Array.from(own ?? []).includes(app)
    }
    property var _saved: ({})
    readonly property string shownActive: root.ready && root.running ? root.active : root.savedActive
    // Whether a sound is shaping what plays, for the faces that only point at the Audio Engine.
    readonly property bool effectsOn: root.ready
        ? root.running && !root.bypass && root.active.length > 0 && root.active !== "Default"
        : root.savedActive.length > 0 && root.savedActive !== "Default"
    // Every sound by name, without running the helper: the built-ins from their file, the person's from the state.
    readonly property list<string> builtinNames: root._builtinNames
    property list<string> _builtinNames: ["Default"]
    readonly property list<string> micNames: root._micNames
    property list<string> _micNames: []
    readonly property var savedPresets: root._saved?.presets ?? []
    readonly property var catalog: root.builtinNames.concat(Array.from(root.savedPresets))
    property bool booted: false

    readonly property string helper: Quickshell.shellPath("scripts/audio/audio_engine.py")
    readonly property string presetsDir: `${Directories.shellConfig}/audio/presets`
    readonly property string stateFile: `${Directories.stateUserPath}/audio-engine.json`

    function acquire(): void {
        root.users++
    }

    function release(): void {
        root.users = Math.max(0, root.users - 1)
    }

    // A command from outside a surface (the Island, IPC, a change of output): the helper runs for it, then rests.
    function hold(): void {
        root.holds++
        holdTimer.restart()
    }

    function module(kind: string): var {
        return root.core.find(m => m.kind === kind) ?? null
    }

    function micModule(kind: string): var {
        return (root.mic?.core ?? []).find(m => m.kind === kind) ?? null
    }

    function extra(id: string): var {
        return root.extras.find(e => e.id === id) ?? null
    }

    function _send(request: var, loud: bool): void {
        if (!root.enabled)
            return
        if (loud) {
            root.pending++
            // A new command starts clean: the last one's error no longer describes anything. A poll is not a command.
            if (!["poll", "refresh", "status"].includes(request.op))
                root.error = ""
        }
        if (!proc.running) {
            root._queue = [...root._queue, request]
            return
        }
        proc.write(JSON.stringify(request) + "\n")
    }

    function _patch(target: var, mutate: var): void {
        if (target.kind && !target.id) {
            root.core = root.core.map(m => m.kind === target.kind ? mutate(Object.assign({}, m)) : m)
        } else {
            root.core = root.core.map(m => m.id === target.id ? mutate(Object.assign({}, m)) : m)
            root.extras = root.extras.map(e => e.id === target.id ? mutate(Object.assign({}, e)) : e)
        }
    }

    function _patchMic(kind: string, mutate: var): void {
        const next = Object.assign({}, root.mic)
        next.core = (root.mic?.core ?? []).map(m => m.kind === kind ? mutate(Object.assign({}, m)) : m)
        root.mic = next
    }

    function _target(ref: string): var {
        return ref.indexOf("#") >= 0 ? { id: ref } : { kind: ref }
    }

    function refresh(): void { root._send({ op: "status" }, true) }

    function start(): void {
        root.starting = true
        root._send({ op: "start" }, true)
    }

    function quitEasyEffects(): void { root._send({ op: "quit" }, true) }

    // The sound iNiR starts with (Settings › Sound & Feedback › Audio Engine): once per shell.
    function boot(name: string, mic: string): void {
        if (root.booted) return
        root.booted = true
        root._send({ op: "boot", name: name.length > 0 ? name : "Default", mic: mic }, true)
    }

    // The next or previous sound in the list everything shows (built in, then yours), from the one playing.
    function stepPreset(step: int): void {
        const list = root.catalog
        if (list.length === 0) return
        const at = list.indexOf(root.shownActive)
        const next = list[((at < 0 ? (step > 0 ? -1 : 0) : at) + step + list.length) % list.length]
        root.hold()
        root.applyPreset(next)
    }

    // Leaving an app out of a chain reloads it (EasyEffects reads its list only from a preset): the sound drops for an instant.
    // EasyEffects claims back any stream it does not leave alone, so a stream is moved only once the chain that leaves
    // its app out has loaded: excludeApplied says when.
    signal excludeApplied(string app, bool on, string pipe)
    property var _excludeWaiting: []
    function exclude(app: string, on: bool, pipe: string): void {
        const next = Object.assign({}, root.excluded)
        const list = Array.from(next[pipe] ?? []).filter(entry => entry !== app)
        next[pipe] = on ? list.concat([app]).sort() : list
        root.excluded = next
        root._excludeWaiting = root._excludeWaiting.concat([{ app: app, on: on, pipe: pipe }])
        root._send({ op: "exclude", app: app, on: on, pipe: pipe }, true)
    }
    function rememberApp(app: string, preset: string): void { root._send({ op: "rememberApp", app: app, preset: preset }, true) }
    function forgetApp(app: string): void { root._send({ op: "forgetApp", app: app }, true) }

    function setEnabled(ref: string, on: bool): void {
        const target = root._target(ref)
        root._patch(target, m => { m.enabled = on; return m })
        root._send(Object.assign({ op: "enable", enabled: on }, target), true)
    }

    // Live: the knob is already where the pointer left it, nothing comes back.
    function setValue(ref: string, prop: string, value: var): void {
        const target = root._target(ref)
        root._patch(target, m => {
            m.values = Object.assign({}, m.values)
            m.values[prop] = value
            return m
        })
        if (!root.adopted) {
            root._send(Object.assign({ op: "enable", enabled: root.module(ref)?.enabled ?? false }, target), true)
        }
        root._send(Object.assign({ op: "set", prop: prop, value: value }, target), false)
        modifiedProbe.restart()
    }

    function setBand(index: int, gain: real): void {
        root._patch({ kind: "equalizer" }, m => {
            m.bands = m.bands.map((b, i) => i === index ? { frequency: b.frequency, gain: gain } : b)
            if (root.headroom) {
                m.values = Object.assign({}, m.values)
                m.values.inputGain = -Math.max(0, ...m.bands.map(b => Number(b.gain)))
            }
            return m
        })
        if (!root.adopted)
            root._send({ op: "enable", kind: "equalizer", enabled: root.module("equalizer")?.enabled ?? false }, true)
        root._send({ op: "band", index: index, gain: gain }, false)
        modifiedProbe.restart()
    }

    function setMicEnabled(kind: string, on: bool): void {
        root._patchMic(kind, m => { m.enabled = on; return m })
        root._send({ op: "enable", pipe: "input", kind: kind, enabled: on }, true)
    }

    function setMicValue(kind: string, prop: string, value: var): void {
        root._patchMic(kind, m => {
            m.values = Object.assign({}, m.values)
            m.values[prop] = value
            return m
        })
        if (!(root.mic?.adopted ?? false))
            root._send({ op: "enable", pipe: "input", kind: kind, enabled: root.micModule(kind)?.enabled ?? false }, true)
        root._send({ op: "set", pipe: "input", kind: kind, prop: prop, value: value }, false)
    }

    // The autotune's key, scale or style: the helper turns it into note switches and knob values.
    function tuneMic(field: string, value: var): void {
        root._patchMic("autotune", m => {
            m.tune = Object.assign({}, m.tune)
            m.tune[field] = value
            return m
        })
        const request = { op: "tune" }
        request[field] = value
        root._send(request, true)
    }

    function setBypass(on: bool): void {
        root.bypass = on
        root._send({ op: "bypass", on: on }, false)
    }

    function toggleBypass(): void { root._send({ op: "toggleBypass" }, false) }

    function setHeadroom(on: bool): void {
        root.headroom = on
        root._send({ op: "headroom", on: on }, true)
    }

    function setBandCount(count: int): void { root._send({ op: "bands", count: count }, true) }
    function applyBuiltin(name: string): void { root._send({ op: "builtin", name: name }, true) }
    function applyPreset(name: string): void { root._send({ op: "apply", name: name }, true) }
    function applyMic(name: string): void { root._send({ op: "mic", name: name }, true) }
    function loadPreset(name: string): void { root._send({ op: "load", name: name }, true) }
    function savePreset(name: string): void { root._send({ op: "save", name: name }, true) }
    // The sound iNiR starts with follows its preset when it is renamed, and falls back to Default when it is deleted.
    readonly property string startupPreset: String(Config.options?.iris?.audio?.startup?.preset ?? "Default")
    function renamePreset(from: string, to: string): void {
        if (root.startupPreset === from) Config.setNestedValue("iris.audio.startup.preset", to)
        root._send({ op: "rename", from: from, to: to }, true)
    }
    function deletePreset(name: string): void {
        if (root.startupPreset === name) Config.setNestedValue("iris.audio.startup.preset", "Default")
        root._send({ op: "delete", name: name }, true)
    }
    function revert(): void { root._send({ op: "revert" }, true) }
    function addEffect(kind: string): void { root._send({ op: "add", kind: kind }, true) }
    function removeEffect(id: string): void { root._send({ op: "remove", id: id }, true) }
    function remember(sink: string, preset: string): void { root._send({ op: "remember", sink: sink, preset: preset }, true) }
    function forget(sink: string): void { root._send({ op: "forget", sink: sink }, true) }
    function exportPreset(name: string, path: string, format: string): void {
        root._send({ op: "export", name: name, path: path, format: format }, true)
    }
    function importPreset(path: string): void { root._send({ op: "import", path: path }, true) }

    function _consume(line: string): void {
        let event = null
        try {
            event = JSON.parse(line)
        } catch (e) {
            return
        }
        if (event.type === "status") {
            root.installed = event.installed === true
            root.running = event.running === true
            root.missing = event.missing ?? []
            root.bandCounts = event.bandCounts ?? root.bandCounts
            root.extraKinds = event.extras ?? []
        } else if (event.type === "error") {
            root.error = String(event.message ?? "")
            if (event.op === "start" || event.op === "boot")
                root.starting = false
        } else if (event.type === "bypass") {
            root.bypass = event.on === true
        } else if (event.type === "exported") {
            root.notice = "exported"
        } else if (event.type === "imported") {
            root.notice = "imported"
        } else if (event.type === "poll") {
            // Nothing changed since the last state: the poll is answered and nothing is read again.
            root.pending = Math.max(0, root.pending - 1)
        } else if (event.type === "state") {
            // A quiet command's state only corrects the knobs; nothing was counted for it.
            if (event.quiet !== true)
                root.pending = Math.max(0, root.pending - 1)
            // A report that failed tells nothing about EasyEffects.
            if (event.unknown === true)
                return
            root.running = event.running === true
            if (root.pending === 0 && root._excludeWaiting.length > 0) {
                const done = root._excludeWaiting
                root._excludeWaiting = []
                for (const entry of done) root.excludeApplied(entry.app, entry.on, entry.pipe)
            }
            root.devices = event.devices ?? root.devices
            root.apps = event.apps ?? root.apps
            root.excluded = event.excluded ?? root.excluded
            root.headroom = event.headroom ?? root.headroom
            if (root.running) {
                root.starting = false
                root.adopted = event.adopted === true
                root.core = event.core ?? []
                root.extras = event.extras ?? []
                root.active = event.active ?? ""
                root.modified = event.modified === true
                root.bypass = event.bypass === true
                root.mic = event.mic ?? root.mic
                root.builtins = event.builtins ?? []
                root.presets = event.presets ?? []
                root.presetInfo = event.presetInfo ?? ({})
            }
            root.ready = true
        }
    }

    onLiveChanged: {
        if (!root.live) {
            root.pending = 0
            root._excludeWaiting = []
            root.ready = false
            root._queue = []
        }
    }

    Process {
        id: proc
        running: root.live
        stdinEnabled: true
        command: ["python3", root.helper, "--presets-dir", root.presetsDir, "--state-file", root.stateFile]
        stdout: SplitParser {
            onRead: line => root._consume(line)
        }
        // A helper that dies leaves nothing to answer what was asked of it.
        onExited: root.pending = 0
        onStarted: {
            const queued = root._queue
            root._queue = []
            if (!queued.some(request => request.op === "status")) root.pending++
            proc.write(JSON.stringify({ op: "status" }) + "\n")
            for (const request of queued) proc.write(JSON.stringify(request) + "\n")
        }
    }

    FileView {
        path: root.stateFile
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root._saved = JSON.parse(text())
            } catch (e) {
                root._saved = ({})
            }
        }
        onLoadFailed: root._saved = ({})
    }

    FileView {
        path: Quickshell.shellPath("scripts/audio/audio-presets.json")
        onLoaded: {
            try {
                const data = JSON.parse(text())
                root._builtinNames = ["Default"].concat(Object.keys(data.presets ?? {}))
                root._micNames = Object.keys(data.microphone ?? {})
            } catch (e) {
                root._builtinNames = ["Default"]
            }
        }
    }

    // A command from outside a surface keeps the helper only as long as it takes.
    Timer {
        id: holdTimer
        interval: 6000
        onTriggered: root.holds = 0
    }

    // Moving a knob comes back with nothing; whether the sound still matches its preset is asked once it rests.
    Timer {
        id: modifiedProbe
        interval: 700
        onTriggered: if (root.active.length > 0 && !root.modified) root._send({ op: "refresh" }, true)
    }

    // EasyEffects can be started or closed, or its chain changed, from elsewhere while a surface is open: a poll
    // reads only what tells whether anything moved, and the whole state comes back only when it did. A knob turned in
    // EasyEffects' own window moves no part of that, so every sixth poll reads everything.
    property int _polls: 0
    Timer {
        interval: root.running ? 5000 : 4000
        repeat: true
        running: root.users > 0 && root.enabled && !root.busy
        onTriggered: {
            root._polls = (root._polls + 1) % 6
            root._send({ op: !root.running ? "status" : root._polls === 0 ? "refresh" : "poll" }, true)
        }
    }
}
