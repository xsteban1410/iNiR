pragma ComponentBehavior: Bound

import QtQuick
import qs.services
import qs.services.deferred
import qs.modules.iris.components
import qs.modules.iris.style

// The person's own presets for a chain ("output" or "input"): what it holds now, saved under a name with every effect
// in it (the person's added ones too), loaded, renamed and deleted; the output's also export.
Rectangle {
    id: root
    readonly property real d: IrisStyle.density
    property string pipe: "output"
    readonly property bool voice: root.pipe === "input"
    readonly property var names: root.voice ? (AudioEngine.mic?.presets ?? []) : AudioEngine.presets
    readonly property var info: root.voice ? (AudioEngine.mic?.presetInfo ?? ({})) : AudioEngine.presetInfo
    readonly property string active: root.voice ? String(AudioEngine.mic?.active ?? "") : AudioEngine.active
    property string emptyText: ""
    property string placeholder: ""
    property string renaming: ""
    property string confirming: ""
    signal exportRequested(string name)

    implicitHeight: column.implicitHeight
    radius: IrisStyle.radiusTile
    color: IrisStyle.readingCard

    Column {
        id: column
        width: parent.width

        Repeater {
            model: root.names
            IrisAudioPresetRow {
                id: preset
                required property var modelData
                readonly property var held: root.info[preset.modelData] ?? ({})
                name: String(preset.modelData)
                own: true
                exportable: !root.voice
                tintName: root.voice ? "orange" : "purple"
                line: [preset.held.base ? Translation.tr(preset.held.base) : "", Translation.tr("%1 on").arg(preset.held.on ?? 0)]
                    .filter(part => part.length > 0).join(" · ")
                current: root.active === preset.name
                editing: root.renaming === preset.name
                asking: root.confirming === preset.name
                onActivated: root.voice ? AudioEngine.loadMicPreset(preset.name) : AudioEngine.loadPreset(preset.name)
                onExportRequested: root.exportRequested(preset.name)
                onRenameRequested: { root.confirming = ""; root.renaming = preset.name }
                onDeleteRequested: { root.renaming = ""; root.confirming = preset.name }
                onRenamed: next => {
                    AudioEngine.error = ""
                    if (root.voice) AudioEngine.renameMicPreset(preset.name, next)
                    else AudioEngine.renamePreset(preset.name, next)
                    root.renaming = ""
                }
                onEditCancelled: root.renaming = ""
                onDeleteConfirmed: {
                    if (root.voice) AudioEngine.deleteMicPreset(preset.name)
                    else AudioEngine.deletePreset(preset.name)
                    root.confirming = ""
                }
                onDeleteCancelled: root.confirming = ""
            }
        }

        IrisText {
            visible: root.names.length === 0
            width: parent.width
            leftPadding: 16 * root.d
            rightPadding: 16 * root.d
            topPadding: 14 * root.d
            text: root.emptyText
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
                        text: root.placeholder
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
                    if (root.voice) AudioEngine.saveMicPreset(name)
                    else AudioEngine.savePreset(name)
                    nameField.text = ""
                }
                onClicked: saveButton.save()
            }
        }
    }
}
