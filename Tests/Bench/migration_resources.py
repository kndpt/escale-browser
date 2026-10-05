#!/usr/bin/env python3
"""Measure explicit imports and their settled idle in disposable probe worlds.

After a release build, run without compilers or other benchmark traffic. Three
small/large trials keep raw socket responsiveness and physical footprints;
these are not input-to-display timings or energy measurements. One large trial
brackets import with 120 s idle intervals without bench polling. SQLite scratch
sampling is a lower bound on transient disk use, not a claimed peak guarantee.
"""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import platform
import sqlite3
import tempfile
import time
import uuid

import resource_baseline as r

# This host's Swift uptime marker and Python monotonic epoch differ after
# sleep. Keep launch/socket observations, but never turn that into paint time.
r.marker_ms = lambda *args: None


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


TIMEBASE = Timebase()
if ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(TIMEBASE)) != 0 or not TIMEBASE.denom:
    raise RuntimeError("could not obtain Mach timebase")


def usage(pid):
    value = r.Usage()
    if r.LIBPROC.proc_pid_rusage(pid, 0, ctypes.byref(value)):
        raise RuntimeError(f"rusage failed for {pid}")
    return {"cpu_ticks": value.user + value.system,
            "cpu": (value.user + value.system) * TIMEBASE.numer / TIMEBASE.denom / 1e9, "physical_mib": value.physical / 1048576,
            "interrupt": value.interrupt_wakeups, "package_idle": value.package_idle_wakeups}


def quiet(memory):
    pids = [memory["app_pid"], *map(int, memory["helpers"])]
    before = {str(pid): usage(pid) for pid in pids}
    start = time.monotonic()
    time.sleep(120)
    seconds = time.monotonic() - start
    after = {str(pid): usage(pid) for pid in pids}
    return {"seconds": seconds, "before": before, "after": after,
            "cpu_percent_one_core": 100 * sum(after[p]["cpu"] - before[p]["cpu"] for p in before) / seconds}


def trial(count, idle):
    world = "mig-perf-" + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix="escale-migration-perf-") as folder:
        profile = Path(folder)
        nodes = [{"type": "url", "guid": str(i), "name": f"Synthetic {i}", "url": f"https://migration.invalid/{i}"} for i in range(count)]
        data = json.dumps({"version": 1, "roots": {"bookmark_bar": {"type": "folder", "guid": "root", "name": "Synthetic", "children": nodes}}}).encode()
        (profile / "Bookmarks").write_bytes(data)
        visits = min(count, 2000)
        with sqlite3.connect(profile / "History") as db:
            db.execute("CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,hidden INTEGER)")
            db.executemany("INSERT INTO urls VALUES (?,?,?,?,?)", [
                (f"https://migration.invalid/history/{i}", f"History {i}", 7, 13434292800000000 - i * 1000000, 0)
                for i in range(visits)])
        r.setup(world)
        try:
            launched = r.launch()
            candidates = set(launched["created_webkit_pids"])
            result = {"bookmarks": count + 1, "history": visits, "source_bytes": len(data) + (profile / "History").stat().st_size, "launch": launched}
            if idle:
                result["idle_before"] = quiet(launched["memory"])
                print("idle before collected", flush=True)
            r.ask("migration", action="open")
            r.ask("migration", action="choose", path=str(profile), browser="Chrome", folder=True)
            r.until("discovery", lambda: not r.ask("migration")["discovering"], 15)
            r.ask("migration", action="categories", categories=["bookmarks", "history"])
            start_cpu = usage(r.app_pid())["cpu"]
            started = time.monotonic()
            r.ask("migration", action="preview")
            latencies = []
            scratch_samples = []
            def wait_phase(expected):
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    before = time.monotonic()
                    state = r.ask("migration", timeout=10)
                    latencies.append((time.monotonic() - before) * 1000)
                    scratch = 0
                    for path in (r.SOCKET.parent / "migration-snapshots").glob("**/*"):
                        try:
                            if path.is_file(): scratch += path.stat().st_size
                        except FileNotFoundError:
                            pass
                    scratch_samples.append(scratch)
                    if state["phase"] == "stopped":
                        raise RuntimeError(state["message"])
                    if state["phase"] == expected:
                        return state
                    time.sleep(0.01)
                raise RuntimeError(f"timed out waiting for {expected}")
            preview = wait_phase("preview")
            result["preview_seconds"] = time.monotonic() - started
            r.check("preview count", preview["previewBookmarks"], count + 1)
            apply_start = time.monotonic()
            r.ask("migration", action="confirm")
            done = wait_phase("finished")
            result["apply_seconds"] = time.monotonic() - apply_start
            result["app_cpu_seconds"] = usage(r.app_pid())["cpu"] - start_cpu
            result["socket_reply_ms"] = latencies
            result["scratch_bytes_samples"] = scratch_samples
            r.check("added", done["addedBookmarks"], count + 1)
            r.check("source unchanged", hashlib.sha256((profile / "Bookmarks").read_bytes()).digest(), hashlib.sha256(data).digest())
            result["after_import"] = r.sample_memory(candidates)
            r.ask("ui", settings=False)
            time.sleep(3)
            result["dismissed"] = r.sample_memory(candidates)
            result["remaining_snapshot_files"] = len(list((r.SOCKET.parent / "migration-snapshots").glob("**/*")))
            if idle:
                result["idle_after"] = quiet(result["dismissed"])
                result["settled"] = r.sample_memory(candidates)
                print("idle after collected", flush=True)
            return result
        finally:
            r.cleanup()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--idle-only", action="store_true")
    args = parser.parse_args()
    result = {"timebase": {"numer": TIMEBASE.numer, "denom": TIMEBASE.denom},
              "commit": r.run("git", "rev-parse", "HEAD").strip(),
              "os": platform.platform(), "machine": r.run("sysctl", "-n", "hw.model").strip(),
              "build": "release; test copies ad-hoc signed by fresh.sh; ESCALE_MEASURE=1",
              "workload": "49,999 URLs plus one folder / 2,000 history entries, one idle trial" if args.idle_only else "100 and 49,999 URLs plus one folder, 100/2,000 history entries; three trials each; no URL opened",
              "small": [], "large": []}
    workloads = [("large", 49999)] if args.idle_only else [("small", 100), ("large", 49999)]
    for key, count in workloads:
        for index in range(1 if args.idle_only else 3):
            result[key].append(trial(count, idle=args.idle_only))
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(result, indent=2) + "\n")
            print(key, index + 1, "saved", flush=True)


if __name__ == "__main__":
    main()
