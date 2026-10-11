#!/usr/bin/env python3
"""Generate scripts/audio/ee-schema.json from EasyEffects' KConfig schemas.

The Audio Engine drives EasyEffects through its local socket, whose
get_property/set_property names are the KConfig entry names. This table gives
every plugin's properties with their type, range, default and choices, so the
engine can validate values and draw a page for any effect.

Usage:
    python3 scripts/audio/generate_ee_schema.py <easyeffects>/src/contents/kcfg [--version 8.3.0]

The kcfg directory is read inside an EasyEffects source tree: the plugins' *_preset.cpp two levels up give where
each property sits in EasyEffects' own preset format, for exporting presets it can load.
"""

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent / "ee-schema.json"

# Output-pipeline plugins and the names EasyEffects shows (tags_plugin_name.cpp).
# echo_canceller is left out: it needs a microphone reference.
PLUGINS = {
    "autogain": "Autogain",
    "autotune": "Autotune",
    "bass_enhancer": "Bass Enhancer",
    "bass_loudness": "Bass Loudness",
    "compressor": "Compressor",
    "convolver": "Convolver",
    "crossfeed": "Crossfeed",
    "crosstalk_canceller": "Crosstalk Canceller",
    "crusher": "Crusher",
    "crystalizer": "Crystalizer",
    "deepfilternet": "Deep Noise Remover",
    "deesser": "Deesser",
    "delay": "Delay",
    "equalizer": "Equalizer",
    "midside_equalizer": "Mid-Side Equalizer",
    "exciter": "Exciter",
    "expander": "Expander",
    "filter": "Filter",
    "gate": "Gate",
    "level_meter": "Level Meter",
    "limiter": "Limiter",
    "loudness": "Loudness",
    "maximizer": "Maximizer",
    "multiband_compressor": "Multiband Compressor",
    "multiband_gate": "Multiband Gate",
    "pitch": "Pitch",
    "reverb": "Reverberation",
    "rnnoise": "Noise Reduction",
    "speex": "Speech Processor",
    "stereo_tools": "Stereo Tools",
    "voice_suppressor": "Voice Suppressor",
}


def number(text: str):
    value = float(text)
    return int(value) if value.is_integer() else value


def read_entries(path: Path) -> list:
    root = ET.parse(path).getroot()
    ns = {"k": root.tag.split("}")[0][1:]} if root.tag.startswith("{") else {}
    prefix = "k:" if ns else ""

    def child(entry, name):
        node = entry.find(prefix + name, ns)
        return node.text.strip() if node is not None and node.text is not None else ""

    raw = []
    for entry in root.iter(("{%s}entry" % ns["k"]) if ns else "entry"):
        raw.append((entry.get("name"), entry.get("type"), child(entry, "default"),
                    child(entry, "min"), child(entry, "max")))

    labels = {name[: -len("Labels")]: default.split(",")
              for name, kind, default, _, _ in raw
              if kind == "StringList" and name.endswith("Labels")}

    props = []
    for name, kind, default, low, high in raw:
        if kind == "StringList":
            continue
        prop = {"name": name}
        if kind == "Bool":
            prop["type"] = "bool"
            prop["default"] = default.lower() == "true"
        elif kind == "Int" and name in labels:
            prop["type"] = "enum"
            prop["choices"] = labels[name]
            prop["default"] = int(default or 0)
        elif kind in ("Int", "UInt"):
            prop["type"] = "int"
            prop["default"] = int(float(default or 0))
        elif kind == "Double":
            prop["type"] = "double"
            prop["default"] = number(default or "0")
        elif kind == "String":
            prop["type"] = "string"
            prop["default"] = default.strip('"')
        else:
            continue
        if low:
            prop["min"] = number(low)
        if high:
            prop["max"] = number(high)
        props.append(prop)
    return props


SAVE_LINE = re.compile(r'json\[section\]\[instance_name\]((?:\["[^"]+"\])+)\s*=\s*(.+)', re.S)
ENUM_VALUE = re.compile(r'settings->(?:default\w+LabelsValue|\w+Labels)\(\)\[settings->(\w+)\(\)\]')
PLAIN_VALUE = re.compile(r'^settings->(\w+)\(\)$')


def read_preset_keys(path: Path, names: set) -> list:
    """Where each property sits in an EasyEffects preset file, from the plugin's save(): the JSON path, and whether
    it is written as its label. Statements the parser cannot read (loops, macros) are left out: EasyEffects gives
    their properties its defaults when such a preset loads."""
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8")
    start = text.find("::save(")
    if start < 0:
        return []
    body = text[text.find("{", start) + 1:]
    body = body[:re.search(r"\n}\n", body).start()]
    keys = []
    for statement in body.split(";"):
        match = SAVE_LINE.search(" ".join(statement.split()))
        if not match:
            continue
        json_path = re.findall(r'\["([^"]+)"\]', match.group(1))
        value = match.group(2).strip()
        enum = ENUM_VALUE.search(value)
        plain = PLAIN_VALUE.match(value)
        prop = enum.group(1) if enum else plain.group(1) if plain else None
        if prop in names:
            keys.append({"path": json_path, "prop": prop, "label": enum is not None})
    return keys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kcfg_dir", type=Path)
    parser.add_argument("--version", default="8.3.0")
    args = parser.parse_args()

    plugins = {}
    for name, label in PLUGINS.items():
        path = args.kcfg_dir / f"easyeffects_db_{name}.kcfg"
        if not path.is_file():
            print(f"missing {path}", file=sys.stderr)
            return 1
        props = read_entries(path)
        source = args.kcfg_dir.parent.parent / f"{name}_preset.cpp"
        plugins[name] = {"label": label, "props": props,
                         "preset": read_preset_keys(source, {p["name"] for p in props})}

    channel = args.kcfg_dir / "easyeffects_db_equalizer_channel.kcfg"
    plugins["equalizer"]["channel"] = read_entries(channel)
    # A band's type, mode and slope are written by their labels in a preset file.
    channel_root = ET.parse(channel).getroot()
    tag = channel_root.tag.split("}")[0] + "}" if channel_root.tag.startswith("{") else ""
    labels = {}
    for entry in channel_root.iter(tag + "entry"):
        name = entry.get("name") or ""
        if entry.get("type") == "StringList" and name.startswith("band") and name.endswith("Labels"):
            labels[name[len("band"):-len("Labels")]] = (entry.find(tag + "default").text or "").split(",")
    plugins["equalizer"]["channelLabels"] = labels

    OUTPUT.write_text(json.dumps({"easyeffects": args.version, "plugins": plugins},
                                 indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(Path.cwd()) if OUTPUT.is_relative_to(Path.cwd()) else OUTPUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
