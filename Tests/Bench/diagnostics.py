"""Retain a failed probe's evidence before its world is wiped.

The pilot records only its synthetic world. Collection is best effort, bounded
to five seconds per observation, and cannot replace the original exception.
Commands keep their full output in numbered files, not in the agent's context.
"""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import traceback


def folder():
    value = os.environ.get("ESCALE_DIAGNOSTICS")
    if value:
        path = Path(value)
        path.mkdir(parents=True, exist_ok=True)
        return path
    return None


def record(command, output, error, code, duration):
    destination = folder()
    if destination is None:
        return
    number = len(list(destination.glob("command-*.json")))
    stem = destination / f"command-{number:05d}"
    stem.with_suffix(".stdout").write_text(output or "")
    stem.with_suffix(".stderr").write_text(error or "")
    stem.with_suffix(".json").write_text(json.dumps({"command": list(map(str, command)),
                                                   "exit": code, "duration": duration}, indent=2))


def launched(world, binary):
    """Keep the running path and the resigned executable's actual identity."""
    destination = folder()
    if destination is None:
        return
    processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True, timeout=5)
    owned = [line.strip() for line in processes.splitlines() if line.strip().split(None, 1)[-1] == binary]
    if not owned:
        raise AssertionError("launched test executable is not running from the owned world")
    number = len(list(destination.glob("launch-*.json")))
    (destination / f"launch-{number}.json").write_text(json.dumps({
        "world": world, "binary": binary, "processes": owned,
        "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        "source_bundle": os.environ.get("ESCALE_TEST_APP", "build/Escale.app")}, indent=2))


def capture(root, world, binary, error):
    destination = folder()
    if destination is None:
        return
    (destination / "failure.txt").write_text("".join(traceback.format_exception(type(error), error, error.__traceback__)))
    (destination / "identity.json").write_text(json.dumps({"world": world, "binary": binary,
                                                          "bundle": os.environ.get("ESCALE_TEST_APP")}, indent=2))
    for label, arguments in (("processes", ["ps", "-axo", "pid=,comm="]),
                              ("probe", [str(root / "bench"), "--world", world, "--json", "probe"]),
                              ("tabs", [str(root / "bench"), "--world", world, "--json", "tabs"]),
                              ("picture", [str(root / "bench"), "--world", world, "picture", str(destination / "failure.png")])):
        try:
            result = subprocess.run(arguments, cwd=root, capture_output=True, text=True, timeout=5)
            output = result.stdout
            if label == "processes":
                output = "\n".join(line for line in output.splitlines() if binary in line)
            (destination / (label + ".txt")).write_text(output + result.stderr)
            if label == "probe" and result.returncode == 0:
                state = json.loads(output)
                window = next((w for w in state.get("windows", [])
                               if w.get("visible") and w.get("kind") == "AppKitWindow"), None)
                if window:
                    captured = subprocess.run(["screencapture", "-x", "-o", "-l", str(window["number"]),
                                               str(destination / "window.png")],
                                              capture_output=True, text=True, timeout=5)
                    (destination / "window.txt").write_text(captured.stdout + captured.stderr)
        except (OSError, ValueError, subprocess.TimeoutExpired) as failure:
            (destination / (label + ".txt")).write_text(str(failure))
