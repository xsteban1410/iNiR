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

// The Auto Audio Engine: measures the output playing now and keeps it as a tuned output, so every built-in sound fits
// it. The Auto Microphone Engine (pipe "input") listens to the person talking instead, and fits the microphone's sounds
// to that voice. Five are kept at most; asking for a sixth first asks which one to let go, then measures.
Rectangle {
    id: root
    property string pipe: "output"
    readonly property bool voice: root.pipe === "input"
    readonly property bool mine: AudioEngine.probing && AudioEngine.probePipe === root.pipe
    readonly property real d: IrisStyle.density
    // Empty when the device behind EasyEffects is not known here: the helper then asks PipeWire which it is.
    readonly property string sink: AudioEngine.outputSink
    readonly property bool full: AudioEngine.tunedList(root.pipe).length >= AudioEngine.outputsMax
    property bool choosing: false
    property bool resume: false
    property real progress: 0

    function start(): void {
        if (root.full) {
            root.choosing = true
            return
        }
        AudioEngine.error = ""
        stage.stop()
        root.progress = 0.02
        if (root.voice) AudioEngine.probeMic("")
        else AudioEngine.probeOutput(root.sink, "")
    }

    // One room freed while choosing: the test the person asked for goes on.
    Connections {
        target: AudioEngine
        function onOutputsChanged(): void { root.resumeIfRoom() }
        function onInputsChanged(): void { root.resumeIfRoom() }
        function onProbeStageChanged(): void {
            if (AudioEngine.probePipe !== root.pipe) return
            stage.stop()
            const timed = { sweep: [0.08, 0.88], quiet: [0.04, 0.2], speak: [0.2, 0.9] }[AudioEngine.probeStage]
            if (timed) {
                stage.from = timed[0]
                stage.to = timed[1]
                stage.duration = Math.max(1000, AudioEngine.probeSeconds * 1000)
                stage.start()
            } else {
                root.progress = AudioEngine.probeStage === "analyse" ? 0.94 : 0.02
            }
        }
    }
    function resumeIfRoom(): void {
        if (!root.resume || root.full) return
        root.resume = false
        root.choosing = false
        root.start()
    }
    NumberAnimation {
        id: stage
        target: root
        property: "progress"
    }

    implicitHeight: body.implicitHeight + Math.round(28 * root.d)
    radius: IrisStyle.radiusTile
    color: IrisStyle.readingCard

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 14 * root.d
        anchors.rightMargin: 14 * root.d
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10 * root.d

        RowLayout {
            Layout.fillWidth: true
            spacing: 12 * root.d
            IrisSquircle {
                Layout.preferredWidth: Math.round(26 * root.d)
                Layout.preferredHeight: Math.round(26 * root.d)
                tint: root.voice ? IrisStyle.identity.orange : IrisStyle.identity.pink
                glyph: root.voice ? "record_voice_over" : "auto_awesome"
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                IrisText {
                    Layout.fillWidth: true
                    text: root.voice ? Translation.tr("Auto Microphone Engine") : Translation.tr("Auto Audio Engine")
                    font.pixelSize: IrisStyle.typeLabel
                    font.weight: IrisStyle.weight(Font.DemiBold)
                    elide: Text.ElideRight
                }
                IrisText {
                    Layout.fillWidth: true
                    text: root.mine ? AudioEngine.probeDetail(AudioEngine.probeStage)
                        : root.voice ? Translation.tr("Listens to you talk and fits every microphone sound to your voice")
                        : Translation.tr("Measures %1 and fits every built-in sound to it").arg(Audio.friendlyDeviceName(AudioEngine.outputDevice))
                    color: IrisStyle.muted
                    font.pixelSize: IrisStyle.typeMeta
                    elide: Text.ElideRight
                }
            }
            IrisButton {
                visible: !root.mine && !root.choosing
                text: root.voice ? Translation.tr("Tune my voice") : Translation.tr("Tune this output")
                emphasized: true
                buttonRadius: height / 2
                enabled: !AudioEngine.busy
                onClicked: root.start()
            }
        }

        // The test's progress: the sweep's own length, the moments around it held.
        Item {
            visible: root.mine
            Layout.fillWidth: true
            implicitHeight: Math.round(8 * root.d)
            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: IrisStyle.fillQuiet
            }
            Rectangle {
                width: parent.width * root.progress
                height: parent.height
                radius: height / 2
                color: root.voice ? IrisStyle.identity.orange : IrisStyle.identity.pink
            }
        }

        // Something to say while it listens: any speech works, and reading keeps it going without thinking.
        IrisText {
            visible: root.mine && root.voice && AudioEngine.probeStage === "speak"
            Layout.fillWidth: true
            text: Translation.tr("“The quick brown fox jumps over the lazy dog. She sells seashells by the seashore, while six thick thistle sticks shake in the wind. Peter Piper picked a peck of pickled peppers, and that is plenty for today.”")
            color: IrisStyle.text
            font.pixelSize: IrisStyle.typeBody
            wrapMode: Text.WordWrap
        }

        IrisText {
            visible: !root.mine && !root.choosing
            Layout.fillWidth: true
            text: root.voice ? Translation.tr("A moment of quiet, then about ten seconds of you talking; nothing is recorded. If your microphone clips or is too quiet, its input level is set right too. Name each one, so a headset and the built-in microphone never write over each other.")
                : Translation.tr("A five-second sweep plays at your volume while the microphone listens; nothing is recorded. Headphones are named, not measured. Name each one, so speakers and headphones on the same output never write over each other.")
            color: IrisStyle.muted
            font.pixelSize: IrisStyle.typeMeta
            wrapMode: Text.WordWrap
        }

        // Five tuned outputs already: which one goes, so this one can be measured.
        ColumnLayout {
            visible: root.choosing
            Layout.fillWidth: true
            spacing: 4 * root.d
            IrisText {
                Layout.fillWidth: true
                text: (root.voice ? Translation.tr("%1 microphones are tuned, as many as it keeps. Remove one to tune this one:")
                    : Translation.tr("%1 outputs are tuned, as many as it keeps. Remove one to tune this one:")).arg(AudioEngine.outputsMax)
                color: IrisStyle.subtext
                font.pixelSize: IrisStyle.typeMeta
                wrapMode: Text.WordWrap
            }
            Repeater {
                model: AudioEngine.tunedList(root.pipe)
                RowLayout {
                    id: choice
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.round(38 * root.d)
                    spacing: 10 * root.d
                    MaterialSymbol {
                        text: root.voice ? "mic" : choice.modelData.kind === "headphones" ? "headphones" : "speaker"
                        iconSize: Math.round(18 * root.d)
                        color: IrisStyle.subtext
                    }
                    IrisText {
                        Layout.fillWidth: true
                        text: Translation.tr("%1 · %2").arg(choice.modelData.name).arg(choice.modelData.created ?? "")
                        font.pixelSize: IrisStyle.typeLabel
                        elide: Text.ElideRight
                    }
                    IrisButton {
                        text: Translation.tr("Remove")
                        danger: true
                        quiet: true
                        buttonRadius: height / 2
                        enabled: !AudioEngine.busy
                        onClicked: {
                            root.resume = true
                            AudioEngine.forgetTuned(choice.modelData.id, root.pipe)
                        }
                    }
                }
            }
            IrisButton {
                Layout.alignment: Qt.AlignRight
                text: Translation.tr("Cancel")
                quiet: true
                buttonRadius: height / 2
                onClicked: {
                    root.resume = false
                    root.choosing = false
                }
            }
        }
    }
}
