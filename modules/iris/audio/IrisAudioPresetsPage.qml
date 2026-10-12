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
    // Built-in sounds in blocks by what someone came for, each with its own hue and a word on what it does.
    readonly property var blocks: [
        { caption: "Start clean", names: ["Default", "Flat"] },
        { caption: "Shape", names: ["Voice", "Bass", "Treble"] },
        { caption: "Media", names: ["Games", "Competitive", "Movies", "Night"] },
        { caption: "Genres", names: ["Pop", "Rock", "Jazz", "Classic", "Electronic", "Hip-hop"] }
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
        Classic: { glyph: "music_note", tint: "teal", line: "Natural, full range" },
        Games: { glyph: "sports_esports", tint: "green", line: "Impact and space, blasts held" },
        Competitive: { glyph: "footprint", tint: "yellow", line: "Footsteps forward, rumble down" },
        Movies: { glyph: "movie", tint: "blue", line: "Clear dialogue, weighty lows" },
        Night: { glyph: "bedtime", tint: "indigo", line: "Quiet and loud held close" },
        Electronic: { glyph: "equalizer", tint: "lavender", line: "Deep sub, crisp top" },
        "Hip-hop": { glyph: "headphones", tint: "orange", line: "Heavy low end, clear vocals" }
    })
    readonly property string errorText: ({
        builtin_name: Translation.tr("That name belongs to a built-in sound."),
        invalid_name: Translation.tr("Give it a name of up to 64 characters."),
        name_taken: Translation.tr("A preset already has that name."),
        chain_failed: Translation.tr("EasyEffects did not take the new chain. Try again."),
        preset_not_found: Translation.tr("That preset is gone."),
        unreadable_file: Translation.tr("That file could not be read."),
        unknown_format: Translation.tr("That file is not an iNiR or EasyEffects output preset."),
        needs_easyeffects: Translation.tr("EasyEffects must be running to read its own presets."),
        tuned_name_taken: Translation.tr("A tuned output already has that name."),
        tuned_not_found: Translation.tr("That tuned output is gone."),
        tuned_full: Translation.tr("Remove a tuned output first: five are kept at most."),
        no_output: Translation.tr("No output to test: choose one in Volume first."),
        needs_numpy: Translation.tr("The test needs NumPy in iNiR's Python environment."),
        probe_failed: Translation.tr("The test could not play or record. Check that the output and the microphone are free.")
    })[AudioEngine.error] ?? (AudioEngine.error.startsWith("internal_")
        ? Translation.tr("Something went wrong there. The Audio Engine keeps running; try again.") : "")

    spacing: 6 * root.d

    // A built-in sound's word on what it does; on a tuned output, Default keeps only what the output needs.
    function lineOf(name: string): string {
        if (name === "Default" && AudioEngine.tunedOutput) return "Only what this output needs"
        return root.looks[name]?.line ?? ""
    }
    // A tuned output just measured opens with its name ready to change.
    Connections {
        target: AudioEngine
        function onProbed(id: string, pipe: string): void { if (pipe === "output") tunedFor.rename(id) }
    }

    IrisAudioTunedFor {
        id: tunedFor
        Layout.fillWidth: true
        visible: AudioEngine.autoOutput && AudioEngine.outputs.length > 0
    }

    Repeater {
        model: root.blocks
        ColumnLayout {
            id: block
            required property var modelData
            readonly property var names: block.modelData.names.filter(name => AudioEngine.builtins.includes(name))
            Layout.fillWidth: true
            spacing: 6 * root.d
            IrisAudioCaption { text: Translation.tr(block.modelData.caption) }
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
                        IrisAudioPresetRow {
                            id: builtin
                            required property var modelData
                            required property int index
                            name: builtin.modelData
                            glyph: root.looks[builtin.modelData]?.glyph ?? "tune"
                            tintName: root.looks[builtin.modelData]?.tint ?? "gray"
                            line: Translation.tr(root.lineOf(builtin.modelData))
                            last: builtin.index === block.names.length - 1
                            current: AudioEngine.active === builtin.modelData
                            onActivated: AudioEngine.applyBuiltin(builtin.modelData)
                        }
                    }
                }
            }
        }
    }

    IrisAudioAutoTune {
        Layout.fillWidth: true
        Layout.topMargin: 10 * root.d
        visible: AudioEngine.autoOutput
    }

    RowLayout {
        Layout.fillWidth: true
        IrisAudioCaption { Layout.fillWidth: true; text: Translation.tr("Yours") }
        IrisButton {
            Layout.topMargin: 8 * root.d
            Layout.rightMargin: 8 * root.d
            text: Translation.tr("Import…")
            quiet: true
            buttonRadius: height / 2
            onClicked: importDialog.open()
        }
    }
    IrisAudioOwnPresets {
        Layout.fillWidth: true
        emptyText: Translation.tr("Nothing saved yet. Start from a sound above, change what you like, and save it here with everything in the chain.")
        placeholder: AudioEngine.presets.length === 0 ? Translation.tr("Save what you hear as a preset") : Translation.tr("New preset name")
        onExportRequested: name => root.exportPreset(name)
    }
    // The sound each output remembers: plugging in headphones brings theirs, the speakers bring back their own.
    IrisAudioCaption { text: Translation.tr("Outputs") }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: outputColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: outputColumn
            width: parent.width
            readonly property string sinkName: AudioEngine.outputSink
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
                        text: Audio.friendlyDeviceName(AudioEngine.outputDevice)
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

    // The sound each app brings while it plays, chosen under the app in Volume.
    IrisAudioCaption { text: Translation.tr("Apps") }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: appColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: appColumn
            width: parent.width
            readonly property var names: Object.keys(AudioEngine.apps).sort()
            IrisText {
                visible: appColumn.names.length === 0
                width: parent.width
                leftPadding: 16 * root.d
                rightPadding: 16 * root.d
                topPadding: 14 * root.d
                bottomPadding: 14 * root.d
                text: Translation.tr("An app can bring its own sound while it plays: open it in Volume and pick one.")
                color: IrisStyle.muted
                font.pixelSize: IrisStyle.typeLabel
                wrapMode: Text.WordWrap
            }
            Repeater {
                model: appColumn.names
                Item {
                    id: appRow
                    required property var modelData
                    required property int index
                    width: appColumn.width
                    height: Math.round(46 * root.d)
                    Rectangle {
                        visible: appRow.index > 0
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.leftMargin: 16 * root.d
                        anchors.right: parent.right
                        height: 1
                        color: IrisStyle.hairline
                    }
                    IrisText {
                        anchors.left: parent.left
                        anchors.leftMargin: 16 * root.d
                        anchors.right: forgetApp.left
                        anchors.rightMargin: 10 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        text: Translation.tr("%1 · %2").arg(String(appRow.modelData))
                            .arg(Translation.tr(String(AudioEngine.apps[appRow.modelData] ?? "")))
                        color: IrisStyle.subtext
                        font.pixelSize: IrisStyle.typeLabel
                        elide: Text.ElideRight
                    }
                    IrisIconButton {
                        id: forgetApp
                        anchors.right: parent.right
                        anchors.rightMargin: 12 * root.d
                        anchors.verticalCenter: parent.verticalCenter
                        materialIcon: "close"
                        Accessible.name: Translation.tr("Forget")
                        enabled: !AudioEngine.busy
                        onClicked: AudioEngine.forgetApp(appRow.modelData)
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
