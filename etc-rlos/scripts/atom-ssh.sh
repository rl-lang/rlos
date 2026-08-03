#!/bin/sh
# atom-ssh.sh - an atom container you can ssh into.
#
# This is the script that exists because of three specific, verified failures. Each
# is commented where it is fixed, because "sshd does not start in a container" has
# about four unrelated causes and knowing which one bit you is most of the work.
#
# The 1. writable /etc/ssh
#    atom ships NO host keys, and cannot generate any: ssh-keygen -A writes into
#    /etc/ssh, which is read-only under --ro-bind. sshd's response is
#
#        sshd: no hostkeys available -- exiting.
#
#    reproduced directly. Note that atom's sshd_config has no HostKey lines at
#    all, so sshd falls back to its compiled-in defaults (/etc/ssh/ssh_host_*_key)
#    rather than to paths relative to the -f file it was given - passing -f does
#    not redirect where it looks for keys.
#
#    The fix is --bind over /etc/ssh and generating keys there on first run. That
#    makes ONE directory writable and leaves the rest of / read-only.
#
# The 2. /bin/sshd, not /usr/sbin/sshd
#    atom is a busybox-style tree: sshd lives at /bin/sshd. Asking for
#    /usr/sbin/sshd gives
#        bwrap: execvp /usr/sbin/sshd: No such file or directory
#    which reads like a broken image rather than a wrong path.
#
# The 3. one port per container, chosen for you
#    No --unshare-net, so the container shares the host network. Its port IS a
#    host port. Two containers on the same port collide, so PORT is per-instance.
#    With no ATOM_PORT set this script now takes the first free port from 2250 up
#    and prints the one it used, so running a second instance needs no arguments.
#    Set ATOM_PORT to pin a specific port; that is honoured exactly.
set -eu

ROOT="${ATOM_DEST:-$HOME/atom}"
DATA="${ATOM_DATA:-$HOME/atom-data}"
KEYDIR="${ATOM_KEYDIR:-$HOME/atom-ssh-keys}"

[ -x "$ROOT/bin/busybox" ] || {
    echo "atom-ssh: $ROOT is not unpacked - run ~/scripts/atom-make.sh first" >&2
    exit 1
}

# The writable overlay for /etc/ssh. Copied from the read-only image on first run
# so that the image's own sshd_config and moduli stay authoritative - this
# directory is a scratch overlay, not a second copy of the configuration.
mkdir -p "$KEYDIR"
if [ ! -f "$KEYDIR/sshd_config" ]; then
    cp "$ROOT/etc/ssh/sshd_config" "$ROOT/etc/ssh/moduli" "$KEYDIR/"
fi

mkdir -p "$DATA"

# Pre-flight: is anything already listening on $PORT?
#
# WHY THIS IS CHECKED BEFORE THE BANNER IS PRINTED. Without it, a second
# instance prints "starting sshd on port 2242" followed by a set of
# copy-pasteable ssh commands, and only then:
#
#     Bind to port 2242 on 0.0.0.0 failed: Address already in use.
#     Cannot bind any address.
#
# so the script reports success and hands over instructions for a container that
# is already dead. That is worse than no message at all: the natural reading is
# "sshd started, so my connection must be the problem", which sends you
# diagnosing the client when the fault is here and is a one-line fix.
#
# Read from /proc/net/tcp{,6} rather than shelling out to ss/netstat/lsof. The
# field layout is stable kernel ABI, it needs no tool that may not be installed
# in the host, and it cannot itself be the thing that fails. st == 0A is TCP_LISTEN;
# the port is the part after the colon in the local_address column, in hex.
#
# Returns 0 (true) if something is already listening on the port given as $1.
port_busy() {
    awk -v p="$(printf '%04X' "$1")" '
        $4 == "0A" { n = split($2, a, ":"); if (a[n] == p) found = 1 }
        END { exit(found ? 0 : 1) }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# Which port?
#
# With no ATOM_PORT set, take the first free port from PORT_BASE upward and
# print the one actually used. Running a second instance therefore needs no
# arguments at all, which is the point: the previous behaviour was to advertise
# a fixed port, so the second instance printed
#
#     atom-ssh: starting sshd on port 2242
#     ssh -p 2242 user@127.0.0.1          <- instructions for a container
#     ... Bind to port 2242 failed: Address already in use.   <- that is dead
#
# Reporting success and handing over working commands for a container that never
# started is worse than printing nothing, because it points the reader at their
# ssh client when the fault is here and is fixed by re-running the script.
#
# An EXPLICIT ATOM_PORT is still honoured exactly, and still fails loudly if it is
# taken. Someone who typed a port asked for that port; quietly giving them a
# different one would leave them connecting to the wrong container, which is a
# more confusing failure than the one being prevented. Auto-selection only ever
# applies when no preference was stated.
PORT_BASE=2250
PORT_LAST=2299
if [ -n "${ATOM_PORT:-}" ]; then
    PORT="$ATOM_PORT"
    if port_busy "$PORT"; then
        echo "atom-ssh: ATOM_PORT=$PORT is already in use - refusing to start." >&2
        echo "           Stop the other instance, or pick another port:" >&2
        echo "             ATOM_PORT=$((PORT + 1)) $0" >&2
        echo "           Omit ATOM_PORT entirely to auto-pick from $PORT_BASE." >&2
        exit 1
    fi
else
    PORT="$PORT_BASE"
    while [ "$PORT" -le "$PORT_LAST" ] && port_busy "$PORT"; do
        PORT=$((PORT + 1))
    done
    if [ "$PORT" -gt "$PORT_LAST" ]; then
        echo "atom-ssh: no free port in $PORT_BASE-$PORT_LAST." >&2
        exit 1
    fi
fi

# Host keys are generated once and REUSED, not regenerated per start. Regenerating
# on every boot would change the server's fingerprint each time, so every
# known_hosts entry and every ssh warning would be correct to complain about.
#
# The keygen runs INSIDE a throwaway container rather than on the host by calling
# "$ROOT/usr/bin/ssh-keygen" directly. That older form worked only by accident:
# it loads atom's ELF interpreter and atom's libc/libcrypto against the HOST's
# search path, so it succeeds only while the host happens to provide sonames
# matching atom's. On a different distribution - or on rlOS itself once a
# library is bumped - that coincidence evaporates and the script dies with a
# loader error that has nothing to do with ssh.
#
# Inside the container the interpreter and the libraries are atom's own, which is
# the only combination guaranteed to work. /etc/ssh is already the KEYDIR bind at
# this point, so writing /etc/ssh/ssh_host_ed25519_key lands in $KEYDIR and the
# long-lived container below finds it already there.
if [ ! -f "$KEYDIR/ssh_host_ed25519_key" ]; then
    echo "atom-ssh: generating a host key in $KEYDIR (first run only)"
    bwrap \
        --ro-bind "$ROOT" / \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --bind "$KEYDIR" /etc/ssh \
        --unshare-user \
        --chdir /root \
        --setenv HOME /root \
        --setenv PATH /bin:/usr/bin:/sbin:/usr/sbin \
        -- \
        /usr/bin/ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key \
        || {
            echo "atom-ssh: ssh-keygen failed inside the container" >&2
            exit 1
        }
fi

# How to reach it.
#
# The container shares the host's network (no --unshare-net), so its port IS a
# host port and every address the host has is an address you can ssh to.
#
# This deliberately does NOT print "ssh user@$(uname -n)". The host's name is
# "system", there is no resolver daemon on this system, and while /etc/hosts now
# maps it, relying on that is how you get a container that works from one prompt
# and not another. Numeric addresses always resolve. So: loopback first, because
# that is the one that is certain to exist - it works even with the cable
# unplugged, which matters when the thing being tested IS the network.
#
# `ip -4 -o addr show scope global` rather than `hostname -I`: busybox's hostname
# has no -I (it has -i, which means something else entirely), and scope global
# filters out loopback and link-local so the list is only addresses another
# machine could plausibly reach.
HOSTNAME_SELF="$(uname -n 2>/dev/null || echo unknown)"
if [ -n "${ATOM_PORT:-}" ]; then
    echo "atom-ssh: starting sshd on port $PORT   (ATOM_PORT, as requested)"
else
    echo "atom-ssh: starting sshd on port $PORT   (first free port from $PORT_BASE)"
fi
echo
echo "  from this machine:   ssh -p $PORT user@127.0.0.1"
for a in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
    echo "  from another host:   ssh -p $PORT user@$a"
done
if ! ip -4 -o addr show scope global 2>/dev/null | grep -q .; then
    echo "  (no routable IPv4 address yet - loopback above still works)"
fi
echo "  by name:            ssh -p $PORT user@$HOSTNAME_SELF   # needs /etc/hosts to map it"
echo
echo "         state: $DATA   (the container's /var/lib/atom)"
echo "         keys:  $KEYDIR"
echo "         password is 'root' for user 'user'"
echo "         Ctrl-C stops it. Run it again for another container - it takes the"
echo "         next free port from $PORT_BASE and prints that one instead."
echo
echo "  if a connection is refused, sshd is not running - read the lines above."
echo "  if it resolves but hangs, something is between you and port $PORT."
echo

# NOTE ON THE COMMENTS BELOW: every flag is annotated, but the annotations sit
# ABOVE this command rather than between its lines. A comment inside a
# backslash-continued command is a shell error that still PARSES: the shell treats
# the comment as the continuation line, the rest of the command is lost, and bwrap
# is handed a truncated argument list. It then prints its help and exits, which
# looks like a bwrap problem rather than a shell one. Every version of these
# scripts that put a comment mid-command failed exactly this way.
#
#   --ro-bind $ROOT /        the image, read-only. The whole reason a service
#                            cannot rewrite its own binaries.
#   --proc /proc             private procfs; with --unshare-pid it is also why the
#                            container cannot see or signal host processes.
#   --dev /dev               minimal devtmpfs INCLUDING a working /dev/pts. Without
#                            the ptys, ssh connects and then cannot allocate a
#                            terminal.
#   --tmpfs /tmp             writable scratch, discarded on exit.
#   --bind $KEYDIR /etc/ssh  THE fix for (1) above: makes /etc/ssh the one writable
#                            directory so ssh-keygen can create host keys. Not a
#                            copy of the config - the image's stays authoritative.
#   --tmpfs /run             silences sshd's "Couldn't create pid file: Read-only
#                            file system", which is harmless but noisy.
#   --unshare-user           the reason this is safe unprivileged: root inside
#                            owns nothing outside the namespace.
#   --unshare-pid/uts/ipc    private pid, hostname and SysV IPC.
#   --hostname atom          --unshare-uts on its own only isolates the name; it
#                            still INHERITS the host's, which here is "system".
#                            atom's own /etc/hosts maps "atom", not "system", so
#                            without this the container cannot resolve its own
#                            hostname - and nothing else in the image would tell
#                            you that, because "system" does resolve on the host
#                            and the container feels like the host.
#   --die-with-parent        no orphans if the terminal goes away.
#   --bind $DATA /var/lib/atom   the ONLY writable path. scp to ~ or / fails with
#                            "read-only filesystem"; this is where files go. The
#                            mount point must exist in the image, which is why
#                            build_atom_rootfs.sh creates it.
#   --chdir /root            start in a home directory that exists.
#   --setenv ...             $HOME/$USER/$PATH, because a login shell with none of
#                            them misbehaves.
#   --                        everything after this is the program, so its own
#                            flags are never eaten by a wrapper.
#
# /bin/sshd, NOT /usr/sbin/sshd: fix (2). atom is a busybox-style tree.
# -D stays in the foreground so the container's lifetime is this process's.
# -e logs to stderr, where the container's death is also visible.
exec bwrap \
    --ro-bind "$ROOT" / \
    --proc /proc \
    --dev /dev \
    --tmpfs /tmp \
    --bind "$KEYDIR" /etc/ssh \
    --tmpfs /run \
    --unshare-user \
    --unshare-pid \
    --unshare-uts \
    --hostname atom \
    --unshare-ipc \
    --die-with-parent \
    --bind "$DATA" /var/lib/atom \
    --chdir /root \
    --setenv HOME /root \
    --setenv USER root \
    --setenv SHELL /bin/ash \
    --setenv PATH /bin:/usr/bin:/sbin:/usr/sbin:/bin \
    -- \
    /bin/sshd -D -e -p "$PORT"
