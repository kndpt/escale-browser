#!/usr/bin/env python3
"""Foreign-label collision regression using random, app-owned keychain fixtures.

The bench creates the foreign-looking item itself in an admitted test world,
checks an import collision and removes exactly that item. No personal item is
queried and no secret is returned. The existing harness owns launch and cleanup.
"""
from datetime import datetime, timedelta, timezone
import json
import socket
import subprocess
import sys
import suite as h


def main():
    if h.SOCKET.parent.exists():
        raise AssertionError("refusing to reuse occupied world")
    try:
        h.command(str(h.ROOT / "fresh.sh"), "wipe")
        h.command("defaults", "write", h.SUITE, "bench", "-bool", "YES")
        h.command("defaults", "write", h.SUITE, "welcomed", "-bool", "YES")
        checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S +0000")
        h.command("defaults", "write", h.SUITE, "update.checked", "-date", checked)
        h.launch()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(20)
            connection.connect(str(h.SOCKET))
            connection.sendall(b'{"do":"migration-keychain"}\n')
            result = b""
            while part := connection.recv(4096):
                result += part
        result = json.loads(result)
        h.require("foreign collision reports failure", result.get("foreignCollisionFailed"), True)
        h.require("foreign item stays unchanged", result.get("foreignItemUnchanged"), True)
        print("ok: foreign-label keychain collision fails without changing the existing item")
    finally:
        h.command(str(h.ROOT / "fresh.sh"), "wipe")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
