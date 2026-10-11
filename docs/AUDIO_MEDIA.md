# Audio and Media

How audio control and media player integration work in iNiR.

## Audio

### PipeWire integration

iNiR controls audio through PipeWire via the Quickshell PipeWire module and `wpctl` (WirePlumber's CLI). This means it works with PipeWire out of the box, no PulseAudio compatibility layer needed.

### Volume control

Keybinds and OSD handle the basics:

| Key | Action |
|-----|--------|
| Volume Up / Down | Adjust default sink volume |
| Mute | Toggle default sink mute |
| Mic Mute | Toggle default source mute |

The OSD (on-screen display) appears for volume and brightness changes, showing the current level with an animated bar.

### Per-app mixer

The right sidebar (ii) and action center (waffle) include a per-app volume mixer. Each app that's outputting audio appears with its own volume slider. You can mute individual apps or adjust their volume independently.

### Visualizer source filters

Visualizer app filters are exclusions, not an allowlist. In **Settings → Quick → Filters**, enabling a filter for an audio app prevents that app from being selected to drive Cava/visualizers. With no visualizer filters enabled, iNiR follows the active player automatically. Cava captures the monitor of the selected playback sink rather than a recording source, so source resolution never falls through to the system microphone. The list is populated from live PipeWire applications, and manual desktop-entry filters can be added when an app is not currently producing audio.

### Organic visualizer

Bars, M3, Pill and Vertical layouts can use the **Organic** visualizer mode. Instead of drawing a conventional spectrum inside the panel, Organic grows from the panel edges and follows the host geometry while keeping the bar's layout and exclusive zone unchanged. Its response, reach, glow, idle motion and related controls live with the normal visualizer settings.

### EasyEffects

If EasyEffects is installed, iNiR detects its virtual sink and controls the physical sink behind it instead. This means volume control works correctly whether EasyEffects is running or not. A toggle in the right sidebar/action center lets you enable/disable EasyEffects.

On EasyEffects 8.2.8 or newer, the ii media controls can also open a native 10-band output equalizer. It is opt-in under **Settings → Modules → Optional → EasyEffects Equalizer**. When disabled, iNiR does not construct the equalizer panel or its IPC owner. When enabled, iNiR talks to EasyEffects through its local server, discovers the actual `equalizer#N` instance, mirrors gain changes to left and right channels, and leaves the rest of the user's effects chain untouched. The audio bundle includes the Linux Studio Plugins LV2 backend used by EasyEffects' Equalizer. On a fresh EasyEffects setup with an empty output pipeline, iNiR creates and loads a neutral `iNiR Equalizer` preset so the 10-band control works immediately. If the output pipeline already contains other effects, iNiR never replaces them just to add Equalizer; the panel instead asks the user to add Equalizer in EasyEffects and detects it automatically.

Under iRiS, the **Audio Engine** (`Mod+U`, `inir audioEngine toggle`, or a right click on the Control Center's Effects control) puts six core effects in front of the EasyEffects output chain you already have: Equalizer (8, 10, 12, 16 or 32 bands), Filter, Bass Enhancer, Exciter, Autogain and Limiter. Built-in sounds change only the core effects that are on; your own presets keep everything, including any other EasyEffects effect you add. Opening it never changes the chain. The Equalizer, Filter and Limiter run on the LSP plugins, the Bass Enhancer and Exciter on Calf, the microphone Autotune on x42; the audio bundle installs all three. It is switched off, and chooses between over the desktop and a window, under **Settings → Sound & Feedback → Audio Engine**.

The Equalizer keeps headroom by default (its input falls as far as its highest band rises) and suggests the Limiter when bands are boosted without it; a live spectrum plays behind its bands. Hold the compare button to hear everything without effects (`inir audioEngine bypass` toggles it). A preset you change shows as changed and can be reverted. Each output can remember a sound, played whenever it becomes the output. Presets export as iNiR or EasyEffects files and import from either. The **Microphone** page puts its own chain (low cut, noise reduction, noise gate, autotune, leveler, limiter) in front of what apps record, with sounds for calls, streaming and noisy rooms. The Island can carry a **Sound** page (Settings → Island → Pages → Navigation).

The **Volume** page (`inir audioEngine page mixer`) is a mixer: the speakers and the microphone in use, every output and input device, and every app playing or recording, each with its level, mute and a live meter; it works with EasyEffects off. An app opens to where it plays or records from, whether the effects reach it (leaving it out reloads the chain once and lasts whenever it plays again) and a sound it brings while it plays, restored when it stops. EasyEffects plays on one device at a time, so an app sent to another device leaves the effects. The **Autogain** page measures what you hear as EBU R128 loudness (momentary, short-term, integrated and peak) against its target; the meter uses NumPy from iNiR's Python environment and records only while the page is open. An **Audio Engine bubble** (Settings → Bubbles) lights up while a sound is on; its card switches sounds, the microphone's sound and the effects, its wheel steps through the sounds and a middle click hears without effects. Now Playing on the Island and the player card carry a shortcut to the Audio Engine. Under **Settings → Sound & Feedback → Audio Engine**, *Start with a sound* starts EasyEffects with iNiR and plays the sound you pick, and optionally a microphone sound.

### IPC

```bash
inir audio volumeUp         # Increase volume
inir audio volumeDown       # Decrease volume
inir audio mute             # Toggle output mute
inir audio micMute          # Toggle mic mute
```

## Media players

### MPRIS support

iNiR picks up any MPRIS-compatible media player automatically. Spotify, Firefox, mpv, VLC, Celluloid, Amberol, whatever speaks MPRIS shows up in the media controls.

The media player widget appears in:
- The bar (compact now-playing indicator)
- Media controls popup (`iiMediaControls`)
- Right sidebar
- Waffle action center

### Player prioritization

When multiple players are active, iNiR picks the most relevant one:

1. A player that's currently playing beats one that's paused
2. The user's manually selected ("tracked") player beats auto-detection
3. If nothing is playing, the last active player stays visible

### YT Music

The left sidebar includes a full YT Music player. It uses mpv for playback and yt-dlp for stream extraction. Search, queue management, playlists, and playback controls all work from within the shell.

When YT Music is playing via the sidebar AND a browser tab is also showing YT Music, iNiR deduplicates them in the media controls (you see one player, not two).

### Media controls layouts

The media controls popup has multiple layout presets you can choose from in Settings. Different presets show different arrangements of album art, controls, and track info.

## SongRec (music recognition)

If SongRec is installed, you can trigger music recognition from the shell. It listens to your audio output, identifies the song (Shazam-style), and shows the result. Useful when you hear something playing and want to know what it is.
