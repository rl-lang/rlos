#!/bin/sh
# atom-nested.sh - a bubblewrap container inside a bubblewrap container.
#
# atom ships its own bwrap and libcap precisely so this is possible. The image
# has no X server, no display and no /dev from the host: a nested desktop is not
# a thing. What IS a thing is a nested sandbox, which is the part that actually
# isolates anything.
#
# It works because user namespaces nest. The outer container's root owns nothing
# outside its namespace, so it is able to create a further namespace inside
# itself; the kernel does not require a process to be real root to unshare.
# Both kernels ship CONFIG_USER_NS=y, which is the hard prerequisite - without it
# bwrap refuses to start at all and there is nothing to nest.
#
# What this demonstrates that the outer one does not: the inner container has its
# own /var/lib/atom, its own /tmp, and its own pid namespace, so it cannot see or
# touch the outer container's state even though it shares the outer's filesystem
# view of everything else.
set -eu

ROOT="${ATOM_DEST:-$HOME/atom}"
OUTER_DATA="${ATOM_DATA:-$HOME/atom-data}"
# The inner container binds a path expressed INSIDE THE OUTER CONTAINER, and that
# is the whole subtlety of this script.
#
# The inner bwrap runs inside the outer container, so every path it is given -
# including --bind sources - is resolved in the outer container's filesystem, not
# on the host. The outer container's / is the read-only atom image, so a host path
# like /home/you/atom-nested-data does not exist in there and this fails:
#
#   bwrap: Can't find source path /home/you/atom-nested-data: No such file or directory
#
# ...even though the directory exists on the host. It is not visible from in there.
#
# The one host path visible inside the outer container is whatever the outer
# container itself binds, which is $OUTER_DATA at /var/lib/atom. So the inner
# container's bind source is /var/lib/atom/inner - a path in the outer container's
# namespace - and the host side of that is $OUTER_DATA/inner, created below.
#
# This does not weaken what the demo shows. Inside the inner container,
# /var/lib/atom is bound to the inner directory alone, so it holds only the inner
# container's files and none of the outer's.
INNER_SRC="/var/lib/atom/inner"

[ -x "$ROOT/bin/busybox" ] || {
    echo "atom-nested: $ROOT is not unpacked - run ~/scripts/atom-make.sh first" >&2
    exit 1
}
[ -x "$ROOT/bin/bwrap" ] || {
    echo "atom-nested: $ROOT/bin/bwrap missing - this atom was built without it" >&2
    exit 1
}

# The host side of the inner bind: a subdirectory of the outer's data, because
# /var/lib/atom is the only host-backed path visible inside the outer container.
mkdir -p "$OUTER_DATA/inner"

# The inner container mounts the SAME unpacked image, read-only, so this needs no
# second unpack - which is the whole point of unpack-once-bind-many.
echo "atom-nested: outer data $OUTER_DATA"
echo "             inner data $OUTER_DATA/inner  (inside the outer's bind; the inner still cannot see the outer's files)"
echo

# Annotated above, not inline: a comment inside a backslash-continued command
# truncates it silently and bwrap answers by printing its help.
#
# The outer container mounts the same unpacked image, read-only, so nesting needs
# no second unpack - which is the whole point of unpack-once-bind-many.
exec bwrap \
    --ro-bind "$ROOT" / \
    --proc /proc \
    --dev /dev \
    --tmpfs /tmp \
    --tmpfs /run \
    --unshare-user \
    --unshare-pid \
    --unshare-uts \
    --hostname atom \
    --unshare-ipc \
    --die-with-parent \
    --bind "$OUTER_DATA" /var/lib/atom \
    --chdir /root \
    --setenv HOME /root \
    --setenv PATH /bin:/usr/bin:/sbin:/usr/sbin:/bin \
    -- \
    /bin/bwrap \
        --ro-bind / / \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --unshare-user \
        --unshare-pid \
        --unshare-uts \
        --hostname atom \
        --unshare-ipc \
        --die-with-parent \
        --bind "$INNER_SRC" /var/lib/atom \
        --chdir /root \
        --setenv HOME /root \
        --setenv PATH /bin:/usr/bin:/sbin:/usr/sbin:/bin \
        -- \
        /bin/sh -c '
            echo "--- inner container ---"
            echo "hostname: $(hostname 2>/dev/null || echo unavailable)"
            echo "pid:      $$   (1 is this container init - see /proc)"
            echo "writable: /var/lib/atom   (the inner one, not the outer)"
            echo "read-only: /   (the image, bound twice, still read-only)"
            echo
            echo "processes visible inside here: $(ls /proc | grep -c "^[0-9]*$")"
            echo
            ls -la /var/lib/atom | head -5
            echo
            echo "type exit to leave."
            exec /bin/sh -l
        '
