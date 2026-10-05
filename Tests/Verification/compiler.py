"""Compare complete compiler diagnostics, never an empty incremental log.

Clean builds use private scratch directories. The base inventory is cached by
revision/toolchain; identical compiler inputs share its complete diagnostics.
This intentionally costs a clean build on changed app inputs, only at delivery.
"""
import re
from collections import Counter
import shutil
import subprocess

from evidence import digest, fingerprint, read, write


class BaseBuildBlocked(RuntimeError):
    """The reference could not compile, so comparison is unavailable."""


def compile_inputs(root):
    """All app sources/resources and the package; tests cannot add app warnings."""
    paths = [root / "Package.swift", *sorted((root / "Sources").rglob("*"))]
    return {str(p.relative_to(root)): fingerprint(p) for p in paths if p.is_file()}


def warnings(text):
    # Swift may print one location several times while compiling the module.
    # Deduplicate those emissions, not distinct locations of the same warning.
    locations = set(re.findall(r"^(.+?):(\d+):(\d+): warning: (.+)$", text, re.M))
    result = [(path.rsplit("/Sources/", 1)[-1], message) for path, _, _, message in locations]
    result += [("driver", line.strip()) for line in sorted(set(text.splitlines()))
               if line.startswith("warning:")]
    return sorted(result)


def compare(root, cache, base, env, log, execute):
    area = cache / "compiler"
    area.mkdir(exist_ok=True)
    # Cache raw diagnostics, then parse them with the current comparator. A
    # parser improvement does not require compiling identical base sources again.
    key = digest({"base": base, "environment": env})
    saved = area / (key + ".json")
    baseline = read(saved)
    base_log = area / (key + ".log")
    if not baseline or baseline.get("log_hash") != fingerprint(base_log):
        source = area / "base"
        shutil.rmtree(source, ignore_errors=True)
        source.mkdir()
        archive = area / "base.tar"
        with archive.open("wb") as output:
            subprocess.run(["git", "archive", base], cwd=root, stdout=output, check=True)
        subprocess.run(["tar", "-xf", str(archive), "-C", str(source)], check=True)
        archive.unlink()
        result = execute(["swift", "build"], source, base_log, 600)
        if result:
            log.write_text("Base build failed; diagnostic comparison unavailable.\n" + base_log.read_text())
            raise BaseBuildBlocked("base build failed; see the retained compiler log")
        baseline = {"base": base, "environment": env, "log_hash": fingerprint(base_log),
                    "inputs": compile_inputs(source)}
        write(saved, baseline)
        shutil.rmtree(source)
    shutil.copy2(base_log, log.with_name("warnings-base.log"))
    baseline_warnings = warnings(base_log.read_text())
    if baseline.get("inputs") == compile_inputs(root):
        log.write_text(base_log.read_text() + "\nIdentical compiler inputs: reused complete base diagnostics.\n"
                       + f"Base warnings: {len(baseline_warnings)}; candidate: {len(baseline_warnings)}\n")
        return 0
    scratch = area / "candidate"
    shutil.rmtree(scratch, ignore_errors=True)
    result = execute(["swift", "build", "--scratch-path", str(scratch)], root, log, 600)
    if result:
        return result
    candidate = warnings(log.read_text())
    introduced = sorted((Counter(candidate) - Counter(baseline_warnings)).elements())
    with log.open("a") as output:
        output.write(f"\nBase warnings: {len(baseline_warnings)}; candidate: {len(candidate)}\n")
        for path, message in introduced:
            output.write(f"NEW WARNING: {path}: {message}\n")
    shutil.rmtree(scratch)
    return 1 if introduced else 0
