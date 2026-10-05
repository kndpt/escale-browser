#!/usr/bin/env python3
"""Resource cost of the API Calls panel: closed, open, closed again.

Usage: python3 Tests/Bench/network_calls_resources.py --output /tmp/calls.json
after ./build.sh (an optimised build), with no compiler or benchmark running.
One fresh world, the loopback fixture of network_calls.py. Each state keeps
3 physical-footprint samples after a settle, then 120 s of idle CPU time and
kernel wakeups with no bench traffic. Processes are attributed by PID: the
browser, the page and the inspector frontend (`_webProcessIdentifier`, bench
`calls pids`); another WebKit helper counts only while it holds files of this
world, since other apps on the Mac start them too. Excluded helpers are
listed. One run: an order of magnitude, not a distribution, and no energy.
`--tail N` adds N idle intervals after closing, to see whether residual
work settles. `--reference inspector` runs the same states with Web Inspector (⌥⌘I)
instead of the panel, to tell WebKit's own cost from the panel's.
"""
from argparse import ArgumentParser
from pathlib import Path
import json
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import resource_baseline as r
import network_calls as fixture


def main():
    parser = ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--idle", type=int, default=120)
    parser.add_argument("--reference", choices=("panel", "inspector"), default="panel")
    parser.add_argument("--tail", type=int, default=0, help="further idle intervals after closing")
    args = parser.parse_args()
    world = "callsres-" + uuid.uuid4().hex[:8]
    a, b = fixture.serve()
    page = f"http://127.0.0.1:{fixture.PORTS['a']}/"
    record = dict(world=world, reference=args.reference, memory=[], idle={}, notes=[], revision=r.run("git", "rev-parse", "HEAD").strip(),
                  os=r.run("sw_vers"), hardware=r.run("sysctl", "-n", "hw.model", "hw.memsize"),
                  power=r.run("pmset", "-g", "batt"), idle_seconds=args.idle)
    ask = r.ask
    roles = {}

    def js(tab, script):
        return ask("eval", id=tab, js=script)["value"]

    def fire(tab, tag):
        ask("eval", id=tab, js=f"fire({json.dumps(tag)}); true")
        r.until("fixture " + tag, lambda: js(tab, "window.done") is True, 40)

    def attributed():
        found = ask("calls", action="pids", id=tab)
        if found["page"]:
            roles["page"] = found["page"]
        if found["frontend"]:
            roles["frontend"] = found["frontend"]
        alive = r.all_processes()
        chosen, excluded = {}, {}
        for pid, name in r.webkit_processes().items():
            role = "page" if pid == roles.get("page") else "frontend" if pid == roles.get("frontend") else name.rsplit(".", 1)[-1]
            (chosen if role in ("page", "frontend") or r.owned_files(pid) else excluded)[pid] = role
        return {pid: role for pid, role in chosen.items() if pid in alive}, excluded

    def sample(stage):
        for _ in range(3):
            chosen, excluded = attributed()
            app = r.footprint(r.app_pid())["mib"]
            procs = {}
            for pid, role in chosen.items():
                try:
                    procs[str(pid)] = dict(role=role, mib=r.footprint(pid)["mib"])
                except RuntimeError:
                    continue
            record["memory"].append(dict(stage=stage, app=app, procs=procs,
                                         excluded={str(p): role for p, role in excluded.items()},
                                         aggregate=round(app + sum(p["mib"] for p in procs.values()), 2)))
            time.sleep(1)
        last = record["memory"][-1]
        print(f"  {stage}: app {last['app']} MiB, aggregate {last['aggregate']} MiB, "
              + ", ".join(f"{p['role']} {p['mib']}" for p in last["procs"].values()), flush=True)

    def idle(stage):
        chosen, _ = attributed()
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

    try:
        r.setup(world)
        r.run(fixture.s.ROOT / "fresh.sh", "again", timeout=90)
        r.until("socket", lambda: isinstance(ask("tabs", timeout=2).get("tabs"), list), 60)
        ask("ui", welcome=False, sidebar=True, look="light", size="standard")
        ask("resize", width=1360, height=860)
        ask("bookmark", url=page, new=True)
        tab = next(t["id"] for t in ask("tabs")["tabs"] if t["active"])
        ask("wait", id=tab, seconds=15)
        fire(tab, "warm")
        time.sleep(5)
        sample("closed-before")
        idle("closed-before")

        if args.reference == "panel":
            ask("calls", action="open")
            r.until("collecting", lambda: ask("calls")["phase"]["name"] == "collecting", 15)
            fire(tab, "open")
            row = next(x for x in reversed(ask("calls")["rows"]) if "k=post" in x["url"])
            ask("calls", action="select", call=row["id"])
            r.until("body read", lambda: (ask("calls").get("body") or {}).get("kind") == "text", 15)
            ask("calls", action="select")
            record["rows_open"] = ask("calls")["count"]
        else:
            ask("press", code=34, chars="i", mods=["cmd", "opt"])
            r.until("inspector docked", lambda: ask("calls")["inspector"] != "", 15)
            fire(tab, "open")
        time.sleep(5)
        sample("open")
        idle("open")

        if args.reference == "panel":
            ask("calls", action="close")
        else:
            ask("press", code=34, chars="i", mods=["cmd", "opt"])
        time.sleep(5)
        record["frontend_alive_after_close"] = roles.get("frontend") in r.all_processes()
        sample("closed-after")
        idle("closed-after")
        for index in range(args.tail):
            idle(f"closed-after+{index + 1}")
        record["frontend_alive_at_end"] = roles.get("frontend") in r.all_processes()
        record["completed"] = True
    finally:
        Path(args.output).write_text(json.dumps(record, indent=1, default=str))
        try:
            r.cleanup()
        except Exception as error:
            print("cleanup", error)
        a.shutdown()
        b.shutdown()
    print(args.output)


if __name__ == "__main__":
    main()
