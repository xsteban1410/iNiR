#!/usr/bin/env python3
"""Audio Engine helper: drives EasyEffects' output and microphone chains for iNiR.

Reads one JSON request per line on stdin and writes one JSON event per line on
stdout. Knob moves go to EasyEffects live through set_property; changing which
effects are in a chain writes a preset ("iNiR Audio Engine", "iNiR Microphone")
and loads it, because the EasyEffects socket has no command to add or remove an
effect. A preset loaded that way resets every value it does not carry, so a
chain is always loaded bypassed and every value is sent again afterwards.

Each chain's core effects sit in front of whatever chain the user already had;
that chain is kept, with its values.

Tuned outputs (at most five, each with its own name, so speakers and headphones on
one sink never write over each other) come from output_probe.py; while one is
chosen, every built-in sound is shaped to it.

Usage:
    audio_engine.py --presets-dir DIR --state-file FILE
"""

import argparse
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# output_probe.py sits beside this file; it is imported only where a device is identified, also under python -I.
sys.path.insert(0, str(HERE))
FLATPAK_ID = "com.github.wwmm.easyeffects"
PIPES = {
    "output": {"core": ["equalizer", "filter", "bass_enhancer", "exciter", "autogain", "limiter"],
               "section": "StreamOutputs", "preset": "iNiR Audio Engine"},
    "input": {"core": ["filter", "rnnoise", "gate", "equalizer", "autotune", "compressor", "limiter"],
              "section": "StreamInputs", "preset": "iNiR Microphone"},
}
CORE = PIPES["output"]["core"]
BAND_COUNTS = [8, 10, 12, 16, 32]
NEEDS = {"equalizer": "lsp", "filter": "lsp", "limiter": "lsp", "gate": "lsp", "compressor": "lsp",
         "bass_enhancer": "calf", "exciter": "calf", "autotune": "x42"}
NOTES = ["noteC", "noteCSharp", "noteD", "noteDSharp", "noteE", "noteF", "noteFSharp", "noteG",
         "noteGSharp", "noteA", "noteASharp", "noteB"]
SCALES = {"chromatic": list(range(12)), "major": [0, 2, 4, 5, 7, 9, 11], "minor": [0, 2, 3, 5, 7, 8, 10],
          "pentatonic": [0, 2, 4, 7, 9], "minorPentatonic": [0, 3, 5, 7, 10], "blues": [0, 3, 5, 6, 7, 10]}
BAND_PROPS = ["Gain", "Frequency", "Q", "Width", "Type", "Mode", "Slope", "Solo", "Mute"]
# Third-octave ISO centres for 32 bands, octave ISO centres for 10.
ISO_32 = [16, 20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
          1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]
ISO_10 = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
NAME_MAX = 64
OUTPUTS_MAX = 5
OUTPUT_NAME_MAX = 32
# Where each chain keeps its tuned devices in the state, and what names the device.
TUNED = {"output": {"list": "outputs", "choice": "tuning", "follow": "tuningFollow", "prefix": "out", "device": "sink"},
         "input": {"list": "inputs", "choice": "micTuning", "follow": "micTuningFollow", "prefix": "in",
                   "device": "source"}}


def finite(value):
    """JSON has no NaN or infinity, and the shell's parser refuses a line that carries one: such a number is null."""
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {k: finite(v) for k, v in value.items()}
    if isinstance(value, list):
        return [finite(v) for v in value]
    return value


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(finite(event), separators=(",", ":")) + "\n")
    sys.stdout.flush()


def nice_frequency(f: float) -> float:
    if f < 100:
        return float(round(f))
    if f < 1000:
        return float(round(f / 5) * 5)
    if f < 10000:
        return float(round(f / 50) * 50)
    return float(round(f / 500) * 500)


def band_frequencies(count: int) -> list:
    if count == 10:
        return [float(f) for f in ISO_10]
    if count == 32:
        return [float(f) for f in ISO_32]
    return [nice_frequency(32 * (500 ** (i / (count - 1)))) for i in range(count)]


def band_q(frequencies: list) -> float:
    """Constant-Q for bands spaced like these, so neighbours meet without gaps."""
    span = math.log2(frequencies[-1] / frequencies[0]) / (len(frequencies) - 1)
    ratio = 2 ** span
    return round(math.sqrt(ratio) / (ratio - 1), 2)


def interpolate(points: list, frequencies: list) -> list:
    """Gains of a curve given as [(frequency, gain)] at other frequencies (log scale)."""
    points = sorted(points)
    out = []
    for f in frequencies:
        if f <= points[0][0]:
            out.append(points[0][1])
            continue
        if f >= points[-1][0]:
            out.append(points[-1][1])
            continue
        for (f0, g0), (f1, g1) in zip(points, points[1:]):
            if f0 <= f <= f1:
                t = math.log(f / f0) / math.log(f1 / f0)
                out.append(round(g0 + (g1 - g0) * t, 1))
                break
    return out


def kind_of(plugin_id: str) -> str:
    return plugin_id.split("#", 1)[0]


def rounded(value):
    if isinstance(value, float):
        return round(value, 2)
    if isinstance(value, dict):
        return {k: rounded(v) for k, v in value.items()}
    if isinstance(value, list):
        return [rounded(v) for v in value]
    return value


class EasyEffects:
    """The EasyEffects install and its local socket."""

    def __init__(self) -> None:
        runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        self.socket_path = os.environ.get("EASYEFFECTS_SERVER_SOCKET") or f"{runtime}/EasyEffectsServer"
        self.sock = None
        self.buffer = b""
        # Whether the EasyEffects behind the open connection is the Flatpak: asked once per connection.
        self._flatpak = None

    # --- install and process -------------------------------------------------

    @staticmethod
    def native() -> bool:
        return shutil.which("easyeffects") is not None

    @staticmethod
    def flatpak() -> bool:
        if shutil.which("flatpak") is None:
            return False
        return subprocess.run(["flatpak", "info", FLATPAK_ID], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0

    @staticmethod
    def pid():
        """The newest easyeffects process, as `pgrep -n -x easyeffects` finds it, read from /proc without a process."""
        newest, newest_start = None, -1
        try:
            entries = [entry.name for entry in os.scandir("/proc") if entry.name.isdigit()]
        except OSError:
            return None
        for name in entries:
            try:
                with open(f"/proc/{name}/comm", "rb") as comm:
                    if comm.read().strip() != b"easyeffects":
                        continue
                with open(f"/proc/{name}/stat", "rb") as stat_file:
                    stat = stat_file.read()
            except OSError:
                continue
            started = int(stat[stat.rfind(b")") + 2:].split()[19])
            if started > newest_start:
                newest, newest_start = int(name), started
        return newest

    def running_flatpak(self) -> bool:
        if self.sock is not None and self._flatpak is not None:
            return self._flatpak
        pid = self.pid()
        found = False
        if pid is not None:
            try:
                found = f"FLATPAK_ID={FLATPAK_ID}".encode() in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
            except OSError:
                pass
        if self.sock is not None:
            self._flatpak = found
        return found

    def config_file(self) -> Path:
        if self.running_flatpak():
            return Path.home() / f".var/app/{FLATPAK_ID}/config/easyeffects/db/easyeffectsrc"
        base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        return Path(base) / "easyeffects/db/easyeffectsrc"

    def preset_dir(self, pipe: str) -> Path:
        if self.running_flatpak():
            return Path.home() / f".var/app/{FLATPAK_ID}/data/easyeffects/{pipe}"
        base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
        return Path(base) / f"easyeffects/{pipe}"

    def lv2_packages(self) -> set:
        """Which of lsp / calf the running EasyEffects can load."""
        pid = self.pid()
        root = Path(f"/proc/{pid}/root") if pid else Path("/")
        paths = ["/usr/lib/lv2", "/usr/lib64/lv2", "/usr/local/lib/lv2", "/usr/local/lib64/lv2",
                 "/app/lib/lv2", "/app/lib64/lv2", "/app/extensions/Plugins/lv2"]
        env = ""
        if pid:
            try:
                for item in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
                    if item.startswith(b"LV2_PATH="):
                        env = item[len(b"LV2_PATH="):].decode(errors="ignore")
            except OSError:
                pass
        else:
            env = os.environ.get("LV2_PATH", "")
            paths.append(str(Path.home() / ".lv2"))
        paths += [p for p in env.split(":") if p]
        found = set()
        for base in paths:
            folder = Path(str(root) + base) if pid and base.startswith("/") else Path(base)
            try:
                names = [entry.name for entry in folder.iterdir()]
            except OSError:
                continue
            if any(n.startswith("lsp") for n in names):
                found.add("lsp")
            if any(n.startswith("calf") for n in names):
                found.add("calf")
            if any(n.startswith("fat1") for n in names):
                found.add("x42")
        return found

    def start(self) -> bool:
        # In the background, as a service: no window, its icon in the tray.
        flags = ["--service-mode", "--hide-window"]
        if self.native():
            command = ["easyeffects", *flags]
        elif self.flatpak():
            command = ["flatpak", "run", FLATPAK_ID, *flags]
        else:
            return False
        subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(100):
            if self.connect():
                return True
            time.sleep(0.1)
        return False

    # --- socket ---------------------------------------------------------------

    def connect(self) -> bool:
        if self.sock is not None:
            return True
        if not os.path.exists(self.socket_path):
            return False
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(1.5)
            sock.connect(self.socket_path)
        except OSError:
            return False
        self.sock = sock
        self.buffer = b""
        self._flatpak = None
        return True

    def drop(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def send(self, line: str) -> bool:
        if not self.connect():
            return False
        try:
            self.sock.sendall((line + "\n").encode())
            return True
        except OSError:
            self.drop()
            return False

    def ask_many(self, lines: list) -> list:
        """Questions sent together: EasyEffects answers a connection's lines in order, so the replies are read back
        in turn instead of waiting on each one."""
        replies = []
        for at in range(0, len(lines), 256):
            batch = lines[at:at + 256]
            if not self.send("\n".join(batch)):
                break
            try:
                for _ in batch:
                    while b"\n" not in self.buffer:
                        chunk = self.sock.recv(65536)
                        if not chunk:
                            raise OSError("closed")
                        self.buffer += chunk
                    reply, self.buffer = self.buffer.split(b"\n", 1)
                    replies.append(reply.decode(errors="replace").strip())
            except OSError:
                self.drop()
                break
        return replies + [None] * (len(lines) - len(replies))

    def ask(self, line: str):
        return self.ask_many([line])[0]

    def get_many(self, pipe: str, paths: list) -> list:
        return [None if value is None or value.startswith("error_") else value
                for value in self.ask_many([f"get_property:{pipe}:{path}" for path in paths])]

    def get(self, pipe: str, path: str):
        return self.get_many(pipe, [path])[0]

    def set(self, pipe: str, path: str, value) -> bool:
        if isinstance(value, bool):
            value = "true" if value else "false"
        text = str(value)
        if "\n" in text:
            return False
        return self.send(f"set_property:{pipe}:{path}:{text}")

    def bypassed(self) -> bool:
        # The server answers 1 when bypassed and 2 when not, as one byte with no line break: it is taken from the
        # shared buffer like any reply, so a byte read ahead is never lost and never read as the next reply.
        if not self.send("get_global_bypass"):
            return False
        try:
            while not self.buffer.lstrip():
                chunk = self.sock.recv(4096)
                if not chunk:
                    self.drop()
                    return False
                self.buffer += chunk
        except OSError:
            self.drop()
            return False
        self.buffer = self.buffer.lstrip()
        reply, self.buffer = self.buffer[:1], self.buffer[1:]
        return reply == b"1"

    def bypass(self, on: bool) -> bool:
        """Set the global bypass and wait until EasyEffects reports it, so what is shown next is what is heard."""
        if not self.send(f"global_bypass:{1 if on else 0}"):
            return False
        deadline = time.monotonic() + 0.6
        while self.bypassed() != on and time.monotonic() < deadline:
            time.sleep(0.03)
        return True

    def quit(self) -> bool:
        if not self.send("quit_app"):
            return False
        self.drop()
        for _ in range(50):
            if not os.path.exists(self.socket_path) or self.pid() is None:
                return True
            time.sleep(0.1)
        return False

    def load_preset(self, pipe: str, name: str) -> bool:
        return self.send(f"load_preset:{pipe}:{name}")


class Engine:
    def __init__(self, presets_dir: Path, state_file: Path) -> None:
        self.ee = EasyEffects()
        self.presets_dir = presets_dir
        self.state_file = state_file
        schema = json.loads((HERE / "ee-schema.json").read_text(encoding="utf-8"))
        self.schema = schema["plugins"]
        self._channel = {p["name"]: p for p in self.schema["equalizer"]["channel"]}
        self.builtins = json.loads((HERE / "audio-presets.json").read_text(encoding="utf-8"))
        self.state = self._read_state()
        self._seen = None

    # --- persistent engine state --------------------------------------------

    def _read_state(self) -> dict:
        try:
            data = json.loads(self.state_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        # The first engine kept the output chain at the top level.
        pipes = data.setdefault("pipes", {})
        if "core" in data or "chain" in data:
            pipes.setdefault("output", {"core": data.pop("core", {}), "chain": data.pop("chain", [])})
        for pipe in PIPES:
            pipes.setdefault(pipe, {"core": {}, "chain": []})
        return data

    def _write_state(self) -> None:
        # The person's presets, so Settings can offer them while the helper is not running.
        self.state["presets"] = self.preset_names()
        self.state["micPresets"] = self.preset_names("input")
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(finite(self.state), indent=1) + "\n", encoding="utf-8")
        tmp.replace(self.state_file)

    def _pipe(self, pipe: str) -> dict:
        return self.state["pipes"][pipe]

    # --- reading EasyEffects ---------------------------------------------------

    def _config_list(self, pipe: str, key: str) -> list:
        try:
            text = self.ee.config_file().read_text(encoding="utf-8")
        except OSError:
            return []
        section = False
        for line in text.splitlines():
            if line.startswith("["):
                section = line.strip() == f"[{PIPES[pipe]['section']}]"
                continue
            if section and line.startswith(key + "="):
                value = line[len(key) + 1:].strip()
                return [item.strip() for item in value.split(",") if item.strip()]
        return []

    def _path(self, plugin_id: str) -> str:
        kind, index = plugin_id.split("#", 1)
        return f"{kind}:{index}"

    def _existing(self, pipe: str, ids: list) -> list:
        """The effects among `ids` that EasyEffects has loaded."""
        ids = [p for p in ids if "#" in p and kind_of(p) in self.schema]
        found = self.ee.get_many(pipe, [f"{self._path(p)}:bypass" for p in ids])
        return [p for p, value in zip(ids, found) if value is not None]

    def chain(self, pipe: str = "output") -> list:
        """A chain. Once the engine has loaded one, the chain it wrote is the truth: EasyEffects writes
        easyeffectsrc lazily, so right after a load it still lists the chain before it."""
        own = self._pipe(pipe)
        known = self._existing(pipe, own.get("chain") or [])
        core = own.get("core") or {}
        if known and all(core.get(kind) in known for kind in PIPES[pipe]["core"]):
            return known
        return self._existing(pipe, self._config_list(pipe, "plugins"))

    def _parse(self, prop: dict, raw):
        if raw is None:
            return prop["default"]
        kind = prop["type"]
        try:
            if kind == "bool":
                return raw.lower() in ("true", "1", "on")
            if kind in ("int", "enum"):
                return int(float(raw))
            if kind == "double":
                value = float(raw)
                return int(value) if value.is_integer() else round(value, 4)
        except ValueError:
            return prop["default"]
        return raw

    def defaults(self, kind: str) -> dict:
        return {p["name"]: p["default"] for p in self.schema[kind]["props"] if p["name"] != "bypass"}

    def read_plugin(self, plugin_id: str, full: bool = False, pipe: str = "output") -> dict:
        kind = kind_of(plugin_id)
        path = self._path(plugin_id)
        props = self.schema[kind]["props"]
        raw = self.ee.get_many(pipe, [f"{path}:{prop['name']}" for prop in props])
        values = {prop["name"]: self._parse(prop, value) for prop, value in zip(props, raw)}
        entry = {"id": plugin_id, "kind": kind, "label": self.schema[kind]["label"],
                 "enabled": not values.pop("bypass", False), "values": values,
                 "defaults": self.defaults(kind)}
        if kind == "equalizer":
            count = int(values.get("numBands", 0))
            channel = self._channel
            # The left side alone, unless the whole of both sides is asked for.
            keys = [(side, f"band{i}{name}") for side in (("left", "right") if full else ("left",))
                    for i in range(count) for name in (BAND_PROPS if full else ("Frequency", "Gain"))]
            raw = self.ee.get_many(pipe, [f"{path}:{side}:{name}" for side, name in keys])
            sides = {"left": {}, "right": {}}
            for (side, name), value in zip(keys, raw):
                sides[side][name] = self._parse(channel[name], value)
            if full:
                entry["channels"] = sides
            left = sides["left"]
            entry["bands"] = [{"frequency": left[f"band{i}Frequency"], "gain": left[f"band{i}Gain"]}
                              for i in range(count)]
        return entry

    def core_ids(self, chain: list, pipe: str = "output") -> dict:
        mapped = self._pipe(pipe).get("core") or {}
        if all(mapped.get(kind) in chain for kind in PIPES[pipe]["core"]):
            return mapped
        return {}

    # --- writing EasyEffects ---------------------------------------------------

    def _skeleton(self, kind: str) -> dict:
        body = {"bypass": True}
        if kind in ("equalizer", "midside_equalizer"):
            bands = {f"band{i}": {} for i in range(32)}
            sides = ("left", "right") if kind == "equalizer" else ("mid", "side")
            body.update({side: dict(bands) for side in sides})
        if kind in ("multiband_compressor", "multiband_gate"):
            body.update({f"band{i}": {} for i in range(8)})
        return body

    def _apply(self, plugin_id: str, values: dict, channels=None, pipe: str = "output") -> None:
        path = self._path(plugin_id)
        kind = kind_of(plugin_id)
        props = {p["name"]: p for p in self.schema[kind]["props"]}
        ordered = sorted(values.items(), key=lambda item: item[0] != "numBands")
        for name, value in ordered:
            if name == "bypass" or name not in props:
                continue
            self.ee.set(pipe, f"{path}:{name}", value)
        for side, side_values in (channels or {}).items():
            for name, value in side_values.items():
                self.ee.set(pipe, f"{path}:{side}:{name}", value)

    def rebuild(self, plan: list, pipe: str = "output") -> bool:
        """Load the chain in `plan` (dicts: id, enabled, values, channels) and send its values."""
        order = [item["id"] for item in plan]
        preset = {pipe: {"blocklist": self.blocklist(pipe), "plugins_order": order}}
        for plugin_id in order:
            preset[pipe][plugin_id] = self._skeleton(kind_of(plugin_id))
        name = PIPES[pipe]["preset"]
        folder = self.ee.preset_dir(pipe)
        folder.mkdir(parents=True, exist_ok=True)
        tmp = folder / f".{name}.tmp"
        tmp.write_text(json.dumps(preset, indent=2) + "\n", encoding="utf-8")
        tmp.replace(folder / f"{name}.json")
        if not self.ee.load_preset(pipe, name):
            return False
        if not self._wait(pipe, order):
            return False
        for item in plan:
            self._apply(item["id"], item.get("values", {}), item.get("channels"), pipe)
        for item in plan:
            self.ee.set(pipe, f"{self._path(item['id'])}:bypass", not item.get("enabled", False))
        if order:
            # Answered only once every value sent before it is in.
            self.ee.get(pipe, f"{self._path(order[0])}:bypass")
        self._pipe(pipe)["chain"] = order
        self._write_state()
        return True

    def blocklist(self, pipe: str = "output") -> list:
        """The apps a chain leaves alone. EasyEffects keeps the list in its settings and takes a new one only from a
        loaded preset; once the engine has changed it, its own copy is the truth (easyeffectsrc is written lazily)."""
        own = self._pipe(pipe).get("blocklist")
        return list(own) if isinstance(own, list) else self._config_list(pipe, "blocklist")

    def exclude(self, name: str, on: bool, pipe: str = "output") -> None:
        """Leave an app out of a chain, or take it back. EasyEffects matches a stream's node.name against the list
        when the stream appears; the shell moves the stream that is already playing."""
        name = str(name or "").strip()
        if not name or "\n" in name or len(name) > 256:
            raise ValueError("invalid_app")
        current = self.blocklist(pipe)
        wanted = sorted(set(current) | {name}) if on else [entry for entry in current if entry != name]
        if wanted == current:
            return
        self._pipe(pipe)["blocklist"] = wanted
        self._write_state()
        if self.ee.connect():
            chain = self.chain(pipe)
            if not self.rebuild(self.snapshot(chain, pipe), pipe):
                raise RuntimeError("chain_failed")

    def _wait(self, pipe: str, order: list) -> bool:
        deadline = time.monotonic() + 4
        pending = list(order)
        while pending and time.monotonic() < deadline:
            # Any effect EasyEffects has, known here or not: an imported chain can hold either.
            found = self.ee.get_many(pipe, [f"{self._path(p)}:bypass" for p in pending])
            pending = [p for p, value in zip(pending, found) if value is None]
            if pending:
                time.sleep(0.05)
        return not pending

    def _free_id(self, kind: str, taken: list) -> str:
        n = 0
        while f"{kind}#{n}" in taken:
            n += 1
        return f"{kind}#{n}"

    def _eq_values(self, gains10: list, input_gain: float, count: int) -> tuple:
        frequencies = band_frequencies(count)
        gains = interpolate(list(zip(ISO_10, gains10)), frequencies)
        q = band_q(frequencies)
        values = {"numBands": count, "splitChannels": False, "inputGain": input_gain}
        channel = {}
        for i, (f, g) in enumerate(zip(frequencies, gains)):
            channel.update({f"band{i}Frequency": f, f"band{i}Gain": g, f"band{i}Q": q,
                            f"band{i}Type": 1, f"band{i}Mute": False, f"band{i}Solo": False})
        return values, {"left": dict(channel), "right": dict(channel)}

    def _builtin_values(self, name: str, kind: str, band_count: int, profile=None) -> tuple:
        preset = self.builtins["presets"][name][kind]
        if kind == "equalizer":
            if profile:
                return self._eq_values(*self._tuned_gains(name, profile), band_count)
            return self._eq_values(preset["gains"], preset["inputGain"], band_count)
        return (self._shaped(name, kind, preset, profile) if profile else dict(preset)), None

    def _mic_values(self, name: str, kind: str, profile=None):
        """A microphone sound's values (and the equalizer's channels) for one effect, shaped to a tuned microphone;
        None where the sound leaves the effect alone."""
        preset = self.builtins["microphone"][name].get(kind)
        if preset is None:
            return None
        preset = dict(preset)
        if kind == "autotune":
            return dict(self.builtins["autotune"]["styles"][preset.get("style", "natural")]), None
        if kind == "equalizer":
            gains = [float(g) for g in preset["gains"]]
            if profile:
                correction = list(profile.get("correction") or []) + [0.0] * len(ISO_10)
                gains = [max(-12.0, min(9.0, g + float(c))) for g, c in zip(gains, correction)]
            return self._eq_values(gains, min(0.0, -max([0.0] + gains)), 10)
        return (self._mic_tuned(kind, preset, profile) if profile else preset), None

    def _mic_start(self, kind: str) -> tuple:
        return self._mic_values("Calls", kind)

    def _mic_needs(self, profile) -> set:
        """The microphone effects a tuned microphone turns on whatever sound plays."""
        if not profile:
            return set()
        needs = {"filter", "equalizer", "compressor", "limiter"}
        noise = profile.get("noise")
        if noise is not None and noise > -62:
            needs.add("gate")
        if noise is not None and noise > -55:
            needs.add("rnnoise")
        return needs

    @staticmethod
    def _mic_tuned(kind: str, values: dict, profile) -> dict:
        """A microphone sound's values for one effect on a tuned microphone: the cut under the voice's own pitch,
        the gate between its noise and its speech, the compressor where its speech sits."""
        values = dict(values)
        if kind == "filter" and profile.get("cut"):
            values["frequency"] = max(float(values.get("frequency", 20)), float(profile["cut"]))
        elif kind == "gate" and profile.get("gate") is not None:
            values["curveThreshold"] = max(-80.0, min(-20.0, float(profile["gate"])))
        elif kind == "compressor" and profile.get("speech") is not None:
            # The built-in sounds are set for speech around -26 dBFS: they follow where this voice really sits.
            shift = max(-12.0, min(12.0, float(profile["speech"]) + 26))
            values["threshold"] = round(max(-60.0, min(0.0, float(values["threshold"]) + shift)), 1)
            values["makeup"] = round(max(0.0, min(18.0, float(values["makeup"]) - shift * 0.8)), 1)
        return values

    def snapshot(self, chain: list, pipe: str = "output") -> list:
        return [self.read_plugin(p, full=True, pipe=pipe) for p in chain]

    def ensure_core(self, pipe: str = "output") -> dict:
        """Put a chain's core effects in front of the user's own chain, once."""
        chain = self.chain(pipe)
        core = self.core_ids(chain, pipe)
        if core:
            return core
        kept = self._kept_core(chain, pipe)
        if kept:
            return self._grow_core(chain, kept, pipe)
        existing = self.snapshot(chain, pipe)
        backup = self.state_file.with_name(f"{self.state_file.stem}-{pipe}-backup.json")
        if existing and not backup.exists():
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_text(json.dumps(existing, indent=1) + "\n", encoding="utf-8")
        taken = list(chain)
        core = {}
        for kind in PIPES[pipe]["core"]:
            core[kind] = self._free_id(kind, taken)
            taken.append(core[kind])
        plan = []
        for kind in PIPES[pipe]["core"]:
            values, channels = self._start_values(kind, pipe)
            plan.append({"id": core[kind], "enabled": False, "values": values, "channels": channels})
        plan += existing
        self._pipe(pipe)["core"] = core
        if not self.rebuild(plan, pipe):
            raise RuntimeError("chain_failed")
        return core

    def _kept_core(self, chain: list, pipe: str) -> dict:
        mapped = self._pipe(pipe).get("core") or {}
        return {kind: mapped[kind] for kind in PIPES[pipe]["core"] if mapped.get(kind) in chain}

    def _grow_core(self, chain: list, kept: dict, pipe: str) -> dict:
        """A newer engine has more core effects: slot the missing ones in, keeping everything else as it is."""
        taken = list(chain)
        core = {}
        plan = []
        for kind in PIPES[pipe]["core"]:
            if kind in kept:
                core[kind] = kept[kind]
                plan.append(self.read_plugin(kept[kind], full=True, pipe=pipe))
                continue
            core[kind] = self._free_id(kind, taken)
            taken.append(core[kind])
            values, channels = self._start_values(kind, pipe)
            plan.append({"id": core[kind], "enabled": False, "values": values, "channels": channels})
        plan += self.snapshot([p for p in chain if p not in kept.values()], pipe)
        self._pipe(pipe)["core"] = core
        if not self.rebuild(plan, pipe):
            raise RuntimeError("chain_failed")
        return core

    # --- what is heard now, and what it started as ------------------------------

    def light(self, core: dict, chain: list) -> dict:
        """What a person can change, in a form to compare: core switches and values, band gains, extras."""
        return self._light_of([self.read_plugin(core[kind]) for kind in CORE],
                              [self.read_plugin(p) for p in chain if p not in core.values()])

    @staticmethod
    def _light_of(core_entries: list, extra_entries: list) -> dict:
        out = {"core": {}, "extras": []}
        for entry in core_entries:
            out["core"][entry["kind"]] = {"enabled": entry["enabled"], "values": entry["values"],
                                          "bands": [b["gain"] for b in entry.get("bands", [])]}
        for entry in extra_entries:
            out["extras"].append({"kind": entry["kind"], "enabled": entry["enabled"], "values": entry["values"]})
        return rounded(out)

    def mark_baseline(self) -> None:
        """The sound a preset just set: changes are measured against it, and Revert returns to it."""
        chain = self.chain()
        core = self.core_ids(chain)
        if not core:
            return
        self.state["baseline"] = {"light": self.light(core, chain), "plan": self.snapshot(chain)}
        self._write_state()

    def revert(self) -> None:
        baseline = self.state.get("baseline")
        if not baseline:
            raise ValueError("nothing_to_revert")
        plan = baseline["plan"]
        if [item["id"] for item in plan] == self.chain():
            for item in plan:
                self._apply(item["id"], item.get("values", {}), item.get("channels"))
                self.ee.set("output", f"{self._path(item['id'])}:bypass", not item.get("enabled", False))
        elif not self.rebuild(plan):
            raise RuntimeError("chain_failed")
        self.headroom_follow()

    def headroom_follow(self) -> None:
        """With headroom kept, the equalizer's input gain falls as far as its highest band rises."""
        if not self.state.get("headroom", True):
            return
        core = self.core_ids(self.chain())
        if not core:
            return
        self._keep_headroom(core["equalizer"], "output")

    def _keep_headroom(self, plugin_id: str, pipe: str) -> None:
        path = self._path(plugin_id)
        count = int(float(self.ee.get(pipe, f"{path}:numBands") or 0))
        gains = [float(g or 0) for g in self.ee.get_many(pipe, [f"{path}:left:band{i}Gain" for i in range(count)])]
        self.ee.set(pipe, f"{path}:inputGain", round(-max([0.0] + gains), 2))

    # --- reports ---------------------------------------------------------------

    def status(self) -> dict:
        running = self.ee.connect()
        installed = running or self.ee.native() or self.ee.flatpak()
        packages = self.ee.lv2_packages() if installed else set()
        return {"type": "status", "installed": installed, "running": running,
                "missing": sorted({"lsp", "calf", "x42"} - packages) if installed else [],
                "bandCounts": BAND_COUNTS,
                "extras": [{"kind": k, "label": v["label"]} for k, v in self.schema.items()
                           if k not in CORE]}

    def _core_report(self, pipe: str, core: dict) -> list:
        modules = []
        for kind in PIPES[pipe]["core"]:
            if core:
                entry = self.read_plugin(core[kind], pipe=pipe)
            else:
                start, channels = self._start_values(kind, pipe)
                values = dict(self.defaults(kind))
                values.update(start)
                entry = {"id": "", "kind": kind, "label": self.schema[kind]["label"],
                         "enabled": False, "values": values, "defaults": self.defaults(kind)}
                if kind == "equalizer":
                    left = channels["left"]
                    entry["bands"] = [{"frequency": left[f"band{i}Frequency"],
                                       "gain": left[f"band{i}Gain"]} for i in range(10)]
            entry["needs"] = NEEDS.get(kind, "")
            if kind == "autotune":
                entry["tune"] = self.tune_of(entry["values"])
            modules.append(entry)
        return modules

    def signature(self) -> list:
        """What a poll compares: whether EasyEffects runs, both chains, the bypass and the sound set. Cheap: no values."""
        if not self.ee.connect():
            return [False]
        return [True, self.chain(), self.chain("input"), self.ee.bypassed(), self.state.get("active", ""),
                self._pipe("input").get("active", ""), self.state.get("tuning", ""), self.state.get("micTuning", "")]

    def poll(self) -> bool:
        """Whether anything a surface shows may have changed since the last report."""
        return self.signature() != self._seen

    def _memory(self) -> dict:
        return {"devices": self.state.get("devices", {}), "apps": self.state.get("apps", {}),
                "excluded": {pipe: self.blocklist(pipe) for pipe in PIPES},
                "headroom": self.state.get("headroom", True), "outputs": self._tuned_list("output"),
                "tuning": self.state.get("tuning", "") if self._profile() else "",
                "tuningFollow": self.state.get("tuningFollow", True), "outputsMax": OUTPUTS_MAX,
                "inputs": self._tuned_list("input"),
                "micTuning": self.state.get("micTuning", "") if self._profile("input") else "",
                "micTuningFollow": self.state.get("micTuningFollow", True)}

    def report(self) -> dict:
        # Each folder of presets is read once per report.
        catalog = {pipe: self._catalog(pipe) for pipe in PIPES}
        if self.state.get("presets") != catalog["output"][0] or self.state.get("micPresets") != catalog["input"][0]:
            self._write_state()
        self._seen = self.signature()
        if not self._seen[0]:
            return {"type": "state", "running": False, "active": self.state.get("active", ""), **self._memory()}
        chain, mic_chain, bypass = self._seen[1], self._seen[2], self._seen[3]
        core = self.core_ids(chain)
        extras = [self.read_plugin(p) for p in chain if p not in core.values()]
        core_entries = self._core_report("output", core)
        baseline = self.state.get("baseline")
        modified = bool(core and baseline and self.state.get("active")) \
            and self._light_of(core_entries, extras) != baseline.get("light")
        for entry in extras:
            entry["props"] = [p for p in self.schema[entry["kind"]]["props"]
                              if p["name"] != "bypass" and p["type"] != "string"]
        mic_core = self.core_ids(mic_chain, "input")
        if not mic_core and self._kept_core(mic_chain, "input"):
            mic_core = self.ensure_core("input")
        return {"type": "state", "running": True, "adopted": bool(core),
                "core": core_entries, "extras": extras,
                "active": self.state.get("active", ""), "modified": modified,
                "bypass": bypass, **self._memory(),
                "builtins": ["Default"] + list(self.builtins["presets"].keys()),
                "presets": catalog["output"][0], "presetInfo": catalog["output"][1],
                "mic": {"adopted": bool(mic_core), "core": self._core_report("input", mic_core),
                        "active": self._pipe("input").get("active", ""),
                        "builtins": list(self.builtins["microphone"].keys()),
                        "presets": catalog["input"][0], "presetInfo": catalog["input"][1]}}

    # --- presets ----------------------------------------------------------------

    def _preset_dir(self, pipe: str = "output") -> Path:
        # The microphone's presets keep a folder of their own, so a sound for the voice never lists among the output's.
        return self.presets_dir / "microphone" if pipe == "input" else self.presets_dir

    def _preset_path(self, name: str, pipe: str = "output") -> Path:
        safe = re.sub(r"[^\w\- ]", "_", name).strip() or "preset"
        return self._preset_dir(pipe) / f"{safe}.json"

    def _preset_files(self, pipe: str = "output") -> list:
        out = []
        try:
            files = sorted(self._preset_dir(pipe).glob("*.json"))
        except OSError:
            return out
        for path in files:
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(data, dict) and isinstance(data.get("name"), str):
                out.append((path, data))
        return out

    def preset_names(self, pipe: str = "output") -> list:
        return self._catalog(pipe)[0]

    def _catalog(self, pipe: str = "output") -> tuple:
        """The person's presets by name, and what each holds: the sound it started from, how many effects it turns on."""
        files = self._preset_files(pipe)
        info = {}
        for _, data in files:
            on = [kind for kind, entry in (data.get("core") or {}).items() if (entry or {}).get("enabled")]
            on += [extra.get("kind") for extra in (data.get("extras") or []) if extra.get("enabled")]
            info[data["name"]] = {"base": data.get("base") or "", "on": len(on)}
        return sorted((data["name"] for _, data in files), key=str.casefold), info

    def _find_preset(self, name: str, pipe: str = "output"):
        for path, data in self._preset_files(pipe):
            if data.get("name") == name:
                return path
        return None

    def _builtin_names(self, pipe: str = "output") -> list:
        if pipe == "input":
            return list(self.builtins["microphone"].keys())
        return ["Default"] + list(self.builtins["presets"].keys())

    def _check_name(self, name: str, pipe: str = "output") -> str:
        name = str(name or "").strip()
        if not name or len(name) > NAME_MAX:
            raise ValueError("invalid_name")
        if name in self._builtin_names(pipe):
            raise ValueError("builtin_name")
        return name

    def _free_name(self, name: str, pipe: str = "output") -> str:
        if self._find_preset(name, pipe) is None and name not in self._builtin_names(pipe):
            return name
        n = 2
        while self._find_preset(f"{name} {n}", pipe) is not None:
            n += 1
        return f"{name} {n}"

    def _write_preset(self, data: dict, path=None, pipe: str = "output") -> None:
        path = path or self._preset_path(data["name"], pipe)
        if path.exists() and self._find_preset(data["name"], pipe) != path:
            n = 2
            while path.exists():
                path = self._preset_path(f"{data['name']} {n}", pipe)
                n += 1
        self._preset_dir(pipe).mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(finite(data), indent=1) + "\n", encoding="utf-8")
        tmp.replace(path)

    def _active(self, pipe: str = "output") -> str:
        return str((self.state if pipe == "output" else self._pipe(pipe)).get("active", "") or "")

    def _set_active(self, name: str, pipe: str = "output") -> None:
        (self.state if pipe == "output" else self._pipe(pipe))["active"] = name

    def _current_preset(self, name: str, pipe: str = "output") -> dict:
        core = self.ensure_core(pipe)
        chain = self.chain(pipe)
        data = {"name": name, "base": self._active(pipe), "core": {}, "extras": []}
        for kind in PIPES[pipe]["core"]:
            entry = self.read_plugin(core[kind], full=True, pipe=pipe)
            data["core"][kind] = {"enabled": entry["enabled"], "values": entry["values"]}
            if "channels" in entry:
                data["core"][kind]["channels"] = entry["channels"]
        for plugin_id in chain:
            if plugin_id in core.values():
                continue
            entry = self.read_plugin(plugin_id, full=True, pipe=pipe)
            item = {"kind": entry["kind"], "enabled": entry["enabled"], "values": entry["values"]}
            if "channels" in entry:
                item["channels"] = entry["channels"]
            data["extras"].append(item)
        return data

    def save(self, name: str, pipe: str = "output") -> None:
        name = self._check_name(name, pipe)
        self._write_preset(self._current_preset(name, pipe), self._find_preset(name, pipe), pipe)
        self._set_active(name, pipe)
        if pipe == "output":
            self.mark_baseline()
        else:
            self._write_state()

    def _start_values(self, kind: str, pipe: str) -> tuple:
        """Where a core effect starts before a preset sets it: neutral, never silent."""
        return self._mic_start(kind) if pipe == "input" else self._builtin_values("Flat", kind, 10)

    def _load_data(self, data: dict, fresh: bool = False, pipe: str = "output") -> None:
        """Play a preset. `fresh` builds the whole chain anew instead of keeping the one EasyEffects has."""
        kinds = PIPES[pipe]["core"]
        if fresh:
            core = {}
            for kind in kinds:
                core[kind] = self._free_id(kind, list(core.values()))
            self._pipe(pipe)["core"] = core
        else:
            core = self.ensure_core(pipe)
        plan = []
        for kind in kinds:
            saved = (data.get("core") or {}).get(kind) or {}
            values, channels = self._start_values(kind, pipe)
            values = dict(values)
            values.update(saved.get("values") or {})
            plan.append({"id": core[kind], "enabled": bool(saved.get("enabled")),
                         "values": values, "channels": saved.get("channels") or channels})
        taken = list(core.values())
        for extra in data.get("extras") or []:
            kind = extra.get("kind")
            if kind not in self.schema:
                continue
            plugin_id = self._free_id(kind, taken)
            taken.append(plugin_id)
            plan.append({"id": plugin_id, "enabled": bool(extra.get("enabled")),
                         "values": extra.get("values") or {}, "channels": extra.get("channels")})
        if not self.rebuild(plan, pipe):
            raise RuntimeError("chain_failed")

    def load(self, name: str, pipe: str = "output") -> None:
        path = self._find_preset(name, pipe)
        if path is None:
            raise ValueError("preset_not_found")
        self._load_data(json.loads(path.read_text(encoding="utf-8")), pipe=pipe)
        self._set_active(name, pipe)
        if pipe == "output":
            self.headroom_follow()
            self.mark_baseline()
        else:
            self._write_state()

    def rename(self, old: str, new: str, pipe: str = "output") -> None:
        new = self._check_name(new, pipe)
        path = self._find_preset(old, pipe)
        if path is None:
            raise ValueError("preset_not_found")
        if new != old and self._find_preset(new, pipe) is not None:
            raise ValueError("name_taken")
        data = json.loads(path.read_text(encoding="utf-8"))
        data["name"] = new
        target = self._preset_path(new, pipe)
        # Two names can share a file name ("Rock?" and "Rock_"): the other preset's file is never written over.
        n = 2
        while target.exists() and target != path:
            target = self._preset_path(f"{new} {n}", pipe)
            n += 1
        tmp = target.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
        tmp.replace(target)
        if target != path:
            path.unlink(missing_ok=True)
        if self._active(pipe) == old:
            self._set_active(new, pipe)
        if pipe == "output":
            for memory in ("devices", "apps"):
                for key, preset in list((self.state.get(memory) or {}).items()):
                    if preset == old:
                        self.state[memory][key] = new
        self._write_state()

    def delete(self, name: str, pipe: str = "output") -> None:
        path = self._find_preset(name, pipe)
        if path is None:
            raise ValueError("preset_not_found")
        path.unlink(missing_ok=True)
        if pipe == "output":
            for memory in ("devices", "apps"):
                self.state[memory] = {key: preset for key, preset in (self.state.get(memory) or {}).items()
                                      if preset != name}
        # The sound it described is gone with it: the chain goes back to its neutral sound.
        if self._active(pipe) == name:
            if self.ee.connect():
                self.apply_builtin("Default") if pipe == "output" else self.apply_mic("Off")
            else:
                self._set_active("", pipe)
        self._write_state()

    # --- import and export --------------------------------------------------------

    def _to_easyeffects(self, data: dict) -> dict:
        """One of the person's presets in EasyEffects' own format, from where its save() writes each property."""
        order, body = [], {}
        entries = [(kind, entry) for kind, entry in (data.get("core") or {}).items()]
        entries += [(extra.get("kind"), extra) for extra in data.get("extras") or []]
        for kind, entry in entries:
            if kind not in self.schema:
                continue
            plugin_id = self._free_id(kind, order)
            order.append(plugin_id)
            values = dict(self.defaults(kind))
            values.update(entry.get("values") or {})
            values["bypass"] = not entry.get("enabled", False)
            props = {p["name"]: p for p in self.schema[kind]["props"]}
            out = {}
            for key in self.schema[kind]["preset"]:
                prop = props[key["prop"]]
                value = values.get(key["prop"], prop["default"])
                if key["label"]:
                    choices = prop.get("choices") or []
                    value = choices[int(value)] if 0 <= int(value) < len(choices) else (choices or [""])[0]
                node = out
                for part in key["path"][:-1]:
                    node = node.setdefault(part, {})
                node[key["path"][-1]] = value
            if kind == "equalizer":
                count = int(values.get("numBands", 10))
                out["num-bands"] = count
                labels = self.schema["equalizer"]["channelLabels"]
                for side in ("left", "right"):
                    channel = (entry.get("channels") or {}).get(side) or {}
                    out[side] = {}
                    for i in range(count):
                        band = lambda name, fallback: channel.get(f"band{i}{name}", fallback)
                        out[side][f"band{i}"] = {
                            "frequency": band("Frequency", 1000.0), "gain": band("Gain", 0.0),
                            "q": band("Q", 1.41), "width": band("Width", 4.0),
                            "type": labels["Type"][int(band("Type", 1))], "mode": labels["Mode"][int(band("Mode", 0))],
                            "slope": labels["Slope"][int(band("Slope", 0))],
                            "mute": bool(band("Mute", False)), "solo": bool(band("Solo", False))}
            body[plugin_id] = out
        return {"output": {"blocklist": [], "plugins_order": order, **body}}

    def export(self, name: str, target: str, kind: str) -> None:
        if name in self._builtin_names() or not name:
            data = self._current_preset(name or "Current")
        else:
            path = self._find_preset(name)
            if path is None:
                raise ValueError("preset_not_found")
            data = json.loads(path.read_text(encoding="utf-8"))
        target_path = Path(target).expanduser()
        target_path.parent.mkdir(parents=True, exist_ok=True)
        payload = self._to_easyeffects(data) if kind == "easyeffects" else data
        target_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    def _clean_preset(self, data: dict) -> dict:
        """One of our presets from a file someone handed over: only known effects and well-formed entries are kept."""
        def entry(raw):
            if not isinstance(raw, dict):
                return None
            values = raw.get("values") if isinstance(raw.get("values"), dict) else {}
            out = {"enabled": bool(raw.get("enabled")),
                   "values": {k: v for k, v in values.items() if isinstance(v, (int, float, bool, str))}}
            channels = raw.get("channels")
            if isinstance(channels, dict):
                out["channels"] = {side: {k: v for k, v in band.items() if isinstance(v, (int, float, bool, str))}
                                   for side, band in channels.items()
                                   if side in ("left", "right") and isinstance(band, dict)}
            return out
        core = data.get("core") if isinstance(data.get("core"), dict) else {}
        extras = data.get("extras") if isinstance(data.get("extras"), list) else []
        clean = {"name": str(data.get("name") or ""), "base": str(data.get("base") or ""), "core": {}, "extras": []}
        for kind in CORE:
            kept = entry(core.get(kind))
            if kept is not None:
                clean["core"][kind] = kept
        for raw in extras:
            kept = entry(raw)
            if kept is not None and isinstance(raw, dict) and raw.get("kind") in self.schema:
                clean["extras"].append(dict(kept, kind=raw["kind"]))
        if not clean["core"] and not clean["extras"]:
            raise ValueError("unknown_format")
        return clean

    def import_preset(self, source: str) -> str:
        path = Path(source).expanduser()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise ValueError("unreadable_file")
        if not isinstance(data, dict):
            raise ValueError("unknown_format")
        if "core" in data or "extras" in data:
            data = self._clean_preset(data)
            data["name"] = self._free_name(str(data.get("name") or path.stem).strip()[:NAME_MAX] or "Imported")
            self._write_preset(data)
            return data["name"]
        if "output" not in data:
            raise ValueError("unknown_format")
        # EasyEffects reads its own format exactly: it loads the file, and the engine keeps what it set.
        if not self.ee.connect():
            raise ValueError("needs_easyeffects")
        folder = self.ee.preset_dir("output")
        folder.mkdir(parents=True, exist_ok=True)
        staged = folder / "iNiR Import.json"
        shutil.copyfile(path, staged)
        try:
            order = [p if "#" in p else f"{p}#0" for p in data["output"].get("plugins_order") or []]
            if not self.ee.load_preset("output", "iNiR Import") or not self._wait("output", order):
                raise RuntimeError("chain_failed")
            imported = self.snapshot([p for p in order if kind_of(p) in self.schema])
        finally:
            staged.unlink(missing_ok=True)
        name = self._free_name(path.stem[:NAME_MAX] or "Imported")
        preset = {"name": name, "base": "", "core": {}, "extras": []}
        for entry in imported:
            kept = {k: v for k, v in entry.items() if k in ("enabled", "values", "channels")}
            # The first effect of a core kind becomes the core one; any further copy stays an extra.
            if entry["kind"] in CORE and entry["kind"] not in preset["core"]:
                preset["core"][entry["kind"]] = kept
            else:
                preset["extras"].append(dict(kept, kind=entry["kind"]))
        self._write_preset(preset)
        self._load_data(preset, fresh=True)
        self.state["active"] = name
        self.mark_baseline()
        return name

    # --- operations ---------------------------------------------------------------

    def apply_builtin(self, name: str) -> None:
        """A built-in sound on the core effects that are on. With a tuned output chosen, shaped to it: the effects the
        output needs (its correction, its high-pass, its limiter) come on too, and Default keeps only those."""
        if name not in self._builtin_names():
            raise ValueError("preset_not_found")
        core = self.ensure_core()
        profile = self._profile()
        needs = self._needs(name, profile)
        for kind in CORE:
            plugin_id = core[kind]
            path = self._path(plugin_id)
            enabled = self.ee.get("output", f"{path}:bypass") in ("false", "0")
            if name != "Default" and not enabled and kind not in needs:
                continue
            count = int(float(self.ee.get("output", f"{path}:numBands") or 10)) if kind == "equalizer" else 10
            if count not in BAND_COUNTS:
                count = 10
            values, channels = self._builtin_values("Flat" if name == "Default" else name, kind, count, profile)
            self._apply(plugin_id, values, channels)
            if name == "Default" or kind in needs:
                self.ee.set("output", f"{path}:bypass", kind not in needs)
        self.state["active"] = name
        self.mark_baseline()

    # --- tuned outputs ------------------------------------------------------------------

    def _tuned_list(self, pipe: str = "output") -> list:
        found = self.state.get(TUNED[pipe]["list"])
        return found if isinstance(found, list) else []

    def _tuned(self, tuned_id: str, pipe: str = "output"):
        return next((o for o in self._tuned_list(pipe) if o.get("id") == tuned_id), None)

    def _profile(self, pipe: str = "output"):
        """The tuned output (or microphone) the built-in sounds are shaped to, or None for Default."""
        return self._tuned(str(self.state.get(TUNED[pipe]["choice"]) or ""), pipe)

    @staticmethod
    def _speakers(profile) -> bool:
        return bool(profile) and profile.get("kind") != "headphones"

    def _dropped_bass(self, name: str, profile) -> float:
        """How much bass a sound asks for below where the output still plays: the bass enhancer suggests it instead."""
        low = (profile or {}).get("low")
        if not self._speakers(profile) or not low or name in ("Default", "Flat"):
            return 0.0
        gains = self.builtins["presets"][name]["equalizer"]["gains"]
        return max([0.0] + [float(g) for f, g in zip(ISO_10, gains) if f < low])

    def _needs(self, name: str, profile) -> set:
        """The core effects a tuned output turns on whatever sound plays."""
        if not profile:
            return set()
        if not self._speakers(profile):
            return {"limiter"}
        needs = {"equalizer", "limiter"}
        if profile.get("low"):
            needs.add("filter")
        if self._dropped_bass(name, profile) >= 3:
            needs.add("bass_enhancer")
        return needs

    def _shaped(self, name: str, kind: str, values: dict, profile) -> dict:
        """A built-in sound's values for one core effect, shaped to a tuned output."""
        base = self.builtins["presets"][name]
        low, high = profile.get("low"), profile.get("high") or 20000
        strain = float(profile.get("strain") or 0)
        values = dict(values)
        if not self._speakers(profile):
            # At the ear: less harmonic fizz and bloom, a touch quieter, peaks held.
            if kind == "bass_enhancer" and values["amount"] > 0:
                values["amount"] = round(values["amount"] * 0.7, 1)
            elif kind == "exciter":
                values["amount"] = max(0.0, values["amount"] - 1) if values["amount"] > 0 else values["amount"]
                if high < 20000:
                    values.update(ceil=max(10000, min(20000, round(high))), ceilActive=True)
            elif kind == "autogain":
                values["target"] = max(-100, values["target"] - 2)
            elif kind == "limiter":
                values.update(threshold=min(values["threshold"], -1), gainBoost=False)
            return values
        if kind == "filter" and low:
            # A laptop's microphone hears little low end itself: the cut stays where any small speaker gives out anyway.
            cut = min(250, round(low * (0.6 + 0.25 * strain)))
            values.update(type=1, frequency=max(float(base["filter"]["frequency"]), cut),
                          slope=max(1, int(base["filter"]["slope"])))
        elif kind == "bass_enhancer" and low and low >= 90:
            values.update(scope=max(values["scope"], min(250, round(low * 1.4))),
                          floor=max(20, min(120, round(low * 0.5))), floorActive=True)
            values["amount"] = round(values["amount"] + min(6.0, self._dropped_bass(name, profile) * 0.75)
                                     * (1 - 0.5 * strain), 1)
        elif kind == "exciter" and high < 14000:
            values.update(ceil=max(10000, min(20000, round(high))), ceilActive=True)
        elif kind == "limiter":
            values.update(threshold=min(values["threshold"], round(-1 - 2 * strain, 1)), gainBoost=False)
        return values

    def _tuned_gains(self, name: str, profile) -> tuple:
        """A built-in sound's ten octave gains and input gain on a tuned output: its correction added, and no boost
        below where the output gives out (the bass enhancer suggests that bass instead)."""
        preset = self.builtins["presets"][name]["equalizer"]
        gains = [float(g) for g in preset["gains"]]
        if self._speakers(profile):
            low = profile.get("low")
            correction = list(profile.get("correction") or []) + [0.0] * len(ISO_10)
            gains = [max(-12.0, min(9.0, (min(g, 0.0) if low and f < low else g) + float(c)))
                     for f, g, c in zip(ISO_10, gains, correction)]
        input_gain = min(float(preset["inputGain"]), -max([0.0] + gains))
        return gains, input_gain

    def _new_tuned_id(self, pipe: str = "output") -> str:
        taken = {o.get("id") for o in self._tuned_list(pipe)}
        prefix = TUNED[pipe]["prefix"]
        n = 1
        while f"{prefix}{n}" in taken:
            n += 1
        return f"{prefix}{n}"

    def _check_tuned_name(self, name, own_id: str = "", pipe: str = "output") -> str:
        name = str(name or "").strip()
        if not name or len(name) > OUTPUT_NAME_MAX or "\n" in name:
            raise ValueError("invalid_name")
        if name.casefold() == "default":
            raise ValueError("builtin_name")
        if any(o.get("name", "").casefold() == name.casefold() and o.get("id") != own_id
               for o in self._tuned_list(pipe)):
            raise ValueError("tuned_name_taken")
        return name

    def _free_tuned_name(self, name: str, pipe: str = "output") -> str:
        name = (str(name or "").strip() or ("Microphone" if pipe == "input" else "Output"))[:OUTPUT_NAME_MAX - 3]
        taken = {o.get("name", "").casefold() for o in self._tuned_list(pipe)} | {"default"}
        if name.casefold() not in taken:
            return name
        n = 2
        while f"{name} {n}".casefold() in taken:
            n += 1
        return f"{name} {n}"

    def _run_probe(self, args: list) -> dict:
        """output_probe.py in iNiR's Python environment (NumPy), its progress passed on as it comes."""
        script = HERE / "output_probe.sh"
        command = [str(script), *args] if script.exists() else [sys.executable, str(HERE / "output_probe.py"), *args]
        try:
            proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True)
        except OSError:
            raise RuntimeError("probe_failed")
        found = None
        for line in proc.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("error"):
                proc.wait(timeout=5)
                raise ValueError(str(event["error"]))
            if event.get("stage"):
                emit(dict(event, type="probe"))
            if "result" in event:
                found = event
        proc.wait(timeout=5)
        if found is None:
            raise RuntimeError("probe_failed")
        return found

    def mic_source(self) -> str:
        """The microphone EasyEffects records from: the one a measurement listens to."""
        import output_probe
        configured = self._config_list("input", "inputDevice")
        here = output_probe.identify_source(configured[0] if configured else "")
        return here.get("source", "") if here.get("found") else ""

    @staticmethod
    def _source_volume(source: str):
        out = subprocess.run(["pactl", "get-source-volume", source], capture_output=True, text=True)
        found = re.search(r"(\d+)%", out.stdout or "")
        return int(found.group(1)) if found else None

    def _set_source_volume(self, source: str, percent: int) -> None:
        subprocess.run(["pactl", "set-source-volume", source, f"{max(5, min(100, int(percent)))}%"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def probe(self, device: str, replace: str = "", pipe: str = "output") -> str:
        """Measure the output playing now, or the microphone (while the person speaks), and keep it as a tuned one,
        chosen at once. `replace` measures a tuned one again, keeping its name."""
        key = TUNED[pipe]["device"]
        device = str(device or "").strip() or (self.mic_source() if pipe == "input" else "")
        if not device:
            raise ValueError("no_output" if pipe == "output" else "no_mic")
        old = self._tuned(replace, pipe) if replace else None
        if replace and old is None:
            raise ValueError("tuned_not_found")
        if old is None and len(self._tuned_list(pipe)) >= OUTPUTS_MAX:
            raise ValueError("tuned_full")
        volume = self._source_volume(device) if pipe == "input" else None
        # What is measured is the device as it is: the engine's own effects stay out of it.
        running = self.ee.connect()
        was = self.ee.bypassed() if running else False
        if running and not was:
            self.ee.bypass(True)
        try:
            found = self._run_probe(["--sink", device] if pipe == "output"
                                    else ["--mic", device, "--volume", str(volume or 0)])
        finally:
            if running and not was:
                self.ee.bypass(False)
        found_device, result = found.get("device") or {}, found.get("result") or {}
        entry = {key: device, "route": found_device.get("route", ""),
                 "description": found_device.get("description", ""), "device": found_device.get("device", ""),
                 "kind": found_device.get("kind", "speakers" if pipe == "output" else "internal"),
                 "measured": bool(result.get("measured")), "reason": result.get("reason", ""),
                 "correction": result.get("correction") or [0.0] * len(ISO_10), "curve": result.get("curve") or [],
                 "snr": result.get("snr"), "created": time.strftime("%Y-%m-%d %H:%M")}
        if pipe == "output":
            entry.update({"builtIn": bool(found_device.get("builtIn")), "codec": found_device.get("codec", ""),
                          "low": result.get("low"), "high": result.get("high"), "strain": result.get("strain", 0),
                          "thd": result.get("thd")})
        else:
            entry.update({key2: result.get(key2) for key2 in ("noise", "speech", "peak", "clipped", "pitch", "cut",
                                                              "gate", "sibilance")})
            # A microphone that clips or barely registers is set right at its source; the tuned microphone keeps it.
            if volume and result.get("volume") and int(result["volume"]) != volume:
                self._set_source_volume(device, int(result["volume"]))
                entry.update(volume=int(result["volume"]), volumeWas=volume)
            else:
                entry.update(volume=volume, volumeWas=volume)
        if old is not None:
            old.update(entry)
            tuned_id = old["id"]
        else:
            tuned_id = self._new_tuned_id(pipe)
            name = self._free_tuned_name(entry["description"] or entry["device"], pipe)
            self.state[TUNED[pipe]["list"]] = self._tuned_list(pipe) + [dict(entry, id=tuned_id, name=name)]
        self.tune_for(tuned_id, pipe)
        return tuned_id

    def tune_for(self, tuned_id: str, pipe: str = "output") -> None:
        """Shape the built-in sounds to a tuned output or microphone ("" for Default); the built-in sound playing follows
        at once, and a tuned microphone brings back the input level it was measured at."""
        tuned_id = str(tuned_id or "")
        profile = self._tuned(tuned_id, pipe) if tuned_id else None
        if tuned_id and profile is None:
            raise ValueError("tuned_not_found")
        self.state[TUNED[pipe]["choice"]] = tuned_id
        self._write_state()
        if pipe == "input" and profile and profile.get("volume") and profile.get("source"):
            self._set_source_volume(profile["source"], profile["volume"])
        active = self._active(pipe)
        if active in self._builtin_names(pipe) and self.ee.connect() and self.core_ids(self.chain(pipe), pipe):
            self.apply_builtin(active) if pipe == "output" else self.apply_mic(active)

    def rename_tuned(self, tuned_id: str, name, pipe: str = "output") -> None:
        entry = self._tuned(str(tuned_id or ""), pipe)
        if entry is None:
            raise ValueError("tuned_not_found")
        entry["name"] = self._check_tuned_name(name, entry["id"], pipe)
        self._write_state()

    def forget_tuned(self, tuned_id: str, pipe: str = "output") -> None:
        tuned_id = str(tuned_id or "")
        if self._tuned(tuned_id, pipe) is None:
            raise ValueError("tuned_not_found")
        self.state[TUNED[pipe]["list"]] = [o for o in self._tuned_list(pipe) if o.get("id") != tuned_id]
        if self.state.get(TUNED[pipe]["choice"]) == tuned_id:
            self.tune_for("", pipe)
        else:
            self._write_state()

    def set_follow(self, on: bool, pipe: str = "output") -> None:
        self.state[TUNED[pipe]["follow"]] = bool(on)
        self._write_state()

    def follow(self, device: str, pipe: str = "output") -> None:
        """The device changed (a sink or source, or a port on one: headphones or a headset in or out): its tuned one,
        the newest measured on that same device and port, takes over; none, and one measured elsewhere steps back to
        Default."""
        if not self.state.get(TUNED[pipe]["follow"], True) or not self._tuned_list(pipe):
            return
        import output_probe
        key = TUNED[pipe]["device"]
        if pipe == "input":
            here = output_probe.identify_source(str(device or "") or self.mic_source())
            device = here.get("source", "")
        else:
            here = output_probe.identify(str(device or ""))
        if not here.get("found"):
            return
        spot = (device, here.get("route", ""))
        matches = [o for o in self._tuned_list(pipe) if (o.get(key), o.get("route", "")) == spot]
        current = self._profile(pipe)
        if matches:
            target = matches[-1]["id"]
        elif current is not None and (current.get(key), current.get("route", "")) != spot:
            target = ""
        else:
            return
        if target != self.state.get(TUNED[pipe]["choice"], ""):
            self.tune_for(target, pipe)

    def apply(self, name: str) -> None:
        """A sound by name, built in or the person's own: what devices and the command line ask for."""
        if name in self._builtin_names():
            self.apply_builtin(name)
        else:
            self.load(name)

    def apply_mic(self, name: str) -> None:
        """A microphone sound on the effects that are on, as the output's built-ins work; Off turns every one off.
        With a tuned microphone chosen, shaped to it, and what it needs comes on too."""
        if name not in self.builtins["microphone"]:
            raise ValueError("preset_not_found")
        core = self.ensure_core("input")
        profile = self._profile("input")
        needs = set() if name == "Off" else self._mic_needs(profile)
        for kind in PIPES["input"]["core"]:
            path = self._path(core[kind])
            if name == "Off":
                self.ee.set("input", f"{path}:bypass", True)
                continue
            enabled = self.ee.get("input", f"{path}:bypass") in ("false", "0")
            if not enabled and kind not in needs:
                continue
            sound = self._mic_values(name, kind, profile) or self._mic_values("Calls", kind, profile)
            if sound is None:
                continue
            values, channels = sound
            self._apply(core[kind], values, channels, "input")
            if kind in needs:
                self.ee.set("input", f"{path}:bypass", False)
        self._pipe("input")["active"] = name
        self._write_state()

    def tune_of(self, values: dict) -> dict:
        """The key, scale and style the autotune's note switches and knobs spell, or "custom"."""
        on = [i for i, note in enumerate(NOTES) if values.get(note, True)]
        key, scale = 0, "custom"
        chosen = self._pipe("input").get("tune") or {}
        if len(on) == 12:
            scale = "chromatic"
        elif chosen.get("scale") in SCALES and sorted(
                (int(chosen.get("key", 0)) + s) % 12 for s in SCALES[chosen["scale"]]) == on:
            # Relative keys share their notes (A minor is C major): the one picked is the one shown.
            key, scale = int(chosen.get("key", 0)) % 12, chosen["scale"]
        else:
            for name, steps in SCALES.items():
                found = next((k for k in range(12) if sorted((k + s) % 12 for s in steps) == on), None)
                if found is not None:
                    key, scale = found, name
                    break
        style = "custom"
        for name, preset in self.builtins["autotune"]["styles"].items():
            if all(abs(float(values.get(p, 0)) - float(v)) < 1e-3 for p, v in preset.items()):
                style = name
                break
        return {"key": key, "scale": scale, "style": style}

    def tune(self, request: dict) -> None:
        """Set the autotune's notes from a key and scale, and/or its knobs from a style."""
        core = self.ensure_core("input")
        path = self._path(core["autotune"])
        current = self.tune_of(self.read_plugin(core["autotune"], pipe="input")["values"])
        if "key" in request or "scale" in request:
            key = int(request.get("key", current["key"])) % 12
            scale = str(request.get("scale", current["scale"]))
            if scale not in SCALES:
                raise ValueError("invalid_scale")
            notes = {(key + step) % 12 for step in SCALES[scale]}
            for i, note in enumerate(NOTES):
                self.ee.set("input", f"{path}:{note}", i in notes)
            self._pipe("input")["tune"] = {"key": key, "scale": scale}
            self._write_state()
        if "style" in request:
            styles = self.builtins["autotune"]["styles"]
            style = str(request["style"])
            if style not in styles:
                raise ValueError("invalid_style")
            self._apply(core["autotune"], styles[style], pipe="input")

    def set_bands(self, count: int) -> None:
        if count not in BAND_COUNTS:
            raise ValueError("invalid_band_count")
        core = self.ensure_core()
        entry = self.read_plugin(core["equalizer"])
        curve = [(b["frequency"], b["gain"]) for b in entry["bands"]] or [(1000, 0)]
        frequencies = band_frequencies(count)
        gains = interpolate(curve, frequencies)
        q = band_q(frequencies)
        path = self._path(core["equalizer"])
        self.ee.set("output", f"{path}:splitChannels", False)
        self.ee.set("output", f"{path}:numBands", count)
        for i, (f, g) in enumerate(zip(frequencies, gains)):
            for side in ("left", "right"):
                for name, value in (("Frequency", f), ("Q", q), ("Type", 1), ("Gain", g),
                                    ("Mute", False), ("Solo", False)):
                    self.ee.set("output", f"{path}:{side}:band{i}{name}", value)
        self.headroom_follow()

    def target(self, request: dict) -> tuple:
        pipe = "input" if request.get("pipe") == "input" else "output"
        if request.get("id"):
            plugin_id = str(request["id"])
            if plugin_id not in self.chain(pipe):
                raise ValueError("plugin_not_found")
            return pipe, plugin_id
        kind = str(request.get("kind", ""))
        if kind not in PIPES[pipe]["core"]:
            raise ValueError("plugin_not_found")
        return pipe, self.ensure_core(pipe)[kind]

    def set_value(self, request: dict) -> None:
        pipe, plugin_id = self.target(request)
        kind = kind_of(plugin_id)
        name = str(request.get("prop", ""))
        props = {p["name"]: p for p in self.schema[kind]["props"]}
        if name not in props or name == "bypass":
            raise ValueError("property_not_found")
        prop = props[name]
        value = request.get("value")
        if prop["type"] in ("double", "int", "enum"):
            value = float(value)
            if "min" in prop:
                value = max(prop["min"], value)
            if "max" in prop:
                value = min(prop["max"], value)
            if prop["type"] == "enum":
                value = int(max(0, min(len(prop["choices"]) - 1, value)))
            elif prop["type"] == "int":
                value = int(value)
        elif prop["type"] == "bool":
            value = bool(value)
        self.ee.set(pipe, f"{self._path(plugin_id)}:{name}", value)

    def set_band(self, index: int, gain: float, pipe: str = "output") -> None:
        core = self.ensure_core(pipe)
        path = self._path(core["equalizer"])
        count = int(float(self.ee.get(pipe, f"{path}:numBands") or 0))
        if not 0 <= index < count:
            raise ValueError("invalid_band")
        gain = max(-36.0, min(36.0, float(gain)))
        for side in ("left", "right"):
            self.ee.set(pipe, f"{path}:{side}:band{index}Gain", gain)
        if pipe == "output":
            self.headroom_follow()
            return
        # The voice's equalizer always keeps its headroom: a boosted band never clips what follows it.
        self._keep_headroom(core["equalizer"], pipe)

    def set_enabled(self, request: dict) -> None:
        pipe, plugin_id = self.target(request)
        self.ee.set(pipe, f"{self._path(plugin_id)}:bypass", not bool(request.get("enabled")))

    def add(self, kind: str) -> None:
        if kind not in self.schema or kind in CORE:
            raise ValueError("invalid_effect")
        self.ensure_core()
        chain = self.chain()
        plan = self.snapshot(chain)
        plan.append({"id": self._free_id(kind, chain), "enabled": True, "values": {}})
        if not self.rebuild(plan):
            raise RuntimeError("chain_failed")

    def remove(self, plugin_id: str) -> None:
        core = self.ensure_core()
        chain = self.chain()
        if plugin_id in core.values() or plugin_id not in chain:
            raise ValueError("plugin_not_found")
        plan = self.snapshot([p for p in chain if p != plugin_id])
        if not self.rebuild(plan):
            raise RuntimeError("chain_failed")

    def remember(self, sink: str, preset: str) -> None:
        sink = str(sink or "").strip()
        if not sink:
            raise ValueError("no_device")
        if preset not in self._builtin_names() and self._find_preset(preset) is None:
            raise ValueError("preset_not_found")
        self.state.setdefault("devices", {})[sink] = preset
        self._write_state()

    def forget(self, sink: str) -> None:
        (self.state.get("devices") or {}).pop(str(sink or ""), None)
        self._write_state()

    def remember_app(self, app: str, preset: str) -> None:
        """A sound an app brings while it plays, keyed by its node.name (what EasyEffects matches apps by too)."""
        app = str(app or "").strip()
        if not app or len(app) > 256:
            raise ValueError("invalid_app")
        if preset not in self._builtin_names() and self._find_preset(preset) is None:
            raise ValueError("preset_not_found")
        self.state.setdefault("apps", {})[app] = preset
        self._write_state()

    def forget_app(self, app: str) -> None:
        (self.state.get("apps") or {}).pop(str(app or ""), None)
        self._write_state()

    def set_headroom(self, on: bool) -> None:
        self.state["headroom"] = bool(on)
        self._write_state()
        self.headroom_follow()

    def start(self) -> None:
        if not self.ee.start():
            raise RuntimeError("start_failed")
        self._settle()

    def _settle(self, timeout: float = 6) -> None:
        """Right after it starts, EasyEffects answers on its socket before it has loaded its chains: until every
        effect it will list answers, the chain reads empty and the core would be rebuilt over the person's own."""
        deadline = time.monotonic() + timeout
        for pipe in PIPES:
            expected = [p for p in (self._pipe(pipe).get("chain") or self._config_list(pipe, "plugins"))
                        if "#" in p and kind_of(p) in self.schema]
            while expected and time.monotonic() < deadline:
                loaded = self._existing(pipe, expected)
                expected = [p for p in expected if p not in loaded]
                if expected:
                    time.sleep(0.1)

    def boot(self, name: str, mic: str = "") -> None:
        """The sound iNiR starts with: EasyEffects started if it is not running, the preset played, the microphone's
        sound when one is named, effects on."""
        if not self.ee.connect():
            self.start()
        self.apply(name)
        if mic:
            self.apply_mic(mic) if mic in self.builtins["microphone"] else self.load(mic, "input")
        if self.ee.bypassed():
            self.ee.bypass(False)

    def quit(self) -> None:
        if not self.ee.quit():
            raise RuntimeError("quit_failed")

    def handle(self, request: dict) -> None:
        op = request.get("op")
        pipe = "input" if request.get("pipe") == "input" else "output"
        quiet = {"set": lambda: self.set_value(request),
                 "band": lambda: self.set_band(int(request.get("index", -1)), request.get("gain", 0), pipe),
                 "bypass": lambda: self.ee.bypass(bool(request.get("on"))),
                 "toggleBypass": lambda: self.ee.bypass(not self.ee.bypassed())}
        loud = {
            "status": None,
            "refresh": None,
            "start": self.start,
            "boot": lambda: self.boot(str(request.get("name", "")), str(request.get("mic", "") or "")),
            "poll": None,
            "exclude": lambda: self.exclude(str(request.get("app", "")), bool(request.get("on")),
                                            "input" if request.get("pipe") == "input" else "output"),
            "rememberApp": lambda: self.remember_app(request.get("app"), str(request.get("preset", ""))),
            "forgetApp": lambda: self.forget_app(request.get("app")),
            "quit": self.quit,
            "enable": lambda: self.set_enabled(request),
            "bands": lambda: self.set_bands(int(request.get("count", 0))),
            "builtin": lambda: self.apply_builtin(str(request.get("name", ""))),
            "apply": lambda: self.apply(str(request.get("name", ""))),
            "mic": lambda: self.apply_mic(str(request.get("name", ""))),
            "tune": lambda: self.tune(request),
            "add": lambda: self.add(str(request.get("kind", ""))),
            "remove": lambda: self.remove(str(request.get("id", ""))),
            "save": lambda: self.save(request.get("name"), pipe),
            "load": lambda: self.load(str(request.get("name", "")), pipe),
            "rename": lambda: self.rename(str(request.get("from", "")), request.get("to"), pipe),
            "delete": lambda: self.delete(str(request.get("name", "")), pipe),
            "revert": self.revert,
            "headroom": lambda: self.set_headroom(bool(request.get("on"))),
            "remember": lambda: self.remember(request.get("sink"), str(request.get("preset", ""))),
            "forget": lambda: self.forget(request.get("sink")),
            "export": lambda: self.export(str(request.get("name", "")), str(request.get("path", "")),
                                          str(request.get("format", "inir"))),
            "import": lambda: emit({"type": "imported", "name": self.import_preset(str(request.get("path", "")))}),
            "probe": lambda: emit({"type": "probed", "pipe": pipe,
                                   "id": self.probe(str(request.get("device", "") or request.get("sink", "")),
                                                    str(request.get("replace", "") or ""), pipe)}),
            "tuneFor": lambda: self.tune_for(str(request.get("id", "") or ""), pipe),
            "renameTuned": lambda: self.rename_tuned(str(request.get("id", "")), request.get("name"), pipe),
            "forgetTuned": lambda: self.forget_tuned(str(request.get("id", "")), pipe),
            "follow": lambda: self.follow(str(request.get("device", "") or request.get("sink", "")), pipe),
            "tuningFollow": lambda: self.set_follow(bool(request.get("on")), pipe),
        }
        try:
            if op in quiet:
                quiet[op]()
                if op in ("bypass", "toggleBypass"):
                    emit({"type": "bypass", "on": self.ee.bypassed()})
                return
            if op not in loud:
                raise ValueError("unknown_op")
            if op == "poll" and not self.poll():
                emit({"type": "poll"})
                return
            if loud[op] is not None:
                loud[op]()
            if op == "export":
                emit({"type": "exported", "path": str(request.get("path", ""))})
        except (ValueError, RuntimeError, OSError) as error:
            emit({"type": "error", "op": op, "message": str(error)})
            if op in quiet:
                # Nothing waits on a quiet command: the state it brings back only puts the knobs right.
                emit(dict(self.report(), quiet=True))
                return
        except Exception as error:  # noqa: BLE001 - one bad request never ends the helper
            emit({"type": "error", "op": op, "message": f"internal_{type(error).__name__}"})
            if op in quiet:
                emit(dict(self.report(), quiet=True))
                return
        if op in ("status", "start", "boot", "quit"):
            emit(self.status())
        emit(self.report())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--presets-dir", type=Path, required=True)
    parser.add_argument("--state-file", type=Path, required=True)
    args = parser.parse_args()
    engine = Engine(args.presets_dir, args.state_file)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            emit({"type": "error", "op": "", "message": "invalid_json"})
            continue
        if not isinstance(request, dict):
            continue
        try:
            engine.handle(request)
        except Exception as error:  # noqa: BLE001 - a report that fails still answers, so nothing waits forever
            emit({"type": "error", "op": request.get("op"), "message": f"internal_{type(error).__name__}"})
            emit({"type": "state", "running": False, "unknown": True})
    return 0


if __name__ == "__main__":
    sys.exit(main())
