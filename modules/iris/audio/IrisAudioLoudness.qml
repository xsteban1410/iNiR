pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.iris.components
import qs.modules.iris.style

// How loud what you hear is, the way Autogain measures it (EBU R128): short-term loudness against the target, the
// momentary level as a bar, and the integrated loudness and peak since the page opened. The meter records the output's
// monitor only while this card is on screen.
ColumnLayout {
    id: root
    // Autogain's target, in LUFS: the marker on the bar and what the difference is measured from.
    property real target: -16
    readonly property real d: IrisStyle.density
    // What you hear: the device itself, never EasyEffects' virtual sink (that is what goes into the effects). Audio.sink
    // resolves to the device behind it once PipeWire says which; until then there is nothing to measure.
    readonly property string sink: {
        const name = String(Audio.sink?.name ?? "")
        return name.startsWith("easyeffects_") ? "" : name
    }
    onSinkChanged: if (meter.running) root.reset()
    readonly property bool shown: root.visible && root.QsWindow.window?.visible === true

    property var momentary: null
    property var shortTerm: null
    property var integrated: null
    property var peak: null
    property string problem: ""
    readonly property var now: root.shortTerm ?? root.momentary
    // The bar runs from -40 LUFS (quiet speech) to 0.
    function place(value: real): real { return Math.max(0, Math.min(1, (value + 40) / 40)) }
    function reset(): void {
        root.momentary = null
        root.shortTerm = null
        root.integrated = null
        root.peak = null
        meter.running = false
        meter.running = Qt.binding(() => root.shown && root.sink.length > 0)
    }

    spacing: 6 * root.d

    Process {
        id: meter
        running: root.shown && root.sink.length > 0
        command: [Quickshell.shellPath("scripts/audio/loudness_meter.sh"), "--target", root.sink]
        stdout: SplitParser {
            onRead: line => {
                let event = null
                try { event = JSON.parse(line) } catch (e) { return }
                if (event.error) { root.problem = String(event.error); return }
                root.problem = ""
                root.momentary = event.momentary
                root.shortTerm = event.short
                root.integrated = event.integrated
                // The meter reports each moment's peak; the card keeps the highest since it opened.
                if (event.peak !== null && event.peak !== undefined)
                    root.peak = root.peak === null ? event.peak : Math.max(root.peak, event.peak)
            }
        }
        onRunningChanged: if (!running) {
            root.momentary = null
            root.shortTerm = null
        }
    }

    IrisText {
        Layout.leftMargin: 16 * root.d
        Layout.topMargin: 10 * root.d
        text: Translation.tr("Loudness now")
        color: IrisStyle.label
        font.family: IrisStyle.fontTitle
        font.pixelSize: IrisStyle.typeMeta
        font.weight: IrisStyle.weight(Font.DemiBold)
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: body.implicitHeight + Math.round(28 * root.d)
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard

        ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16 * root.d
            anchors.rightMargin: 16 * root.d
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10 * root.d

            RowLayout {
                Layout.fillWidth: true
                spacing: 10 * root.d
                IrisNumber {
                    text: root.now === null ? "—" : Number(root.now).toFixed(1)
                    pixelSize: IrisStyle.typeHeadline
                    weight: Font.DemiBold
                }
                IrisText {
                    Layout.alignment: Qt.AlignBaseline
                    text: "LUFS"
                    color: IrisStyle.muted
                    font.pixelSize: IrisStyle.typeMeta
                    font.weight: IrisStyle.weight(Font.DemiBold)
                }
                Item { Layout.fillWidth: true }
                IrisText {
                    text: root.problem === "numpy" ? Translation.tr("Needs NumPy in iNiR's Python environment")
                        : root.problem.length > 0 ? Translation.tr("The meter could not start")
                        : root.now === null ? Translation.tr("Silence")
                        : Math.abs(root.now - root.target) < 1 ? Translation.tr("On your target")
                        : root.now > root.target ? Translation.tr("%1 LU above your target").arg(Math.abs(root.now - root.target).toFixed(1))
                        : Translation.tr("%1 LU below your target").arg(Math.abs(root.now - root.target).toFixed(1))
                    color: root.problem.length > 0 ? IrisStyle.danger : IrisStyle.subtext
                    font.pixelSize: IrisStyle.typeMeta
                }
            }

            // The momentary level, with the target marked on it.
            Item {
                Layout.fillWidth: true
                implicitHeight: Math.round(10 * root.d)
                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: IrisStyle.fillQuiet
                }
                Rectangle {
                    width: parent.width * (root.momentary === null ? 0 : root.place(root.momentary))
                    height: parent.height
                    radius: height / 2
                    color: IrisStyle.identity.green
                }
                Rectangle {
                    x: Math.round(parent.width * root.place(root.target) - width / 2)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(2, Math.round(2 * root.d))
                    height: parent.height + Math.round(6 * root.d)
                    radius: width / 2
                    color: IrisStyle.text
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8 * root.d
                IrisText {
                    Layout.fillWidth: true
                    text: Translation.tr("Since this page opened: %1 LUFS · peak %2 dBFS")
                        .arg(root.integrated === null ? "—" : Number(root.integrated).toFixed(1))
                        .arg(root.peak === null ? "—" : Number(root.peak).toFixed(1))
                    color: IrisStyle.muted
                    font.pixelSize: IrisStyle.typeMeta
                    elide: Text.ElideRight
                }
                IrisButton {
                    text: Translation.tr("Reset")
                    quiet: true
                    buttonRadius: height / 2
                    enabled: meter.running
                    onClicked: root.reset()
                }
            }
        }
    }
}
