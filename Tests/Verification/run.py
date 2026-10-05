"""Select, run and resume checks without replacing their test runners.

One checkout runs one campaign at a time. App checks receive an immutable bundle
copy and a unique world, side by side with --jobs; a failed prerequisite stops
the campaign. Evidence stays local until an explicit export. No retry or
automatic visual/resource approval.
"""
import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

from catalog import CHECKS, RISK_CHECKS, plan
from evidence import changes, digest, environment, fingerprint, git, latest, read, stamp, validity, write
from compiler import BaseBuildBlocked, compare

ROOT = Path(__file__).resolve().parents[2]


@contextmanager
def locked(cache):
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("another verification/cleanup owns this checkout")
        yield


# Set when the campaign is interrupted: checks running beside each other are
# each in a thread of their own, which a signal to the campaign never reaches.
ABORT = threading.Event()


def execute(command, root, log, timeout, env=None, abortable=True):
    """Keep complete output and let Python scenarios clean up on interruption."""
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=root, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    return process.wait(timeout=max(0, min(0.25, deadline - time.monotonic())))
                except subprocess.TimeoutExpired:
                    if abortable and ABORT.is_set():
                        raise KeyboardInterrupt
                    if time.monotonic() >= deadline:
                        raise subprocess.TimeoutExpired(command, timeout)
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            os.killpg(process.pid, signal.SIGINT)
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise


def changed(root, base):
    names = subprocess.check_output(["git", "diff", "--name-only", "-z", base], cwd=root).decode().split("\0")
    names += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    return sorted(set(names) - {""})


def preflight(check, env):
    if check.name == "portable" and sys.platform != "darwin":
        return "collector baseline tests need macOS; Linux CI runs the archive tests separately"
    mac = check.name in ("icons", "build", "swift", "warnings", "bundle") or check.category == "app"
    if mac and sys.platform != "darwin":
        return "macOS is required"
    if os.environ.get("PYTHONOPTIMIZE") not in (None, "", "0"):
        return "PYTHONOPTIMIZE disables scenario assertions; unset it"
    tools = ["python3", "git"] + (["swift", "xcode-select"] if mac else [])
    if check.name == "bundle" or check.category == "app":
        tools += ["codesign", "open", "defaults"]
    missing = [name for name in tools if not shutil.which(name)]
    if missing:
        return "missing prerequisite: " + ", ".join(missing)
    if mac and env.get("swift", {}).get("exit", 1):
        return "Swift toolchain unavailable"
    return None


def describe(proposal):
    print("Iteration checks (not delivery)" if proposal["quick"] else "Checks for changed inputs")
    for name in proposal["checks"]:
        check = CHECKS[name]
        print(f"  {name}: {proposal['reasons'][name]} — {check.risks}")
    if proposal["unknown"]:
        print("Unmapped: " + ", ".join(proposal["unknown"]))
        print("Scope decision: " + (proposal["acknowledge"] or "required: add checks/risks and --acknowledge with rationale"))
    for observation in proposal["observations"]:
        print("Manual qualification pending: " + observation)


def bundle_from(receipt):
    if receipt and receipt.get("result") == "passed":
        path = receipt.get("bundle")
        if path and fingerprint(path) == receipt.get("artifacts", {}).get(path):
            return {"path": path, "sha256": fingerprint(path)}
    return None


def snapshot_bundle(root, cache, key):
    source = root / "build/Escale.app"
    before = fingerprint(source)
    if before is None:
        raise RuntimeError("build succeeded without an app bundle")
    destination = cache / "bundles" / digest({"inputs": key, "bundle": before}) / "Escale.app"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(destination, ignore_errors=True)
    shutil.copytree(source, destination, symlinks=True)
    if fingerprint(source) != before or fingerprint(destination) != before:
        raise RuntimeError("bundle changed while being copied")
    return str(destination)


def failure(log):
    if not log.exists():
        return "no process output"
    lines = log.read_text(errors="replace").splitlines()
    return next((line for line in lines if any(term in line for term in
                ("FAIL:", "AssertionError:", "error:", "NEW WARNING:", "FAILED"))
                 and not line.lstrip().startswith(("raise ", "print(", "if "))),
                next((line for line in reversed(lines) if line.strip()), "empty output"))[:600]


def untracked_whitespace(root, log):
    """Git diff omits new files until staging; check their actual contents too."""
    names = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    failed = False
    with log.open("a") as output:
        for name in filter(None, names):
            result = subprocess.run(["git", "diff", "--no-index", "--check", "/dev/null", name],
                                    cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=15)
            # --no-index returns 1 for an ordinary difference and 3 for a
            # difference with whitespace errors. Other failures remain failures.
            failed |= result.returncode not in (0, 1)
    return int(failed)


def attempt(name, context, background=False, peers=False):
    """One check from stamp to receipt; the campaign decides when it starts.
    Among peers, a failure is the group's to record, not this check's."""
    root, cache, folder, env, base = (context[k] for k in ("root", "cache", "folder", "env", "base"))
    report, proposal, bundle = context["report"], context["proposal"], context["bundle"]
    check = CHECKS[name]
    current = stamp(root, check, env, base, bundle)
    previous = latest(cache, name)
    state = validity(previous, current)
    log = folder / f"{name}.log"
    receipt = {"name": name, "stamp": current, "result": "not-run", "duration": 0,
               "artifacts": {}, "head": report["head"], "base": base,
               "category": check.category, "risks": check.risks,
               "command": shlex.join(check.command), "previous": state}
    receipt["invalidated_by"] = changes(previous, current)
    reproduction = ["./verify", "run", "--quick", "--base", base, "--check", name, "--force"]
    if proposal["acknowledge"]:
        reproduction += ["--acknowledge", proposal["acknowledge"]]
    receipt["reproduce"] = shlex.join(reproduction)
    if context["halted"]:
        receipt["cause"] = "campaign stopped by an earlier failure or unresolved scope"
    elif not context["force"] and state == "passed":
        return {"name": name, "result": "passed", "action": "reused",
                "receipt": previous["receipt"], "duration": 0}
    else:
        cause = preflight(check, env)
        if cause:
            receipt.update(result="blocked", cause=cause)
        else:
            receipt["result"] = "running"
            receipt["receipt"] = str(folder / f"{name}.json")
            write(receipt["receipt"], receipt)
            clock = time.monotonic()
            child_env = dict(os.environ)
            for key in tuple(child_env):
                if key.startswith("ESCALE_") or key == "KEEP":
                    child_env.pop(key)
            world = "verify-" + uuid.uuid4().hex[:16]
            diagnostics = folder / (name + "-diagnostics")
            if check.category == "app":
                child_env.update(ESCALE_VERIFY_WORLD=world, ESCALE_TEST_APP=bundle["path"] if bundle else "",
                                 ESCALE_DIAGNOSTICS=str(diagnostics))
                if background:
                    child_env["ESCALE_BACKGROUND"] = "1"
                receipt["world"] = world
                receipt["bundle"] = bundle
                receipt["lane"] = "background" if background else "foreground"
            try:
                if name == "warnings":
                    receipt["command"] = "clean swift build of base and candidate (Tests/Verification/compiler.py)"
                    code = compare(root, cache, base, env, log, execute)
                else:
                    command = list(check.command)
                    if name == "whitespace":
                        command.append(base)
                    receipt["command"] = shlex.join(command)
                    code = execute(command, root, log, check.timeout, child_env)
                    if name == "whitespace" and code == 0:
                        code = untracked_whitespace(root, log)
                        receipt["command"] += " ; untracked files: git diff --no-index --check /dev/null FILE"
                receipt["result"] = "passed" if code == 0 else "failed"
                receipt["exit"] = code
                if code:
                    receipt["cause"] = failure(log)
                if name == "bundle" and code == 0:
                    receipt["bundle"] = snapshot_bundle(root, cache, current["key"])
                after = stamp(root, check, env, base, bundle)
                if after["key"] != current["key"]:
                    receipt.update(result="stale", cause="inputs changed during execution")
                if bundle and check.category == "app" and fingerprint(bundle["path"]) != bundle["sha256"]:
                    receipt.update(result="stale", cause="tested bundle changed during execution")
            except KeyboardInterrupt:
                receipt.update(result="interrupted", cause="interrupted; no success inferred")
                context["interrupted"] = True
            except subprocess.TimeoutExpired:
                receipt.update(result="failed", cause=f"deadline exceeded ({check.timeout}s); cause undiagnosed")
            except BaseBuildBlocked as error:
                receipt.update(result="blocked", cause=str(error))
            except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
                receipt.update(result="failed", cause=str(error))
            finally:
                # LaunchServices children are not necessarily in our process
                # group. Only this campaign's exact world may be cleaned.
                if check.category == "app":
                    cleanup_log = folder / f"{name}-cleanup.log"
                    try:
                        code = execute([str(root / "fresh.sh"), "wipe"], root, cleanup_log, 30,
                                       dict(child_env, ESCALE_PROBE=world), abortable=False)
                        if code:
                            receipt["cleanup_error"] = failure(cleanup_log)
                            if receipt["result"] == "passed":
                                receipt.update(result="failed", cause="world cleanup failed")
                    except (OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                        receipt["cleanup_error"] = str(error)
                        if receipt["result"] == "passed":
                            receipt.update(result="failed", cause="world cleanup interrupted")
                receipt["duration"] = time.monotonic() - clock
        if receipt["result"] != "passed" and not peers:
            context["halted"] = True
    receipt["receipt"] = str(folder / f"{name}.json")
    # This check's own files only: "calls" must not take in "calls-browse.log",
    # which a check running beside it is still writing.
    receipt["artifacts"] = {str(p): fingerprint(p) for p in folder.glob(name + "*")
                            if p.suffix != ".json" and p.is_file() and p.stem in (name, name + "-cleanup")}
    if name == "bundle" and receipt.get("bundle"):
        receipt["artifacts"][receipt["bundle"]] = fingerprint(receipt["bundle"])
        context["bundle"] = bundle_from(receipt)
    diagnostics = folder / (name + "-diagnostics")
    if diagnostics.exists():
        receipt["artifacts"][str(diagnostics)] = fingerprint(diagnostics)
    # Not-run entries belong to this plan, but must not erase an older
    # completed receipt for a check that was never attempted this time.
    if receipt["result"] != "not-run":
        write(receipt["receipt"], receipt)
    return {"name": name, "result": receipt["result"], "action": "executed",
            "receipt": receipt["receipt"] if receipt["result"] != "not-run" else None,
            "previous": state, "duration": receipt["duration"], "cause": receipt.get("cause"),
            **({"lane": receipt["lane"]} if "lane" in receipt else {})}


def announce(row):
    if row["action"] == "reused":
        print(f"{row['name']}: passed (reused)", flush=True)
    else:
        print(f"{row['name']}: {row['result']} ({row['duration']:.2f}s)" +
              (f" — {row['cause']}" if row.get("cause") else ""), flush=True)


def side_by_side(names, context, jobs, record):
    """App checks in their own worlds at once. A foreground check takes the
    keyboard and pointer, so one runs at a time; the others are opened behind
    and never take either. They depend on the bundle, not on each other: one
    failing leaves the others to finish, so a campaign reports every failure
    at once, and what comes after them stops as before. The longest by their
    last receipt start first, so the campaign is not left waiting on one long
    check at the end."""
    def last(name):
        receipt = latest(context["cache"], name)
        return (receipt or {}).get("duration") or 0
    waiting = sorted(names, key=lambda name: (-last(name), names.index(name)))
    running = {}
    lock = threading.Lock()
    # Stopped before the group began (a prerequisite, an interruption): no
    # check starts. A peer's failure is recorded once the group is over.
    stopped = context["halted"]
    failed = False

    def work(name, background):
        nonlocal failed
        row = attempt(name, context, background, peers=True)
        with lock:
            failed |= row["result"] != "passed"
            record(row)

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        try:
            while waiting or running:
                for future in [f for f in running if f.done()]:
                    future.result()
                    del running[future]
                foreground_busy = any(lane == "foreground" for lane in running.values())
                for name in list(waiting):
                    if len(running) >= jobs:
                        break
                    if stopped or context["interrupted"]:
                        waiting.remove(name)
                        with lock:
                            record(attempt(name, dict(context, halted=True)))
                        continue
                    lane = "foreground" if CHECKS[name].foreground else "background"
                    if lane == "foreground" and foreground_busy:
                        continue
                    waiting.remove(name)
                    foreground_busy |= lane == "foreground"
                    running[pool.submit(work, name, lane == "background")] = lane
                wait(list(running), timeout=0.2, return_when=FIRST_COMPLETED) if running else None
        except KeyboardInterrupt:
            # Every running scenario is asked to stop, then given time to clean.
            ABORT.set()
            context["halted"] = True
            context["interrupted"] = True
            wait(list(running))
            raise
    if failed:
        context["halted"] = True


def campaign(root, cache, proposal, base, force=False, jobs=1):
    started = time.monotonic()
    ABORT.clear()
    folder = cache / "runs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f") + "-" + uuid.uuid4().hex[:6])
    folder.mkdir(parents=True)
    need_mac = any(n in proposal["checks"] for n in ("build", "icons", "bundle"))
    env = environment(mac=need_mac)
    report = {"plan": proposal, "base": base, "head": git(root, "rev-parse", "HEAD"),
              "root": str(root), "results": [], "result": "running", "jobs": jobs}
    write(folder / "report.json", report)
    if proposal["quick"]:
        print("Quick loop — not delivery qualification", flush=True)
    context = {"root": root, "cache": cache, "folder": folder, "env": env, "base": base,
               "report": report, "proposal": proposal, "force": force,
               "halted": bool(proposal["unknown"] and not proposal["acknowledge"]),
               "bundle": bundle_from(latest(cache, "bundle")), "interrupted": False}
    order = proposal["checks"]

    def record(row):
        report["results"].append(row)
        report["results"].sort(key=lambda r: order.index(r["name"]))
        announce(row)
        write(folder / "report.json", report)

    index = 0
    try:
        while index < len(order):
            name = order[index]
            if CHECKS[name].category == "app":
                group = []
                while index < len(order) and CHECKS[order[index]].category == "app":
                    group.append(order[index])
                    index += 1
                side_by_side(group, context, jobs, record)
            else:
                record(attempt(name, context))
                index += 1
    except KeyboardInterrupt:
        context["interrupted"] = True
    interrupted = context["interrupted"]
    report["duration"] = time.monotonic() - started
    report["result"] = ("interrupted" if interrupted else "incomplete" if context["halted"] or proposal["observations"]
                        else "passed")
    # A source can change after its check but before the campaign ends. Never
    # combine receipts for different trees into a green delivery report.
    report = refreshed(report, root, cache, env)
    write(folder / "report.json", report)
    (folder / "report.md").write_text(markdown(report))
    print(markdown(report), end="")
    return 0 if report["result"] == "passed" else 130 if interrupted else 1


def markdown(report):
    command = ["./verify", "run"] + (["--quick"] if report["plan"]["quick"] else [])
    for flag, key in (("--risk", "risks"), ("--check", "requested")):
        for value in report["plan"].get(key, []):
            command += [flag, value]
    passed = [row["name"] for row in report["results"] if row["result"] == "passed"]
    remaining = [row for row in report["results"] if row["result"] != "passed"]
    lines = ["## Verification", "", f"`{shlex.join(command)}`: {report['result']} ({len(passed)}/{len(report['results'])} checks passed)."]
    if passed:
        lines.append("Passed: " + ", ".join(passed) + ".")
    for row in remaining:
        lines.append(f"{row['name']}: {row['result']}" + (f" — {row['cause']}" if row.get("cause") else "") + ".")
    limits = (["quick loop, not a delivery qualification"] if report["plan"]["quick"] else [])
    limits += report["plan"]["observations"]
    if limits:
        lines.append("Limits: " + "; ".join(limits) + ".")
    if report["plan"]["unknown"]:
        lines += ["Outside the catalogue: " + ", ".join(report["plan"]["unknown"]),
                  "Rationale: " + (report["plan"]["acknowledge"] or "not given")]
    return "\n".join(lines) + "\n"


def refreshed(report, root, cache, env=None):
    """A report is historical until its receipts are checked against today."""
    if env is None:
        env = environment(mac=any(n in report["plan"]["checks"] for n in ("build", "icons", "bundle")))
    bundle = bundle_from(latest(cache, "bundle"))
    for row in report["results"]:
        receipt = read(row["receipt"]) if row.get("receipt") else None
        if receipt:
            state = validity(receipt, stamp(root, CHECKS[row["name"]], env, report["base"], bundle))
            if state != "passed":
                row["result"] = state
                if report["result"] != "interrupted":
                    report["result"] = "incomplete"
    return report


def main():
    def interrupted(_number, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "run", "status", "report", "clean"))
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--risk", choices=RISK_CHECKS, action="append", default=[])
    parser.add_argument("--check", choices=CHECKS, action="append", default=[])
    parser.add_argument("--quick", action="store_true", help="iteration: defer automatic app checks and clean warning comparison")
    parser.add_argument("--acknowledge", help="explicit rationale for changed paths outside the catalogue")
    parser.add_argument("--force", action="store_true", help="rerun; never erase the previous failure")
    parser.add_argument("--jobs", type=int, default=3,
                        help="app checks at once, each in its own world; one at a time in front")
    parser.add_argument("--export", type=Path, help="copy the last report and referenced evidence for review")
    parser.add_argument("--days", type=int, default=14, help="clean inactive local evidence older than N days")
    args = parser.parse_args()
    if args.export and args.action != "report":
        parser.error("--export belongs to report")
    cache = ROOT / "build/verification"
    try:
        with locked(cache):
            if args.action == "clean":
                if args.days < 1:
                    parser.error("--days must be at least 1; export review evidence first")
                cutoff = time.time() - args.days * 86400
                for group in ("runs", "bundles", "compiler"):
                    for path in (cache / group).glob("*"):
                        if path.stat().st_mtime < cutoff:
                            shutil.rmtree(path) if path.is_dir() else path.unlink()
                print("Removed old local evidence; missing artifacts invalidate reuse.")
                return 0
            if args.action == "report":
                reports = sorted((cache / "runs").glob("*/report.json"))
                if not reports:
                    raise RuntimeError("no campaign to report")
                report = refreshed(read(reports[-1]), ROOT, cache)
                if args.export:
                    destination = args.export.resolve()
                    if destination == cache or cache in destination.parents:
                        raise RuntimeError("export outside the disposable cache")
                    destination.mkdir(parents=True, exist_ok=False)
                    shutil.copytree(reports[-1].parent, destination / "campaign")
                    write(destination / "current-report.json", report)
                    for row in report["results"]:
                        if not row.get("receipt"):
                            continue
                        receipt = read(row["receipt"])
                        if receipt:
                            target = destination / "evidence" / row["name"]
                            target.mkdir(parents=True)
                            shutil.copy2(row["receipt"], target / "receipt.json")
                            for name in receipt["artifacts"]:
                                path = Path(name)
                                if path.suffix == ".app":
                                    continue
                                if path.is_dir():
                                    shutil.copytree(path, target / path.name)
                                elif path.exists():
                                    shutil.copy2(path, target / path.name)
                    exported = json.loads(json.dumps(report))
                    for row in exported["results"]:
                        if row.get("receipt"):
                            row["receipt"] = f"evidence/{row['name']}/receipt.json"
                    (destination / "report.md").write_text(markdown(exported))
                    print(destination)
                else:
                    print(markdown(report))
                return 0
            base = git(ROOT, "merge-base", args.base, "HEAD")
            proposal = plan(changed(ROOT, base), args.risk, args.check, args.quick, args.acknowledge)
            if args.action == "plan":
                describe(proposal)
                return 1 if proposal["unknown"] and not proposal["acknowledge"] else 0
            if args.action == "status":
                env = environment(mac=any(n in proposal["checks"] for n in ("build", "icons", "bundle")))
                bundle = bundle_from(latest(cache, "bundle"))
                bad = False
                for name in proposal["checks"]:
                    receipt = latest(cache, name)
                    current = stamp(ROOT, CHECKS[name], env, base, bundle)
                    state = validity(receipt, current)
                    reason = changes(receipt, current) if state == "stale" else []
                    print(f"{name}: {state}" + (" — " + ", ".join(reason[:4]) +
                                               (f" (+{len(reason)-4})" if len(reason) > 4 else "") if reason else ""))
                    bad |= state != "passed"
                describe(proposal)
                return int(bad or bool(proposal["observations"]) or bool(proposal["unknown"] and not proposal["acknowledge"]))
            if args.jobs < 1:
                parser.error("--jobs must be at least 1")
            return campaign(ROOT, cache, proposal, base, args.force, args.jobs)
    except KeyboardInterrupt:
        print("interrupted: no success inferred", file=sys.stderr)
        return 130
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"blocked: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
