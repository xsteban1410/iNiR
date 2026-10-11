pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.components
import qs.modules.iris.style

// The equalizer: its switch, how many bands (8 to 32), the bands themselves across one card, then its input gain.
ColumnLayout {
    id: root
    required property var entry

    readonly property real d: IrisStyle.density
    readonly property var bands: root.entry?.bands ?? []
    readonly property int count: Number(root.entry?.values?.numBands ?? root.bands.length)
    readonly property bool on: root.entry?.enabled ?? false
    readonly property real boost: Math.max(0, ...root.bands.map(band => Number(band.gain ?? 0)))
    readonly property bool limiterOn: AudioEngine.module("limiter")?.enabled ?? false

    spacing: 14 * root.d

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: headColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: headColumn
            width: parent.width
            IrisAudioRow {
                width: parent.width
                param: ({ kind: "switch", label: "Equalizer",
                          description: AudioEngine.missing.includes("lsp") ? "Needs the LSP plugins, which are not installed." : "" })
                value: root.entry?.enabled ?? false
                enabled: !AudioEngine.missing.includes("lsp")
                onEdited: value => AudioEngine.setEnabled("equalizer", value)
            }
            IrisAudioRow {
                width: parent.width
                enabled: root.on
                opacity: root.on ? 1 : 0.4
                param: ({ kind: "switch", label: "Keep headroom",
                          description: "Lowers the input as far as the highest band rises, so a boost never clips." })
                value: AudioEngine.headroom
                onEdited: value => AudioEngine.setHeadroom(value)
            }
            IrisAudioRow {
                width: parent.width
                last: true
                enabled: root.on
                opacity: root.on ? 1 : 0.4
                param: ({ kind: "choice", label: "Bands", description: "More bands reach finer details of the tone.",
                          choices: AudioEngine.bandCounts.map(n => ({ value: n, label: String(n) })) })
                value: root.count
                onEdited: value => AudioEngine.setBandCount(value)
            }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: Math.round(300 * root.d)
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        IrisAudioEqGraph {
            anchors.fill: parent
            enabled: root.on
            anchors.margins: IrisStyle.concentricPad(IrisStyle.radiusTile, 8 * root.d)
            bands: root.bands
            active: root.entry?.enabled ?? false
            spectrum: AudioEngine.running
            onEdited: (index, gain) => AudioEngine.setBand(index, gain)
        }
    }

    // A boost with nothing after it to catch the peaks: the Limiter is the net under the headroom.
    Rectangle {
        visible: root.on && root.boost > 0 && !root.limiterOn
        Layout.fillWidth: true
        implicitHeight: Math.round(56 * root.d)
        radius: IrisStyle.radiusTile
        color: IrisStyle.tintFill(IrisStyle.secondaryAccent)
        MaterialSymbol {
            id: hintGlyph
            anchors.left: parent.left
            anchors.leftMargin: 16 * root.d
            anchors.verticalCenter: parent.verticalCenter
            text: "warning"
            iconSize: Math.round(18 * root.d)
            color: IrisStyle.secondaryAccent
        }
        IrisText {
            anchors.left: hintGlyph.right
            anchors.leftMargin: 10 * root.d
            anchors.right: hintButton.left
            anchors.rightMargin: 12 * root.d
            anchors.verticalCenter: parent.verticalCenter
            text: Translation.tr("Bands are boosted and the Limiter is off: loud passages can still clip.")
            font.pixelSize: IrisStyle.typeMeta
            wrapMode: Text.WordWrap
        }
        IrisButton {
            id: hintButton
            anchors.right: parent.right
            anchors.rightMargin: 12 * root.d
            anchors.verticalCenter: parent.verticalCenter
            text: Translation.tr("Turn on the Limiter")
            buttonRadius: height / 2
            onClicked: AudioEngine.setEnabled("limiter", true)
        }
    }

    Rectangle {
        Layout.fillWidth: true
        // Kept by headroom, the input gain follows the bands and is not set by hand.
        enabled: root.on && !AudioEngine.headroom
        opacity: enabled ? 1 : 0.4
        implicitHeight: gainColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: gainColumn
            width: parent.width
            Repeater {
                model: IrisAudioModules.params.equalizer
                IrisAudioRow {
                    required property var modelData
                    required property int index
                    width: gainColumn.width
                    param: modelData
                    last: index === IrisAudioModules.params.equalizer.length - 1
                    value: root.entry?.values?.[modelData.prop]
                    fallback: root.entry?.defaults?.[modelData.prop]
                    onEdited: value => AudioEngine.setValue("equalizer", modelData.prop, value)
                }
            }
        }
    }
}
