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

CLEAN=0
JOBS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs)  JOBS="$2"; shift 2 ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)
      sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
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

# --- Colors ---
if [ -t 1 ] && [ -t 2 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_CYAN=$'\e[36m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

info()  { printf "${C_DIM}  ::${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}  [ OK ]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}  [FAIL]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}  [WARN]${C_RESET} %s\n" "$*"; }
header(){ printf "\n${C_BOLD}${C_CYAN}:: %s${C_RESET}\n" "*"; }

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
run_quiet() {
  local log
  log="$(mktemp)"
  if "$@" > "$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  fail "failed: $*"
  tail -25 "$log" | sed 's/^/         /'
  rm -f "$log"
  return 1
}

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
rm -rf "$SUDO_BUILD"
cp -a "$BASE_SRC/sudo-${SUDO_VER}" "$SUDO_BUILD"
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
for t in sudo ttyrec ttyplay rlin rlperf; do
  p="$BASE_DIST/usr/bin/$t"
  if [ ! -x "$p" ]; then
    fail "$t missing from base-dist"
    exit 1
  fi
done
ok "all five binaries present"

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
  info "$b linkage:"
  ldd "$p" 2>/dev/null | awk '{print $1}' | grep '^lib' | sort -u \
    | sed 's/^/         /' || true
done
echo
info "next: assemble-rootfs.sh stages base-dist/ into EVERY image -"
info "      it is not gated on -x, unlike x11-dist/."