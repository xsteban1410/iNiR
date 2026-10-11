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

// Every other EasyEffects effect, by what it is for, to put at the end of the chain. Adding one changes the chain,
// which EasyEffects only takes as a whole: the sound may drop for an instant.
ColumnLayout {
    id: root
    readonly property real d: IrisStyle.density
    signal added(string kind)

    spacing: 6 * root.d

    Repeater {
        model: IrisAudioModules.groups
        ColumnLayout {
            id: block
            required property var modelData
            readonly property var kinds: AudioEngine.extraKinds.filter(entry => IrisAudioModules.lookOf(entry.kind).group === block.modelData.id)
            visible: block.kinds.length > 0
            Layout.fillWidth: true
            spacing: 6 * root.d

            IrisText {
                Layout.leftMargin: 16 * root.d
                Layout.topMargin: 10 * root.d
                text: Translation.tr(block.modelData.title)
                color: IrisStyle.label
                font.family: IrisStyle.fontTitle
                font.pixelSize: IrisStyle.typeMeta
                font.weight: IrisStyle.weight(Font.DemiBold)
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: kindColumn.implicitHeight
                radius: IrisStyle.radiusTile
                color: IrisStyle.readingCard
                Column {
                    id: kindColumn
                    width: parent.width
                    Repeater {
                        model: block.kinds
                        MouseArea {
                            id: row
                            required property var modelData
                            required property int index
                            readonly property int count: AudioEngine.extras.filter(entry => entry.kind === row.modelData.kind).length
                            width: kindColumn.width
                            height: Math.round(46 * root.d)
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !AudioEngine.busy
                            Accessible.role: Accessible.Button
                            Accessible.name: Translation.tr("Add %1").arg(Translation.tr(row.modelData.label))
                            onClicked: { AudioEngine.addEffect(row.modelData.kind); root.added(row.modelData.kind) }
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 3 * root.d
                                radius: IrisStyle.radiusRow
                                color: row.pressed ? IrisStyle.fillActive : row.containsMouse ? IrisStyle.fillQuiet : "transparent"
                                Behavior on color { ColorAnimation { duration: IrisStyle.duration(110); easing.type: IrisStyle.feedbackEasing } }
                            }
                            Rectangle {
                                visible: row.index < block.kinds.length - 1
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
                                tint: IrisStyle.identityColor(block.modelData.tint)
                                glyph: IrisAudioModules.lookOf(row.modelData.kind).glyph
                            }
                            IrisText {
                                id: label
                                anchors.left: mark.right
                                anchors.leftMargin: 12 * root.d
                                anchors.right: inChain.left
                                anchors.rightMargin: 8 * root.d
                                anchors.verticalCenter: parent.verticalCenter
                                text: Translation.tr(row.modelData.label)
                                font.pixelSize: IrisStyle.typeLabel
                                font.weight: IrisStyle.weight(Font.Medium)
                                elide: Text.ElideRight
                            }
                            IrisText {
                                id: inChain
                                anchors.right: plus.left
                                anchors.rightMargin: 10 * root.d
                                anchors.verticalCenter: parent.verticalCenter
                                visible: row.count > 0
                                text: row.count > 1 ? Translation.tr("%1 in the chain").arg(row.count) : Translation.tr("In the chain")
                                color: IrisStyle.muted
                                font.pixelSize: IrisStyle.typeLabel
                            }
                            MaterialSymbol {
                                id: plus
                                anchors.right: parent.right
                                anchors.rightMargin: 16 * root.d
                                anchors.verticalCenter: parent.verticalCenter
                                text: "add_circle"
                                iconSize: Math.round(20 * root.d)
                                color: row.containsMouse ? IrisStyle.accent : IrisStyle.muted
                            }
                        }
                    }
                }
            }
        }
    }
}
