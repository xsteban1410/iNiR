pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.modules.common
import qs.modules.iris.components
import qs.modules.iris.style

// The equalizer's response as EasyEffects shapes it: each band a peaking filter (RBJ biquad at 48 kHz) with the
// constant-Q the engine gives it, summed in dB and drawn over 20 Hz–20 kHz on a log axis, ±12 dB.
Item {
    id: root
    property var bands: []
    property bool active: true
    property real range: 12

    // Behind the equalizer's bands the curve is a quiet echo of them; alone it is the picture.
    property bool quiet: false
    property bool grid: true
    property real headroom: 0.9
    property real lowHz: 20
    property real highHz: 20000
    readonly property int samples: 120
    readonly property real q: {
        const n = root.bands.length
        if (n < 2) return 1.41
        const first = Number(root.bands[0].frequency)
        const last = Number(root.bands[n - 1].frequency)
        const ratio = Math.pow(2, Math.log2(last / first) / (n - 1))
        return Math.sqrt(ratio) / (ratio - 1)
    }
    function peakDb(f: real, f0: real, gain: real): real {
        if (Math.abs(gain) < 0.01) return 0
        const fs = 48000
        const A = Math.pow(10, gain / 40)
        const w0 = 2 * Math.PI * f0 / fs
        const alpha = Math.sin(w0) / (2 * root.q)
        const b0 = 1 + alpha * A, b1 = -2 * Math.cos(w0), b2 = 1 - alpha * A
        const a0 = 1 + alpha / A, a1 = -2 * Math.cos(w0), a2 = 1 - alpha / A
        const w = 2 * Math.PI * f / fs
        const c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w)
        const nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        const dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * Math.log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
    readonly property var points: {
        const out = []
        for (let i = 0; i < root.samples; i++) {
            const t = i / (root.samples - 1)
            const f = root.lowHz * Math.pow(root.highHz / root.lowHz, t)
            let db = 0
            for (const band of root.bands) db += root.peakDb(f, Number(band.frequency), Number(band.gain))
            const y = Math.max(-1, Math.min(1, db / root.range))
            out.push(Qt.point(t * root.width, root.height / 2 - y * root.height / 2 * root.headroom))
        }
        return out
    }

    // Decade grid with its frequencies, and the 0 dB line.
    Repeater {
        model: root.grid ? [100, 1000, 10000] : []
        Item {
            id: decade
            required property var modelData
            x: Math.round(Math.log(decade.modelData / root.lowHz) / Math.log(root.highHz / root.lowHz) * root.width)
            height: root.height
            Rectangle {
                width: 1
                height: parent.height
                color: IrisStyle.hairline
            }
            IrisText {
                x: Math.round(4 * IrisStyle.density)
                y: 0
                text: decade.modelData >= 1000 ? (decade.modelData / 1000) + "k" : String(decade.modelData)
                color: IrisStyle.muted
                font.pixelSize: IrisStyle.typeCaption
                font.features: ({ "tnum": 1 })
            }
        }
    }
    Rectangle {
        visible: root.grid
        y: Math.round(root.height / 2)
        width: root.width
        height: 1
        color: IrisStyle.hairlineStrong
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: !root.active ? IrisStyle.fillQuiet : root.quiet ? IrisStyle.tintFill(IrisStyle.accent) : IrisStyle.tintFillHover(IrisStyle.accent)
            startX: 0
            startY: root.height / 2
            PathPolyline { path: root.points }
            PathLine { x: root.width; y: root.height / 2 }
            PathLine { x: 0; y: root.height / 2 }
        }
        ShapePath {
            strokeWidth: Math.max(1.5, (root.quiet ? 1.5 : 2) * IrisStyle.density)
            strokeColor: !root.active ? IrisStyle.muted : root.quiet ? IrisStyle.tintBorder(IrisStyle.accent) : IrisStyle.accent
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: root.points.length > 0 ? root.points[0].x : 0
            startY: root.points.length > 0 ? root.points[0].y : root.height / 2
            PathPolyline { path: root.points }
        }
    }
}
