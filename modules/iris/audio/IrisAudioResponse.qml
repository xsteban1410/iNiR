pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.services
import qs.modules.common
import qs.modules.iris.components
import qs.modules.iris.style

// What a tuned output plays: its measured response (a quiet line, 0 dB at its mids), the correction the built-in
// sounds carry on it (the equalizer's own curve), and the low end it cannot play, shaded.
Item {
    id: root
    // [[frequency, dB]…] as output_probe.py measured it; empty when the output was named, not heard.
    property var curve: []
    property var correction: []
    property var low: null
    property real range: 18
    readonly property real lowHz: 20
    readonly property real highHz: 20000
    readonly property real d: IrisStyle.density
    readonly property var bands: [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        .map((f, i) => ({ frequency: f, gain: Number(root.correction[i] ?? 0) }))

    function xOf(f: real): real {
        return Math.log(f / root.lowHz) / Math.log(root.highHz / root.lowHz) * root.width
    }
    readonly property var points: root.curve.map(point => Qt.point(root.xOf(Number(point[0])),
        root.height / 2 - Math.max(-1, Math.min(1, Number(point[1]) / root.range)) * root.height / 2 * 0.9))

    Rectangle {
        visible: root.low !== null && root.low !== undefined
        width: Math.max(0, Math.round(root.xOf(Number(root.low ?? root.lowHz))))
        height: parent.height
        color: IrisStyle.fillQuiet
        IrisText {
            visible: parent.width > 40 * root.d
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4 * root.d
            anchors.horizontalCenter: parent.horizontalCenter
            text: Translation.tr("Out of reach")
            color: IrisStyle.muted
            font.pixelSize: IrisStyle.typeCaption
        }
    }
    IrisAudioCurve {
        anchors.fill: parent
        bands: root.bands
        range: root.range
        quiet: true
    }
    Shape {
        visible: root.points.length > 1
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: Math.max(1, 1.5 * root.d)
            strokeColor: IrisStyle.subtext
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: root.points.length > 0 ? root.points[0].x : 0
            startY: root.points.length > 0 ? root.points[0].y : root.height / 2
            PathPolyline { path: root.points }
        }
    }
}
