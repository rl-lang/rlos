#!/usr/bin/env python3
"""Capture the guest framebuffer from a running rlOS QEMU, as a PNG.

Why this exists: testing the X session needs to see the framebuffer, but QEMU's
GUI backends (gtk, sdl) are optional build-time dependencies. A build without
them cannot open a window at all, and refusing to start looked like a broken
ISO. VNC works, but every VNC viewer in common use pulls in GTK or Qt, which is
a lot of packages to install just to look at a screenshot.

QMP's screendump needs nothing installed at all, so this is the lowest-friction
way to confirm what the guest is actually drawing. It also works on a build that
does have a GUI backend, which makes it the better regression check anyway: an
automated image of the framebuffer rather than somebody's eyeballs.

Usage:
    ./shot.sh [out.png] [socket]

Defaults to qmp.sock next to this script, which is what run_qemu_uefi.sh opens.
"""

import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def fail(msg):
    print(f"shot.sh: {msg}", file=sys.stderr)
    sys.exit(1)


def connect(sock_path, timeout=10.0):
    """QMP needs a greeting, then a capabilities handshake."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(timeout)
            s.connect(sock_path)
            f = s.makefile("rwb")
            f.readline()  # greeting
            cmd(f, "qmp_capabilities")
            return s, f
        except (OSError, ValueError) as exc:
            last = exc
            time.sleep(0.5)
    fail(f"could not talk to QMP at {sock_path}: {last}")


def cmd(f, name, **args):
    f.write(json.dumps({"execute": name, **({"arguments": args} if args else {})}).encode() + b"\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            fail("QMP connection closed unexpectedly")
        r = json.loads(line)
        if "error" in r:
            fail(f"{name} failed: {r['error'].get('desc', r['error'])}")
        if "return" in r:
            return r["return"]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "screenshot.png")
    sock_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "qmp.sock")

    if not os.path.exists(sock_path):
        fail(f"no QMP socket at {sock_path} - is QEMU running? (./run_qemu_uefi.sh --video)")

    s, f = connect(sock_path)
    try:
        # screendump writes on the host side, so give it an absolute path.
        out = os.path.abspath(out)
        cmd(f, "screendump", filename=out)
    finally:
        s.close()

    if not os.path.exists(out):
        fail("screendump reported success but wrote no file")
    size = os.path.getsize(out)
    print(f"wrote {out} ({size} bytes)")


if __name__ == "__main__":
    main()
