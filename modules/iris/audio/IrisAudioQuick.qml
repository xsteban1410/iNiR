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

// The Audio Engine at a glance: the sound playing now, effects on or off, a few sounds and the microphone's a tap
// away. The Island's Sound page and the Audio Engine bubble's card both show it; everything else is one step further,
// in the Audio Engine itself (openRequested).
ColumnLayout {
    id: root
    // Holds the helper only while it is on screen: a page left behind a collapsed Island must not keep it running.
    property bool live: true
    signal openRequested()

    readonly property real d: IrisStyle.density
    readonly property var quick: {
        const picks = ["Default", "Voice", "Bass", "Pop", "Rock"].concat(AudioEngine.presets.slice(0, 3))
        const now = AudioEngine.active
        return now.length > 0 && !picks.includes(now) ? picks.concat([now]) : picks
    }
    readonly property var micSounds: AudioEngine.mic?.builtins ?? []
    spacing: 12 * root.d

    property bool held: false
    function hold(on: bool): void {
        if (on === root.held) return
        root.held = on
        if (on) AudioEngine.acquire()
        else AudioEngine.release()
    }
    onLiveChanged: root.hold(root.live)
    Component.onCompleted: root.hold(root.live)
    Component.onDestruction: root.hold(false)

    RowLayout {
        Layout.fillWidth: true
        spacing: 12 * root.d
        IrisSquircle {
            Layout.preferredWidth: Math.round(40 * root.d)
            Layout.preferredHeight: Math.round(40 * root.d)
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
                    : !AudioEngine.installed ? Translation.tr("EasyEffects is not installed")
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
            onClicked: root.openRequested()
        }
    }

    Flow {
        Layout.fillWidth: true
        visible: AudioEngine.running
        spacing: Math.round(6 * root.d)
        Repeater {
            model: root.quick
            Chip {
                required property var modelData
                name: modelData
                selected: AudioEngine.active === modelData
                onClicked: AudioEngine.applyPreset(modelData)
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: AudioEngine.running && root.micSounds.length > 0
        spacing: 8 * root.d
        IrisText {
            text: Translation.tr("Microphone")
            role: IrisText.Meta
            font.weight: IrisStyle.weight(Font.DemiBold)
        }
        Flow {
            Layout.fillWidth: true
            spacing: Math.round(6 * root.d)
            Repeater {
                model: root.micSounds
                Chip {
                    required property var modelData
                    name: modelData
                    selected: (AudioEngine.mic?.active ?? "") === modelData
                    onClicked: AudioEngine.applyMic(modelData)
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

    component Chip: MouseArea {
        id: chip
        property string name: ""
        property bool selected: false
        width: chipLabel.implicitWidth + Math.round(24 * root.d)
        height: Math.round(30 * root.d)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: !AudioEngine.busy
        Accessible.role: Accessible.RadioButton
        Accessible.name: Translation.tr(chip.name)
        Accessible.checked: chip.selected
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
            text: Translation.tr(chip.name)
            font.pixelSize: IrisStyle.typeLabel
            font.weight: IrisStyle.weight(chip.selected ? Font.DemiBold : Font.Medium)
        }
    }
}
