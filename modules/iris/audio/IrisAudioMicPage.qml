pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.components
import qs.modules.iris.style
import qs.modules.iris.settings

// The microphone's chain, laid out like the output's: the microphone the sounds are tuned for, a sound for what you are
// doing (it shapes the effects that are on, as the output's built-ins do), the Auto Microphone Engine, your own
// presets, then each effect as a captioned card that opens on its own switch. The autotune's key, scale and style are
// not EasyEffects parameters: the helper spells them into its note switches and knobs.
ColumnLayout {
    id: root
    readonly property real d: IrisStyle.density
    readonly property var mic: AudioEngine.mic ?? ({})

    spacing: 6 * root.d

    readonly property string errorText: ({
        builtin_name: Translation.tr("That name belongs to a built-in sound."),
        invalid_name: Translation.tr("Give it a name of up to 64 characters."),
        name_taken: Translation.tr("A preset already has that name."),
        tuned_name_taken: Translation.tr("A tuned microphone already has that name."),
        tuned_not_found: Translation.tr("That tuned microphone is gone."),
        tuned_full: Translation.tr("Remove a tuned microphone first: five are kept at most."),
        no_mic: Translation.tr("No microphone to listen with."),
        needs_numpy: Translation.tr("The test needs NumPy in iNiR's Python environment."),
        probe_failed: Translation.tr("The test could not record. Check that the microphone is free.")
    })[AudioEngine.error] ?? ""

    // A microphone just tuned opens with its name ready to change: a headset and the built-in one are told apart here.
    Connections {
        target: AudioEngine
        function onProbed(id: string, pipe: string): void { if (pipe === "input") tunedFor.rename(id) }
    }

    IrisAudioTunedFor {
        id: tunedFor
        Layout.fillWidth: true
        pipe: "input"
        visible: AudioEngine.autoMic && AudioEngine.inputs.length > 0
    }

    IrisAudioCaption { text: Translation.tr("Sound for") }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: soundColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: soundColumn
            width: parent.width
            Repeater {
                model: root.mic.builtins ?? []
                IrisAudioPresetRow {
                    id: sound
                    required property var modelData
                    required property int index
                    readonly property var look: IrisAudioModules.micLooks[sound.modelData] ?? ({ glyph: "mic", tint: "gray", line: "" })
                    name: sound.modelData
                    glyph: sound.look.glyph
                    tintName: sound.look.tint
                    line: sound.modelData === "Off" || !AudioEngine.tunedInput ? Translation.tr(sound.look.line)
                        : Translation.tr("%1, fit to your voice").arg(Translation.tr(sound.look.line))
                    last: sound.index === (root.mic.builtins ?? []).length - 1
                    current: (root.mic.active ?? "") === sound.modelData
                    onActivated: AudioEngine.applyMic(sound.modelData)
                }
            }
        }
    }

    IrisText {
        Layout.fillWidth: true
        Layout.leftMargin: 16 * root.d
        text: Translation.tr("A sound shapes only the effects you turned on below; Off turns them all off.")
        color: IrisStyle.muted
        font.pixelSize: IrisStyle.typeMeta
        wrapMode: Text.WordWrap
    }

    IrisAudioAutoTune {
        Layout.fillWidth: true
        Layout.topMargin: 10 * root.d
        pipe: "input"
        visible: AudioEngine.autoMic
    }

    IrisAudioCaption { text: Translation.tr("Yours") }
    IrisAudioOwnPresets {
        Layout.fillWidth: true
        pipe: "input"
        emptyText: Translation.tr("Nothing saved yet. Turn on the effects you want, pick a sound, adjust it, and save your voice here.")
        placeholder: Translation.tr("Save your voice as a preset")
    }

    IrisText {
        Layout.fillWidth: true
        Layout.leftMargin: 16 * root.d
        visible: root.errorText.length > 0
        text: root.errorText
        color: IrisStyle.danger
        font.pixelSize: IrisStyle.typeMeta
        wrapMode: Text.WordWrap
    }

    Repeater {
        model: IrisAudioModules.micModules
        ColumnLayout {
            id: block
            required property var modelData
            readonly property var entry: AudioEngine.micModule(block.modelData.kind)
            readonly property bool on: block.entry?.enabled ?? false
            readonly property var values: block.entry?.values ?? ({})
            readonly property var tune: block.entry?.tune ?? ({})
            readonly property bool blocked: String(block.entry?.needs ?? "").length > 0 && AudioEngine.missing.includes(block.entry.needs)
            readonly property var rows: (IrisAudioModules.micParams[block.modelData.kind] ?? [])
                .filter(param => (!param.when || Boolean(block.values[param.when]))
                    && (!param.keyed || block.tune.scale !== "chromatic"))
            Layout.fillWidth: true
            spacing: 6 * root.d

            IrisAudioCaption { text: Translation.tr(block.modelData.title) }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: blockColumn.implicitHeight
                radius: IrisStyle.radiusTile
                color: IrisStyle.readingCard
                Column {
                    id: blockColumn
                    width: parent.width
                    IrisAudioRow {
                        width: blockColumn.width
                        last: block.rows.length === 0
                        param: ({ kind: "switch", label: block.modelData.title,
                                  description: block.blocked ? Translation.tr("Needs the %1 plugins, which are not installed.").arg(block.entry.needs === "x42" ? "x42" : "LSP")
                                      : block.on ? "On: the sound passes through it." : "Off: the sound passes by untouched." })
                        value: block.on
                        enabled: !block.blocked
                        onEdited: value => AudioEngine.setMicEnabled(block.modelData.kind, value)
                    }
                    // The voice's equalizer: its ten bands over the response they shape.
                    Item {
                        visible: block.modelData.kind === "equalizer"
                        width: blockColumn.width
                        height: visible ? Math.round(220 * root.d) : 0
                        IrisAudioEqGraph {
                            anchors.fill: parent
                            anchors.margins: IrisStyle.concentricPad(IrisStyle.radiusTile, 8 * root.d)
                            enabled: block.on
                            bands: block.entry?.bands ?? []
                            active: block.on
                            onEdited: (index, gain) => AudioEngine.setMicBand(index, gain)
                        }
                    }
                    Repeater {
                        model: block.rows
                        IrisAudioRow {
                            required property var modelData
                            required property int index
                            width: blockColumn.width
                            param: modelData
                            last: index === block.rows.length - 1
                            enabled: block.on
                            opacity: block.on ? 1 : 0.4
                            value: modelData.tune ? block.tune[modelData.tune] : block.values[modelData.prop]
                            fallback: modelData.tune ? undefined : block.entry?.defaults?.[modelData.prop]
                            onEdited: value => modelData.tune ? AudioEngine.tuneMic(modelData.tune, value)
                                : AudioEngine.setMicValue(block.modelData.kind, modelData.prop, value)
                        }
                    }
                }
            }
        }
    }
}
