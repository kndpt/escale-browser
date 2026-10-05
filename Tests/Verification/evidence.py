"""Small immutable receipts: byte contents, not Git HEAD, decide reuse.

Only named inputs and relevant environment values are retained. Receipts and
full logs live in ignored build/verification; missing or changed evidence is
stale. Atomic replacement keeps an interrupted write from becoming a success.
"""
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

from catalog import ENGINE


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def fingerprint(path):
    path = Path(path)
    if not path.exists():
        return None
    if path.is_dir():
        return digest({str(p.relative_to(path)): {"sha256": fingerprint(p), "executable": os.access(p, os.X_OK)}
                       for p in sorted(path.rglob("*")) if p.is_file()})
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def read(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def inventory(root):
    return sorted(set(subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root).decode().strip("\0").split("\0")) - {""})


def inputs(root, patterns):
    names = inventory(root)
    # Glob additionally includes an explicitly declared ignored fixture/profile.
    selected = {n for n in names if any(fnmatch.fnmatch(n, p) for p in patterns + ENGINE)}
    for pattern in patterns + ENGINE:
        if pattern != "**" and not pattern.startswith("**/"):
            for match in root.glob(pattern):
                selected.update(str(p.relative_to(root)) for p in
                                (match.rglob("*") if match.is_dir() else (match,)) if p.is_file())
    selected = {n for n in selected if "__pycache__" not in Path(n).parts}
    return {n: {"sha256": fingerprint(root / n),
                "executable": os.access(root / n, os.X_OK)} for n in sorted(selected)}


def environment(mac=False):
    value = {"os": platform.platform(), "machine": platform.machine(), "python": sys.version,
             "tools": {n: shutil.which(n) for n in ("python3", "git")},
             "variables": {n: os.environ.get(n) for n in
                           ("DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS", "SWIFT_EXEC", "CC", "CXX",
                            "MACOSX_DEPLOYMENT_TARGET", "PYTHONOPTIMIZE", "PYTHONPATH")}}
    if mac:
        for name, command in (("swift", ["swift", "--version"]),
                              ("sdk", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
                              ("developer", ["xcode-select", "-p"]), ("os_build", ["sw_vers"])):
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=15)
                value[name] = {"exit": result.returncode, "text": result.stdout + result.stderr}
            except (OSError, subprocess.TimeoutExpired) as error:
                value[name] = {"unavailable": str(error)}
    return value


def stamp(root, check, env, base, bundle=None):
    manifest = inputs(root, check.inputs)
    value = {"checkout": str(root.resolve()), "inputs": manifest, "environment": env, "command": check.command,
             "category": check.category}
    if check.name in ("warnings", "whitespace"):
        value["base"] = base
    if check.name in ("links", "whitespace"):
        value["inventory"] = inventory(root)
    if check.category == "app":
        value["bundle"] = bundle
    return {"key": digest(value), **value}


def validity(receipt, current):
    if not receipt:
        return "not-run"
    if receipt.get("stamp", {}).get("key") != current["key"]:
        return "stale"
    for name, expected in receipt.get("artifacts", {}).items():
        if fingerprint(name) != expected:
            return "stale"
    if receipt["result"] == "running":
        return "interrupted"
    return receipt["result"]


def changes(receipt, current):
    if not receipt:
        return []
    old = receipt.get("stamp", {})
    names = sorted(set(old.get("inputs", {})) | set(current["inputs"]))
    reasons = [n for n in names if old.get("inputs", {}).get(n) != current["inputs"].get(n)]
    reasons += [key for key in ("checkout", "environment", "command", "base", "bundle", "inventory")
                if old.get(key) != current.get(key)]
    if not reasons and validity(receipt, current) == "stale":
        reasons = ["missing or changed evidence"]
    return reasons


def latest(cache, name):
    # Never fall back to an earlier success after an observed failure.
    matches = sorted((cache / "runs").glob(f"*/{name}.json"))
    return read(matches[-1]) if matches else None
