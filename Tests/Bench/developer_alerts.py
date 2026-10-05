#!/usr/bin/env python3
"""Only enabled local development events reach the macOS notification bridge.

Run after ./build.sh debug. This owns one isolated world. It checks socket
lifetime, acknowledgement, category filtering and bounded input. The app's
posted counter means macOS accepted a request, not that a banner was seen.
"""

from pathlib import Path
import json
import os
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
WORLD = "developer-alerts"
SOCKET = Path.home() / "Library/Application Support" / f"Escale ({WORLD})" / "alerts.sock"


def run(*args, env=None, expected=0):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                            text=True, timeout=40)
    if result.returncode != expected:
        raise AssertionError(f"{args}: exit {result.returncode}, expected {expected}: {result.stdout} {result.stderr}")
    return result.stdout


def bench(*args):
    return json.loads(run(str(ROOT / "bench"), "--world", WORLD, "--json", *args))


def until(label, predicate):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.15)
    raise AssertionError(f"timed out: {label}")


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run("./fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        assert not SOCKET.exists() and not bench("alerts")["running"] and not bench("alerts")["delegate"]
        bench("ui", "alerts", "on")
        until("socket opened", SOCKET.exists)
        assert bench("alerts")["delegate"], "local alerts did not take their foreground delegate"
        assert run("./notify", "--world", WORLD, "agent", "Agent finished", "Tests passed").strip() == "sent"
        until("macOS request posted", lambda: bench("alerts")["posted"] >= 1)
        assert run("./notify", "--world", WORLD, "agent", 'Agent "ready"', "Line 1\nLine 2").strip() == "sent"
        until("quoted event posted", lambda: bench("alerts")["posted"] >= 2)
        bench("ui", "alertBuilds", "off")
        failed = subprocess.run([str(ROOT / "notify"), "--world", WORLD,
                                 "build", "Build passed"], cwd=ROOT,
                                capture_output=True, text=True, timeout=5)
        assert failed.returncode == 1 and "disabled" in failed.stderr, failed
        assert bench("alerts")["filtered"] == 1
        long = subprocess.run([str(ROOT / "notify"), "--world", WORLD,
                               "agent", "a" * 101], cwd=ROOT,
                              capture_output=True, text=True, timeout=5)
        assert long.returncode == 1 and "invalid event" in long.stderr, long
        bench("ui", "alerts", "off")
        until("socket closed", lambda: not SOCKET.exists())
        assert not bench("alerts")["running"] and not bench("alerts")["delegate"]
        print("developer alerts: event posted, filtering, socket and delegate released when off")
    finally:
        run("./fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
