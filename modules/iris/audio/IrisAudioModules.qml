pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.modules.iris.style

// What the Audio Engine shows of each core effect: its mark and the parameters worth a row. Ranges are the useful part
// of EasyEffects' own (ee-schema.json); `scale: "log"` spreads a frequency the way it is heard.
Singleton {
    id: root

    readonly property var sections: [
        { id: "presets", title: "Presets", glyph: "library_music", tint: "pink",
          line: "Start from a sound, then make it yours.",
          tip: "A built-in sound changes only the effects that are on; Default turns them all off." },
        { id: "equalizer", title: "Equalizer", glyph: "graphic_eq", tint: "blue",
          line: "Shape the tone band by band.",
          tip: "Double-click a band to return it to 0 dB; the wheel moves it half a decibel." },
        { id: "filter", title: "Filter", glyph: "filter_alt", tint: "teal",
          line: "Cut what you never want to hear, like rumble under a voice.",
          tip: "A high-pass around 80–100 Hz cleans up a voice without thinning it." },
        { id: "bass_enhancer", title: "Bass Enhancer", glyph: "speaker", tint: "orange",
          line: "Adds the harmonics of the bass, so small speakers sound deeper.",
          tip: "Keep the Limiter on with it: added bass raises the peaks." },
        { id: "exciter", title: "Exciter", glyph: "auto_awesome", tint: "yellow",
          line: "Adds the harmonics of the highs, for air and presence.",
          tip: "A little goes a long way: past +6 dB it starts to hiss." },
        { id: "autogain", title: "Autogain", glyph: "equalizer", tint: "green",
          line: "Keeps loudness even from one song or video to the next.",
          tip: "Measured in LUFS, the way streaming services level what they play." },
        { id: "limiter", title: "Limiter", glyph: "vertical_align_center", tint: "red",
          line: "Keeps peaks under a ceiling, so nothing clips.",
          tip: "It runs last, so the effects before it can push without distorting." }
    ]
    readonly property var core: root.sections.filter(section => section.id !== "presets").map(section => section.id)

    // Levels, not effects: every device and app at its own volume, with or without EasyEffects.
    readonly property var mixerSection: ({ id: "mixer", title: "Volume", glyph: "tune", tint: "indigo",
        line: "Every speaker, microphone and app at its own level.",
        tip: "These are your system's levels, so they work with EasyEffects off too. Use makes a device the one everything plays through or records from." })

    // The microphone has its own chain: what others hear of you on calls and streams.
    readonly property var micSection: ({ id: "microphone", title: "Microphone", glyph: "mic", tint: "orange",
        line: "What others hear of you: less noise, an even voice.",
        tip: "It runs on what apps record, so calls and streams get it; your own playback is left alone." })
    readonly property var micModules: [
        { kind: "filter", title: "Low cut", glyph: "filter_alt", tint: "teal" },
        { kind: "rnnoise", title: "Noise reduction", glyph: "noise_control_off", tint: "green" },
        { kind: "gate", title: "Noise gate", glyph: "door_front", tint: "blue" },
        { kind: "autotune", title: "Autotune", glyph: "mic_external_on", tint: "pink" },
        { kind: "compressor", title: "Leveler", glyph: "compress", tint: "purple" },
        { kind: "limiter", title: "Limiter", glyph: "vertical_align_center", tint: "red" }
    ]
    readonly property var micLooks: ({ Off: { glyph: "mic_off", tint: "gray", line: "Your microphone as it is" },
        Calls: { glyph: "call", tint: "green", line: "Clear and even, background hushed" },
        Streaming: { glyph: "podcasts", tint: "purple", line: "Fuller and louder, firmly levelled" },
        "Noisy room": { glyph: "noise_aware", tint: "orange", line: "Strong cleanup for loud places" } })
    readonly property var micParams: ({
        filter: [
            { prop: "frequency", label: "Cut below", description: "Rumble, desk knocks and breath pops live down here.", kind: "range", min: 20, max: 300, scale: "log", unit: "Hz" }
        ],
        rnnoise: [
            { prop: "enableVad", label: "Only while you speak", description: "Silences the line between words.", kind: "switch" },
            { prop: "vadThres", label: "Voice threshold", kind: "range", min: 0, max: 100, step: 1, unit: "%", when: "enableVad" }
        ],
        gate: [
            { prop: "curveThreshold", label: "Opens above", description: "Quieter than this is treated as background.", kind: "range", min: -60, max: 0, step: 1, unit: "dB" },
            { prop: "reduction", label: "Background down by", kind: "range", min: -72, max: 0, step: 1, unit: "dB" },
            { prop: "release", label: "Release", kind: "range", min: 10, max: 1000, step: 10, unit: "ms" }
        ],
        autotune: [
            { tune: "style", label: "Style", description: "How hard the voice snaps onto each note.", kind: "choice", choices: [
                { value: "subtle", label: "Subtle" }, { value: "natural", label: "Natural" }, { value: "robot", label: "Robot" }] },
            { tune: "scale", label: "Scale", description: "Only its notes are sung; every note suits speech.", kind: "choice", choices: [
                { value: "chromatic", label: "Every note" }, { value: "major", label: "Major" }, { value: "minor", label: "Minor" },
                { value: "pentatonic", label: "Pentatonic" }, { value: "minorPentatonic", label: "Minor pentatonic" }, { value: "blues", label: "Blues" }] },
            { tune: "key", label: "Key", kind: "choice", keyed: true, choices: ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
                .map((note, index) => ({ value: index, label: note })) },
            { prop: "correction", label: "Correction", description: "How far toward the note the voice is pulled.", kind: "range", min: 0, max: 1, step: 0.01, unit: "" },
            { prop: "filter", label: "Smoothing", description: "Lower snaps between notes, higher glides.", kind: "range", min: 0.02, max: 0.5, step: 0.01, unit: "" },
            { prop: "tuning", label: "Tuning", description: "The pitch of A; 440 Hz is standard.", kind: "range", min: 400, max: 480, step: 1, unit: "Hz" }
        ],
        compressor: [
            { prop: "threshold", label: "Threshold", description: "Louder than this is brought down.", kind: "range", min: -60, max: 0, step: 1, unit: "dB" },
            { prop: "ratio", label: "Ratio", kind: "range", min: 1, max: 20, step: 0.5, unit: ":1" },
            { prop: "makeup", label: "Make up", description: "Raises the levelled voice back up.", kind: "range", min: 0, max: 24, step: 0.5, unit: "dB" }
        ],
        limiter: [
            { prop: "threshold", label: "Ceiling", kind: "range", min: -24, max: 0, step: 0.5, unit: "dB" }
        ]
    })

    // Every other effect by what it is for: its mark, its hue and the block it sits in when adding one.
    readonly property var groups: [
        { id: "dynamics", title: "Dynamics", tint: "orange" },
        { id: "tone", title: "Tone", tint: "blue" },
        { id: "space", title: "Space", tint: "teal" },
        { id: "voice", title: "Voice and cleanup", tint: "green" },
        { id: "character", title: "Character", tint: "purple" },
        { id: "measure", title: "Measure", tint: "gray" }
    ]
    readonly property var extraLooks: ({
        compressor: { glyph: "compress", group: "dynamics" },
        expander: { glyph: "expand", group: "dynamics" },
        gate: { glyph: "door_front", group: "dynamics" },
        multiband_compressor: { glyph: "view_week", group: "dynamics" },
        multiband_gate: { glyph: "view_column", group: "dynamics" },
        maximizer: { glyph: "trending_up", group: "dynamics" },
        level_meter: { glyph: "speed", group: "measure" },
        bass_loudness: { glyph: "speaker_group", group: "tone" },
        loudness: { glyph: "hearing", group: "tone" },
        crystalizer: { glyph: "diamond", group: "tone" },
        midside_equalizer: { glyph: "tune", group: "tone" },
        reverb: { glyph: "blur_on", group: "space" },
        delay: { glyph: "timer", group: "space" },
        crossfeed: { glyph: "headphones", group: "space" },
        crosstalk_canceller: { glyph: "surround_sound", group: "space" },
        stereo_tools: { glyph: "settings_input_component", group: "space" },
        convolver: { glyph: "waves", group: "space" },
        rnnoise: { glyph: "noise_control_off", group: "voice" },
        deepfilternet: { glyph: "noise_aware", group: "voice" },
        speex: { glyph: "record_voice_over", group: "voice" },
        deesser: { glyph: "text_fields", group: "voice" },
        voice_suppressor: { glyph: "voice_over_off", group: "voice" },
        autotune: { glyph: "mic_external_on", group: "character" },
        pitch: { glyph: "piano", group: "character" },
        crusher: { glyph: "grain", group: "character" }
    })
    function lookOf(kind: string): var {
        const look = root.extraLooks[kind] ?? { glyph: "tune", group: "character" }
        const group = root.groups.find(entry => entry.id === look.group) ?? root.groups[4]
        return { glyph: look.glyph, tint: group.tint, group: group.id }
    }

    function section(id: string): var {
        return root.sections.find(entry => entry.id === id) ?? null
    }

    readonly property var params: ({
        equalizer: [
            { prop: "inputGain", label: "Input gain", description: "Lower it as far as the highest band rises, so a boost never clips.", kind: "range", min: -24, max: 12, step: 0.5, unit: "dB" }
        ],
        filter: [
            { prop: "type", part: "Shape", label: "Type", kind: "choice", choices: [
                { value: 1, label: "High-pass" }, { value: 0, label: "Low-pass" }, { value: 2, label: "Low-shelf" },
                { value: 3, label: "High-shelf" }, { value: 4, label: "Bell" }, { value: 5, label: "Band-pass" }, { value: 6, label: "Notch" }] },
            { prop: "frequency", part: "Where it acts", label: "Frequency", description: "Where the filter starts to act.", kind: "range", min: 10, max: 20000, scale: "log", unit: "Hz" },
            { prop: "slope", part: "Shape", label: "Slope", description: "How steeply it cuts past the frequency.", kind: "choice", choices: [
                { value: 0, label: "x1" }, { value: 1, label: "x2" }, { value: 2, label: "x3" }, { value: 3, label: "x4" }, { value: 4, label: "x6" }, { value: 5, label: "x8" }] },
            { prop: "gain", part: "Where it acts", label: "Gain", description: "For shelves and bells only.", kind: "range", min: -24, max: 24, step: 0.5, unit: "dB" },
            { prop: "quality", part: "Where it acts", label: "Quality", description: "How narrow a bell or notch is.", kind: "range", min: 0, max: 10, step: 0.1, unit: "" }
        ],
        bass_enhancer: [
            { prop: "amount", part: "Harmonics", label: "Amount", description: "How much of the harmonics is added.", kind: "range", min: -24, max: 24, step: 0.5, unit: "dB" },
            { prop: "harmonics", part: "Harmonics", label: "Harmonics", description: "Their order: higher reads brighter.", kind: "range", min: 0.1, max: 10, step: 0.1, unit: "" },
            { prop: "scope", part: "Range", label: "Scope", description: "The bass below this frequency is enhanced.", kind: "range", min: 10, max: 250, step: 1, unit: "Hz" },
            { prop: "blend", part: "Harmonics", label: "Blend", description: "Even harmonics are warmer, odd ones edgier.", kind: "range", min: -10, max: 10, step: 0.5, unit: "" },
            { prop: "floorActive", part: "Range", label: "Floor", description: "Leaves the deepest rumble out of it.", kind: "switch" },
            { prop: "floor", part: "Range", label: "Floor frequency", kind: "range", min: 10, max: 120, step: 1, unit: "Hz", when: "floorActive" }
        ],
        exciter: [
            { prop: "amount", part: "Harmonics", label: "Amount", description: "How much of the harmonics is added.", kind: "range", min: -24, max: 24, step: 0.5, unit: "dB" },
            { prop: "harmonics", part: "Harmonics", label: "Harmonics", description: "Their order: higher reads brighter.", kind: "range", min: 0.1, max: 10, step: 0.1, unit: "" },
            { prop: "scope", part: "Range", label: "Scope", description: "The highs above this frequency are excited.", kind: "range", min: 2000, max: 12000, step: 100, unit: "Hz" },
            { prop: "blend", part: "Harmonics", label: "Blend", description: "Even harmonics are warmer, odd ones edgier.", kind: "range", min: -10, max: 10, step: 0.5, unit: "" },
            { prop: "ceilActive", part: "Range", label: "Ceiling", description: "Stops before the very top, where it would hiss.", kind: "switch" },
            { prop: "ceil", part: "Range", label: "Ceiling frequency", kind: "range", min: 10000, max: 20000, step: 100, unit: "Hz", when: "ceilActive" }
        ],
        autogain: [
            { prop: "target", part: "Loudness", label: "Target", description: "Streaming services aim at −14 LUFS, speech at −16.", kind: "range", min: -36, max: 0, step: 0.5, unit: "LUFS" },
            { prop: "reference", part: "Loudness", label: "Measured over", kind: "choice", choices: [
                { value: 0, label: "Moment" }, { value: 1, label: "Short term" }, { value: 2, label: "Whole history" }, { value: 3, label: "Balanced" }] },
            { prop: "maximumHistory", part: "Memory", label: "History", description: "How far back loudness is remembered.", kind: "range", min: 6, max: 120, step: 1, unit: "s" },
            { prop: "silenceThreshold", part: "Memory", label: "Silence below", description: "Quieter than this is left alone, so pauses are not raised.", kind: "range", min: -100, max: 0, step: 1, unit: "dB" }
        ],
        limiter: [
            { prop: "threshold", part: "Ceiling", label: "Ceiling", description: "No peak goes past it.", kind: "range", min: -24, max: 0, step: 0.5, unit: "dB" },
            { prop: "gainBoost", part: "Ceiling", label: "Make up", description: "Raises the result by what the ceiling takes off.", kind: "switch" },
            { prop: "lookahead", part: "Timing", label: "Lookahead", kind: "range", min: 0.1, max: 20, step: 0.1, unit: "ms" },
            { prop: "attack", part: "Timing", label: "Attack", kind: "range", min: 0.25, max: 20, step: 0.25, unit: "ms" },
            { prop: "release", part: "Timing", label: "Release", kind: "range", min: 0.25, max: 20, step: 0.25, unit: "ms" },
            { prop: "oversampling", part: "Ceiling", label: "Oversampling", description: "Catches peaks between samples, at some CPU.", kind: "choice", choices: [
                { value: 0, label: "Off" }, { value: 2, label: "x2" }, { value: 6, label: "x4" }, { value: 22, label: "True peak" }] }
        ]
    })

    // A row for any EasyEffects parameter, from the helper's schema entry.
    function paramFor(prop: var): var {
        const words = String(prop.name).replace(/([A-Z])/g, " $1").toLowerCase().trim()
        const label = words.charAt(0).toUpperCase() + words.slice(1)
        if (prop.type === "bool")
            return { prop: prop.name, label: label, kind: "switch" }
        if (prop.type === "enum")
            return { prop: prop.name, label: label, kind: "choice",
                     choices: prop.choices.map((choice, index) => ({ value: index, label: choice })) }
        const span = Number(prop.max ?? 100) - Number(prop.min ?? 0)
        return { prop: prop.name, label: label, kind: "range", min: Number(prop.min ?? 0), max: Number(prop.max ?? 100),
                 step: prop.type === "int" ? 1 : span > 200 ? 1 : span > 20 ? 0.5 : 0.01, unit: "",
                 scale: /frequency/i.test(prop.name) && Number(prop.min ?? 0) > 0 ? "log" : "" }
    }

    function valueText(param: var, value: var): string {
        const number = Number(value)
        if (!Number.isFinite(number)) return ""
        const step = Number(param.step ?? 1)
        const decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : 2
        let text = param.unit === "Hz" && number >= 1000
            ? (number / 1000).toFixed(number % 1000 === 0 ? 0 : 1) + " kHz"
            : number.toFixed(param.scale === "log" ? 0 : decimals) + (!param.unit ? "" : (param.unit.startsWith(":") || param.unit === "%") ? param.unit : " " + param.unit)
        return text.replace("-", "−")
    }
}
