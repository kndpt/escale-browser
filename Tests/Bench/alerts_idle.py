#!/usr/bin/env python3
"""Compare 120-second blank-window idle with developer alerts off and on.

Run after ./build.sh debug, without another benchmark or compiler running.
The same isolated app and static blank tab are used in both phases. Bench
traffic occurs only between intervals. The result is diagnostic; repeat it
under the full PERFORMANCE protocol before making a product energy claim.
"""

from pathlib import Path
import ctypes
import json
import os
import subprocess
import time

import resource_baseline as resources


ROOT = Path(__file__).resolve().parents[2]
WORLD = "alerts-idle"
resources.WORLD = WORLD


def run(*args, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                            text=True, timeout=45)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout


def bench(*args):
    return json.loads(run(str(ROOT / "bench"), "--world", WORLD, "--json", *args))


def counters(pid):
    usage = resources.Usage()
    if resources.LIBPROC.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        raise OSError(ctypes.get_errno(), "proc_pid_rusage")
    return {"cpu_seconds": (usage.user + usage.system) / 1_000_000_000,
            "interrupt_wakeups": usage.interrupt_wakeups,
            "package_idle_wakeups": usage.package_idle_wakeups}


def phase(name, pid):
    time.sleep(5)
    before = counters(pid)
    print(f"{name}: starting 120-second idle interval", flush=True)
    time.sleep(120)
    after = counters(pid)
    footprint = resources.footprint(pid)
    result = {"name": name, "seconds": 120,
              "cpu_seconds": round(after["cpu_seconds"] - before["cpu_seconds"], 4),
              "interrupt_wakeups": after["interrupt_wakeups"] - before["interrupt_wakeups"],
              "package_idle_wakeups": after["package_idle_wakeups"] - before["package_idle_wakeups"],
              "app_footprint_mib": footprint["mib"]}
    print(json.dumps(result), flush=True)
    return result


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    env = dict(os.environ, ESCALE_PROBE=WORLD, ESCALE_MEASURE="1")
    try:
        run("./fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        pid = resources.app_pid()
        off = phase("off", pid)
        bench("ui", "alerts", "on")
        assert bench("alerts")["running"]
        on = phase("on", pid)
        bench("ui", "alerts", "off")
        assert not bench("alerts")["running"]
        print(json.dumps({"off": off, "on": on, "delta_cpu_seconds": round(on["cpu_seconds"] - off["cpu_seconds"], 4),
                          "delta_interrupt_wakeups": on["interrupt_wakeups"] - off["interrupt_wakeups"],
                          "delta_footprint_mib": round(on["app_footprint_mib"] - off["app_footprint_mib"], 3)}), flush=True)
    finally:
        run("./fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
