pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.components
import qs.modules.iris.style
import qs.modules.iris.settings

// Volume, the way a mixer lays it out: the speakers and the microphone in use, then every device and every app
// that plays or records, each at its own level with a meter of what passes. An app opens to where it plays, whether
// the effects reach it and the sound it brings. These are PipeWire's levels, not effects: they answer with EasyEffects
// off, and EasyEffects' own virtual devices are left out of the lists because they only carry the chain.
ColumnLayout {
    id: root
    readonly property real d: IrisStyle.density
    // Ear protection's limit holds here too: a slider at its end is the loudest the shell allows.
    readonly property real ceiling: Math.max(0.01, Audio.ceiling)
    // Meters run only while the page is on screen.
    readonly property bool metering: root.visible && root.QsWindow.window?.visible === true

    // EasyEffects' own nodes, and meters (Quickshell's peak monitors, the loudness meter): they carry or watch sound,
    // nobody plays through them.
    function carriesChain(node): bool {
        const props = node?.properties ?? {}
        const name = String(props["node.name"] ?? node?.name ?? "")
        return name.startsWith("easyeffects_") || name.startsWith("ee_")
            || String(props["application.id"] ?? "") === "com.github.wwmm.easyeffects"
            || String(props["stream.monitor"] ?? "") === "true" || String(props["media.category"] ?? "") === "Monitor"
    }
    function same(a, b): bool { return a !== null && a !== undefined && b !== null && b !== undefined && Number(a.id) === Number(b.id) }
    function nodeName(node): string { return String(node?.properties?.["node.name"] ?? node?.name ?? "") }
    readonly property var outputs: (Audio.outputDevices ?? []).filter(node => node && !root.carriesChain(node))
    readonly property var inputs: (Audio.inputDevices ?? []).filter(node => node && !root.carriesChain(node))
    readonly property var playing: (Audio.outputAppNodes ?? []).filter(node => node?.audio && !root.carriesChain(node))
    readonly property var recording: (Audio.inputAppNodes ?? []).filter(node => node?.audio && !root.carriesChain(node))
    readonly property var effectsSink: (Audio.outputDevices ?? []).find(node => root.nodeName(node) === "easyeffects_sink") ?? null
    readonly property var effectsSource: (Audio.inputDevices ?? []).find(node => root.nodeName(node) === "easyeffects_source") ?? null
    // With EasyEffects on, the devices in use are the real ones behind its virtual sink and source.
    readonly property int outputInUse: Number(Audio.sink?.id ?? -1)
    readonly property int inputInUse: Audio._hardwareSourceId()
    readonly property var microphone: root.inputs.find(node => Number(node.id) === root.inputInUse) ?? Audio.source
    readonly property bool effectsLive: AudioEngine.running && root.effectsSink !== null

    // The shared tracker binds the default devices and app streams; the other devices are bound here while shown.
    PwObjectTracker { objects: root.outputs.concat(root.inputs) }

    // A stream is moved once EasyEffects has stopped claiming it (or has been told it may again).
    property var pendingMoves: ({})
    function send(stream, input: bool, target): void {
        const app = root.nodeName(stream)
        const toEffects = root.same(target, input ? root.effectsSource : root.effectsSink)
        const pipe = input ? "input" : "output"
        if (!root.effectsLive || app.length === 0 || AudioEngine.isExcluded(app, pipe) === !toEffects) {
            Audio.moveStream(stream, target)
            return
        }
        const next = Object.assign({}, root.pendingMoves)
        next[pipe + ":" + app] = { stream: stream, target: target }
        root.pendingMoves = next
        AudioEngine.exclude(app, !toEffects, pipe)
    }
    Connections {
        target: AudioEngine
        function onExcludeApplied(app: string, on: bool, pipe: string): void {
            const key = pipe + ":" + app
            const move = root.pendingMoves[key]
            if (!move) return
            const next = Object.assign({}, root.pendingMoves)
            delete next[key]
            root.pendingMoves = next
            Audio.moveStream(move.stream, move.target)
        }
    }

    spacing: 6 * root.d

    component Empty: IrisText {
        Layout.fillWidth: true
        Layout.leftMargin: 16 * root.d
        Layout.rightMargin: 16 * root.d
        Layout.topMargin: 12 * root.d
        Layout.bottomMargin: 12 * root.d
        color: IrisStyle.muted
        font.pixelSize: IrisStyle.typeLabel
        wrapMode: Text.WordWrap
    }

    // What passes through a device, on a decibel scale: -60 dBFS is empty, 0 full, red once it clips. Quickshell
    // publishes the cube root of the linear peak, so its decibels are 60·log10. Apps get no meter: a stream's own
    // output cannot be captured without a stream-to-stream link, which WirePlumber does not make.
    component Meter: Rectangle {
        id: meter
        property var node: null
        property color tint: IrisStyle.accent
        readonly property real peak: Math.max(0, Number(monitor.peak) || 0)
        readonly property real level: meter.peak <= 0.1 ? 0 : Math.max(0, Math.min(1, (60 * Math.log10(meter.peak) + 60) / 60))
        implicitHeight: Math.max(2, Math.round(3 * root.d))
        radius: height / 2
        color: IrisStyle.fillQuiet
        PwNodePeakMonitor {
            id: monitor
            node: meter.node
            enabled: root.metering && meter.node !== null
        }
        Rectangle {
            width: parent.width * meter.level
            height: parent.height
            radius: parent.radius
            color: meter.peak >= 0.999 ? IrisStyle.danger : meter.tint
        }
    }

    // One of the two levels everything else follows: what the default output plays at, what the microphone sends.
    component MasterLevel: ColumnLayout {
        id: master
        property bool input: false
        property bool last: false
        readonly property bool muted: master.input ? Audio.micMuted : (Audio.sink?.audio?.muted ?? false)
        readonly property real level: master.input ? Audio.micVolume : (Audio.value ?? 0)
        readonly property real span: master.input ? 1 : root.ceiling
        spacing: 10 * root.d
        Layout.fillWidth: true
        Layout.leftMargin: 16 * root.d
        Layout.rightMargin: 16 * root.d
        Layout.topMargin: 14 * root.d
        Layout.bottomMargin: master.last ? 16 * root.d : 4 * root.d
        RowLayout {
            Layout.fillWidth: true
            spacing: 12 * root.d
            IrisSquircle {
                Layout.preferredWidth: Math.round(30 * root.d)
                Layout.preferredHeight: Math.round(30 * root.d)
                tint: master.input ? IrisStyle.identity.orange : IrisStyle.identity.indigo
                glyph: master.input ? "mic" : "volume_up"
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                IrisText {
                    Layout.fillWidth: true
                    text: master.input ? Translation.tr("Microphone") : Translation.tr("Speakers")
                    font.pixelSize: IrisStyle.typeLabel
                    font.weight: IrisStyle.weight(Font.DemiBold)
                    elide: Text.ElideRight
                }
                IrisText {
                    Layout.fillWidth: true
                    text: Audio.friendlyDeviceName(master.input ? root.microphone : Audio.sink)
                    color: IrisStyle.muted
                    font.pixelSize: IrisStyle.typeMeta
                    elide: Text.ElideRight
                }
            }
            IrisNumber {
                text: master.muted ? Translation.tr("Muted") : Math.round(master.level * 100) + "%"
                color: IrisStyle.subtext
                pixelSize: IrisStyle.typeLabel
                weight: Font.DemiBold
            }
        }
        IrisCapsuleSlider {
            Layout.fillWidth: true
            implicitHeight: Math.round(44 * root.d)
            muted: master.muted
            icon: master.input ? (master.muted ? "mic_off" : "mic")
                : master.muted ? "volume_off" : master.level < 0.34 ? "volume_mute" : master.level < 0.67 ? "volume_down" : "volume_up"
            value: Math.min(1, master.level / master.span)
            Accessible.name: master.input ? Translation.tr("Microphone") : Translation.tr("Volume")
            onMoved: next => master.input ? Audio.setSourceVolume(next) : Audio.setSinkVolume(next * master.span)
            onIconClicked: master.input ? Audio.toggleMicMute() : Audio.toggleMute()
        }
        Meter {
            Layout.fillWidth: true
            Layout.leftMargin: 6 * root.d
            Layout.rightMargin: 6 * root.d
            node: master.input ? root.microphone : Audio.sink
            tint: master.input ? IrisStyle.identity.orange : IrisStyle.identity.indigo
        }
    }

    // A device or an app at its own level: its mark, name and what it is doing, its slider and meter. An app opens
    // to where it plays, the effects and the sound it brings.
    component LevelRow: Item {
        id: row
        required property var modelData
        required property int index
        property int count: 0
        property bool device: false
        property bool input: false
        property bool open: false
        readonly property var node: row.modelData
        readonly property string app: root.nodeName(row.node)
        readonly property bool muted: row.node?.audio?.muted ?? false
        readonly property real level: Number(row.node?.audio?.volume ?? 0) || 0
        readonly property bool current: row.device && (row.input ? root.inputInUse : root.outputInUse) === Number(row.node?.id ?? -2)
        readonly property string media: String(row.node?.properties?.["media.name"] ?? "")
        // Where an app's stream goes now: the other end of its link, compared by id (one node, many wrappers).
        readonly property var linked: {
            if (row.device) return null
            const own = Number(row.node?.id ?? -1)
            for (const link of Pipewire.links.values) {
                if (row.input && Number(link?.target?.id ?? -2) === own && !link.source?.isStream) return link.source
                if (!row.input && Number(link?.source?.id ?? -2) === own && !link.target?.isStream) return link.target
            }
            return null
        }
        readonly property bool throughEffects: root.same(row.linked, row.input ? root.effectsSource : root.effectsSink)
        readonly property string detail: row.device ? (row.current ? Translation.tr("In use") : "")
            : row.throughEffects ? Translation.tr("Through effects")
            : row.linked ? Audio.friendlyDeviceName(row.linked)
            : row.media !== Audio.appNodeDisplayName(row.node) ? row.media : ""
        readonly property string brings: String(AudioEngine.ready ? (AudioEngine.apps[row.app] ?? "") : (AudioEngine.savedApps[row.app] ?? ""))
        Layout.fillWidth: true
        implicitHeight: rowColumn.implicitHeight + Math.round(22 * root.d)

        Rectangle {
            visible: row.index < row.count - 1
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16 * root.d
            height: 1
            color: IrisStyle.hairline
        }

        ColumnLayout {
            id: rowColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16 * root.d
            anchors.rightMargin: 12 * root.d
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * root.d
            RowLayout {
                Layout.fillWidth: true
                spacing: 12 * root.d
                // An app's mark and name open its options.
                MouseArea {
                    id: head
                    Layout.fillWidth: true
                    Layout.preferredHeight: headRow.implicitHeight
                    enabled: !row.device
                    hoverEnabled: !row.device
                    cursorShape: row.device ? Qt.ArrowCursor : Qt.PointingHandCursor
                    Accessible.role: row.device ? Accessible.StaticText : Accessible.Button
                    Accessible.name: row.device ? Audio.friendlyDeviceName(row.node) : Audio.appNodeDisplayName(row.node)
                    onClicked: row.open = !row.open
                    RowLayout {
                        id: headRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 12 * root.d
                        IrisSquircle {
                            visible: row.device
                            Layout.preferredWidth: Math.round(26 * root.d)
                            Layout.preferredHeight: Math.round(26 * root.d)
                            tint: row.input ? IrisStyle.identity.orange : IrisStyle.identity.indigo
                            glyph: row.input ? "mic"
                                : /head|bluez|airpod|buds/i.test(String(row.node?.name ?? "") + String(row.node?.description ?? "")) ? "headphones" : "speaker"
                        }
                        IrisImage {
                            visible: !row.device
                            Layout.preferredWidth: Math.round(26 * root.d)
                            Layout.preferredHeight: Math.round(26 * root.d)
                            source: !row.device && row.node ? Quickshell.iconPath(MprisController.streamIconName(row.node), "audio-x-generic") : ""
                            opacity: row.muted ? 0.45 : 1
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            IrisText {
                                Layout.fillWidth: true
                                text: row.device ? Audio.friendlyDeviceName(row.node) : Audio.appNodeDisplayName(row.node)
                                font.pixelSize: IrisStyle.typeLabel
                                font.weight: IrisStyle.weight(row.current || row.open ? Font.DemiBold : Font.Medium)
                                elide: Text.ElideRight
                            }
                            IrisText {
                                Layout.fillWidth: true
                                visible: text.length > 0
                                text: row.brings.length > 0 ? Translation.tr("%1 · brings %2").arg(row.detail).arg(Translation.tr(row.brings)) : row.detail
                                color: row.current ? IrisStyle.accent : IrisStyle.muted
                                font.pixelSize: IrisStyle.typeMeta
                                elide: Text.ElideRight
                            }
                        }
                        MaterialSymbol {
                            visible: !row.device
                            text: "expand_more"
                            iconSize: Math.round(18 * root.d)
                            color: head.containsMouse ? IrisStyle.text : IrisStyle.muted
                            rotation: row.open ? 180 : 0
                            Behavior on rotation { NumberAnimation { duration: IrisStyle.duration(160); easing.type: IrisStyle.feedbackEasing } }
                        }
                    }
                }
                IrisNumber {
                    text: Math.round(row.level * 100) + "%"
                    color: IrisStyle.subtext
                    pixelSize: IrisStyle.typeMeta
                    weight: Font.DemiBold
                }
                // A device that is not in use can be made the one everything plays through, or records from.
                IrisButton {
                    visible: row.device && !row.current
                    text: Translation.tr("Use")
                    quiet: true
                    buttonRadius: height / 2
                    Accessible.name: Translation.tr("Use %1").arg(Audio.friendlyDeviceName(row.node))
                    onClicked: row.input ? Audio.setDefaultSource(row.node) : Audio.setDefaultSink(row.node)
                }
                IrisIconButton {
                    materialIcon: row.input ? (row.muted ? "mic_off" : "mic") : (row.muted ? "volume_off" : "volume_up")
                    selected: row.muted
                    Accessible.name: row.muted ? Translation.tr("Unmute") : Translation.tr("Mute")
                    onClicked: if (row.node?.audio) row.node.audio.muted = !row.muted
                }
            }
            IrisScrubber {
                Layout.fillWidth: true
                enabled: row.node?.audio !== undefined && row.node?.audio !== null
                fillColor: row.muted ? IrisStyle.muted : IrisStyle.fillStrong
                value: Math.min(1, row.level / root.ceiling)
                onMoved: next => { if (row.node?.audio) row.node.audio.volume = next * root.ceiling }
            }
            Meter {
                Layout.fillWidth: true
                visible: row.device
                node: row.device ? row.node : null
                tint: row.input ? IrisStyle.identity.orange : IrisStyle.identity.indigo
            }
            Loader {
                Layout.fillWidth: true
                active: row.open && !row.device
                visible: active
                sourceComponent: AppOptions { stream: row.node; input: row.input; linked: row.linked; app: row.app; brings: row.brings }
            }
        }
    }

    // Where an app plays or records from, whether the effects reach it, and the sound it brings while it plays.
    component AppOptions: ColumnLayout {
        id: options
        property var stream: null
        property bool input: false
        property var linked: null
        property string app: ""
        property string brings: ""
        readonly property string pipe: options.input ? "input" : "output"
        readonly property var effectsNode: options.input ? root.effectsSource : root.effectsSink
        readonly property var devices: options.input ? root.inputs : root.outputs
        readonly property bool excluded: AudioEngine.isExcluded(options.app, options.pipe)
        spacing: 10 * root.d
        Layout.topMargin: 4 * root.d
        Layout.bottomMargin: 4 * root.d

        RowLayout {
            Layout.fillWidth: true
            visible: root.effectsLive && options.app.length > 0
            spacing: 12 * root.d
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                IrisText {
                    text: Translation.tr("Through effects")
                    font.pixelSize: IrisStyle.typeLabel
                    font.weight: IrisStyle.weight(Font.Medium)
                }
                IrisText {
                    Layout.fillWidth: true
                    text: options.excluded
                        ? Translation.tr("EasyEffects leaves this app alone, now and whenever it plays again.")
                        : options.input ? Translation.tr("It records through the microphone's chain.")
                        : Translation.tr("It plays through your sound. Turning this off reloads the chain, so the sound may drop for an instant.")
                    color: IrisStyle.muted
                    font.pixelSize: IrisStyle.typeMeta
                    wrapMode: Text.WordWrap
                }
            }
            IrisSwitch {
                on: !options.excluded
                enabled: !AudioEngine.busy
                name: Translation.tr("Through effects")
                onToggled: root.send(options.stream, options.input, options.excluded
                    ? options.effectsNode
                    : (options.input ? root.microphone : Audio.sink))
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6 * root.d
            IrisText {
                text: options.input ? Translation.tr("Records from") : Translation.tr("Plays on")
                color: IrisStyle.label
                font.pixelSize: IrisStyle.typeMeta
                font.weight: IrisStyle.weight(Font.DemiBold)
            }
            Flow {
                Layout.fillWidth: true
                spacing: Math.round(6 * root.d)
                IrisAudioChip {
                    visible: root.effectsLive
                    name: Translation.tr("Effects")
                    glyph: "graphic_eq"
                    selected: root.same(options.linked, options.effectsNode)
                    onClicked: root.send(options.stream, options.input, options.effectsNode)
                }
                Repeater {
                    model: options.devices
                    IrisAudioChip {
                        required property var modelData
                        name: Audio.friendlyDeviceName(modelData)
                        glyph: options.input ? "mic" : "speaker"
                        selected: root.same(options.linked, modelData)
                        onClicked: root.send(options.stream, options.input, modelData)
                    }
                }
            }
            IrisText {
                Layout.fillWidth: true
                visible: root.effectsLive
                text: Translation.tr("Another device leaves the effects out: EasyEffects plays on one device at a time.")
                color: IrisStyle.muted
                font.pixelSize: IrisStyle.typeMeta
                wrapMode: Text.WordWrap
            }
        }

        // The sound an app brings while it plays, and takes away when it stops.
        ColumnLayout {
            Layout.fillWidth: true
            visible: !options.input && options.app.length > 0
            spacing: 6 * root.d
            IrisText {
                text: Translation.tr("Sound while it plays")
                color: IrisStyle.label
                font.pixelSize: IrisStyle.typeMeta
                font.weight: IrisStyle.weight(Font.DemiBold)
            }
            Flow {
                Layout.fillWidth: true
                spacing: Math.round(6 * root.d)
                IrisAudioChip {
                    name: Translation.tr("None")
                    selected: options.brings.length === 0
                    onClicked: if (options.brings.length > 0) AudioEngine.forgetApp(options.app)
                }
                Repeater {
                    model: AudioEngine.catalog
                    IrisAudioChip {
                        required property var modelData
                        name: Translation.tr(modelData)
                        selected: options.brings === modelData
                        onClicked: AudioEngine.rememberApp(options.app, modelData)
                    }
                }
            }
        }
    }

    component Group: Rectangle {
        default property alias rows: groupColumn.data
        Layout.fillWidth: true
        implicitHeight: groupColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        ColumnLayout {
            id: groupColumn
            width: parent.width
            spacing: 0
        }
    }

    IrisText {
        Layout.fillWidth: true
        Layout.leftMargin: 16 * root.d
        visible: text.length > 0
        text: AudioEngine.error === "chain_failed" ? Translation.tr("EasyEffects did not take the new chain. Try again.")
            : AudioEngine.error.startsWith("internal_") ? Translation.tr("Something went wrong there. The Audio Engine keeps running; try again.")
            : ""
        color: IrisStyle.danger
        font.pixelSize: IrisStyle.typeMeta
        wrapMode: Text.WordWrap
    }

    IrisAudioCaption { text: Translation.tr("Now") }
    Group {
        MasterLevel {}
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 16 * root.d
            Layout.topMargin: 10 * root.d
            implicitHeight: 1
            color: IrisStyle.hairline
        }
        MasterLevel { input: true; last: true }
    }

    IrisAudioCaption { text: Translation.tr("Playback") }
    Group {
        Empty { visible: root.playing.length === 0; text: Translation.tr("No app is playing sound.") }
        Repeater {
            // A stream coming or going keeps the other rows: a plain array rebuilt every delegate.
            model: ScriptModel { values: root.playing }
            LevelRow { count: root.playing.length }
        }
    }

    IrisAudioCaption { text: Translation.tr("Recording") }
    Group {
        Empty { visible: root.recording.length === 0; text: Translation.tr("No app is recording.") }
        Repeater {
            model: ScriptModel { values: root.recording }
            LevelRow { input: true; count: root.recording.length }
        }
    }

    IrisAudioCaption { text: Translation.tr("Output devices") }
    Group {
        Empty { visible: root.outputs.length === 0; text: Translation.tr("No output device found.") }
        Repeater {
            model: ScriptModel { values: root.outputs }
            LevelRow { device: true; count: root.outputs.length }
        }
    }

    IrisAudioCaption { text: Translation.tr("Input devices") }
    Group {
        Empty { visible: root.inputs.length === 0; text: Translation.tr("No microphone found.") }
        Repeater {
            model: ScriptModel { values: root.inputs }
            LevelRow { device: true; input: true; count: root.inputs.length }
        }
    }
}
