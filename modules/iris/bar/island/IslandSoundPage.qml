pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.services.deferred
import qs.modules.iris.audio

// The Audio Engine at a glance on the Island; the bubble's card shows the same (IrisAudioQuick).
IrisAudioQuick {
    id: page
    required property Item island
    live: page.island.visualExpanded && page.island.effectivePage === "sound"
    onOpenRequested: {
        AudioEngine.lastSection = "presets"
        page.island.expanded = false
        GlobalStates.openAudioEngine()
    }
}
