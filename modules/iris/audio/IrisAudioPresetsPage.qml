pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import qs
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.iris.components
import qs.modules.iris.style
import qs.modules.iris.settings
import qs.modules.settings as SharedSettings

// Built-in sounds (they change only the core effects that are on), the person's own presets (load, rename, delete,
// export, import), saving what is heard now under a name, and the sound each output remembers.
ColumnLayout {
    id: root
    readonly property real d: IrisStyle.density
    property string renaming: ""
    property string confirming: ""
    // Built-in sounds in blocks by what someone came for, each with its own hue and a word on what it does.
    readonly property var blocks: [
        { caption: "Start clean", names: ["Default", "Flat"] },
        { caption: "Shape", names: ["Voice", "Bass", "Treble"] },
        { caption: "Genres", names: ["Pop", "Rock", "Jazz", "Classic"] }
    ]
    readonly property var looks: ({
        Default: { glyph: "do_not_disturb_on", tint: "gray", line: "Every effect off" },
        Flat: { glyph: "horizontal_rule", tint: "gray", line: "On, but neutral" },
        Voice: { glyph: "record_voice_over", tint: "orange", line: "Clear speech, less rumble" },
        Bass: { glyph: "speaker", tint: "purple", line: "Deep, controlled lows" },
        Treble: { glyph: "graphic_eq", tint: "sky", line: "Bright, airy top" },
        Pop: { glyph: "star", tint: "pink", line: "Warm mids with punch" },
        Rock: { glyph: "electric_bolt", tint: "red", line: "Scooped mids, bite" },
        Jazz: { glyph: "piano", tint: "indigo", line: "Warm and open" },
        Classic: { glyph: "music_note", tint: "teal", line: "Natural, full range" }
    })
    readonly property string errorText: ({
        builtin_name: Translation.tr("That name belongs to a built-in sound."),
        invalid_name: Translation.tr("Give it a name of up to 64 characters."),
        name_taken: Translation.tr("A preset already has that name."),
        chain_failed: Translation.tr("EasyEffects did not take the new chain. Try again."),
        preset_not_found: Translation.tr("That preset is gone."),
        unreadable_file: Translation.tr("That file could not be read."),
        unknown_format: Translation.tr("That file is not an iNiR or EasyEffects output preset."),
        needs_easyeffects: Translation.tr("EasyEffects must be running to read its own presets.")
    })[AudioEngine.error] ?? ""

    spacing: 6 * root.d

    component Caption: IrisText {
        Layout.leftMargin: 16 * root.d
        Layout.topMargin: 8 * root.d
        color: IrisStyle.label
        font.family: IrisStyle.fontTitle
        font.pixelSize: IrisStyle.typeMeta
        font.weight: IrisStyle.weight(Font.DemiBold)
    }

    component PresetRow: MouseArea {
        id: row
        required property string name
        property string glyph: "tune"
        property string tintName: "purple"
        property string line: ""
        property bool own: false
        property bool last: false
        readonly property bool current: AudioEngine.active === row.name
        readonly property bool editing: row.own && root.renaming === row.name
        readonly property bool asking: row.own && root.confirming === row.name
        width: parent ? parent.width : 0
        height: Math.round(46 * root.d)
        hoverEnabled: true
        cursorShape: row.editing ? Qt.IBeamCursor : Qt.PointingHandCursor
        Accessible.role: Accessible.Button
        Accessible.name: row.name
        onClicked: {
            if (row.editing || row.asking) return
            if (row.own) AudioEngine.loadPreset(row.name)
            else AudioEngine.applyBuiltin(row.name)
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: 3 * root.d
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
            anchors.leftMargin: 14 * root.d
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(26 * root.d)
            height: width
            tint: IrisStyle.identityColor(row.tintName)
            glyph: row.glyph
        }
        IrisText {
            id: label
            visible: !row.editing
            anchors.left: mark.right
            anchors.leftMargin: 12 * root.d
            anchors.right: summary.visible ? summary.left : tools.left
            anchors.rightMargin: 8 * root.d
            anchors.verticalCenter: parent.verticalCenter
            text: row.asking ? Translation.tr("Delete “%1”?").arg(row.name) : (row.own ? row.name : Translation.tr(row.name))
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
            if (next.length > 0 && next !== row.name) AudioEngine.renamePreset(row.name, next)
            root.renaming = ""
        }
        IrisText {
            id: summary
            visible: row.line.length > 0 && !row.editing && !row.asking
            anchors.right: tools.left
            anchors.rightMargin: 10 * root.d
            anchors.verticalCenter: parent.verticalCenter
            text: Translation.tr(row.line)
            color: IrisStyle.muted
            font.pixelSize: IrisStyle.typeLabel
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
                visible: row.own && row.containsMouse && !row.editing && !row.asking
                materialIcon: "ios_share"
                Accessible.name: Translation.tr("Export")
                onClicked: root.exportPreset(row.name)
            }
            IrisIconButton {
                visible: row.own && row.containsMouse && !row.editing && !row.asking
                materialIcon: "edit"
                Accessible.name: Translation.tr("Rename")
                onClicked: { root.confirming = ""; root.renaming = row.name }
            }
            IrisIconButton {
                visible: row.own && row.containsMouse && !row.editing && !row.asking
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
                onClicked: { AudioEngine.deletePreset(row.name); root.confirming = "" }
            }
        }
    }

    Repeater {
        model: root.blocks
        ColumnLayout {
            id: block
            required property var modelData
            readonly property var names: block.modelData.names.filter(name => AudioEngine.builtins.includes(name))
            Layout.fillWidth: true
            spacing: 6 * root.d
            Caption { text: Translation.tr(block.modelData.caption) }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: blockColumn.implicitHeight
                radius: IrisStyle.radiusTile
                color: IrisStyle.readingCard
                Column {
                    id: blockColumn
                    width: parent.width
                    Repeater {
                        model: block.names
                        PresetRow {
                            required property var modelData
                            required property int index
                            name: modelData
                            glyph: root.looks[modelData]?.glyph ?? "tune"
                            tintName: root.looks[modelData]?.tint ?? "gray"
                            line: root.looks[modelData]?.line ?? ""
                            last: index === block.names.length - 1
                        }
                    }
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Caption { Layout.fillWidth: true; text: Translation.tr("Yours") }
        IrisButton {
            Layout.topMargin: 8 * root.d
            Layout.rightMargin: 8 * root.d
            text: Translation.tr("Import…")
            quiet: true
            buttonRadius: height / 2
            onClicked: importDialog.open()
        }
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: ownColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: ownColumn
            width: parent.width
            Repeater {
                model: AudioEngine.presets
                PresetRow {
                    required property var modelData
                    readonly property var info: AudioEngine.presetInfo[modelData] ?? ({})
                    name: modelData
                    own: true
                    glyph: "tune"
                    line: [info.base ? Translation.tr(info.base) : "", Translation.tr("%1 on").arg(info.on ?? 0)]
                        .filter(part => part.length > 0).join(" · ")
                }
            }
            IrisText {
                visible: AudioEngine.presets.length === 0
                width: parent.width
                leftPadding: 16 * root.d
                rightPadding: 16 * root.d
                topPadding: 14 * root.d
                text: Translation.tr("Nothing saved yet. Start from a sound above, change what you like, and save it here with everything in the chain.")
                color: IrisStyle.muted
                font.pixelSize: IrisStyle.typeMeta
                wrapMode: Text.WordWrap
            }
            Item {
                width: parent.width
                height: Math.round(54 * root.d)
                Rectangle {
                    id: nameBox
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
                            text: AudioEngine.presets.length === 0
                                ? Translation.tr("Save what you hear as a preset")
                                : Translation.tr("New preset name")
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
                    text: AudioEngine.presets.includes(nameField.text.trim()) ? Translation.tr("Replace") : Translation.tr("Save")
                    emphasized: nameField.text.trim().length > 0
                    enabled: nameField.text.trim().length > 0
                    function save(): void {
                        const name = nameField.text.trim()
                        if (name.length === 0) return
                        AudioEngine.error = ""
                        AudioEngine.savePreset(name)
                        nameField.text = ""
                    }
                    onClicked: saveButton.save()
                }
            }
        }
    }
    // The sound each output remembers: plugging in headphones brings theirs, the speakers bring back their own.
    Caption { text: Translation.tr("Outputs") }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: outputColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: outputColumn
            width: parent.width
            readonly property string sinkName: String(Audio.sink?.name ?? "")
            readonly property string remembered: String(AudioEngine.devices[outputColumn.sinkName] ?? "")
            readonly property var others: Object.keys(AudioEngine.devices).filter(name => name !== outputColumn.sinkName)
            Item {
                width: parent.width
                height: Math.round(58 * root.d)
                IrisSquircle {
                    id: outputMark
                    anchors.left: parent.left
                    anchors.leftMargin: 14 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.round(26 * root.d)
                    height: width
                    tint: IrisStyle.identity.blue
                    glyph: "headphones"
                }
                Column {
                    anchors.left: outputMark.right
                    anchors.leftMargin: 12 * root.d
                    anchors.right: outputButton.left
                    anchors.rightMargin: 10 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    IrisText {
                        width: parent.width
                        text: Audio.friendlyDeviceName(Audio.sink)
                        font.pixelSize: IrisStyle.typeLabel
                        font.weight: IrisStyle.weight(Font.Medium)
                        elide: Text.ElideRight
                    }
                    IrisText {
                        width: parent.width
                        text: outputColumn.remembered.length > 0
                            ? Translation.tr("Plays %1 whenever it becomes your output").arg(Translation.tr(outputColumn.remembered))
                            : Translation.tr("Remembers no sound yet")
                        color: IrisStyle.muted
                        font.pixelSize: IrisStyle.typeMeta
                        elide: Text.ElideRight
                    }
                }
                IrisButton {
                    id: outputButton
                    anchors.right: parent.right
                    anchors.rightMargin: 14 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property bool same: outputColumn.remembered === AudioEngine.active
                    visible: outputColumn.sinkName.length > 0 && (AudioEngine.active.length > 0 || outputColumn.remembered.length > 0)
                    text: outputButton.same || AudioEngine.active.length === 0 ? Translation.tr("Forget")
                        : Translation.tr("Use %1 here").arg(Translation.tr(AudioEngine.active))
                    quiet: outputButton.same
                    buttonRadius: height / 2
                    enabled: !AudioEngine.busy
                    onClicked: outputButton.same || AudioEngine.active.length === 0
                        ? AudioEngine.forget(outputColumn.sinkName)
                        : AudioEngine.remember(outputColumn.sinkName, AudioEngine.active)
                }
            }
            Repeater {
                model: outputColumn.others
                Item {
                    id: other
                    required property var modelData
                    width: outputColumn.width
                    height: Math.round(46 * root.d)
                    Rectangle {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.leftMargin: 52 * root.d
                        anchors.right: parent.right
                        height: 1
                        color: IrisStyle.hairline
                    }
                    IrisText {
                        anchors.left: parent.left
                        anchors.leftMargin: 52 * root.d
                        anchors.right: forgetOther.left
                        anchors.rightMargin: 10 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        text: Translation.tr("%1 · %2").arg(String(other.modelData).replace(/^alsa_output\./, "").replace(/[._-]/g, " "))
                            .arg(Translation.tr(String(AudioEngine.devices[other.modelData] ?? "")))
                        color: IrisStyle.subtext
                        font.pixelSize: IrisStyle.typeLabel
                        elide: Text.ElideRight
                    }
                    IrisIconButton {
                        id: forgetOther
                        anchors.right: parent.right
                        anchors.rightMargin: 12 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        materialIcon: "close"
                        Accessible.name: Translation.tr("Forget")
                        onClicked: AudioEngine.forget(other.modelData)
                    }
                }
            }
        }
    }

    IrisText {
        Layout.fillWidth: true
        Layout.leftMargin: 16 * root.d
        visible: root.errorText.length > 0
        text: root.errorText
        color: IrisStyle.danger
        font.pixelSize: IrisStyle.typeMeta
        wrapMode: Text.WordWrap
    }

    function exportPreset(name: string): void {
        exportDialog.preset = name
        exportDialog.selectedFile = "file://" + Directories.documentsPath + "/" + name + ".json"
        exportDialog.open()
    }
    FileDialog {
        id: exportDialog
        property string preset: ""
        title: Translation.tr("Export preset")
        fileMode: FileDialog.SaveFile
        nameFilters: [Translation.tr("iNiR preset") + " (*.json)", Translation.tr("EasyEffects preset") + " (*.json)"]
        onAccepted: AudioEngine.exportPreset(exportDialog.preset, FileUtils.trimFileProtocol(String(selectedFile)),
            selectedNameFilter.index === 1 ? "easyeffects" : "inir")
    }
    FileDialog {
        id: importDialog
        title: Translation.tr("Import preset")
        fileMode: FileDialog.OpenFile
        nameFilters: [Translation.tr("Presets") + " (*.json)"]
        onAccepted: { AudioEngine.error = ""; AudioEngine.importPreset(FileUtils.trimFileProtocol(String(selectedFile))) }
    }
    // The Audio Engine steps down a layer while a chooser is up, so the chooser is never under it.
    SharedSettings.SettingsNativeDialogGuard { dialog: exportDialog; dialogKey: "iris-audio-export" }
    SharedSettings.SettingsNativeDialogGuard { dialog: importDialog; dialogKey: "iris-audio-import" }
}
