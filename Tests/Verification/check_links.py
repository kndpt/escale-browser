"""Check local Markdown destinations without fetching websites or loading browser data.

Scan tracked and non-ignored Markdown, skipping fenced examples. This small
standard-library check handles inline links, reference definitions and ordinary
GitHub heading anchors; it is not a complete CommonMark renderer. Semantic and
historical-reference review stays with the person or agent changing the docs.
"""

import os
from functools import lru_cache
from pathlib import Path
import re
import subprocess
import sys
import unicodedata
from urllib.parse import unquote, urlsplit


def outside_fences(text):
    lines = []
    fence = None
    for line in text.splitlines():
        match = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if match:
            marker = match[1]
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            lines.append("")
        else:
            lines.append(line if fence is None else "")
    return "\n".join(lines)


def heading_anchors(text):
    anchors = set(re.findall(r'<a\s+(?:name|id)=["\x27]([^"\x27]+)', text))
    counts = {}
    for heading in re.findall(r"^ {0,3}#{1,6}\s+(.+?)\s*#*$", text, re.M):
        heading = re.sub(r"<[^>]*>", "", heading).lower()
        slug = "".join(c for c in heading if unicodedata.category(c)[0] not in "PS" or c in "-_")
        slug = slug.replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        anchors.add(slug + (f"-{count}" if count else ""))
    return anchors


def check(root):
    root = root.resolve()

    @lru_cache(maxsize=None)
    def entries(directory):
        return {entry.name for entry in directory.iterdir()}

    def exact_case(path):
        current = Path(path.anchor)
        for part in path.parts[1:]:
            if part == "..":
                current = current.resolve().parent
                continue
            if part not in entries(current):
                return False
            current /= part
        return True

    listing = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
    ).decode().split("\0")
    documents = {}
    for name in set(listing):
        path = root / name
        if name.endswith(".md") and path.is_file():
            documents[path.resolve()] = outside_fences(path.read_text())
    inline = re.compile(r'\[[^\]\n]*\]\((<[^>]+>|[^\s)]+)(?:\s+"[^"]*")?\)')
    reference = re.compile(r"^ {0,3}\[[^\]\n]+\]:\s*(<[^>]+>|\S+)", re.M)
    errors = []
    count = 0
    for source, text in documents.items():
        for pattern in (inline, reference):
            for match in pattern.finditer(text):
                raw = match[1].strip("<>")
                url = urlsplit(raw)
                if url.scheme or url.netloc:
                    continue
                count += 1
                path = unquote(url.path)
                target = root / path.lstrip("/") if path.startswith("/") else source.parent / path
                if not path:
                    target = source
                reason = None
                if not target.exists():
                    reason = "missing file"
                elif not exact_case(target):
                    reason = "incorrect path capitalization"
                elif url.fragment and target.suffix == ".md":
                    target_text = documents.get(target.resolve())
                    if target_text is None:
                        target_text = outside_fences(target.read_text())
                    if unquote(url.fragment) not in heading_anchors(target_text):
                        reason = "missing anchor"
                if reason:
                    line = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{os.path.relpath(source, root)}:{line}: {reason}: {raw}")
    for error in sorted(errors):
        print(error)
    print(f"{len(documents)} Markdown files, {count} local links, {len(errors)} errors")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(check(Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()))
