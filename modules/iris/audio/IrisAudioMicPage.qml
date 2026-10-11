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

// The microphone's chain: a sound for what you are doing, then each of its effects as a captioned card that
// opens on its own switch. An effect that is off greys out its rows, as the output's do. The autotune's key, scale
// and style are not EasyEffects parameters: the helper spells them into its note switches and knobs.
ColumnLayout {
    id: root
    readonly property real d: IrisStyle.density
    readonly property var mic: AudioEngine.mic ?? ({})

    spacing: 6 * root.d

    component Caption: IrisText {
        Layout.leftMargin: 16 * root.d
        Layout.topMargin: 10 * root.d
        color: IrisStyle.label
        font.family: IrisStyle.fontTitle
        font.pixelSize: IrisStyle.typeMeta
        font.weight: IrisStyle.weight(Font.DemiBold)
    }

    Caption { text: Translation.tr("Sound for") }
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
                MouseArea {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property var look: IrisAudioModules.micLooks[row.modelData] ?? ({ glyph: "mic", tint: "gray", line: "" })
                    readonly property bool current: (root.mic.active ?? "") === row.modelData
                    width: soundColumn.width
                    height: Math.round(46 * root.d)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !AudioEngine.busy
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: Translation.tr(row.modelData)
                    Accessible.checked: row.current
                    onClicked: AudioEngine.applyMic(row.modelData)
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 3 * root.d
                        radius: IrisStyle.radiusRow
                        color: row.pressed ? IrisStyle.fillActive : row.containsMouse ? IrisStyle.fillQuiet : "transparent"
                        Behavior on color { ColorAnimation { duration: IrisStyle.duration(110); easing.type: IrisStyle.feedbackEasing } }
                    }
                    Rectangle {
                        visible: row.index < (root.mic.builtins ?? []).length - 1
                        anchors.bottom: parent.bottom
                        anchors.left: label.left
                        anchors.right: parent.right
                        height: 1
                        color: IrisStyle.hairline
                    }
                    IrisSquircle {
                        id: mark
                        anchors.left: parent.left
                        anchors.leftMargin: 14 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.round(26 * root.d)
                        height: width
                        tint: IrisStyle.identityColor(row.look.tint)
                        glyph: row.look.glyph
                    }
                    IrisText {
                        id: label
                        anchors.left: mark.right
                        anchors.leftMargin: 12 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        text: Translation.tr(row.modelData)
                        font.pixelSize: IrisStyle.typeLabel
                        font.weight: IrisStyle.weight(row.current ? Font.DemiBold : Font.Medium)
                    }
                    IrisText {
                        anchors.right: check.left
                        anchors.rightMargin: 10 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        text: Translation.tr(row.look.line)
                        color: IrisStyle.muted
                        font.pixelSize: IrisStyle.typeLabel
                    }
                    MaterialSymbol {
                        id: check
                        anchors.right: parent.right
                        anchors.rightMargin: 14 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.round(18 * root.d)
                        text: "check"
                        iconSize: Math.round(18 * root.d)
                        color: IrisStyle.accent
                        opacity: row.current ? 1 : 0
                    }
                }
            }
        }
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

            Caption { text: Translation.tr(block.modelData.title) }
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
