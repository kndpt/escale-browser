#!/usr/bin/env python3
"""Collect repeatable, local resource samples from an isolated Escale build.

Usage: python3 Tests/Bench/resource_baseline.py --label before
Run from the checkout whose *release* build is being measured. Never run a
compiler or another benchmark during this script. This uses physical footprint
per process and samples CPU time across a 120 s interval. WebKit helpers have
PPID 1 on macOS, so attribution uses the probe world's open files plus the
helpers born during launch; temporal-only GPU attribution stays labelled as
inferred. Kernel per-process wakeup counters bracket idle; they are not an
energy measurement. In measurement mode the app exposes the successful first
focus of its empty-tab field and the existing WebKit first-content reveal;
both use system uptime, the same monotonic clock as this collector.
"""

from argparse import ArgumentParser
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ctypes
import hashlib
import json
import os
import plistlib
import re
import socket
import statistics
import subprocess
import tempfile
import threading
import time

from resource_archive import sample_name, save_sample

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "build/Escale.app"
WORLD = ""
SOCKET = None
SERVER = None
SUN_PATH_ROOM = 104


class Usage(ctypes.Structure):
    # RUSAGE_INFO_V0 from the bundled macOS SDK's sys/resource.h.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "package_idle_wakeups", "interrupt_wakeups",
            "pageins", "wired", "resident", "physical", "start", "exit")]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
LIBPROC.proc_pid_rusage.restype = ctypes.c_int


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/dynamic"):
            body = ("<title>Resource fixture</title><main><h1>Resource fixture</h1>"
                    "<p id='moving'>Dynamic</p></main><script>"
                    "let n=0; setInterval(()=>{document.querySelector('#moving').textContent="
                    "String(++n)},50)</script>").encode()
        else:
            body = ("<title>Resource fixture</title><main><h1>Resource fixture</h1>"
                    "<p>Local static page, no scripts or external assets.</p></main>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(*args, timeout=60, check=True):
    env = dict(os.environ, ESCALE_PROBE=WORLD, ESCALE_MEASURE="1")
    result = subprocess.run([str(a) for a in args], cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}: {result.returncode}: "
                           f"{result.stderr.strip()} {result.stdout.strip()}")
    return result.stdout


def ask(verb, timeout=30, **fields):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(str(SOCKET))
        connection.sendall((json.dumps({"do": verb, **fields}) + "\n").encode())
        chunks = []
        while part := connection.recv(65536):
            chunks.append(part)
    raw = b"".join(chunks).split(b"\n", 1)[0]
    reply = json.loads(raw)
    if "error" in reply:
        raise RuntimeError(f"{verb}: {reply['error']}")
    return reply


def until(what, condition, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if condition():
                return
        except (OSError, ValueError, RuntimeError, KeyError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"{what}: timeout after {seconds}s")


def all_processes():
    rows = run("ps", "-axo", "pid=,comm=", timeout=10)
    processes = {}
    for line in rows.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            processes[int(parts[0])] = parts[1]
    return processes


def webkit_processes():
    return {pid: name for pid, name in all_processes().items()
            if "/com.apple.WebKit." in name}


def app_pid():
    binary = str((ROOT / "build/probe" / WORLD /
                  "Escale.app/Contents/MacOS/Escale").resolve())
    found = [pid for pid, name in all_processes().items() if name == binary]
    if len(found) != 1:
        raise RuntimeError(f"expected one probe process at {binary}, found {found}")
    return found[0]


def footprint(pid):
    output = run("footprint", "-p", str(pid), timeout=20)
    match = re.search(r"Footprint:\s*([\d.]+)\s*([KMG]B)", output)
    peak = re.search(r"phys_footprint_peak:\s*([\d.]+)\s*([KMG]B)", output)
    if not match:
        raise RuntimeError(f"footprint output not understood for {pid}: {output[:160]}")

    def mib(value, unit):
        return round(float(value) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[unit], 3)

    return {"mib": mib(*match.groups()),
            "peak_mib": mib(*peak.groups()) if peak else None}


def cpu_seconds(pid):
    value = run("ps", "-p", str(pid), "-o", "time=", timeout=10).strip()
    if not value:
        raise RuntimeError(f"process {pid} disappeared")
    parts = value.split(":")
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(parts)))


def wakeups(pid):
    usage = Usage()
    if LIBPROC.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        errno = ctypes.get_errno()
        raise OSError(errno, f"proc_pid_rusage failed for {pid}")
    return {"package_idle": usage.package_idle_wakeups,
            "interrupt": usage.interrupt_wakeups}


def counters(pid):
    """CPU seconds and wakeups, or None once the process has exited: WebKit
    lets an idle helper go, and a hidden window gives back its GPU work."""
    try:
        return cpu_seconds(pid), wakeups(pid)
    except (RuntimeError, OSError):
        return None


def owned_files(pid):
    output = run("lsof", "-p", str(pid), "-Fn", timeout=15, check=False)
    return f"com.kndpt.escale.probe.{WORLD}" in output


def sample_memory(created):
    app = app_pid()
    helpers = webkit_processes()
    world_helpers = {}
    for pid, name in helpers.items():
        file_owned = owned_files(pid)
        if pid not in created and not file_owned:
            continue
        basis = "open-file" if file_owned else "launch-cohort"
        world_helpers[str(pid)] = {"kind": name.rsplit("/", 1)[-1],
                                   "basis": basis, **footprint(pid)}
    browser = footprint(app)
    return {"app_pid": app, "browser": browser, "helpers": world_helpers,
            "observed_aggregate_mib": round(browser["mib"] + sum(
                item["mib"] for item in world_helpers.values()), 3)}


def probe_socket(world):
    path = Path.home() / "Library/Application Support" / f"Escale ({world})" / "bench.sock"
    if len(os.fsencode(path)) >= SUN_PATH_ROOM:
        raise ValueError(f"probe world makes a socket path too long for macOS "
                         f"({len(os.fsencode(path))} bytes; limit {SUN_PATH_ROOM - 1})")
    return path


def setup(world, session=None, history=None, spaces=None, extra_sessions=None, settings=None):
    global WORLD, SOCKET
    WORLD = world
    # Reject an unusable world before wipe/defaults writes or a 60 s socket wait.
    SOCKET = probe_socket(WORLD)
    run(ROOT / "fresh.sh", "wipe")
    suite = f"com.kndpt.escale.test.{WORLD}"
    run("defaults", "write", suite, "bench", "-bool", "YES")
    run("defaults", "write", suite, "welcomed", "-bool", "YES")
    checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime(
        "%Y-%m-%d %H:%M:%S +0000")
    run("defaults", "write", suite, "update.checked", "-date", checked)
    for key, value in (settings or {}).items():
        run("defaults", "write", suite, key, "-bool", "YES" if value else "NO")
    folder = SOCKET.parent
    folder.mkdir(parents=True, exist_ok=True)
    if session is not None:
        (folder / "session.json").write_text(json.dumps(session))
    if history is not None:
        (folder / "history.json").write_text(json.dumps(history))
    if spaces is not None:
        (folder / "spaces.json").write_text(json.dumps(spaces))
    for name, shape in (extra_sessions or {}).items():
        (folder / name).write_text(json.dumps(shape))


def launch(fixture_url=None):
    before = set(webkit_processes())
    env = dict(os.environ, ESCALE_PROBE=WORLD, ESCALE_MEASURE="1")
    started = time.monotonic()
    process = subprocess.Popen([str(ROOT / "fresh.sh"), "again"], cwd=ROOT,
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True)
    try:
        until("probe process visible", lambda: app_pid() > 0, 60)
        visible = time.monotonic()
        until("socket ready", lambda: isinstance(ask("tabs", timeout=2).get("tabs"), list), 60)
        ready = time.monotonic()
        ready_ms = round((ready - started) * 1000, 2)
        markers = {}
        if fixture_url is None:
            until("usable address field",
                  lambda: ask("probe").get("fieldFocused") is True
                  and isinstance(ask("probe").get("fieldUsableAt"), (int, float)), 15)
            field_at = ask("probe")["fieldUsableAt"]
            markers["field_usable_ms"] = marker_ms("field usable", field_at, started)
        if fixture_url is not None:
            until("selected fixture", lambda: any(row["active"] for row in ask("tabs")["tabs"]), 15)
            selected = next(row for row in ask("tabs")["tabs"] if row["active"])
            loaded_fixture(selected["id"], fixture_url)
            selected = next(row for row in ask("tabs")["tabs"] if row["id"] == selected["id"])
            markers["first_page_reveal_ms"] = marker_ms(
                "first page reveal", selected.get("firstVisibleAt"), started)
            markers["first_page_reveal_source"] = selected.get("firstVisibleSource", "missing")
        output, error = process.communicate(timeout=30)
        if process.returncode:
            raise RuntimeError(f"fresh.sh: {error} {output}")
        time.sleep(2)
        created = set(webkit_processes()) - before
        return {"socket_ready_ms": ready_ms,
                "process_visible_to_socket_ms": round((ready - visible) * 1000, 2),
                "created_webkit_pids": sorted(created),
                "memory": sample_memory(created), **markers}
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


def cleanup():
    if WORLD:
        run(ROOT / "fresh.sh", "wipe", timeout=60)


def marker_ms(name, marker, started):
    if not isinstance(marker, (int, float)):
        raise RuntimeError(f"{name}: the application did not expose a timestamp")
    elapsed = (marker - started) * 1000
    upper = (time.monotonic() - started) * 1000 + 1000
    if elapsed < 0 or elapsed > upper:
        raise RuntimeError(f"{name}: incompatible monotonic timestamps ({elapsed:.2f} ms)")
    return round(elapsed, 2)


def session(count, base):
    return {"tabs": [{"url": f"{base}/tab-{i}", "title": f"Tab {i}"}
                     for i in range(count)], "active": 0}


def history(count):
    now = time.time() - 978307200
    return [{"url": f"https://project{i:05d}.example.test/",
             "key": f"project{i:05d}.example.test", "title": f"Project {i}",
             "count": 1 + i % 9, "last": now - 60 * i} for i in range(count)]


def check(name, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{name}: expected {expected!r}, got {actual!r}")


def loaded_fixture(ident, expected_url):
    until(f"fixture {ident} loaded",
          lambda: (not next(tab for tab in ask("tabs")["tabs"]
                            if tab["id"] == ident)["loading"]
                   and "Resource fixture" in ask("text", id=ident).get("text", "")), 15)
    loaded = ask("wait", timeout=25, id=ident, seconds=15)
    check(f"fixture {ident} loading", loaded.get("loading"), False)
    check(f"fixture {ident} failure", loaded.get("failure"), None)
    check(f"fixture {ident} address", loaded["url"], expected_url)
    return loaded


def launches(label, count):
    results = []
    for i in range(count):
        setup(f"resource-{label}-launch-{i}")
        try:
            results.append(launch())
            check("empty session", len(ask("tabs")["tabs"]), 1)
        finally:
            cleanup()
        print(f"launch {i + 1}/{count}: {results[-1]['socket_ready_ms']} ms", flush=True)
    return results


def first_display(label, count, base):
    results = []
    for i in range(count):
        setup(f"resource-{label}-display-{i}", session=session(1, base))
        try:
            result = launch(f"{base}/tab-0")
            check(f"display {i + 1} marker", result["first_page_reveal_source"],
                  "rendering-progress")
            results.append(result)
        finally:
            cleanup()
        print(f"display {i + 1}/{count}: {result['first_page_reveal_ms']} ms", flush=True)
    return results


def idle_trials(label, base, seconds, count, background):
    trials = []
    for i in range(count):
        trial = idle(label, base, seconds, background=background)
        trials.append(trial)
        kind = "background" if background else "visible"
        print(f"{kind} idle {i + 1}/{count}: "
              f"{trial['cpu_percent_one_core']:.3f}% CPU, "
              f"{trial['wakeups_total']['package_idle']} package-idle / "
              f"{trial['wakeups_total']['interrupt']} interrupt wakeups", flush=True)
    return trials


def restored(label, count, base):
    setup(f"resource-{label}-tabs-{count}", session=session(count, base))
    try:
        result = launch(f"{base}/tab-0")
        until("restored tabs", lambda: len(ask("tabs")["tabs"]) == count, 15)
        result["tabs"] = len(ask("tabs")["tabs"])
        result["views"] = len(ask("space")["pages"])
        check("lazy page count", result["views"], 1)
        return result
    finally:
        cleanup()


def typing(label, count, base):
    setup(f"resource-{label}-history-{count}",
          session=session(1, base), history=history(count))
    try:
        result = launch(f"{base}/tab-0")
        timings = []
        for i in range(20):
            reply = ask("field", timeout=90, text="proje", type=True)
            pairs = reply.get("ms", [])
            check(f"typing trial {i} key count", len(pairs), 5)
            timings.extend(pair[1] for pair in pairs)
        result["typing_rest_ms"] = timings
        result["history_entries"] = count
        return result
    finally:
        cleanup()


def idle(label, base, seconds, background=False):
    # Keep the Application Support socket path below macOS's 104-byte limit.
    name = "bg" if background else "idle"
    setup(f"resource-{label}-{name}", session=session(1, base))
    try:
        result = launch(f"{base}/tab-0")
        if background:
            ask("pages", on=False)
            result["visible_windows"] = [window for window in ask("probe")["windows"]
                                         if window["kind"] == "AppKitWindow" and window["visible"]]
            check("background app windows", result["visible_windows"], [])
            time.sleep(2)
        pid = result["memory"]["app_pid"]
        helpers = [int(key) for key in result["memory"]["helpers"]]
        pids = [pid] + helpers
        before = {str(pid): counters(pid) for pid in pids}
        # No bench traffic, footprint or ps polling during the timed interval.
        time.sleep(seconds)
        after = {str(pid): counters(pid) for pid in pids}
        alive = [key for key in before if before[key] and after[key]]
        if str(pid) not in alive:
            raise RuntimeError(f"the browser process {pid} exited during the idle interval")
        # What an exited helper spent before it went is not known: it is
        # listed, not counted.
        result["exited_pids"] = sorted(set(before) - set(alive))
        result["idle_seconds"] = seconds
        result["cpu_seconds_by_pid"] = {key: round(after[key][0] - before[key][0], 3) for key in alive}
        result["cpu_percent_one_core"] = round(100 * sum(result["cpu_seconds_by_pid"].values()) / seconds, 3)
        result["wakeups_by_pid"] = {key: {name: after[key][1][name] - before[key][1][name]
                                         for name in ["package_idle", "interrupt"]}
                                    for key in alive}
        result["wakeups_total"] = {name: sum(value[name] for value in result["wakeups_by_pid"].values())
                                   for name in ["package_idle", "interrupt"]}
        result["after_memory"] = sample_memory(set(result["created_webkit_pids"]))
        return result
    finally:
        cleanup()


def three_spaces(label, base):
    first = "00000000-0000-0000-0000-000000000001"
    second = "00000000-0000-0000-0000-000000000002"
    third = "00000000-0000-0000-0000-000000000003"
    spaces = [{"id": ident, "name": name, "colour": index,
               "sharesSignIns": False} for index, (ident, name) in enumerate(
                   [(first, "Docs"), (second, "Local"), (third, "Reviews")])]
    setup(f"resource-{label}-spaces", session=session(7, base), spaces=spaces,
          extra_sessions={f"session-{second}.json": session(7, base),
                          f"session-{third}.json": session(6, base)})
    try:
        result = {"launch": launch(f"{base}/tab-0"), "switches": []}
        check("space count", len(ask("space")["spaces"]), 3)
        for index in [2, 3, 1]:
            start = time.monotonic()
            state = ask("space", timeout=30, action="go", index=index)
            elapsed = round((time.monotonic() - start) * 1000, 2)
            check(f"space {index} tab count", state["tabs"], [7, 7, 6][index - 1])
            selected = next(row for row in ask("tabs")["tabs"] if row["active"])
            loaded_fixture(selected["id"], f"{base}/tab-0")
            time.sleep(2)
            result["switches"].append({"index": index, "socket_reply_ms": elapsed,
                                        "pages": len(state["pages"]),
                                        "memory": sample_memory(set(result["launch"]["created_webkit_pids"]))})
        return result
    finally:
        cleanup()


def churn(label, base, cycles):
    setup(f"resource-{label}-churn", session=session(1, base))
    try:
        result = {"launch": launch(f"{base}/tab-0"), "blocks": []}
        baseline_tabs = len(ask("tabs")["tabs"])
        check("churn initial tabs", baseline_tabs, 1)
        for block in range(3):
            started = time.monotonic()
            for i in range(cycles):
                # New Tab opens the field first and makes the tab as the page
                # starts, so the page lands in a second tab, not the first.
                ask("bookmark", timeout=30, url=f"{base}/churn-{block}-{i}", new=True)
                check(f"churn {block}:{i} tab count", len(ask("tabs")["tabs"]), 2)
                ask("press", timeout=15, code=13, chars="w", mods=["cmd"])
                # Old Bench.press leaves Command in NSApp.currentEvent. Clear it
                # before the next bookmark so both revisions run the same cycle.
                ask("press", timeout=15, code=53, chars="\u001b")
                until("closed churn tab", lambda: len(ask("tabs")["tabs"]) == 1, 8)
            time.sleep(2)
            result["blocks"].append({"cycles": cycles,
                                     "elapsed_seconds": round(time.monotonic() - started, 2),
                                     "memory": sample_memory(set(result["launch"]["created_webkit_pids"]))})
            print(f"churn block {block + 1}/3: {cycles} cycles", flush=True)
        return result
    finally:
        cleanup()


def sleep_pages(label, base):
    setup(f"resource-{label}-sleep", session=session(20, base))
    try:
        result = {"launch": launch(f"{base}/tab-0"), "sleep_results": []}
        rows = ask("tabs")["tabs"]
        check("sleep tab count", len(rows), 20)
        previous = None
        for row in rows:
            ident = row["id"]
            ask("select", id=ident)
            until(f"loaded page {ident}",
                  lambda: (not next(tab for tab in ask("tabs")["tabs"]
                                    if tab["id"] == ident)["loading"]
                           and "Resource fixture" in ask("text", id=ident).get("text", "")), 15)
            loaded = ask("wait", timeout=25, id=ident, seconds=15)
            check(f"loaded page {ident}", loaded.get("timeout", False), False)
            check(f"loaded page {ident} loading", loaded.get("loading"), False)
            check(f"loaded page {ident} failure", loaded.get("failure"), None)
            if previous:
                result["sleep_results"].append(ask("sleep", timeout=30, id=previous))
            previous = ident
        result["sleep_memory"] = sample_memory(set(result["launch"]["created_webkit_pids"]))
        result["asleep"] = sum(tab["asleep"] for tab in ask("tabs")["tabs"])
        check("eligible tabs asleep", result["asleep"], 19)
        ask("select", id=rows[0]["id"])
        until("first page awake", lambda: not next(t for t in ask("tabs")["tabs"]
              if t["id"] == rows[0]["id"])["asleep"], 15)
        result["wake_memory"] = sample_memory(set(result["launch"]["created_webkit_pids"]))
        return result
    finally:
        cleanup()


def features(label, base, seconds):
    result = {}
    for active in [False, True]:
        name = "on" if active else "off"
        settings = {"passwords.save": active, "passwords.fill": active,
                    "tabs.reading": active}
        setup(f"resource-{label}-features-{name}",
              session=session(1, f"{base}/dynamic"), settings=settings)
        try:
            trial = launch(f"{base}/dynamic/tab-0")
            page = ask("tabs")["tabs"][0]
            until("dynamic fixture loaded",
                  lambda: (not next(tab for tab in ask("tabs")["tabs"]
                                    if tab["id"] == page["id"])["loading"]
                           and ask("eval", id=page["id"],
                                   js="document.querySelector('#moving') !== null")
                           .get("value") is True), 15)
            loaded = ask("wait", timeout=25, id=page["id"], seconds=15)
            check("dynamic page loading", loaded.get("loading"), False)
            check("dynamic page failure", loaded.get("failure"), None)
            check("dynamic page address", page["url"], f"{base}/dynamic/tab-0")
            pids = [trial["memory"]["app_pid"]] + [int(p) for p in trial["memory"]["helpers"]]
            before = {str(pid): counters(pid) for pid in pids}
            time.sleep(seconds)
            after = {str(pid): counters(pid) for pid in pids}
            alive = [key for key in before if before[key] and after[key]]
            trial["exited_pids"] = sorted(set(before) - set(alive))
            trial["cpu_seconds_by_pid"] = {key: round(after[key][0] - before[key][0], 3) for key in alive}
            trial["cpu_percent_one_core"] = round(100 * sum(trial["cpu_seconds_by_pid"].values()) / seconds, 3)
            trial["seconds"] = seconds
            trial["after_memory"] = sample_memory(set(trial["created_webkit_pids"]))
            result[name] = trial
        finally:
            cleanup()
        print(f"features {name}: {result[name]['cpu_percent_one_core']:.2f}%", flush=True)
    return result


def extensions(label, base):
    setup(f"resource-{label}-extensions", session=session(1, base))
    try:
        trial = launch(f"{base}/tab-0")
        result = {"zero": trial["memory"], "installed": []}
        candidates = set(trial["created_webkit_pids"])
        with tempfile.TemporaryDirectory(prefix="escale-baseline-extensions-") as folder:
            for count in range(1, 4):
                path = Path(folder) / f"extension-{count}"
                path.mkdir()
                (path / "manifest.json").write_text(json.dumps({
                    "manifest_version": 3, "name": f"Baseline Local {count}",
                    "version": "1.0", "background": {"service_worker": "worker.js"}}))
                (path / "worker.js").write_text("chrome.runtime.onMessage.addListener(() => {});\n")
                before = set(webkit_processes())
                ask("ext-folder", path=str(path), yes=True)
                until(f"extension {count} loaded", lambda: (
                    (state := ask("extensions"))["busy"] == ""
                    and len(state["extensions"]) == count
                    and all(item["loaded"] for item in state["extensions"])), 30)
                candidates |= set(webkit_processes()) - before
                time.sleep(5)  # Let each local worker settle before sampling.
                state = ask("extensions")
                result["installed"].append({"count": count,
                                            "extensions": state["extensions"],
                                            "memory": sample_memory(candidates)})
                print(f"extensions: {count} loaded", flush=True)
        return result
    finally:
        cleanup()


def navigation(label, base, count):
    setup(f"resource-{label}-navigation", session=session(2, base))
    try:
        result = {"launch": launch(f"{base}/tab-0"), "bookmark": [], "selection_ack_ms": []}
        rows = ask("tabs")["tabs"]
        check("navigation tab count", len(rows), 2)
        ids = [row["id"] for row in rows]
        for index, ident in enumerate(ids):
            ask("select", id=ident)
            until(f"navigation fixture {ident} loaded",
                  lambda: (not next(tab for tab in ask("tabs")["tabs"]
                                    if tab["id"] == ident)["loading"]
                           and "Resource fixture" in ask("text", id=ident).get("text", "")), 15)
            loaded = ask("wait", id=ident, seconds=15)
            check(f"navigation fixture {ident} loading", loaded.get("loading"), False)
            check(f"navigation fixture {ident} failure", loaded.get("failure"), None)
            check(f"navigation fixture {ident} address", loaded["url"],
                  f"{base}/tab-{index}")
        for i in range(count):
            reply = ask("bookmark", timeout=30, url=f"{base}/navigation-{i}")
            check(f"navigation {i} stayed in tab", reply["sameTab"], True)
            result["bookmark"].append({key: reply[key] for key in
                                       ["returned", "loading", "rested", "viewWasBuilt"]})
        for i in range(count):
            start = time.monotonic()
            reply = ask("select", id=ids[i % 2])
            result["selection_ack_ms"].append(round((time.monotonic() - start) * 1000, 3))
            check(f"selection {i} active", reply["active"], True)
        result["after_memory"] = sample_memory(set(result["launch"]["created_webkit_pids"]))
        print(f"navigation and selection: {count} each", flush=True)
        return result
    finally:
        cleanup()


def main():
    global ROOT, APP
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT,
                        help="checkout whose release build is being measured")
    parser.add_argument("--label", required=True,
                        help="lowercase name for the measured revision")
    parser.add_argument("--out", type=Path, default=ROOT / ".build/baseline/samples.tar.gz",
                        help="compressed archive (default: local, ignored .build/baseline/samples.tar.gz)")
    parser.add_argument("--tag", help="optional sample tag, such as repeat")
    parser.add_argument("--launches", type=int, default=10)
    parser.add_argument("--idle-seconds", type=int, default=120)
    parser.add_argument("--idle-runs", type=int, default=1)
    parser.add_argument("--churn-cycles", type=int, default=100)
    parser.add_argument("--navigation-count", type=int, default=100)
    parser.add_argument("--feature-seconds", type=int, default=60)
    parser.add_argument("--only", choices=["core", "launches", "display", "typing", "spaces", "churn", "sleep", "features", "extensions", "idle", "background-idle", "navigation"],
                        default="core")
    args = parser.parse_args()
    if not str(args.out).endswith(".tar.gz"):
        parser.error("--out must name a .tar.gz archive")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.label):
        parser.error("--label must contain lowercase words separated by hyphens")
    if args.tag is not None and not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.tag):
        parser.error("--tag must contain lowercase words separated by hyphens")
    if args.idle_runs < 1:
        parser.error("--idle-runs must be at least 1")
    ROOT = args.root.resolve()
    APP = ROOT / "build/Escale.app"
    if not APP.exists():
        raise RuntimeError("build/Escale.app missing; run ./build.sh release first")
    global SERVER
    SERVER = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=SERVER.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{SERVER.server_address[1]}"
    result = {"commit": run("git", "rev-parse", "HEAD").strip(),
              "label": args.label, "world_prefix": f"resource-{args.label}",
              "binary_sha256": hashlib.sha256(
                  (APP / "Contents/MacOS/Escale").read_bytes()).hexdigest(),
              "bundle_build": plistlib.loads(
                  (APP / "Contents/Info.plist").read_bytes())["CFBundleVersion"],
              "system": run("sw_vers"), "swift": run("swift", "--version"),
              "machine": run("sysctl", "-n", "hw.model").strip(),
              "ram_bytes": int(run("sysctl", "-n", "hw.memsize").strip()),
              "power": run("pmset", "-g", "batt"),
              "fixture": "local HTML fixtures, 1180x780 default window; extension count varies by scenario"}
    try:
        if args.only in ("core", "launches"):
            result["launches"] = launches(args.label, args.launches)
        if args.only == "display":
            result["first_display"] = first_display(args.label, args.launches, base)
        if args.only == "core":
            for count in [20, 100]:
                result[f"restored_{count}"] = restored(args.label, count, base)
                print(f"restored {count}: {result[f'restored_{count}']['views']} view", flush=True)
        if args.only in ("core", "typing"):
            for count in [2000, 20000]:
                result[f"typing_{count}"] = typing(args.label, count, base)
                times = result[f"typing_{count}"]["typing_rest_ms"]
                print(f"typing {count}: median {statistics.median(times):.2f} ms", flush=True)
        if args.only in ("core", "idle"):
            if args.idle_runs == 1:
                result["idle"] = idle(args.label, base, args.idle_seconds)
                print(f"idle: {result['idle']['cpu_percent_one_core']:.2f}% of one core", flush=True)
            else:
                result["idle_trials"] = idle_trials(
                    args.label, base, args.idle_seconds, args.idle_runs, background=False)
        if args.only == "spaces":
            result["three_spaces"] = three_spaces(args.label, base)
            print("three spaces: 20 tabs switched", flush=True)
        if args.only == "churn":
            result["churn"] = churn(args.label, base, args.churn_cycles)
        if args.only == "sleep":
            result["sleep"] = sleep_pages(args.label, base)
            print("sleep: 19 pages slept, one woken", flush=True)
        if args.only == "features":
            result["features"] = features(args.label, base, args.feature_seconds)
        if args.only == "extensions":
            result["extensions"] = extensions(args.label, base)
        if args.only == "background-idle":
            if args.idle_runs == 1:
                result["background_idle"] = idle(args.label, base, args.idle_seconds, background=True)
                print(f"background idle: {result['background_idle']['cpu_percent_one_core']:.2f}%", flush=True)
            else:
                result["background_idle_trials"] = idle_trials(
                    args.label, base, args.idle_seconds, args.idle_runs, background=True)
        if args.only == "navigation":
            result["navigation"] = navigation(args.label, base, args.navigation_count)
    finally:
        SERVER.shutdown()
        cleanup()
    name = sample_name(args.label, args.only, args.tag)
    save_sample(args.out, name, result)
    print(f"raw sample: {args.out} ({name})")


if __name__ == "__main__":
    main()
