pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.style
import qs.modules.iris.components
import qs.modules.iris.settings

// The Audio Engine at a glance: the sound playing now and the equalizer's curve, effects on or off, a few sounds (the
// person's own among them), the output and microphone they are tuned for, and the microphone's sounds a tap away. The
// Island's Sound page and the Audio Engine bubble's card both show it; everything else is one step further, in the
// Audio Engine itself (openRequested).
ColumnLayout {
    id: root
    // Holds the helper only while it is on screen: a page left behind a collapsed Island must not keep it running.
    property bool live: true
    signal openRequested()

    readonly property real d: IrisStyle.density
    readonly property var quick: {
        const picks = ["Default", "Voice", "Bass", "Games", "Movies", "Night"].filter(name => AudioEngine.builtins.includes(name))
            .concat(AudioEngine.presets.slice(0, 3))
        const now = AudioEngine.active
        return now.length > 0 && !picks.includes(now) ? picks.concat([now]) : picks
    }
    readonly property var micBuiltins: AudioEngine.mic?.builtins ?? []
    readonly property var micSounds: root.micBuiltins.concat(AudioEngine.mic?.presets ?? [])
    readonly property var eq: AudioEngine.module("equalizer")
    spacing: 12 * root.d

    property bool held: false
    function hold(on: bool): void {
        if (on === root.held) return
        root.held = on
        if (on) AudioEngine.acquire()
        else AudioEngine.release()
    }
    onLiveChanged: root.hold(root.live)
    Component.onCompleted: root.hold(root.live)
    Component.onDestruction: root.hold(false)

    RowLayout {
        Layout.fillWidth: true
        spacing: 12 * root.d
        IrisSquircle {
            Layout.preferredWidth: Math.round(40 * root.d)
            Layout.preferredHeight: Math.round(40 * root.d)
            tint: IrisStyle.identity.pink
            glyph: "graphic_eq"
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            IrisText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: AudioEngine.shownActive.length === 0 ? Translation.tr("No sound chosen")
                    : AudioEngine.tunedOutput && AudioEngine.builtins.includes(AudioEngine.shownActive)
                    ? Translation.tr("%1 for %2").arg(Translation.tr(AudioEngine.shownActive)).arg(AudioEngine.tunedOutput.name)
                    : AudioEngine.presets.includes(AudioEngine.shownActive) ? AudioEngine.shownActive
                    : Translation.tr(AudioEngine.shownActive)
                font.pixelSize: IrisStyle.typeBody
                font.weight: IrisStyle.weight(Font.DemiBold)
            }
            IrisText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: !AudioEngine.ready ? Translation.tr("Looking for EasyEffects…")
                    : !AudioEngine.installed ? Translation.tr("EasyEffects is not installed")
                    : !AudioEngine.running ? Translation.tr("EasyEffects is off")
                    : AudioEngine.bypass ? Translation.tr("Without effects")
                    : AudioEngine.modified ? Translation.tr("Changed from the preset")
                    : Translation.tr("Audio Engine")
                role: IrisText.Meta
            }
        }
        IrisSwitch {
            visible: AudioEngine.running
            on: !AudioEngine.bypass
            name: Translation.tr("Effects")
            onToggled: AudioEngine.setBypass(!AudioEngine.bypass)
        }
        IrisIconButton {
            materialIcon: "open_in_full"
            Accessible.name: Translation.tr("Open the Audio Engine")
            onClicked: root.openRequested()
        }
    }

    // What the equalizer does to the sound now, quiet while it is off or bypassed.
    IrisAudioCurve {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.round(44 * root.d)
        visible: AudioEngine.running && (root.eq?.bands ?? []).length > 0
        bands: root.eq?.bands ?? []
        active: (root.eq?.enabled ?? false) && !AudioEngine.bypass
        grid: false
        quiet: true
    }

    Flow {
        Layout.fillWidth: true
        visible: AudioEngine.running
        spacing: Math.round(6 * root.d)
        Repeater {
            model: root.quick
            IrisAudioChip {
                id: soundChip
                required property var modelData
                name: soundChip.modelData
                translated: !AudioEngine.presets.includes(soundChip.modelData)
                selected: AudioEngine.active === soundChip.modelData
                onClicked: AudioEngine.applyPreset(soundChip.modelData)
            }
        }
    }

    // The output and microphone the built-in sounds are fit to, when the Auto Audio / Microphone Engine is on.
    Tuned {
        visible: AudioEngine.running && AudioEngine.autoOutput && AudioEngine.outputs.length > 0
        pipe: "output"
        title: Translation.tr("Tuned for")
    }
    Tuned {
        visible: AudioEngine.running && AudioEngine.autoMic && AudioEngine.inputs.length > 0
        pipe: "input"
        title: Translation.tr("Voice tuned for")
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: AudioEngine.running && root.micSounds.length > 0
        spacing: 8 * root.d
        IrisText {
            text: Translation.tr("Microphone")
            role: IrisText.Meta
            font.weight: IrisStyle.weight(Font.DemiBold)
        }
        Flow {
            Layout.fillWidth: true
            spacing: Math.round(6 * root.d)
            Repeater {
                model: root.micSounds
                IrisAudioChip {
                    id: micChip
                    required property var modelData
                    name: micChip.modelData
                    selected: (AudioEngine.mic?.active ?? "") === micChip.modelData
                    translated: root.micBuiltins.includes(micChip.modelData)
                    onClicked: micChip.translated ? AudioEngine.applyMic(micChip.modelData) : AudioEngine.loadMicPreset(micChip.modelData)
                }
            }
        }
    }

    IrisButton {
        visible: AudioEngine.ready && AudioEngine.installed && !AudioEngine.running
        Layout.alignment: Qt.AlignLeft
        text: AudioEngine.starting ? Translation.tr("Starting…") : Translation.tr("Start EasyEffects")
        emphasized: true
        buttonRadius: height / 2
        enabled: !AudioEngine.starting
        onClicked: AudioEngine.start()
    }

    component Tuned: ColumnLayout {
        id: tuned
        property string pipe: "output"
        property string title: ""
        readonly property var chosen: AudioEngine.tunedOf(tuned.pipe)
        Layout.fillWidth: true
        spacing: 8 * root.d
        IrisText {
            text: tuned.title
            role: IrisText.Meta
            font.weight: IrisStyle.weight(Font.DemiBold)
        }
        Flow {
            Layout.fillWidth: true
            spacing: Math.round(6 * root.d)
            IrisAudioChip {
                name: "Default"
                translated: true
                selected: tuned.chosen === null
                onClicked: AudioEngine.tuneFor("", tuned.pipe)
            }
            Repeater {
                model: AudioEngine.tunedList(tuned.pipe)
                IrisAudioChip {
                    required property var modelData
                    name: String(modelData.name)
                    selected: tuned.chosen?.id === modelData.id
                    onClicked: AudioEngine.tuneFor(String(modelData.id), tuned.pipe)
                }
            }
        }
    }
}
