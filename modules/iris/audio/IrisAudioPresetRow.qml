pragma ComponentBehavior: Bound

import QtQuick
import qs.services
import qs.services.deferred
import qs.modules.common.widgets
import qs.modules.iris.components
import qs.modules.iris.style
import qs.modules.iris.settings

// A sound in a list: its mark, its name and a word on it, a check while it plays. One of the person's own also renames
// in place, asks before it is deleted and, on the output, exports; the list holding it keeps which row does what.
MouseArea {
    id: row
    readonly property real d: IrisStyle.density
    required property string name
    property string glyph: "tune"
    property string tintName: "purple"
    property string line: ""
    property bool own: false
    property bool exportable: false
    property bool last: false
    property bool current: false
    property bool editing: false
    property bool asking: false
    signal activated()
    signal renameRequested()
    signal deleteRequested()
    signal exportRequested()
    signal renamed(string next)
    signal editCancelled()
    signal deleteConfirmed()
    signal deleteCancelled()
    readonly property bool tools: row.own && row.containsMouse && !row.editing && !row.asking

    width: parent ? parent.width : 0
    height: Math.round(46 * row.d)
    hoverEnabled: true
    cursorShape: row.editing ? Qt.IBeamCursor : Qt.PointingHandCursor
    enabled: !AudioEngine.busy || row.editing
    Accessible.role: Accessible.Button
    Accessible.name: row.own ? row.name : Translation.tr(row.name)
    onClicked: if (!row.editing && !row.asking) row.activated()

    function commitRename(): void {
        const next = renameField.text.trim()
        if (next.length > 0 && next !== row.name) row.renamed(next)
        else row.editCancelled()
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 3 * row.d
        radius: IrisStyle.radiusRow
        color: row.pressed ? IrisStyle.fillActive : row.containsMouse ? IrisStyle.fillQuiet : "transparent"
        Behavior on color { ColorAnimation { duration: IrisStyle.duration(110); easing.type: IrisStyle.feedbackEasing } }
    }
    Rectangle {
        visible: !row.last
        anchors.bottom: parent.bottom
        anchors.left: label.left
        anchors.right: parent.right
        height: 1
        color: IrisStyle.hairline
    }
    IrisSquircle {
        id: mark
        anchors.left: parent.left
        anchors.leftMargin: 14 * row.d
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(26 * row.d)
        height: width
        tint: IrisStyle.identityColor(row.tintName)
        glyph: row.glyph
    }
    IrisText {
        id: label
        visible: !row.editing
        anchors.left: mark.right
        anchors.leftMargin: 12 * row.d
        anchors.right: summary.visible ? summary.left : tools.left
        anchors.rightMargin: 8 * row.d
        anchors.verticalCenter: parent.verticalCenter
        text: row.asking ? Translation.tr("Delete “%1”?").arg(row.name) : (row.own ? row.name : Translation.tr(row.name))
        font.pixelSize: IrisStyle.typeLabel
        font.weight: IrisStyle.weight(row.current ? Font.DemiBold : Font.Medium)
        elide: Text.ElideRight
    }
    Rectangle {
        visible: row.editing
        anchors.left: mark.right
        anchors.leftMargin: 8 * row.d
        anchors.right: tools.left
        anchors.rightMargin: 8 * row.d
        anchors.verticalCenter: parent.verticalCenter
        height: Math.round(30 * row.d)
        radius: IrisStyle.radiusRow
        color: IrisStyle.fill
        border.width: 1
        border.color: IrisStyle.tintBorder(IrisStyle.accent)
        TextInput {
            id: renameField
            anchors.fill: parent
            anchors.leftMargin: 8 * row.d
            anchors.rightMargin: 8 * row.d
            verticalAlignment: TextInput.AlignVCenter
            color: IrisStyle.text
            selectionColor: IrisStyle.accentContainer
            font.family: IrisStyle.fontMain
            font.pixelSize: IrisStyle.typeLabel
            maximumLength: 64
            clip: true
            onVisibleChanged: if (visible) { text = row.name; selectAll(); forceActiveFocus() }
            Keys.onReturnPressed: row.commitRename()
            Keys.onEscapePressed: row.editCancelled()
        }
    }
    IrisText {
        id: summary
        visible: row.line.length > 0 && !row.editing && !row.asking
        anchors.right: tools.left
        anchors.rightMargin: 10 * row.d
        anchors.verticalCenter: parent.verticalCenter
        text: row.line
        color: IrisStyle.muted
        font.pixelSize: IrisStyle.typeLabel
    }
    Row {
        id: tools
        anchors.right: parent.right
        anchors.rightMargin: 12 * row.d
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2 * row.d
        MaterialSymbol {
            visible: row.current && !row.editing && !row.asking && !(row.own && row.containsMouse)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(18 * row.d)
            text: "check"
            iconSize: Math.round(18 * row.d)
            color: IrisStyle.accent
        }
        IrisIconButton {
            visible: row.tools && row.exportable
            materialIcon: "ios_share"
            Accessible.name: Translation.tr("Export")
            onClicked: row.exportRequested()
        }
        IrisIconButton {
            visible: row.tools
            materialIcon: "edit"
            Accessible.name: Translation.tr("Rename")
            onClicked: row.renameRequested()
        }
        IrisIconButton {
            visible: row.tools
            materialIcon: "delete"
            Accessible.name: Translation.tr("Delete")
            onClicked: row.deleteRequested()
        }
        IrisButton {
            visible: row.editing
            text: Translation.tr("Done")
            onClicked: row.commitRename()
        }
        IrisButton {
            visible: row.asking
            text: Translation.tr("Cancel")
            quiet: true
            onClicked: row.deleteCancelled()
        }
        IrisButton {
            visible: row.asking
            text: Translation.tr("Delete")
            danger: true
            emphasized: true
            onClicked: row.deleteConfirmed()
        }
    }
}
