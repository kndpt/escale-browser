#!/usr/bin/env python3
"""Exercise Chrome speech through a local extension, with native audio state.

A shared runner owns the unique bundle/world, deadlines and cleanup. Native
start/pause/completion observations distinguish actual playback from an API
promise merely resolving. No personal profile or store extension is used.
"""
from pathlib import Path
import json
import shutil
import tempfile
import suite as h

ROOT = Path(__file__).resolve().parents[2]
LONG = "This is a local speech regression. " * 150


def obj(*args):
    return json.loads(h.command(str(ROOT / "bench"), "--world", h.WORLD, "--json", *args, seconds=35))


def js(page, script):
    return obj("eval", page, script)["value"]


def call(page, method, *args, error=None):
    payload = ",".join(json.dumps(arg) for arg in args)
    js(page, "window.speechReply = null; Promise.resolve().then(() => "
       f"chrome.tts.{method}({payload}))"
       ".then(value => window.speechReply = {value: value ?? null}, "
       "error => window.speechReply = {error: String(error.message || error)}); 0")
    h.until(f"tts.{method} reply", lambda: js(page, "window.speechReply !== null"))
    reply = js(page, "window.speechReply")
    if error:
        assert error in reply.get("error", ""), reply
    else:
        assert "error" not in reply, reply
    return reply.get("value")


def state():
    return obj("extensions")["speech"]


def expect(label, **fields):
    return h.wait_for(label, state, fields, seconds=20)


def installed(name):
    return next((row for row in obj("extensions")["extensions"] if row["name"] == name), None)


def ready(page):
    """The page loaded and given the extension's API, which can follow the load."""
    return js(page, "document.readyState === 'complete' && typeof globalThis.chrome?.tts?.speak === 'function'")


def install(folder, name):
    obj("ext-folder", str(folder), "--yes")
    row = h.until(f"{name} loaded", lambda: (row if (row := installed(name)) and row["loaded"] else None), 30)
    h.require("extension errors", row["errors"], [])
    h.require("extension reported errors", row["reported"], [])
    page = obj("ext-page", row["id"], "page.html")["id"]
    h.until("extension page ready", lambda: ready(page))
    return row["id"], page


def main():
    with tempfile.TemporaryDirectory(prefix="escale-speech-") as temp, h.world(None):
        first_folder = Path(temp) / "first"
        second_folder = Path(temp) / "second"
        shutil.copytree(ROOT / "Tests/Bench/fixtures/speech-extension", first_folder)
        shutil.copytree(first_folder, second_folder)
        manifest = json.loads((second_folder / "manifest.json").read_text())
        manifest["name"] = "Escale second speech fixture"
        (second_folder / "manifest.json").write_text(json.dumps(manifest))
        h.launch()
        first, page = install(first_folder, "Escale speech fixture")
        second, other = install(second_folder, manifest["name"])
        expect("no audio on installation", active=False, speaking=False, queued=0)
        voices = call(page, "getVoices")
        assert voices, "no installed system voices"
        assert all(v["voiceName"] and v["lang"] and v["remote"] is False and v["eventTypes"] == ["start", "end"] for v in voices), voices
        voice = next((v for v in voices if v["lang"] == "en-US"), voices[0])
        expect("voice enumeration does not allocate audio", active=False)
        h.require("initial isSpeaking", call(page, "isSpeaking"), False)
        call(page, "speak", LONG, {"voiceName": voice["voiceName"], "rate": 0.5})
        reading = expect("native reading with selected voice", started=True, speaking=True, voiceName=voice["voiceName"])
        assert reading["rate"] < 0.5, reading
        h.require("reading isSpeaking", call(page, "isSpeaking"), True)
        call(page, "pause")
        expect("native pause", paused=True)
        h.require("paused isSpeaking", call(page, "isSpeaking"), True)
        call(page, "speak", "First queued phrase.", {"enqueue": True})
        call(page, "speak", "Second queued phrase.", {"enqueue": True})
        expect("enqueue preserves paused reading", paused=True, queued=2)
        call(page, "resume")
        expect("native resume", paused=False, speaking=True)
        call(other, "stop")
        expect("stop releases audio and queue", active=False, speaking=False, queued=0)
        h.require("stopped isSpeaking", call(page, "isSpeaking"), False)

        call(page, "speak", "Short phrase.", {"voiceName": voice["voiceName"]})
        expect("natural utterance starts", started=True)
        call(page, "speak", "The queued phrase.", {"enqueue": True, "rate": 1.5})
        expect("queued utterance really starts with its own rate", started=True, rate=0.75)
        expect("natural queue drains and audio is released", active=False, queued=0)

        call(page, "speak", LONG)
        expect("replacement source starts", started=True)
        call(page, "pause")
        expect("replacement source pauses", paused=True)
        call(page, "speak", LONG, {"rate": 1.5, "voiceName": "Escale nonexistent voice"})
        expect("replacement resumes with default voice", started=True, paused=False, queued=0, voiceName="", rate=0.75)
        call(page, "pause")
        expect("capacity setup pauses", paused=True)
        for _ in range(31):
            call(page, "speak", "Queued phrase.", {"enqueue": True})
        expect("queue has its declared bound", queued=31)
        call(page, "speak", "", {"enqueue": True})
        expect("empty enqueue at capacity is a no-op", paused=True, queued=31)
        call(page, "speak", "Overflow.", {"enqueue": True}, error="queue is full")
        call(page, "speak", "a" * 32769, error="exceeds")
        call(page, "speak", "Invalid rate.", {"rate": 0}, error="rate")
        expect("refusal preserves existing reading", paused=True, queued=31)
        call(page, "speak", "")
        expect("empty replacement releases full queue", active=False, queued=0)

        call(page, "speak", LONG)
        reading = expect("owner unload setup", started=True)
        obj("space", "new", "Speech parked")
        expect("Space switch preserves existing speech", started=True, speaking=True, scope=reading["scope"])
        obj("space", "go", "1")
        expect("Space return preserves existing speech", started=True, speaking=True, scope=reading["scope"])
        call(page, "pause")
        expect("owner unload paused", paused=True)
        call(other, "speak", LONG, {"enqueue": True})
        expect("another extension queued", queued=1)
        obj("ext-enable", second, "off")
        expect("queued owner's disable leaves current reading", paused=True, queued=0)
        obj("ext-enable", second, "on")
        h.until("second reload", lambda: installed(manifest["name"])["loaded"])
        other = obj("ext-page", second, "page.html")["id"]
        h.until("second page ready", lambda: ready(other))
        call(other, "speak", LONG, {"enqueue": True})
        obj("ext-enable", first, "off")
        remaining = expect("current owner's disable advances surviving queue", started=True, speaking=True, queued=0, paused=False)
        assert remaining["scope"].endswith("/" + second), remaining
        obj("ext-remove", second)
        expect("remove stops and releases audio", active=False, speaking=False, queued=0)

        obj("space", "new", "Speech deletion")
        third, third_page = install(first_folder, "Escale speech fixture")
        call(third_page, "speak", LONG)
        expect("Space deletion setup", started=True)
        obj("space", "delete")
        expect("Space deletion stops and releases audio", active=False, queued=0)
        # Orderly quit runs the production termination hook; restart has no
        # audio or pending speech even though the extension stays installed.
        obj("space", "go", "1")
        obj("ext-enable", first, "on")
        h.until("first reload", lambda: installed("Escale speech fixture")["loaded"])
        page = obj("ext-page", first, "page.html")["id"]
        h.until("quit page ready", lambda: ready(page))
        call(page, "speak", LONG)
        expect("quit setup starts", started=True)
        obj("press", "12", "q", "cmd")
        h.until("task app exits", lambda: not h.running())
        h.launch()
        expect("restart keeps no speech work", active=False, speaking=False, queued=0)
        print("PASS: voices/selection/rate, reading, pause/resume, queue/replacement/bounds, natural completion, disable/remove/Space deletion/quit")


if __name__ == "__main__":
    main()
