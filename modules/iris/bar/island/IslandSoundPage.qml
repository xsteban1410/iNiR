pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.style
import qs.modules.iris.components
import qs.modules.iris.settings

// The Audio Engine at a glance: the sound playing now, effects on or bypassed, and a few sounds a tap away.
// Everything else is one step further, in the Audio Engine itself.
ColumnLayout {
    id: page
    required property Item island
    readonly property real d: IrisStyle.density
    readonly property var quick: ["Default", "Voice", "Bass", "Pop", "Rock"].concat(AudioEngine.presets.slice(0, 3))
    spacing: 12 * page.d

    Component.onCompleted: AudioEngine.acquire()
    Component.onDestruction: AudioEngine.release()

    RowLayout {
        Layout.fillWidth: true
        spacing: 12 * page.d
        IrisSquircle {
            Layout.preferredWidth: Math.round(40 * page.d)
            Layout.preferredHeight: Math.round(40 * page.d)
            tint: IrisStyle.identity.pink
            glyph: "graphic_eq"
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            IrisText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: AudioEngine.shownActive.length > 0 ? Translation.tr(AudioEngine.shownActive) : Translation.tr("No sound chosen")
                font.pixelSize: IrisStyle.typeBody
                font.weight: IrisStyle.weight(Font.DemiBold)
            }
            IrisText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: !AudioEngine.ready ? Translation.tr("Looking for EasyEffects…")
                    : !AudioEngine.running ? Translation.tr("EasyEffects is off")
                    : AudioEngine.bypass ? Translation.tr("Without effects")
                    : AudioEngine.modified ? Translation.tr("Changed from the preset")
                    : Translation.tr("Audio Engine")
                role: IrisText.Meta
            }
        }
        IrisSwitch {
            visible: AudioEngine.running
            on: !AudioEngine.bypass
            name: Translation.tr("Effects")
            onToggled: AudioEngine.setBypass(!AudioEngine.bypass)
        }
        IrisIconButton {
            materialIcon: "open_in_full"
            Accessible.name: Translation.tr("Open the Audio Engine")
            onClicked: {
                AudioEngine.lastSection = "presets"
                GlobalStates.openAudioEngine()
            }
        }
    }

    Flow {
        Layout.fillWidth: true
        visible: AudioEngine.running
        spacing: Math.round(6 * page.d)
        Repeater {
            model: page.quick
            MouseArea {
                id: chip
                required property var modelData
                readonly property bool selected: AudioEngine.active === chip.modelData
                width: chipLabel.implicitWidth + Math.round(24 * page.d)
                height: Math.round(30 * page.d)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                enabled: !AudioEngine.busy
                Accessible.role: Accessible.RadioButton
                Accessible.name: Translation.tr(chip.modelData)
                Accessible.checked: chip.selected
                onClicked: AudioEngine.applyPreset(chip.modelData)
                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: chip.selected ? IrisStyle.tintFillHover(IrisStyle.accent)
                        : chip.containsMouse ? IrisStyle.fillHover : IrisStyle.fillQuiet
                    Behavior on color { ColorAnimation { duration: IrisStyle.duration(120); easing.type: IrisStyle.feedbackEasing } }
                }
                IrisText {
                    id: chipLabel
                    anchors.centerIn: parent
                    text: Translation.tr(chip.modelData)
                    font.pixelSize: IrisStyle.typeLabel
                    font.weight: IrisStyle.weight(chip.selected ? Font.DemiBold : Font.Medium)
                }
            }
        }
    }

    IrisButton {
        visible: AudioEngine.ready && AudioEngine.installed && !AudioEngine.running
        Layout.alignment: Qt.AlignLeft
        text: AudioEngine.starting ? Translation.tr("Starting…") : Translation.tr("Start EasyEffects")
        emphasized: true
        buttonRadius: height / 2
        enabled: !AudioEngine.starting
        onClicked: AudioEngine.start()
    }
}
