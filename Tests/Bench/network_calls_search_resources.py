#!/usr/bin/env python3
"""Cost of the API Calls panel's search in responses.

Usage: python3 Tests/Bench/network_calls_search_resources.py --output PATH
[--workload small|large] after ./build.sh (an optimised build), with no
compiler or benchmark running. ESCALE_TEST_APP=/path/Escale.app measures
another build, such as main's, for the before side: a build without the
response search answers the same stages with the address filter alone.

One fresh world, one loopback page. `small` makes 400 JSON responses of
about 1 KB, `large` 12 of about 700 KB (past the 512 KB searched in each).
Stages: the panel open with the calls listed, no search; a search typed
(results latency, cold then warm, and the main thread's answer time to
`probe` while a cold pass reads responses); the search standing; the field
emptied. Each stage keeps 3 physical-footprint samples of the browser, the
page and the inspector frontend (by PID, as network_calls_resources.py) and
`--idle` seconds of CPU time and interrupt wakeups with no bench traffic.
Latencies are polled through the bench socket every 20 ms: an upper bound
with the socket's own cost in it, not a displayed-frame time. One run: an
order of magnitude, not a distribution, and no energy.
"""
from argparse import ArgumentParser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from threading import Thread
import json
import statistics
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import resource_baseline as r

WORD = "quokka"
PAGE = """<!doctype html><title>Search cost</title><h1>Search cost</h1><script>
window.done = true;
async function load(kind, count) {
  window.done = false;
  for (let i = 0; i < count; i += 20)
    await Promise.all(Array.from({length: Math.min(20, count - i)}, (_, j) => fetch('/api/' + kind + '?i=' + (i + j)).then(r => r.text())));
  window.done = true;
}
</script>"""


def small(i):
    rows = [{"id": i * 10 + k, "name": "item-%05d" % (i * 10 + k), "tags": ["a", "b"]} for k in range(10)]
    if i % 25 == 0:
        rows[3]["note"] = "a " + WORD + " here"
    return json.dumps({"page": i, "rows": rows})


def large(i):
    rows = [{"i": k, "pad": "x" * 90} for k in range(7000)]
    rows[100]["note"] = WORD if i % 3 == 0 else "none"
    return json.dumps({"page": i, "rows": rows})


BODIES = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        path, _, query = self.path.partition('?')
        if path == '/':
            data, kind = PAGE.encode(), 'text/html; charset=utf-8'
        else:
            i = int(query.split('i=')[1]) if 'i=' in query else 0
            key = (path, i)
            if key not in BODIES:
                BODIES[key] = (large(i) if path == '/api/large' else small(i)).encode()
            data, kind = BODIES[key], 'application/json'
        self.send_response(200)
        self.send_header('content-type', kind)
        self.send_header('content-length', str(len(data)))
        self.send_header('cache-control', 'no-store')
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--workload", choices=("small", "large"), default="small")
    parser.add_argument("--idle", type=int, default=120)
    args = parser.parse_args()
    count = 400 if args.workload == "small" else 12
    world = "searchres-" + uuid.uuid4().hex[:8]
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://127.0.0.1:{server.server_port}/"
    record = dict(world=world, workload=args.workload, calls=count, memory=[], idle={}, latency={},
                  revision=r.run("git", "rev-parse", "HEAD").strip(), os=r.run("sw_vers"),
                  hardware=r.run("sysctl", "-n", "hw.model", "hw.memsize"), power=r.run("pmset", "-g", "batt"),
                  idle_seconds=args.idle)
    ask = r.ask
    roles = {}

    def js(tab, script):
        return ask("eval", id=tab, js=script)["value"]

    def attributed():
        found = ask("calls", action="pids", id=tab)
        if found["page"]:
            roles["page"] = found["page"]
        if found["frontend"]:
            roles["frontend"] = found["frontend"]
        alive = r.all_processes()
        chosen = {}
        for pid, name in r.webkit_processes().items():
            if pid == roles.get("page"):
                chosen[pid] = "page"
            elif pid == roles.get("frontend"):
                chosen[pid] = "frontend"
            elif r.owned_files(pid):
                chosen[pid] = name.rsplit(".", 1)[-1]
        return {pid: role for pid, role in chosen.items() if pid in alive}

    def sample(stage):
        for _ in range(3):
            chosen = attributed()
            app = r.footprint(r.app_pid())["mib"]
            procs = {}
            for pid, role in chosen.items():
                try:
                    procs[str(pid)] = dict(role=role, mib=r.footprint(pid)["mib"])
                except RuntimeError:
                    continue
            record["memory"].append(dict(stage=stage, app=app, procs=procs,
                                         aggregate=round(app + sum(p["mib"] for p in procs.values()), 2)))
            time.sleep(1)
        last = record["memory"][-1]
        print(f"  {stage}: app {last['app']} MiB, aggregate {last['aggregate']} MiB, "
              + ", ".join(f"{p['role']} {p['mib']}" for p in last["procs"].values()), flush=True)

    def idle(stage):
        chosen = attributed()
        pids = [r.app_pid(), *chosen]
        names = {r.app_pid(): "app", **chosen}
        cpu = {p: r.cpu_seconds(p) for p in pids}
        wake = {p: r.wakeups(p) for p in pids}
        start = time.monotonic()
        time.sleep(args.idle)
        spent = time.monotonic() - start
        alive = r.all_processes()
        record["idle"][stage] = {
            f"{names[p]}:{p}": dict(cpu_percent=round((r.cpu_seconds(p) - cpu[p]) * 100 / spent, 3),
                                    interrupt_wakeups=r.wakeups(p)["interrupt"] - wake[p]["interrupt"])
            for p in pids if p in alive}
        print(f"  idle {stage}: {record['idle'][stage]}", flush=True)

    def searched(text):
        """Milliseconds from typing `text` to its results, polled every 20 ms,
        and the main thread's answer times to `probe` meanwhile."""
        answers = []
        started = time.monotonic()
        ask("calls", action="filter", search=text)
        while True:
            state = ask("calls")
            found = state.get("search")
            if found is None:
                # A build without the response search: the filter is at once.
                return round((time.monotonic() - started) * 1000, 1), answers, len(state["shown"]), None
            if found["needle"] == text and not found["running"]:
                return (round((time.monotonic() - started) * 1000, 1), answers, len(state["shown"]),
                        found.get("coverage"))
            asked = time.monotonic()
            ask("probe")
            answers.append(round((time.monotonic() - asked) * 1000, 2))
            if time.monotonic() - started > 60:
                raise RuntimeError("search did not settle in 60 s")
            time.sleep(0.02)

    try:
        r.setup(world)
        r.run(r.ROOT / "fresh.sh", "again", timeout=90)
        r.until("socket", lambda: isinstance(ask("tabs", timeout=2).get("tabs"), list), 60)
        ask("ui", welcome=False, sidebar=True, look="light", size="standard")
        ask("resize", width=1360, height=860)
        ask("bookmark", url=page, new=True)
        tab = next(t["id"] for t in ask("tabs")["tabs"] if t["active"])
        ask("wait", id=tab, seconds=15)
        ask("calls", action="open")
        r.until("collecting", lambda: ask("calls")["phase"]["name"] == "collecting", 15)
        ask("eval", id=tab, js=f"load('{args.workload}', {count}); true")
        r.until("loaded", lambda: js(tab, "window.done") is True, 120)
        r.until("rows", lambda: len([x for x in ask("calls")["rows"] if "/api/" in x["url"] and x["state"] == "done"]) >= count, 30)
        time.sleep(5)
        sample("open")
        idle("open")

        cold, answers, shown, coverage = searched(WORD)
        record["latency"]["cold"] = dict(ms=cold, shown=shown, coverage=coverage, probe_ms=answers)
        print(f"  cold search: {cold} ms, {shown} shown; probe answers median "
              f"{statistics.median(answers) if answers else '—'} ms, max {max(answers) if answers else '—'} ms", flush=True)
        warm = []
        for text in ("quokk", WORD, "item-0001", "item-00", WORD):
            ms, _, shown, _ = searched(text)
            warm.append(dict(text=text, ms=ms, shown=shown))
        record["latency"]["warm"] = warm
        print(f"  warm searches: {[w['ms'] for w in warm]} ms", flush=True)
        # Quick typing: one character at a time, 30 ms apart, as a hand types.
        started = time.monotonic()
        for end in range(2, len("item-00042") + 1):
            ask("calls", action="filter", search="item-00042"[:end])
            time.sleep(0.03)
        ms, _, shown, _ = searched("item-00042")
        record["latency"]["typed"] = dict(ms_after_last_key=ms, total_ms=round((time.monotonic() - started) * 1000, 1), shown=shown)
        print(f"  typed 'item-00042': results {ms} ms after the last key", flush=True)
        searched(WORD)
        time.sleep(5)
        sample("search")
        idle("search")

        searched("")
        time.sleep(5)
        sample("emptied")
        idle("emptied")
        record["completed"] = True
    finally:
        Path(args.output).write_text(json.dumps(record, indent=1, default=str))
        try:
            r.cleanup()
        except Exception as error:
            print("cleanup", error)
        server.shutdown()
    print(args.output)


if __name__ == "__main__":
    main()
