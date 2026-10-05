#!/usr/bin/env python3
"""Measure bounded sleeping-tab imports, including Zen's pinned folder mapping.

Run on a release bundle without compilers or other benches. Every source is
synthetic, every app is a unique disposable world. Memory brackets the same
world's explicit import and dismissal, including attributed WebKit helpers.
Socket latency is responsiveness evidence, never paint time or energy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import tempfile
import time
import uuid

from migration_browsers import moz, tab, FIREFOX
from migration_resources import r, usage


def trial(brand, count):
    with tempfile.TemporaryDirectory(prefix="escale-session-perf-") as folder:
        root = Path(folder)
        tabs = [tab(f"https://session.invalid/{i}", pinned=i % 2 == 0,
                    zenSyncId=str(i), zenWorkspace="work", groupId="folder") for i in range(count)]
        if brand == "Zen":
            value = {"lastCollected": 1, "spaces": [{"uuid": "work", "name": "Work"}],
                     "folders": [{"id": "folder", "name": "Project", "workspaceId": "work"}], "tabs": tabs}
            file = "zen-sessions.jsonlz4"
        else:
            value = {"version": ["sessionrestore", 1], "windows": [{"tabs": tabs}]}
            file = "sessionstore.jsonlz4"
        data = moz(value)
        (root / file).write_bytes(data)
        r.setup("mig-sess-" + uuid.uuid4().hex[:10])
        try:
            launched = r.launch()
            candidates = set(launched["created_webkit_pids"])
            pages = r.ask("space")["pages"]
            result = {"brand": brand, "count": count, "source_bytes": len(data), "launch": launched}
            r.ask("migration", action="open")
            r.ask("migration", action="choose", path=str(root), browser=brand, folder=True)
            r.until("discovery", lambda: not r.ask("migration")["discovering"], 15)
            result["before"] = r.sample_memory(candidates)
            cpu = usage(r.app_pid())["cpu"]
            started = time.monotonic()
            latencies = []
            for category in (["bookmarks", "tabs"] if brand == "Zen" else ["tabs"]):
                r.ask("migration", action="step", category=category)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    before = time.monotonic()
                    state = r.ask("migration", timeout=10)
                    latencies.append(1000 * (time.monotonic() - before))
                    if state["phase"] == "stopped":
                        raise RuntimeError(state["message"])
                    if state["phase"] == "finished":
                        break
                    time.sleep(0.01)
                else:
                    raise RuntimeError("import timeout")
            result["seconds"] = time.monotonic() - started
            result["app_cpu_seconds"] = usage(r.app_pid())["cpu"] - cpu
            result["socket_reply_ms"] = latencies
            r.check("tab count", state["addedTabs"], count)
            r.check("no pages created", r.ask("space")["pages"], pages)
            r.check("source unchanged", hashlib.sha256((root / file).read_bytes()).digest(), hashlib.sha256(data).digest())
            result["after"] = r.sample_memory(candidates)
            r.ask("ui", settings=False)
            time.sleep(3)
            result["dismissed"] = r.sample_memory(candidates)
            result["remaining_snapshots"] = len(list((r.SOCKET.parent / "migration-snapshots").glob("**/*")))
            return result
        finally:
            r.cleanup()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    results = {"date": "2026-10-02", "base_commit": r.run("git", "rev-parse", "HEAD").strip(),
               "os": platform.platform(), "machine": r.run("sysctl", "-n", "hw.model").strip(),
               "build": "release; browser-migrations working tree; ESCALE_MEASURE=1; no imported URL loaded",
               "workload": "Firefox saved tabs; Zen pinned bookmarks plus saved tabs; 100/2000 tabs, half pinned; three trials each",
               "trials": []}
    for brand in [FIREFOX, "Zen"]:
        for count in [100, 2000]:
            for index in range(3):
                results["trials"].append(trial(brand, count))
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_text(json.dumps(results, indent=2) + "\n")
                print(brand, count, index + 1, "saved", flush=True)


if __name__ == "__main__":
    main()
