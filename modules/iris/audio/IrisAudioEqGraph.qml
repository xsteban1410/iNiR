pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.components
import qs.modules.iris.style

// The equalizer as one graph: a dB scale, the response EasyEffects will shape drawn behind, and every band standing
// where its frequency is heard, a thumb on a hairline. A band is heard while it moves (40 ms at most between sends);
// double-click returns it to 0 dB, the wheel moves it half a decibel.
Item {
    id: root
    property var bands: []
    property bool active: true
    property real range: 12
    // What is playing, behind the bands: the shell's shared Cava, only while the graph is shown and on.
    property bool spectrum: false
    signal edited(int index, real gain)

    readonly property real d: IrisStyle.density
    readonly property int count: root.bands.length
    readonly property bool dense: root.count > 16
    readonly property real lowHz: root.count > 0 ? Number(root.bands[0].frequency) / 1.5 : 20
    readonly property real highHz: root.count > 0 ? Number(root.bands[root.count - 1].frequency) * 1.5 : 20000
    readonly property real gutter: Math.round(34 * root.d)
    readonly property real labelHeight: Math.round(20 * root.d)
    property int hovered: -1
    property int dragged: -1
    property real dragGain: 0

    function xFor(frequency: real): real {
        return Math.log(frequency / root.lowHz) / Math.log(root.highHz / root.lowHz) * plot.width
    }
    function yFor(gain: real): real {
        return plot.height / 2 - Math.max(-1, Math.min(1, gain / root.range)) * plot.height / 2
    }
    function gainAt(y: real): real {
        const raw = (plot.height / 2 - y) / (plot.height / 2) * root.range
        return Math.max(-root.range, Math.min(root.range, Math.round(raw * 2) / 2))
    }
    function gainText(gain: real): string {
        const text = (gain > 0 ? "+" : "") + gain.toFixed(Math.abs(gain % 1) > 0 ? 1 : 0)
        return text.replace("-", "−")
    }
    function frequencyText(frequency: real): string {
        return frequency >= 1000 ? (frequency / 1000).toFixed(frequency % 1000 === 0 ? 0 : 1) + "k" : String(Math.round(frequency))
    }
    function shownGain(index: int): real {
        return index === root.dragged ? root.dragGain : Number(root.bands[index]?.gain ?? 0)
    }

    // The scale.
    Repeater {
        model: [12, 6, 0, -6, -12]
        IrisText {
            required property var modelData
            x: 0
            width: root.gutter - Math.round(8 * root.d)
            y: plot.y + root.yFor(modelData) - height / 2
            horizontalAlignment: Text.AlignRight
            text: root.gainText(modelData)
            color: modelData === 0 ? IrisStyle.subtext : IrisStyle.muted
            font.pixelSize: IrisStyle.typeCaption
            font.features: ({ "tnum": 1 })
        }
    }

    Item {
        id: plot
        // Off, the equalizer is out of the sound: the graph greys out and does not answer.
        opacity: root.active ? 1 : 0.45
        x: root.gutter
        y: Math.round(10 * root.d)
        width: root.width - root.gutter - Math.round(10 * root.d)
        height: root.height - y - root.labelHeight - Math.round(6 * root.d)

        Repeater {
            model: [12, 6, -6, -12]
            Rectangle {
                required property var modelData
                y: Math.round(root.yFor(modelData))
                width: plot.width
                height: 1
                color: IrisStyle.hairline
                opacity: Math.abs(modelData) === 12 ? 0.5 : 1
            }
        }
        Rectangle {
            y: Math.round(plot.height / 2)
            width: plot.width
            height: 1
            color: IrisStyle.hairlineStrong
        }

        CavaProcess {
            id: cava
            active: root.spectrum && root.active && root.visible
            sampleCount: 48
        }
        Row {
            anchors.bottom: parent.bottom
            width: parent.width
            height: parent.height
            spacing: Math.max(1, Math.round(2 * root.d))
            visible: cava.held
            Repeater {
                model: cava.points.length
                Rectangle {
                    required property int index
                    readonly property real level: Math.max(0, Math.min(1, Number(cava.points[index] ?? 0) / Math.max(1, cava.normalizationCeiling)))
                    anchors.bottom: parent.bottom
                    width: Math.max(1, (plot.width - (cava.points.length - 1) * parent.spacing) / Math.max(1, cava.points.length))
                    height: Math.max(1, level * plot.height)
                    radius: Math.min(width / 2, IrisStyle.radiusMicro)
                    color: IrisStyle.fillQuiet
                }
            }
        }

        IrisAudioCurve {
            anchors.fill: parent
            bands: root.bands
            active: root.active
            range: root.range
            lowHz: root.lowHz
            highHz: root.highHz
            headroom: 1
            grid: false
            quiet: true
        }

        Repeater {
            model: root.count
            Item {
                id: band
                required property int index
                readonly property real centre: root.xFor(Number(root.bands[band.index]?.frequency ?? 1000))
                readonly property real gain: root.shownGain(band.index)
                readonly property bool engaged: root.hovered === band.index || root.dragged === band.index
                readonly property real slot: plot.width / Math.max(1, root.count)
                x: band.centre - band.slot / 2
                width: band.slot
                height: plot.height

                // The band's line, and the stretch from 0 dB to where it stands.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(1, Math.round(2 * root.d))
                    height: parent.height
                    radius: width / 2
                    color: band.engaged ? IrisStyle.fillActive : IrisStyle.fill
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    readonly property real upper: Math.min(root.yFor(band.gain), plot.height / 2)
                    readonly property real lower: Math.max(root.yFor(band.gain), plot.height / 2)
                    y: upper
                    width: Math.round((root.dense ? 3 : 4) * root.d)
                    height: Math.max(0, lower - upper)
                    radius: width / 2
                    color: root.active ? IrisStyle.accent : IrisStyle.textTertiary
                }
                RectangularShadow {
                    anchors.fill: thumb
                    radius: thumb.radius
                    offset.y: root.d
                    blur: 3 * root.d
                    color: IrisStyle.shadow
                }
                Rectangle {
                    id: thumb
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.round(((root.dense ? 12 : 16) + (band.engaged ? 4 : 0)) * root.d)
                    height: width
                    radius: width / 2
                    y: root.yFor(band.gain) - height / 2
                    color: root.active ? IrisStyle.onTint : IrisStyle.textTertiary
                    Behavior on width { NumberAnimation { duration: IrisStyle.duration(120); easing.type: IrisStyle.feedbackEasing } }
                    Behavior on y {
                        enabled: root.dragged !== band.index
                        NumberAnimation { duration: IrisStyle.duration(140); easing.type: IrisStyle.feedbackEasing }
                    }
                }

                // What it is set to, over the thumb while it is pointed at or moved.
                Rectangle {
                    visible: band.engaged
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Math.max(-Math.round(6 * root.d), thumb.y - height - Math.round(6 * root.d))
                    z: 2
                    width: valueText.implicitWidth + Math.round(12 * root.d)
                    height: Math.round(20 * root.d)
                    radius: height / 2
                    color: IrisStyle.bodySurface
                    IrisText {
                        id: valueText
                        anchors.centerIn: parent
                        text: root.gainText(band.gain) + " dB"
                        font.pixelSize: IrisStyle.typeCaption
                        font.weight: IrisStyle.weight(Font.DemiBold)
                        font.features: ({ "tnum": 1 })
                    }
                }

                MouseArea {
                    id: pointer
                    anchors.fill: parent
                    enabled: root.active
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: Qt.SizeVerCursor
                    // The press of a double click moved the band; the release that follows must not send that back.
                    property bool resetting: false
                    // Where the thumb stood before each of the last two presses: a double click counts only on it.
                    property real heldAt: 0
                    property real heldBefore: 0
                    IrisWheelIntent { id: wheelIntent; hovered: pointer.containsMouse }
                    Accessible.role: Accessible.Slider
                    Accessible.name: root.frequencyText(Number(root.bands[band.index]?.frequency ?? 0)) + " Hz"
                    onContainsMouseChanged: {
                        if (containsMouse) root.hovered = band.index
                        else if (root.hovered === band.index) root.hovered = -1
                    }
                    onPressed: event => {
                        pointer.heldBefore = pointer.heldAt
                        pointer.heldAt = root.yFor(band.gain)
                        root.dragged = band.index
                        root.dragGain = root.gainAt(event.y)
                        root.edited(band.index, root.dragGain)
                        sendTimer.restart()
                    }
                    onPositionChanged: event => {
                        wheelIntent.track(event.x, event.y)
                        if (!pressed) return
                        const next = root.gainAt(event.y)
                        if (next === root.dragGain) return
                        root.dragGain = next
                        if (!sendTimer.running) { root.edited(band.index, next); sendTimer.restart() }
                    }
                    onReleased: {
                        sendTimer.stop()
                        if (!pointer.resetting) root.edited(band.index, root.dragGain)
                        pointer.resetting = false
                        root.dragged = -1
                    }
                    // Only on the thumb itself: back to 0 dB.
                    onDoubleClicked: event => {
                        if (Math.abs(event.y - pointer.heldBefore) > thumb.height) return
                        pointer.resetting = true
                        sendTimer.stop()
                        root.dragGain = 0
                        root.edited(band.index, 0)
                    }
                    onWheel: wheel => {
                        if (!wheelIntent.take(wheel)) return
                        const step = wheel.angleDelta.y > 0 ? 0.5 : wheel.angleDelta.y < 0 ? -0.5 : 0
                        if (step !== 0)
                            root.edited(band.index, Math.max(-root.range, Math.min(root.range, Number(root.bands[band.index]?.gain ?? 0) + step)))
                    }
                }
            }
        }
    }

    // Frequencies under their bands; when they crowd, every other one.
    Repeater {
        model: root.count
        IrisText {
            required property int index
            readonly property real frequency: Number(root.bands[index]?.frequency ?? 0)
            visible: !root.dense || index % 2 === 0
            x: plot.x + root.xFor(frequency) - width / 2
            y: plot.y + plot.height + Math.round(6 * root.d)
            text: root.frequencyText(frequency)
            color: root.hovered === index || root.dragged === index ? IrisStyle.text : IrisStyle.muted
            font.pixelSize: IrisStyle.typeCaption
            font.features: ({ "tnum": 1 })
        }
    }

    Timer {
        id: sendTimer
        interval: 40
        onTriggered: if (root.dragged >= 0) root.edited(root.dragged, root.dragGain)
    }
}
