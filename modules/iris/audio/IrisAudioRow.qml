pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.iris.components
import qs.modules.iris.style

// One parameter of an effect, laid out like a Settings row: label and description left, the value on the title's line,
// the control right (switch) or under it (range, choices). A range is heard while it moves: unlike a setting it writes
// no config, so it is sent at most every 40 ms while dragging and once more on release.
Item {
    id: root
    required property var param
    property var value
    property bool last: false
    // Where a range returns on a double click on its knob: EasyEffects' own default for that parameter.
    property var fallback: undefined
    property bool resetting: false
    signal edited(var value)

    readonly property real d: IrisStyle.density
    readonly property bool log: root.param.scale === "log"
    readonly property real low: Number(root.param.min ?? 0)
    readonly property real high: Number(root.param.max ?? 1)
    property real dragValue: NaN
    readonly property var shownValue: Number.isFinite(root.dragValue) ? root.dragValue : root.value
    readonly property var choices: root.param.choices ?? []
    readonly property bool inlineChoice: root.param.kind === "choice" && root.choices.length <= 3
        && root.choices.every(choice => String(choice.label).length <= 11)

    function toUnit(value: real): real {
        const v = Math.max(root.low, Math.min(root.high, value))
        if (root.log) return Math.log(v / root.low) / Math.log(root.high / root.low)
        return (v - root.low) / Math.max(0.0001, root.high - root.low)
    }
    function fromUnit(unit: real): real {
        if (root.log) return Math.round(root.low * Math.pow(root.high / root.low, unit))
        const step = Number(root.param.step ?? 1)
        const raw = root.low + unit * (root.high - root.low)
        return Number((Math.round(raw / step) * step).toFixed(4))
    }

    implicitHeight: layout.implicitHeight + Math.round(22 * root.d)

    Rectangle {
        visible: !root.last
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 16 * root.d
        height: 1
        color: IrisStyle.hairline
    }

    ColumnLayout {
        id: layout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 16 * root.d
        anchors.rightMargin: 16 * root.d
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10 * root.d

        RowLayout {
            Layout.fillWidth: true
            spacing: 12 * root.d

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2 * root.d
                IrisText {
                    id: label
                    Layout.fillWidth: true
                    text: Translation.tr(root.param.label)
                    font.pixelSize: IrisStyle.typeLabel
                    font.weight: IrisStyle.weight(Font.Medium)
                    wrapMode: Text.WordWrap
                }
                IrisText {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: root.param.description ? Translation.tr(root.param.description) : ""
                    color: IrisStyle.muted
                    font.pixelSize: IrisStyle.typeMeta
                    wrapMode: Text.WordWrap
                }
            }

            IrisText {
                visible: root.param.kind === "range"
                Layout.alignment: Qt.AlignTop
                Layout.preferredHeight: label.implicitHeight
                verticalAlignment: Text.AlignVCenter
                text: IrisAudioModules.valueText(root.param, root.shownValue)
                color: IrisStyle.subtext
                font.features: ({ "tnum": 1 })
                font.pixelSize: IrisStyle.typeLabel
            }

            IrisSwitch {
                id: toggle
                visible: root.param.kind === "switch"
                on: Boolean(root.value)
                name: Translation.tr(root.param.label)
                onToggled: root.edited(!toggle.on)
            }

            Loader {
                active: root.inlineChoice
                visible: active
                Layout.preferredWidth: Math.round(Math.min(90 * root.choices.length, 270) * root.d)
                sourceComponent: segmentedComponent
            }
        }

        IrisScrubber {
            id: scrubber
            Layout.fillWidth: true
            Layout.preferredHeight: Math.round(22 * root.d)
            visible: root.param.kind === "range"
            knob: true
            Accessible.name: Translation.tr(root.param.label)
            stepSize: root.log ? 0.01 : Number(root.param.step ?? 1) / Math.max(0.0001, root.high - root.low)
            fillColor: IrisStyle.accent
            trackColor: IrisStyle.fill
            value: root.param.kind === "range" ? root.toUnit(Number(root.shownValue)) : 0
            onMoved: next => {
                const value = root.fromUnit(next)
                if (!scrubber.dragging) { if (value !== Number(root.value)) root.edited(value); return }
                if (value === root.dragValue) return
                root.dragValue = value
                if (!sendTimer.running) { root.edited(value); sendTimer.restart() }
            }
            onKnobDoubleClicked: {
                if (root.fallback === undefined) return
                // The press of the double click already moved it; the release that follows must not send that back.
                root.resetting = true
                sendTimer.stop()
                root.dragValue = NaN
                root.edited(Math.max(root.low, Math.min(root.high, Number(root.fallback))))
            }
            onDraggingChanged: if (!dragging) {
                sendTimer.stop()
                if (root.resetting) { root.resetting = false; root.dragValue = NaN; return }
                if (Number.isFinite(root.dragValue)) root.edited(root.dragValue)
                root.dragValue = NaN
            }
        }
        Timer {
            id: sendTimer
            interval: 40
            onTriggered: if (Number.isFinite(root.dragValue)) root.edited(root.dragValue)
        }

        Loader {
            Layout.fillWidth: true
            active: root.param.kind === "choice" && !root.inlineChoice
            visible: active
            sourceComponent: chipsComponent
        }
    }

    Component {
        id: segmentedComponent
        IrisSegmented {
            options: root.choices.map(choice => ({ value: choice.value, label: Translation.tr(choice.label) }))
            current: root.value
            accessibleName: Translation.tr(root.param.label)
            onPicked: value => root.edited(value)
        }
    }

    Component {
        id: chipsComponent
        Flow {
            spacing: Math.round(6 * root.d)
            Repeater {
                model: root.choices
                MouseArea {
                    id: chip
                    required property var modelData
                    readonly property bool selected: chip.modelData.value === root.value
                    width: chipLabel.implicitWidth + Math.round(24 * root.d)
                    height: Math.round(28 * root.d)
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    activeFocusOnTab: true
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: Translation.tr(root.param.label) + ": " + Translation.tr(chip.modelData.label)
                    Accessible.checked: chip.selected
                    Keys.onSpacePressed: root.edited(chip.modelData.value)
                    Keys.onReturnPressed: root.edited(chip.modelData.value)
                    onClicked: root.edited(chip.modelData.value)
                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: chip.selected ? IrisStyle.fillActive : chip.containsMouse ? IrisStyle.fillHover : IrisStyle.fillQuiet
                        border.width: chip.activeFocus ? 1 : 0
                        border.color: IrisStyle.accent
                        Behavior on color { ColorAnimation { duration: IrisStyle.duration(120); easing.type: IrisStyle.feedbackEasing } }
                    }
                    IrisText {
                        id: chipLabel
                        anchors.centerIn: parent
                        text: Translation.tr(chip.modelData.label)
                        font.pixelSize: IrisStyle.typeLabel
                        font.weight: IrisStyle.weight(chip.selected ? Font.DemiBold : Font.Normal)
                    }
                }
            }
        }
    }
}
