"""Change notes, one file each, gathered into CHANGELOG.md at a release.

Every pull request used to add its line at the top of Unreleased, the same
place as every other one, so git reported a conflict on each second merge even
when the code had nothing in common. A note is now its own file in
changelog.d/, which two branches never both touch, and only `release` writes
to CHANGELOG.md. Standard library only, like the rest of the verification.

A note can also be a highlight: a change people will notice first. It opens
with a small header, `highlight:` (a short title) and `plain:` (the same
change in everyday words, for someone who has never read the code), and the
release puts those two above the full list. `body` composes the text of the
GitHub release from NOTES.md and that section, so publish.sh and the tests
read one definition of it.

NOTES.md's first paragraph is the update message the app shows. It must read
in under ten seconds: two sentences and 35 words at most, which `check` and
`body` (so publish.sh) enforce. Older paragraphs below it are history.
"""
from datetime import date
from pathlib import Path
import re
import subprocess

FOLDER = "changelog.d"
NAME = re.compile(r"[a-z0-9][a-z0-9-]*\.md")
HEADING = "## Unreleased"
KEYS = ("highlight", "plain")
TITLE_MAX = 60
HIGHLIGHTS_MAX = 5
# About ten seconds of reading at an ordinary pace.
SUMMARY_WORDS = 35
SUMMARY_SENTENCES = 2


def notes(root):
    """The note files, newest first: by the commit that added them, then name."""
    folder = Path(root) / FOLDER
    files = sorted(p for p in folder.glob("*.md") if p.name != "README.md") if folder.is_dir() else []
    return sorted(files, key=lambda p: (-added(p), p.name))


def added(path):
    """When the note came in: its first commit, or its mtime while untracked."""
    try:
        out = subprocess.run(["git", "log", "--diff-filter=A", "--format=%ct", "--", path.name],
                             cwd=path.parent, capture_output=True, text=True, check=True).stdout.split()
        if out:
            return int(out[-1])
    except (OSError, subprocess.CalledProcessError):
        pass
    return int(path.stat().st_mtime)


def split(path):
    """A note as (header, paragraph, error): the header is {} when there is none."""
    raw = path.read_text().strip()
    if not raw.startswith("---"):
        return {}, raw, None
    lines = raw.splitlines()
    if lines[0].strip() != "---" or "---" not in (l.strip() for l in lines[1:]):
        return {}, raw, "the header opened with --- has no closing ---"
    end = 1 + [l.strip() for l in lines[1:]].index("---")
    header = {}
    for line in lines[1:end]:
        key, colon, value = line.partition(":")
        if not colon or key.strip() not in KEYS or not value.strip():
            return {}, raw, f'header line "{line}" is not {" or ".join(k + ": …" for k in KEYS)}'
        header[key.strip()] = value.strip()
    return header, "\n".join(lines[end + 1:]).strip(), None


def text(path):
    """A note's line: its wrapped paragraph joined, without a list marker."""
    return " ".join(split(path)[1].split())


def highlights(files):
    """The notes that carry a header, in the order given."""
    return [p for p in files if split(p)[0]]


def problems(root):
    """What keeps the notes or CHANGELOG.md from being gathered, one line each."""
    found = []
    files = notes(root)
    for path in files:
        header, body, error = split(path)
        if not NAME.fullmatch(path.name):
            found.append(f"{FOLDER}/{path.name}: name it with lowercase words and dashes, like reading-line-page.md")
        if error:
            found.append(f"{FOLDER}/{path.name}: {error}")
        elif header and set(header) != set(KEYS):
            found.append(f"{FOLDER}/{path.name}: a highlight needs both highlight: and plain:")
        elif len(header.get("highlight", "")) > TITLE_MAX:
            found.append(f"{FOLDER}/{path.name}: the highlight title is over {TITLE_MAX} characters")
        if not body:
            found.append(f"{FOLDER}/{path.name}: empty")
        elif re.search(r"\n\s*\n", body):
            found.append(f"{FOLDER}/{path.name}: one paragraph only, no blank line")
        elif body[0] in "-*#":
            found.append(f"{FOLDER}/{path.name}: write the sentence itself, without a list marker or heading")
    if len(highlights(files)) > HIGHLIGHTS_MAX:
        found.append(f"{FOLDER}: {len(highlights(files))} highlights, at most {HIGHLIGHTS_MAX} — the rest is what changed")
    log = (Path(root) / "CHANGELOG.md").read_text().splitlines()
    if log.count(HEADING) != 1:
        found.append(f'CHANGELOG.md: needs exactly one "{HEADING}" heading')
    return found


def release(root, version, day=None):
    """Turn Unreleased and the notes into the section of `version`."""
    if problems(root):
        raise SystemExit("\n".join(problems(root)))
    files = notes(root)
    log = Path(root) / "CHANGELOG.md"
    lines = log.read_text().splitlines()
    start = lines.index(HEADING)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    kept = [l for l in lines[start + 1:end]]
    while kept and not kept[0].strip():
        kept.pop(0)
    while kept and not kept[-1].strip():
        kept.pop()
    bullets = ["- " + text(p) for p in files] + kept
    if not bullets:
        raise SystemExit("nothing to release: no note in changelog.d/ and nothing under Unreleased")
    heading = f"## {version} — {day or date.today().isoformat()}"
    body = bullets
    top = highlights(files)
    if top:
        body = ["### Highlights", ""] + [f"- **{split(p)[0]['highlight']}.** {split(p)[0]['plain']}" for p in top] \
            + ["", "### What changed", ""] + bullets
    section = [HEADING, "", heading, ""] + body + [""]
    log.write_text("\n".join(lines[:start] + section + lines[end:]) + "\n")
    for p in files:
        p.unlink()
    return len(files)


def summary(root):
    """NOTES.md's first paragraph, joined on one line; empty when there is none."""
    paragraph = []
    for line in (Path(root) / "NOTES.md").read_text().splitlines():
        if line.strip():
            paragraph.append(line.strip())
        elif paragraph:
            break
    return " ".join(paragraph)


def summary_problems(root):
    """What makes the update message too long to read at a glance, one line each."""
    text = summary(root)
    if not text:
        return ["NOTES.md: no first paragraph, the update message"]
    found = []
    words = len(text.split())
    if words > SUMMARY_WORDS:
        found.append(f"NOTES.md: the first paragraph has {words} words, at most {SUMMARY_WORDS} — it is the update message, read in seconds")
    sentences = len(re.findall(r"[.!?](?=\s|$)", text))
    if sentences > SUMMARY_SENTENCES:
        found.append(f"NOTES.md: the first paragraph has {sentences} sentences, at most {SUMMARY_SENTENCES}")
    return found


def body(root, version):
    """The GitHub release text: NOTES.md's first paragraph, then the version's
    section, whose Highlights and What changed headings become the release's own."""
    root = Path(root)
    paragraph = summary(root)
    lines = (root / "CHANGELOG.md").read_text().splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith("## ") and l.split()[1:2] == [version]), None)
    if start is None:
        raise SystemExit(f'CHANGELOG.md has no section "## {version}" — give Unreleased its number and date first')
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    section = "\n".join(lines[start + 1:end]).strip()
    if not paragraph:
        raise SystemExit("NOTES.md has no first paragraph to summarise the release")
    if summary_problems(root):
        raise SystemExit("\n".join(summary_problems(root)))
    if not section:
        raise SystemExit(f'CHANGELOG.md\'s "## {version}" section is empty — a release needs its changes listed')
    if re.search(r"^### ", section, re.M):
        section = re.sub(r"^### ", "## ", section, flags=re.M)
    else:
        section = "## What changed\n\n" + section
    return paragraph + "\n\n" + section + "\n"


def main(argv):
    root = Path(__file__).resolve().parents[2]
    command = argv[0] if argv else "list"
    if command == "list":
        for p in notes(root):
            print(f"- {text(p)}")
        return 0
    if command == "check":
        found = problems(root) + summary_problems(root)
        print("\n".join(found) if found else f"changelog: {len(notes(root))} note(s), all well formed")
        return 1 if found else 0
    if command == "release" and len(argv) in (2, 3):
        count = release(root, argv[1], argv[2] if len(argv) == 3 else None)
        print(f"CHANGELOG.md: {argv[1]} section written from {count} note(s); commit the result")
        return 0
    if command == "body" and len(argv) == 2:
        print(body(root, argv[1]), end="")
        return 0
    print("usage: ./changelog [list | check | release VERSION [YYYY-MM-DD] | body VERSION]")
    return 2
