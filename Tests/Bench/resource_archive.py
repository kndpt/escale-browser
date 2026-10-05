"""Keep named raw resource samples in one compact local file.

Each scenario replaces its named entry after success. Rebuilding into a temporary
archive preserves the previous measurements if serialization or writing fails.
The gzip header and tar metadata are fixed so rerunning an identical sample
does not produce a spurious change in Git.
"""

import gzip
import io
import json
import os
from pathlib import Path
import re
import tarfile
import tempfile


def sample_name(label, scenario, tag):
    """Keep the collector's names aligned with the versioned baseline archive."""
    if scenario == "core":
        stem = label
    elif scenario == "launches":
        stem = f"{label}-launch-process"
    elif scenario == "background-idle" and tag is not None and tag.startswith("wakeups"):
        stem = f"{label}-background"
    else:
        stem = f"{label}-{scenario}"
    return stem + (f"-{tag}" if tag else "") + ".json"


def save_sample(destination, name, result):
    """Replace one sample only after the complete archive is written."""
    entries = {}
    if destination.exists():
        with tarfile.open(destination, "r:gz") as source:
            for member in source:
                if not member.isfile() or not re.fullmatch(r"[a-z0-9-]+\.json", member.name):
                    raise RuntimeError(f"unexpected archive member: {member.name}")
                if member.name in entries:
                    raise RuntimeError(f"duplicate archive member: {member.name}")
                stream = source.extractfile(member)
                if stream is None:
                    raise RuntimeError(f"unreadable archive member: {member.name}")
                entries[member.name] = stream.read()
    entries[name] = (json.dumps(result, indent=2) + "\n").encode()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", dir=destination.parent,
                                         prefix=f".{destination.name}.", suffix=".tmp",
                                         delete=False) as output:
            temporary = Path(output.name)
            with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode="w|") as archive:
                    for entry_name, data in sorted(entries.items()):
                        member = tarfile.TarInfo(entry_name)
                        member.size = len(data)
                        member.mode = 0o644
                        archive.addfile(member, io.BytesIO(data))
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
