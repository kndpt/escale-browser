"""Check waiting and world ownership without an app or platform defaults.

An invalid command must fail immediately; only a false observed condition may
be polled. Fake clocks make deadlines deterministic, and cleanup faults must
not erase the assertion that explains the original failure.
"""
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import traceback
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bench"))
import suite


class WaitTests(unittest.TestCase):
    def test_state_transition_returns_complete_observation(self):
        observe = Mock(side_effect=[{"ready": False}, {"ready": True, "page": "kept"}])
        with patch.object(suite.time, "sleep"):
            self.assertEqual(suite.wait_for("page", observe, {"ready": True}),
                             {"ready": True, "page": "kept"})
        self.assertEqual(observe.call_count, 2)

    def test_timeout_retains_expected_and_last_state(self):
        with patch.object(suite.time, "monotonic", side_effect=[0, 0, 0.9, 1]), \
             patch.object(suite.time, "sleep") as sleep:
            with self.assertRaisesRegex(suite.WaitExpired, "expected.*ready.*True.*last observed.*False"):
                suite.wait_for("page", lambda: {"ready": False}, {"ready": True}, seconds=1)
        self.assertAlmostEqual(sleep.call_args.args[0], 0.1)

    def test_errors_are_not_retried_or_replaced_by_timeout(self):
        for error in (AssertionError("command failed"), OSError("socket failed"),
                      ValueError("invalid JSON"), KeyError("missing field"),
                      subprocess.TimeoutExpired("bench", 1)):
            with self.subTest(error=error), patch.object(suite.time, "sleep") as sleep:
                observe = Mock(side_effect=error)
                with self.assertRaises(type(error)) as caught:
                    suite.wait_for("page", observe, {"ready": True})
                self.assertIs(caught.exception, error)
                self.assertEqual(observe.call_count, 1)
                sleep.assert_not_called()

    def test_startup_retries_only_the_known_not_listening_response(self):
        with patch.object(suite, "ask", side_effect=[AssertionError("Escale isn't listening"), {"tabs": []}]), \
             patch.object(suite.time, "sleep"):
            suite.until("socket", suite.probe_ready)
        with patch.object(suite, "ask", side_effect=AssertionError("unknown command")):
            with self.assertRaisesRegex(AssertionError, "unknown command"):
                suite.until("socket", suite.probe_ready)

    def test_missing_observed_field_is_a_schema_failure(self):
        with self.assertRaises(KeyError):
            suite.wait_for("page", lambda: {}, {"ready": True})


class WorldTests(unittest.TestCase):
    def test_commands_never_inherit_a_browser_demo_source(self):
        shell = {"ESCALE_CHROME_SOURCE": "/Users/someone/Chrome", "ESCALE_ARC_SOURCE": "/Users/someone/Arc", "KEPT": "1"}
        with patch.dict(suite.os.environ, shell), patch.object(suite.subprocess, "run") as run, \
             patch.object(suite.diagnostics, "record"):
            run.return_value = subprocess.CompletedProcess([], 0, "", "")
            suite.command("true")
        env = run.call_args.kwargs["env"]
        self.assertEqual([key for key in env if key.endswith("_SOURCE")], [])
        self.assertEqual(env["KEPT"], "1")

    def test_missing_explicit_bundle_never_builds_or_launches_a_fallback(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, ESCALE_TEST_APP=str(Path(directory) / "absent.app")), \
             patch.object(suite, "command") as command:
            with self.assertRaisesRegex(AssertionError, "test app missing"):
                suite.launch()
            command.assert_not_called()

    def test_occupied_world_releases_server_without_touching_app(self):
        server = Mock()
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(suite, "SOCKET", Path(directory) / "bench.sock"), \
             patch.object(suite, "command") as command, \
             patch.object(suite.diagnostics, "capture") as capture:
            with self.assertRaisesRegex(AssertionError, "occupied"):
                with suite.world(server):
                    self.fail("world admitted")
            command.assert_not_called()
            capture.assert_not_called()
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()

    def test_server_failure_still_wipes_owned_world_and_cannot_hide_assertion(self):
        server = Mock()
        server.shutdown.side_effect = OSError("server cleanup failed")
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(suite, "SOCKET", Path(directory) / "unused/bench.sock"), \
             patch.object(suite, "command") as command, \
             patch.object(suite.diagnostics, "capture"), redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(AssertionError, "expected page, got blank"):
                with suite.world(server):
                    raise AssertionError("expected page, got blank")
            self.assertEqual(command.call_args.args[-1], "wipe")
        server.server_close.assert_called_once()

    def test_failure_diagnostics_use_python39_signature_before_owned_cleanup(self):
        original = AssertionError("expected repository suggestion")
        commands = []
        formatter = traceback.format_exception

        def python39(etype, value, tb):
            return formatter(etype, value, tb)

        def observe(arguments, **kwargs):
            commands.append(arguments)
            return subprocess.CompletedProcess(arguments, 0, "{}" if "probe" in arguments else "", "")

        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, ESCALE_DIAGNOSTICS=directory), \
             patch.object(suite, "SOCKET", Path(directory) / "unused/bench.sock"), \
             patch.object(suite, "command") as cleanup, \
             patch.object(suite.diagnostics.subprocess, "run", side_effect=observe), \
             patch.object(suite.diagnostics.traceback, "format_exception", side_effect=python39):
            with self.assertRaises(AssertionError) as caught:
                with suite.world(None):
                    raise original
            self.assertIs(caught.exception, original)
            self.assertIn("AssertionError: expected repository suggestion", (Path(directory) / "failure.txt").read_text())
            self.assertEqual(json.loads((Path(directory) / "identity.json").read_text())["world"], suite.WORLD)
            self.assertTrue((Path(directory) / "tabs.txt").exists())
            self.assertTrue(all("--world" in command and suite.WORLD in command
                                for command in commands if str(suite.ROOT / "bench") in command))
            self.assertEqual(cleanup.call_args.args, (str(suite.ROOT / "fresh.sh"), "wipe"))

    def test_cleanup_failure_cannot_report_success(self):
        server = Mock()
        server.server_close.side_effect = OSError("close failed")
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(suite, "SOCKET", Path(directory) / "unused/bench.sock"), \
             patch.object(suite, "command") as command:
            with self.assertRaisesRegex(OSError, "close failed"):
                with suite.world(server):
                    pass
            self.assertEqual(command.call_args.args[-1], "wipe")

    def test_standalone_scenarios_choose_different_worlds(self):
        directory = str(Path(suite.__file__).parent)
        worlds = []
        for name in ("navigation_history", "address_field", "glass_frame"):
            code = (f"import sys; sys.path.insert(0, {directory!r}); "
                    f"import {name}; import suite; print(suite.WORLD)")
            env = {key: value for key, value in os.environ.items() if key != "ESCALE_VERIFY_WORLD"}
            worlds.append(subprocess.check_output([sys.executable, "-c", code], text=True, env=env).strip())
        self.assertEqual(len(set(worlds)), 3)
        self.assertTrue(all(world.startswith("tests-") for world in worlds))


if __name__ == "__main__":
    unittest.main()
