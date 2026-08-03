#!/usr/bin/env bash
# assemble-rootfs.sh - build the shared rlos userspace tree into a target dir
#
# The SAME tree becomes `/` two ways:
#   initramfs  -> packed with cpio+gz (rlos-initramfs/build_initramfs.sh)
#   disk       -> copied onto ext4   (rlos-disk/install.sh)
# Keeping one assembler means the two targets can never drift apart.
#
# Layout notes:
#   sbin/init is the real file; /init is a symlink to it. The kernel finds
#   /sbin/init on disk boots and follows /init on initramfs boots.
#
# Usage:
#   ./assemble-rootfs.sh <target-dir>     # e.g. ./assemble-rootfs.sh /tmp/rootfs
# Run from anywhere; rlos-relative inputs resolve from the script's location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: assemble-rootfs.sh <target-dir>}"
PROGRAMS="$SCRIPT_DIR/rl_programs"
SCRIPTS="$SCRIPT_DIR/scripts"

# Every rl program installed into /bin. Declared once and used by both the
# check below and the packaging loop at the end: when those were two separate
# lists they drifted (different order), and a program added to one but not the
# other would either fail the build or ship missing. Keep this the only list.
RL_BIN_PROGRAMS=(rlsh whoami hostname ls wc rm fbtest log shutdown reboot help)
RL_BINS="$SCRIPT_DIR/rl-bins/rlos"
INIT_BIN="$SCRIPT_DIR/rlos-initramfs/init"
GIT_DIST="$SCRIPT_DIR/git-dist"
GCC_DIST="$SCRIPT_DIR/gcc-dist"
BINUTILS_DIST="$SCRIPT_DIR/binutils-dist"
BB_DIST="$SCRIPT_DIR/busybox-dist"
X11_DIST="$SCRIPT_DIR/x11-dist"
# Phase 3 + sqlite3: curl, the OpenSSH client/server and sqlite3, with their
# ldd closure and configs. Optional like X11 so a text-only image still builds.
NETTOOLS_DIST="$SCRIPT_DIR/nettools-dist"
DBUS_DIST="$SCRIPT_DIR/dbus-dist"
IWD_DIST="$SCRIPT_DIR/iwd-dist"
BLUEZ_DIST="$SCRIPT_DIR/bluesz-dist"
FW_DIST="$SCRIPT_DIR/fw-dist"
FF_DIST="$SCRIPT_DIR/fastfetch-dist"
# w3m, a text-mode browser. See the long note at the staging site near the end of
# this script for why there is no graphical browser in this image.
W3M_DIST="$SCRIPT_DIR/w3m-dist"
  # rlos-atom: the single-file service container image that runs inside this
  # system via bubblewrap, plus bwrap itself so the desktop can host it. The
  # archive, not the unpacked tree: the tree is a build input that
  # pack_atom_image.sh turns into the image.
  ATOM_IMAGE="$SCRIPT_DIR/rlos-atom/atom-rootfs.tar.gz"
  BWRAP_DIST="$SCRIPT_DIR/rlos-atom/bwrap-dist"

# The X11 stack is optional. If x11-dist/ is present the guest boots into an
# i3 + mlterm session; if it is absent the text console is the whole system and
# nothing here runs. Keeping it optional means the minimal image still builds
# on a machine that never ran build_x11.sh.
WITH_X11=0
if [[ -d "$X11_DIST/bin" ]]; then
    WITH_X11=1
fi

if [[ ! -x "$INIT_BIN" ]]; then
    echo "error: $INIT_BIN not found - run rlos-initramfs/compile_init.sh first" >&2
    exit 1
fi
for tool_bin in rl rlc rlt rldocs rlrepl rlsp; do
    if [[ ! -x "$RL_BINS/$tool_bin" ]]; then
        echo "error: $RL_BINS/$tool_bin not found - run build_rl_bins.sh first" >&2
        exit 1
    fi
done
for prog in "${RL_BIN_PROGRAMS[@]}"; do
    if [[ ! -f "$PROGRAMS/$prog.rl" ]]; then
        echo "error: required program source code '$prog.rl' not found in '$PROGRAMS'" >&2
        exit 1
    fi
done
if [[ ! -f "$PROGRAMS/nano/nano.rl" ]]; then
    echo "error: required program source code 'nano/nano.rl' not found in '$PROGRAMS'" >&2
    exit 1
fi
if [[ ! -x "$GIT_DIST/bin/git" ]]; then
    echo "error: $GIT_DIST/bin/git not found - run build_git.sh first" >&2
    exit 1
fi
if [[ ! -x "$GCC_DIST/bin/gcc" ]]; then
    echo "error: $GCC_DIST/bin/gcc not found - run build_gcc.sh first" >&2
    exit 1
fi
# gcc has no built-in assembler or linker (tcc had both), so binutils is a hard
# prerequisite rather than a convenience. Without as/ld in the guest every
# in-guest compile dies at the first link.
if [[ ! -x "$BINUTILS_DIST/bin/ld" ]]; then
    echo "error: $BINUTILS_DIST/bin/ld not found - run build_binutils.sh first" >&2
    exit 1
fi
if [[ ! -x "$BB_DIST/bin/busybox" ]]; then
    echo "error: $BB_DIST/bin/busybox not found - run build_busybox.sh first" >&2
    exit 1
fi
if [[ ! -f "$BB_DIST/APPLYTS" ]]; then
    echo "error: $BB_DIST/APPLYTS not found - run build_busybox.sh first" >&2
    exit 1
fi

echo "assembling rootfs in $TARGET/..."
rm -rf "$TARGET"
mkdir -p "$TARGET"/{bin,sbin,dev,proc,sys,tmp,run,root,lib64,usr/lib,usr/lib64}
mkdir -p "$TARGET/etc"

# Accounts. The desktop runs as `user` (uid 1000) and escalates with sudo, so
# there are two real accounts rather than one root shell.
#
#   root  uid 0    no password (the rescue console on tty0 is already root, and
#                  `sudo` from `user` is the intended escalation path)
#   user  uid 1000 password "root"
#
# `openssl passwd -6` produces the SHA-512 crypt hash that libcrypt (what sudo
# links against) checks. The salt is fixed only so the image is byte-reproducible,
# not for any security reason - this is a live image whose whole filesystem is
# readable by whoever boots it.
if command -v openssl > /dev/null 2>&1; then
    USER_PW_HASH="$(openssl passwd -6 -salt rlos root)"
else
    echo "error: openssl not found on PATH - cannot hash the 'user' password" >&2
    exit 1
fi
printf 'root:x:0:0:root:/root:/bin/ash\n' > "$TARGET/etc/passwd"
printf 'user:x:1000:1000:user:/home/user:/bin/ash\n' >> "$TARGET/etc/passwd"
printf 'root:x:0:\nuser:x:1000:\n' > "$TARGET/etc/group"
# root is locked (!), user has the "root" password. Field order is
# name:hash:lastchange:min:max:warn:inactive:expire:reserved.
printf 'root:!:19000:0:99999:7:::\n' > "$TARGET/etc/shadow"
printf 'user:%s:19000:0:99999:7:::\n' "$USER_PW_HASH" >> "$TARGET/etc/shadow"
chmod 600 "$TARGET/etc/shadow"

# sudo's policy. init.c (secure_sudo_files) chowns these to root and sets the
# modes at boot, because this image is packed by a non-root user and cannot set
# root ownership at package time - and sudo refuses to run unless it is setuid
# root, owned by root, and its sudoers file is root-owned 0440.
mkdir -p "$TARGET/etc/sudoers.d"
cat > "$TARGET/etc/sudoers" << 'SUDOEOF'
# rlOS: full sudo for the one unprivileged account, which is the person at the
# keyboard. This is a live image on the user's own hardware, not a shared host;
# `user` can read the whole filesystem anyway, so restricting what it may run
# as root would only be theatre.
Defaults	env_reset
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root	ALL=(ALL:ALL) ALL
user	ALL=(ALL:ALL) ALL
SUDOEOF
chmod 440 "$TARGET/etc/sudoers"

echo "system" > "$TARGET/etc/hostname"

# /etc/hosts, written immediately after /etc/hostname for the same reason:
# init.c calls sethostname("system", 6), and a host with a name that nothing can
# resolve is a real and easily-misdiagnosed problem.
#
# It is not a cosmetic file. There is no resolver daemon here - no avahi, no
# systemd-resolved - and no /etc/nsswitch.conf either, so glibc falls back to
# files for host lookup. With this file absent, EVERY name fails, including the
# machine's own:
#
#     $ ssh user@system
#     ssh: Could not resolve hostname system: Name or service not known
#
# which reads as "ssh is broken" or "nothing is listening", and neither is true.
# A numeric address bypasses resolution entirely, which is why a container test
# over 127.0.0.1 can pass while the same thing over the hostname never works.
#
# localhost is the entry that actually earns its keep: tools that probe their
# own name, and anything that resolves "localhost" to a routable address instead
# of the loopback, fail in ways that look unrelated to name resolution.
printf '127.0.0.1\tlocalhost\n127.0.1.1\tsystem\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
    > "$TARGET/etc/hosts"

mkdir -p "$TARGET/home/user"

# /etc/os-release: how this system identifies itself.

# $HOME/scripts: worked examples, shipped as source and run in place.
#
# These are NOT installed into /usr/bin and are NOT on PATH. They are examples to
# read and copy, and the whole point of them is that you can see exactly what
# bwrap and ffmpeg are being asked to do - the reason atom has no wrapper script
# is that a wrapper hides the namespace and mount setup that IS the security
# boundary. Putting them in a directory rather than on PATH keeps that explicit.
#
# Main rlOS only, never atom: atom is a service image with no desktop, so there is
# nothing here for it to do. The atom scripts assume bwrap is on the HOST, which
# it is - but atom itself is the thing being run, not the thing doing the running.
#
# init.c chowns /home/user recursively at boot, so these arrive owned by root from
# the build and are handed to uid 1000 before anyone can run them. That is the
# same treatment every other file under $HOME gets.
SCRIPT_SRC="$SCRIPT_DIR/etc-rlos/scripts"
if [[ -d "$SCRIPT_SRC" ]]; then
    mkdir -p "$TARGET/home/user/scripts"
    n=0
    for s in "$SCRIPT_SRC"/*.sh; do
        [ -f "$s" ] || continue
        install -m 0755 "$s" "$TARGET/home/user/scripts/$(basename "$s")"
        n=$((n + 1))
    done
    # The atom scripts are useless without the image, and the ffmpeg ones
    # without ffmpeg. Assert that rather than shipping a directory of broken
    # examples - a script that cannot work is worse than an absent one, because
    # it looks like the feature is there.
    #
    # Tested against $ATOM_IMAGE, the SOURCE path, not $TARGET/atom-rootfs.tar.gz.
    # This block runs ~75 lines BEFORE the atom image is staged further down, so
    # testing the target here reported "no atom image" on builds that went on to
    # stage one - a false warning on every single build.
    if [[ -f "$ATOM_IMAGE" ]]; then
        echo "home/user/scripts: $n scripts (atom + ffmpeg)"
    else
        echo "home/user/scripts: $n scripts (WARNING: $ATOM_IMAGE not built, atom-*.sh will not run)"
    fi
fi

# X11 goes in early, before the runtime-dependency sweep further down, so the
# sweep sees bin/Xorg, bin/i3, bin/mlterm and bin/setrootcursor and picks up anything
# build_x11.sh's own closure pass missed.
if [[ "$WITH_X11" == "1" ]]; then
    echo "installing X11 stack from x11-dist/ ($(du -sh "$X11_DIST" | cut -f1))..."
    cp -a "$X11_DIST/." "$TARGET/"
    chmod 755 "$TARGET"/bin/* 2>/dev/null || true
    # No /dev/tty nodes needed: CONFIG_DEVTMPFS_MOUNT=y makes the kernel mount
    # devtmpfs on /dev itself, so tty0..6 and pts appear on their own. init.c
    # also mounts devtmpfs over the top, which is harmless and idempotent.
    #
    # What is needed is the X unix socket dir and the config files in the
    # places the tools actually look - Xft reads /etc/fonts/fonts.conf and
    # Xorg reads /etc/X11/xorg.conf, neither of which is under /usr/share.
    mkdir -p "$TARGET/tmp/.X11-unix" "$TARGET/etc/fonts" "$TARGET/etc/X11"
    chmod 1777 "$TARGET/tmp"
    cp -f "$TARGET/usr/share/rlos/fonts.conf" "$TARGET/etc/fonts/fonts.conf"
    # Only the *base* config is staged. /etc/X11/xorg.conf is generated at boot
    # by init.c (gen_input_config), which appends one InputDevice section per
    # /dev/input/event* node plus the ServerLayout - xf86-input-libinput needs
    # an explicit Option "Device" per device and nothing else can supply it
    # without a udevd. See build_x11.sh for the matching generator.
    # Both templates are staged; init.c copies the one that matches the driver
    # the kernel bound and appends the input sections to it. Neither is edited.
    # i3 dies without a config file (src/config.c:235), and it resolves paths
    # relative to $HOME, so the config is shipped in the image and init passes
    # -c with an absolute path rather than relying on the environment.
    for cfg in i3.config; do
        if [[ ! -f "$SCRIPT_DIR/etc-rlos/$cfg" ]]; then
            echo "error: etc-rlos/$cfg missing" >&2
            exit 1
        fi
        cp -f "$SCRIPT_DIR/etc-rlos/$cfg" "$TARGET/etc/$cfg"
    done
    for tmpl in ms fbdev; do
        if [[ ! -f "$TARGET/usr/share/rlos/xorg.conf.$tmpl.base" ]]; then
            echo "error: xorg.conf.$tmpl.base missing from x11-dist - run build_x11.sh first" >&2
            exit 1
        fi
        cp -f "$TARGET/usr/share/rlos/xorg.conf.$tmpl.base" "$TARGET/etc/X11/xorg.conf.$tmpl.base"
    done
      # rlos-clock: the bar's status_command. Staged as a real binary in /usr/bin,
      # not as a config line with the loop inline, because i3bar re-execs the
      # command whenever it dies and an inline one would be re-parsed every time;
      # and because a script can be tested on its own (`rlos-clock | head -1`
      # prints one line of JSON) without starting a window manager.
      if [[ -f "$SCRIPT_DIR/etc-rlos/rlos-clock" ]]; then
          install -m 0755 "$SCRIPT_DIR/etc-rlos/rlos-clock" "$TARGET/usr/bin/rlos-clock"
          echo "usr/bin/rlos-clock (bar clock)"
      else
          echo "error: etc-rlos/rlos-clock missing - i3.config's status_command will fail" >&2
          exit 1
      fi
      echo "X11 installed (config: etc/fonts/fonts.conf, etc/X11/xorg.conf.{ms,fbdev}.base)"
else
    echo "no x11-dist/ - building the text-only image (run build_x11.sh for X11)"
fi

# ---------------------------------------------------------------------------
# rlos-atom + bubblewrap
# ---------------------------------------------------------------------------
# rlOS hosts atom: /atom-rootfs.tar.gz is the single-file image every container
# root is unpacked from, and bwrap bind-mounts whatever directory it was unpacked
# into. Both are optional, so a desktop-only build still works.
#
# The atom tree is ~95M uncompressed and the archive is ~41M, so shipping the
# archive rather than the tree saves over half the space in the initramfs. It
# also means there is exactly one source of truth for the container filesystem:
# a staged directory could drift from the archive beside it, and nothing would
# notice until a container behaved differently from the image it was built from.
if [[ -f "$ATOM_IMAGE" && -d "$BWRAP_DIST" ]]; then
    echo "installing rlos-atom ($(du -h "$ATOM_IMAGE" | cut -f1)) + bubblewrap..."
    install -m 0644 "$ATOM_IMAGE" "$TARGET/atom-rootfs.tar.gz"

    # bwrap and its libcap closure. Only the HOST needs this: inside the
    # container /atom's own unpacked tree already has a copy, and the container
    # bind-mounts its own /usr/bin over the host's.
    cp -a "$BWRAP_DIST/." "$TARGET/"
    if [[ -x "$TARGET/bin/bwrap" ]]; then
        echo "bwrap staged ($(du -h "$TARGET/bin/bwrap" | cut -f1))"
    else
        echo "error: bwrap not staged from bwrap-dist" >&2
        exit 1
    fi

    # The image must be the archive we think it is. A truncated or zero-length
    # file here would surface as a container that will not start, much later and
    # with nothing pointing back at the cause.
    if ! tar -tzf "$TARGET/atom-rootfs.tar.gz" >/dev/null 2>&1; then
        echo "error: staged atom-rootfs.tar.gz is not a readable gzip archive" >&2
        exit 1
    fi
    echo "atom image verified as a readable gzip archive"

    # The documentation, on the host image only. It is deliberately NOT inside
    # the atom image: atom ships as one file the host unpacks into a scratch
    # directory, so a guide placed inside it would only be readable from inside
    # a container - which is the wrong place to read how to start a container.
    DOC_SRC="$SCRIPT_DIR/rlos-atom/docs"
    if [[ -d "$DOC_SRC" ]]; then
        mkdir -p "$TARGET/usr/share/doc/bwrap"
        # Upstream's own documents, vendored verbatim and pinned to the
        # bubblewrap version we stage. See docs/PROVENANCE.md.
        install -m 0644 "$DOC_SRC/bwrap.1" "$TARGET/usr/share/doc/bwrap/bwrap.1"
        install -m 0644 "$DOC_SRC/bubblewrap-README.v0.12.0.md" \
            "$TARGET/usr/share/doc/bwrap/README.md"
        install -m 0644 "$DOC_SRC/PROVENANCE.md" \
            "$TARGET/usr/share/doc/bwrap/PROVENANCE.md"
        echo "bubblewrap docs: $(ls "$TARGET/usr/share/doc/bwrap" | wc -l) files"
    else
        echo "warning: rlos-atom/docs/ missing - shipping without bwrap documentation" >&2
    fi

    # Our guide, in the two places someone actually looks for it.
    if [[ -f "$SCRIPT_DIR/rlos-atom/ATOM-BWRAP.md" ]]; then
        mkdir -p "$TARGET/usr/share/doc"
        install -m 0644 "$SCRIPT_DIR/rlos-atom/ATOM-BWRAP.md" \
            "$TARGET/usr/share/doc/ATOM-BWRAP.md"
        install -m 0644 "$SCRIPT_DIR/rlos-atom/ATOM-BWRAP.md" \
            "$TARGET/home/user/ATOM-BWRAP.md"
        echo "guide: /usr/share/doc/ATOM-BWRAP.md, /home/user/ATOM-BWRAP.md"
    fi

    # The atom must be root-owned and not writable by anyone else, or a process
    # inside a container could rewrite the image every later container is
    # unpacked from. This assembler runs unprivileged so it cannot guarantee that
    # here - init.c fixes it at boot, for the same reason it chowns /home/user:
    # the file's ownership depends on who packed the initramfs.
    echo "atom: image staged; init.c enforces root ownership at boot"
else
    echo "no rlos-atom/atom-rootfs.tar.gz - building without the atom container"
    echo "  (run rlos-atom/build_atom_rootfs.sh, then pack_atom_image.sh,"
    echo "   then build_atom_bwrap.sh to include it)"
fi

    # fastfetch, optional like X11: without fastfetch-dist/ the guest has no banner
    # tool, which costs nothing.
    #
    # It goes to /usr/bin, which matters. The ldd closure earlier walks only /bin/*
    # and /usr/libexec/git-core/*, so a binary here is INVISIBLE to it and its
    # libraries have to already be staged. build_fastfetch.sh does that, staging
    # libyyjson (the only dependency not already needed by the rest of the guest).
    if [[ -d "$FF_DIST/usr/bin" ]]; then
        echo "installing fastfetch from fastfetch-dist/ ($(du -sh "$FF_DIST" | cut -f1))..."
        cp -a "$FF_DIST/." "$TARGET/"
        chmod 755 "$TARGET/usr/bin/fastfetch"
        # The logo and the config that makes fastfetch use it.
        #
        # fastfetch resolves a config through ~/.config/fastfetch/,
        # /etc/xdg/fastfetch/, /etc/fastfetch/ ... (see --list-config-paths), so
        # /etc/xdg/fastfetch/config.jsonc is the one location that is both
        # system-wide and writable at build time. The filename is config.jsonc,
        # NOT fastfetch.jsonc - established from what `fastfetch --gen-config`
        # writes. XDG_CONFIG_DIRS has to include /etc/xdg for this to be found,
        # which init.c sets (init.c:x_envp has XDG_CONFIG_DIRS=/etc/xdg).
        #
        # A user can still override all of it by dropping their own
        # ~/.config/fastfetch/config.jsonc, which fastfetch prefers.
        #
        # ff_logo.txt is a fastfetch-format ASCII logo: the $1..$8 tokens select
        # from the "color" map below, one colour per letter of RLOS. A plain
        # text logo also works, just monochrome.
        if [[ -f "$SCRIPT_DIR/ff_logo.txt" ]]; then
        LOGO_LINES="$(wc -l < "$SCRIPT_DIR/ff_logo.txt")"
        mkdir -p "$TARGET/usr/share/rlos" "$TARGET/etc/xdg/fastfetch"
        cp "$SCRIPT_DIR/ff_logo.txt" "$TARGET/usr/share/rlos/ff_logo.txt"
        cat > "$TARGET/etc/xdg/fastfetch/config.jsonc" << 'FFCFG'
{
  "logo": {
    "source": "/usr/share/rlos/ff_logo.txt",
    "color": {
      "1": "#DC143C",
      "2": "#7A0C22",
      "3": "#E34234",
      "4": "#7A241D",
      "5": "#82AAFF",
      "6": "#44557A",
      "7": "#C099FF",
      "8": "#5C4A80"
    }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "initsystem",
    "uptime",
    "break",
    "shell",
    "wm",
    "font",
    "editor",
    "terminal",
    "break",
    "cpu",
    "gpu",
    "memory",
    "disk",
    "battery",
    "break",
    "colors"
  ]
}
FFCFG
        echo "  logo: etc/xdg/fastfetch/fastfetch.jsonc -> usr/share/rlos/ff_logo.txt ($LOGO_LINES lines)"
    else
        echo "  no ff_logo.txt in the repo - fastfetch will use its built-in logo"
    fi
else
    echo "no fastfetch-dist/ - skipping fastfetch (run build_fastfetch.sh to add it)"
fi

echo "installing init (sbin/init + /init symlink)..."
cp "$INIT_BIN" "$TARGET/sbin/init"
chmod 755 "$TARGET/sbin/init"
ln -sf sbin/init "$TARGET/init"

KLOGD_BIN="$SCRIPT_DIR/rlos-initramfs/klogd"
if [[ -x "$KLOGD_BIN" ]]; then
    echo "installing klogd..."
    cp "$KLOGD_BIN" "$TARGET/sbin/klogd"
    chmod 755 "$TARGET/sbin/klogd"
else
    echo "warning: $KLOGD_BIN not found - run rlos-initramfs/compile_klogd.sh first (boot log stays uncolored)" >&2
fi

echo "installing toolchain (rl rlc rlt rldocs rlrepl rlsp)..."
for tool_bin in rl rlc rlt rldocs rlrepl rlsp; do
    cp "$RL_BINS/$tool_bin" "$TARGET/bin/"
done
# /bin/sh is busybox's ash: the rl programs are shipped as source under
# /home/user/programs/rl, so there is no /bin/rlsh binary to point at, and ash
# is the shell with line editing regardless.
if [[ -x "$BB_DIST/bin/busybox" ]]; then
    ln -sf busybox "$TARGET/bin/sh"
fi

echo "installing git bundle..."
cp -a "$GIT_DIST/." "$TARGET/"

echo "installing gcc bundle (C-only + LTO)..."
cp -a "$GCC_DIST/." "$TARGET/"

echo "installing binutils bundle (as/ld - gcc has no built-in ones)..."
cp -a "$BINUTILS_DIST/." "$TARGET/"

# The driver has to land in /usr/bin, NOT /bin, and that is not cosmetic.
#
# gcc resolves cc1, lto1, collect2, libgcc.a and the crt objects relative to
# where the gcc binary itself lives. It was configured --prefix=/usr, so a
# driver at /usr/bin/gcc looks in:
#
#     /usr/libexec/gcc/<triplet>/<ver>/cc1     <- where build_gcc.sh staged it
#     /usr/lib/gcc/<triplet>/<ver>/crtbegin.o  <- likewise
#
# A driver at /bin/gcc instead derives the prefix "/" and searches:
#
#     /libexec/gcc/<triplet>/<ver>/cc1         <- does not exist
#     /lib/gcc/<triplet>/<ver>/crtbegin.o      <- does not exist
#
# and when it cannot find them it falls back to a PATH search for a bare "cc1",
# so every single compile in the guest dies with the thoroughly unhelpful:
#
#     cc: fatal error: cannot execute 'cc1': posix_spawnp: No such file or directory
#
# `cc --version` still works in that state, because it prints and exits without
# ever spawning cc1 - which is exactly why this is worth asserting rather than
# smoke-testing.
mkdir -p "$TARGET/usr/bin"
for tool in gcc gcc-ar gcc-nm gcc-ranlib; do
    mv -f "$TARGET/bin/$tool" "$TARGET/usr/bin/$tool"
done
# binutils too, so the assembler and linker sit beside the driver that execs
# them rather than depending on a PATH search finding them in /bin.
for tool in as ld ld.bfd ar nm ranlib objcopy strip size strings addr2line elfedit; do
    if [[ -f "$TARGET/bin/$tool" ]]; then
        mv -f "$TARGET/bin/$tool" "$TARGET/usr/bin/$tool"
    fi
done
ln -sf gcc "$TARGET/usr/bin/cc"

# Assert the layout contract, on the real tree, rather than trusting the copy.
# Cheap, and it is the check whose absence let a broken image be built.
GCC_CC1="$(find "$TARGET/usr/libexec/gcc" -name cc1 -type f 2>/dev/null | head -1)"
GCC_LTO1="$(find "$TARGET/usr/libexec/gcc" -name lto1 -type f 2>/dev/null | head -1)"
if [[ ! -x "$TARGET/usr/bin/gcc" ]]; then
    echo "error: gcc not staged at usr/bin/gcc (it must be at its configured prefix)" >&2
    exit 1
fi
if [[ ! -x "$GCC_CC1" ]]; then
    echo "error: no cc1 under usr/libexec/gcc/ - every in-guest compile would fail" >&2
    echo "  with 'cannot execute cc1: posix_spawnp: No such file or directory'" >&2
    exit 1
fi
if [[ ! -x "$GCC_LTO1" ]]; then
    echo "error: no lto1 under usr/libexec/gcc/ - 'rlt --compile --lto' would fail" >&2
    exit 1
fi
if [[ "$(readlink -f "$TARGET/usr/bin/cc")" != "$(readlink -f "$TARGET/usr/bin/gcc")" ]]; then
    echo "error: usr/bin/cc does not resolve to usr/bin/gcc" >&2
    exit 1
fi
echo "gcc at usr/bin/gcc, cc1 + lto1 present under usr/libexec/gcc (prefix contract OK)"

echo "installing busybox bundle..."
cp -a "$BB_DIST/." "$TARGET/"

# Symlink one name per applet, so `cat` is busybox's cat and `grep` is busybox's.
# The applet list is the one written by build_busybox.sh from the binary it
# actually built - not from the config we asked for - because oldconfig drops
# unsatisfiable symbols without failing.
#
# Skipped: `sh` (symlinked to busybox explicitly, as ash), and `cc`/`git`,
# which are gcc and real git.
#
# The rl programs - ls, rm, wc, whoami, hostname, reboot, log, help - are NOT
# excluded any more. They are shipped as source under /home/user/programs/rl
# rather than compiled to /bin/<name> binaries, so there is no rl binary for
# busybox to collide with, and busybox's versions are now what `ls` and `wc` on
# PATH resolve to. The rl source remains runnable with `rl run <file>`.
#
# `klogd` is excluded and is not an rl program: rlOS ships its own at
# /sbin/klogd that tees the kernel stream to /log/kmsg. PATH is
# /bin:/usr/bin:/sbin, so a busybox klogd linked into /bin would take precedence
# over it, and the two would then fight over /dev/kmsg and the console loglevel.
#
# `busybox` itself is an applet too, but it is caught by the -e test below since
# the binary is already staged by this point.
# `ar` and `strings` are excluded because binutils-dist provides real ones in
# the same directory (/bin) and busybox has applets of both names. `ar` in
# particular is not cosmetic: gcc-ar and the LTO wrapper exec `ar` from PATH
# when building the intermediate archive for `rlt --compile --lto`, and busybox's
# ar is not a substitute. The applet loop below would skip them anyway since
# binutils is staged first, but relying on that ordering is how a reordering
# silently swaps in busybox's ar later.
BB_EXCLUDE="sh cc git klogd ar strings"
N_BB_LINKED=0
N_BB_SKIPPED=0
while read -r applet; do
    [ -n "$applet" ] || continue
    skip=0
    for ex in $BB_EXCLUDE; do
        if [ "$applet" = "$ex" ]; then
            skip=1
            break
        fi
    done
    # Never clobber something already staged, whatever put it there.
    if [ "$skip" = "1" ] || [ -e "$TARGET/bin/$applet" ]; then
        N_BB_SKIPPED=$((N_BB_SKIPPED + 1))
        continue
    fi
    ln -sf busybox "$TARGET/bin/$applet"
    N_BB_LINKED=$((N_BB_LINKED + 1))
done < "$BB_DIST/APPLYTS"

# A busybox applet that shadows one of our own binaries is a silent, hard-to-
# trace failure, so check for it instead of trusting the hand-written list
# above to stay complete as the image gains programs.
BB_SHADOW=""
while read -r applet; do
    [ -n "$applet" ] || continue
    for ex in $BB_EXCLUDE; do
        [ "$applet" = "$ex" ] && continue 2
    done
    # /bin is first on PATH, so anything staged in /sbin or /usr/sbin would be
    # shadowed by a /bin/<name> link.
    if [ -e "$TARGET/sbin/$applet" ] || [ -e "$TARGET/usr/sbin/$applet" ]; then
        BB_SHADOW="$BB_SHADOW $applet"
    fi
done < "$BB_DIST/APPLYTS"
if [ -n "$BB_SHADOW" ]; then
    echo "error: busybox applets would shadow binaries staged in sbin:$BB_SHADOW" >&2
    echo "hint: add them to BB_EXCLUDE with a note on why." >&2
    exit 1
fi
echo "busybox: $N_BB_LINKED applets linked, $N_BB_SKIPPED left to rl/git/gcc"

# `rescue` cannot be a symlink: busybox dispatches on argv[0] and has no applet
# named "rescue", so a link fails with "rescue: applet not found" and exit 127.
# build_busybox.sh stages it as a script with an interpreter in the shebang.
if [[ ! -x "$TARGET/bin/rescue" ]]; then
    echo "error: $BB_DIST/bin/rescue missing or not executable" >&2
    exit 1
fi
echo "busybox: rescue shell staged (busybox ash, rlsh remains the default)"

echo "copying runtime library dependencies for everything staged..."
echo "(preserving absolute paths + flat /usr/lib64, no ld.so.cache in guest)"
DEPS="$(for tool_bin in "$TARGET"/bin/* "$TARGET"/usr/libexec/git-core/*; do
    [[ -f "$tool_bin" && -x "$tool_bin" ]] || continue
    ldd "$tool_bin" 2>/dev/null | awk '{print $3}'
done | grep '^/' | sort -u || true)"
if [[ -z "$DEPS" ]]; then
    echo "warning: no dynamic dependencies found (statically linked toolchain?)"
else
    for lib in $DEPS; do
        if [[ -f "$lib" ]]; then
            mkdir -p "$TARGET/$(dirname "$lib")"
            cp -n "$lib" "$TARGET/$lib"
            # Flat copy too: the loader has no ld.so.cache in the guest and
            # only searches /lib64 + /usr/lib64 by default, so libs from
            # anywhere else (e.g. gcc's libgcc_s) would not resolve by
            # their real path alone.
            cp -n "$lib" "$TARGET/usr/lib64/"
        else
            echo "warning: dependency $lib listed by ldd but not found on disk" >&2
        fi
    done
fi

  # No staged binary may reference the BUILD HOST's filesystem.
  #
  # The closure loop above copies each dependency both flat and at its absolute
  # path, which is what makes a dlopen of an absolute path work in the guest. The
  # cost is that it also faithfully recreates, inside the image, whatever absolute
  # path ldd happened to report - and ldd reports the RUNPATH-resolved location.
  # i3 used to be staged from its meson BUILD tree, so it carried
  # DT_RUNPATH=[$HOME/dev/rl/rlos/x11-prefix/usr/lib64] and the image grew a
  # /home/crimson/... tree. Worse, DT_RUNPATH is searched BEFORE the default
  # directories, so that leaked path was where i3 actually loaded its libraries
  # from - the leak was load-bearing, not cosmetic.
  #
  # i3 is now staged from a DESTDIR install, which fixes this instance. But the
  # failure is silent and comes back the next time anything is staged from a build
  # tree, so it is asserted rather than assumed.
  #
  # Scoped to this user's home and this repo's prefix on purpose: checking every
  # absolute path would false-positive on /usr and /lib all day.
  LEAKED_ABS=""
  while IFS= read -r elf; do
      [ -n "$elf" ] || continue
      # `|| true` is load-bearing. Not every file under bin/ is an ELF - some are
      # shell scripts and some are busybox applet symlinks - and readelf exits
      # nonzero on those. Under `set -o pipefail` that aborts the whole build with
      # no message, right after the closure pass.
      refs="$(readelf -d "$elf" 2>/dev/null \
                | awk '/NEEDED|RPATH|RUNPATH/ {print $NF}' || true)"
      case "$refs" in
          *"$HOME"*|*"$SCRIPT_DIR"*) LEAKED_ABS="$LEAKED_ABS $(basename "$elf")" ;;
      esac
  done < <(find "$TARGET/bin" "$TARGET/usr/bin" "$TARGET/sbin" \
                "$TARGET/usr/sbin" -type f 2>/dev/null)
  if [[ -n "$LEAKED_ABS" ]]; then
      echo "error: these staged binaries reference the build host's paths:$LEAKED_ABS" >&2
      echo "  A DT_NEEDED/RPATH/RUNPATH holding an absolute host path means the" >&2
      echo "  binary was staged from a build tree instead of an install tree." >&2
      echo "  Check: readelf -d <binary> | grep -E 'RPATH|RUNPATH|NEEDED'" >&2
      exit 1
  fi
  echo "no staged binary references the build host"

LD_LINUX="/lib64/ld-linux-x86-64.so.2"
if [[ -f "$LD_LINUX" ]]; then
    cp "$LD_LINUX" "$TARGET/lib64/"
else
    echo "error: dynamic linker $LD_LINUX not found" >&2
    exit 1
fi

# Every -l flag rlt --compile can put on a gcc command line must resolve in the
# finished guest, or a program that happens to use that feature fails to link
# with "cannot find -lX" and nothing in this build would have noticed.
#
# build_gcc.sh stages all of these now - including libffi, which used to arrive
# only via the ldd closure above on the accident that some shipped binary links
# it. This check remains because it runs against the FINISHED tree, after the
# ldd closure and the busybox symlink pass have both had their say, which is a
# different question from whether the toolchain's own tree was complete.
#
# Note the glob, not an exact name: libyaml's SONAME on Gentoo is
# libyaml-0.so.2, and neither libyaml.so* nor a hardcoded libyaml.so.0 matches
# it. Hence the pattern also accepts lib*yaml*.
for rlt_lib in "m" "ffi" "curl" "argon2" "yaml" "pthread" "dl"; do
    if ! compgen -G "$TARGET/usr/lib64/lib${rlt_lib}.so*" > /dev/null \
       && ! compgen -G "$TARGET/usr/lib64/lib*${rlt_lib}*.so*" > /dev/null; then
        echo "error: rlt can emit '-l$rlt_lib' but no matching library is in the guest." >&2
        echo "  Add it to build_gcc.sh's runtime-lib staging loop." >&2
        exit 1
    fi
done
echo "rlt link libraries present: m ffi curl argon2 yaml pthread dl"

# -lNAME dev symlinks, created here because this is the first point where the
# whole tree exists.
#
# The loop above is NOT sufficient. It asks whether lib<name>*.so* exists, which
# libpthread.so.0 and libcurl.so.4 both satisfy - but a linker resolves -lNAME by
# looking for libNAME.so specifically and does not accept libNAME.so.N:
#
#   ld: cannot find -lpthread
#
# So every library rlt can emit needs libNAME.so -> libNAME.so.N. Without this,
# no rl program using std::http (-lcurl), password hashing (-largon2), YAML
# (-lyaml) or audio (-lpthread) has ever linked in this guest.
echo "creating -l dev symlinks for rlt link libraries..."
rlt_symlinked=""
rlt_missing=""
for rlt_lib in "ffi" "curl" "argon2" "yaml" "pthread" "dl"; do
    # Glob, not lib<name>.so.*: libyaml's real file is libyaml-0.so.2.
    rlt_target="$(ls -1 "$TARGET"/usr/lib64/lib"$rlt_lib"*.so.* 2>/dev/null | head -1 || true)"
    if [[ -z "$rlt_target" ]]; then
        rlt_missing="$rlt_missing $rlt_lib"
        continue
    fi
    ln -sf "$(basename "$rlt_target")" "$TARGET/usr/lib64/lib$rlt_lib.so"
    rlt_symlinked="$rlt_symlinked lib$rlt_lib.so->$(basename "$rlt_target")"
done
if [[ -n "$rlt_missing" ]]; then
    echo "error: no libNAME.so.N staged for:$rlt_missing" >&2
    echo "  rlt emits -l for these and the linker cannot resolve them." >&2
    exit 1
fi
echo "dev symlinks:$rlt_symlinked"

echo "installing rl-program sources..."
mkdir -p "$TARGET/home/user/programs/rl"
for prog in "${RL_BIN_PROGRAMS[@]}"; do
    cp "$PROGRAMS/$prog.rl" "$TARGET/home/user/programs/rl/$prog.rl"
done
cp "$PROGRAMS/nano/nano.rl" "$TARGET/home/user/programs/rl/nano.rl"
echo "rl sources in /home/user/programs/rl"

# busybox udhcpc's script to actually apply a lease.
#
# Not optional. udhcpc gets a lease and then execs this script with "bound" or
# "renew" - without it the address is never configured, the route is never
# added, and /etc/resolv.conf is never written, so networking silently does
# nothing while looking like it worked. The path is compiled into the binary
# (confirmed with strings: /usr/share/udhcpc/default.script).
echo "staging udhcpc lease script..."
mkdir -p "$TARGET/usr/share/udhcpc"
cat > "$TARGET/usr/share/udhcpc/default.script" << 'UDSCRIPT'
#!/bin/sh
# Applied by busybox udhcpc. Called with the environment busybox sets:
#   $1 = "bound" | "renew" | "deconfig" | "leasefail" | "timeout"
#   $ip, $subnet, $router, $dns are the lease terms.
[ -n "$1" ] || exit 1

if [ "$1" = "deconfig" ]; then
    # Lease gone or lost: drop what we had, or a stale address outlives the DHCP
    # server and traffic goes nowhere.
    ip addr flush dev "$interface" 2>/dev/null
    : > /etc/resolv.conf
    exit 0
fi

case "$1" in
    bound|renew)
        ip addr flush dev "$interface" 2>/dev/null
        ip addr add "$ip/${subnet:-24}" dev "$interface" 2>/dev/null
        # Default route. "$router" can be several space-separated; the first is
        # the one busybox considers primary.
        for r in $router; do
            ip route add default via "$r" dev "$interface" 2>/dev/null && break
        done
        : > /etc/resolv.conf
        for d in $dns; do
            echo "nameserver $d" >> /etc/resolv.conf
        done
        ;;
esac
exit 0
UDSCRIPT
chmod 755 "$TARGET/usr/share/udhcpc/default.script"
echo "udhcpc lease script: usr/share/udhcpc/default.script"

# Shell scripts into /usr/bin, which is on the guest PATH
# (/bin:/usr/bin:/sbin:/usr/sbin - see init.c's child_envp).
#
# Installed under their name with the .sh suffix dropped, so scripts/lsblk.sh
# becomes /usr/bin/lsblk and can be called the way the tool it replaces is.
# Nothing else in the guest provides it: busybox has no lsblk applet at all,
# which is why the script exists, so there is no shadowing to reason about.
#
# The loop globs rather than listing names, so a new script needs no edit here.
if [[ -d "$SCRIPTS" ]]; then
    installed=()
    for script in "$SCRIPTS"/*.sh; do
        [[ -f "$script" ]] || continue
        base="${script##*/}"
        cp "$script" "$TARGET/usr/bin/${base%.sh}"
        chmod 0755 "$TARGET/usr/bin/${base%.sh}"
        installed+=("${base%.sh}")
    done
    if (( ${#installed[@]} > 0 )); then
        echo "scripts in /usr/bin: ${installed[*]}"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: curl, ssh client+server, sqlite3  (+ gitconfig, locale)
# ---------------------------------------------------------------------------
# Copied before the runtime-dependency sweep below, so the sweep sees sshd,
# sqlite3 and curl and picks up anything build_nettools.sh's closure pass
# missed (libreadline for ssh, libedit for sqlite3, libssh2 for scp/sftp).
#
# Optional, exactly like X11: without nettools-dist/ the guest still boots, it
# just has no curl and no ssh. That keeps a text-only build possible.
if [[ -d "$NETTOOLS_DIST" ]]; then
    echo "installing network tools from nettools-dist/ ($(du -sh "$NETTOOLS_DIST" | cut -f1))..."
    cp -a "$NETTOOLS_DIST/." "$TARGET/"

    # /bin/lsblk as well as /usr/bin/lsblk. Both names are conventional for
    # util-linux tools and a symlink is free; the scripts loop above installs
    # into /usr/bin, so only the /bin name is new here. Relative target so it
    # survives the initramfs being moved or unpacked anywhere.
    ln -sf /usr/bin/lsblk "$TARGET/bin/lsblk"

    # sshd wants these to exist and be root-owned with tight modes. The host
    # /etc/ssh is mode 755 and would be shipped as-is by cp -a; sshd refuses a
    # group/world-writable dir but accepts 755, so this is belt-and-braces plus
    # it makes the intent explicit rather than inherited.
    chmod 755 "$TARGET/etc/ssh" 2>/dev/null || true
    chmod 644 "$TARGET/etc/ssh/sshd_config" "$TARGET/etc/ssh/ssh_config" 2>/dev/null || true
    chmod 644 "$TARGET/etc/ssh/moduli" 2>/dev/null || true

    # ALSA needs /var/lib/alsa to exist and be writable by root for its own
    # state (cards/ctl/asound.conf.lock etc). Without it some paths fail with
    # EACCES rather than a clean error. Cheap, and matches what a normal
    # alsa-lib install has.
    mkdir -p "$TARGET/var/lib/alsa"
    chmod 755 "$TARGET/var/lib/alsa"

    # /dev/snd/* comes from devtmpfs once a driver binds, so nothing is staged
    # here. init logs whether a card actually appeared, because CONFIG_SOUND
    # being on in the kernel only guarantees the driver exists - not that a codec
    # matched, which is the usual reason a card shows up in /proc/asound/cards
    # and then still fails to open a PCM with -112.

    # /etc/mtab is a symlink to /proc/mounts on any normal system. btop reads it
    # to list mounted filesystems, and without it that panel is simply empty
    # (CPU and memory still work). Cheap to add and it removes a confusing gap.
    ln -sf /proc/mounts "$TARGET/etc/mtab"

    # /etc/passwd and /etc/group are written ABOVE this point, so the sshd
    # privilege-separation user has to be appended after the fact. OpenSSH 10
    # hard-exits at startup ("Privilege separation user sshd does not exist")
    # if uid 22 is absent from both files. uid/gid 22 is what upstream uses and
    # what the sshd binary was compiled against.
    #
    # /var/empty is the privsep chroot's cwd. It must exist, be root-owned, and
    # NOT be group/world-writable or sshd refuses to start.
    if ! grep -q '^sshd:' "$TARGET/etc/passwd"; then
        printf 'sshd:x:22:22:sshd privsep:/var/empty:/bin/false\n' >> "$TARGET/etc/passwd"
    fi
    if ! grep -q '^sshd:' "$TARGET/etc/group"; then
        printf 'sshd:x:22:\n' >> "$TARGET/etc/group"
    fi
    mkdir -p "$TARGET/var/empty"
    chmod 755 "$TARGET/var/empty"

    # The D-Bus system bus identity. dbus-daemon drops privileges to this user,
    # and refuses to start without it:
    #
    #     Failed to start message bus: Failed to connect to socket ... No such file
    #     (or, more usually) "Could not get UID and GID for username messagebus"
    #
    # uid 81 is dbus's own upstream choice and is what most distributions use, so
    # it is kept for compatibility with anything that hardcodes it. The account is
    # not creatable by a user logging in: the shell is /bin/false and the home is
    # /dev/null, so it exists purely as an identity to run as.
    if ! grep -q '^messagebus:' "$TARGET/etc/passwd"; then
        printf 'messagebus:x:81:81:System message bus:/var/lib/dbus:/bin/false\n' \
            >> "$TARGET/etc/passwd"
    fi
    if ! grep -q '^messagebus:' "$TARGET/etc/group"; then
        printf 'messagebus:x:81:\n' >> "$TARGET/etc/group"
    fi

    # Locale: glibc's C.UTF-8 is built in, so there is no locale archive to
    # stage and no locale-gen to run. cp -a above already placed the selection
    # at /etc/locale.conf; just confirm it landed, because a silently missing
    # locale.conf shows up much later as mangled filenames.
    if [[ -f "$TARGET/etc/locale.conf" ]]; then
        echo "locale: $(tr '\n' ' ' < "$TARGET/etc/locale.conf") (glibc built-in, no archive)"
    else
        echo "error: nettools-dist/etc/locale.conf missing" >&2
        exit 1
    fi

      echo "net tools installed (sshd_config: /etc/ssh/sshd_config, privsep uid 22 ready)"

      # btop's user config. Placed HERE, immediately after nettools-dist is copied,
      # rather than up with the other $HOME setup: the theme it selects lives in
      # usr/share/btop/themes, which does not exist in the target until the copy
      # above has happened. Written any earlier, the existence test below fails and
      # the config is silently never created - which is exactly what happened, and
      # left btop on its built-in Default theme with a staged theme file that
      # nothing pointed at.
      if [[ -f "$TARGET/usr/share/btop/themes/tokyo-night.theme" ]]; then
          mkdir -p "$TARGET/home/user/.config/btop"
          cat > "$TARGET/home/user/.config/btop/btop.conf" << 'BTOPCONF'
# Staged by assemble-rootfs.sh.
#
# Only the theme is set. Everything else stays at btop's defaults on purpose: the
# defaults are what upstream tests against, and a config full of restated defaults
# is a second place for them to drift out of sync with the binary.
#
# The theme itself lives in /usr/share/btop/themes, which btop finds relative to
# its own binary. A copy in ~/.config/btop/themes would shadow it, and that is the
# supported way to override without touching /usr.
color_theme = "tokyo-night"

# False so the graphs are drawn on the terminal's own background instead of
# painting their own. The terminal behind btop is #24273b and btop's theme
# background is #1a1b26, so leaving this True puts a visibly darker rectangle
# inside a lighter window - the same layering mistake the desktop config used to
# make before the terminal was made the lightest surface of the three.
theme_background = false
BTOPCONF
          echo "btop: tokyo-night theme selected"
      else
          echo "btop: no tokyo-night.theme staged - btop keeps its built-in theme"
      fi
  else
      echo "no nettools-dist/ - building without curl/ssh/sqlite3 (run build_nettools.sh)"
  fi

# D-Bus system bus. Optional in the same sense as everything above: without it
# the guest still boots, it just has no wireless (iwctl is a D-Bus client, so
# there is nothing for it to talk to) and no bluetooth. Kept separate from
# nettools-dist because it has a different provenance - copied from the host and
# verified by its own build script - and because it deliberately does NOT ship
# /etc/machine-id, which is exactly the kind of omission that gets "helpfully"
# filled in later by something copying a host's /etc.
if [[ -d "$DBUS_DIST" ]]; then
  echo "installing D-Bus from dbus-dist/ ($(du -sh "$DBUS_DIST" | cut -f1))..."
  cp -a "$DBUS_DIST/." "$TARGET/"

  # This is an assertion, not a warning. dbus-dist is required to leave
  # /etc/machine-id absent and init.c generates one on first boot. If a machine-id
  # is ever present here then every machine booted from this image shares one
  # D-Bus identity, and the symptom - two of them on a network confusing each
  # other's bus connections - points nowhere near the cause.
  if [[ -e "$TARGET/etc/machine-id" ]]; then
    echo "error: $TARGET/etc/machine-id exists - it must be generated on first boot," >&2
    echo "       never baked into an image (dbus-dist must not create it)" >&2
    exit 1
  fi

  mkdir -p "$TARGET/var/lib/dbus" "$TARGET/etc/dbus-1"
  chmod 755 "$TARGET/var/lib/dbus" "$TARGET/etc/dbus-1"
  chmod 644 "$TARGET/etc/dbus-1/system.conf"
  # Real copies under /bin as well, matching how curl and the other host-copied
  # tools are staged. Not required functionally - init execs /usr/bin/dbus-daemon
  # by absolute path and PATH includes /usr/bin - but a tool that exists at one
  # path and not the other is the kind of inconsistency that costs an hour
  # later.
  for t in dbus-daemon dbus-uuidgen dbus-send; do
    if [ -f "$TARGET/usr/bin/$t" ]; then
      cp -f "$TARGET/usr/bin/$t" "$TARGET/bin/$t"
    fi
  done
  echo "  D-Bus: system.conf staged, machine-id correctly absent"
else
  echo "no dbus-dist/ - building without D-Bus (no wireless, no bluetooth)"
fi

# Wireless: iwd + iwctl. Kept separate from D-Bus above because the dependency
# runs the other way round - iwctl is a D-Bus client and does nothing at all
# without a bus, so a guest with iwd but no dbus-daemon has an `iwctl` that
# starts and immediately exits with a bus error.
if [[ -d "$IWD_DIST" ]]; then
  echo "installing iwd from iwd-dist/ ($(du -sh "$IWD_DIST" | cut -f1))..."
  cp -a "$IWD_DIST/." "$TARGET/"
  # Real copies under /bin as well as /usr/bin, which is how curl and the rest of
  # the host-copied tools are staged - both paths exist on disk, neither is a
  # symlink into the other.
  #
  # This was a symlink to /usr/bin/iwctl while iwctl itself was staged to /bin,
  # which produced a DANGLING link: iwctl appeared in the tree and could not be
  # executed. The failure is invisible in a build log and only shows up as
  # "command not found" on the machine, at the moment someone tries to connect
  # to Wi-Fi.
  for t in iwctl; do
    [ -f "$TARGET/usr/bin/$t" ] && cp -f "$TARGET/usr/bin/$t" "$TARGET/bin/$t"
  done
  mkdir -p "$TARGET/var/lib/iwd"
  chmod 700 "$TARGET/var/lib/iwd"
  chmod 755 "$TARGET/usr/libexec/iwd" 2>/dev/null || true
  echo "  wireless: iwd + iwctl staged, /var/lib/iwd ready (no credentials shipped)"
else
  echo "no iwd-dist/ - building without wireless"
fi

# Bluetooth: bluetoothd + clients, from the same BlueZ build as each other.
if [[ -d "$BLUEZ_DIST" ]]; then
  echo "installing BlueZ from bluesz-dist/ ($(du -sh "$BLUEZ_DIST" | cut -f1))..."
  cp -a "$BLUEZ_DIST/." "$TARGET/"
  chmod 755 "$TARGET/usr/libexec/bluetooth/bluetoothd" 2>/dev/null || true
  echo "  bluetooth: bluetoothd + bluetoothctl + btmon staged"
else
  echo "no bluesz-dist/ - building without bluetooth"
fi

# Kernel firmware. Optional like everything else, but the failure mode when it is
# missing is worth stating: the wireless driver still binds, so wlan0 appears and
# then never brings its interface up, and the reason is a single line in dmesg
# that a user has no reason to know to go looking for.
if [[ -d "$FW_DIST" ]]; then
  echo "installing firmware from fw-dist/ ($(du -sh "$FW_DIST" | cut -f1))..."
  cp -a "$FW_DIST/." "$TARGET/"
  chmod -R a+rX "$TARGET/lib/firmware"
  echo "  firmware: $(find "$TARGET/lib/firmware" -type f | wc -l) blobs"
else
  echo "no fw-dist/ - wireless drivers will load but find no firmware"
fi

# A web browser: w3m, in a terminal.
#
# WHY A TEXT BROWSER, given this image has a full X11 desktop.
#
# NetSurf was the first choice and was dropped for a concrete reason rather than
# a preference. Current NetSurf ships only these frontends:
#
#     amiga atari beos framebuffer gtk monkey qt riscos windows
#
# There is no X11 frontend - frontends/x11 was removed years ago - so a NetSurf
# that draws to X is a NetSurf that links GTK3. GTK3's closure is glib, gobject,
# gio, pango, pangocairo, cairo, harfbuzz, fribidi, atk, atspi, gdk-pixbuf,
# epoxy, libXft and the X11 extensions, plus gsettings schemas, the Adwaita icon
# theme and the gdk-pixbuf loader cache. That is a large, hard-to-audit addition
# to a 181M image whose premise is a small rootfs with a built-in kernel and no
# package manager, and it would be added for one program.
#
# w3m's own requirements are ncurses-era terminfo, OpenSSL, zlib and libbsd, of
# which this image already had all but terminfo. It renders inside mlterm, which
# is already the desktop's terminal, so it adds no display machinery at all.
#
# NO LAUNCHER, KEYBINDING OR DESKTOP ENTRY, DELIBERATELY. It is run as a plain
# command from any shell: `w3m`, or `w3m https://example.org`. Nothing else in
# this image advertises a program this way either - the i3 keybindings are a
# fixed set for terminal and file manager, and adding one keybinding per program
# does not scale to a program list. If w3m turns out to be used constantly, a
# binding is a one-line change to etc-rlos/i3.config at that point.
#
# Note /usr/bin is on the PATH init passes to every child, so no copy under /bin
# is needed for `w3m` to resolve.
if [[ -d "$W3M_DIST" ]]; then
  echo "installing w3m from w3m-dist/ ($(du -sh "$W3M_DIST" | cut -f1))..."
  cp -a "$W3M_DIST/." "$TARGET/"
  chmod 755 "$TARGET/usr/bin/w3m" 2>/dev/null || true
  # w3m's help pages are read by w3m itself out of /usr/share/w3m. Without them
  # the built-in help is a silent no-op rather than an error, so they are staged.
  chmod -R a+rX "$TARGET/usr/share/w3m" 2>/dev/null || true
  # libtinfo is the one genuinely new library: the image already had libssl,
  # libcrypto, libz, libbsd and libc. libtinfow was present too, but that is the
  # wide-character terminfo library mlterm uses, and it is a different object -
  # it does not satisfy a DT_NEEDED on libtinfo.so.6.
  if [[ -e "$TARGET/usr/lib64/libtinfo.so.6" ]]; then
    echo "  browser: w3m staged at /usr/bin/w3m, terminfo library present"
  else
    echo "  *** WARNING: libtinfo.so.6 missing - w3m will not start ***"
  fi
else
  echo "no w3m-dist/ - building without a browser"
fi


# mlterm needs no staging of its own here. Its system config lives at
# /usr/etc/mlterm/{main,aafont}, which is where the binary's compiled-in
# SYSCONFDIR (/usr/etc) makes it look; build_x11.sh writes those into
# x11-dist/ and they arrive with the tree copied in above. Nothing sets
# MLTERM_CONFIG_DIR or passes a config flag, so there is no second copy that
# can drift from the image.

echo "done: rootfs assembled in $TARGET/ ($(du -sh "$TARGET" | cut -f1))"
