#!/usr/bin/env bash
# build_atom_rootfs.sh - assemble the rlos-atom root filesystem.
#
# Atom is what rlOS runs inside bubblewrap when it needs a service (a git server,
# say) isolated from the desktop. It is also bootable standalone from
# rlos-atom.iso. One rootfs serves both.
#
# This is deliberately NOT assemble-rootfs.sh with a flag. That script builds a
# desktop: X11, i3, mlterm, fonts, xorg drivers, fastfetch, the xkb compiler, ALSA.
# Together those are ~51M of a 176M tree and none of it is reachable from a
# service container. A separate assembler keeps the "what is atom" question
# answerable by reading one list at the top of this file, and keeps the desktop
# build from growing new things into atom by accident.
#
# What atom contains:
#
#   busybox   the shell and coreutils; everything else is built on it
#   gcc       the C compiler rlt links with (C-only + LTO)
#   binutils  as/ld - gcc has no built-in assembler or linker, unlike tcc
#   git       a git server is the motivating use case
#   ssh       client and server, so the container is reachable
#   sqlite3   small, and the natural companion to a git server
#   curl      health checks and fetching things
#   rlc rlt rldocs   the rl toolchain (no-media: no audio, no GUI)
#   bwrap     so atom can in turn run nested containers
#
# What atom deliberately excludes: X11, fonts, xorg, i3, mlterm, fastfetch,
# xkbcomp, setrootbg/setrootcursor, ALSA, libasound, sudo, and the rl VM runner.
#
# Usage:
#   ./build_atom_rootfs.sh [TARGET]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-$ROOT/rlos-atom/atom-rootfs}"

BB_DIST="$ROOT/busybox-dist"
GCC_DIST="$ROOT/gcc-dist"
BINUTILS_DIST="$ROOT/binutils-dist"
GIT_DIST="$ROOT/git-dist"
NETTOOLS_DIST="$ROOT/nettools-dist"
BWRAP_DIST="$ROOT/rlos-atom/bwrap-dist"
ATOM_BINS="$ROOT/rl-bins/rlos-atom"
ATOM_INIT="$ROOT/rlos-atom/atom-init"

info() { echo "  $*"; }
ok()   { echo "ok: $*"; }
warn() { echo "warn: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
header() {
  echo
  echo "== $* =="
}

# ---------------------------------------------------------------------------
# Preconditions. Every one of these produces a silently broken atom otherwise.
# ---------------------------------------------------------------------------

header "Checking inputs"
[ -d "$BB_DIST" ]        || fail "busybox-dist/ missing - run build_busybox.sh"
[ -d "$GCC_DIST" ]       || fail "gcc-dist/ missing - run build_gcc.sh"
[ -d "$BINUTILS_DIST" ] || fail "binutils-dist/ missing - run build_binutils.sh"
[ -d "$GIT_DIST" ]       || fail "git-dist/ missing - run build_git.sh"
[ -d "$NETTOOLS_DIST" ]  || fail "nettools-dist/ missing - run build_nettools.sh"
[ -d "$BWRAP_DIST" ]     || fail "rlos-atom/bwrap-dist missing - run rlos-atom/build_atom_bwrap.sh"
[ -x "$ATOM_INIT" ]      || fail "rlos-atom/atom-init missing - run rlos-atom/compile_atom_init.sh"
for b in rlc rlt rldocs; do
    [ -x "$ATOM_BINS/$b" ] || fail "atom-bins/$b missing - run rlos-atom/build_atom_rl.sh"
done
ok "all inputs present"

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

header "Cleaning"
rm -rf "$TARGET"
mkdir -p "$TARGET"/{bin,sbin,etc,proc,sys,dev,tmp,run,root,home/user,var/lib}

# /var/lib/atom has to EXIST in the image, and that is not tidiness - it is the
# difference between the documented writable path working and not working.
#
# A bwrap --bind needs its mount point to already exist. The root is mounted
# --ro-bind, so bwrap cannot create the directory for you, and --dir does not
# help either because by the time it runs the filesystem is already read-only:
#
#   bwrap: Can't create file /var/lib/atom: Read-only file system
#
# So an atom without this directory has no writable path at all, and every
# scp into a container fails - which is precisely the workflow the guide and the
# shipped scripts exist to support. Created here, empty, owned by root like
# everything else in the image; the host binds a host directory over it.
mkdir -p "$TARGET/var/lib/atom"
chmod 0755 "$TARGET/var/lib/atom"
mkdir -p "$TARGET/usr"/{bin,sbin,lib,lib64,include,share}
chmod 1777 "$TARGET/tmp"
info "$TARGET"

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
header "init"
install -m 0755 "$ATOM_INIT" "$TARGET/sbin/init"
ln -sf /sbin/init "$TARGET/init"
# The rescue shell: atom's init is the shared rlos init.c built with -DRLOS_ATOM,
# so it brings up networking, the user account and sshd itself. It does not need
# a separate rescue shell the way the desktop build does - that one exists to
# give a prompt when X and mlterm have both failed, which cannot happen here.
ok "sbin/init (shared init.c, RLOS_ATOM)"

# ---------------------------------------------------------------------------
# busybox
# ---------------------------------------------------------------------------
header "busybox"
cp -a "$BB_DIST/." "$TARGET/"
chmod 755 "$TARGET"/bin/* 2>/dev/null || true

# The applet symlinks. busybox-dist ships the binary and an APPLYTS list, but
# NOT the links - assemble-rootfs.sh creates those for the desktop image. Atom
# has no assemble-rootfs.sh, so without this it would get a busybox with no
# applet names, which is the difference between a usable shell and none at all.
[ -f "$BB_DIST/APPLYTS" ] || fail "busybox-dist/APPLYTS missing - cannot link applets"

# Applets that must not shadow a real binary. /bin is first on PATH, so a link
# here beats anything staged in /usr/bin or /sbin.
BB_EXCLUDE="rl rlc rlt rldocs rlsp rlrepl git git-daemon git-upload-pack \
git-receive-pack git-shell ssh sshd scp sftp ssh-keygen curl sqlite3 bwrap \
gcc gcc-ar gcc-nm gcc-ranlib cc as ld ar nm ranlib objcopy strings size bwrap"

N_LINKED=0
while read -r applet; do
    [ -n "$applet" ] || continue
    for ex in $BB_EXCLUDE; do
        if [ "$applet" = "$ex" ]; then
            continue 2
        fi
    done
    # Never clobber a real binary already staged in the tree.
    if [ -e "$TARGET/usr/bin/$applet" ] || [ -e "$TARGET/bin/$applet" ]; then
        continue
    fi
    ln -sf busybox "$TARGET/bin/$applet"
    N_LINKED=$((N_LINKED + 1))
done < "$BB_DIST/APPLYTS"
ok "$N_LINKED applets linked"

# `rescue` cannot be a symlink: busybox dispatches on argv[0] and has no applet
# by that name, so a link fails with "applet not found" and exit 127. Copied
# from assemble-rootfs.sh, which found this the hard way.
if [ -f "$BB_DIST/rescue" ]; then
    install -m 0755 "$BB_DIST/rescue" "$TARGET/bin/rescue"
    ok "bin/rescue (real file, not a link)"
fi

# ---------------------------------------------------------------------------
# gcc + binutils
# ---------------------------------------------------------------------------
header "Libraries nothing here links but rlt still emits"
# libffi is the awkward one. rlt emits -lffi whenever a program uses std::c, but
# in atom nothing links it: the desktop image only gets libffi because i3's ldd
# closure drags it in, and atom has no i3. So it has to be staged deliberately
# or every program using std::c fails with "cannot find -lffi".
#
# libcurl has the same shape - nothing in atom links it, but rlt emits -lcurl
# for std::http - except nettools-dist already stages it, so it is covered.
#
# Staged by SONAME, then a libNAME.so dev symlink, because a linker resolves
# -lNAME by looking for libNAME.so and rejects libNAME.so.N.
#
# gcc-dist stages libffi itself now, but atom keeps doing it here too: atom builds
# from a different dist tree and this costs 60KB.
stage_needed_lib() {
  local name="$1" soname="$2" src="$3"
  if [ -z "$src" ] || [ ! -e "$src" ]; then
    warn "could not find $soname on this host - std::c programs will not link"
    return
  fi
  cp -Lf "$src" "$TARGET/usr/lib64/$soname"
  ln -sf "$soname" "$TARGET/usr/lib64/lib$name.so"
  ok "lib$name.so -> $soname ($(du -h "$TARGET/usr/lib64/$soname" | cut -f1))"
}

# Follow the soname symlink chain to a real file.
resolve() {
  local cand
  cand="$(ls -1 "/usr/lib64/$1" 2>/dev/null | head -1 || true)"
  [ -n "$cand" ] || return 1
  readlink -f "$cand"
}

stage_needed_lib "ffi" "libffi.so.8" "$(resolve libffi.so.8 || true)"

header "gcc + binutils"
cp -a "$GCC_DIST/." "$TARGET/"
cp -a "$BINUTILS_DIST/." "$TARGET/"
# The driver MUST go to /usr/bin, not /bin. gcc resolves cc1, lto1, collect2
# and the crt objects relative to where the gcc binary itself lives: configured
# --prefix=/usr, a driver at /usr/bin/gcc finds /usr/libexec/gcc/<tr>/<ver>/cc1,
# while one at /bin/gcc derives the prefix "/" and searches /libexec/gcc/...,
# which does not exist - leaving every compile to fail with
#   cc: fatal error: cannot execute 'cc1': posix_spawnp: No such file or directory
# `cc --version` still succeeds in that state, so it is not a valid smoke test.
mkdir -p "$TARGET/usr/bin"
for tool in gcc gcc-ar gcc-nm gcc-ranlib; do
    mv -f "$TARGET/bin/$tool" "$TARGET/usr/bin/$tool"
done
for tool in as ld ld.bfd ar nm ranlib objcopy strip size strings addr2line elfedit; do
    [[ -f "$TARGET/bin/$tool" ]] && mv -f "$TARGET/bin/$tool" "$TARGET/usr/bin/$tool"
done
ln -sf gcc "$TARGET/usr/bin/cc"
if [[ ! -x "$(find "$TARGET/usr/libexec/gcc" -name cc1 -type f 2>/dev/null | head -1)" ]]; then
    fail "no cc1 under usr/libexec/gcc - every compile in atom would fail"
fi
ok "gcc (C-only + LTO) + binutils (as/ld) + glibc header closure"

# The -l dev symlinks a linker needs: it resolves -lNAME by looking for
# libNAME.so and rejects libNAME.so.N, so without these every rl program using
# http, argon2, yaml or audio fails with "cannot find -lpthread". Same fix as
# the desktop build, applied here because atom has the same need.


# ---------------------------------------------------------------------------
# git, ssh, sqlite3, curl
# ---------------------------------------------------------------------------
header "git + ssh + sqlite3 + curl"
# git first: git-dist and nettools-dist both write under /usr, and copying them
# in this order keeps a later copy from silently masking an earlier one.
if [ -d "$GIT_DIST" ]; then
    cp -a "$GIT_DIST/." "$TARGET/"
    ok "git + git-core from git-dist"
else
    fail "git-dist missing - a git server is the main reason atom exists"
fi
cp -a "$NETTOOLS_DIST/." "$TARGET/"

# nettools-dist also stages ALSA, because the desktop image wants it for
# rl-std/audio.rs. Atom deliberately has no sound: its kernel has CONFIG_SOUND
# off and its rl binaries are built no-media, so nothing in atom can open a PCM.
# Carrying a 1MB libasound and 12K of alsa.conf would be dead weight that also
# makes the exclusions check below fail.
rm -f "$TARGET/usr/lib64/libasound.so.2"
rm -rf "$TARGET/usr/share/alsa"
ok "ssh/sshd/sftp/scp/ssh-keygen, sqlite3, curl (ALSA stripped - atom has no audio)"

# git-core is 25M of atom's tree and all of it is needed for a real git server
# (git-daemon, git-http-backend, git-receive-pack, git-upload-pack are used for
# exactly that). Kept whole rather than pruned: it is the motivating service and
# a half-stripped git is worse than a big one.
if [ -d "$GIT_DIST/usr/libexec/git-core" ]; then
    ok "git-core ($(ls "$GIT_DIST/usr/libexec/git-core" | wc -l) subcommands)"
else
    warn "git-core not found in git-dist - git will not work as a server"
fi
if [ ! -x "$TARGET/usr/libexec/git-core/git-daemon" ]; then
    warn "git-daemon missing - a git:// server will not start"
else
    ok "git-daemon present (git:// server works)"
fi

# ---------------------------------------------------------------------------
# bwrap
# ---------------------------------------------------------------------------
header "bwrap"
cp -a "$BWRAP_DIST/." "$TARGET/"
ok "bwrap ($(du -h "$TARGET/bin/bwrap" | cut -f1)) + libcap"

# ---------------------------------------------------------------------------
# rl toolchain (no-media)
# ---------------------------------------------------------------------------
header "rl toolchain"
for b in rlc rlt rldocs; do
    install -m 0755 "$ATOM_BINS/$b" "$TARGET/usr/bin/$b"
    ok "usr/bin/$b ($(du -h "$ATOM_BINS/$b" | cut -f1))"
done

# ---------------------------------------------------------------------------
# runtime library closure
# ---------------------------------------------------------------------------


# A linker resolves -lNAME by looking for libNAME.so and rejects libNAME.so.N, so
# these symlinks must exist for rlt. Placed here, after every library is
# staged, because libffi comes from the host and libcurl from nettools-dist -
# doing this earlier in the script finds whichever of them is not there yet.
echo "creating -l dev symlinks..."
LINK_LIBS="ffi curl argon2 yaml pthread dl"
missing=""
for l in $LINK_LIBS; do
    tgt="$(ls -1 "$TARGET"/usr/lib64/lib"$l"*.so.* 2>/dev/null | head -1 || true)"
    if [ -z "$tgt" ]; then missing="$missing $l"; continue; fi
    ln -sf "$(basename "$tgt")" "$TARGET/usr/lib64/lib$l.so"
done
if [ -n "$missing" ]; then
    fail "no libNAME.so.N staged for:$missing - rlt emits -l for these"
fi
ok "libNAME.so symlinks for:$LINK_LIBS"

header "ldd closure over everything staged"
# The guest has no ld.so.cache, so every shared object must exist as a real file
# under /usr/lib64 (a default loader search dir). Flattened, absolute paths kept
# too, because dlopen of an absolute path is a thing software does.
CLOSURE_SEEN=""
# `return 0` is load-bearing. A bare `return` returns the status of the last
# command executed, which under `set -e` makes a *skip* look like a failure:
# the caller's `[ -f "$elf" ] && collect ...` then evaluates false and the whole
# script aborts mid-walk with no message. Cost an hour of "why does this stop
# silently"; every early return here is explicit.
collect() {
  local target="$1" lib
  [ -f "$target" ] || return 0
  # $3 for resolved libraries, $1 for the interpreter line. ldd prints the
  # interpreter as "/lib64/ld-linux-x86-64.so.2 (0x...)" with no "=>", so a
  # naive $3-only filter silently drops the dynamic loader - and every
  # dynamically linked binary then fails with a bare "not found" that looks
  # like a missing binary rather than a missing interpreter.
  for lib in $(ldd "$target" 2>/dev/null \
                 | awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }'); do
    case " $CLOSURE_SEEN " in *" $lib "*) continue ;; esac
    CLOSURE_SEEN="$CLOSURE_SEEN $lib"
    collect "$lib"
  done
  return 0
}
# find exits nonzero if any path is missing, and under `set -e` a failing
# command substitution in an assignment aborts the script silently. Both the
# `|| true` and the directories above matter.
ALL_ELFS="$(find "$TARGET/bin" "$TARGET/usr/bin" "$TARGET/sbin" "$TARGET/usr/sbin" \
  "$TARGET/usr/lib64/misc" -type f 2>/dev/null || true)"
[ -n "$ALL_ELFS" ] || fail "no ELF files found under $TARGET - nothing was staged"
for elf in $ALL_ELFS; do
    if [ -f "$elf" ]; then
        collect "$elf"
    fi
done
N=0
for lib in $CLOSURE_SEEN; do
    base="$(basename "$lib")"
    # Preserve the absolute path under TARGET as well as flattening, so both a
    # DT_NEEDED lookup and an absolute dlopen resolve.
    mkdir -p "$TARGET$(dirname "$lib")"
    cp -Ln "$lib" "$TARGET$(dirname "$lib")/$base" 2>/dev/null || true
    cp -Ln "$lib" "$TARGET/usr/lib64/$base" 2>/dev/null || true
    N=$((N + 1))
done
ok "$N libraries, $(du -sh "$TARGET/usr/lib64" | cut -f1) in usr/lib64"

# The dynamic loader, asserted rather than assumed. Without it every ELF in the
# image fails to exec with "not found", which reads as a broken binary rather
# than a missing interpreter - and it is the single most confusing failure mode
# a rootfs can have.
LD_LINUX="/lib64/ld-linux-x86-64.so.2"
if [ -f "$LD_LINUX" ]; then
    mkdir -p "$TARGET/lib64"
    cp "$LD_LINUX" "$TARGET/lib64/"
    ok "/lib64/ld-linux-x86-64.so.2 (interpreter present)"
else
    fail "dynamic linker $LD_LINUX not found - every binary in atom would fail to exec"
fi

# ---------------------------------------------------------------------------
# /etc
# ---------------------------------------------------------------------------
header "/etc"
# Accounts. Identical shape to the desktop build on purpose: the shared init.c
# creates the user, chowns trees, and starts sshd, and any divergence here shows
# up as "works on the desktop, broken in atom".
#
# The password is a real consideration. Atom is a service container that may be
# exposed on a network, and "root" as a password on an ssh-accessible box is a
# bad default. It is kept here only because it matches what the user already
# knows and because init.c and mkusb.sh share the convention; the file below is
# the single place to change it.
USER_PW_HASH="$(openssl passwd -6 -salt rlosatom root 2>/dev/null || echo '!*')"

printf 'root:x:0:0:root:/root:/bin/ash\n' > "$TARGET/etc/passwd"
printf 'user:x:1000:1000:user:/home/user:/bin/ash\n' >> "$TARGET/etc/passwd"
# sshd's privilege-separation user. OpenSSH hard-exits at startup without it.
printf 'sshd:x:22:22:sshd privsep:/var/empty:/bin/false\n' >> "$TARGET/etc/passwd"

printf 'root:x:0:\nuser:x:1000:\nsshd:x:22:\n' > "$TARGET/etc/group"

printf 'root:!:19000:0:99999:7:::\n' > "$TARGET/etc/shadow"
printf 'user:%s:19000:0:99999:7:::\n' "$USER_PW_HASH" >> "$TARGET/etc/shadow"
chmod 0600 "$TARGET/etc/shadow"

printf 'atom\n' > "$TARGET/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 atom\n::1 localhost\n' > "$TARGET/etc/hosts"
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$TARGET/etc/resolv.conf"
mkdir -p "$TARGET/etc/ssh"
chmod 755 "$TARGET/etc/ssh"
# /etc/passwd must be world-readable. 0600 is only correct for /etc/shadow.
#
# This is not cosmetic: inside atom, /etc/passwd is bind-mounted read-only from
# /atom, and init chowns /atom to root. With --unshare-user the container's uid 0
# maps to an UNPRIVILEGED host uid, so a 0600 root-owned passwd is unreadable and
# every lookup fails - which surfaces as ssh reporting the memorable
# "No user exists for uid 0" and nothing else being wrong.
chmod 0644 "$TARGET/etc/passwd"
# /var/empty is sshd's privsep cwd; must be root-owned and not group/world
# writable. init.c fixes this too (the assembler runs unprivileged so it cannot),
# but staging it correctly avoids depending on that.
mkdir -p "$TARGET/var/empty"
chmod 755 "$TARGET/var/empty"
ok "passwd/group/shadow, hostname, hosts, resolv.conf"
info "user password is 'root' - change openssl passwd -6 -salt <s> <pw> in this script"

# ssh/sshd configs come from nettools-dist, which already wrote them.
[ -f "$TARGET/etc/ssh/sshd_config" ] && ok "sshd_config (from nettools-dist)"
[ -f "$TARGET/etc/ssh/moduli" ]       && ok "moduli"
# sshd hard-exits without host keys; init.c generates them on first boot. Never
# ship them: a key baked into a downloadable image is the same key for everyone.
ok "host keys: generated at first boot, not shipped"

# gitconfig, same defaults as the desktop build.
if [ -f "$TARGET/etc/git/config" ]; then ok "git config"; fi

# ---------------------------------------------------------------------------
# fastfetch (the ATOM logo, and a module set trimmed for a container)
# ---------------------------------------------------------------------------
header "fastfetch (atom logo)"
# Sourced from fastfetch-dist/, the same tree the desktop stages, rather than from
# the host path: build_fastfetch.sh already resolved fastfetch's dependency
# closure and staged libyyjson.so.0, and re-resolving it here would be a second
# source of truth for the same answer.
FF_DIST="$ROOT/fastfetch-dist"
# -f, not -d: fastfetch is a single executable file, so testing for a directory
# here silently took the "not built" branch on a tree that was present and
# correct, and the build reported success with no fastfetch in the image.
if [ -f "$FF_DIST/usr/bin/fastfetch" ]; then
    mkdir -p "$TARGET/usr/bin" "$TARGET/usr/lib64" "$TARGET/usr/share/rlos" \
             "$TARGET/etc/xdg/fastfetch"
    install -m 0755 "$FF_DIST/usr/bin/fastfetch" "$TARGET/usr/bin/fastfetch"
    # libyyjson is fastfetch's only dependency that the rest of atom does not
    # already need. Without it fastfetch starts and then fails to parse its own
    # config, which is a confusing way to learn that.
    for l in "$FF_DIST"/usr/lib64/libyyjson.so*; do
        [ -f "$l" ] || continue
        install -m 0644 "$l" "$TARGET/usr/lib64/$(basename "$l")"
    done

    if [ -f "$ROOT/ff_logo_atom.txt" ]; then
        install -m 0644 "$ROOT/ff_logo_atom.txt" "$TARGET/usr/share/rlos/ff_logo_atom.txt"
    else
        fail "ff_logo_atom.txt missing - atom's fastfetch would fall back to the desktop logo"
    fi

    # /etc/os-release, without which fastfetch's `os` module prints nothing. This
    # is asserted rather than staged-if-present because the first atom image with
    # fastfetch in it rendered a correct ATOM logo next to a blank line where the
    # operating system should have been - the module was configured correctly and
    # had nothing to read.
    if [ -f "$ROOT/etc-rlos/os-release" ]; then
        install -m 0644 "$ROOT/etc-rlos/os-release" "$TARGET/etc/os-release"
    else
        fail "etc-rlos/os-release missing - fastfetch's os module would print nothing"
    fi

    # A config of its own, because the desktop's is wrong here in two ways: it
    # points at the RLOS logo, and it asks for modules a container cannot answer.
    #
    # Dropped: WM and GPU (no window manager and no GPU is passed through - atom's
    # kernel has no VA-API at all, and GLX is off in every kernel config here), and
    # Battery (no battery is passed through either).
    #
    # Dropped after checking rather than assuming: `container`. There IS no such
    # module in fastfetch 2.65.2 - the full module list is Battery, BIOS, ...,
    # Wallpaper, Weather, WM, Wifi, WMTheme, Zpool, and nothing container-shaped.
    # Naming a module that does not exist makes fastfetch print a warning and carry
    # on, which would have looked like it worked. Uptime plus Host is the honest
    # substitute for "which container am I in": the hostname differs per container
    # if you set one with --hostname, and uptime answers "is this the one I just
    # started".
    #
    # Kept: Packages, because rl-lang is in atom and `rl --version` is the thing
    # worth knowing. Locale, because the guest forces C.UTF-8 and a timezone that
    # is silently UTC is worth surfacing.
    cat > "$TARGET/etc/xdg/fastfetch/config.jsonc" << 'FFATOMEOF'
  {
    "logo": {
      "source": "/usr/share/rlos/ff_logo_atom.txt",
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
      "packages",
      "locale",
      "break",
      "cpu",
      "memory",
      "disk",
      "break",
      "colors"
    ]
  }
FFATOMEOF
    ok "fastfetch staged with the ATOM logo ($([ -f "$TARGET/usr/share/rlos/ff_logo_atom.txt" ] && echo yes || echo NO))"
else
    # Optional, like X11 on the desktop. Without it there is no banner tool, which
    # costs nothing and is not a build failure.
    warn "fastfetch-dist/ not built - atom will have no fastfetch"
fi

# ---------------------------------------------------------------------------
# scripts
# ---------------------------------------------------------------------------
header "scripts"
# Deliberately nothing here. No bwrap wrapper, because atom users write bwrap
# invocations directly: a wrapper hides the namespace and mount setup that is the
# actual security boundary, and its invented flags collide with the flags of
# whatever program is being wrapped. No docs either, because atom ships as a
# single file the host unpacks into a scratch directory - a guide living inside
# that directory would be read from a container, which is the wrong place to
# read it from. ATOM-BWRAP.md installs on the host image instead.

# ---------------------------------------------------------------------------
# exclusions, asserted
# ---------------------------------------------------------------------------
header "Verifying exclusions"
  # Not a wishlist: assert each of these is absent, because the failure mode
  # otherwise is an atom that silently grew a 40M desktop.
  #
  # fastfetch is NOT in this list any more. It used to be, and it was the wrong
  # call: fastfetch is a 2M binary that reports what the machine IS, which is
  # exactly what you want when you ssh into a container and need to know which
  # container you are in, how much disk it has, and how long it has been up. It
  # pulls in no toolkit and no GL - its only extra dependency is libyyjson.
  # Excluding it was cargo-culting the "atom is minimal" rule rather than
  # applying it.
  LEAKED=""
  for p in bin/Xorg bin/i3 bin/i3bar bin/mlterm bin/setrootbg bin/setrootcursor \
           usr/bin/xauth usr/bin/xkbcomp usr/bin/sudo \
           usr/lib64/libasound.so.2 usr/share/alsa bin/rl usr/bin/rl usr/bin/rlsp \
           usr/bin/rlrepl usr/bin/atom-run; do
      [ -e "$TARGET/$p" ] && LEAKED="$LEAKED $p"
  done
  if [ -n "$LEAKED" ]; then
      fail "desktop-only paths leaked into atom:$LEAKED"
  fi
  ok "no X11, fonts, sudo, ALSA, the rl VM/LSP/REPL, or the atom-run wrapper"

# And assert audio really is absent, since that is what no-media is for.
if ldd "$TARGET/usr/bin/rlc" 2>/dev/null | grep -qi asound; then
    fail "rlc links libasound - atom binaries must be built no-media"
fi
ok "rl toolchain links no audio"

# ---------------------------------------------------------------------------
# size
# ---------------------------------------------------------------------------
header "Size"
TOTAL="$(du -sh "$TARGET" | cut -f1)"
ok "atom rootfs: $TOTAL uncompressed"
for d in usr/bin usr/lib64 usr/libexec bin; do
    [ -d "$TARGET/$d" ] && printf '  %-14s %s\n' "$d" "$(du -sh "$TARGET/$d" | cut -f1)"
done
info "gzipped size is what the ISO target cares about; measured by mkiso.sh"

header "done"
ok "atom rootfs assembled at $TARGET"
info "next: rlos-atom/mkiso.sh packs it into rlos-atom.iso."