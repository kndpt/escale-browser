#!/usr/bin/env python3
"""Chrome's automatic route against a synthetic Chrome Stable layout.

The journey is Aside's (migration_aside.run): Chrome only adds its brand and
the folders a Chrome home holds beside its profiles, observed on Chrome 154:
System and Guest profiles with their own files, and non-profile folders. They
must never become sources. Nothing here reads the installed Chrome.
"""
import json
import subprocess
import sys

from migration_aside import run, seed


def chrome(root):
    seed(root, host="chrome.invalid")
    state = json.loads((root / "Local State").read_text())
    # Chrome keeps many more keys per profile; discovery reads only the name.
    for entry in state["profile"]["info_cache"].values():
        entry.update({"active_time": 1790000000.0, "avatar_icon": "chrome://theme/IDR_PROFILE_AVATAR_26", "is_using_default_name": False})
    state["profile"]["last_used"] = "Default"
    (root / "Local State").write_text(json.dumps(state))
    for name in ["System Profile", "Guest Profile"]:
        (root / name).mkdir()
        (root / name / "Bookmarks").write_text((root / "Default" / "Bookmarks").read_text())
    for name in ["Crashpad", "Safe Browsing", "component_crx_cache", "Snapshots"]:
        (root / name).mkdir()


if __name__ == "__main__":
    try:
        run("Chrome", chrome)
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
