"""Change notes stay one paragraph each, and a release gathers them in order."""
import os
import tempfile
import unittest
from pathlib import Path

import fragments

LOG = """# Changelog

## Unreleased

- Kept line from before.

## 0.1 — 2026-09-29

First.
"""


class FragmentTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / "changelog.d").mkdir()
        (self.root / "CHANGELOG.md").write_text(LOG)

    def tearDown(self):
        self.dir.cleanup()

    def note(self, name, body, age=0):
        path = self.root / "changelog.d" / name
        path.write_text(body)
        os.utime(path, (1_000_000 - age, 1_000_000 - age))

    def test_well_formed_notes_pass(self):
        self.note("one.md", "A line (#1).\n")
        self.assertEqual(fragments.problems(self.root), [])

    def test_each_defect_is_named(self):
        self.note("Bad Name.md", "Fine.")
        self.note("empty.md", "  \n")
        self.note("two.md", "First.\n\nSecond.")
        self.note("bullet.md", "- Already a list item.")
        found = "\n".join(fragments.problems(self.root))
        for word in ("Bad Name.md: name it", "empty.md: empty", "two.md: one paragraph", "bullet.md: write the sentence"):
            self.assertIn(word, found)

    def test_changelog_needs_one_unreleased_heading(self):
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.1\n")
        self.assertIn("exactly one", fragments.problems(self.root)[0])

    def test_readme_is_not_a_note(self):
        (self.root / "changelog.d" / "README.md").write_text("# Rules")
        self.assertEqual(fragments.notes(self.root), [])

    def test_release_gathers_notes_newest_first_above_what_stood_there(self):
        self.note("older.md", "Older change.", age=100)
        self.note("newer.md", "Newer change\nwrapped over two lines.", age=10)
        self.assertEqual(fragments.release(self.root, "0.2", "2026-10-01"), 2)
        log = (self.root / "CHANGELOG.md").read_text()
        self.assertEqual(log, """# Changelog

## Unreleased

## 0.2 — 2026-10-01

- Newer change wrapped over two lines.
- Older change.
- Kept line from before.

## 0.1 — 2026-09-29

First.
""")
        self.assertEqual(fragments.notes(self.root), [])
        self.assertEqual(fragments.problems(self.root), [])

    def test_release_refuses_when_there_is_nothing_to_say(self):
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n\n## 0.1 — 2026-09-29\n")
        with self.assertRaises(SystemExit):
            fragments.release(self.root, "0.2")

    def test_release_refuses_an_ill_formed_note_and_leaves_files_alone(self):
        self.note("two.md", "First.\n\nSecond.")
        with self.assertRaises(SystemExit):
            fragments.release(self.root, "0.2")
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), LOG)
        self.assertEqual(len(fragments.notes(self.root)), 1)

    def test_a_highlight_goes_above_the_full_list(self):
        self.note("hot.md", "---\nhighlight: Bearings finds by words\nplain: Type a few words and find the page.\n---\nThe long, exact sentence (#2).", age=10)
        self.note("plain.md", "A smaller change.", age=100)
        self.assertEqual(fragments.problems(self.root), [])
        fragments.release(self.root, "0.2", "2026-10-01")
        log = (self.root / "CHANGELOG.md").read_text()
        self.assertIn("""## 0.2 — 2026-10-01

### Highlights

- **Bearings finds by words.** Type a few words and find the page.

### What changed

- The long, exact sentence (#2).
- A smaller change.
- Kept line from before.
""", log)
        self.assertEqual(fragments.problems(self.root), [])

    def test_a_note_header_is_checked(self):
        self.note("half.md", "---\nhighlight: Only a title\n---\nSentence.")
        self.note("open.md", "---\nhighlight: Never closed\nSentence.")
        self.note("odd.md", "---\nhighlight: T\nplain: P\nbold: yes\n---\nSentence.")
        self.note("long.md", "---\nhighlight: " + "x" * 61 + "\nplain: P\n---\nSentence.")
        self.note("none.md", "---\nhighlight: T\nplain: P\n---\n")
        found = "\n".join(fragments.problems(self.root))
        for word in ("half.md: a highlight needs both", "open.md: the header", 'odd.md: header line "bold: yes"',
                     "long.md: the highlight title is over", "none.md: empty"):
            self.assertIn(word, found)

    def test_at_most_five_highlights(self):
        for i in range(6):
            self.note(f"hot-{i}.md", f"---\nhighlight: T{i}\nplain: P\n---\nSentence {i}.")
        self.assertIn("6 highlights, at most 5", "\n".join(fragments.problems(self.root)))

    def test_body_is_the_summary_then_the_section(self):
        (self.root / "NOTES.md").write_text("First line\nof the summary.\n\nOlder paragraph.\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n\n## 0.2 — 2026-10-01\n\n- One.\n- Two.\n\n## 0.1 — 2026-09-29\n\nFirst.\n")
        self.assertEqual(fragments.body(self.root, "0.2"),
                         "First line of the summary.\n\n## What changed\n\n- One.\n- Two.\n")

    def test_body_promotes_highlights_and_what_changed(self):
        (self.root / "NOTES.md").write_text("Summary.\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.2 — 2026-10-01\n\n### Highlights\n\n- **A.** B.\n\n### What changed\n\n- One.\n\n## 0.1 — x\n")
        self.assertEqual(fragments.body(self.root, "0.2"),
                         "Summary.\n\n## Highlights\n\n- **A.** B.\n\n## What changed\n\n- One.\n")

    def test_body_refuses_an_empty_section(self):
        (self.root / "NOTES.md").write_text("Summary.\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.2 — x\n\n## 0.1 — y\n\nFirst.\n")
        with self.assertRaises(SystemExit):
            fragments.body(self.root, "0.2")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.2 — x\n")
        with self.assertRaises(SystemExit):
            fragments.body(self.root, "0.2")

    def test_body_refuses_a_missing_section_or_summary(self):
        (self.root / "NOTES.md").write_text("Summary.\n")
        with self.assertRaises(SystemExit):
            fragments.body(self.root, "0.2")
        (self.root / "NOTES.md").write_text("\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.2 — x\n\n- One.\n")
        with self.assertRaises(SystemExit):
            fragments.body(self.root, "0.2")

    def test_the_update_message_reads_in_seconds(self):
        (self.root / "NOTES.md").write_text("Escale 0.2: one change.\nAnd a second.\n\n" + "Older and long. " * 40 + "\n")
        self.assertEqual(fragments.summary_problems(self.root), [])
        (self.root / "NOTES.md").write_text(" ".join(["word"] * 36) + ".\n")
        self.assertIn("36 words", fragments.summary_problems(self.root)[0])
        (self.root / "NOTES.md").write_text("One. Two. Three.\n")
        self.assertIn("3 sentences", fragments.summary_problems(self.root)[0])
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.2 — x\n\n- One.\n")
        with self.assertRaises(SystemExit):
            fragments.body(self.root, "0.2")


if __name__ == "__main__":
    unittest.main()
