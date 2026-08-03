#!/bin/sh
# atom-make.sh - unpack the atom image once, into a directory bwrap can bind.
#
# atom is a complete little Linux filesystem - busybox, gcc+binutils, git, ssh, sqlite,
# curl - that runs inside bubblewrap as an isolated service. The image ships as
# ONE file, /atom-rootfs.tar.gz.
#
# bwrap cannot consume an archive. There is no --image, no --squashfs and no
# generic --mount type=, so nothing can ever be what bwrap binds directly. Unpack
# it once to a directory and bind THAT: because bwrap --ro-bind shares pages
# rather than copying them, one unpacked tree backs any number of concurrent
# containers at no extra memory. Unpack once, bind many.
#
# Run this once. The other atom-*.sh scripts assume ~/atom already exists.
set -eu

IMAGE="${ATOM_IMAGE:-/atom-rootfs.tar.gz}"
DEST="${ATOM_DEST:-$HOME/atom}"

if [ ! -f "$IMAGE" ]; then
    echo "atom-make: no image at $IMAGE" >&2
    exit 1
fi

# Already unpacked? Say so rather than redoing 95M of work.
if [ -x "$DEST/bin/busybox" ]; then
    echo "atom-make: $DEST is already unpacked"
    echo "           delete it first to start over:  rm -rf $DEST"
    exit 0
fi

echo "atom-make: unpacking $IMAGE -> $DEST"
mkdir -p "$DEST"

# -p is LOAD-BEARING, not decoration.
#
# Without it tar restores every directory as 0755, and $DEST/tmp comes out 0755
# instead of 1777 - a /tmp that no unprivileged process can write. There is no
# error message for this. You get a confusing failure from whatever program you
# tried to run next, with nothing pointing at the real cause.
#
# Verified by round-trip test in pack_atom_image.sh, which extracts the archive
# and diffs the whole tree against the original - types, modes, symlink targets,
# hardlink groupings and per-file hashes. The mode check is what catches this.
tar -xzpf "$IMAGE" -C "$DEST"

# Assert rather than assume. A half-unpacked tree produces a container that fails
# in a way that looks like a bwrap problem.
for required in bin/busybox bin/sh lib64/ld-linux-x86-64.so.2 usr/lib64/libc.so.6; do
    if [ ! -e "$DEST/$required" ]; then
        echo "atom-make: unpack finished but $DEST/$required is missing." >&2
        echo "           The archive looks truncated or the extraction failed." >&2
        exit 1
    fi
done

# The interpreter check above matters more than it looks: atom ships lib64 as a
# REAL directory containing a real ld-linux, not as a symlink to usr/lib64. That
# is why the bwrap command needs no --symlink lib64 line.
#
# DELIBERATELY no chmod on $DEST/tmp here. An earlier version of this file ended
# with `chmod 0755 "$DEST/tmp"`, which silently undid the one thing -p is for:
# the archive stores /tmp as 1777, -p restores it as 1777, and the chmod then
# flattened it back to 0755 so that no unprivileged process could write to it
# again. If you ever find /tmp unwritable inside a container, this is the line to
# look at first.
#
# Verify it rather than assume:
if [ "$(stat -c %a "$DEST/tmp" 2>/dev/null || echo 000)" != "1777" ]; then
    echo "atom-make: WARNING - $DEST/tmp is not 1777 (got $(stat -c %a "$DEST/tmp" 2>/dev/null || echo '?'))." >&2
    echo "            Anything in the container that writes to /tmp will fail." >&2
    echo "            Fix with:  chmod 1777 $DEST/tmp" >&2
fi

echo "atom-make: done. $DEST is $(du -sh "$DEST" | cut -f1)"
echo
echo "Next:"
echo "  ~/scripts/atom-shell.sh          interactive shell in a container"
echo "  ~/scripts/atom-ssh.sh            container you can ssh into"
echo "  ~/scripts/atom-web.sh            container serving HTTP"
echo "  ~/scripts/atom-nested.sh         a container inside a container"
