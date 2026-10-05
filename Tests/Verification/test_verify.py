"""Exercise trust boundaries with real local files and disposable Git repos.

These regressions deliberately mutate inputs and binaries, interrupt a
process, and fail an assertion. No browser, compiler or personal storage is used.
"""
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from catalog import CHECKS, Check, plan
from compiler import warnings, compare
from evidence import fingerprint, inputs, latest, read, stamp, validity
from run import campaign, execute, locked, markdown, preflight, snapshot_bundle, refreshed, untracked_whitespace


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.put(".gitignore", "build/\n")
        self.put("script.py", "print('passed')\n")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@invalid", "commit", "-qm", "fixture")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.check = Check("probe", (sys.executable, "script.py"), ("script.py", "fixtures/**"), "synthetic assertion")
        self.cache = self.root / "build/verification"
        self.proposal = {"checks": ["probe"], "unknown": [], "acknowledge": None,
                         "quick": False, "observations": []}

    def put(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True)

    def run_campaign(self, force=False):
        with patch.dict(CHECKS, probe=self.check), redirect_stdout(io.StringIO()):
            return campaign(self.root, self.cache, self.proposal, self.base, force)

    def test_resume_runs_nothing_and_keeps_original_receipt(self):
        self.assertEqual(self.run_campaign(), 0)
        original = latest(self.cache, "probe")
        self.assertEqual(self.run_campaign(), 0)
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual(report["results"][0]["action"], "reused")
        self.assertEqual(latest(self.cache, "probe"), original)

    def test_run_prints_short_pr_summary(self):
        output = io.StringIO()
        with patch.dict(CHECKS, probe=self.check), redirect_stdout(output):
            self.assertEqual(campaign(self.root, self.cache, self.proposal, self.base), 0)
        self.assertIn("`./verify run`: passed (1/1 checks passed)", output.getvalue())
        self.assertNotIn(str(self.cache), output.getvalue())

    def test_summary_preserves_requested_risks_and_checks(self):
        proposal = plan([], risks=['routes', 'visual'], checks=['swift'], quick=True)
        summary = markdown({'plan': proposal, 'result': 'incomplete', 'results': []})
        self.assertIn('./verify run --quick --risk routes --risk visual --check swift', summary)
        self.assertIn('visual review of affected surfaces', summary)

    def test_dirty_mutation_is_detected_then_repaired_without_hiding_failure(self):
        self.assertEqual(self.run_campaign(), 0)
        self.put("script.py", "assert 1 == 2, 'expected 2, got 1'\n")
        self.assertEqual(self.run_campaign(), 1)
        failed = latest(self.cache, "probe")
        self.assertEqual(failed["result"], "failed")
        self.assertIn("expected 2, got 1", failed["cause"])
        self.assertIn("AssertionError", Path(failed["receipt"]).with_suffix(".log").read_text())
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.base)
        self.put("script.py", "print('passed')\n")
        self.assertEqual(self.run_campaign(), 0)
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual(report["results"][0]["action"], "executed")
        self.assertEqual(read(failed["receipt"])["result"], "failed")

    def test_added_deleted_renamed_and_ignored_fixture_invalidate(self):
        original = stamp(self.root, self.check, {}, self.base)
        self.put("fixtures/new.txt", "a")
        added = stamp(self.root, self.check, {}, self.base)
        self.assertNotEqual(original["key"], added["key"])
        (self.root / "fixtures/new.txt").rename(self.root / "fixtures/renamed.txt")
        renamed = stamp(self.root, self.check, {}, self.base)
        self.assertNotEqual(added["key"], renamed["key"])
        (self.root / "fixtures/renamed.txt").unlink()
        self.assertEqual(original["key"], stamp(self.root, self.check, {}, self.base)["key"])
        self.put(".gitignore", "build/\nfixtures/\n")
        self.put("fixtures/ignored.txt", "important")
        self.assertIn("fixtures/ignored.txt", inputs(self.root, self.check.inputs))

    def test_shared_runner_and_environment_invalidate(self):
        first = stamp(self.root, self.check, {"os": "one"}, self.base)
        self.put("Tests/Verification/evidence.py", "changed shared code")
        second = stamp(self.root, self.check, {"os": "one"}, self.base)
        self.assertNotEqual(first["key"], second["key"])
        self.assertNotEqual(second["key"], stamp(self.root, self.check, {"os": "two"}, self.base)["key"])

    def test_harness_test_edit_does_not_invalidate_unrelated_results(self):
        first = stamp(self.root, self.check, {}, self.base)
        self.put("Tests/Verification/test_selection.py", "new selection test")
        self.assertEqual(first["key"], stamp(self.root, self.check, {}, self.base)["key"])

    def test_targeted_fixture_leaves_an_unrelated_check_valid(self):
        other = Check("other", (sys.executable, "other.py"), ("other.py",), "another scenario")
        self.put("other.py", "print('other')")
        before = stamp(self.root, other, {}, self.base)
        self.put("fixtures/new.txt", "targeted")
        self.assertEqual(before["key"], stamp(self.root, other, {}, self.base)["key"])
        self.put("Tests/Verification/evidence.py", "shared dependency")
        self.assertNotEqual(before["key"], stamp(self.root, other, {}, self.base)["key"])

    def test_scenario_mutation_invalidates_only_its_receipt_then_shared_runner_invalidates_all(self):
        names = ("navigation", "address", "chrome", "keyboard")
        paths = {name: CHECKS[name].command[-1] for name in names}
        for path in paths.values():
            self.put(path, "fixture")
        before = {name: stamp(self.root, CHECKS[name], {}, self.base)["key"] for name in names}
        self.put(paths["navigation"], "changed fixture")
        for name in names:
            key = stamp(self.root, CHECKS[name], {}, self.base)["key"]
            self.assertEqual(key == before[name], name != "navigation")
        self.put("Tests/Bench/suite.py", "changed shared lifecycle")
        for name in names:
            self.assertNotEqual(stamp(self.root, CHECKS[name], {}, self.base)["key"], before[name])

    def test_missing_logs_are_stale(self):
        self.run_campaign()
        receipt = latest(self.cache, "probe")
        Path(receipt["receipt"]).with_suffix(".log").unlink()
        self.assertEqual(validity(receipt, receipt["stamp"]), "stale")

    def test_links_watch_root_markdown_and_deleted_tracked_destinations(self):
        self.put("README.md", "[image](image.png)\n")
        self.put("image.png", "fixture")
        self.git("add", ".")
        before = stamp(self.root, CHECKS["links"], {}, self.base)
        self.put("README.md", "[missing](missing.png)\n")
        self.assertNotEqual(before["key"], stamp(self.root, CHECKS["links"], {}, self.base)["key"])
        self.put("README.md", "[image](image.png)\n")
        (self.root / "image.png").unlink()
        self.assertNotEqual(before["key"], stamp(self.root, CHECKS["links"], {}, self.base)["key"])

    def test_bundle_snapshot_survives_rebuild_but_tampering_invalidates(self):
        self.put("build/Escale.app/Contents/MacOS/Escale", "first binary")
        copied = Path(snapshot_bundle(self.root, self.cache, "one"))
        self.put("build/Escale.app/Contents/MacOS/Escale", "replacement binary")
        second = Path(snapshot_bundle(self.root, self.cache, "one"))
        self.assertNotEqual(copied, second)
        self.assertEqual((second / "Contents/MacOS/Escale").read_text(), "replacement binary")
        self.assertEqual((copied / "Contents/MacOS/Escale").read_text(), "first binary")
        receipt = {"stamp": {"key": "one"}, "result": "passed", "artifacts": {str(copied): fingerprint(copied)}}
        (copied / "Contents/MacOS/Escale").write_text("tampered")
        self.assertEqual(validity(receipt, {"key": "one"}), "stale")

    def test_blocked_not_run_and_interrupted_remain_distinct(self):
        second = Check("next", (sys.executable, "script.py"), ("script.py",), "dependent")
        self.proposal["checks"].append("next")
        with patch.dict(CHECKS, next=second), patch("run.preflight", return_value="missing tool"):
            self.assertEqual(self.run_campaign(), 1)
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual([r["result"] for r in report["results"]], ["blocked", "not-run"])
        self.proposal["checks"] = ["probe"]
        with patch("run.execute", side_effect=KeyboardInterrupt):
            self.assertEqual(self.run_campaign(), 130)
        self.assertEqual(latest(self.cache, "probe")["result"], "interrupted")

    def test_inputs_changed_during_execution_cannot_pass(self):
        self.put("script.py", "from pathlib import Path\nPath('script.py').write_text('changed')\n")
        self.assertEqual(self.run_campaign(), 1)
        self.assertEqual(latest(self.cache, "probe")["result"], "stale")

    def test_force_executes_instead_of_reusing(self):
        self.assertEqual(self.run_campaign(), 0)
        self.assertEqual(self.run_campaign(force=True), 0)
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual(report["results"][0]["action"], "executed")

    def test_report_marks_old_success_stale_after_edit(self):
        self.run_campaign()
        path = sorted((self.cache / "runs").glob("*/report.json"))[-1]
        self.put("script.py", "print('edited after success')\n")
        with patch.dict(CHECKS, probe=self.check):
            report = refreshed(read(path), self.root, self.cache)
        self.assertEqual(report["result"], "incomplete")
        self.assertEqual(report["results"][0]["result"], "stale")
        self.assertEqual(read(path)["result"], "passed")
        summary = markdown(report)
        self.assertIn("probe: stale", summary)
        self.assertNotIn(str(self.cache), summary)
        self.assertNotIn("--export", summary)

    def test_timeout_allows_child_finally(self):
        self.put("script.py", "from pathlib import Path\nimport time\ntry:\n time.sleep(30)\nfinally:\n Path('cleaned').write_text('yes')\n")
        with self.assertRaises(subprocess.TimeoutExpired):
            execute(self.check.command, self.root, self.root / "timeout.log", 0.3)
        self.assertEqual((self.root / "cleaned").read_text(), "yes")

    def test_lock_refuses_overlapping_campaign_or_cleanup(self):
        with locked(self.cache):
            with self.assertRaisesRegex(RuntimeError, "owns this checkout"):
                with locked(self.cache):
                    self.fail("lock admitted a second owner")

    def test_missing_tool_is_blocked_and_optimized_assertions_refused(self):
        with patch("run.shutil.which", return_value=None):
            self.assertIn("missing prerequisite", preflight(self.check, {}))
        with patch.dict(os.environ, PYTHONOPTIMIZE="1"):
            self.assertIn("disables scenario assertions", preflight(self.check, {}))
        with patch("run.sys.platform", "linux"):
            self.assertIn("need macOS", preflight(CHECKS["portable"], {}))

    def test_untracked_whitespace_cannot_pass_before_staging(self):
        self.put("new.py", "value = 1 \n")
        log = self.root / "build/whitespace.log"
        log.parent.mkdir()
        self.assertEqual(untracked_whitespace(self.root, log), 1)
        self.assertIn("trailing whitespace", log.read_text())
        self.put("new.py", "value = 1\n")
        self.assertEqual(untracked_whitespace(self.root, log), 0)

    def test_identical_compiler_inputs_reuse_base_but_dirty_source_forces_build(self):
        self.put("Package.swift", "package fixture")
        self.put("Sources/Foo.swift", "first")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@invalid", "commit", "-qm", "compiler fixture")
        base = self.git("rev-parse", "HEAD").strip()
        self.cache.mkdir(parents=True)
        log = self.cache / "warnings.log"
        commands = []
        def compile(command, root, destination, timeout):
            commands.append(command)
            destination.write_text(str(root / "Sources/Foo.swift") + ":1:2: warning: inherited\n")
            (self.cache / "compiler/candidate").mkdir(exist_ok=True)
            return 0
        self.assertEqual(compare(self.root, self.cache, base, {}, log, compile), 0)
        self.assertEqual(len(commands), 1)
        self.assertIn("Identical compiler inputs", log.read_text())
        self.put("Sources/Foo.swift", "dirty source")
        self.assertEqual(compare(self.root, self.cache, base, {}, log, compile), 0)
        self.assertEqual(len(commands), 2)
        self.assertIn("--scratch-path", commands[-1])


class SideBySideTests(unittest.TestCase):
    """App checks in parallel: overlap, one foreground at a time, stop on failure."""
    put = EvidenceTests.put
    git = EvidenceTests.git

    def setUp(self):
        EvidenceTests.setUp(self)
        # Spans are compared across processes, so they use the wall clock:
        # before Python 3.10, macOS's monotonic clock is per process.
        # The runner wipes each app check's world; a stand-in records nothing.
        self.put("fresh.sh", "#!/bin/sh\nexit 0\n")
        os.chmod(self.root / "fresh.sh", 0o755)
        self.put("app.py", "import os, sys, time\nfrom pathlib import Path\n"
                 "name = sys.argv[1]\nPath(name + '.start').write_text(repr(time.time()))\n"
                 "Path(name + '.lane').write_text(os.environ.get('ESCALE_BACKGROUND', ''))\n"
                 "time.sleep(float(sys.argv[2]))\nPath(name + '.end').write_text(repr(time.time()))\n"
                 "assert sys.argv[3] == 'pass', 'synthetic failure'\n")

    def app(self, name, seconds=0.6, outcome="pass", foreground=False):
        return Check(name, (sys.executable, "app.py", name, str(seconds), outcome), ("app.py",),
                     "synthetic app", "app", foreground=foreground)

    def span(self, name):
        return (float((self.root / f"{name}.start").read_text()), float((self.root / f"{name}.end").read_text()))

    def side_by_side(self, checks, jobs):
        self.proposal["checks"] = [c.name for c in checks]
        with patch.dict(CHECKS, {c.name: c for c in checks}), patch("run.preflight", return_value=None), \
             redirect_stdout(io.StringIO()):
            return campaign(self.root, self.cache, self.proposal, self.base, False, jobs)

    def test_background_checks_overlap_and_are_marked_behind(self):
        self.assertEqual(self.side_by_side([self.app("one"), self.app("two")], 2), 0)
        one, two = self.span("one"), self.span("two")
        self.assertLess(max(one[0], two[0]), min(one[1], two[1]))
        self.assertEqual((self.root / "one.lane").read_text(), "1")
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual([r["name"] for r in report["results"]], ["one", "two"])
        self.assertEqual({r["lane"] for r in report["results"]}, {"background"})

    def test_foreground_checks_never_overlap_but_run_beside_background(self):
        checks = [self.app("front1", foreground=True), self.app("front2", foreground=True),
                  self.app("behind", seconds=1.2)]
        self.assertEqual(self.side_by_side(checks, 3), 0)
        first, second, behind = self.span("front1"), self.span("front2"), self.span("behind")
        self.assertTrue(first[1] <= second[0] or second[1] <= first[0])
        self.assertLess(behind[0], min(first[1], second[1]))
        self.assertEqual((self.root / "front1.lane").read_text(), "")

    def test_a_failure_leaves_peers_to_finish_and_stops_what_follows(self):
        follower = Check("follower", (sys.executable, "script.py"), ("script.py",), "after the app checks")
        checks = [self.app("broken", seconds=0.1, outcome="fail"), self.app("running", seconds=0.8),
                  self.app("later")]
        self.proposal["checks"] = [c.name for c in checks] + ["follower"]
        with patch.dict(CHECKS, {c.name: c for c in checks}, follower=follower), \
             patch("run.preflight", return_value=None), redirect_stdout(io.StringIO()):
            self.assertEqual(campaign(self.root, self.cache, self.proposal, self.base, False, 2), 1)
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual([r["result"] for r in report["results"]], ["failed", "passed", "passed", "not-run"])
        self.assertEqual(report["result"], "incomplete")
        self.assertIn("synthetic failure", latest(self.cache, "broken")["cause"])

    def test_a_stopped_campaign_starts_no_app_check(self):
        self.proposal["unknown"] = ["tools/unmapped.sh"]
        self.assertEqual(self.side_by_side([self.app("one"), self.app("two")], 2), 1)
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual([r["result"] for r in report["results"]], ["not-run", "not-run"])
        self.assertFalse((self.root / "one.start").exists())

    def test_a_check_named_like_the_start_of_another_keeps_only_its_own_evidence(self):
        self.assertEqual(self.side_by_side([self.app("calls", seconds=0.1), self.app("calls-browse", seconds=1)], 2), 0)
        receipt = latest(self.cache, "calls")
        self.assertEqual(sorted(Path(p).name for p in receipt["artifacts"]), ["calls-cleanup.log", "calls.log"])
        report = read(sorted((self.cache / "runs").glob("*/report.json"))[-1])
        self.assertEqual(report["result"], "passed")

    def test_interrupted_parallel_checks_are_never_successes(self):
        checks = [self.app("one", seconds=30), self.app("two", seconds=30)]
        timer = threading.Timer(0.8, lambda: os.kill(os.getpid(), signal.SIGINT))
        timer.start()
        try:
            self.assertEqual(self.side_by_side(checks, 2), 130)
        finally:
            timer.cancel()
        for name in ("one", "two"):
            self.assertEqual(latest(self.cache, name)["result"], "interrupted")
            self.assertFalse((self.root / f"{name}.end").exists())


class SelectionTests(unittest.TestCase):
    def test_new_scenarios_select_their_dependencies_and_common_changes_select_all_app_checks(self):
        for path, expected in (("Tests/Bench/navigation_history.py", "navigation"),
                               ("Sources/Escale/Address/Field.swift", "address"),
                               ("Sources/Escale/Design/Glass.swift", "chrome")):
            proposal = plan([path])
            self.assertEqual(proposal["unknown"], [])
            self.assertIn(expected, proposal["checks"])
            self.assertLess(proposal["checks"].index("bundle"), proposal["checks"].index(expected))
        proposal = plan(["Tests/Bench/suite.py"])
        self.assertTrue(all(name in proposal["checks"] for name, check in CHECKS.items() if check.category == "app"))

    def test_docs_only_has_no_build_and_unknown_tooling_never_silent(self):
        self.assertEqual(plan(["docs/TESTING.md"])["checks"], ["links", "whitespace"])
        proposal = plan(["tools/new-tool.sh"])
        self.assertEqual(proposal["unknown"], ["tools/new-tool.sh"])

    def test_targeted_rule_precedes_broad_and_app_checks(self):
        proposal = plan(["Sources/Escale/Tabs/Icons.swift"])
        self.assertEqual(proposal["checks"][0], "icons")
        self.assertLess(proposal["checks"].index("bundle"), proposal["checks"].index("favicon"))

    def test_visual_and_resources_never_implicitly_pass(self):
        proposal = plan([], risks=["visual", "resources"])
        self.assertEqual(len(proposal["observations"]), 2)

    def test_warning_identity_ignores_line_shift_not_new_diagnostic(self):
        one = warnings("/a/Sources/Escale/Foo.swift:1:2: warning: old\n")
        moved = warnings("/b/Sources/Escale/Foo.swift:12:8: warning: old\n")
        newer = warnings("/a/Sources/Escale/Foo.swift:1:2: warning: new\n")
        self.assertEqual(one, moved)
        self.assertNotEqual(one, newer)

    def test_duplicate_emission_is_ignored_but_another_warning_site_is_not(self):
        line = "/a/Sources/Escale/Foo.swift:1:2: warning: old\n"
        second = "/a/Sources/Escale/Foo.swift:2:2: warning: old\n"
        self.assertEqual(len(warnings(line + line)), 1)
        self.assertEqual(len(warnings(line + second)), 2)
        self.assertIn(("driver", "warning: extra file"), warnings("warning: extra file\n"))


class DiagnosticTests(unittest.TestCase):
    def test_failure_is_collected_before_cleanup_and_cleanup_cannot_mask_it(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bench"))
        import suite
        calls = []
        class Server:
            def shutdown(self):
                calls.append("shutdown")
            def server_close(self):
                calls.append("close")
        def command(*args, **kwargs):
            if "wipe" in args:
                calls.append("wipe")
                raise OSError("cleanup unavailable")
            return ""
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(suite, "SOCKET", Path(directory) / "unused/bench.sock"), \
             patch.object(suite, "command", side_effect=command), \
             patch.object(suite.diagnostics, "capture", side_effect=lambda *a: calls.append("capture")), \
             patch("sys.stderr", new=io.StringIO()):
            with self.assertRaisesRegex(AssertionError, "original expected/actual"):
                with suite.world(Server()):
                    raise AssertionError("original expected/actual")
        self.assertEqual(calls, ["capture", "shutdown", "close", "wipe"])

    def test_occupied_world_is_never_wiped(self):
        import suite
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(suite, "SOCKET", Path(directory) / "bench.sock"), \
             patch.object(suite, "command") as command:
            with self.assertRaisesRegex(AssertionError, "occupied"):
                with suite.world(None):
                    self.fail("entered occupied world")
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
