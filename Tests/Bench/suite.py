#!/usr/bin/env python3
"""Short local WebKit regressions: page, lazy restore and a typed draft.

Run after ./build.sh with `python3 Tests/Bench/suite.py`. The runner owns a
fresh, random probe world and a loopback HTTP server. Every socket and
process wait has a deadline; cleanup touches only that world. `--fail-check`
and `--timeout-check` exercise the runner's two failure paths without launching
the app, for validating the test harness itself.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from datetime import datetime, timedelta, timezone
from contextlib import contextmanager
import diagnostics
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
# Twenty hex digits leave the Unix socket path below macOS's 104-byte limit.
WORLD = os.environ.get("ESCALE_VERIFY_WORLD", f"tests-{uuid.uuid4().hex[:20]}")
if not re.fullmatch(r"(?:tests|verify)-[a-f0-9]{16,20}", WORLD):
    raise ValueError("invalid owned test-world identity")
SOCKET = Path.home() / "Library/Application Support" / f"Escale ({WORLD})" / "bench.sock"
SUITE = f"com.kndpt.escale.test.{WORLD}"
BINARY = str(ROOT / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = (f"<title>Suite {name}</title><h1>{name}</h1>"
                "<textarea id='draft'></textarea>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def require(what, actual, expected):
    if actual != expected:
        raise AssertionError(f"{what}: expected {expected!r}, got {actual!r}")


class WaitExpired(AssertionError):
    """An observable condition stayed false; command failures remain distinct."""


def until(what, condition, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = condition()
        if result:
            return result
        time.sleep(min(0.15, max(0, end - time.monotonic())))
    raise WaitExpired(f"{what}: timed out after {seconds}s")


def wait_for(what, observe, expected, seconds=15):
    """Wait for named state values, retaining the last observation on timeout."""
    actual = {}

    def matches():
        nonlocal actual
        actual = observe()
        return all(actual[key] == value for key, value in expected.items())

    try:
        until(what, matches, seconds)
    except WaitExpired as error:
        raise WaitExpired(f"{error}; expected {expected!r}, last observed {actual!r}") from error
    return actual


def bench_client():
    """The ./bench script loaded as a module, once."""
    global _bench
    if _bench is None:
        loader = importlib.machinery.SourceFileLoader("bench_client", str(BENCH))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(module)
        _bench = module
    return _bench


_bench = None
BENCH = ROOT / "bench"


def command(*args, seconds=60):
    if args and str(args[0]) == str(BENCH):
        # The same client in this process: a scenario sends hundreds of
        # commands, and starting Python for each cost more than most answers.
        # Output, exit status, deadline and diagnostics stay as the shell's.
        started = time.monotonic()
        try:
            code, output, error = bench_client().run([str(a) for a in args[1:]], timeout=seconds, cwd=ROOT)
        except (TimeoutError, OSError) as caught:
            diagnostics.record(args, "", str(caught), "timeout" if isinstance(caught, TimeoutError) else "error",
                               time.monotonic() - started)
            if isinstance(caught, TimeoutError):
                raise subprocess.TimeoutExpired([str(a) for a in args], seconds) from caught
            raise
        diagnostics.record(args, output, error, code, time.monotonic() - started)
        if code:
            raise AssertionError(f"{' '.join(map(str, args))}: exit {code}: {error.strip()} {output.strip()}")
        return output
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    env.pop("ESCALE_MEASURE", None)
    # fresh.sh forwards every brand's demo source; a scenario reads only the
    # fixtures under its world's Store, never a real profile left in the shell.
    for key in [key for key in env if re.fullmatch(r"ESCALE_[A-Z0-9]+_SOURCE", key)]:
        env.pop(key)
    started = time.monotonic()
    try:
        result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=seconds)
    except subprocess.TimeoutExpired as error:
        diagnostics.record(args, (error.stdout or b"").decode() if isinstance(error.stdout, bytes) else error.stdout,
                           (error.stderr or b"").decode() if isinstance(error.stderr, bytes) else error.stderr,
                           "timeout", time.monotonic() - started)
        raise
    diagnostics.record(args, result.stdout, result.stderr, result.returncode, time.monotonic() - started)
    if result.returncode:
        raise AssertionError(f"{' '.join(map(str, args))}: exit {result.returncode}: "
                             f"{result.stderr.strip()} {result.stdout.strip()}")
    return result.stdout


def ask(verb, **fields):
    args = [verb]
    if verb in ("open", "bookmark"):
        args.append(fields["url"])
        if fields.get("new"):
            args.append("new")
    elif verb in ("wait",):
        args.extend([fields["id"], str(fields["seconds"])])
    elif verb in ("text", "close", "select", "sleep"):
        args.append(fields["id"])
    elif verb == "press":
        args.extend([str(fields["code"]), fields["chars"], *fields.get("mods", [])])
    elif verb in ("tap", "key"):
        args.extend([fields["id"], fields.get("selector", fields.get("text"))])
    elif verb == "eval":
        args.extend([fields["id"], fields["js"]])
    elif verb not in ("tabs", "space"):
        raise AssertionError(f"unsupported bench command: {verb}")
    raw = command(str(ROOT / "bench"), "--world", WORLD, "--json", *args, seconds=35)
    try:
        answer = json.loads(raw)
    except ValueError as error:
        raise AssertionError(f"{verb} {fields}: invalid or empty reply {raw!r}") from error
    return answer


def probe_ready():
    try:
        return bool(ask("tabs"))
    except AssertionError as error:
        if "Escale isn't listening" in str(error):
            return False
        raise


def launch():
    source = Path(os.environ.get("ESCALE_TEST_APP", ROOT / "build/Escale.app"))
    if not source.is_dir():
        raise AssertionError(f"test app missing: {source}; run ./build.sh debug first")
    command(str(ROOT / "fresh.sh"), "again")
    until("probe socket", probe_ready, 30)
    diagnostics.launched(WORLD, BINARY)


@contextmanager
def world(server):
    """Own preparation, evidence-before-cleanup and all terminal paths."""
    owned = False
    error = None
    previous_diagnostics = os.environ.get("ESCALE_DIAGNOSTICS")
    try:
        if SOCKET.parent.exists() or (ROOT / "build/probe" / WORLD).exists():
            raise AssertionError(f"test world {WORLD} is occupied; refusing to wipe it")
        owned = True
        if not previous_diagnostics:
            os.environ["ESCALE_DIAGNOSTICS"] = str(ROOT / "build/bench-diagnostics" / WORLD)
        command("defaults", "write", SUITE, "bench", "-bool", "YES")
        command("defaults", "write", SUITE, "welcomed", "-bool", "YES")
        checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S +0000")
        command("defaults", "write", SUITE, "update.checked", "-date", checked)
        yield
    except BaseException as caught:
        error = caught
        if owned:
            try:
                diagnostics.capture(ROOT, WORLD, BINARY, caught)
                print(f"Diagnostics: {diagnostics.folder()}", file=sys.stderr)
            except Exception as diagnostic_error:
                print(f"diagnostics unavailable: {diagnostic_error}", file=sys.stderr)
        raise
    finally:
        cleanup_failure = None
        try:
            # Always release the fixture, including when an occupied world is
            # refused. A server failure must not prevent owned app cleanup.
            for cleanup in ([server.shutdown, server.server_close] if server else []) + (
                    [lambda: command(str(ROOT / "fresh.sh"), "wipe")] if owned else []):
                try:
                    cleanup()
                except Exception as cleanup_error:
                    if error is None and cleanup_failure is None:
                        cleanup_failure = cleanup_error
                    else:
                        print(f"cleanup also failed: {cleanup_error}", file=sys.stderr)
            if cleanup_failure is not None:
                raise cleanup_failure
        finally:
            if previous_diagnostics is None:
                os.environ.pop("ESCALE_DIAGNOSTICS", None)
            else:
                os.environ["ESCALE_DIAGNOSTICS"] = previous_diagnostics


def tabs():
    return ask("tabs")["tabs"]


def running():
    output = subprocess.run(["ps", "-axo", "comm="], capture_output=True,
                            text=True, timeout=5).stdout
    return BINARY in output.splitlines()


def at(url):
    return next((tab for tab in tabs() if tab["url"] == url), None)


def open_ordinary(url):
    ask("bookmark", url=url, new=True)
    until(f"ordinary tab {url}", lambda: at(url) is not None, 15)
    ident = at(url)["id"]
    loaded_page(ident, url.rsplit("/", 1)[-1], 15, "ordinary page")
    return ident


def loaded_page(ident, content, seconds, label):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        row = next((tab for tab in tabs() if tab["id"] == ident), None)
        if row is not None and not row["loading"]:
            # Bench.wait currently returns after one beat even if still loading.
            # Poll the observable tab state and content before accepting it.
            state = ask("wait", id=ident, seconds=1)
            require(f"{label} failure", state.get("failure"), None)
            if content in ask("text", id=ident).get("text", ""):
                return state
        time.sleep(0.15)
    raise AssertionError(f"{label} timeout after {seconds}s")


def exercise(base):
    # A bench tab is deliberately outside the saved session.
    page = ask("open", url=f"{base}/page")
    page_id = page["id"]
    loaded = loaded_page(page_id, "page", 15, "page")
    require("page loaded", loaded.get("loading"), False)
    require("page timeout", loaded.get("timeout", False), False)
    require("page load failure", loaded.get("failure"), None)
    require("page content", "page" in ask("text", id=page_id).get("text", ""), True)
    ask("close", id=page_id)
    require("page closed", any(t["id"] == page_id for t in tabs()), False)
    print("ok: loopback page loads and closes")

    first = f"{base}/first"
    second = f"{base}/second"
    open_ordinary(first)
    open_ordinary(second)
    ask("press", code=12, chars="q", mods=["cmd"])
    until("probe to quit", lambda: not running(), 30)
    launch()
    rows = tabs()
    require("restored URLs", {t["url"] for t in rows if t["url"] in (first, second)},
            {first, second})
    require("restored page views", len(ask("space")["pages"]), 1)
    selected = next(t for t in rows if t["active"])
    require("restored selected page", selected["url"], second)
    restored = loaded_page(selected["id"], "second", 15, "restored page")
    require("restored page timeout", restored.get("timeout", False), False)
    require("restored page loaded", restored.get("loading"), False)
    require("restored page failure", restored.get("failure"), None)
    require("restored page content", "second" in ask("text", id=selected["id"]).get("text", ""), True)
    print("ok: two ordinary tabs restore with one page view")

    draft = f"{base}/draft"
    draft_id = open_ordinary(draft)
    ask("tap", id=draft_id, selector="#draft")
    ask("key", id=draft_id, text="unsent words")
    until("typed draft", lambda: ask("eval", id=draft_id, js="document.querySelector('#draft').value")
          .get("value") == "unsent words", 5)
    ask("select", id=at(first)["id"])
    sleeping = ask("sleep", id=draft_id)
    require("draft sleep result", sleeping["asleep"], False)
    require("draft preservation reason", sleeping["said"], "holding something typed")
    require("draft still present", ask("eval", id=draft_id,
            js="document.querySelector('#draft').value").get("value"), "unsent words")
    print("ok: real keys leave an unsent draft awake")

    # If the page's draft check is absent, returns no Boolean, or throws,
    # never count as proof that the text can be discarded.
    for label, script in (("missing", "window.__escaleForms.unsaved = undefined; true"),
                          ("undefined result", "window.__escaleForms.unsaved = () => undefined; true"),
                          ("numeric result", "window.__escaleForms.unsaved = () => 0; true"),
                          ("throwing", "window.__escaleForms.unsaved = () => { throw Error('draft check failed') }; true")):
        require(f"{label} check setup", ask("eval", id=draft_id, js=script).get("value"), True)
        sleeping = ask("sleep", id=draft_id)
        require(f"{label} check keeps page awake", sleeping["asleep"], False)
        require(f"{label} check reason", sleeping["said"], "could not check for a draft")
        require(f"{label} check keeps the draft", ask("eval", id=draft_id,
                js="document.querySelector('#draft').value").get("value"), "unsent words")
    print("ok: an unavailable draft check keeps the page awake")

    safe = ask("sleep", id=at(second)["id"])
    require("ordinary page can still sleep", safe["asleep"], True)
    require("ordinary page sleep reason", safe["said"], "asleep")
    print("ok: an ordinary page without a draft can sleep")


def main():
    if "--fail-check" in sys.argv:
        require("intentional false assertion", 1, 2)
    if "--timeout-check" in sys.argv:
        until("intentional timeout", lambda: False, 0.2)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with world(server):
        launch()
        exercise(f"http://127.0.0.1:{server.server_address[1]}")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
