pragma ComponentBehavior: Bound

import QtQuick
import qs.services
import qs.services.deferred
import qs.modules.common.widgets
import qs.modules.iris.style
import qs.modules.iris.components

// One choice among a few, as a pill: a sound, a device, a tuned output.
MouseArea {
    id: chip
    readonly property real d: IrisStyle.density
    property string name: ""
    property string glyph: ""
    property bool selected: false
    // A built-in name is looked up as a translation; a name the person gave, or one already translated, is shown as it is.
    property bool translated: false
    readonly property string shown: chip.translated ? Translation.tr(chip.name) : chip.name
    width: chipRow.implicitWidth + Math.round(24 * chip.d)
    height: Math.round(30 * chip.d)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    enabled: !AudioEngine.busy
    Accessible.role: Accessible.RadioButton
    Accessible.name: chip.shown
    Accessible.checked: chip.selected
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: chip.selected ? IrisStyle.tintFillHover(IrisStyle.accent)
            : chip.containsMouse ? IrisStyle.fillHover : IrisStyle.fillQuiet
        Behavior on color { ColorAnimation { duration: IrisStyle.duration(120); easing.type: IrisStyle.feedbackEasing } }
    }
    Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: 5 * chip.d
        MaterialSymbol {
            visible: chip.glyph.length > 0
            anchors.verticalCenter: parent.verticalCenter
            text: chip.glyph
            iconSize: Math.round(15 * chip.d)
            color: chip.selected ? IrisStyle.text : IrisStyle.subtext
        }
        IrisText {
            anchors.verticalCenter: parent.verticalCenter
            text: chip.shown
            font.pixelSize: IrisStyle.typeLabel
            font.weight: IrisStyle.weight(chip.selected ? Font.DemiBold : Font.Medium)
        }
    }
}
