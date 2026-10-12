#!/usr/bin/env python3
"""What an output can play, for the Audio Engine's tuned outputs.

Names the output (sink, active port, what kind of thing it is) from pw-dump, then,
for anything a microphone can hear, plays an exponential sine sweep through it and
records it with a hardware microphone. Deconvolving the recording with the sweep's
inverse (Farina) gives the output's impulse response: its first part is the linear
response, and each harmonic's distortion arrives on its own, earlier in time. From
those: the frequency response, where the low end gives out, where the top rolls
off, how much the low end distorts, and an equalizer correction at the engine's
ten octave bands. Headphones are not measured: the microphone cannot hear them.

A microphone is measured with the person's voice instead: a moment of quiet, then
ten seconds of speech. From those: the room's noise, where the speech sits and
whether it clips, the voice's pitch, and its long-term spectrum against the usual
shape of speech; and the input level that keeps it clear of clipping.

The sweep lives in XDG_RUNTIME_DIR for as long as it plays; nothing is recorded to disk.
Progress and the result are printed as JSON lines.

Usage:
    output_probe.py --sink NODE_NAME [--identify]
    output_probe.py --mic NODE_NAME [--volume PERCENT] [--identify]
"""

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import threading
import time
import wave

RATE = 48000
F1, F2 = 20.0, 20000.0
SWEEP = 5.0                # seconds of sweep
LEAD = 0.8                 # silence before it: the noise floor is read from the recording's start
TAIL = 1.2                 # silence after it: the room's decay and the stream's latency
LEVEL = 0.22               # about -13 dBFS, at the person's own volume
ISO_10 = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
HEADPHONE_PORTS = {"headphones", "headset", "handset", "earpiece"}
HEADPHONE_FORMS = {"headphone", "headset", "handset", "hands-free", "handsfree", "earpiece"}


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, separators=(",", ":")) + "\n")
    sys.stdout.flush()


# --- which output this is ---------------------------------------------------------


def _pairs(info) -> dict:
    """A route's info list ([n, key, value, key, value…]) as a dict."""
    if isinstance(info, dict):
        return info
    if not isinstance(info, list) or not info:
        return {}
    items = info[1:] if isinstance(info[0], int) else info
    return {str(items[i]): items[i + 1] for i in range(0, len(items) - 1, 2)}


def pw_dump() -> list:
    try:
        out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5)
        data = json.loads(out.stdout or "[]")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []
    return data if isinstance(data, list) else []


def default_sink(dump=None) -> str:
    """The output playing now by node name: the device itself, followed from EasyEffects' sink to the one driving it."""
    dump = pw_dump() if dump is None else dump
    nodes = {item.get("id"): (item.get("info") or {}).get("props") or {}
             for item in dump if str(item.get("type", "")).endswith("Node")}
    name = ""
    for item in dump:
        if str(item.get("type", "")).endswith("Metadata") and (item.get("props") or {}).get("metadata.name") == "default":
            entry = next((m for m in item.get("metadata") or [] if m.get("key") == "default.audio.sink"), None)
            value = (entry or {}).get("value")
            name = str(value.get("name", "")) if isinstance(value, dict) else ""
    props = next((p for p in nodes.values() if p.get("node.name") == name), {})
    if name.startswith("easyeffects_") or props.get("application.id") == "com.github.wwmm.easyeffects":
        name = str(nodes.get(props.get("node.driver-id"), {}).get("node.name") or "")
    return name


def identify(sink: str, dump=None) -> dict:
    """The output by node name: its port, what kind of thing plays it, and a microphone that could hear it."""
    dump = pw_dump() if dump is None else dump
    nodes, devices = [], {}
    for item in dump:
        info = item.get("info") or {}
        props = info.get("props") or {}
        kind = str(item.get("type", ""))
        if kind.endswith("Node"):
            nodes.append((item.get("id"), props))
        elif kind.endswith("Device"):
            devices[item.get("id")] = (props, (info.get("params") or {}).get("Route") or [])
    node = next((props for _, props in nodes if props.get("node.name") == sink), None)
    if node is None:
        return {"sink": sink, "found": False}
    device_id = node.get("device.id")
    device_props, routes = devices.get(device_id, ({}, []))
    profile_device = node.get("card.profile.device")
    route = next((r for r in routes if r.get("direction") == "Output"
                  and (profile_device is None or r.get("device") == profile_device)), None)
    route_info = _pairs((route or {}).get("info"))
    port = str(route_info.get("port.type") or "").lower()
    form = str(node.get("device.form-factor") or device_props.get("device.form-factor") or "").lower()
    bus = str(node.get("device.bus") or device_props.get("device.bus") or "").lower()
    route_name = str((route or {}).get("name") or "")
    if port in HEADPHONE_PORTS or form in HEADPHONE_FORMS or "headphone" in route_name:
        kind = "headphones"
    elif port == "hdmi" or "hdmi" in route_name or "hdmi" in sink.lower():
        kind = "display"
    elif port == "line" or route_name.endswith("lineout"):
        kind = "line"
    else:
        kind = "speakers"
    built_in = form == "internal" or port == "speaker" or "speaker" in route_name
    # A microphone on the same card first (a laptop's own), then any other the hardware has.
    sources = [(nid, props) for nid, props in nodes
               if props.get("media.class") == "Audio/Source" and not str(props.get("node.name", "")).startswith("easyeffects")
               and "monitor" not in str(props.get("node.name", ""))]
    sources.sort(key=lambda entry: entry[1].get("device.id") != device_id)
    description = str((route or {}).get("description") or node.get("node.description") or sink)
    return {"sink": sink, "found": True, "route": route_name, "description": description,
            "device": str(node.get("node.description") or device_props.get("device.description") or sink),
            "kind": kind, "builtIn": built_in, "bus": bus,
            "codec": str(node.get("api.bluez5.codec") or ""),
            "rate": int(node.get("audio.rate") or 0) or None,
            "channels": int(node.get("audio.channels") or 0) or None,
            "source": str(sources[0][1].get("node.name")) if sources else ""}


def identify_source(source: str, dump=None) -> dict:
    """A microphone by node name (or, when that one is gone, the first the hardware has): its port and its kind."""
    dump = pw_dump() if dump is None else dump
    nodes, devices = [], {}
    for item in dump:
        info = item.get("info") or {}
        kind = str(item.get("type", ""))
        if kind.endswith("Node"):
            nodes.append(info.get("props") or {})
        elif kind.endswith("Device"):
            devices[item.get("id")] = (info.get("props") or {}, (info.get("params") or {}).get("Route") or [])
    hardware = [props for props in nodes if props.get("media.class") == "Audio/Source"
                and not str(props.get("node.name", "")).startswith("easyeffects")
                and "monitor" not in str(props.get("node.name", ""))]
    node = next((props for props in hardware if props.get("node.name") == source), None) \
        or (hardware[0] if hardware else None)
    if node is None:
        return {"source": source, "found": False}
    device_props, routes = devices.get(node.get("device.id"), ({}, []))
    profile_device = node.get("card.profile.device")
    route = next((r for r in routes if r.get("direction") == "Input"
                  and (profile_device is None or r.get("device") == profile_device)), None)
    port = str(_pairs((route or {}).get("info")).get("port.type") or "").lower()
    route_name = str((route or {}).get("name") or "")
    bus = str(node.get("device.bus") or device_props.get("device.bus") or "").lower()
    form = str(node.get("device.form-factor") or device_props.get("device.form-factor") or "").lower()
    if port == "headset" or "headset" in route_name or form in HEADPHONE_FORMS:
        kind = "headset"
    elif bus == "bluetooth":
        kind = "bluetooth"
    elif bus == "usb":
        kind = "usb"
    elif form == "internal" or "internal" in route_name:
        kind = "internal"
    else:
        kind = "external"
    return {"source": str(node.get("node.name")), "found": True, "route": route_name, "kind": kind, "bus": bus,
            "description": str((route or {}).get("description") or node.get("node.description") or source),
            "device": str(node.get("node.description") or device_props.get("device.description") or source)}


# --- the sweep -----------------------------------------------------------------------


def sweep(np, rate: int = RATE, seconds: float = SWEEP):
    """The exponential sweep and its inverse filter (time-reversed, with -6 dB/octave to make it white)."""
    t = np.arange(int(rate * seconds)) / rate
    k = math.log(F2 / F1)
    x = np.sin(2 * math.pi * F1 * seconds / k * (np.exp(t * k / seconds) - 1))
    fade = int(rate * 0.02)
    x[:fade] *= np.linspace(0, 1, fade)
    x[-fade:] *= np.linspace(1, 0, fade)
    inverse = x[::-1] * np.exp(-t * k / seconds)
    # Normalised so the deconvolved linear response reads 0 dB at the sweep's middle frequencies.
    spectrum = np.abs(np.fft.rfft(x, 1 << 20) * np.fft.rfft(inverse, 1 << 20))
    freqs = np.fft.rfftfreq(1 << 20, 1 / rate)
    band = (freqs > 500) & (freqs < 2000)
    inverse /= float(np.median(spectrum[band]))
    return x, inverse


def _write_wav(path: str, samples, np) -> None:
    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(np.repeat(pcm[:, None], 2, axis=1).tobytes())


def record_sweep(np, sink: str, source: str, level: float):
    """Play the sweep through the output while the microphone records; the recording, mono float."""
    signal_, _ = sweep(np)
    padded = np.concatenate([np.zeros(int(RATE * LEAD)), signal_ * level, np.zeros(int(RATE * TAIL))])
    folder = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    fd, path = tempfile.mkstemp(prefix="inir-sweep-", suffix=".wav", dir=folder)
    os.close(fd)
    chunks = []
    try:
        _write_wav(path, padded, np)
        recorder = subprocess.Popen(
            ["pw-record", "--target", source, "-P",
             "{ node.name = \"inir-audio-probe-in\" media.name = \"Audio Engine test\" node.dont-reconnect = true }",
             "--format", "f32", "--rate", str(RATE), "--channels", "1", "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

        def drain():
            while True:
                data = recorder.stdout.read(16384)
                if not data:
                    return
                chunks.append(data)

        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        time.sleep(0.3)
        emit({"stage": "sweep", "seconds": round(LEAD + SWEEP + TAIL, 1)})
        player = subprocess.run(
            ["pw-play", "--target", sink, "-P",
             "{ node.name = \"inir-audio-probe\" media.name = \"Audio Engine test\" media.role = \"Production\" }", path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=LEAD + SWEEP + TAIL + 10)
        time.sleep(0.4)
        recorder.terminate()
        recorder.wait(timeout=3)
        reader.join(timeout=3)
        if player.returncode != 0:
            raise RuntimeError("probe_failed")
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    raw = b"".join(chunks)
    raw = raw[:len(raw) - len(raw) % 4]
    # A stream that is just starting can hand over a sample that is not a number; one would poison every FFT after it.
    return np.nan_to_num(np.frombuffer(raw, dtype=np.float32).astype(np.float64), nan=0.0, posinf=0.0, neginf=0.0)


# --- reading the recording -----------------------------------------------------------


def _windowed(np, ir, centre: int, before: int, length: int):
    start = centre - before
    if start < 0 or start + length > len(ir):
        return None
    part = ir[start:start + length].copy()
    rise = before
    part[:rise] *= np.hanning(2 * rise)[:rise]
    fall = length // 4
    part[-fall:] *= np.hanning(2 * fall)[fall:]
    return part


def _smoothed(np, part, points, width: float = 1 / 3):
    """Power in a fractional-octave band around each point, in dB."""
    n = 1 << 16
    power = np.abs(np.fft.rfft(part, n)) ** 2
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    half = 2 ** (width / 2)
    out = []
    for f in points:
        band = (freqs >= f / half) & (freqs <= f * half)
        value = float(power[band].mean()) if band.any() else 0.0
        out.append(10 * math.log10(max(value, 1e-20)))
    return np.array(out)


def analyse(np, recording, rate: int = RATE) -> dict:
    """The output's response from a recording of the sweep: see the module's description."""
    _, inverse = sweep(np, rate)
    if len(recording) < rate * (LEAD + SWEEP):
        return {"measured": False, "reason": "too_quiet", "snr": 0.0}
    clipped = float(np.abs(recording).max()) >= 0.99
    n = 1 << int(math.ceil(math.log2(len(recording) + len(inverse))))
    ir = np.fft.irfft(np.fft.rfft(recording, n) * np.fft.rfft(inverse, n), n)
    peak = int(np.argmax(np.abs(ir)))
    # Where the sweep starts in the recording, whatever the stream's latency: the noise floor is read before it.
    start = max(0, peak - len(inverse) + 1)
    # A peak with no whole sweep after it is noise, not the output's answer.
    if start + int(rate * SWEEP) > len(recording):
        return {"measured": False, "reason": "too_quiet", "snr": 0.0}
    before, length = int(rate * 0.002), int(rate * 0.06)
    linear = _windowed(np, ir, peak, before, length)
    # The deconvolved noise floor: after the linear response has died away (the harmonics arrive before it). The sweep's
    # processing gain lifts the output well above a noisy microphone, so this is the signal-to-noise that counts.
    floor_at = peak + int(rate * 0.3)
    quiet = _windowed(np, ir, floor_at, before, length)
    if linear is None or quiet is None:
        return {"measured": False, "reason": "too_quiet", "snr": 0.0}
    energy = float(np.mean(ir[peak - before:peak + int(rate * 0.01)] ** 2))
    snr = 10 * math.log10(max(energy, 1e-20) / max(float(np.mean(ir[floor_at:floor_at + length] ** 2)), 1e-20))
    if snr < 20:
        return {"measured": False, "reason": "too_quiet", "snr": round(snr, 1)}

    points = [F1 * (F2 / F1) ** (i / 59) for i in range(60)]
    response = _smoothed(np, linear, points)
    # Where the output does not rise 6 dB over the noise it is not playing, whatever the noise reads as.
    heard = response - _smoothed(np, quiet, points) >= 6
    mids = [i for i, f in enumerate(points) if 400 <= f <= 4000 and heard[i]] \
        or [i for i, f in enumerate(points) if 400 <= f <= 4000]
    reference = float(np.median(response[mids]))
    curve = np.where(heard, response - reference, np.minimum(response - reference, -15.0))

    def edge(start_hz: float, step: int) -> float:
        i = min(range(len(points)), key=lambda j: abs(points[j] - start_hz))
        # Held for two points running: one narrow notch (a cabinet resonance, a reflection) is not where it gives out.
        while 0 <= i < len(points) and 0 <= i + step < len(points):
            if curve[i] < -10 and curve[i + step] < -10:
                return points[i]
            i += step
        return points[0] if step < 0 else points[-1]

    low = min(800.0, max(30.0, edge(1000, -1)))
    high = max(2000.0, min(20000.0, edge(3000, 1)))

    # Harmonic distortion: the k-th harmonic's response arrives T·ln(k)/ln(F2/F1) before the linear one, on the
    # k-times-higher frequency axis. Read over the low end the output still plays, where small drivers strain.
    k = math.log(F2 / F1)
    shift = {h: int(rate * SWEEP * math.log(h) / k) for h in (2, 3)}
    harmonics = {h: _windowed(np, ir, peak - shift[h], before, length) for h in (2, 3)}
    thd = 0.0
    if all(part is not None for part in harmonics.values()):
        lows = [f for f in points if low <= f <= min(1000.0, low * 4)]
        if lows:
            fund = _smoothed(np, linear, lows)
            h2 = _smoothed(np, harmonics[2], [2 * f for f in lows])
            h3 = _smoothed(np, harmonics[3], [3 * f for f in lows])
            ratio = np.sqrt((10 ** (h2 / 10) + 10 ** (h3 / 10)) / 10 ** (fund / 10))
            thd = float(np.median(ratio))
    strain = max(0.0, min(1.0, (thd - 0.03) / 0.12))

    # The correction, octave by octave: only where the microphone is trustworthy and the output can play; a fraction
    # of the deviation, boosts held lower than cuts, because the microphone sits close and hears the chassis too.
    correction = []
    for fc in ISO_10:
        span = [i for i, f in enumerate(points) if fc / math.sqrt(2) <= f <= fc * math.sqrt(2)]
        deviation = float(np.mean(curve[span])) if span else 0.0
        if fc < max(150.0, low * 1.5) or fc > min(10000.0, high * 0.8):
            correction.append(0.0)
            continue
        correction.append(round(max(-6.0, min(4.0, -deviation * 0.6)) * 2) / 2)
    return {"measured": True, "snr": round(snr, 1), "clipped": clipped, "low": round(low), "high": round(high),
            "thd": round(thd * 100, 1), "strain": round(strain, 2), "correction": correction,
            "curve": [[round(f), round(max(-30.0, min(15.0, float(db))), 1)] for f, db in zip(points, curve)]}


# --- a voice -----------------------------------------------------------------------------

QUIET = 2.5                # seconds of quiet: the room's noise
SPEECH = 10.0              # seconds of speech
# The long-term spectrum of speech (octave levels against the 500 Hz octave, male and female voices together, after
# Byrne et al. 1994): what a voice is measured against. Its own pitch and the room tilt it away from this.
SPEECH_SHAPE = {125: -6.0, 250: -1.0, 500: 0.0, 1000: -5.0, 2000: -11.0, 4000: -15.0, 8000: -20.0}


def record_voice(np, source: str):
    """The quiet, then the speech, from the microphone; mono float."""
    chunks = []
    recorder = subprocess.Popen(
        ["pw-record", "--target", source, "-P",
         "{ node.name = \"inir-audio-probe-in\" media.name = \"Audio Engine test\" node.dont-reconnect = true }",
         "--format", "f32", "--rate", str(RATE), "--channels", "1", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def drain():
        while True:
            data = recorder.stdout.read(16384)
            if not data:
                return
            chunks.append(data)

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    emit({"stage": "quiet", "seconds": QUIET})
    time.sleep(QUIET + 0.2)
    emit({"stage": "speak", "seconds": SPEECH})
    time.sleep(SPEECH + 0.2)
    recorder.terminate()
    recorder.wait(timeout=3)
    reader.join(timeout=3)
    raw = b"".join(chunks)
    raw = raw[:len(raw) - len(raw) % 4]
    samples = np.nan_to_num(np.frombuffer(raw, dtype=np.float32).astype(np.float64), nan=0.0, posinf=0.0, neginf=0.0)
    split = int(RATE * (QUIET + 0.1))
    return samples[int(RATE * 0.4):split], samples[split:]


def _db(value: float) -> float:
    return 20 * math.log10(max(value, 1e-9))


def _pitch(np, frame) -> float:
    """The fundamental of one voiced frame by autocorrelation, 70–400 Hz; 0 when it is not voiced."""
    frame = frame - frame.mean()
    spectrum = np.fft.rfft(frame, 2 * len(frame))
    corr = np.fft.irfft(np.abs(spectrum) ** 2)[:len(frame)]
    if corr[0] <= 0:
        return 0.0
    lo, hi = int(RATE / 400), int(RATE / 70)
    lag = lo + int(np.argmax(corr[lo:hi]))
    return RATE / lag if corr[lag] / corr[0] > 0.45 else 0.0


def analyse_voice(np, quiet, speech, volume: int = 0) -> dict:
    """What a microphone makes of this voice in this room; see the module's description."""
    if len(speech) < RATE * 3 or len(quiet) < RATE * 0.5:
        return {"measured": False, "reason": "no_speech"}
    noise = _db(float(np.sqrt(np.mean(quiet ** 2))))
    size, hop = int(RATE * 0.04), int(RATE * 0.01)
    frames = [speech[i:i + size] for i in range(0, len(speech) - size, hop)]
    levels = np.array([_db(float(np.sqrt(np.mean(f ** 2)))) for f in frames])
    active = levels > max(noise + 10, -65)
    if active.sum() * hop < RATE * 1.5:
        return {"measured": False, "reason": "no_speech", "noise": round(noise, 1)}
    level = float(np.median(levels[active]))
    peak = _db(float(np.abs(speech).max()))
    clipped = bool(np.mean(np.abs(speech) >= 0.99) > 1e-4)
    pitches = [p for p in (_pitch(np, frames[i]) for i in np.flatnonzero(active)[::3]) if p > 0]
    pitch = float(np.median(pitches)) if len(pitches) >= 10 else 0.0
    low_pitch = float(np.percentile(pitches, 10)) if len(pitches) >= 10 else 0.0

    # The voice's long-term spectrum, over the frames where it speaks, as octave and third-octave levels.
    window = np.hanning(size)
    power = np.zeros(size // 2 + 1)
    for i in np.flatnonzero(active):
        power += np.abs(np.fft.rfft(frames[i] * window)) ** 2
    freqs = np.fft.rfftfreq(size, 1 / RATE)

    def level_at(fc: float, width: float) -> float:
        band = (freqs >= fc / 2 ** (width / 2)) & (freqs < fc * 2 ** (width / 2))
        return 10 * math.log10(max(float(power[band].sum()), 1e-20))

    shape = {fc: level_at(fc, 1) for fc in SPEECH_SHAPE}
    centre = float(np.mean([shape[fc] - SPEECH_SHAPE[fc] for fc in (250, 500, 1000, 2000)]))
    deviation = {fc: shape[fc] - centre - SPEECH_SHAPE[fc] for fc in SPEECH_SHAPE}
    correction = [round(max(-6.0, min(4.0, -deviation[fc] * 0.5)) * 2) / 2 if fc in deviation else 0.0
                  for fc in ISO_10]
    # Sibilance: the top octaves standing out of the speech shape; the 8 kHz band takes a little more off.
    sibilance = round(max(0.0, (deviation[4000] + deviation[8000]) / 2), 1)
    if sibilance > 4:
        correction[8] = max(-6.0, correction[8] - 2.0)
    points = [100 * (10000 / 100) ** (i / 39) for i in range(40)]
    third = [level_at(f, 1 / 3) - centre for f in points]
    mids = float(np.median([v for f, v in zip(points, third) if 300 <= f <= 3000]))
    curve = [[round(f), round(max(-30.0, min(15.0, v - mids)), 1)] for f, v in zip(points, third)]

    # The input level: clipping takes it down until its peaks sit around -6 dBFS; a voice lost in the floor takes it up.
    # PipeWire's volume is cubic: 60·log10 of the fraction is its gain in dB.
    change = 0.0
    if clipped or peak > -1.5:
        change = min(-6.0, -6 - peak) if clipped else -6 - peak
    elif level < -40:
        change = min(12.0, -30 - level)
    suggested = None
    if volume and abs(change) >= 1.5:
        suggested = max(5, min(100, round(volume * 10 ** (change / 60))))
        change = 60 * math.log10(suggested / volume)
    else:
        change = 0.0
    noise, level, peak = noise + change, level + change, peak + change
    gate = max(noise + 6, min(level - 12, noise + 0.35 * (level - noise)))
    cut = max(50.0, min(150.0, round(low_pitch * 0.6 / 5) * 5)) if low_pitch else 80.0
    return {"measured": True, "noise": round(noise, 1), "speech": round(level, 1), "peak": round(peak, 1),
            "clipped": clipped, "pitch": round(pitch), "cut": cut, "gate": round(gate, 1), "sibilance": sibilance,
            "snr": round(level - noise, 1), "correction": correction, "curve": curve, "volume": suggested}


def estimate(device: dict, reason: str) -> dict:
    """What the kind of output says, when it cannot be heard."""
    flat = [0.0] * len(ISO_10)
    if device.get("kind") == "headphones":
        return {"measured": False, "reason": reason, "low": None, "high": 16000 if device.get("codec") == "sbc" else 20000,
                "strain": 0.0, "correction": flat}
    # Small built-in speakers rarely play below ~150 Hz.
    return {"measured": False, "reason": reason, "low": 150 if device.get("builtIn") else None, "high": 20000,
            "strain": 0.3 if device.get("builtIn") else 0.0, "correction": flat}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sink", default="")
    parser.add_argument("--mic", default="")
    parser.add_argument("--volume", type=int, default=0)
    parser.add_argument("--identify", action="store_true")
    args = parser.parse_args()
    emit({"stage": "identify"})
    if args.mic:
        return measure_mic(args)
    device = identify(args.sink)
    if not device.get("found"):
        emit({"error": "no_output"})
        return 1
    if args.identify:
        emit({"device": device})
        return 0
    if device["kind"] == "headphones":
        emit({"device": device, "result": estimate(device, "headphones")})
        return 0
    if not device.get("source"):
        emit({"device": device, "result": estimate(device, "no_mic")})
        return 0
    try:
        import numpy as np
    except ImportError:
        emit({"error": "needs_numpy"})
        return 1
    level = LEVEL
    result = None
    for _ in range(2):
        try:
            recording = record_sweep(np, args.sink, device["source"], level)
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            emit({"error": "probe_failed"})
            return 1
        emit({"stage": "analyse"})
        result = analyse(np, recording)
        # Too loud for the microphone: once more, 9 dB down.
        if not result.get("clipped"):
            break
        level /= 2.8
    if not result.get("measured"):
        result = dict(estimate(device, result.get("reason", "too_quiet")), snr=result.get("snr"))
    emit({"device": device, "result": result})
    return 0


def measure_mic(args) -> int:
    device = identify_source(args.mic)
    if not device.get("found"):
        emit({"error": "no_mic"})
        return 1
    if args.identify:
        emit({"device": device})
        return 0
    try:
        import numpy as np
    except ImportError:
        emit({"error": "needs_numpy"})
        return 1
    try:
        quiet, speech = record_voice(np, device["source"])
    except (OSError, subprocess.TimeoutExpired):
        emit({"error": "probe_failed"})
        return 1
    emit({"stage": "analyse"})
    result = analyse_voice(np, quiet, speech, args.volume)
    emit({"device": device, "result": result})
    return 0


if __name__ == "__main__":
    sys.exit(main())
