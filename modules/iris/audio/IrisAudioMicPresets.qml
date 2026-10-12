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

// The microphone's own presets: what the voice's chain holds now, saved under a name with every effect in it (the
// person's added ones too), loaded, renamed and deleted the way the output's are.
Rectangle {
    id: root
    readonly property real d: IrisStyle.density
    readonly property var names: AudioEngine.mic?.presets ?? []
    readonly property var info: AudioEngine.mic?.presetInfo ?? ({})
    property string renaming: ""
    property string confirming: ""

    implicitHeight: column.implicitHeight
    radius: IrisStyle.radiusTile
    color: IrisStyle.readingCard

    Column {
        id: column
        width: parent.width

        Repeater {
            model: root.names
            MouseArea {
                id: row
                required property var modelData
                readonly property string name: String(row.modelData)
                readonly property bool current: (AudioEngine.mic?.active ?? "") === row.name
                readonly property bool editing: root.renaming === row.name
                readonly property bool asking: root.confirming === row.name
                width: column.width
                height: Math.round(46 * root.d)
                hoverEnabled: true
                cursorShape: row.editing ? Qt.IBeamCursor : Qt.PointingHandCursor
                enabled: !AudioEngine.busy || row.editing
                Accessible.role: Accessible.Button
                Accessible.name: row.name
                onClicked: if (!row.editing && !row.asking) AudioEngine.loadMicPreset(row.name)
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 3 * root.d
                    radius: IrisStyle.radiusRow
                    color: row.pressed ? IrisStyle.fillActive : row.containsMouse ? IrisStyle.fillQuiet : "transparent"
                    Behavior on color { ColorAnimation { duration: IrisStyle.duration(110); easing.type: IrisStyle.feedbackEasing } }
                }
                Rectangle {
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
                    tint: IrisStyle.identity.orange
                    glyph: "tune"
                }
                IrisText {
                    id: label
                    visible: !row.editing
                    anchors.left: mark.right
                    anchors.leftMargin: 12 * root.d
                    anchors.right: tools.left
                    anchors.rightMargin: 8 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.asking ? Translation.tr("Delete “%1”?").arg(row.name)
                        : [row.name, root.info[row.name]?.base ? Translation.tr(root.info[row.name].base) : "",
                           Translation.tr("%1 on").arg(root.info[row.name]?.on ?? 0)].filter(part => part.length > 0).join(" · ")
                    font.pixelSize: IrisStyle.typeLabel
                    font.weight: IrisStyle.weight(row.current ? Font.DemiBold : Font.Medium)
                    elide: Text.ElideRight
                }
                Rectangle {
                    visible: row.editing
                    anchors.left: mark.right
                    anchors.leftMargin: 8 * root.d
                    anchors.right: tools.left
                    anchors.rightMargin: 8 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    height: Math.round(30 * root.d)
                    radius: IrisStyle.radiusRow
                    color: IrisStyle.fill
                    border.width: 1
                    border.color: IrisStyle.tintBorder(IrisStyle.accent)
                    TextInput {
                        id: renameField
                        anchors.fill: parent
                        anchors.leftMargin: 8 * root.d
                        anchors.rightMargin: 8 * root.d
                        verticalAlignment: TextInput.AlignVCenter
                        color: IrisStyle.text
                        selectionColor: IrisStyle.accentContainer
                        font.family: IrisStyle.fontMain
                        font.pixelSize: IrisStyle.typeLabel
                        maximumLength: 64
                        clip: true
                        onVisibleChanged: if (visible) { text = row.name; selectAll(); forceActiveFocus() }
                        Keys.onReturnPressed: row.commitRename()
                        Keys.onEscapePressed: root.renaming = ""
                    }
                }
                function commitRename(): void {
                    const next = renameField.text.trim()
                    if (next.length > 0 && next !== row.name) {
                        AudioEngine.error = ""
                        AudioEngine.renameMicPreset(row.name, next)
                    }
                    root.renaming = ""
                }
                Row {
                    id: tools
                    anchors.right: parent.right
                    anchors.rightMargin: 12 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2 * root.d
                    MaterialSymbol {
                        visible: row.current && !row.editing && !row.asking && !row.containsMouse
                        anchors.verticalCenter: parent.verticalCenter
                        text: "check"
                        iconSize: Math.round(18 * root.d)
                        color: IrisStyle.accent
                    }
                    IrisIconButton {
                        visible: row.containsMouse && !row.editing && !row.asking
                        materialIcon: "edit"
                        Accessible.name: Translation.tr("Rename")
                        onClicked: { root.confirming = ""; root.renaming = row.name }
                    }
                    IrisIconButton {
                        visible: row.containsMouse && !row.editing && !row.asking
                        materialIcon: "delete"
                        Accessible.name: Translation.tr("Delete")
                        onClicked: { root.renaming = ""; root.confirming = row.name }
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
                        onClicked: root.confirming = ""
                    }
                    IrisButton {
                        visible: row.asking
                        text: Translation.tr("Delete")
                        danger: true
                        emphasized: true
                        onClicked: { AudioEngine.deleteMicPreset(row.name); root.confirming = "" }
                    }
                }
            }
        }

        IrisText {
            visible: root.names.length === 0
            width: parent.width
            leftPadding: 16 * root.d
            rightPadding: 16 * root.d
            topPadding: 14 * root.d
            text: Translation.tr("Nothing saved yet. Turn on the effects you want, pick a sound, adjust it, and save your voice here.")
            color: IrisStyle.muted
            font.pixelSize: IrisStyle.typeMeta
            wrapMode: Text.WordWrap
        }

        Item {
            width: parent.width
            height: Math.round(54 * root.d)
            Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: 14 * root.d
                anchors.right: saveButton.left
                anchors.rightMargin: 8 * root.d
                anchors.verticalCenter: parent.verticalCenter
                height: Math.round(32 * root.d)
                radius: Math.min(height / 2, IrisStyle.radiusRow)
                color: nameField.activeFocus ? IrisStyle.fill : IrisStyle.fillQuiet
                border.width: nameField.activeFocus ? 1 : 0
                border.color: IrisStyle.tintBorder(IrisStyle.accent)
                TextInput {
                    id: nameField
                    anchors.fill: parent
                    anchors.leftMargin: 10 * root.d
                    anchors.rightMargin: 10 * root.d
                    verticalAlignment: TextInput.AlignVCenter
                    color: IrisStyle.text
                    selectionColor: IrisStyle.accentContainer
                    font.family: IrisStyle.fontMain
                    font.pixelSize: IrisStyle.typeLabel
                    maximumLength: 64
                    clip: true
                    Keys.onReturnPressed: saveButton.save()
                    IrisText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: nameField.text.length === 0
                        text: Translation.tr("Save your voice as a preset")
                        color: IrisStyle.muted
                        font.pixelSize: nameField.font.pixelSize
                    }
                }
            }
            IrisButton {
                id: saveButton
                anchors.right: parent.right
                anchors.rightMargin: 14 * root.d
                anchors.verticalCenter: parent.verticalCenter
                text: root.names.includes(nameField.text.trim()) ? Translation.tr("Replace") : Translation.tr("Save")
                emphasized: nameField.text.trim().length > 0
                enabled: nameField.text.trim().length > 0 && !AudioEngine.busy
                function save(): void {
                    const name = nameField.text.trim()
                    if (name.length === 0) return
                    AudioEngine.error = ""
                    AudioEngine.saveMicPreset(name)
                    nameField.text = ""
                }
                onClicked: saveButton.save()
            }
        }
    }
}
