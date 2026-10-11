"""Reject baseline worlds whose bench socket cannot exist on macOS, and keep
an idle interval going when a WebKit helper exits during it.

The collector accepts descriptive revision labels, but validates the complete
generated world because scenario suffixes and the user's home path share the
same fixed sockaddr_un budget.
"""

import os
import subprocess
import unittest

from resource_baseline import counters, probe_socket, SUN_PATH_ROOM


class ResourceBaselineTests(unittest.TestCase):
    def test_current_reference_world_fits(self):
        path = probe_socket("resource-main-20260925-bg")
        self.assertLess(len(os.fsencode(path)), SUN_PATH_ROOM)

    def test_full_commit_label_is_rejected_before_launch(self):
        world = f"resource-{'a' * 40}-launch-0"
        with self.assertRaisesRegex(ValueError, "socket path too long"):
            probe_socket(world)

    def test_an_exited_process_has_no_counters(self):
        live = counters(os.getpid())
        self.assertIsNotNone(live)
        self.assertGreaterEqual(live[0], 0)
        self.assertIn("interrupt", live[1])
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.assertIsNone(counters(gone.pid))


if __name__ == "__main__":
    unittest.main()
