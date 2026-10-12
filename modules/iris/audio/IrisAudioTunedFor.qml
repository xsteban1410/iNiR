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

// Which output (or microphone) the built-in sounds are shaped to: Default (as they are) or one the Auto Audio Engine
// or the Auto Microphone Engine measured. The chosen one shows what was measured, and is renamed, measured again or
// removed here.
ColumnLayout {
    id: root
    // "output" for the Audio Engine's sounds, "input" for the microphone's.
    property string pipe: "output"
    readonly property bool voice: root.pipe === "input"
    readonly property real d: IrisStyle.density
    // The output playing now: the device itself, never EasyEffects' virtual sink.
    readonly property string sink: AudioEngine.outputSink
    readonly property var chosen: AudioEngine.tunedOf(root.pipe)
    property string renaming: ""
    property bool confirming: false
    // A new tuned output opens with its name ready to change: two ports of one sink are told apart here.
    function rename(id: string): void {
        root.confirming = false
        root.renaming = id
    }

    spacing: 6 * root.d

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 8 * root.d
        Layout.leftMargin: 16 * root.d
        Layout.rightMargin: 12 * root.d
        spacing: 8 * root.d
        IrisText {
            Layout.fillWidth: true
            text: Translation.tr("Tuned for")
            color: IrisStyle.label
            font.family: IrisStyle.fontTitle
            font.pixelSize: IrisStyle.typeMeta
            font.weight: IrisStyle.weight(Font.DemiBold)
        }
        IrisText {
            text: root.voice ? Translation.tr("Follow the microphone") : Translation.tr("Follow the output")
            color: IrisStyle.subtext
            font.pixelSize: IrisStyle.typeMeta
        }
        IrisSwitch {
            on: AudioEngine.tunedFollow(root.pipe)
            name: root.voice ? Translation.tr("Follow the microphone") : Translation.tr("Follow the output")
            enabled: !AudioEngine.busy
            onToggled: AudioEngine.setTuningFollow(!AudioEngine.tunedFollow(root.pipe), root.pipe)
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: body.implicitHeight + Math.round(24 * root.d)
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard

        ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 12 * root.d
            anchors.rightMargin: 12 * root.d
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12 * root.d

            IrisSegmented {
                Layout.fillWidth: true
                accessibleName: Translation.tr("Tuned for")
                options: [{ value: "", label: "Default" }].concat(AudioEngine.tunedList(root.pipe).map(o => ({ value: o.id, label: o.name })))
                current: root.chosen ? root.chosen.id : ""
                enabled: !AudioEngine.busy
                onPicked: value => {
                    root.renaming = ""
                    root.confirming = false
                    AudioEngine.tuneFor(String(value), root.pipe)
                }
            }

            IrisText {
                visible: root.chosen === null
                Layout.fillWidth: true
                Layout.leftMargin: 4 * root.d
                text: root.voice ? Translation.tr("The microphone's sounds play as they are. Pick a tuned microphone to fit them to your voice; with Follow the microphone on, plugging a headset in or out switches for you.")
                    : Translation.tr("The built-in sounds play as they are. Pick a tuned output to fit them to it; with Follow the output on, plugging in or out switches for you.")
                color: IrisStyle.muted
                font.pixelSize: IrisStyle.typeMeta
                wrapMode: Text.WordWrap
            }

            RowLayout {
                visible: root.chosen !== null
                Layout.fillWidth: true
                spacing: 14 * root.d

                Rectangle {
                    Layout.preferredWidth: Math.round(240 * root.d)
                    Layout.preferredHeight: Math.round(104 * root.d)
                    Layout.alignment: Qt.AlignTop
                    radius: IrisStyle.radiusRow
                    color: IrisStyle.fillQuiet
                    clip: true
                    IrisAudioResponse {
                        anchors.fill: parent
                        curve: root.chosen?.curve ?? []
                        correction: root.chosen?.correction ?? []
                        low: root.chosen?.measured && !root.voice ? root.chosen.low : null
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 4 * root.d

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8 * root.d
                        IrisSquircle {
                            Layout.preferredWidth: Math.round(24 * root.d)
                            Layout.preferredHeight: Math.round(24 * root.d)
                            tint: IrisStyle.identityColor(root.voice ? "orange" : root.chosen?.kind === "headphones" ? "indigo" : "blue")
                            glyph: ({ headphones: "headphones", display: "tv", headset: "headset_mic", usb: "mic_external_on",
                                      bluetooth: "bluetooth", internal: "laptop_chromebook", external: "mic" })[root.chosen?.kind ?? ""]
                                ?? "speaker"
                        }
                        IrisText {
                            visible: root.renaming !== root.chosen?.id
                            Layout.fillWidth: true
                            text: root.confirming ? Translation.tr("Remove “%1”?").arg(root.chosen?.name ?? "") : (root.chosen?.name ?? "")
                            font.pixelSize: IrisStyle.typeLabel
                            font.weight: IrisStyle.weight(Font.DemiBold)
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            visible: root.renaming === root.chosen?.id
                            Layout.fillWidth: true
                            implicitHeight: Math.round(30 * root.d)
                            radius: IrisStyle.radiusRow
                            color: IrisStyle.fill
                            border.width: 1
                            border.color: IrisStyle.tintBorder(IrisStyle.accent)
                            TextInput {
                                id: nameField
                                anchors.fill: parent
                                anchors.leftMargin: 8 * root.d
                                anchors.rightMargin: 8 * root.d
                                verticalAlignment: TextInput.AlignVCenter
                                color: IrisStyle.text
                                selectionColor: IrisStyle.accentContainer
                                font.family: IrisStyle.fontMain
                                font.pixelSize: IrisStyle.typeLabel
                                maximumLength: 32
                                clip: true
                                onVisibleChanged: if (visible) { text = root.chosen?.name ?? ""; selectAll(); forceActiveFocus() }
                                Keys.onReturnPressed: root.commitRename()
                                Keys.onEscapePressed: root.renaming = ""
                            }
                        }
                    }

                    IrisText {
                        Layout.fillWidth: true
                        text: root.summary(root.chosen)
                        color: IrisStyle.subtext
                        font.pixelSize: IrisStyle.typeMeta
                        wrapMode: Text.WordWrap
                    }
                    IrisText {
                        Layout.fillWidth: true
                        text: Translation.tr("%1 · measured %2").arg(root.chosen?.description || root.chosen?.device || "").arg(root.chosen?.created ?? "")
                        color: IrisStyle.muted
                        font.pixelSize: IrisStyle.typeMeta
                        elide: Text.ElideRight
                    }

                    RowLayout {
                        Layout.topMargin: 4 * root.d
                        spacing: 6 * root.d
                        IrisButton {
                            visible: root.renaming === root.chosen?.id
                            text: Translation.tr("Done")
                            emphasized: true
                            buttonRadius: height / 2
                            onClicked: root.commitRename()
                        }
                        IrisButton {
                            visible: root.renaming === root.chosen?.id
                            text: Translation.tr("Cancel")
                            quiet: true
                            buttonRadius: height / 2
                            onClicked: root.renaming = ""
                        }
                        IrisButton {
                            visible: root.renaming !== root.chosen?.id && !root.confirming
                            text: Translation.tr("Rename")
                            quiet: true
                            buttonRadius: height / 2
                            onClicked: root.rename(root.chosen?.id ?? "")
                        }
                        IrisButton {
                            visible: root.renaming !== root.chosen?.id && !root.confirming
                            text: Translation.tr("Measure again")
                            quiet: true
                            buttonRadius: height / 2
                            enabled: !AudioEngine.busy && (root.voice || root.sink.length > 0)
                            onClicked: root.voice ? AudioEngine.probeMic(root.chosen?.id ?? "")
                                : AudioEngine.probeOutput(root.sink, root.chosen?.id ?? "")
                        }
                        IrisButton {
                            visible: root.renaming !== root.chosen?.id && !root.confirming
                            text: Translation.tr("Remove")
                            quiet: true
                            buttonRadius: height / 2
                            onClicked: root.confirming = true
                        }
                        IrisButton {
                            visible: root.confirming
                            text: Translation.tr("Cancel")
                            quiet: true
                            buttonRadius: height / 2
                            onClicked: root.confirming = false
                        }
                        IrisButton {
                            visible: root.confirming
                            text: Translation.tr("Remove")
                            danger: true
                            emphasized: true
                            buttonRadius: height / 2
                            enabled: !AudioEngine.busy
                            onClicked: {
                                root.confirming = false
                                AudioEngine.forgetTuned(root.chosen?.id ?? "", root.pipe)
                            }
                        }
                    }
                }
            }
        }
    }

    function commitRename(): void {
        const next = nameField.text.trim()
        if (next.length > 0 && next !== root.chosen?.name) {
            AudioEngine.error = ""
            AudioEngine.renameTuned(root.chosen?.id ?? "", next, root.pipe)
        }
        root.renaming = ""
    }

    // What the test found, in words: how low it plays and how hard it works there, or why it was only named.
    function summary(output: var): string {
        if (!output) return ""
        if (root.voice) return root.voiceSummary(output)
        if (!output.measured) {
            return output.reason === "headphones"
                ? Translation.tr("Headphones are named, not measured: the microphone cannot hear them. Sounds are kept gentler at the ear, peaks held.")
                : output.reason === "no_mic"
                ? Translation.tr("No microphone to listen with, so it is tuned from the kind of output it is.")
                : Translation.tr("The microphone barely heard the test, so it is tuned from the kind of output it is. Turn the volume up and measure again.")
        }
        const parts = [Translation.tr("Plays down to %1 Hz").arg(Math.round(output.low))]
        if (Number(output.high) < 14000) parts.push(Translation.tr("its top fades at %1 kHz").arg((Number(output.high) / 1000).toFixed(1)))
        if (Number(output.strain) >= 0.35) parts.push(Translation.tr("strains in the low end, so it is protected"))
        return parts.join(" · ")
    }

    // What the test heard of the voice: its pitch, the room against the speech, and the input level it set.
    function voiceSummary(input: var): string {
        if (!input.measured)
            return Translation.tr("It did not hear enough speech. Measure again and keep talking the whole time.")
        const parts = []
        if (Number(input.pitch) > 0) parts.push(Translation.tr("Voice around %1 Hz").arg(Math.round(input.pitch)))
        parts.push(Translation.tr("speech %1 dB over the room").arg(Math.round(Number(input.snr))))
        if (input.volume && input.volumeWas && input.volume !== input.volumeWas)
            parts.push(Translation.tr("input level %1 % → %2 %").arg(input.volumeWas).arg(input.volume))
        else if (input.clipped)
            parts.push(Translation.tr("it clips: turn the input level down"))
        return parts.join(" · ")
    }
}
