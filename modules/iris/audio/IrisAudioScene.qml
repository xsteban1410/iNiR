pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.iris.components
import qs.modules.iris.style
import qs.modules.iris.settings

// What is heard now, at a glance: the equalizer's curve over the core chain, each effect lit when it is on.
Item {
    id: root
    readonly property real d: IrisStyle.density
    readonly property var eq: AudioEngine.module("equalizer")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12 * root.d
        spacing: 10 * root.d

        IrisAudioCurve {
            Layout.fillWidth: true
            Layout.fillHeight: true
            bands: root.eq?.bands ?? []
            active: root.eq?.enabled ?? false
        }

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.round(22 * root.d)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: Math.round(11 * root.d)
                width: parent.width - Math.round(22 * root.d)
                height: 1
                color: IrisStyle.hairlineStrong
            }
            RowLayout {
                id: chain
                anchors.fill: parent
                spacing: 0
                Repeater {
                    model: IrisAudioModules.core
                    Item {
                        id: link
                        required property var modelData
                        required property int index
                        readonly property var section: IrisAudioModules.section(link.modelData)
                        readonly property bool on: AudioEngine.module(link.modelData)?.enabled ?? false
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        IrisSquircle {
                            anchors.horizontalCenter: link.index === 0 ? undefined : link.index === IrisAudioModules.core.length - 1 ? undefined : parent.horizontalCenter
                            anchors.left: link.index === 0 ? parent.left : undefined
                            anchors.right: link.index === IrisAudioModules.core.length - 1 ? parent.right : undefined
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(22 * root.d)
                            height: width
                            tint: link.on ? IrisStyle.identityColor(link.section?.tint ?? "gray") : IrisStyle.identity.gray
                            glyph: link.section?.glyph ?? "tune"
                            opacity: link.on ? 1 : 0.4
                            Behavior on opacity { NumberAnimation { duration: IrisStyle.duration(160); easing.type: IrisStyle.feedbackEasing } }
                        }
                    }
                }
            }
        }
    }
}
