"""Keep resource samples in one recoverable archive without stale entries.

These tests exercise the writer without launching Escale or touching a test world.
"""

import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from resource_archive import sample_name, save_sample



class ResourceArchiveTests(unittest.TestCase):
    def test_rerunning_archived_scenarios_keeps_the_entry_count(self):
        scenarios = (("after", "launches", None),
                     ("after", "background-idle", "wakeups"),
                     ("after", "background-idle", "wakeups-repeat"),
                     ("main-20260925", "launches", None),
                     ("main-20260925", "display", None),
                     ("main-20260925", "idle", None),
                     ("main-20260925", "background-idle", None))
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "samples.tar.gz"
            for label, scenario, tag in scenarios:
                save_sample(destination, sample_name(label, scenario, tag), {"first": True})
            with tarfile.open(destination, "r:gz") as archive:
                previous = set(archive.getnames())
            self.assertEqual(len(previous), len(scenarios))
            for label, scenario, tag in scenarios:
                save_sample(destination, sample_name(label, scenario, tag), {"rerun": True})
            with tarfile.open(destination, "r:gz") as archive:
                self.assertEqual(set(archive.getnames()), previous)

    def test_replaces_only_the_selected_sample(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "samples.tar.gz"
            save_sample(destination, "before.json", {"sample": 1})
            save_sample(destination, "after.json", {"sample": 2})
            save_sample(destination, "before.json", {"sample": 3})

            with tarfile.open(destination, "r:gz") as archive:
                self.assertEqual(archive.getnames(), ["after.json", "before.json"])
                self.assertEqual(json.load(archive.extractfile("before.json")), {"sample": 3})
                self.assertEqual(json.load(archive.extractfile("after.json")), {"sample": 2})
            previous = destination.read_bytes()
            save_sample(destination, "before.json", {"sample": 3})
            self.assertEqual(destination.read_bytes(), previous)

    def test_unreadable_archive_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "samples.tar.gz"
            destination.write_bytes(b"not an archive")
            with self.assertRaises(tarfile.TarError):
                save_sample(destination, "before.json", {"sample": 1})
            self.assertEqual(destination.read_bytes(), b"not an archive")

    def test_failed_sample_preserves_previous_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "samples.tar.gz"
            save_sample(destination, "before.json", {"sample": 1})
            previous = destination.read_bytes()
            with self.assertRaises(TypeError):
                save_sample(destination, "after.json", {"unserializable": object()})
            self.assertEqual(destination.read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
