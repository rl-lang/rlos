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
#   ./assemble-rootfs.sh <target-dir>       # text-only image (the default)
#   ./assemble-rootfs.sh -x <target-dir>   # same, plus the X11 desktop
# Run from anywhere; rlos-relative inputs resolve from the script's location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourced before the option parsing below, which reports errors through errmsg.
source "$SCRIPT_DIR/build-lib.sh"
PROGRAMS="$SCRIPT_DIR/rl_programs"
SCRIPTS="$SCRIPT_DIR/scripts"

RL_BIN_PROGRAMS=(rlsh whoami hostname ls wc rm fbtest log shutdown reboot help)
RL_BINS="$SCRIPT_DIR/rl-bins/rlos"
INIT_BIN="$SCRIPT_DIR/rlos-initramfs/init"
GIT_DIST="$SCRIPT_DIR/git-dist"
GCC_DIST="$SCRIPT_DIR/gcc-dist"
BINUTILS_DIST="$SCRIPT_DIR/binutils-dist"
BB_DIST="$SCRIPT_DIR/busybox-dist"
X11_DIST="$SCRIPT_DIR/x11-dist"
XAPPS_DIST="$SCRIPT_DIR/xapps-dist"
WAYLAND_DIST="$SCRIPT_DIR/wayland-dist"
INSTALLER_DIST="$SCRIPT_DIR/installer-dist"
GRUB_DIST="$SCRIPT_DIR/grub-dist"
BASE_DIST="$SCRIPT_DIR/base-dist"
KERNEL="$SCRIPT_DIR/kernel-images/rlos/bzImage"
NETTOOLS_DIST="$SCRIPT_DIR/nettools-dist"
DBUS_DIST="$SCRIPT_DIR/dbus-dist"
IWD_DIST="$SCRIPT_DIR/iwd-dist"
BLUEZ_DIST="$SCRIPT_DIR/bluesz-dist"
FW_DIST="$SCRIPT_DIR/fw-dist"
FF_DIST="$SCRIPT_DIR/fastfetch-dist"
W3M_DIST="$SCRIPT_DIR/w3m-dist"
ATOM_IMAGE="$SCRIPT_DIR/rlos-atom/atom-rootfs.tar.gz"
BWRAP_DIST="$SCRIPT_DIR/rlos-atom/bwrap-dist"

usage() {
    cat >&2 << EOF
usage: assemble-rootfs.sh [-x|--x11 | -w|--wayland] [-i|--installer] <target-dir>

Assembles the shared rlos userspace tree into <target-dir>. The same tree
becomes the initramfs and the disk root, so the two can never drift.

  -x, --x11       include the X11 desktop from x11-dist/ (Xorg + i3 + mlterm)
  -w, --wayland   include the Wayland desktop from wayland-dist/ (sway + foot)
  -i, --installer include the in-guest installer (rlos-install + sfdisk +
                  the GRUB boot artifacts)

With no backend flag the image is text-console only, even when the build trees
exist - the presence of a build tree does not decide what ships.

X11 and Wayland are mutually exclusive. The X11 GUI applications (feh, xfiles)
come from xapps-dist/ and ship with EITHER desktop.
EOF
}

# --- options ---
# The desktop is opt-in, not auto-detected: init.c gates the desktop on the
# compositor being present, so leaving it unstaged is all it takes to get a
# text-only boot.
BACKEND="text"
WANT_X11=0
WANT_WAYLAND=0
WITH_INSTALLER=0
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -x|--x11)     WANT_X11=1; shift ;;
        -w|--wayland) WANT_WAYLAND=1; shift ;;
        -i|--installer) WITH_INSTALLER=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) errmsg "unknown option '$1'"; usage; exit 1 ;;
        *)
            if [[ -n "$TARGET" ]]; then
                errmsg "too many arguments (already have '$TARGET')"
                usage
                exit 1
            fi
            TARGET="$1"
            shift ;;
    esac
done
if [[ -z "$TARGET" ]]; then
    usage
    exit 1
fi
if [[ "$WANT_X11" == "1" && "$WANT_WAYLAND" == "1" ]]; then
    errmsg "-x and -w are mutually exclusive - pick one desktop"
    usage
    exit 1
fi
if [[ "$WANT_X11" == "1" ]]; then
    BACKEND="x11"
elif [[ "$WANT_WAYLAND" == "1" ]]; then
    BACKEND="wayland"
fi

header "Checking prerequisites"

# base-dist/ (sudo, ttyrec, rlin, rlperf) is NOT gated on a desktop: those are
# not desktop tools and the text console needs them too.
case "$BACKEND" in
    x11)
        if [[ ! -d "$X11_DIST/bin" ]]; then
            errmsg "-x was given but $X11_DIST/bin does not exist"
            info  "hint: run build_x11.sh first, or drop -x for a text-only image." >&2
            exit 1
        fi
        ;;
    wayland)
        if [[ ! -d "$WAYLAND_DIST/bin" ]]; then
            errmsg "-w was given but $WAYLAND_DIST does not exist"
            if [[ ! -f "$SCRIPT_DIR/build_wl.sh" ]]; then
                info  "the Wayland backend is not implemented yet." >&2
                info  "build_wl.sh does not exist, so there is nothing to run." >&2
                info  "Use -x for a desktop, or no flag for text-only." >&2
            else
                info  "hint: run build_wl.sh first." >&2
            fi
            exit 1
        fi
        ;;
esac

# The installer needs two things and they fail separately, because they come
# from different places: the partition/filesystem tools are a build product
# (build_install_tools.sh), while the GRUB boot artifacts are generated by
# mkiso.sh on the way in. Naming both in the error is the difference between
# "run this" and "hunt for what is missing".
if [[ "$WITH_INSTALLER" == "1" ]]; then
    if [[ ! -d "$INSTALLER_DIST/usr/bin" ]]; then
        errmsg "-i was given but $INSTALLER_DIST does not exist"
        info  "hint: run build_install_tools.sh (sfdisk, mke2fs, e2fsck, ...)." >&2
        exit 1
    fi
    if [[ ! -f "$GRUB_DIST/core.img" || ! -f "$GRUB_DIST/grubx64.efi" ]]; then
        errmsg "-i was given but $GRUB_DIST has no GRUB boot artifacts"
        info  "hint: these are generated by 'mkiso.sh -i', not built by hand." >&2
        info  "  Running build_initramfs.sh -i directly skips that step." >&2
        exit 1
    fi
    # The kernel has to be reachable from inside the running system, and it
    # normally is not: GRUB reads /boot/bzImage off the ISO, but nothing mounts
    # the ISO afterwards - init.c has no iso9660 support at all, and when booted
    # from a USB stick there is no ISO block device to mount either. The guest's
    # / is the unpacked initramfs, which has no /boot in it. So the kernel is
    # copied in here, at build time, where it is just a file.
    if [[ ! -f "$KERNEL" ]]; then
        errmsg "-i was given but $KERNEL does not exist"
        info  "hint: run compile_kernel.sh first." >&2
        exit 1
    fi
fi

# Init
if [[ ! -x "$INIT_BIN" ]]; then
    fail "$INIT_BIN not found - run rlos-initramfs/compile_init.sh first"
fi

# RL Toolchain
for tool_bin in rl rlc rlt rldocs rlrepl rlsp; do
    if [[ ! -x "$RL_BINS/$tool_bin" ]]; then
        fail "$RL_BINS/$tool_bin not found - run build_rl_bins.sh first"
    fi
done

# RL Programs
for prog in "${RL_BIN_PROGRAMS[@]}"; do
    if [[ ! -f "$PROGRAMS/$prog.rl" ]]; then
        fail "required program source code '$prog.rl' not found in '$PROGRAMS'"
    fi
done
if [[ ! -f "$PROGRAMS/nano/nano.rl" ]]; then
    fail "required program source code 'nano/nano.rl' not found in '$PROGRAMS'"
fi

# Git
if [[ ! -x "$GIT_DIST/bin/git" ]]; then
    fail "$GIT_DIST/bin/git not found - run build_git.sh first"
fi

# GCC
if [[ ! -x "$GCC_DIST/bin/gcc" ]]; then
    fail "$GCC_DIST/bin/gcc not found - run build_gcc.sh first"
fi

# Linker
if [[ ! -x "$BINUTILS_DIST/bin/ld" ]]; then
    fail "$BINUTILS_DIST/bin/ld not found - run build_binutils.sh first"
fi

# BusyBox
if [[ ! -x "$BB_DIST/bin/busybox" ]]; then
    fail "$BB_DIST/bin/busybox not found - run build_busybox.sh first"
fi
if [[ ! -f "$BB_DIST/APPLYTS" ]]; then
    fail "$BB_DIST/APPLYTS not found - run build_busybox.sh first"
fi

header "Target"
# --- Setting up directory ---
step "assembling rootfs in $TARGET/..."
rm -rf "$TARGET"
mkdir -p "$TARGET"/{bin,sbin,dev,proc,sys,tmp,run,root,lib64,usr/lib,usr/lib64}
mkdir -p "$TARGET/etc"

# openssh
if command -v openssl > /dev/null 2>&1; then
    USER_PW_HASH="$(openssl passwd -6 -salt rlos root)"
else
    fail "openssl not found on PATH - cannot hash the 'user' password"
fi
printf 'root:x:0:0:root:/root:/bin/ash\n' > "$TARGET/etc/passwd"
printf 'user:x:1000:1000:user:/home/user:/bin/ash\n' >> "$TARGET/etc/passwd"
printf 'root:x:0:\nuser:x:1000:\n' > "$TARGET/etc/group"
printf 'root:!:19000:0:99999:7:::\n' > "$TARGET/etc/shadow"
printf 'user:%s:19000:0:99999:7:::\n' "$USER_PW_HASH" >> "$TARGET/etc/shadow"
chmod 600 "$TARGET/etc/shadow"

# sudo
mkdir -p "$TARGET/etc/sudoers.d"
cat > "$TARGET/etc/sudoers" << 'SUDOEOF'
Defaults	env_reset
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root	ALL=(ALL:ALL) ALL
user	ALL=(ALL:ALL) ALL
SUDOEOF
chmod 440 "$TARGET/etc/sudoers"

# hostname
echo "system" > "$TARGET/etc/hostname"

# hosts
printf '127.0.0.1\tlocalhost\n127.0.1.1\tsystem\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
    > "$TARGET/etc/hosts"

# user home directory
mkdir -p "$TARGET/home/user"

# OS release
OS_RELEASE_SRC="$SCRIPT_DIR/etc-rlos/os-release"
if [[ -f "$OS_RELEASE_SRC" ]]; then
    install -m 0644 "$OS_RELEASE_SRC" "$TARGET/etc/os-release"
else
    errmsg "etc-rlos/os-release missing - fastfetch's os module would print"
    echo "       nothing, and no tool can identify this OS" >&2
    exit 1
fi

# scripts for ~/scripts
SCRIPT_SRC="$SCRIPT_DIR/etc-rlos/scripts"
if [[ -d "$SCRIPT_SRC" ]]; then
    mkdir -p "$TARGET/home/user/scripts"
    n=0
    for s in "$SCRIPT_SRC"/*.sh; do
        [ -f "$s" ] || continue
        install -m 0755 "$s" "$TARGET/home/user/scripts/$(basename "$s")"
        n=$((n + 1))
    done
    if [[ -f "$ATOM_IMAGE" ]]; then
        substep "home/user/scripts: $n scripts (atom + capture + xmenu)"
    else
        substep "home/user/scripts: $n scripts (WARNING: $ATOM_IMAGE not built, atom-*.sh will not run)"
    fi
fi

header "Base tools and desktop"
# Tools with no X11 dependency, staged into every image regardless of -x.
# Separate from x11-dist/ so the -x flag cannot take sudo and ttyrec with it.
if [[ -d "$BASE_DIST" ]]; then
    step "installing base tools from base-dist/ ($(du -sh "$BASE_DIST" | cut -f1))..."
    cp -a "$BASE_DIST/." "$TARGET/"
    N_BASE=0
    for t in sudo ttyrec ttyplay rlin rlperf nnn; do
        if [[ -x "$TARGET/usr/bin/$t" ]]; then
            N_BASE=$((N_BASE + 1))
        else
            warn "base-dist/usr/bin/$t missing"
        fi
    done
    substep "base tools: $N_BASE/6 staged (sudo ttyrec ttyplay rlin rlperf nnn)"
else
    warn "no base-dist/ - no sudo, ttyrec, ttyplay, rlin, rlperf or nnn"
    echo "  (run build_base_tools.sh to add them; they are needed on the text console too)"
fi

# The X11 GUI applications (feh, xfiles). These ship with EITHER desktop
# backend, not just -x: in a Wayland session they run under XWayland. They live
# in their own dist rather than x11-dist/ precisely so the backend flag cannot
# decide whether a file manager exists.
if [[ "$BACKEND" != "text" ]]; then
    if [[ -d "$XAPPS_DIST" ]]; then
        step "installing X11 apps from xapps-dist/ ($(du -sh "$XAPPS_DIST" | cut -f1))..."
        cp -a "$XAPPS_DIST/." "$TARGET/"
        N_XAPPS=0
        for t in feh xfiles xfilesctl xfilesthumb; do
            if [[ -x "$TARGET/usr/bin/$t" ]]; then
                N_XAPPS=$((N_XAPPS + 1))
            else
                warn "xapps-dist/usr/bin/$t missing"
            fi
        done
        substep "x11 apps: $N_XAPPS/4 staged (feh xfiles xfilesctl xfilesthumb)"
        # Imlib2's loaders are dlopen'd by name, so nothing checks their
        # presence. A tree with libImlib2 and no loaders beside it decodes
        # nothing and reports it as "unsupported format" rather than as the
        # missing module it is, so assert them here instead.
        N_LOADERS="$(find "$TARGET/usr/lib64/imlib2/loaders" -name '*.so' 2>/dev/null | wc -l)"
        if [[ "$N_LOADERS" -eq 0 ]]; then
            fail "no Imlib2 loaders staged - feh would load no image formats at all"
        fi
        substep "imlib2 loaders: $N_LOADERS staged"
    else
        warn "no xapps-dist/ - no feh, xfiles, xfilesctl or xfilesthumb"
        echo "  (run build_xapps.sh; these ship with any desktop backend)"
    fi
fi

# The in-guest installer. Opt-in via -i, because it is ~5.5M of partitioning and
# filesystem tools plus ~760K of GRUB boot artifacts that a plain live image has
# no use for. rlos-install.sh itself is one of the etc-rlos/scripts/*.sh files,
# so the existing staging glob above has already put it in the image.
if [[ "$WITH_INSTALLER" == "1" ]]; then
    step "staging installer tools from installer-dist/ ($(du -sh "$INSTALLER_DIST" | cut -f1))..."
    cp -a "$INSTALLER_DIST/." "$TARGET/"
    N_INST=0
    for t in sfdisk mke2fs tune2fs resize2fs e2fsck; do
        if [[ -x "$TARGET/usr/bin/$t" ]]; then
            N_INST=$((N_INST + 1))
        else
            fail "installer-dist/usr/bin/$t missing"
        fi
    done
    substep "installer tools: $N_INST/5 staged (sfdisk mke2fs tune2fs resize2fs e2fsck)"

    step "staging GRUB boot artifacts from grub-dist/ ($(du -sh "$GRUB_DIST" | cut -f1))..."
    mkdir -p "$TARGET/usr/share/rlos/grub"
    cp -a "$GRUB_DIST/." "$TARGET/usr/share/rlos/grub/"
    N_GRUB=0
    for f in core.img grubx64.efi boot.img diskboot.img; do
        if [[ -s "$TARGET/usr/share/rlos/grub/$f" ]]; then
            N_GRUB=$((N_GRUB + 1))
        else
            fail "grub artifact $f missing or empty - the installed disk would not boot"
        fi
    done
    substep "grub artifacts: $N_GRUB/4 required present (grubia32.efi optional)"

    step "staging the kernel for the installed system..."
    mkdir -p "$TARGET/boot/grub"
    cp "$KERNEL" "$TARGET/boot/bzImage"
    substep "kernel at /boot/bzImage ($(du -h "$TARGET/boot/bzImage" | cut -f1))"
fi

# setting up x11 stuff if exist
if [[ "$BACKEND" == "x11" ]]; then
    step "installing X11 stack from x11-dist/ ($(du -sh "$X11_DIST" | cut -f1))..."
    cp -a "$X11_DIST/." "$TARGET/"
    chmod 755 "$TARGET"/bin/* 2>/dev/null || true
    mkdir -p "$TARGET/tmp/.X11-unix" "$TARGET/etc/fonts" "$TARGET/etc/X11"
    chmod 1777 "$TARGET/tmp"
    cp -f "$TARGET/usr/share/rlos/fonts.conf" "$TARGET/etc/fonts/fonts.conf"
    for cfg in i3.config; do
        if [[ ! -f "$SCRIPT_DIR/etc-rlos/$cfg" ]]; then
            fail "etc-rlos/$cfg missing"
        fi
        cp -f "$SCRIPT_DIR/etc-rlos/$cfg" "$TARGET/etc/$cfg"
    done
    for tmpl in ms fbdev; do
        if [[ ! -f "$TARGET/usr/share/rlos/xorg.conf.$tmpl.base" ]]; then
            fail "xorg.conf.$tmpl.base missing from x11-dist - run build_x11.sh first"
        fi
        cp -f "$TARGET/usr/share/rlos/xorg.conf.$tmpl.base" "$TARGET/etc/X11/xorg.conf.$tmpl.base"
    done
      if [[ -f "$SCRIPT_DIR/etc-rlos/rlos-clock" ]]; then
          install -m 0755 "$SCRIPT_DIR/etc-rlos/rlos-clock" "$TARGET/usr/bin/rlos-clock"
          substep "usr/bin/rlos-clock (bar clock)"
      else
          fail "etc-rlos/rlos-clock missing - i3.config's status_command will fail"
      fi
substep "X11 installed (config: etc/fonts/fonts.conf, etc/X11/xorg.conf.{ms,fbdev}.base)"
  elif [[ "$BACKEND" == "wayland" ]]; then
      # The Wayland counterpart of the block above.
      #
      # Deliberately not a variation on the -x block: the two stacks share no
      # configuration format, no helper daemon and no environment. sway is
      # configured entirely by /etc/sway/config (staged by build_wl.sh), the
      # fonts are found through the same fontconfig the X11 side uses, and
      # everything else the compositor needs - a seat, an input stack, libseat -
      # it starts itself or dlopens.
      step "installing Wayland stack from wayland-dist/ ($(du -sh "$WAYLAND_DIST" | cut -f1))..."
      cp -a "$WAYLAND_DIST/." "$TARGET/"
      chmod 755 "$TARGET"/bin/* 2>/dev/null || true

      # Assert the executables before anything else. Every one of these is named
      # either by init.c's supervise table or by sway's config, and both of those
      # fail in the least legible way available when the file is absent: init
      # reports "exec /bin/sway failed" and sway reports nothing at all.
      WL_MISSING_BINS=""
      for b in sway swaybar swaymsg foot swaybg grim; do
          [[ -x "$TARGET/bin/$b" ]] || WL_MISSING_BINS="$WL_MISSING_BINS $b"
      done
      if [[ -n "$WL_MISSING_BINS" ]]; then
          errmsg "these Wayland executables are not in the image:$WL_MISSING_BINS"
          echo "  init.c supervises sway and swaybar; sway's config execs foot." >&2
          echo "  A missing one is a black VT with no explanation." >&2
          echo "  Rebuild with ./build_wl.sh." >&2
          exit 1
      fi
      substep "6/6 executables staged (sway swaybar swaymsg foot swaybg grim)"

      # sway's config. init execs `sway -c /etc/sway/config`, and without -c
      # sway falls back to paths under $HOME - which is uid 1000's, not root's -
      # so this file is the difference between a configured session and sway's
      # compiled-in defaults.
      if [[ ! -f "$TARGET/etc/sway/config" ]]; then
          errmsg "etc/sway/config missing from wayland-dist"
          echo "  init.c execs 'sway -c /etc/sway/config'; without it sway runs" >&2
          echo "  on built-in defaults and every binding in this image is ignored." >&2
          exit 1
      fi
      substep "etc/sway/config staged ($(wc -l < "$TARGET/etc/sway/config") lines)"

      # The same fontconfig as the X11 path. foot resolves faces through
      # fontconfig at startup, and a terminal that cannot find a default face
      # renders boxes or refuses to start, so this is not optional.
      #
      # The mkdir matters: the -x branch gets etc/fonts from its own
      # `mkdir -p "$TARGET/tmp/.X11-unix" "$TARGET/etc/fonts" ...` line, and this
      # branch has no such line, so without it the cp fails on a directory that
      # simply does not exist yet.
      mkdir -p "$TARGET/etc/fonts"
      cp -f "$TARGET/usr/share/rlos/fonts.conf" "$TARGET/etc/fonts/fonts.conf"
      substep "usr/share/rlos/fonts.conf -> etc/fonts/fonts.conf"

      # XDG_RUNTIME_DIR is created by init at boot, not here: it has to be owned
      # by uid 1000 with mode 0700, and doing that during assembly would bake a
      # root-owned directory into the image that init would then have to fix up
      # anyway. Assert only that the parent exists and is world-traversable, so
      # init's mkdir has somewhere to land.
      mkdir -p "$TARGET/run/user"
      chmod 755 "$TARGET/run/user"
      substep "run/user prepared (init creates 1000 at boot, mode 0700)"

      # xapps-dist is handled above and does NOT require XWayland to be present;
      # it stages for any non-text backend. Without XWayland those binaries
      # cannot reach a display, so say so rather than letting the user find out
      # by launching a file manager that exits immediately.
      if [[ ! -x "$TARGET/usr/bin/Xwayland" ]]; then
          warn "-w: XWayland is not built, so the X11 apps (feh, xfiles) have no"
          warn "    display to connect to. XWayland is stage 5 in build_wl.sh."
      fi
      substep "Wayland installed (config: etc/sway/config, fonts, run/user)"
  else
    substep "text-only image (no -x/-w) - no Xorg, no sway, no i3, no foot"
fi

# RLOS Atom and bwrap
if [[ -f "$ATOM_IMAGE" && -d "$BWRAP_DIST" ]]; then
    step "installing rlos-atom ($(du -h "$ATOM_IMAGE" | cut -f1)) + bubblewrap..."
    install -m 0644 "$ATOM_IMAGE" "$TARGET/atom-rootfs.tar.gz"

    cp -a "$BWRAP_DIST/." "$TARGET/"
    if [[ -x "$TARGET/bin/bwrap" ]]; then
        substep "bwrap staged ($(du -h "$TARGET/bin/bwrap" | cut -f1))"
    else
        fail "bwrap not staged from bwrap-dist"
    fi

    if ! tar -tzf "$TARGET/atom-rootfs.tar.gz" >/dev/null 2>&1; then
        fail "staged atom-rootfs.tar.gz is not a readable gzip archive"
    fi
    substep "atom image verified as a readable gzip archive"

    DOC_SRC="$SCRIPT_DIR/rlos-atom/docs"
    if [[ -d "$DOC_SRC" ]]; then
        mkdir -p "$TARGET/usr/share/doc/bwrap"
        install -m 0644 "$DOC_SRC/bwrap.1" "$TARGET/usr/share/doc/bwrap/bwrap.1"
        install -m 0644 "$DOC_SRC/bubblewrap-README.v0.12.0.md" \
            "$TARGET/usr/share/doc/bwrap/README.md"
        install -m 0644 "$DOC_SRC/PROVENANCE.md" \
            "$TARGET/usr/share/doc/bwrap/PROVENANCE.md"
        substep "bubblewrap docs: $(ls "$TARGET/usr/share/doc/bwrap" | wc -l) files"
    else
        warn "rlos-atom/docs/ missing - shipping without bwrap documentation"
    fi

    if [[ -f "$SCRIPT_DIR/rlos-atom/ATOM-BWRAP.md" ]]; then
        mkdir -p "$TARGET/usr/share/doc"
        install -m 0644 "$SCRIPT_DIR/rlos-atom/ATOM-BWRAP.md" \
            "$TARGET/usr/share/doc/ATOM-BWRAP.md"
        install -m 0644 "$SCRIPT_DIR/rlos-atom/ATOM-BWRAP.md" \
            "$TARGET/home/user/ATOM-BWRAP.md"
        substep "guide: /usr/share/doc/ATOM-BWRAP.md, /home/user/ATOM-BWRAP.md"
    fi

    substep "atom: image staged; init.c enforces root ownership at boot"
else
    warn "no rlos-atom/atom-rootfs.tar.gz - building without the atom container"
    echo "  (run rlos-atom/build_atom_rootfs.sh, then pack_atom_image.sh,"
    echo "   then build_atom_bwrap.sh to include it)"
fi
    # Fastfetch setup
    if [[ -d "$FF_DIST/usr/bin" ]]; then
        step "installing fastfetch from fastfetch-dist/ ($(du -sh "$FF_DIST" | cut -f1))..."
        cp -a "$FF_DIST/." "$TARGET/"
        chmod 755 "$TARGET/usr/bin/fastfetch"
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
        substep "logo: etc/xdg/fastfetch/fastfetch.jsonc -> usr/share/rlos/ff_logo.txt ($LOGO_LINES lines)"
    else
        substep "no ff_logo.txt in the repo - fastfetch will use its built-in logo"
    fi
else
    warn "no fastfetch-dist/ - skipping fastfetch (run build_fastfetch.sh to add it)"
fi

header "Init and toolchain"
# symlink init
step "installing init (sbin/init + /init symlink)..."
cp "$INIT_BIN" "$TARGET/sbin/init"
chmod 755 "$TARGET/sbin/init"
ln -sf sbin/init "$TARGET/init"

# klogd
KLOGD_BIN="$SCRIPT_DIR/rlos-initramfs/klogd"
if [[ -x "$KLOGD_BIN" ]]; then
    step "installing klogd..."
    cp "$KLOGD_BIN" "$TARGET/sbin/klogd"
    chmod 755 "$TARGET/sbin/klogd"
else
    warn "$KLOGD_BIN not found - run rlos-initramfs/compile_klogd.sh first (boot log stays uncolored)"
fi

# RL toolchain
step "installing toolchain (rl rlc rlt rldocs rlrepl rlsp)..."
for tool_bin in rl rlc rlt rldocs rlrepl rlsp; do
    cp "$RL_BINS/$tool_bin" "$TARGET/bin/"
done
if [[ -x "$BB_DIST/bin/busybox" ]]; then
    ln -sf busybox "$TARGET/bin/sh"
fi

# Git
header "Bundles"
step "installing git bundle..."
cp -a "$GIT_DIST/." "$TARGET/"

# GCC
step "installing gcc bundle (C-only + LTO)..."
cp -a "$GCC_DIST/." "$TARGET/"

step "installing binutils bundle (as/ld - gcc has no built-in ones)..."
cp -a "$BINUTILS_DIST/." "$TARGET/"

mkdir -p "$TARGET/usr/bin"
for tool in gcc gcc-ar gcc-nm gcc-ranlib; do
    mv -f "$TARGET/bin/$tool" "$TARGET/usr/bin/$tool"
done
for tool in as ld ld.bfd ar nm ranlib objcopy strip size strings addr2line elfedit; do
    if [[ -f "$TARGET/bin/$tool" ]]; then
        mv -f "$TARGET/bin/$tool" "$TARGET/usr/bin/$tool"
    fi
done
ln -sf gcc "$TARGET/usr/bin/cc"

GCC_CC1="$(find "$TARGET/usr/libexec/gcc" -name cc1 -type f 2>/dev/null | head -1)"
GCC_LTO1="$(find "$TARGET/usr/libexec/gcc" -name lto1 -type f 2>/dev/null | head -1)"
if [[ ! -x "$TARGET/usr/bin/gcc" ]]; then
    fail "gcc not staged at usr/bin/gcc (it must be at its configured prefix)"
fi
if [[ ! -x "$GCC_CC1" ]]; then
    errmsg "no cc1 under usr/libexec/gcc/ - every in-guest compile would fail"
    echo "  with 'cannot execute cc1: posix_spawnp: No such file or directory'" >&2
    exit 1
fi
if [[ ! -x "$GCC_LTO1" ]]; then
    fail "no lto1 under usr/libexec/gcc/ - 'rlt --compile --lto' would fail"
fi
if [[ "$(readlink -f "$TARGET/usr/bin/cc")" != "$(readlink -f "$TARGET/usr/bin/gcc")" ]]; then
    fail "usr/bin/cc does not resolve to usr/bin/gcc"
fi
substep "gcc at usr/bin/gcc, cc1 + lto1 present under usr/libexec/gcc (prefix contract OK)"

# BusyBox
step "installing busybox bundle..."
cp -a "$BB_DIST/." "$TARGET/"

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
    if [ "$skip" = "1" ] || [ -e "$TARGET/bin/$applet" ]; then
        N_BB_SKIPPED=$((N_BB_SKIPPED + 1))
        continue
    fi
    ln -sf busybox "$TARGET/bin/$applet"
    N_BB_LINKED=$((N_BB_LINKED + 1))
done < "$BB_DIST/APPLYTS"

BB_SHADOW=""
while read -r applet; do
    [ -n "$applet" ] || continue
    for ex in $BB_EXCLUDE; do
        [ "$applet" = "$ex" ] && continue 2
    done
    if [ -e "$TARGET/sbin/$applet" ] || [ -e "$TARGET/usr/sbin/$applet" ]; then
        BB_SHADOW="$BB_SHADOW $applet"
    fi
done < "$BB_DIST/APPLYTS"
if [ -n "$BB_SHADOW" ]; then
    errmsg "busybox applets would shadow binaries staged in sbin:$BB_SHADOW"
    echo "hint: add them to BB_EXCLUDE with a note on why." >&2
    exit 1
fi
substep "busybox: $N_BB_LINKED applets linked, $N_BB_SKIPPED left to rl/git/gcc"

if [[ ! -x "$TARGET/bin/rescue" ]]; then
    fail "$BB_DIST/bin/rescue missing or not executable"
fi
substep "busybox: rescue shell staged (busybox ash, rlsh remains the default)"

header "Runtime libraries"
# Needed Libraries
step "copying runtime library dependencies for everything staged..."
substep "(preserving absolute paths + flat /usr/lib64, no ld.so.cache in guest)"
# base-dist's binaries are named explicitly rather than globbing
# $TARGET/usr/bin/*, which also holds gcc, w3m, fastfetch and the nettools
# binaries - widening the closure every time one of those dists changes. Their
# libraries come from other dists (sudo->nettools/w3m, ttyrec->gcc), so check
# them rather than assume.
DEPS="$(for tool_bin in "$TARGET"/bin/* "$TARGET"/usr/libexec/git-core/* \
                   "$BASE_DIST"/usr/bin/*; do
    [[ -f "$tool_bin" && -x "$tool_bin" ]] || continue
    ldd "$tool_bin" 2>/dev/null | awk '{print $3}'
done | grep '^/' | sort -u || true)"
if [[ -z "$DEPS" ]]; then
    warn "no dynamic dependencies found (statically linked toolchain?)"
else
    for lib in $DEPS; do
        if [[ -f "$lib" ]]; then
            mkdir -p "$TARGET/$(dirname "$lib")"
            cp -n "$lib" "$TARGET/$lib"
            cp -n "$lib" "$TARGET/usr/lib64/"
        else
            warn "dependency $lib listed by ldd but not found on disk"
        fi
    done
fi

  LEAKED_ABS=""
  while IFS= read -r elf; do
      [ -n "$elf" ] || continue
      refs="$(readelf -d "$elf" 2>/dev/null \
                | awk '/NEEDED|RPATH|RUNPATH/ {print $NF}' || true)"
      case "$refs" in
          *"$HOME"*|*"$SCRIPT_DIR"*) LEAKED_ABS="$LEAKED_ABS $(basename "$elf")" ;;
      esac
  done < <(find "$TARGET/bin" "$TARGET/usr/bin" "$TARGET/sbin" \
                "$TARGET/usr/sbin" -type f 2>/dev/null)
  if [[ -n "$LEAKED_ABS" ]]; then
      errmsg "these staged binaries reference the build host's paths:$LEAKED_ABS"
      echo "  A DT_NEEDED/RPATH/RUNPATH holding an absolute host path means the" >&2
      echo "  binary was staged from a build tree instead of an install tree." >&2
      echo "  Check: readelf -d <binary> | grep -E 'RPATH|RUNPATH|NEEDED'" >&2
      exit 1
  fi
  ok "no staged binary references the build host"

LD_LINUX="/lib64/ld-linux-x86-64.so.2"
if [[ -f "$LD_LINUX" ]]; then
    cp "$LD_LINUX" "$TARGET/lib64/"
else
    fail "dynamic linker $LD_LINUX not found"
fi

for rlt_lib in "m" "ffi" "curl" "argon2" "yaml" "pthread" "dl"; do
    if ! compgen -G "$TARGET/usr/lib64/lib${rlt_lib}.so*" > /dev/null \
       && ! compgen -G "$TARGET/usr/lib64/lib*${rlt_lib}*.so*" > /dev/null; then
        errmsg "rlt can emit '-l$rlt_lib' but no matching library is in the guest."
        echo "  Add it to build_gcc.sh's runtime-lib staging loop." >&2
        exit 1
    fi
done
substep "rlt link libraries present: m ffi curl argon2 yaml pthread dl"

# RLT symlinks
step "creating -l dev symlinks for rlt link libraries..."
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
    errmsg "no libNAME.so.N staged for:$rlt_missing"
    echo "  rlt emits -l for these and the linker cannot resolve them." >&2
    exit 1
fi
substep "dev symlinks:$rlt_symlinked"

# RL Programs
step "installing rl-program sources..."
mkdir -p "$TARGET/home/user/programs/rl"
for prog in "${RL_BIN_PROGRAMS[@]}"; do
    cp "$PROGRAMS/$prog.rl" "$TARGET/home/user/programs/rl/$prog.rl"
done
cp "$PROGRAMS/nano/nano.rl" "$TARGET/home/user/programs/rl/nano.rl"
substep "rl sources in /home/user/programs/rl"

# Scripts
step "staging udhcpc lease script..."
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
substep "udhcpc lease script: usr/share/udhcpc/default.script"

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
        substep "scripts in /usr/bin: ${installed[*]}"
    fi
fi

# btop/curl/scp/sftp/sqlite3/ssh
if [[ -d "$NETTOOLS_DIST" ]]; then
    step "installing network tools from nettools-dist/ ($(du -sh "$NETTOOLS_DIST" | cut -f1))..."
    cp -a "$NETTOOLS_DIST/." "$TARGET/"

    ln -sf /usr/bin/lsblk "$TARGET/bin/lsblk"

    chmod 755 "$TARGET/etc/ssh" 2>/dev/null || true
    chmod 644 "$TARGET/etc/ssh/sshd_config" "$TARGET/etc/ssh/ssh_config" 2>/dev/null || true
    chmod 644 "$TARGET/etc/ssh/moduli" 2>/dev/null || true

    mkdir -p "$TARGET/var/lib/alsa"
    chmod 755 "$TARGET/var/lib/alsa"

    ln -sf /proc/mounts "$TARGET/etc/mtab"

    if ! grep -q '^sshd:' "$TARGET/etc/passwd"; then
        printf 'sshd:x:22:22:sshd privsep:/var/empty:/bin/false\n' >> "$TARGET/etc/passwd"
    fi
    if ! grep -q '^sshd:' "$TARGET/etc/group"; then
        printf 'sshd:x:22:\n' >> "$TARGET/etc/group"
    fi
    mkdir -p "$TARGET/var/empty"
    chmod 755 "$TARGET/var/empty"

    if ! grep -q '^messagebus:' "$TARGET/etc/passwd"; then
        printf 'messagebus:x:81:81:System message bus:/var/lib/dbus:/bin/false\n' \
            >> "$TARGET/etc/passwd"
    fi
    if ! grep -q '^messagebus:' "$TARGET/etc/group"; then
        printf 'messagebus:x:81:\n' >> "$TARGET/etc/group"
    fi

    if [[ -f "$TARGET/etc/locale.conf" ]]; then
        substep "locale: $(tr '\n' ' ' < "$TARGET/etc/locale.conf") (glibc built-in, no archive)"
    else
        fail "nettools-dist/etc/locale.conf missing"
    fi

      substep "net tools installed (sshd_config: /etc/ssh/sshd_config, privsep uid 22 ready)"

      if [[ -f "$TARGET/usr/share/btop/themes/tokyo-night.theme" ]]; then
          mkdir -p "$TARGET/home/user/.config/btop"
          cat > "$TARGET/home/user/.config/btop/btop.conf" << 'BTOPCONF'
color_theme = "tokyo-night"
theme_background = false
BTOPCONF
          substep "btop: tokyo-night theme selected"
      else
          substep "btop: no tokyo-night.theme staged - btop keeps its built-in theme"
      fi
  else
      warn "no nettools-dist/ - building without curl/ssh/sqlite3 (run build_nettools.sh)"
  fi

header "Optional components"
# Dbus
if [[ -d "$DBUS_DIST" ]]; then
  step "installing D-Bus from dbus-dist/ ($(du -sh "$DBUS_DIST" | cut -f1))..."
  cp -a "$DBUS_DIST/." "$TARGET/"

  if [[ -e "$TARGET/etc/machine-id" ]]; then
    errmsg "$TARGET/etc/machine-id exists - it must be generated on first boot,"
    echo "       never baked into an image (dbus-dist must not create it)" >&2
    exit 1
  fi

  mkdir -p "$TARGET/var/lib/dbus" "$TARGET/etc/dbus-1"
  chmod 755 "$TARGET/var/lib/dbus" "$TARGET/etc/dbus-1"
  chmod 644 "$TARGET/etc/dbus-1/system.conf"
  for t in dbus-daemon dbus-uuidgen dbus-send; do
    if [ -f "$TARGET/usr/bin/$t" ]; then
      cp -f "$TARGET/usr/bin/$t" "$TARGET/bin/$t"
    fi
  done
  substep "D-Bus: system.conf staged, machine-id correctly absent"
else
  warn "no dbus-dist/ - building without D-Bus (no wireless, no bluetooth)"
fi

# Wireless (iwd)
if [[ -d "$IWD_DIST" ]]; then
  step "installing iwd from iwd-dist/ ($(du -sh "$IWD_DIST" | cut -f1))..."
  cp -a "$IWD_DIST/." "$TARGET/"
  for t in iwctl; do
    [ -f "$TARGET/usr/bin/$t" ] && cp -f "$TARGET/usr/bin/$t" "$TARGET/bin/$t"
  done
  mkdir -p "$TARGET/var/lib/iwd"
  chmod 700 "$TARGET/var/lib/iwd"
  chmod 755 "$TARGET/usr/libexec/iwd" 2>/dev/null || true
  substep "wireless: iwd + iwctl staged, /var/lib/iwd ready (no credentials shipped)"
else
  warn "no iwd-dist/ - building without wireless"
fi

# Bluetooth
if [[ -d "$BLUEZ_DIST" ]]; then
  step "installing BlueZ from bluesz-dist/ ($(du -sh "$BLUEZ_DIST" | cut -f1))..."
  cp -a "$BLUEZ_DIST/." "$TARGET/"
  chmod 755 "$TARGET/usr/libexec/bluetooth/bluetoothd" 2>/dev/null || true
  substep "bluetooth: bluetoothd + bluetoothctl + btmon staged"
else
  warn "no bluesz-dist/ - building without bluetooth"
fi

# Firmware
if [[ -d "$FW_DIST" ]]; then
  step "installing firmware from fw-dist/ ($(du -sh "$FW_DIST" | cut -f1))..."
  cp -a "$FW_DIST/." "$TARGET/"
  chmod -R a+rX "$TARGET/lib/firmware"
  substep "firmware: $(find "$TARGET/lib/firmware" -type f | wc -l) blobs"
else
  warn "no fw-dist/ - wireless drivers will load but find no firmware"
fi

# W3M web browser
if [[ -d "$W3M_DIST" ]]; then
  step "installing w3m from w3m-dist/ ($(du -sh "$W3M_DIST" | cut -f1))..."
  cp -a "$W3M_DIST/." "$TARGET/"
  chmod 755 "$TARGET/usr/bin/w3m" 2>/dev/null || true
  chmod -R a+rX "$TARGET/usr/share/w3m" 2>/dev/null || true
  if [[ -e "$TARGET/usr/lib64/libtinfo.so.6" ]]; then
    substep "browser: w3m staged at /usr/bin/w3m, terminfo library present"
  else
    substep "*** WARNING: libtinfo.so.6 missing - w3m will not start ***"
  fi
else
  warn "no w3m-dist/ - building without a browser"
fi

ok "rootfs assembled in $TARGET/ ($(du -sh "$TARGET" | cut -f1))"
