#!/usr/bin/env bash
# build_base_tools.sh - stage the tools that need no X11, into base-dist/.
#
# WHY THIS IS A SEPARATE SCRIPT
#
# sudo, ttyrec, ttyplay, rlin and rlperf all used to be built by build_x11.sh
# into x11-dist/, which coupled them to the -x flag that decides whether an
# image gets the desktop. None of them needs X:
#
#   sudo     privilege escalation for the `user` account, needed on the text
#            console as much as on the desktop - init's vt3-vt6 shells run as
#            uid 1000 and sudo is how they reach anything root-owned
#   ttyrec   records a terminal session to a tty. build_x11.sh said so itself:
#            "No X and no GL: it reads and writes a tty"
#   ttyplay  plays one back, same dependency story
#   rlin     the rlos.diag input report. It reads /dev/input/event* and starts
#            no X - that is the whole point of it, being the one diagnostic
#            that runs while the desktop is deliberately NOT started
#   rlperf   reads /proc and /dev/fb0. Its own comment: "Needs no X libraries"
#   nnn      terminal file manager. Draws in a text console, so it belongs to
#            the text-only image as much as to the desktop one
#
# The first five link nothing but libc. nnn is the exception: it links
# ncursesw, and ncurses brings a terminfo database that no text-only image had
# before. That is a real cost - roughly a megabyte in every image - and it is
# paid deliberately, because "no X11 dependency" is the rule this dist follows
# and ncurses is not an X11 dependency. The five below it still hold to the
# stricter "libc only" check further down, which nnn is deliberately outside of.
#
# Staging them here means assemble-rootfs.sh ships them into every image and
# only -x decides whether the desktop comes along.
#
# What stayed in build_x11.sh, and why:
#   rlfc   links libXft/libX11/libfontconfig/libXrender - it reports the X
#          client's font resolution, so it cannot answer without them
#   xauth  the X display cookie; meaningless without a display
#   udevd  only ever run from init's X block, for libinput
#   ffmpeg ffmpeg's only capture device here is x11grab; there is no screen to
#          grab without an X server
#
# Output:
#   base-dist/usr/bin/sudo        setuid 04755, stripped
#   base-dist/usr/bin/ttyrec
#   base-dist/usr/bin/ttyplay
#   base-dist/usr/bin/rlin
#   base-dist/usr/bin/rlperf
#
# Usage:
#   ./build_base_tools.sh            # build (default)
#   ./build_base_tools.sh -j 8       # 8 parallel jobs
#   ./build_base_tools.sh --clean    # remove base-src/ base-dist/
#
# Needs on the host: gcc, make, curl. Nothing else - no X pkg-config modules,
# no fonts, no meson. That is the point: a machine that has never run
# build_x11.sh can still produce this.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
BASE_SRC="$SCRIPT_DIR/base-src"
BASE_DIST="$SCRIPT_DIR/base-dist"
# ncurses and nnn both install into a prefix, not straight into the dist, so
# their .h files and build intermediates never end up in the image.
BASE_PREFIX="$SCRIPT_DIR/base-prefix"

CLEAN=0
JOBS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs)  JOBS="$2"; shift 2 ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)
      sed -n '2,42p' "$SCRIPT_DIR/build_base_tools.sh" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "build_base_tools.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

NPROC="$(nproc 2>/dev/null || echo 4)"
JOBS_FLAG=""
if [ -n "$JOBS" ]; then
  JOBS_FLAG="-j $JOBS"
elif command -v nproc > /dev/null 2>&1; then
  JOBS_FLAG="-j $NPROC"
fi

if [ "$CLEAN" = "1" ]; then
  echo "removing base-src/ base-dist/"
  rm -rf "$BASE_SRC" "$BASE_DIST"
  echo "cleaned"
fi

source "$SCRIPT_DIR/build-lib.sh"

source "$SCRIPT_DIR/pins.sh"

# fetch <url> <dest> [pin-key] - download unless already present.
# With a pin-key the file is verified against pins.lock whether it was just
# downloaded or already cached: a truncated or edited tarball in base-src/
# would otherwise be reused silently and fail hours later in a compiler.
fetch() {
  local url="$1" dest="$2" key="${3:-}"
  if [ -f "$dest" ]; then
    info "have $(basename "$dest")"
  else
    info "fetching $(basename "$dest")"
    curl -fL --retry 3 --retry-delay 2 --max-time 300 -o "$dest" "$url" \
      || { fail "download failed: $url"; exit 1; }
  fi
  [ -n "$key" ] && pins_verify "$dest" "$key"
  return 0
}

# run_quiet <cmd...> - run quietly, but print the tail on failure. Without this
# every `make ... > /dev/null` hides its own errors and you debug blind.

# sudo: privilege escalation for the unprivileged `user` session, which is how
# every VT shell and the desktop run. Four configure choices are forced by what
# this guest is and are not preferences:
#
#   --without-pam            there is no PAM in the image (no libpam, no
#                            /etc/pam.d); a PAM build would fail to load it
#   --enable-static-sudoers  the normal sudoers policy is a dlopen'd plugin
#                            (.so); linking it in means nothing to find on disk
#   --disable-openssl/zlib   the only libraries sudo then needs are libcrypt,
#                            libmd and libc
#
# The first two of those libraries come from other dists (nettools-dist and
# w3m-dist), which is why assemble-rootfs.sh puts base-dist's binaries through
# the ldd closure rather than trusting them to be there.
SUDO_VER="1.9.17p2"
SUDO_URL="https://www.sudo.ws/files/sudo-${SUDO_VER}.tar.gz"

# ttyrec/ttyplay: terminal session recorder. Debian's packaging of OVH's fork,
# which has no reachable upstream home any more.
TTYREC_VER="1.1.7.1"
TTYREC_URL="http://deb.debian.org/debian/pool/main/t/ttyrec/ttyrec_${TTYREC_VER}.orig.tar.gz"

# nnn: terminal file manager. The only program here that needs a library, and
# the reason this dist is no longer libc-only.
#
# WHY IT LIVES IN base-dist RATHER THAN xapps-dist: nnn is a TERMINAL program.
# feh and xfiles need X, so they are xapps and ship only with a desktop backend.
# nnn draws in a text console, which is exactly the case base-dist serves - a
# text-only image, or an installed system booted with no desktop flags at all.
# The four-VT console layout on the installed system has room for it.
#
# It brings ncurses, which is in no other dist, and with ncurses a terminfo
# database - which a text-only image did not previously have at all. That is a
# side effect rather than the goal, but a welcome one: an interactive shell
# without terminfo falls back to dumb behaviour for anything TERM-dependent.
#
# Static linking is not an option and not merely a preference: there is no
# libncursesw.a on the build host, so nnn cannot be linked statically against
# it, and ncurses would have to be built with --enable-static to make that
# possible. Shared plus a closure is the shape every other dist in this repo
# already uses.
NCURSES_VER="6.6"
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"

NNN_VER="5.3"
NNN_URL="https://github.com/jarun/nnn/releases/download/v${NNN_VER}/nnn-v${NNN_VER}.tar.gz"

header "Host prerequisites"
MISSING=""
for tool in gcc make curl; do
  command -v "$tool" > /dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  fail "missing host tools:$MISSING"
  fail "on Gentoo: emerge sys-devel/gcc sys-devel/make net/curl"
  exit 1
fi
ok "gcc make curl present"

if [ "$CLEAN" = "1" ]; then
  exit 0
fi

mkdir -p "$BASE_SRC" "$BASE_DIST/usr/bin"
rm -rf "$BASE_DIST"/usr/bin/*

# ---------------------------------------------------------------------------
header "sudo ${SUDO_VER}"
# Prefer a tarball the host already has (Gentoo's distfile cache) so the build
# does not depend on sudo.ws being reachable; fall back to fetching it.
SUDO_TARBALL="$BASE_SRC/sudo-${SUDO_VER}.tar.gz"
if [ ! -f "$SUDO_TARBALL" ]; then
  if [ -f "/var/cache/distfiles/sudo-${SUDO_VER}.tar.gz" ]; then
    info "sudo tarball taken from the host distfile cache"
    cp "/var/cache/distfiles/sudo-${SUDO_VER}.tar.gz" "$SUDO_TARBALL"
  else
    fetch "$SUDO_URL" "$SUDO_TARBALL" "sudo"
  fi
fi
if [ ! -d "$BASE_SRC/sudo-${SUDO_VER}" ]; then
  rm -rf "$BASE_SRC/sudo-${SUDO_VER}"
  mkdir -p "$BASE_SRC/sudo-${SUDO_VER}"
  tar -xf "$SUDO_TARBALL" -C "$BASE_SRC/sudo-${SUDO_VER}" --strip-components=1 \
    || { fail "sudo did not unpack"; exit 1; }
fi

# sudo's tree is built in place (its Makefile is not comfortable out-of-tree),
# into a throwaway copy so a re-run does not fight a previous configure.
SUDO_BUILD="$BASE_SRC/sudo-build"
step "preparing an in-place build tree"
substep "source:   $BASE_SRC/sudo-${SUDO_VER}"
substep "build in: $SUDO_BUILD"
rm -rf "$SUDO_BUILD"
cp -a "$BASE_SRC/sudo-${SUDO_VER}" "$SUDO_BUILD"
step "configure + make"
(
  cd "$SUDO_BUILD"
  run_quiet ./configure \
      --prefix=/usr \
      --libexecdir=/usr/libexec/sudo \
      --with-rundir=/run/sudo \
      --with-iologdir=/var/log/sudo-io \
      --without-pam \
      --enable-static-sudoers \
      --disable-shared-libutil \
      --disable-nls \
      --disable-root-mailer \
      --without-sendmail \
      --without-lecture \
      --without-ldap \
      --without-sssd \
      --without-kerb5 \
      --disable-python \
      --disable-openssl \
      --disable-zlib \
      --disable-gcrypt \
      --without-interfaces
  run_quiet make $JOBS_FLAG
) || { fail "sudo build failed"; exit 1; }

# libexecdir is still /usr/libexec/sudo in the configure paths, but with
# static-sudoers the binary has the policy inside it and there are no plugins to
# stage. Strip it: sudo is setuid, and a stripped binary is smaller to hold in
# the initramfs.
strip "$SUDO_BUILD/src/sudo" 2>/dev/null || true
cp "$SUDO_BUILD/src/sudo" "$BASE_DIST/usr/bin/sudo"
# The setuid bit is set here so the file is executable-escalatable if the image
# is ever unpacked by root; init ALSO re-asserts ownership and the setuid bit at
# boot (secure_sudo_files in init.c), because the initramfs is packed by a
# non-root user and cannot set the owner to 0. Both belt and braces, because
# sudo refuses to start if either is wrong.
chmod 4755 "$BASE_DIST/usr/bin/sudo"
# A stripped sudo that still needs three libraries is the whole story of the
# --disable-* flags above; assert it, so a future dependency creeping in is a
# build failure rather than a surprise in the closure. LC_ALL=C on the sort, or
# the expected string below is wrong on a host whose locale ignores punctuation
# and orders "libcrypt.so.2" ahead of "libc.so.6".
SUDO_LIBS="$(objdump -p "$BASE_DIST/usr/bin/sudo" 2>/dev/null | sed -n 's/^ *NEEDED *//p' | grep '^lib' | LC_ALL=C sort | tr '\n' ' ')"
if [ "$SUDO_LIBS" != "libc.so.6 libcrypt.so.2 libmd.so.0 " ]; then
  fail "sudo linkage changed: $SUDO_LIBS"
  fail "expected exactly libc.so.6 libcrypt.so.2 libmd.so.0"
  exit 1
fi
ok "sudo built ($(du -h "$BASE_DIST/usr/bin/sudo" | cut -f1), setuid)"
info "sudo linkage: $SUDO_LIBS"

# ---------------------------------------------------------------------------
header "ttyrec ${TTYREC_VER} (terminal session record/playback)"
step "fetch + unpack"
# This is Debian's packaging of OVH's fork, which unpacks as
# ovh-ttyrec-1.1.7.1/ - not ttyrec-1.1.7.1/ - so --strip-components=1 is used to
# get a stable path rather than hardcoding a name that tracks whoever last
# repackaged it.
fetch "$TTYREC_URL" "$BASE_SRC/ttyrec-${TTYREC_VER}.tar.gz" "ttyrec"
if [ ! -f "$BASE_SRC/ttyrec/Makefile" ]; then
  rm -rf "$BASE_SRC/ttyrec"
  mkdir -p "$BASE_SRC/ttyrec"
  tar -xf "$BASE_SRC/ttyrec-${TTYREC_VER}.tar.gz" -C "$BASE_SRC/ttyrec" \
    --strip-components=1 || { fail "ttyrec did not unpack"; exit 1; }
fi
TTYREC_SRC="$BASE_SRC/ttyrec"
[ -x "$TTYREC_SRC/configure" ] || { fail "ttyrec has no configure"; exit 1; }
# zstd stays ENABLED, and that is forced rather than chosen. NO_ZSTD=1 looks like
# the obvious way to keep ttyrec dependency-free, and it does stop configure
# adding compress_zstd.o to the link line - but this fork's compress.c calls
# fclose_wrapper_zstd unconditionally, so NO_ZSTD=1 yields a ttyrec that does
# not link at all:
#
#   compress.c:(.text+0x2c): undefined reference to `fclose_wrapper_zstd'
#
# That is a bug in OVH's fork (the variable is read from the environment, not
# from a positional argument, so passing it after --prefix does nothing
# anyway). The consequence to design around is a DT_NEEDED on libzstd.so.1,
# which gcc-dist already stages for the guest.
step "configure + make"
substep "NO_ZSTD is deliberately NOT set (see above: this fork does not link)"
run_quiet "$TTYREC_SRC/configure" --prefix=/usr
run_quiet make -C "$TTYREC_SRC" $JOBS_FLAG
for t in ttyrec ttyplay; do
  [ -x "$TTYREC_SRC/$t" ] || { fail "ttyrec: $t not built"; exit 1; }
  install -m 0755 "$TTYREC_SRC/$t" "$BASE_DIST/usr/bin/$t"
done
# ttyrec must stay this narrow: libzstd comes from gcc-dist and libc from the
# base image, but any THIRD DT_NEEDED would be a library this image ships for
# one recorder. ld-linux and linux-vdso are filtered because they are the
# loader, not a dependency.
TTYREC_DT="$(objdump -p "$BASE_DIST/usr/bin/ttyrec" | sed -n 's/^ *NEEDED *//p' | grep -vE 'ld-linux|linux-vdso' | LC_ALL=C sort | tr '\n' ' ')"
if [ "$TTYREC_DT" != "libc.so.6 libzstd.so.1 " ]; then
  fail "ttyrec linkage changed: $TTYREC_DT"
  fail "expected exactly libc.so.6 libzstd.so.1 (both already staged)"
  exit 1
fi
ok "ttyrec + ttyplay staged ($(du -h "$BASE_DIST/usr/bin/ttyrec" | cut -f1)); links: $TTYREC_DT"

# ---------------------------------------------------------------------------
header "rlin + rlperf (guest-side diagnostics)"
# Both are host-side C compiled straight into the guest. They are here rather
# than in build_x11.sh because neither links an X library: rlin reads
# /dev/input/event* and rlperf reads /proc and /dev/fb0.
for t in rlin rlperf; do
  if [ ! -f "$SCRIPT_DIR/x11-drv/$t.c" ]; then
    fail "x11-drv/$t.c missing - the sources live with the other guest drivers"
    exit 1
  fi
  gcc -O2 -Wall -Wextra \
      -o "$BASE_DIST/usr/bin/$t" \
      "$SCRIPT_DIR/x11-drv/$t.c" \
    || { fail "$t failed to build"; exit 1; }
ok "$t built ($(du -h "$BASE_DIST/usr/bin/$t" | cut -f1))"
  done

# ---------------------------------------------------------------------------
# ncurses, then nnn. In that order because nnn's configure looks for ncursesw,
# and finding the right one is the whole point of building it ourselves rather
# than linking whatever the host happens to have.
# ---------------------------------------------------------------------------
header "ncurses ${NCURSES_VER} (terminal library, for nnn)"
rm -rf "$BASE_PREFIX"
mkdir -p "$BASE_PREFIX"
NCURSES_TARBALL="$BASE_SRC/ncurses-${NCURSES_VER}.tar.gz"
fetch "$NCURSES_URL" "$NCURSES_TARBALL" "ncurses"
step "unpack"
# Into a dedicated directory. `tar --strip-components=1 -C "$BASE_SRC"` looks
# right and is not: it strips the top directory and then dumps what is left
# straight into base-src/, flattening the ncurses tree across every other
# tool's build directory in there. Unpack into a named subdir instead, the way
# sudo does above.
rm -rf "$BASE_SRC/ncurses-${NCURSES_VER}"
mkdir -p "$BASE_SRC/ncurses-${NCURSES_VER}"
tar -xf "$NCURSES_TARBALL" -C "$BASE_SRC/ncurses-${NCURSES_VER}" --strip-components=1 \
    || { fail "ncurses unpack failed"; exit 1; }

step "configure"
# The flags that matter, and what each one is here for:
#
#   --enable-widec        nnn links libncursesw, the wide-character build. This
#                         is not cosmetic - without it the libncursesw soname
#                         does not exist and nnn will not configure at all.
#   --with-shared         the alternative is --with-static, which would need
#                         libncursesw.a built too; shared is what every other
#                         dist here does and keeps the build quick.
#   --with-termlib        ncurses 6.x builds its terminal description into
#                         libtinfo/libncursesw and needs this to produce a
#                         usable share/terminfo at all.
#   --without-debug       -g in the installed .so is a size cost in every image.
#   --without-manpages    docs are not shipped and cost build time.
#   --without-ada --without-cxx-binding   drop language bindings we have no use
#                         for and that pull in compilers we would otherwise
#                         have to require on the host.
#
# --with-shared plus --without-normal is deliberately NOT combined: the last
# wins, and the default (normal libs included) is what nnn wants.
( cd "$BASE_SRC/ncurses-${NCURSES_VER}" && \
  ./configure \
      --prefix="$BASE_PREFIX" \
      --with-shared \
      --enable-widec \
      --with-termlib \
      --without-debug \
      --without-manpages \
      --without-ada \
      --without-cxx-binding \
      > "$SCRIPT_DIR/.ncurses-configure.log" 2>&1 ) \
  || { fail "ncurses configure failed"; tail -25 "$SCRIPT_DIR/.ncurses-configure.log" | sed 's/^/         /'; exit 1; }

step "make"
( cd "$BASE_SRC/ncurses-${NCURSES_VER}" && make $JOBS_FLAG > "$SCRIPT_DIR/.ncurses-build.log" 2>&1 ) \
  || { fail "ncurses build failed"; tail -25 "$SCRIPT_DIR/.ncurses-build.log" | sed 's/^/         /'; exit 1; }
step "make install"
( cd "$BASE_SRC/ncurses-${NCURSES_VER}" && make install > "$SCRIPT_DIR/.ncurses-install.log" 2>&1 ) \
  || { fail "ncurses install failed"; tail -25 "$SCRIPT_DIR/.ncurses-install.log" | sed 's/^/         /'; exit 1; }

if [ ! -e "$BASE_PREFIX/lib/libncursesw.so" ]; then
  fail "$BASE_PREFIX/lib/libncursesw.so was not built"
  fail "expected with --enable-widec; a non-widec build leaves nnn without a library to link"
  exit 1
fi
if [ ! -d "$BASE_PREFIX/share/terminfo" ]; then
  fail "$BASE_PREFIX/share/terminfo missing - nnn needs a terminfo database to start"
  exit 1
fi
ok "ncurses built ($(du -sh "$BASE_PREFIX" | cut -f1)), libncursesw + terminfo present"

header "nnn ${NNN_VER} (terminal file manager)"
NNN_TARBALL="$BASE_SRC/nnn-${NNN_VER}.tar.gz"
fetch "$NNN_URL" "$NNN_TARBALL" "nnn"
step "unpack"
rm -rf "$BASE_SRC/nnn-${NNN_VER}"
mkdir -p "$BASE_SRC/nnn-${NNN_VER}"
tar -xf "$NNN_TARBALL" -C "$BASE_SRC/nnn-${NNN_VER}" --strip-components=1 \
    || { fail "nnn unpack failed"; exit 1; }

step "make"
# No ./configure: nnn v5 ships a plain top-level Makefile, so the ncurses search
# path is handed over as make variables instead. PREFIX is set for correctness
# even though only the binary is taken below.
#
# The three overrides each fix a specific failure:
#
#   O_NORL=1              nnn links GNU readline by default and this host has it,
#                         but the image has no readline and would need a second
#                     library to satisfy it. nnn's own line editing is fine.
#   CFLAGS_CURSES=...     the Makefile otherwise asks pkg-config, which finds the
#                         HOST's ncursesw headers. -I must point at the prefix's
#                         include/ncursesw specifically: ncurses installs curses.h
#                         one level down, and pointing at include/ instead gives
#                         an implicit-declaration error for addnwstr, because the
#                         wide-character API is what nnn actually calls.
#   LDLIBS_CURSES=...     same reason on the link side, plus libtinfow, which
#                         ncurses 6 splits into its own library and which nnn
#                         needs as a separate DT_NEEDED.
#
# `make install` is deliberately NOT used: it also installs a man page, a
# .desktop file and an icon, none of which belong in this image.
( cd "$BASE_SRC/nnn-${NNN_VER}" && \
  make $JOBS_FLAG \
      O_NORL=1 \
      PREFIX="$BASE_PREFIX" \
      CFLAGS_CURSES="-I$BASE_PREFIX/include/ncursesw" \
      LDLIBS_CURSES="-L$BASE_PREFIX/lib -lncursesw -ltinfow" \
      > "$SCRIPT_DIR/.nnn-build.log" 2>&1 ) \
  || { fail "nnn build failed"; tail -25 "$SCRIPT_DIR/.nnn-build.log" | sed 's/^/         /'; exit 1; }

install -m 0755 "$BASE_SRC/nnn-${NNN_VER}/nnn" "$BASE_DIST/usr/bin/nnn" \
  || { fail "could not install nnn into base-dist"; exit 1; }

# Stage what nnn needs at runtime.
#
# ncurses and tinfo are copied FROM THE PREFIX, not from an ldd closure. nnn
# has no RPATH (deliberately - it resolves through the image), so `ldd` on the
# build host happily answers with the host's own /usr/lib64/libncursesw.so.6
# and libtinfow.so.6. A closure run first would therefore stage the HOST's
# libraries and quietly ship those instead of the pinned ones, which is the
# whole thing the pin exists to prevent. Ours go in first; the closure below
# then only fills in what is genuinely still missing.
#
# Both the SONAME and the versioned file, deliberately as two real files rather
# than a symlink: base-dist is packed into a cpio and extracted into a guest
# that has no ld.so.cache and no /usr/lib to resolve through, and a dangling
# symlink in a cpio is worse than a duplicate.
mkdir -p "$BASE_DIST/usr/lib64" "$BASE_DIST/usr/share"
for soname in libncursesw.so.6 libtinfow.so.6; do
  # Matched with a loop rather than a quoted glob: "$BASE_PREFIX/lib/$soname".*
  # inside [ -e ] expands to itself, the test fails, and the message blames the
  # ncurses build for a shell quoting mistake.
  matched=""
  for f in "$BASE_PREFIX/lib/$soname".*; do
    [ -e "$f" ] && matched="$matched $f"
  done
  if [ -z "$matched" ]; then
    fail "no $soname.* under $BASE_PREFIX/lib - the pinned ncurses was not staged"
    exit 1
  fi
  for f in $matched; do
    real="$(readlink -f "$f")"
    cp -f "$real" "$BASE_DIST/usr/lib64/$(basename "$f")"
    [ "$(basename "$real")" != "$(basename "$f")" ] \
      && cp -f "$real" "$BASE_DIST/usr/lib64/$(basename "$real")"
  done
  # The unversioned symlink, resolved and stored as a real file.
  [ -e "$BASE_PREFIX/lib/$soname" ] \
    || { fail "$BASE_PREFIX/lib/$soname missing"; exit 1; }
  cp -f "$(readlink -f "$BASE_PREFIX/lib/$soname")" "$BASE_DIST/usr/lib64/$soname"
done

rm -rf "$BASE_DIST/usr/share/terminfo"
mkdir -p "$BASE_DIST/usr/share/terminfo"

# Only the entries worth carrying, not the full ncurses database.
#
# Left complete, share/terminfo is 2899 entries and 7.3M - which would make this
# the single largest thing in base-dist by a wide margin, to serve a program that
# will use one or two of them. Nothing in the image sets anything exotic: init.c
# uses TERM=linux on the VT shells, mlterm brings its own terminfo with it in
# x11-dist, and foot sets TERM itself.
#
# The list below is the terminals people actually put in TERM on this kind of
# system, plus the `b/` backspace variants, which are separate files rather than
# aliases and are what `st` and friends reach for. `linux` must be here and is
# checked below: it is what the VT shells run with, and if it is missing every
# interactive shell on the installed system degrades.
TERMINFO_KEEP="linux xterm xterm-256color xterm-16color xterm-direct vt100 vt102 vt220 ansi dumb screen screen-256color tmux tmux-256color rxvt rxvt-unicode rxvt-unicode-256color st st-256color alacritty alacritty-direct konsole foot foot-256color vte vte-256color Eterm Eterm-256color putty putty-256color kitty wezterm tmux-direct gnome gnome-256color wsvt25 cons25 sun wyse50 wyse60"
N_TINFO=0
for t in $TERMINFO_KEEP; do
  found=0
  for p in "$BASE_PREFIX/share/terminfo/$(printf '%s' "$t" | cut -c1)/$t" \
           "$BASE_PREFIX/share/terminfo/$t"; do
    if [ -f "$p" ]; then
      mkdir -p "$BASE_DIST/usr/share/terminfo/$(dirname "${p#"$BASE_PREFIX/share/terminfo/"}")"
      cp -f "$p" "$BASE_DIST/usr/share/terminfo/${p#"$BASE_PREFIX/share/terminfo/"}"
      found=1
    fi
  done
  [ "$found" = "1" ] && N_TINFO=$((N_TINFO + 1))
done

if [ ! -f "$BASE_DIST/usr/share/terminfo/l/linux" ]; then
  fail "terminfo 'linux' was not staged"
  fail "every VT shell in the image runs with TERM=linux; without it they lose cursor and colour"
  exit 1
fi
# The wanted count is the number of words in the list, not its first word.
set -- $TERMINFO_KEEP
info "terminfo: $N_TINFO of $# entries kept (ncurses ships 2899)"

# Whatever is still missing from nnn's dependencies. The loader and libc are
# skipped: assemble-rootfs.sh stages libc for the whole image, so copying a
# second one here would only duplicate what is already there.
collect_deps() {
  local elf="$1" lib real base soname
  for lib in $(ldd "$elf" 2>/dev/null | awk '{print $3}' | grep '^/' || true); do
    base="$(basename "$lib")"
    case "$base" in
      ld-linux*|linux-vdso*|libc.so.6|libm.so.6) continue ;;
    esac
    [ -e "$BASE_DIST/usr/lib64/$base" ] && continue
    real="$(readlink -f "$lib" 2>/dev/null || echo "$lib")"
    cp -f "$real" "$BASE_DIST/usr/lib64/$base"
    soname="$(basename "$real")"
    [ "$soname" != "$base" ] && [ ! -e "$BASE_DIST/usr/lib64/$soname" ] \
      && cp -f "$real" "$BASE_DIST/usr/lib64/$soname"
    collect_deps "$BASE_DIST/usr/lib64/$base"
  done
}
step "ldd closure for nnn"
collect_deps "$BASE_DIST/usr/bin/nnn"

# Verification. nnn is the one binary here that is allowed to link more than
# libc, so the set is asserted explicitly rather than merely reported: a change
# in nnn's dependencies should stop the build, not quietly change the image.
NNN_DT="$(objdump -p "$BASE_DIST/usr/bin/nnn" 2>/dev/null | sed -n 's/^ *NEEDED *//p' \
          | { grep -vE 'ld-linux|linux-vdso|^libc\.so\.' || true; } | LC_ALL=C sort | tr '\n' ' ')"
if [ "$NNN_DT" != "libncursesw.so.6 libtinfow.so.6 " ]; then
  fail "nnn linkage changed: '$NNN_DT'"
  fail "expected exactly libncursesw.so.6 and libtinfow.so.6"
  fail "readline here would mean the image needs a library this build does not stage"
  exit 1
fi
ok "nnn built ($(du -h "$BASE_DIST/usr/bin/nnn" | cut -f1)), links exactly ncursesw + tinfow"
ok "terminfo staged: $(find "$BASE_DIST/usr/share/terminfo" -type f | wc -l) entries, linux present"
info "ncurses libs staged: $(ls "$BASE_DIST/usr/lib64" | grep -c ncurses) files"
# The reason this build exists rather than x11-dist: if either grew anything
# beyond libc, every text-only image would be carrying a library for a
# diagnostic that runs before any graphics exist. ld-linux/linux-vdso are the
# loader, libc is the base image's - neither is an X dependency.
for t in rlin rlperf; do
  # The `|| true` matters: grep -v exits 1 when it filters everything out, and
  # under `set -e` + `pipefail` that would kill the script on the SUCCESS case
  # - which is exactly when these two link nothing.
  DT="$(objdump -p "$BASE_DIST/usr/bin/$t" | sed -n 's/^ *NEEDED *//p' \
        | { grep -vE 'ld-linux|linux-vdso|^libc\.so\.' || true; } | tr '\n' ' ')"
  if [ -n "$DT" ]; then
    fail "$t now links $DT - it was moved here on the grounds it needs no X"
    exit 1
  fi
  ok "$t: nothing linked beyond libc"
done

# ---------------------------------------------------------------------------
header "Self-check: the tree is complete and setuid survived"
for t in sudo ttyrec ttyplay rlin rlperf nnn; do
  p="$BASE_DIST/usr/bin/$t"
  if [ ! -x "$p" ]; then
    fail "$t missing from base-dist"
    exit 1
  fi
done
ok "all six binaries present"

# sudo's setuid bit has to be in the packed file, not just on the build host's
# copy: assemble-rootfs.sh copies with `cp -a`, but initramfs packing does not
# carry ownership and init re-asserts it via secure_sudo_files(). Checking here
# catches the case where a cp -p somewhere in the middle dropped it.
SUID="$(stat -c %a "$BASE_DIST/usr/bin/sudo" 2>/dev/null || stat -f %Lp "$BASE_DIST/usr/bin/sudo")"
if [ "$SUID" != "4755" ]; then
  fail "sudo mode is $SUID, expected 4755 - the setuid bit did not survive"
  exit 1
fi
ok "sudo is setuid 4755"

header "Results"
ok "base-dist ready ($(du -sh "$BASE_DIST" | cut -f1))"
info "layout:"
find "$BASE_DIST" -maxdepth 3 | sort | sed 's/^/         /'
for b in sudo ttyrec ttyplay rlin rlperf; do
  p="$(find "$BASE_DIST" -type f -name "$b" -perm -u+x | head -1)"
  substep "$b linkage:"
  ldd "$p" 2>/dev/null | awk '{print $1}' | grep '^lib' | sort -u \
    | sed 's/^/         /' || true
done
echo
info "next: assemble-rootfs.sh stages base-dist/ into EVERY image -"
info "      it is not gated on -x, unlike x11-dist/."