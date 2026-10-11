pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.iris.frame
import qs.modules.iris.components
import qs.modules.iris.style
import qs.modules.iris.settings

// The Audio Engine: a Place laid out like Settings (§5.12). The sidebar lists Presets, the six core effects and the
// effects the person added; the page shows the one chosen. Hosted by IrisAudioOverlay or IrisAudioWindow.
Item {
    id: root
    property bool windowed: false
    readonly property alias frame: frame
    readonly property real d: IrisStyle.density
    property string section: AudioEngine.lastSection
    onSectionChanged: AudioEngine.lastSection = root.section

    readonly property bool shown: root.windowed || GlobalStates.audioEngineOpen
    property bool held: false
    function hold(on: bool): void {
        if (on === root.held) return
        root.held = on
        if (on) AudioEngine.acquire()
        else AudioEngine.release()
    }
    onShownChanged: root.hold(root.shown)
    Component.onCompleted: root.hold(root.shown)
    Component.onDestruction: root.hold(false)

    readonly property var extraSections: AudioEngine.extras.map(entry => {
        const look = IrisAudioModules.lookOf(entry.kind)
        return { id: entry.id, title: entry.label, glyph: look.glyph, tint: look.tint, extra: true }
    })
    // Taking an added effect out lands on its nearest neighbour (the next one, else the one before); with none left,
    // on the start page.
    function removeCurrent(): void {
        const list = AudioEngine.extras
        const at = list.findIndex(entry => entry.id === root.section)
        if (at < 0) return
        const id = list[at].id
        const rest = list.filter(entry => entry.id !== id)
        root.section = rest.length > 0 ? rest[Math.min(at, rest.length - 1)].id : "presets"
        AudioEngine.removeEffect(id)
    }
    readonly property var current: root.section === "microphone" ? IrisAudioModules.micSection : IrisAudioModules.section(root.section)
        ?? root.extraSections.find(entry => entry.id === root.section)
        ?? (root.section === "add" ? { id: "add", title: "Add effect", glyph: "add", tint: "gray",
                                       line: "Any other EasyEffects effect, after the core ones.",
                                       tip: "Added effects are saved with your presets. Adding or removing one reloads the chain, so the sound may drop for an instant." } : null)
    onCurrentChanged: if (root.current === null) root.section = "presets"
    readonly property string phase: !AudioEngine.ready ? "loading"
        : !AudioEngine.installed ? "missing"
        : !AudioEngine.running ? "stopped"
        : "ready"

    function close(): void { GlobalStates.audioEngineOpen = false }
    // The other host opens on the same page: the page lives in the service, the host is the person's choice.
    function switchHost(): void {
        Config.setNestedValue("iris.audio.host", root.windowed ? "overlay" : "window")
    }

    Shortcut { sequence: "Escape"; enabled: root.shown && !root.windowed; onActivated: root.close() }
    MouseArea { anchors.fill: parent; enabled: !root.windowed; onClicked: root.close() }

    readonly property bool windowField: root.windowed && IrisStyle.textured
    IrisMorphSurface {
        id: frame
        motionSurface: "settings"
        settles: true
        windowOffset: Qt.point(IrisFrame.band, IrisFrame.band)
        ownField: !root.windowed || root.windowField
        glass: !root.windowed || IrisStyle.glassCompositor
        compositorBlurred: true
        open: root.shown
        color: IrisStyle.surface
        light: IrisStyle.surfaceLight("settings", IrisStyle.wallpaperLight)
        radius: root.windowField ? Number(IrisNiri.data["window-rules"]?.corner_radius ?? 16)
            : root.windowed ? 0 : IrisStyle.surfaceRadius("settings", IrisStyle.radiusPanel)
        onClosed: GlobalStates.irisMorphOwner = ""
        x: root.windowed ? 0 : (parent.width - width) / 2
        y: root.windowed ? 0 : (parent.height - height) / 2
        width: root.windowed ? parent.width
            : Math.min(parent.width - 32 - IrisFrame.musicReach("left") - IrisFrame.musicReach("right"), 1080 * root.d)
        height: root.windowed ? parent.height
            : Math.min(parent.height - 48 - IrisFrame.musicReach("top") - IrisFrame.musicReach("bottom"), 780 * root.d)
        MouseArea { anchors.fill: parent }

        RowLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                id: sidebar
                readonly property int pad: IrisStyle.concentricPad(frame.radius, 12 * root.d)
                Layout.fillHeight: true
                Layout.preferredWidth: Math.min(260 * root.d, frame.width * 0.3)
                topLeftRadius: frame.radius
                bottomLeftRadius: frame.radius
                color: IrisStyle.readingSidebar
                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 1
                    color: IrisStyle.hairline
                }
                Flickable {
                    anchors.fill: parent
                    anchors.margins: sidebar.pad
                    anchors.topMargin: sidebar.pad + 4 * root.d
                    anchors.rightMargin: sidebar.pad - 4 * root.d
                    clip: true
                    contentHeight: sideColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: IrisScrollBar {}
                    Column {
                        id: sideColumn
                        width: parent.width - 4 * root.d
                        spacing: 0

                        Row {
                            height: Math.round(50 * root.d)
                            spacing: 10 * root.d
                            leftPadding: 6 * root.d
                            IrisSquircle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.round(36 * root.d)
                                height: width
                                tint: IrisStyle.identity.pink
                                glyph: "graphic_eq"
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                IrisText {
                                    text: Translation.tr("Audio Engine")
                                    font.pixelSize: IrisStyle.typeLabel
                                    font.weight: IrisStyle.weight(Font.DemiBold)
                                }
                                Row {
                                    spacing: 5 * root.d
                                    IrisText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: !AudioEngine.running ? Translation.tr("EasyEffects is off")
                                            : AudioEngine.bypass ? Translation.tr("Without effects")
                                            : AudioEngine.active.length > 0 ? Translation.tr(AudioEngine.active)
                                            : Translation.tr("EasyEffects")
                                        color: IrisStyle.muted
                                        font.pixelSize: IrisStyle.typeMeta
                                    }
                                    // Changed since its preset was set, like a Settings row that differs from its default.
                                    Rectangle {
                                        visible: AudioEngine.running && AudioEngine.modified && !AudioEngine.bypass
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.round(6 * root.d)
                                        height: width
                                        radius: width / 2
                                        color: IrisStyle.accent
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: IrisAudioModules.sections
                            SideRow { gapAbove: index <= 1 }
                        }
                        SideRow {
                            gapAbove: true
                            modelData: IrisAudioModules.micSection
                            index: 0
                        }
                        Repeater {
                            model: root.extraSections
                            SideRow { gapAbove: index === 0 }
                        }
                        SideRow {
                            gapAbove: root.extraSections.length === 0
                            modelData: ({ id: "add", title: "Add effect", glyph: "add", tint: "gray" })
                            index: 0
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20 * root.d
                    Layout.rightMargin: IrisStyle.concentricPad(frame.radius, 14 * root.d)
                    Layout.topMargin: IrisStyle.concentricPad(frame.radius, 14 * root.d)
                    Layout.preferredHeight: Math.round(52 * root.d)
                    spacing: 8 * root.d
                    IrisText {
                        Layout.fillWidth: true
                        text: Translation.tr(root.current?.title ?? "")
                        font.family: IrisStyle.fontTitle
                        font.pixelSize: IrisStyle.typeTitle
                        font.weight: IrisStyle.weight(Font.DemiBold)
                        elide: Text.ElideRight
                    }
                    IrisText {
                        visible: AudioEngine.busy && root.phase === "ready"
                        text: Translation.tr("Applying…")
                        color: IrisStyle.muted
                        font.pixelSize: IrisStyle.typeMeta
                    }
                    // Held, the sound plays without any effect; let go and they are back: the quickest A/B.
                    IrisIconButton {
                        visible: AudioEngine.running && root.phase === "ready"
                        materialIcon: "compare"
                        selected: AudioEngine.bypass
                        onPressedChanged: AudioEngine.setBypass(pressed)
                        Accessible.name: Translation.tr("Hold to hear without effects")
                    }
                    IrisIconButton {
                        materialIcon: root.windowed ? "layers" : "web_asset"
                        onClicked: root.switchHost()
                        Accessible.name: root.windowed ? Translation.tr("Open over the desktop") : Translation.tr("Open as a window")
                    }
                    // Quits EasyEffects itself: the chain stops until it is started again.
                    IrisIconButton {
                        visible: AudioEngine.running
                        materialIcon: "power_settings_new"
                        enabled: !AudioEngine.busy
                        onClicked: AudioEngine.quitEasyEffects()
                        Accessible.name: Translation.tr("Quit EasyEffects")
                    }
                    IrisIconButton {
                        materialIcon: "close"
                        Accessible.name: Translation.tr("Close")
                        onClicked: root.close()
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Flickable {
                        id: page
                        anchors.fill: parent
                        visible: root.phase === "ready"
                        clip: true
                        contentHeight: pageColumn.implicitHeight + Math.round(32 * root.d)
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: IrisScrollBar {}

                        ColumnLayout {
                            id: pageColumn
                            x: Math.round(20 * root.d)
                            y: Math.round(8 * root.d)
                            width: Math.min(page.width - 40 * root.d, 820 * root.d)
                            spacing: 16 * root.d

                            HeroCard { Layout.fillWidth: true }

                            Loader {
                                Layout.fillWidth: true
                                active: root.phase === "ready"
                                visible: active
                                sourceComponent: root.section === "presets" ? presetsPage
                                    : root.section === "microphone" ? micPage
                                    : root.section === "equalizer" ? equalizerPage
                                    : root.section === "add" ? addPage
                                    : effectPage
                            }
                        }
                    }

                    StatePane {
                        visible: root.phase !== "ready"
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -Math.round(26 * root.d)
                        width: Math.min(parent.width - 40 * root.d, 460 * root.d)
                    }
                }
            }
        }
    }

    // The page's head (§5.12): its mark, what it does and a tip; the equalizer's curve rides at its right where Settings
    // shows a scene, on the pages it shapes.
    component HeroCard: Rectangle {
        id: hero
        readonly property bool staged: root.section === "presets" && hero.width >= Math.round(560 * root.d)
        readonly property var eq: AudioEngine.module("equalizer")
        readonly property real inset: IrisStyle.concentricPad(IrisStyle.radiusTile, 6 * root.d)
        implicitHeight: Math.max(heroText.implicitHeight + Math.round(36 * root.d), hero.staged ? Math.round(150 * root.d) + hero.inset * 2 : 0)
        radius: IrisStyle.radiusTile
        color: IrisStyle.readingCard
        IrisSquircle {
            id: heroMark
            anchors.left: parent.left
            anchors.leftMargin: 14 * root.d
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(48 * root.d)
            height: width
            tint: IrisStyle.identityColor(root.current?.tint ?? "gray")
            glyph: root.current?.glyph ?? "tune"
        }
        ColumnLayout {
            id: heroText
            anchors.left: heroMark.right
            anchors.leftMargin: 14 * root.d
            anchors.right: hero.staged ? curveBox.left : parent.right
            anchors.rightMargin: 16 * root.d
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3 * root.d
            IrisText {
                Layout.fillWidth: true
                text: root.current?.extra ? Translation.tr("An effect you added, after the core ones.")
                    : Translation.tr(root.current?.line ?? "")
                font.pixelSize: IrisStyle.typeBody
                font.weight: IrisStyle.weight(Font.DemiBold)
                wrapMode: Text.WordWrap
            }
            IrisText {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.current?.extra ? Translation.tr("It is saved with your presets, with everything you set here.")
                    : Translation.tr(root.current?.tip ?? "")
                color: IrisStyle.muted
                font.pixelSize: IrisStyle.typeMeta
                wrapMode: Text.WordWrap
            }
            Row {
                visible: root.section === "presets" && AudioEngine.active.length > 0
                Layout.topMargin: 4 * root.d
                spacing: 6 * root.d
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.round(6 * root.d)
                    height: width
                    radius: width / 2
                    color: IrisStyle.accent
                }
                IrisText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: AudioEngine.modified ? Translation.tr("Now: %1 · changed").arg(Translation.tr(AudioEngine.active))
                        : Translation.tr("Now: %1").arg(Translation.tr(AudioEngine.active))
                    color: IrisStyle.subtext
                    font.pixelSize: IrisStyle.typeMeta
                    font.weight: IrisStyle.weight(Font.Medium)
                }
                IrisButton {
                    visible: AudioEngine.modified
                    anchors.verticalCenter: parent.verticalCenter
                    text: Translation.tr("Revert")
                    quiet: true
                    buttonRadius: height / 2
                    enabled: !AudioEngine.busy
                    onClicked: AudioEngine.revert()
                }
            }
        }
        Rectangle {
            id: curveBox
            visible: hero.staged
            anchors.right: parent.right
            anchors.rightMargin: hero.inset
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(300 * root.d)
            height: Math.round(150 * root.d)
            radius: Math.max(IrisStyle.radiusMicro, IrisStyle.radiusTile - hero.inset)
            color: IrisStyle.fillQuiet
            clip: true
            IrisAudioScene { anchors.fill: parent }
        }
    }

    Component { id: presetsPage; IrisAudioPresetsPage {} }
    Component { id: micPage; IrisAudioMicPage {} }
    Component { id: addPage; IrisAudioAddPage { onAdded: kind => root.pendingKind = kind } }
    Component { id: equalizerPage; IrisAudioEqualizerPage { entry: AudioEngine.module("equalizer") } }
    Component {
        id: effectPage
        IrisAudioEffectPage {
            extra: root.current?.extra ?? false
            entry: root.current?.extra ? AudioEngine.extra(root.section) : AudioEngine.module(root.section)
            onRemoved: root.removeCurrent()
        }
    }

    // Adding an effect opens it once the chain that holds it comes back.
    property string pendingKind: ""
    Connections {
        target: AudioEngine
        function onExtrasChanged(): void {
            if (root.pendingKind.length === 0) return
            const added = AudioEngine.extras.filter(entry => entry.kind === root.pendingKind)
            if (added.length === 0) return
            root.section = added[added.length - 1].id
            root.pendingKind = ""
        }
    }

    component SideRow: MouseArea {
        id: row
        required property var modelData
        required property int index
        property bool gapAbove: false
        readonly property bool selected: root.section === row.modelData.id
        readonly property real rowHeight: Math.round(27 * root.d * Math.max(1, IrisStyle.typeScale))
        width: parent ? parent.width : 0
        height: row.rowHeight + (row.gapAbove ? Math.round(8 * root.d) : 0)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.phase === "ready"
        opacity: enabled ? 1 : 0.4
        Accessible.role: Accessible.Button
        Accessible.name: Translation.tr(row.modelData.title)
        onClicked: root.section = row.modelData.id
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: row.rowHeight
            radius: Math.min(row.rowHeight / 2, IrisStyle.iconRadius(mark.width) + mark.x)
            color: row.selected ? IrisStyle.tintFillHover(IrisStyle.accent)
                : row.containsMouse ? IrisStyle.fillHover : "transparent"
            Behavior on color { ColorAnimation { duration: IrisStyle.duration(110); easing.type: IrisStyle.feedbackEasing } }
            IrisSquircle {
                id: mark
                x: Math.round(6 * root.d)
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(20 * root.d)
                height: width
                tint: IrisStyle.identityColor(row.modelData.tint)
                glyph: row.modelData.glyph
            }
            IrisText {
                anchors.left: mark.right
                anchors.leftMargin: 10 * root.d
                anchors.right: dot.left
                anchors.rightMargin: 6 * root.d
                anchors.verticalCenter: parent.verticalCenter
                text: Translation.tr(row.modelData.title)
                font.pixelSize: IrisStyle.typeLabel
                font.weight: IrisStyle.weight(row.selected ? Font.DemiBold : Font.Medium)
                elide: Text.ElideRight
            }
            // An effect that is on carries a dot in its own hue.
            Rectangle {
                id: dot
                readonly property var entry: row.modelData.extra ? AudioEngine.extra(row.modelData.id)
                    : row.modelData.id === "microphone" ? ({ enabled: (AudioEngine.mic?.core ?? []).some(m => m.enabled) })
                    : AudioEngine.module(row.modelData.id)
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.d
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(6 * root.d)
                height: width
                radius: width / 2
                color: IrisStyle.identityColor(row.modelData.tint)
                visible: dot.entry?.enabled ?? false
            }
        }
    }

    component StatePane: ColumnLayout {
        spacing: 10 * root.d
        IrisSquircle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.round(56 * root.d)
            Layout.preferredHeight: Math.round(56 * root.d)
            tint: IrisStyle.identity.pink
            glyph: "graphic_eq"
        }
        IrisText {
            Layout.alignment: Qt.AlignHCenter
            text: root.phase === "loading" ? Translation.tr("Looking for EasyEffects…")
                : root.phase === "missing" ? Translation.tr("EasyEffects is not installed")
                : Translation.tr("EasyEffects is not running")
            font.family: IrisStyle.fontTitle
            font.pixelSize: IrisStyle.typeTitle
            font.weight: IrisStyle.weight(Font.DemiBold)
        }
        IrisText {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: Math.round(420 * root.d)
            visible: root.phase !== "loading"
            horizontalAlignment: Text.AlignHCenter
            text: root.phase === "missing"
                ? Translation.tr("The Audio Engine runs its effects in EasyEffects. Install it, with the LSP and Calf plugins, from your package manager.")
                : Translation.tr("The Audio Engine runs its effects in EasyEffects. Start it to hear them; nothing in your chain changes until you do.")
            color: IrisStyle.muted
            font.pixelSize: IrisStyle.typeBody
            wrapMode: Text.WordWrap
        }
        IrisButton {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 6 * root.d
            visible: root.phase === "stopped"
            text: AudioEngine.starting ? Translation.tr("Starting…") : Translation.tr("Start EasyEffects")
            emphasized: true
            enabled: !AudioEngine.starting
            onClicked: AudioEngine.start()
        }
        IrisText {
            Layout.alignment: Qt.AlignHCenter
            visible: AudioEngine.error === "start_failed" && root.phase === "stopped"
            text: Translation.tr("EasyEffects did not start.")
            color: IrisStyle.danger
            font.pixelSize: IrisStyle.typeMeta
        }
    }
}
