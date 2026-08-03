#!/bin/sh
# atom-shell.sh - an interactive shell inside an atom container.
#
# Every flag here is bwrap's own, annotated. This file is deliberately not a
# wrapper that hides the invocation: the namespace and mount setup IS the security
# boundary, and a script that concealed it would be asking you to trust a layer
# you cannot read. Read it, change it, copy it.
#
# The reference is /usr/share/doc/ATOM-BWRAP.md, and upstream's own man page is
# at /usr/share/doc/bwrap/bwrap.1.
set -eu

ROOT="${ATOM_DEST:-$HOME/atom}"
# No PORT here, deliberately. This container runs an interactive shell and
# listens on nothing, so it never collided with anything. It used to set
# PORT="${ATOM_PORT:-2242}" anyway, which was dead and actively misleading: it
# implied a port was assigned, so a user running several atoms would hand out
# ATOM_PORT values to a script that has no use for them.

[ -x "$ROOT/bin/busybox" ] || {
    echo "atom-shell: $ROOT is not unpacked - run ~/scripts/atom-make.sh first" >&2
    exit 1
}

# Every flag below is annotated, but the annotations are ABOVE this command
# rather than between its lines. A comment inside a backslash-continued command
# parses without error and then silently truncates the command: the shell eats
# the comment as the continuation line, bwrap gets a partial argument list, and it
# responds by printing its help. That reads like a bwrap bug rather than a shell
# one, which is why it is worth stating once here instead of discovering it three
# more times.
#
#   --ro-bind $ROOT /   the image, read-only. This is why scp to / or ~ inside the
#                       container fails, and why /var/lib/atom is the only place a
#                       transferred file can land.
#   --proc /proc        private procfs; with --unshare-pid it is also why the
#                       container cannot see or signal host processes.
#   --dev /dev          minimal devtmpfs including a real /dev/pts.
#   --tmpfs /tmp        writable scratch, discarded on exit.
#   --tmpfs /run        /run is read-only under --ro-bind, which makes services
#                       complain they cannot write a pidfile.
#   --unshare-user      the reason this is safe unprivileged.
#   --unshare-pid       private pid namespace.
#   --unshare-uts       private hostname; pair it with --hostname to tell
#                       containers apart.
#   --unshare-ipc       private SysV IPC and POSIX message queues.
#   --die-with-parent   tear the container down with the terminal, no orphans.
#   --bind $DATA /var/lib/atom   the one writable path. The mount point must exist
#                       in the image or bwrap cannot create it on a read-only /
#                       (bwrap: "Can't create file ... Read-only file system").
#   --chdir /root       start somewhere that exists.
#   --setenv ...        $HOME/$USER/$SHELL/$PATH; a login shell without them is
#                       a Bad Substitute waiting to happen.
#   --                  everything after is the program, so its flags stay its own.
#
# NOT --unshare-net, deliberately: the container shares the host network, so a port
# it binds is a host port. That is what makes atom-ssh.sh reachable without port
# forwarding - bwrap cannot forward ports, and this kernel has no CONFIG_VETH, so a
# private netns would be unreachable from outside.
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
    --bind "${ATOM_DATA:-$HOME/atom-data}" /var/lib/atom \
    --chdir /root \
    --setenv HOME /root \
    --setenv USER root \
    --setenv SHELL /bin/ash \
    --setenv PATH /bin:/usr/bin:/sbin:/usr/sbin:/bin \
    -- \
    /bin/sh -l "$@"
