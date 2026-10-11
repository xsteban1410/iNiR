pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.components
import qs.modules.iris.style

// A core effect or one the person added: its switch first, then its parameters. A core effect reads as captioned
// cards, one per part its rows name (§5.12); an added one, whose parameters come straight from EasyEffects, in
// cards of at most six rows.
ColumnLayout {
    id: root
    required property var entry
    property bool extra: false
    signal removed()

    readonly property real d: IrisStyle.density
    readonly property string ref: root.extra ? String(root.entry?.id ?? "") : String(root.entry?.kind ?? "")
    readonly property var values: root.entry?.values ?? ({})
    readonly property bool on: root.entry?.enabled ?? false
    readonly property var params: {
        const list = root.extra ? (root.entry?.props ?? []).map(prop => IrisAudioModules.paramFor(prop))
            : (IrisAudioModules.params[root.entry?.kind] ?? [])
        return list.filter(param => !param.when || Boolean(root.values[param.when]))
    }
    readonly property var chunks: {
        const out = []
        if (root.extra) {
            for (let i = 0; i < root.params.length; i += 6) out.push({ caption: "", rows: root.params.slice(i, i + 6) })
            return out
        }
        for (const param of root.params) {
            let chunk = out.find(entry => entry.caption === (param.part ?? ""))
            if (!chunk) { chunk = { caption: param.part ?? "", rows: [] }; out.push(chunk) }
            chunk.rows.push(param)
        }
        return out
    }
    readonly property string needs: String(root.entry?.needs ?? "")
    readonly property bool blocked: root.needs.length > 0 && AudioEngine.missing.includes(root.needs)

    spacing: 6 * root.d

    component Caption: IrisText {
        Layout.leftMargin: 16 * root.d
        Layout.topMargin: 10 * root.d
        color: IrisStyle.label
        font.family: IrisStyle.fontTitle
        font.pixelSize: IrisStyle.typeMeta
        font.weight: IrisStyle.weight(Font.DemiBold)
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: headColumn.implicitHeight
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        Column {
            id: headColumn
            width: parent.width
            IrisAudioRow {
                width: parent.width
                last: !root.extra
                param: ({ kind: "switch", label: root.entry?.label ?? "",
                          description: root.blocked ? Translation.tr("Needs the %1 plugins, which are not installed.").arg(root.needs === "lsp" ? "LSP" : "Calf")
                              : root.on ? "On: the sound passes through it." : "Off: the sound passes by untouched." })
                value: root.on
                enabled: !root.blocked
                onEdited: value => AudioEngine.setEnabled(root.ref, value)
            }
            Item {
                visible: root.extra
                width: parent.width
                height: Math.round(52 * root.d)
                IrisText {
                    anchors.left: parent.left
                    anchors.leftMargin: 16 * root.d
                    anchors.right: removeButton.left
                    anchors.rightMargin: 12 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    text: Translation.tr("Taking it out reloads the chain, so the sound may drop for an instant.")
                    color: IrisStyle.muted
                    font.pixelSize: IrisStyle.typeMeta
                    wrapMode: Text.WordWrap
                }
                IrisButton {
                    id: removeButton
                    anchors.right: parent.right
                    anchors.rightMargin: 16 * root.d
                    anchors.verticalCenter: parent.verticalCenter
                    text: Translation.tr("Remove")
                    danger: true
                    enabled: !AudioEngine.busy
                    onClicked: root.removed()
                }
            }
        }
    }

    // Autogain levels what it measures: what it measures is shown, against its target.
    IrisAudioLoudness {
        Layout.fillWidth: true
        visible: !root.extra && root.entry?.kind === "autogain"
        target: Number(root.values.target ?? -16)
    }

    Repeater {
        model: root.chunks
        ColumnLayout {
            id: chunk
            required property var modelData
            Layout.fillWidth: true
            spacing: 6 * root.d
            // An effect that is off is out of the sound: its parameters grey out and wait for it.
            enabled: root.on
            opacity: root.on ? 1 : 0.4
            Behavior on opacity { NumberAnimation { duration: IrisStyle.duration(140); easing.type: IrisStyle.feedbackEasing } }
            Caption {
                visible: text.length > 0
                text: Translation.tr(chunk.modelData.caption)
            }
            Rectangle {
                id: card
                Layout.fillWidth: true
                Layout.topMargin: chunk.modelData.caption.length > 0 ? 0 : 8 * root.d
                implicitHeight: cardColumn.implicitHeight
                radius: IrisStyle.radiusTile
                color: IrisStyle.readingCard
                Column {
                    id: cardColumn
                    width: parent.width
                    Repeater {
                        model: chunk.modelData.rows
                        IrisAudioRow {
                            required property var modelData
                            required property int index
                            width: cardColumn.width
                            param: modelData
                            last: index === chunk.modelData.rows.length - 1
                            value: root.values[modelData.prop]
                            fallback: root.entry?.defaults?.[modelData.prop]
                            onEdited: value => AudioEngine.setValue(root.ref, modelData.prop, value)
                        }
                    }
                }
            }
        }
    }
}
