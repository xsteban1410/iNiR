#!/usr/bin/env python3
"""Audio Engine helper against a fake EasyEffects socket.

Checks: the core goes in front of the user's chain and keeps its values; built-in
presets touch only the enabled core effects; Default turns the core off; band
counts; added effects pile up and leave one by one; headroom follows the
highest band; a changed preset reads as modified and reverts; global bypass;
sounds remembered per output; saving, loading, renaming and deleting presets;
exporting in both formats and importing them back; the microphone chain; the sound iNiR
starts with; cheap polls; apps left out of a chain; sounds per app; file-name collisions;
malformed imports and failing quiet commands never ending the helper.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "scripts" / "audio" / "audio_engine.py"
SCHEMA = json.loads((REPO / "scripts" / "audio" / "ee-schema.json").read_text())["plugins"]


def typed(prop: dict):
    return float(prop["default"]) if prop["type"] == "double" else prop["default"]


class FakeEasyEffects:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.sock_path = str(root / "EasyEffectsServer")
        self.config = root / "config" / "easyeffects" / "db" / "easyeffectsrc"
        self.data = root / "data" / "easyeffects"
        self.config.parent.mkdir(parents=True)
        self.pipes = {"output": {"dbs": {}, "chain": []}, "input": {"dbs": {}, "chain": []}}
        self.bypass = False
        self.loads = 0
        self.blocklists = {"output": None, "input": None}

    def dbs(self, pipe: str = "output") -> dict:
        return self.pipes[pipe]["dbs"]

    def chain(self, pipe: str = "output") -> list:
        return self.pipes[pipe]["chain"]

    def add(self, plugin_id: str, pipe: str = "output", stale: bool = False, **values) -> None:
        kind = plugin_id.split("#")[0]
        db = {p["name"]: typed(p) for p in SCHEMA[kind]["props"]}
        db.update(values)
        self.dbs(pipe)[plugin_id] = db
        if kind == "equalizer":
            for side in ("left", "right"):
                self.dbs(pipe)[f"{plugin_id}#{side}"] = {p["name"]: typed(p) for p in SCHEMA["equalizer"]["channel"]}
        self.chain(pipe).append(plugin_id)
        if not stale:
            self.write_config()

    def write_config(self) -> None:
        self.config.write_text("[StreamOutputs]\nplugins=" + ",".join(self.chain("output")) + "\n"
                               "[StreamInputs]\nplugins=" + ",".join(self.chain("input")) + "\n")

    def load(self, pipe: str, name: str) -> None:
        data = json.loads((self.data / pipe / f"{name}.json").read_text())[pipe]
        self.loads += 1
        self.blocklists[pipe] = data.get("blocklist")
        self.pipes[pipe] = {"dbs": {}, "chain": []}
        for plugin_id in data["plugins_order"]:
            kind = plugin_id.split("#")[0]
            body = data.get(plugin_id, {})
            # Like EasyEffects, a loaded preset reaches easyeffectsrc only later.
            self.add(plugin_id, pipe, stale=True)
            db = self.dbs(pipe)[plugin_id]
            props = {p["name"]: p for p in SCHEMA[kind]["props"]}
            for key in SCHEMA[kind]["preset"]:
                node = body
                for part in key["path"]:
                    node = node.get(part) if isinstance(node, dict) else None
                if node is None:
                    continue
                prop = props[key["prop"]]
                db[key["prop"]] = prop["choices"].index(node) if key["label"] else node
            if kind == "equalizer":
                db["numBands"] = int(body.get("num-bands", db["numBands"]))
                labels = SCHEMA["equalizer"]["channelLabels"]
                for side in ("left", "right"):
                    for band, values in (body.get(side) or {}).items():
                        if not values:
                            continue
                        channel = self.dbs(pipe)[f"{plugin_id}#{side}"]
                        for name, value in values.items():
                            prop = name.capitalize() if name != "q" else "Q"
                            channel[f"{band}{prop}"] = labels[prop].index(value) if prop in labels else value

    def answer(self, line: str):
        parts = line.split(":")
        if parts[0] == "load_preset":
            self.load(parts[1], ":".join(parts[2:]))
            return None
        if parts[0] == "global_bypass":
            self.bypass = parts[1] == "1"
            return None
        if parts[0] == "get_global_bypass":
            return ("1" if self.bypass else "2", False)
        if parts[0] not in ("get_property", "set_property"):
            return None
        pipe, kind, index = parts[1], parts[2], parts[3]
        rest = parts[4:]
        key = f"{kind}#{index}"
        if rest and rest[0] in ("left", "right"):
            key += "#" + rest[0]
            rest = rest[1:]
        db = self.dbs(pipe).get(key)
        if parts[0] == "get_property":
            if db is None:
                return "error_plugin_not_found"
            if rest[0] not in db:
                return "error_property_not_found"
            value = db[rest[0]]
            return ("true" if value else "false") if isinstance(value, bool) else str(value)
        if db is not None and rest[0] in db:
            current = db[rest[0]]
            raw = rest[1]
            if isinstance(current, bool):
                db[rest[0]] = raw in ("true", "1", "on")
            elif isinstance(current, int):
                db[rest[0]] = int(float(raw))
            elif isinstance(current, float):
                db[rest[0]] = float(raw)
            else:
                db[rest[0]] = raw
        return None

    def serve(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.sock_path)
        server.listen(4)

        def client(conn):
            buffer = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    reply = self.answer(line.decode())
                    if isinstance(reply, tuple):
                        conn.sendall(reply[0].encode())
                    elif reply is not None:
                        conn.sendall((reply + "\n").encode())

        def accept():
            while True:
                conn, _ = server.accept()
                threading.Thread(target=client, args=(conn,), daemon=True).start()

        threading.Thread(target=accept, daemon=True).start()


class Helper:
    def __init__(self, root: Path, fake: FakeEasyEffects) -> None:
        env = dict(os.environ, EASYEFFECTS_SERVER_SOCKET=fake.sock_path,
                   XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
                   PATH="/usr/bin:/bin")
        self.root = root
        self.proc = subprocess.Popen(
            [sys.executable, "-I", str(HELPER), "--presets-dir", str(root / "presets"),
             "--state-file", str(root / "state" / "audio-engine.json")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

    def call(self, **request) -> list:
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
        if request["op"] in ("set", "band", "bypass"):
            self.proc.stdin.write(json.dumps({"op": "refresh"}) + "\n")
            self.proc.stdin.flush()
        events = []
        while True:
            event = json.loads(self.proc.stdout.readline())
            events.append(event)
            if event["type"] == "state":
                return events

    def state(self, **request) -> dict:
        events = self.call(**request)
        errors = [e for e in events if e["type"] == "error"]
        assert not errors, errors
        return events[-1]

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


CORE_KINDS = ["equalizer", "filter", "bass_enhancer", "exciter", "autogain", "limiter"]


def core(state: dict, kind: str) -> dict:
    return next(m for m in state["core"] if m["kind"] == kind)


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fake = FakeEasyEffects(root)
        fake.add("equalizer#0", numBands=4)
        fake.add("gate#0", curveThreshold=-33.0, bypass=False)
        fake.serve()
        helper = Helper(root, fake)
        out = fake.dbs
        try:
            state = helper.state(op="refresh")
            assert state["running"] and not state["adopted"], state
            assert fake.loads == 0, "opening must not touch the chain"

            state = helper.state(op="enable", kind="equalizer", enabled=True)
            assert state["adopted"]
            assert fake.chain()[:6] == ["equalizer#1", "filter#0", "bass_enhancer#0", "exciter#0",
                                        "autogain#0", "limiter#0"], fake.chain()
            assert fake.chain()[6:] == ["equalizer#0", "gate#0"], fake.chain()
            assert out()["gate#0"]["curveThreshold"] == -33.0
            assert out()["equalizer#0"]["numBands"] == 4
            assert out()["equalizer#1"]["bypass"] is False and out()["limiter#0"]["bypass"] is True
            assert (root / "state" / "audio-engine-output-backup.json").exists()

            before = dict(out()["bass_enhancer#0"])
            state = helper.state(op="builtin", name="Rock")
            assert state["active"] == "Rock" and not state["modified"]
            assert out()["equalizer#1"]["inputGain"] == -4.0 and out()["equalizer#1#left"]["band0Gain"] == 4.0
            assert out()["bass_enhancer#0"] == before, "disabled core effects stay untouched"
            assert out()["gate#0"]["curveThreshold"] == -33.0, "extras stay untouched"

            # Headroom follows the highest band; a change reads as modified and reverts.
            state = helper.state(op="band", index=0, gain=6)
            assert out()["equalizer#1"]["inputGain"] == -6.0, out()["equalizer#1"]["inputGain"]
            assert state["modified"]
            state = helper.state(op="revert")
            assert out()["equalizer#1#left"]["band0Gain"] == 4.0 and not state["modified"]
            assert out()["equalizer#1"]["inputGain"] == -4.0
            helper.state(op="headroom", on=False)
            helper.state(op="band", index=0, gain=9)
            assert out()["equalizer#1"]["inputGain"] == -4.0, "without headroom the input gain stays"
            helper.state(op="headroom", on=True)
            assert out()["equalizer#1"]["inputGain"] == -9.0

            state = helper.state(op="bands", count=16)
            eq = core(state, "equalizer")
            assert eq["values"]["numBands"] == 16 and len(eq["bands"]) == 16
            assert eq["bands"][0]["frequency"] == 32 and eq["bands"][-1]["frequency"] == 16000

            helper.state(op="band", index=3, gain=2.5)
            assert out()["equalizer#1#right"]["band3Gain"] == 2.5
            helper.state(op="set", kind="limiter", prop="threshold", value=-70)
            assert out()["limiter#0"]["threshold"] == -48.0, "values are clamped to the schema"

            state = helper.state(op="add", kind="reverb")
            assert [e["kind"] for e in state["extras"]] == ["equalizer", "gate", "reverb"]
            assert out()["equalizer#1"]["numBands"] == 16, "values survive a chain change"
            assert out()["equalizer#1#left"]["band3Gain"] == 2.5

            state = helper.state(op="add", kind="autotune")
            autotune = state["extras"][-1]["id"]
            state = helper.state(op="add", kind="crusher")
            assert [e["kind"] for e in state["extras"]][-2:] == ["autotune", "crusher"], "adding never drops another"
            state = helper.state(op="remove", id=autotune)
            assert [e["kind"] for e in state["extras"]] == ["equalizer", "gate", "reverb", "crusher"], state["extras"]
            helper.state(op="remove", id=state["extras"][-1]["id"])

            state = helper.state(op="save", name="Mine")
            assert state["presets"] == ["Mine"] and state["active"] == "Mine" and not state["modified"]
            errors = [e for e in helper.call(op="save", name="Rock") if e["type"] == "error"]
            assert errors and errors[0]["message"] == "builtin_name"

            # Global bypass, for hearing the sound without any effect.
            state = helper.state(op="bypass", on=True)
            assert fake.bypass and state["bypass"]
            state = helper.state(op="bypass", on=False)
            assert not fake.bypass and not state["bypass"]

            # Sounds remembered per output follow a rename and leave with a delete.
            state = helper.state(op="remember", sink="alsa_output.headphones", preset="Mine")
            assert state["devices"] == {"alsa_output.headphones": "Mine"}
            state = helper.state(op="remember", sink="alsa_output.speakers", preset="Voice")
            state = helper.state(op="rename", **{"from": "Mine", "to": "Night"})
            assert state["devices"]["alsa_output.headphones"] == "Night" and state["active"] == "Night"
            state = helper.state(op="forget", sink="alsa_output.speakers")
            assert list(state["devices"]) == ["alsa_output.headphones"]

            # Export in both formats, then import them back.
            ours = root / "exports" / "night.json"
            theirs = root / "exports" / "Night EE.json"
            helper.state(op="export", name="Night", path=str(ours), format="inir")
            helper.state(op="export", name="Night", path=str(theirs), format="easyeffects")
            assert json.loads(ours.read_text())["name"] == "Night"
            ee = json.loads(theirs.read_text())["output"]
            assert ee["plugins_order"][:2] == ["equalizer#0", "filter#0"], ee["plugins_order"]
            assert ee["limiter#0"]["mode"] == "Herm Thin" and ee["equalizer#0"]["num-bands"] == 16
            assert ee["equalizer#0"]["left"]["band3"]["gain"] == 2.5

            events = helper.call(op="import", path=str(theirs))
            imported = next(e for e in events if e["type"] == "imported")["name"]
            state = events[-1]
            assert imported == "Night EE" and state["active"] == "Night EE", imported
            kinds = [p.split("#")[0] for p in fake.chain()]
            assert kinds[:6] == CORE_KINDS and kinds.count("limiter") == 1, "one core, never a second one"
            assert [e["kind"] for e in state["extras"]] == ["equalizer", "gate", "reverb"]
            assert core(state, "equalizer")["enabled"] and out()[core(state, "equalizer")["id"]]["numBands"] == 16
            assert out()[core(state, "equalizer")["id"] + "#left"]["band3Gain"] == 2.5, "EasyEffects' own format round-trips"
            events = helper.call(op="import", path=str(ours))
            assert next(e for e in events if e["type"] == "imported")["name"] == "Night 2"

            state = helper.state(op="load", name="Night")
            assert [e["kind"] for e in state["extras"]] == ["equalizer", "gate", "reverb"]
            assert core(state, "equalizer")["enabled"] and out()[core(state, "equalizer")["id"]]["numBands"] == 16
            assert out()["gate#0"]["curveThreshold"] == -33.0

            state = helper.state(op="delete", name="Night")
            assert "Night" not in state["presets"] and state["active"] == "Default", state["active"]
            assert all(out()[p]["bypass"] for p in fake.chain()[:6]), "deleting the active preset loads Default"
            assert state["devices"] == {}, "a deleted preset leaves the outputs that used it"
            assert core(state, "limiter")["defaults"]["threshold"] == 0

            # The microphone: its own core in front of its own chain.
            state = helper.state(op="mic", name="Calls")
            assert state["mic"]["adopted"] and state["mic"]["active"] == "Calls"
            assert fake.chain("input") == ["filter#0", "rnnoise#0", "gate#0", "autotune#0", "compressor#0", "limiter#0"]
            assert fake.dbs("input")["rnnoise#0"]["bypass"] is False
            assert fake.dbs("input")["gate#0"]["curveThreshold"] == -50.0
            assert fake.dbs("input")["autotune#0"]["bypass"] is True, "a sound for calls leaves the autotune off"
            helper.state(op="set", pipe="input", kind="gate", prop="curveThreshold", value=-42)
            assert fake.dbs("input")["gate#0"]["curveThreshold"] == -42.0

            # The autotune: a key and scale spell its notes, a style sets its knobs.
            helper.state(op="enable", pipe="input", kind="autotune", enabled=True)
            state = helper.state(op="tune", key=9, scale="minor", style="robot")
            tune = core(state["mic"], "autotune")["tune"]
            assert tune == {"key": 9, "scale": "minor", "style": "robot"}, tune
            at = fake.dbs("input")["autotune#0"]
            assert [at[n] for n in ("noteA", "noteASharp", "noteC", "noteCSharp")] == [True, False, True, False]
            assert at["correction"] == 1.0 and at["fastMode"] is True
            state = helper.state(op="set", pipe="input", kind="autotune", prop="correction", value=0.55)
            assert core(state["mic"], "autotune")["tune"]["style"] == "custom"
            state = helper.state(op="tune", scale="chromatic")
            assert core(state["mic"], "autotune")["tune"]["scale"] == "chromatic"
            helper.state(op="mic", name="Streaming")
            assert fake.dbs("input")["autotune#0"]["bypass"] is False, "a sound leaves an autotune it does not name"
            assert helper.call(op="tune", scale="dorian")[0]["message"] == "invalid_scale"
            helper.state(op="mic", name="Off")
            assert all(fake.dbs("input")[p]["bypass"] for p in fake.chain("input"))
            assert len(fake.chain()) >= 6, "the output chain is left alone"
        finally:
            helper.close()

        # An engine from before the autotune: its core grows in place, the user's own effects stay behind it.
        state_file = root / "state" / "audio-engine.json"
        saved = json.loads(state_file.read_text())
        old = ["filter#0", "rnnoise#0", "gate#0", "compressor#0", "limiter#0"]
        saved["pipes"]["input"]["core"] = {p.split("#")[0]: p for p in old}
        saved["pipes"]["input"]["chain"] = old + ["deesser#0"]
        state_file.write_text(json.dumps(saved))
        fake.pipes["input"] = {"dbs": {}, "chain": []}
        for plugin_id in old:
            fake.add(plugin_id, pipe="input", bypass=False)
        fake.add("deesser#0", pipe="input", threshold=-30.0)
        helper = Helper(root, fake)
        try:
            state = helper.state(op="refresh")
            assert fake.chain("input") == old[:3] + ["autotune#0"] + old[3:] + ["deesser#0"], fake.chain("input")
            assert state["mic"]["adopted"] and not core(state["mic"], "autotune")["enabled"]
            assert core(state["mic"], "gate")["enabled"], "the effects already on stay on"
            assert fake.dbs("input")["deesser#0"]["threshold"] == -30.0
        finally:
            helper.close()

        # The sound iNiR starts with: the preset played and effects back on; Settings reads the presets from the state.
        helper = Helper(root, fake)
        try:
            fake.bypass = True
            state = helper.state(op="boot", name="Rock")
            assert state["active"] == "Rock" and fake.bypass is False and state["bypass"] is False
            assert helper.call(op="boot", name="Nope")[0]["message"] == "preset_not_found"
            helper.state(op="save", name="Startup mine")
            saved = json.loads((root / "state" / "audio-engine.json").read_text())
            assert "Startup mine" in saved["presets"], saved.get("presets")

            # With a microphone sound named, iNiR starts with that too.
            state = helper.state(op="boot", name="Default", mic="Calls")
            assert state["mic"]["active"] == "Calls"

            # A poll with nothing changed is answered without reading the chain again; a change brings the state.
            helper.state(op="refresh")
            helper.proc.stdin.write(json.dumps({"op": "poll"}) + "\n")
            helper.proc.stdin.flush()
            assert json.loads(helper.proc.stdout.readline())["type"] == "poll"
            fake.bypass = True
            assert helper.state(op="poll")["bypass"] is True
            helper.state(op="bypass", on=False)
            assert fake.bypass is False

            # The bypass byte arrives with no line break: replies after it stay in step.
            fake.bypass = True
            state = helper.state(op="refresh")
            assert state["bypass"] is True and state["active"] == "Default"
            fake.bypass = False

            # Apps left out of the chain reach EasyEffects through the preset it loads; taking one back reloads it.
            loads = fake.loads
            state = helper.state(op="exclude", app="spotify", on=True)
            assert state["excluded"]["output"] == ["spotify"] and fake.blocklists["output"] == ["spotify"]
            assert fake.loads == loads + 1, "the chain is reloaded once"
            helper.state(op="exclude", app="spotify", on=True)
            assert fake.loads == loads + 1, "excluding twice changes nothing"
            state = helper.state(op="exclude", app="spotify", on=False)
            assert state["excluded"]["output"] == [] and fake.blocklists["output"] == []
            state = helper.state(op="exclude", app="discord", on=True, pipe="input")
            assert state["excluded"]["input"] == ["discord"] and fake.blocklists["input"] == ["discord"]
            assert helper.call(op="exclude", app="", on=True)[0]["message"] == "invalid_app"

            # A sound per app follows its preset's renames and goes with it.
            state = helper.state(op="rememberApp", app="discord", preset="Startup mine")
            assert state["apps"] == {"discord": "Startup mine"}
            state = helper.state(op="rename", **{"from": "Startup mine", "to": "Calls mine"})
            assert state["apps"] == {"discord": "Calls mine"}
            state = helper.state(op="delete", name="Calls mine")
            assert state["apps"] == {}
            state = helper.state(op="rememberApp", app="discord", preset="Voice")
            state = helper.state(op="forgetApp", app="discord")
            assert state["apps"] == {}

            # Two names that share a file name never write over each other.
            helper.state(op="save", name="Rock?")
            helper.state(op="save", name="Rock_ 1")
            state = helper.state(op="rename", **{"from": "Rock_ 1", "to": "Rock_"})
            assert {"Rock?", "Rock_"} <= set(state["presets"]), state["presets"]

            # A file that is ours in name only is refused, and the helper keeps answering.
            bad = root / "bad.json"
            bad.write_text(json.dumps({"name": "Bad", "core": ["not", "a", "dict"], "extras": "nope"}))
            assert helper.call(op="import", path=str(bad))[0]["message"] == "unknown_format"
            odd = root / "odd.json"
            odd.write_text(json.dumps({"name": "Odd", "core": {"limiter": {"enabled": True, "values": {"threshold": -3}}},
                                       "extras": [{"kind": "nope"}, 5]}))
            events = helper.call(op="import", path=str(odd))
            assert events[0]["name"] == "Odd" and "Odd" in events[-1]["presets"]

            # A quiet command that fails says so without standing for a loud one.
            events = helper.call(op="set", kind="limiter", prop="nope", value=1)
            assert events[0]["type"] == "error" and events[1].get("quiet") is True
            assert helper.state(op="refresh")["running"] is True
        finally:
            helper.close()
    print("audio engine: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
