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
FLATPAK_ID = "com.github.wwmm.easyeffects"
PIPES = {
    "output": {"core": ["equalizer", "filter", "bass_enhancer", "exciter", "autogain", "limiter"],
               "section": "StreamOutputs", "preset": "iNiR Audio Engine"},
    "input": {"core": ["filter", "rnnoise", "gate", "autotune", "compressor", "limiter"],
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


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, separators=(",", ":")) + "\n")
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
        out = subprocess.run(["pgrep", "-n", "-x", "easyeffects"], capture_output=True, text=True)
        value = out.stdout.strip()
        return int(value) if value.isdigit() else None

    def running_flatpak(self) -> bool:
        pid = self.pid()
        if pid is None:
            return False
        try:
            environ = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        except OSError:
            return False
        return f"FLATPAK_ID={FLATPAK_ID}".encode() in environ

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

    def ask(self, line: str):
        if not self.send(line):
            return None
        try:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(4096)
                if not chunk:
                    self.drop()
                    return None
                self.buffer += chunk
        except OSError:
            self.drop()
            return None
        reply, self.buffer = self.buffer.split(b"\n", 1)
        return reply.decode(errors="replace").strip()

    def get(self, pipe: str, path: str):
        value = self.ask(f"get_property:{pipe}:{path}")
        return None if value is None or value.startswith("error_") else value

    def set(self, pipe: str, path: str, value) -> bool:
        if isinstance(value, bool):
            value = "true" if value else "false"
        text = str(value)
        if "\n" in text:
            return False
        return self.send(f"set_property:{pipe}:{path}:{text}")

    def bypassed(self) -> bool:
        # The server answers 1 when bypassed and 2 when not, with no line break.
        if not self.send("get_global_bypass"):
            return False
        try:
            chunk = self.sock.recv(16)
        except OSError:
            self.drop()
            return False
        return chunk.strip() == b"1"

    def bypass(self, on: bool) -> bool:
        return self.send(f"global_bypass:{1 if on else 0}")

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
        self.builtins = json.loads((HERE / "audio-presets.json").read_text(encoding="utf-8"))
        self.state = self._read_state()

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
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, indent=1) + "\n", encoding="utf-8")
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

    def _exists(self, pipe: str, plugin_id: str) -> bool:
        return kind_of(plugin_id) in self.schema and "#" in plugin_id \
            and self.ee.get(pipe, f"{self._path(plugin_id)}:bypass") is not None

    def chain(self, pipe: str = "output") -> list:
        """A chain. Once the engine has loaded one, the chain it wrote is the truth: EasyEffects writes
        easyeffectsrc lazily, so right after a load it still lists the chain before it."""
        own = self._pipe(pipe)
        known = [p for p in (own.get("chain") or []) if self._exists(pipe, p)]
        core = own.get("core") or {}
        if known and all(core.get(kind) in known for kind in PIPES[pipe]["core"]):
            return known
        return [p for p in self._config_list(pipe, "plugins") if self._exists(pipe, p)]

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
        values = {}
        for prop in self.schema[kind]["props"]:
            values[prop["name"]] = self._parse(prop, self.ee.get(pipe, f"{path}:{prop['name']}"))
        entry = {"id": plugin_id, "kind": kind, "label": self.schema[kind]["label"],
                 "enabled": not values.pop("bypass", False), "values": values,
                 "defaults": self.defaults(kind)}
        if kind == "equalizer":
            count = int(values.get("numBands", 0))
            channel = {p["name"]: p for p in self.schema["equalizer"]["channel"]}
            if full:
                entry["channels"] = {}
                for side in ("left", "right"):
                    entry["channels"][side] = {
                        f"band{i}{name}": self._parse(channel[f"band{i}{name}"],
                                                      self.ee.get(pipe, f"{path}:{side}:band{i}{name}"))
                        for i in range(count) for name in BAND_PROPS}
            entry["bands"] = [{
                "frequency": self._parse(channel[f"band{i}Frequency"],
                                         self.ee.get(pipe, f"{path}:left:band{i}Frequency")),
                "gain": self._parse(channel[f"band{i}Gain"],
                                    self.ee.get(pipe, f"{path}:left:band{i}Gain")),
            } for i in range(count)]
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
        preset = {pipe: {"blocklist": self._config_list(pipe, "blocklist"), "plugins_order": order}}
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
            self.ee.get(pipe, f"{self._path(order[0])}:bypass")
        self._pipe(pipe)["chain"] = order
        self._write_state()
        return True

    def _wait(self, pipe: str, order: list) -> bool:
        deadline = time.monotonic() + 4
        pending = list(order)
        while pending and time.monotonic() < deadline:
            pending = [p for p in pending if self.ee.get(pipe, f"{self._path(p)}:bypass") is None]
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

    def _builtin_values(self, name: str, kind: str, band_count: int) -> tuple:
        preset = self.builtins["presets"][name][kind]
        if kind == "equalizer":
            return self._eq_values(preset["gains"], preset["inputGain"], band_count)
        return dict(preset), None

    def _mic_values(self, name: str, kind: str):
        """A microphone sound's switch and values for one effect; None where the sound leaves it alone."""
        if kind not in self.builtins["microphone"][name]:
            return None
        preset = dict(self.builtins["microphone"][name][kind])
        return bool(preset.pop("enabled", False)), preset

    def _mic_start(self, kind: str) -> dict:
        if kind == "autotune":
            return dict(self.builtins["autotune"]["styles"]["natural"])
        return self._mic_values("Calls", kind)[1]

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
            if pipe == "output":
                values, channels = self._builtin_values("Flat", kind, 10)
            else:
                values, channels = self._mic_start(kind), None
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
            values = self._mic_start(kind) if pipe == "input" else self._builtin_values("Flat", kind, 10)[0]
            plan.append({"id": core[kind], "enabled": False, "values": values, "channels": None})
        plan += self.snapshot([p for p in chain if p not in kept.values()], pipe)
        self._pipe(pipe)["core"] = core
        if not self.rebuild(plan, pipe):
            raise RuntimeError("chain_failed")
        return core

    # --- what is heard now, and what it started as ------------------------------

    def light(self, core: dict, chain: list) -> dict:
        """What a person can change, in a form to compare: core switches and values, band gains, extras."""
        out = {"core": {}, "extras": []}
        for kind in CORE:
            entry = self.read_plugin(core[kind])
            out["core"][kind] = {"enabled": entry["enabled"], "values": entry["values"],
                                 "bands": [b["gain"] for b in entry.get("bands", [])]}
        for plugin_id in chain:
            if plugin_id in core.values():
                continue
            entry = self.read_plugin(plugin_id)
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

    def modified(self, core: dict, chain: list) -> bool:
        baseline = self.state.get("baseline")
        if not baseline or not self.state.get("active") or not core:
            return False
        return self.light(core, chain) != baseline.get("light")

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
        path = self._path(core["equalizer"])
        count = int(float(self.ee.get("output", f"{path}:numBands") or 0))
        gains = [float(self.ee.get("output", f"{path}:left:band{i}Gain") or 0) for i in range(count)]
        self.ee.set("output", f"{path}:inputGain", round(-max([0.0] + gains), 2))

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
            elif pipe == "output":
                values, channels = self._builtin_values("Flat", kind, 10)
                entry = {"id": "", "kind": kind, "label": self.schema[kind]["label"],
                         "enabled": False, "values": values, "defaults": self.defaults(kind)}
                if kind == "equalizer":
                    left = channels["left"]
                    entry["bands"] = [{"frequency": left[f"band{i}Frequency"],
                                       "gain": left[f"band{i}Gain"]} for i in range(10)]
            else:
                values = dict(self.defaults(kind))
                values.update(self._mic_start(kind))
                entry = {"id": "", "kind": kind, "label": self.schema[kind]["label"],
                         "enabled": False, "values": values, "defaults": self.defaults(kind)}
            entry["needs"] = NEEDS.get(kind, "")
            if kind == "autotune":
                entry["tune"] = self.tune_of(entry["values"])
            modules.append(entry)
        return modules

    def report(self) -> dict:
        if not self.ee.connect():
            return {"type": "state", "running": False, "active": self.state.get("active", ""),
                    "devices": self.state.get("devices", {}), "headroom": self.state.get("headroom", True)}
        chain = self.chain()
        core = self.core_ids(chain)
        extras = [self.read_plugin(p) for p in chain if p not in core.values()]
        for entry in extras:
            entry["props"] = [p for p in self.schema[entry["kind"]]["props"]
                              if p["name"] != "bypass" and p["type"] != "string"]
        mic_chain = self.chain("input")
        mic_core = self.core_ids(mic_chain, "input")
        if not mic_core and self._kept_core(mic_chain, "input"):
            mic_core = self.ensure_core("input")
        return {"type": "state", "running": True, "adopted": bool(core),
                "core": self._core_report("output", core), "extras": extras,
                "active": self.state.get("active", ""), "modified": self.modified(core, chain),
                "bypass": self.ee.bypassed(), "headroom": self.state.get("headroom", True),
                "devices": self.state.get("devices", {}),
                "builtins": ["Default"] + list(self.builtins["presets"].keys()),
                "presets": self.preset_names(), "presetInfo": self.preset_info(),
                "mic": {"adopted": bool(mic_core), "core": self._core_report("input", mic_core),
                        "active": self._pipe("input").get("active", ""),
                        "builtins": list(self.builtins["microphone"].keys())}}

    # --- presets ----------------------------------------------------------------

    def _preset_path(self, name: str) -> Path:
        safe = re.sub(r"[^\w\- ]", "_", name).strip() or "preset"
        return self.presets_dir / f"{safe}.json"

    def _preset_files(self) -> list:
        out = []
        try:
            files = sorted(self.presets_dir.glob("*.json"))
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

    def preset_names(self) -> list:
        return sorted((data["name"] for _, data in self._preset_files()), key=str.casefold)

    def preset_info(self) -> dict:
        """What each of the person's presets holds: the sound it started from, and how many effects it turns on."""
        info = {}
        for _, data in self._preset_files():
            on = [kind for kind, entry in (data.get("core") or {}).items() if (entry or {}).get("enabled")]
            on += [extra.get("kind") for extra in (data.get("extras") or []) if extra.get("enabled")]
            info[data["name"]] = {"base": data.get("base") or "", "on": len(on)}
        return info

    def _find_preset(self, name: str):
        for path, data in self._preset_files():
            if data.get("name") == name:
                return path
        return None

    def _builtin_names(self) -> list:
        return ["Default"] + list(self.builtins["presets"].keys())

    def _check_name(self, name: str) -> str:
        name = str(name or "").strip()
        if not name or len(name) > NAME_MAX:
            raise ValueError("invalid_name")
        if name in self._builtin_names():
            raise ValueError("builtin_name")
        return name

    def _free_name(self, name: str) -> str:
        if self._find_preset(name) is None and name not in self._builtin_names():
            return name
        n = 2
        while self._find_preset(f"{name} {n}") is not None:
            n += 1
        return f"{name} {n}"

    def _write_preset(self, data: dict, path=None) -> None:
        path = path or self._preset_path(data["name"])
        if path.exists() and self._find_preset(data["name"]) != path:
            n = 2
            while path.exists():
                path = self._preset_path(f"{data['name']} {n}")
                n += 1
        self.presets_dir.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
        tmp.replace(path)

    def _current_preset(self, name: str) -> dict:
        core = self.ensure_core()
        chain = self.chain()
        data = {"name": name, "base": self.state.get("active", ""), "core": {}, "extras": []}
        for kind in CORE:
            entry = self.read_plugin(core[kind], full=True)
            data["core"][kind] = {"enabled": entry["enabled"], "values": entry["values"]}
            if "channels" in entry:
                data["core"][kind]["channels"] = entry["channels"]
        for plugin_id in chain:
            if plugin_id in core.values():
                continue
            entry = self.read_plugin(plugin_id, full=True)
            item = {"kind": entry["kind"], "enabled": entry["enabled"], "values": entry["values"]}
            if "channels" in entry:
                item["channels"] = entry["channels"]
            data["extras"].append(item)
        return data

    def save(self, name: str) -> None:
        name = self._check_name(name)
        self._write_preset(self._current_preset(name), self._find_preset(name))
        self.state["active"] = name
        self.mark_baseline()

    def _load_data(self, data: dict, fresh: bool = False) -> None:
        """Play a preset. `fresh` builds the whole chain anew instead of keeping the one EasyEffects has."""
        if fresh:
            core = {}
            for kind in CORE:
                core[kind] = self._free_id(kind, list(core.values()))
            self._pipe("output")["core"] = core
        else:
            core = self.ensure_core()
        plan = []
        for kind in CORE:
            saved = (data.get("core") or {}).get(kind) or {}
            values, channels = self._builtin_values("Flat", kind, 10)
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
        if not self.rebuild(plan):
            raise RuntimeError("chain_failed")

    def load(self, name: str) -> None:
        path = self._find_preset(name)
        if path is None:
            raise ValueError("preset_not_found")
        self._load_data(json.loads(path.read_text(encoding="utf-8")))
        self.state["active"] = name
        self.headroom_follow()
        self.mark_baseline()

    def rename(self, old: str, new: str) -> None:
        new = self._check_name(new)
        path = self._find_preset(old)
        if path is None:
            raise ValueError("preset_not_found")
        if new != old and self._find_preset(new) is not None:
            raise ValueError("name_taken")
        data = json.loads(path.read_text(encoding="utf-8"))
        data["name"] = new
        target = self._preset_path(new)
        tmp = target.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
        tmp.replace(target)
        if target != path:
            path.unlink(missing_ok=True)
        if self.state.get("active") == old:
            self.state["active"] = new
        for sink, preset in list((self.state.get("devices") or {}).items()):
            if preset == old:
                self.state["devices"][sink] = new
        self._write_state()

    def delete(self, name: str) -> None:
        path = self._find_preset(name)
        if path is None:
            raise ValueError("preset_not_found")
        path.unlink(missing_ok=True)
        self.state["devices"] = {sink: preset for sink, preset in (self.state.get("devices") or {}).items()
                                 if preset != name}
        # The sound it described is gone with it: the engine goes back to Default.
        if self.state.get("active") == name:
            if self.ee.connect():
                self.apply_builtin("Default")
            else:
                self.state["active"] = ""
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

    def import_preset(self, source: str) -> str:
        path = Path(source).expanduser()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise ValueError("unreadable_file")
        if not isinstance(data, dict):
            raise ValueError("unknown_format")
        if "core" in data or "extras" in data:
            data["name"] = self._free_name(str(data.get("name") or path.stem)[:NAME_MAX])
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
        if name not in self._builtin_names():
            raise ValueError("preset_not_found")
        core = self.ensure_core()
        for kind in CORE:
            plugin_id = core[kind]
            path = self._path(plugin_id)
            enabled = self.ee.get("output", f"{path}:bypass") in ("false", "0")
            if name != "Default" and not enabled:
                continue
            count = int(float(self.ee.get("output", f"{path}:numBands") or 10)) if kind == "equalizer" else 10
            if count not in BAND_COUNTS:
                count = 10
            values, channels = self._builtin_values("Flat" if name == "Default" else name, kind, count)
            self._apply(plugin_id, values, channels)
            if name == "Default":
                self.ee.set("output", f"{path}:bypass", True)
        self.state["active"] = name
        self.mark_baseline()

    def apply(self, name: str) -> None:
        """A sound by name, built in or the person's own: what devices and the command line ask for."""
        if name in self._builtin_names():
            self.apply_builtin(name)
        else:
            self.load(name)

    def apply_mic(self, name: str) -> None:
        if name not in self.builtins["microphone"]:
            raise ValueError("preset_not_found")
        core = self.ensure_core("input")
        for kind in PIPES["input"]["core"]:
            sound = self._mic_values(name, kind)
            if sound is None:
                continue
            enabled, values = sound
            self._apply(core[kind], values, pipe="input")
            self.ee.set("input", f"{self._path(core[kind])}:bypass", not enabled)
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

    def set_band(self, index: int, gain: float) -> None:
        core = self.ensure_core()
        path = self._path(core["equalizer"])
        count = int(float(self.ee.get("output", f"{path}:numBands") or 0))
        if not 0 <= index < count:
            raise ValueError("invalid_band")
        gain = max(-36.0, min(36.0, float(gain)))
        for side in ("left", "right"):
            self.ee.set("output", f"{path}:{side}:band{index}Gain", gain)
        self.headroom_follow()

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

    def set_headroom(self, on: bool) -> None:
        self.state["headroom"] = bool(on)
        self._write_state()
        self.headroom_follow()

    def start(self) -> None:
        if not self.ee.start():
            raise RuntimeError("start_failed")

    def quit(self) -> None:
        if not self.ee.quit():
            raise RuntimeError("quit_failed")

    def handle(self, request: dict) -> None:
        op = request.get("op")
        quiet = {"set": lambda: self.set_value(request),
                 "band": lambda: self.set_band(int(request.get("index", -1)), request.get("gain", 0)),
                 "bypass": lambda: self.ee.bypass(bool(request.get("on"))),
                 "toggleBypass": lambda: self.ee.bypass(not self.ee.bypassed())}
        loud = {
            "status": None,
            "refresh": None,
            "start": self.start,
            "quit": self.quit,
            "enable": lambda: self.set_enabled(request),
            "bands": lambda: self.set_bands(int(request.get("count", 0))),
            "builtin": lambda: self.apply_builtin(str(request.get("name", ""))),
            "apply": lambda: self.apply(str(request.get("name", ""))),
            "mic": lambda: self.apply_mic(str(request.get("name", ""))),
            "tune": lambda: self.tune(request),
            "add": lambda: self.add(str(request.get("kind", ""))),
            "remove": lambda: self.remove(str(request.get("id", ""))),
            "save": lambda: self.save(request.get("name")),
            "load": lambda: self.load(str(request.get("name", ""))),
            "rename": lambda: self.rename(str(request.get("from", "")), request.get("to")),
            "delete": lambda: self.delete(str(request.get("name", ""))),
            "revert": self.revert,
            "headroom": lambda: self.set_headroom(bool(request.get("on"))),
            "remember": lambda: self.remember(request.get("sink"), str(request.get("preset", ""))),
            "forget": lambda: self.forget(request.get("sink")),
            "export": lambda: self.export(str(request.get("name", "")), str(request.get("path", "")),
                                          str(request.get("format", "inir"))),
            "import": lambda: emit({"type": "imported", "name": self.import_preset(str(request.get("path", "")))}),
        }
        try:
            if op in quiet:
                quiet[op]()
                if op in ("bypass", "toggleBypass"):
                    emit({"type": "bypass", "on": self.ee.bypassed()})
                return
            if op not in loud:
                raise ValueError("unknown_op")
            if loud[op] is not None:
                loud[op]()
            if op == "export":
                emit({"type": "exported", "path": str(request.get("path", ""))})
        except (ValueError, RuntimeError, OSError) as error:
            emit({"type": "error", "op": op, "message": str(error)})
        if op in ("status", "start", "quit"):
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
        if isinstance(request, dict):
            engine.handle(request)
    return 0


if __name__ == "__main__":
    sys.exit(main())
