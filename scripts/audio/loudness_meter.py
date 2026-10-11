#!/usr/bin/env python3
"""Loudness of what an output plays, as ITU-R BS.1770 / EBU R128 measure it.

Records the output's monitor with pw-record and prints one JSON line every 200 ms:
momentary (400 ms) and short-term (3 s) loudness in LUFS, integrated loudness since
the meter started (absolute gate -70 LUFS, relative gate -10 LU) and the sample peak
in dBFS. Silence reads as null.

The K-weighting is applied as its power response on each window's spectrum: the mean
square of the filtered signal is the same sum by Parseval, without a sample-by-sample
filter in Python. The capture stream names its target, so EasyEffects never claims it.

Usage:
    loudness_meter.py --target NODE_NAME
"""

import argparse
import json
import math
import os
import signal
import subprocess
import sys

try:
    import numpy as np
except ImportError:
    np = None

RATE = 48000
HOP = RATE // 10          # 100 ms: the gating blocks overlap by 75 %
MOMENTARY = RATE * 4 // 10
SHORT = RATE * 3
EMIT_EVERY = 2            # hops
# BS.1770-4 K-weighting at 48 kHz: a high shelf, then the RLB high-pass.
STAGES = [([1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585]),
          ([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])]


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def power_response(size: int):
    """|H(f)|^2 of the K-weighting on the bins of an rfft of `size` samples."""
    w = 2 * np.pi * np.arange(size // 2 + 1) / size
    z = np.exp(-1j * w)
    response = np.ones_like(w)
    for b, a in STAGES:
        num = b[0] + b[1] * z + b[2] * z * z
        den = a[0] + a[1] * z + a[2] * z * z
        response = response * np.abs(num / den) ** 2
    return response


def mean_square(window, weight) -> float:
    """K-weighted mean square summed over the channels (each weighs 1 for stereo)."""
    size = window.shape[0]
    spectrum = np.fft.rfft(window, axis=0)
    energy = (np.abs(spectrum) ** 2) * weight[:, None]
    # One-sided spectrum: every bin but DC (and Nyquist for an even size) stands for two.
    energy[1:size // 2 + (size % 2)] *= 2
    return float(energy.sum() / (size * size))


def lufs(power: float):
    return None if power <= 1e-10 else round(-0.691 + 10 * math.log10(power), 1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    if np is None:
        emit({"error": "numpy"})
        return 1
    command = ["pw-record", "--target", args.target, "-P", "{ stream.capture.sink = true stream.monitor = true media.category = Monitor "
               "node.name = \"inir-loudness\" media.name = \"Loudness meter\" node.dont-reconnect = true }",
               "--format", "f32", "--rate", str(RATE), "--channels", "2", "-"]
    try:
        recorder = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        emit({"error": "pw-record"})
        return 1

    def stop(*_):
        recorder.terminate()
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    weights = {MOMENTARY: power_response(MOMENTARY), SHORT: power_response(SHORT)}
    history = np.zeros((SHORT, 2), dtype=np.float64)
    filled = 0
    blocks = []               # momentary mean squares, one per hop, for the integrated gate
    hops = 0
    peak = 0.0
    chunk = HOP * 2 * 4
    while True:
        data = recorder.stdout.read(chunk)
        if not data or len(data) < chunk:
            break
        frames = np.frombuffer(data, dtype=np.float32).reshape(-1, 2).astype(np.float64)
        history = np.roll(history, -HOP, axis=0)
        history[-HOP:] = frames
        filled = min(SHORT, filled + HOP)
        peak = max(peak, float(np.abs(frames).max()))
        if filled < MOMENTARY:
            continue
        momentary = mean_square(history[-MOMENTARY:], weights[MOMENTARY])
        blocks.append(momentary)
        hops += 1
        if hops % EMIT_EVERY:
            continue
        short = mean_square(history, weights[SHORT]) if filled >= SHORT else None
        gated = [p for p in blocks if p > 10 ** ((-70 + 0.691) / 10)]
        integrated = None
        if gated:
            relative = 10 ** ((lufs(sum(gated) / len(gated)) - 10 + 0.691) / 10)
            kept = [p for p in gated if p > relative]
            integrated = lufs(sum(kept) / len(kept)) if kept else None
        emit({"momentary": lufs(momentary), "short": lufs(short) if short is not None else None,
              "integrated": integrated, "peak": None if peak <= 1e-6 else round(20 * math.log10(peak), 1)})
        peak = 0.0
    recorder.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
