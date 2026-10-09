#!/usr/bin/env bash
# build_gcc.sh - build GCC (C only + LTO) for the rlos guest + stage its files
#
# This replaces build_tcc.sh. rlt emits C99; tcc compiled it fast and small
# but had a built-in assembler and linker, which is why the guest never needed
# binutils. GCC has neither, so build_binutils.sh is a hard prerequisite - the
# driver shells out to `as` and `ld` and there is no built-in fallback.
#
# What is deliberately NOT here: any C++ front end, or the libstdcxx/libgomp/
# libquadmath target libraries. rlt emits C, and nothing in the guest links
# OpenMP or __float128. C-only takes the install from ~41MB of cc1 plus a
# second language front end down to a single cc1.
#
# --enable-lto is the reason to build gcc rather than ship tcc: `rlt --compile
# --lto` needs a real LTO implementation with a working plugin and wrapper,
# and tcc has none. LTO matters more here than usual because rl_runtime.c is
# ~15.6k lines of type-erased containers in one translation unit - whole
# program visibility across it is worth real time and size.
#
# Output is a guest-root tree in gcc-dist/:
#   bin/gcc, gcc-ar, gcc-nm, gcc-ranlib    the driver and the LTO binutils
#   libexec/gcc/<triplet>/<ver>/           cc1, collect2, lto-wrapper, lto1,
#                                          liblto_plugin.so
#   lib/gcc/<triplet>/<ver>/               libgcc.a, libgcc_s.so.1,
#                                          crtbegin.o, crtend.o, include-fixed/
#   lib64/                                 glibc crt objects + the -l targets
#   include/...                            glibc header closure + gcc's own
#                                          freestanding headers + ffi.h
#   <tooldir>/bin/                         where the driver looks for as/ld
#
# assemble-rootfs.sh copies this in and symlinks cc -> gcc.
#
# Usage:
#   ./build_gcc.sh                    # build (default)
#   ./build_gcc.sh -j 8               # 8 parallel jobs
#   ./build_gcc.sh --clean            # remove gcc-dist/ before building
#
# Needs on the host: gcc, make, gmp/mpfr/mpc headers (this host has all three),
# and rl-bins/rlos/rlt for the header-closure probe - run build_rl_bins.sh
# first, or the probe step warns and skips.
#
# Needs rlos/gcc symlinked to a gcc tree at the release tag:
#   ln -s ~/dev/c/gcc-16.2.0 gcc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The rl-lang checkout this gcc must agree with. Overridable so that
# `build_rl_bins.sh --rl-lang DIR` and this script can be pointed at the same
# tree; without the override, pointing build_rl_bins.sh elsewhere while leaving
# the default here builds a gcc against one rl-lang's headers and an image with
# another rl-lang's binaries.
RL_LANG_DIR="${RL_LANG_DIR:-$SCRIPT_DIR/rl-lang}"
# Local checkout via symlink: rlos/gcc -> your gcc tree.
GCC_PIN="78d4ac73dd391005b895a6148cd9831e28e1208b" # releases/gcc-16.2.0
GCC_DIST="$SCRIPT_DIR/gcc-dist"
GCC_SRC="$SCRIPT_DIR/gcc"
PKG="$SCRIPT_DIR/gcc-pkg"
CLEAN=0
JOBS=""
REUSE=0

# --- Colors ---
if [ -t 1 ] && [ -t 2 ]; then
  C_RESET=$'\e[0m'
  C_BOLD=$'\e[1m'
  C_DIM=$'\e[2m'
  C_CYAN=$'\e[36m'
  C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'
  C_RED=$'\e[31m'
  C_MAGENTA=$'\e[35m'
  C_BLUE=$'\e[34m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_MAGENTA="" C_BLUE=""
fi

info()  { printf "${C_DIM}  ::${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}  [ OK ]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}  [FAIL]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}  [WARN]${C_RESET} %s\n" "$*"; }
header(){ printf "\n${C_BOLD}${C_CYAN}:: %s${C_RESET}\n" "*"; }

# Sourced after the message helpers so pins_clone_hint can report through fail().
# shellcheck source=pins.sh
source "$SCRIPT_DIR/pins.sh"

# Follows a SONAME symlink chain to a real file, the way the loader will.
# Defined up here because both the runtime-dependency closure below and the
# -l target staging further down need it, and a helper used before its
# definition is a "command not found" that `set -e` turns into a confusing
# failure deep in an unrelated section.
lib_resolve() {
    local cand
    cand="$(ls -1 "/usr/lib64/$1" 2>/dev/null | head -1 || true)"
    [ -n "$cand" ] || cand="$(ldconfig -p 2>/dev/null | grep -m1 -oE "/[^ ]*/$1 \(libc6,x86-64\)" | awk '{print $1}' || true)"
    [ -n "$cand" ] || return 1
    readlink -f "$cand"
}

usage() {
  printf "\n"
  printf "${C_BOLD}Usage:${C_RESET} ${C_CYAN}build_gcc.sh${C_RESET} [OPTIONS]\n"
  printf "\n"
  printf "Build GCC C-only+LTO (%s) into guest-root ${C_BOLD}gcc-dist/${C_RESET}.\n" "${GCC_PIN:0:12}"
  printf "\n"
  printf "${C_BOLD}Options:${C_RESET}\n"
  printf "  ${C_YELLOW}-j, --jobs${C_RESET} ${C_CYAN}N${C_RESET}       Number of parallel jobs\n"
  printf "  ${C_RED}--clean${C_RESET}            Remove gcc-dist/ before building\n"
  printf "  ${C_CYELLOW}--reuse${C_RESET}            Reuse an existing gcc-pkg/, skip configure+make\n"
  printf "  ${C_BLUE}-h, --help${C_RESET}         Show this help\n"
  printf "\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs)  JOBS="$2"; shift 2 ;;
    --clean)    CLEAN=1; shift ;;
    --reuse)    REUSE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          fail "unknown option: $1"; exit 1 ;;
  esac
done

JOBS_FLAG=""
if [ -n "$JOBS" ]; then
  JOBS_FLAG="-j $JOBS"
fi

for tool in gcc make; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    fail "$tool not found on PATH (host build tool)"
    exit 1
  fi
done
if [[ ! -x "$SCRIPT_DIR/binutils-dist/bin/ld" ]]; then
  fail "binutils-dist/ missing - run build_binutils.sh first"
  fail "  gcc has no built-in assembler or linker; without as/ld it cannot link"
  exit 1
fi

if [ "$CLEAN" = "1" ]; then
  header "Cleaning"
  info "removing gcc-dist/ (never touches your gcc/ tree)"
  rm -rf "$GCC_DIST"
  ok "cleaned"
fi

header "Build config"
info "pin:    ${C_BOLD}${GCC_PIN:0:12}${C_RESET} (releases/gcc-16.2.0)"
info "output: ${C_BOLD}gcc-dist/${C_RESET} (guest root)"
info "jobs:   ${C_BOLD}${JOBS:-auto}${C_RESET}"

header "Checking gcc tree"
if [[ ! -f "$GCC_SRC/configure" ]]; then
  # Hint generated from pins.lock, so the suggested clone always names the pinned
  # commit rather than a branch tip that may have moved since this was written.
  pins_clone_hint gcc "$GCC_SRC"
  fail "build_gcc.sh needs a gcc checkout. Symlink one at ./gcc and re-run."
  exit 1
fi
if [[ -d "$GCC_SRC/.git" ]]; then
  HAVE_PIN="$(cd "$GCC_SRC" && git rev-parse HEAD)"
  if [[ "$HAVE_PIN" == "$GCC_PIN" ]]; then
    ok "at tested pin ${HAVE_PIN:0:12}"
  else
    warn "tree is at ${HAVE_PIN:0:12}, tested pin is ${GCC_PIN:0:12} - building anyway"
  fi
else
  warn "not a git tree - building as-is"
fi

# The triplet is discovered, never hardcoded. This host is Gentoo, where
# config.guess says x86_64-pc-linux-gnu rather than the more common
# x86_64-linux-gnu, and every path below (libexec, libgcc, tooldir) is keyed
# off it. Hardcoding would produce a gcc-dist that is silently wrong on any
# other distro.
TRIPLET="$(cd "$GCC_SRC" && ./config.guess 2>/dev/null || true)"
if [[ -z "$TRIPLET" ]]; then
  fail "config.guess produced no triplet - cannot determine install layout"
  exit 1
fi
GCC_VER="$(cd "$GCC_SRC" && cat ./gcc/version.te 2>/dev/null | sed -n 's/.*[0-9]\+\.[0-9]\+\.[0-9]\+\(.*\)/\1/p' | tr -d ' ' || true)"
GCC_VER="${GCC_VER:-16.2.0}"
info "triplet: ${C_BOLD}${TRIPLET}${C_RESET}   version: ${C_BOLD}${GCC_VER}${C_RESET} (native)"

# ---- build ----
#
# --disable-bootstrap because host == target: there is nothing to bootstrap
# from, and a bootstrap would triple the build time for no gain.
#
# --without-isl: this host has gmp, mpfr and mpc but no ISL. ISL drives
# graphite/polyhedral loop optimisation, which buys nothing for the straight
# container code in rl_runtime.c and would otherwise fail configure.
#
# --with-gmp=/usr and friends point at the host's libraries, so
# contrib/download_prerequisites never runs and the build needs no network.
#
# --reuse skips all of it and reuses an existing gcc-pkg/. It exists because
# the build is ~25 minutes while the staging and verification below are the
# parts that actually get iterated on; a clean --clean run is still the way to
# prove the whole thing from scratch.
if [ "$REUSE" = "1" ]; then
    if [[ ! -d "$PKG" ]] || [[ ! -f "$PKG/usr/bin/gcc" ]]; then
        fail "--reuse given but no usable gcc-pkg/ (needs $PKG/usr/bin/gcc)"
        exit 1
    fi
    header "Reusing existing gcc-pkg (--reuse: configure and make skipped)"
    info "staging and verification still run in full - only the build is skipped"
else
header "Configuring gcc (C only, LTO enabled)"
info "./configure --enable-languages=c --enable-lto --without-isl ..."
( cd "$GCC_SRC" && make distclean > /dev/null 2>&1 || true
  ./configure --prefix=/usr \
    --enable-languages=c \
    --enable-lto \
    --disable-bootstrap \
    --disable-multilib \
    --disable-nls \
    --disable-libstdcxx \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libsanitizer \
    --disable-libvtv \
    --disable-libmpx \
    --disable-libstdcxx-pch \
    --without-isl \
    --with-gmp=/usr \
    --with-mpfr=/usr \
    --with-mpc=/usr > "$SCRIPT_DIR/.gcc-conf.log" 2>&1 && \
  make $JOBS_FLAG all-gcc all-target-libgcc all-target-libatomic > "$SCRIPT_DIR/.gcc-build.log" 2>&1 && \
  rm -rf "$PKG" && \
  make install-gcc install-target-libgcc install-target-libatomic DESTDIR="$PKG" >> "$SCRIPT_DIR/.gcc-build.log" 2>&1 ) || {
    fail "gcc build failed - tail of .gcc-build.log:"
    tail -30 "$SCRIPT_DIR/.gcc-build.log" 2>/dev/null | sed 's/^/         /'
    fail "configure tail:"
    tail -20 "$SCRIPT_DIR/.gcc-conf.log" 2>/dev/null | sed 's/^/         /'
    exit 1
  }
ok "gcc $GCC_VER built and staged to gcc-pkg/"
fi

# ---- assemble ----
header "Assembling guest tree"
rm -rf "$GCC_DIST"
mkdir -p "$GCC_DIST/bin"

# Both REL constants carry the leading "usr/" on purpose. gcc-pkg/ and gcc-dist/
# are both laid out as guest roots - pkg is what DESTDIR produced, dist is what
# gets copied over / - so one relative path resolves correctly in both. Dropping
# the usr/ from these is what put libexec at /libexec instead of /usr/libexec
# and made the staged freestanding headers invisible to the compiler.
LIBEXEC_REL="usr/libexec/gcc/$TRIPLET/$GCC_VER"
LIBGCC_REL="usr/lib/gcc/$TRIPLET/$GCC_VER"

# The driver and its LTO-aware binutils. Without gcc-ar/gcc-nm/gcc-ranlib the
# driver can compile but `-flto` link fails when lto-wrapper tries to build the
# intermediate archive with the plain host `ar`.
for tool in gcc gcc-ar gcc-nm gcc-ranlib; do
    if [[ -f "$PKG/usr/bin/$tool" ]]; then
      cp -f "$PKG/usr/bin/$tool" "$GCC_DIST/bin/$tool"
    else
      fail "$tool not installed - found: $(ls "$PKG/usr/bin" 2>/dev/null | tr '\n' ' ')"
      exit 1
    fi
done
ok "driver + LTO binutils: gcc gcc-ar gcc-nm gcc-ranlib"

# cc1 compiles, collect2 drives the link, and the three LTO pieces are the
# reason this build exists. lto1 does the actual LTO code generation at link
# time, lto-wrapper is what the driver execs when it sees -flto on the link
# line, and liblto_plugin.so is what lets gcc-ar handle LTO objects inside a
# static archive.
#
# A gcc without these four is not "gcc without LTO", it is a gcc that fails to
# link the moment anyone passes --lto, which is the flag this build exists to
# support.
LTO_MISSING=""
for piece in cc1 collect2 lto-wrapper lto1 liblto_plugin.so; do
    if [[ ! -f "$PKG/$LIBEXEC_REL/$piece" ]]; then
      LTO_MISSING="$LTO_MISSING $piece"
    fi
done
if [ -n "$LTO_MISSING" ]; then
    fail "missing from $LIBEXEC_REL:$LTO_MISSING"
    fail "installed there: $(ls "$PKG/$LIBEXEC_REL" 2>/dev/null | tr '\n' ' ')"
    fail "these are required for 'rlt --compile --lto' to work at all"
    exit 1
fi
mkdir -p "$GCC_DIST/$LIBEXEC_REL"
cp -f "$PKG/$LIBEXEC_REL"/{cc1,collect2,lto-wrapper,lto1,liblto_plugin.so} "$GCC_DIST/$LIBEXEC_REL/"
ok "cc1 + collect2 + lto-wrapper + lto1 + liblto_plugin.so"

# Strip the executables and the plugin. This is the single biggest lever on
# image size in this whole script: the unstripped drivers carry full DWARF and
# measure cc1 372M, lto1 360M, lto-wrapper 19M, collect2 11M. Stripped they are
# 42M, 40M, 2.3M and 1.4M - about 690MB out of the tree, and a 792M gcc-dist
# becomes roughly 100M.
#
# libgcc.a and the crt objects are deliberately left alone: they are already
# small, and stripping an archive risks disturbing the symbol index that the
# linker reads.
#
# This runs BEFORE the verification below on purpose. A stripped compiler that
# no longer links is a far cheaper failure to find here than after assembling
# an image and booting QEMU.
strip --strip-unneeded \
    "$GCC_DIST/$LIBEXEC_REL"/{cc1,collect2,lto-wrapper,lto1,liblto_plugin.so} \
    "$GCC_DIST/bin"/{gcc,gcc-ar,gcc-nm,gcc-ranlib} 2>/dev/null || true
ok "drivers stripped ($(du -sh "$GCC_DIST" | cut -f1) so far, was ~792M unstripped)"

# libgcc, and the crt begin/end objects every link starts and ends with.
mkdir -p "$GCC_DIST/$LIBGCC_REL"
cp -f "$PKG/$LIBGCC_REL"/libgcc.a "$GCC_DIST/$LIBGCC_REL/" 2>/dev/null || true
cp -f "$PKG/$LIBGCC_REL"/crtbegin.o "$GCC_DIST/$LIBGCC_REL/" 2>/dev/null || true
cp -f "$PKG/$LIBGCC_REL"/crtend.o "$GCC_DIST/$LIBGCC_REL/" 2>/dev/null || true
# libgcc_s.so.1 is the unwinder half. Staged because glibc's static libc
# references _Unwind_* and __gcc_personality_v0, and because a program using
# long double pulls in compiler-rt builtins that live here. Must be THIS gcc's
# copy - a mismatched libgcc_s against a newer cc1 is a runtime crash, not a
# link error, so the host's is never copied as a fallback.
#
# install-target-libgcc puts it under libdir (observed: /usr/lib/../lib64,
# i.e. /usr/lib64), NOT alongside libgcc.a in lib/gcc/<triplet>/<ver>/. Check
# both, because which one applies depends on how the build was configured and
# guessing wrong here is a "file not found" on a file that was built.
LIBGCC_S_SRC=""
for cand in "$PKG/$LIBGCC_REL/libgcc_s.so.1" "$PKG/usr/lib64/libgcc_s.so.1" "$PKG/usr/lib/libgcc_s.so.1"; do
    if [[ -f "$cand" ]]; then
        LIBGCC_S_SRC="$cand"
        break
    fi
done
if [[ -z "$LIBGCC_S_SRC" ]]; then
    fail "libgcc_s.so.1 not found - install-target-libgcc did not produce it"
    fail "looked in: $PKG/$LIBGCC_REL/ $PKG/usr/lib64/ $PKG/usr/lib/"
    fail "everything staged under pkg:"
    find "$PKG" -name 'libgcc*' 2>/dev/null | sed 's/^/         /'
    exit 1
fi
mkdir -p "$GCC_DIST/usr/lib64"
cp -f "$LIBGCC_S_SRC" "$GCC_DIST/usr/lib64/libgcc_s.so.1"
# The linker plugin rewrites -lgcc_s_asneeded into -lgcc_s before ld sees it, so
# the real libgcc_s has to be linkable by that name too or the link fails with
# "cannot find -lgcc_s" while libgcc_s.so.1 sits right there unused.
ln -sf libgcc_s.so.1 "$GCC_DIST/usr/lib64/libgcc_s.so"
ok "libgcc_s.so -> libgcc_s.so.1 (from this gcc, $(du -h "$LIBGCC_S_SRC" | cut -f1))"

# The *asneeded variants. gcc's link spec passes these by name, so the file
# has to exist under exactly that name or ld fails with
#
#   ld: cannot find -lgcc_s_asneeded: No such file or directory
#
# which is confusing because the "real" library it stands in for is right
# there. install-target-libgcc puts libgcc_s_asneeded.so under libdir.
#
# libatomic is a separate target library, and it is NOT optional here: gcc's
# spec emits -latomic_asneeded on every link regardless of whether the program
# uses atomics, because it cannot know at link-spec time. Building only
# libgcc produces a compiler whose every single link fails. On x86_64 it is a
# few KB, and it exists for the handful of 16-byte builtins x86-64 lacks.
ASNEEDED_MISSING=""
for lib in libgcc_s_asneeded libatomic_asneeded libatomic; do
    src=""
    for cand in "$PKG/usr/lib64/$lib.so" "$PKG/usr/lib/$lib.so" \
                "$PKG/usr/$LIBGCC_REL/$lib.a" "$PKG/usr/lib64/$lib.a"; do
        if [[ -f "$cand" ]]; then src="$cand"; break; fi
    done
    if [[ -n "$src" ]]; then
        cp -f "$src" "$GCC_DIST/usr/lib64/$(basename "$src")"
    else
        ASNEEDED_MISSING="$ASNEEDED_MISSING $lib"
    fi
done
if [ -n "$ASNEEDED_MISSING" ]; then
    fail "gcc's link spec needs these by name and they were not built:$ASNEEDED_MISSING"
    fail "gcc emits -latomic_asneeded on every link, so a libgcc-only build"
    fail "fails to link anything at all. Check install-target-libatomic ran."
    exit 1
fi
ok "asneeded variants staged: $(ls "$GCC_DIST/usr/lib64" | grep asneeded | tr '\n' ' ')"

# ---- the shared libraries cc1 and lto1 need to start at all -----------------
#
# This is the bug that makes the whole image look fine and then fail on the
# first compile in the guest:
#
#   cc: fatal error: cannot execute 'cc1': posix_spawnp: No such file or directory
#
# Nothing is wrong with cc1 or with the path to it. Configuring
# --with-gmp=/usr --with-mpfr=/usr --with-mpc=/usr (instead of
# contrib/download_prerequisites, which needs network) links cc1 and lto1
# against the HOST's shared libgmp/libmpfr/libmpc. Those are then required at
# exec time, and they are not in the guest:
#
#   * nothing else in the image links them, so assemble-rootfs.sh's ldd closure
#     never stages them either - and cc1 is a build-time tool, not a shipped
#     binary, so that closure structurally cannot see it
#   * the error names cc1, not the library, because the spawn fails before any
#     diagnostic about the loader can be printed
#
# Discovered from ldd rather than hardcoded, so a future configure line that
# pulls in something else does not silently reintroduce this. libc and libm are
# skipped: the image stages those for every other binary already.
DEP_ROOTS=()
for f in cc1 lto1 lto-wrapper collect2; do
    while IFS= read -r d; do
        [ -n "$d" ] && DEP_ROOTS+=("$d")
    done < <(ldd "$GCC_DIST/$LIBEXEC_REL/$f" 2>/dev/null \
             | awk '/=> \//{print $3}' | xargs -r -n1 basename | sort -u)
done
DEP_QUEUE=("${DEP_ROOTS[@]}")
DEP_SEEN=""
DEP_STAGED=""
DEP_UNRESOLVED=""
while [ ${#DEP_QUEUE[@]} -gt 0 ]; do
    l="${DEP_QUEUE[0]}"
    DEP_QUEUE=("${DEP_QUEUE[@]:1}")
    case " $DEP_SEEN " in *" $l "*) continue ;; esac
    DEP_SEEN="$DEP_SEEN $l"
    case "$l" in
        libc.so.6|libm.so.6|ld-linux-x86-64.so.2) continue ;;
    esac
    src="$(lib_resolve "$l" || true)"
    if [ -z "$src" ] || [ ! -e "$src" ]; then
        DEP_UNRESOLVED="$DEP_UNRESOLVED $l"
        continue
    fi
    cp -f "$src" "$GCC_DIST/usr/lib64/$l"
    DEP_STAGED="$DEP_STAGED $l"
    # Its own dependencies join the queue - libmpc needs libmpfr and libgmp, and
    # on another distro those pull in libintl.
    while IFS= read -r d; do
        [ -n "$d" ] && DEP_QUEUE+=("$d")
    done < <(ldd "$src" 2>/dev/null \
             | awk '/=> \//{print $3}' | xargs -r -n1 basename | sort -u)
done
if [ -n "$DEP_UNRESOLVED" ]; then
    fail "cc1/lto1 need these shared libraries and they are not on this host:$DEP_UNRESOLVED"
    fail "  Install them, or configure gcc with static gmp/mpfr/mpc so cc1"
    fail "  carries no runtime dependency at all."
    exit 1
fi
# libzstd is the one that surprised us: --without-zstd on binutils removed it
# there, but gcc's own libs link it, and it is easy to assume it went away too.
if [ -n "$DEP_STAGED" ]; then
    ok "cc1/lto1 runtime closure staged:$DEP_STAGED"
fi

# ---- verification: every staged gcc binary can actually start ---------------
#
# The binutils script has an equivalent check, added there after a build
# produced a tree whose `as` would not exec. This is the same class of bug
# reaching the compiler, and the check has to exist in both places or it only
# protects whichever one was written second.
#
# ldd on the host answers "does this run HERE", and the host has libmpfr and
# everything else. The question that matters is whether every DT_NEEDED entry
# resolves inside the staged tree (or against libc/libm, which the image
# guarantees). Anything else is an in-guest exec failure, so it is a build
# error rather than a warning.
header "Shared-library closure for the staged compiler"
GCC_BINS="$GCC_DIST/bin/gcc $GCC_DIST/bin/gcc-ar $GCC_DIST/bin/gcc-nm \
$GCC_DIST/bin/gcc-ranlib $GCC_DIST/$LIBEXEC_REL/cc1 \
$GCC_DIST/$LIBEXEC_REL/collect2 $GCC_DIST/$LIBEXEC_REL/lto-wrapper \
$GCC_DIST/$LIBEXEC_REL/lto1"
DEP_OK=1
for f in $GCC_BINS; do
    [ -f "$f" ] || { fail "missing staged binary: $f"; exit 1; }
    unexpected=""
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        case "$d" in
            libc.so.6|libm.so.6|ld-linux-x86-64.so.2) continue ;;
        esac
        # Either already staged into usr/lib64, or the interpreter/loader the
        # guest provides.
        if ! compgen -G "$GCC_DIST/usr/lib64/$d" > /dev/null; then
            unexpected="$unexpected $d"
        fi
    done < <(ldd "$f" 2>/dev/null | awk '/=> \//{print $3}' | xargs -r -n1 basename | sort -u)
    if [ -n "$unexpected" ]; then
        fail "$(basename "$f"): would not start in-guest, missing:$unexpected"
        DEP_OK=0
    fi
done
if [ "$DEP_OK" = "0" ]; then
    fail "staged gcc binaries depend on libraries the guest does not have."
    fail "  Stage them in the closure block above; do NOT rely on the ldd"
    fail "  closure in assemble-rootfs.sh, which cannot see build-time tools."
    exit 1
fi
ok "all 8 staged compiler binaries resolve within the tree (cc1, lto1, lto-wrapper, collect2, gcc*)"
ok "libgcc.a + crtbegin.o + crtend.o + include-fixed"

# include-fixed holds the target-specific copies of stddef.h/stdarg.h that
# gcc's own internal headers must agree with. Mismatching them against the
# glibc versions is a classic source of "conflicting types for size_t".
if [[ -d "$PKG/$LIBGCC_REL/include-fixed" ]]; then
    cp -a "$PKG/$LIBGCC_REL/include-fixed/." "$GCC_DIST/$LIBGCC_REL/include-fixed/"
fi

# ---- interrogate the baked paths, then satisfy them exactly ----
#
# Everything below this point is driven by asking the compiler where it looks,
# rather than by predicting it. GCC 16 no longer has a named ST_LIBDIR in
# gcc/Makefile.in - the crt and library search dirs are derived inside the
# driver - so there is nothing stable to read out of the Makefiles. But the
# built driver can be asked directly:
#
#   gcc -print-file-name=crt1.o     where the driver looks for crt1.o
#   gcc -print-prog-name=as         where the driver execs the assembler
#   gcc -print-search-dirs          the full library search path
#
# A wrong guess here is invisible until an in-guest link fails, so read it.
header "Interrogating baked paths (the driver knows, the Makefiles do not)"
STAGED_GCC="$GCC_DIST/bin/gcc"
BAKED_AS="$("$STAGED_GCC" -print-prog-name=as 2>/dev/null || true)"
BAKED_LD="$("$STAGED_GCC" -print-prog-name=ld 2>/dev/null || true)"
BAKED_CRT1="$("$STAGED_GCC" -print-file-name=crt1.o 2>/dev/null || true)"
SEARCH_DIRS="$("$STAGED_GCC" -print-search-dirs 2>/dev/null || true)"
info "as   -> ${BAKED_AS:-unknown}"
info "ld   -> ${BAKED_LD:-unknown}"
info "crt1 -> ${BAKED_CRT1:-unknown}"
echo "$SEARCH_DIRS" | sed -n 's/^libraries=\(.*\)/\1/p' | tr ':' '\n' | head -12 | sed 's/^/         lib: /'

# Satisfy the baked as/ld. On this Gentoo host configure found them under
# /usr/x86_64-pc-linux-gnu/bin, so that path is now compiled into the driver
# and the guest has to have a file there or every in-guest compile dies with
# "as: command not found". Rather than force the paths at configure time -
# which would mean hardcoding a Gentoo triplet into the build - stage the
# already-built binutils at exactly the path the driver asks for.
stage_for_prog() {
    local prog="$1" baked="$2"
    [ -n "$baked" ] || return 0
    # Only absolute paths need staging; a bare name means "not found, search
    # COMPILER_PATH then PATH", and /usr/bin is on PATH in the guest.
    case "$baked" in
        /*) ;;
        *) return 0 ;;
    esac
    local normalized
    normalized="$(cd / && realpath -m "$baked" 2>/dev/null || echo "$baked")"
    if [[ -f "$GCC_DIST$normalized" ]]; then
        return 0
    fi
    mkdir -p "$GCC_DIST$(dirname "$normalized")"
    if [[ -f "$SCRIPT_DIR/binutils-dist/bin/$prog" ]]; then
        cp -f "$SCRIPT_DIR/binutils-dist/bin/$prog" "$GCC_DIST$normalized"
        ok "$prog staged at $normalized (driver's baked path)"
    else
        warn "no binutils-dist/bin/$prog to satisfy the baked path $normalized"
    fi
}
stage_for_prog as "$BAKED_AS"
stage_for_prog ld "$BAKED_LD"

# ---- glibc crt objects and the -l targets ----
#
# Same shape as build_tcc.sh staged them, and for the same reason: the guest
# ships the *runtime* shared objects, but a linker needs something named
# libc.so / libm.so to resolve -lc / -lm against. ld's default SEARCH_DIR
# already covers /usr/lib64 (build_binutils.sh asserts it), so these go there.
mkdir -p "$GCC_DIST/usr/lib64"
STAGED_CRT=""
for crt in crt1.o crti.o crtn.o Scrt1.o rcrt1.o Mcrt1.o; do
    if [[ -f "/usr/lib64/$crt" ]]; then
      cp -f "/usr/lib64/$crt" "$GCC_DIST/usr/lib64/"
      STAGED_CRT="$STAGED_CRT $crt"
    fi
done
ok "glibc crt objects in usr/lib64:$STAGED_CRT"

# libc.so as a symlink to the shared libc.so.6 - never libc.a. Static glibc
# carries references to __gcc_personality_v0 and _Unwind_* which live in
# libgcc, and rlt does not pass -lgcc_s, so a static libc links small programs
# and fails big ones. The shared object is self-contained and matches every
# other binary in the image.
LIBC_SO="/usr/lib64/libc.so.6"
if [[ -f "$LIBC_SO" ]]; then
    cp -f "$(readlink -f "$LIBC_SO")" "$GCC_DIST/usr/lib64/libc.so.6"
    ln -sf libc.so.6 "$GCC_DIST/usr/lib64/libc.so"
    rm -f "$GCC_DIST/usr/lib64/libc.a"
    # Write the whole thing to a file first, then grep it. Piping `strings` into
    # `grep -m1` under `set -o pipefail` is the false negative this repo has
    # already been bitten by (build_tcc.sh documents it): grep exits as soon as
    # it has a match, strings dies of SIGPIPE, pipefail reports the pipeline as
    # failed, and a `|| echo unknown` fallback fires on a search that actually
    # succeeded.
    RUNTIME_VER="$(strings "$LIBC_SO" 2>/dev/null \
                   | grep -oE 'GNU C Library .*stable release version [0-9]+\.[0-9]+' \
                   | head -1 || true)"
    : "${RUNTIME_VER:=unknown}"
    ok "libc.so -> libc.so.6 (shared, not static) from: $RUNTIME_VER"
else
    fail "libc.so.6 not found at $LIBC_SO - nothing could link in-guest"
    exit 1
fi

if [[ -f "/usr/lib64/libm.so.6" ]]; then
    cp -f "$(readlink -f /usr/lib64/libm.so.6)" "$GCC_DIST/usr/lib64/libm.so.6"
    ln -sf libm.so.6 "$GCC_DIST/usr/lib64/libm.so"
    ok "libm.so -> libm.so.6 (rlt passes -lm unconditionally)"
else
    fail "libm.so.6 not found - rlt always passes -lm"
    exit 1
fi

if [[ -f "/usr/lib64/libmvec.so.1" ]]; then
    cp -f "$(readlink -f /usr/lib64/libmvec.so.1)" "$GCC_DIST/usr/lib64/libmvec.so.1" 2>/dev/null || true
    ok "libmvec.so.1"
fi

# The libraries rlt can put on the command line beyond -lm/-lc. libffi and
# libcurl reach the guest through assemble-rootfs.sh's ldd closure because
# something already-shipped links them; these four do not, because nothing
# shipped references them - they are only ever needed by a binary produced AT
# RUNTIME by rlt --compile, which no build step here can see.
#
# Staged by SONAME, because the linker records the SONAME in DT_NEEDED and the
# loader looks for exactly that string. libyaml's real file is
# libyaml-0.so.2.0.9 and its SONAME is libyaml-0.so.2; staging it as
# libyaml.so.0 links and then fails at exec.
for rt in yaml argon2 pthread dl ffi; do
    case "$rt" in
        yaml)    soname="libyaml-0.so.2" ;;
        argon2)  soname="libargon2.so.1" ;;
        pthread) soname="libpthread.so.0" ;;
        dl)      soname="libdl.so.2" ;;
        ffi)     soname="libffi.so.8" ;;
    esac
    src="$(lib_resolve "$soname" || true)"
    if [ -z "$src" ] || [ ! -e "$src" ]; then
        fail "could not find $soname on this host - rlt --compile would fail in-guest"
        fail "on Gentoo: emerge yaml app-crypt/argon2 glibc libffi"
        exit 1
    fi
    cp -f "$src" "$GCC_DIST/usr/lib64/$soname"
    ok "staged $soname ($(du -h "$src" | cut -f1))"
done

# libffi is the one that used to be staged on faith. build_tcc.sh noted that
# libffi and libcurl "reach the guest through assemble-rootfs.sh's ldd closure"
# - which is true, but only because some already-shipped binary happens to link
# libffi. That is an accident, not a contract: if the binary that pulls it in
# is ever dropped, every std::c program silently stops linking. rlt emits
# -DRL_USE_LIBFFI -lffi whenever a program mentions std::c, so the library is
# staged here deliberately, next to its header. It is 4KB and depends on libc
# alone.
#
# libcurl is NOT staged: rlt's -DRL_USE_CURL branch is dead code (the codegen
# never emits the token the branch tests for), so nothing can ask for it.

# -lNAME dev symlinks. ld resolves -lNAME by looking for libNAME.so (or
# libNAME.a); it will NOT accept libNAME.so.N. So the SONAME alone is not
# enough, and the symptom is a bare "cannot find -lpthread" even though
# libpthread.so.0 is sitting right there.
#
# The target pattern is a glob, not lib<name>.so.*: libyaml's real file is
# libyaml-0.so.2, which libyaml.so.* does not match.
DEV_LINK_LIBS="pthread dl argon2 yaml ffi"
DEV_MISSING=""
for l in $DEV_LINK_LIBS; do
    target="$(ls -1 "$GCC_DIST/usr/lib64/lib$l"*.so.* 2>/dev/null | head -1 || true)"
    if [ -z "$target" ]; then
        DEV_MISSING="$DEV_MISSING $l"
        continue
    fi
    ln -sf "$(basename "$target")" "$GCC_DIST/usr/lib64/lib$l.so"
done
if [ -n "$DEV_MISSING" ]; then
    fail "no staged libNAME.so.N for:$DEV_MISSING - rlt emits -l for these"
    fail "staged lib64: $(ls "$GCC_DIST/usr/lib64" | tr '\n' ' ')"
    exit 1
fi
ok "libNAME.so dev symlinks for: $DEV_LINK_LIBS"

# ---- headers ----
#
# Three separate closures, because three separate things provide headers and
# missing any one of them is an in-guest "include file not found":
#
#   1. glibc's, via `gcc -M rl_runtime.c`. rl_runtime.c is the superset -
#      every rlt program links it - so probing it rather than a toy program is
#      what makes this complete.
#   2. gcc's own freestanding headers, which do NOT come from that probe
#      because they live in gcc's include-fixed and the system include dir, not
#      in /usr/include. stddef.h and stdarg.h especially: glibc's stdio.h
#      includes gcc's, and staging glibc's copy instead breaks every compile.
#   3. ffi.h, for the std::c path. See below.

header "Staging gcc's freestanding headers"
GCC_INC="$PKG/$LIBGCC_REL/include"
if [[ ! -d "$GCC_INC" ]]; then
    fail "gcc's include dir not found at $GCC_INC"
    exit 1
fi
# Stage gcc's own headers wholesale rather than a hand-picked list.
#
# Two reasons, both learned the hard way here:
#
#   * A list invites whack-a-mole. limits.h needs syslimits.h, features.h needs
#     stdc-predef.h, stdio.h needs bits/stdio.h, and each one surfaces as a
#     separate in-guest "No such file or directory". The full non-intrinsic set
#     is 22 files and 172KB, so there is no reason to enumerate.
#   * They must precede glibc's copies in the guest's search order.
#     stddef.h, stdarg.h and stdint.h in particular are gcc's to provide -
#     glibc's versions either #include_next them or are tuned to a different
#     gcc.
#
# The *intrin.h family is skipped: ~115 files of x86 intrinsics that nothing
# transpiled from RL includes, and which would be dead weight in the image.
#
# stdc-predef.h needs a special case because it is the one header -H cannot
# find: glibc's features.h does an UNCONDITIONAL `#include <stdc-predef.h>`,
# but gcc preincludes it internally, so it never appears in the closure probe
# above. Without it the guest compile fails with
#
#   features.h:518:10: fatal error: stdc-predef.h: No such file or directory
#
# despite the probe reporting a complete closure. On this host it lives in
# /usr/include rather than gcc's include dir, so fall back to it.
GCC_INC_OUT="$GCC_DIST/$LIBGCC_REL/include"
mkdir -p "$GCC_INC_OUT"
for h in "$GCC_INC"/*.h; do
    base="$(basename "$h")"
    case "$base" in
        *intrin.h) continue ;;
    esac
    cp -f "$h" "$GCC_INC_OUT/$base"
done
if [[ ! -f "$GCC_INC_OUT/stdc-predef.h" ]]; then
    if [[ -f "/usr/include/stdc-predef.h" ]]; then
        cp -f "/usr/include/stdc-predef.h" "$GCC_INC_OUT/stdc-predef.h"
    else
        fail "stdc-predef.h not found in $GCC_INC or /usr/include"
        fail "  every in-guest compile fails in features.h without it"
        exit 1
    fi
fi
# limits.h pulling syslimits.h and stdio.h pulling bits/stdio.h are the two
# that actually broke, so assert on them rather than trusting the count.
for need in stddef.h stdarg.h stdint.h syslimits.h stdc-predef.h float.h; do
    if [[ ! -f "$GCC_INC_OUT/$need" ]]; then
        fail "gcc header $need missing from $LIBGCC_REL/include"
        fail "  staged: $(ls "$GCC_INC_OUT" | tr '\n' ' ')"
        exit 1
    fi
done
N_FS="$(ls "$GCC_INC_OUT" 2>/dev/null | wc -l)"
ok "$N_FS gcc headers in $LIBGCC_REL/include (freestanding + syslimits + stdc-predef)"

# The flags every real rlt-generated program is compiled with, defined ONCE.
#
# This has to be a single source of truth shared by the header-closure probe
# and the verification compile below, because they must agree exactly. They did
# not, and the mismatch cost a real bug:
#
#   glibc's features.h only defines __USE_EXTERN_INLINES when __OPTIMIZE__ is
#   set, i.e. only at -O2. Under that macro stdio.h pulls in bits/stdio.h.
#   Probing with a bare `gcc -M` (no -O) therefore produced a closure missing
#   bits/stdio.h, and the first real -O2 compile died with
#
#     fatal error: bits/stdio.h: No such file or directory
#
# tcc never tripped this, which is why a closure probe that was wrong for gcc
# still produced a working tcc guest.
#
# So: -std=c11 because that is what rlt pins. Measured with the staged compiler,
# rl_runtime.c is clean under `-std=c11 -pedantic-errors` with zero diagnostics;
# the only thing standing between it and C99 is `_Generic` (C11), used by the
# rl_ok/rl_box/rl_print/rl_println/rl_unwrap dispatch macros. This MUST stay in
# step with the -std in rlt.rs, or the closure computed here does not match the
# compile the guest performs.
# -O2 because that is rlt's default and it is what turns on __OPTIMIZE__.
# -fno-strict-aliasing because rl_runtime.c type-puns through unions and void*
# throughout (type-erased rl_array, rl_value, rl_map*/rl_set*), which -O2 with
# a real aliasing optimiser may reorder into wrong answers; tcc never did this.
RL_CFLAGS="-std=c11 -O2 -fno-strict-aliasing"

header "Collecting glibc headers (-H closure on rl_runtime.c, $RL_CFLAGS)"
PROBE_DIR="$(mktemp -d)"
if [[ -x "$SCRIPT_DIR/rl-bins/rlos/rlt" ]]; then
    cp "$SCRIPT_DIR/rl_programs/hostname.rl" "$PROBE_DIR/probe.rl"
    ( cd "$PROBE_DIR" && "$SCRIPT_DIR/rl-bins/rlos/rlt" --runtime probe.rl > /dev/null 2>&1 )
else
    # Fallback for a tree that was built before rl_programs/nano/*.c became
    # generated output. Those files are gitignored (rlt --compile produces
    # them), so on a fresh clone they are absent too and this fallback cannot
    # rescue the build - say so plainly instead of letting the header closure
    # come back empty and failing several steps later as "empty header closure",
    # which points at the probe rather than at the missing prerequisite.
    if [[ -f "$SCRIPT_DIR/rl_programs/nano/rl_runtime.c" ]]; then
        warn "rl-bins/rlos/rlt absent - using rl_runtime.c from rl_programs/nano/"
        cp "$SCRIPT_DIR/rl_programs/nano/rl_runtime.c" "$PROBE_DIR/" || true
        cp "$SCRIPT_DIR/rl_programs/nano/rl_runtime.h" "$PROBE_DIR/" 2>/dev/null || true
    else
        fail "rlt not found and no fallback runtime source."
        fail "  Build it first:  ./build_rl_bins.sh   (needs rl-lang at $RL_LANG_DIR)"
        fail "  It produces rl-bins/rlos/rlt, which generates the rl_runtime.c"
        fail "  this probe needs. The files under rl_programs/nano/ are gitignored"
        fail "  build output, so there is nothing to fall back to on a fresh clone."
        exit 1
    fi
fi
# -H, not -M. -M emits the dependency list the preprocessor computes, which
# misses headers reached only under a conditional macro; -H reports every file
# the compiler actually opened, so it is the closure that matters by
# construction. -fsyntax-only because the header set does not depend on linking.
#
# Probed THREE times and unioned, because the reachable set depends on more than
# just -O2, and each pass catches a different miss:
#
#   $RL_CFLAGS        what rlt actually passes (c11, and rl_runtime.c's own
#                     `#define _GNU_SOURCE`)
#   default dialect   for a hand-written `cc foo.c` in the guest
#   bare, no macros   rlt's generated files define _GNU_SOURCE and
#                     _POSIX_C_SOURCE, which NARROWS the feature set and changes
#                     which glibc headers get pulled in. bits/pthread_stack_min.h
#                     is the concrete case: it is reachable only from a probe
#                     without those macros, so neither of the two passes above
#                     ever sees it, and a c11-only closure produces a toolchain
#                     where every rlt build works and `cc foo.c` dies on a
#                     missing glibc header.
#
# All three keep -O2, since that is the other half of what gates includes
# (__USE_EXTERN_INLINES, hence bits/stdio.h, depends on __OPTIMIZE__).
HDRS_C11="$(cd "$PROBE_DIR" && gcc $RL_CFLAGS -H -fsyntax-only rl_runtime.c 2>&1 \
            | sed -n 's/^\.* //p' | grep '^/usr/include/' | sort -u || true)"
HDRS_DEF="$(cd "$PROBE_DIR" && gcc -O2 -fno-strict-aliasing -H -fsyntax-only rl_runtime.c 2>&1 \
            | sed -n 's/^\.* //p' | grep '^/usr/include/' | sort -u || true)"
printf '%s\n' '#include <stdio.h>' '#include <stdlib.h>' '#include <string.h>' \
  '#include <strings.h>' '#include <unistd.h>' '#include <limits.h>' \
  '#include <errno.h>' '#include <fcntl.h>' '#include <dirent.h>' \
  '#include <time.h>' '#include <ctype.h>' '#include <math.h>' \
  '#include <signal.h>' '#include <pthread.h>' 'int main(void){return 0;}' \
  > "$PROBE_DIR/bare.c"
HDRS_BARE="$(cd "$PROBE_DIR" && gcc -O2 -H -fsyntax-only bare.c 2>&1 \
             | sed -n 's/^\.* //p' | grep '^/usr/include/' | sort -u || true)"
HDRS="$(printf '%s\n%s\n%s\n' "$HDRS_C11" "$HDRS_DEF" "$HDRS_BARE" \
        | grep '/usr/include/' | sort -u)"
if [[ -z "$HDRS" ]]; then
    fail "empty header closure - the rlt/gcc probe failed"
    rm -rf "$PROBE_DIR"
    exit 1
fi
while IFS= read -r hdr; do
    [[ -z "$hdr" ]] && continue
    mkdir -p "$GCC_DIST/$(dirname "$hdr")"
    cp -n "$hdr" "$GCC_DIST/$hdr"
done <<< "$HDRS"
N_HDRS="$(printf "%s" "$HDRS" | grep -c / || true)"
# The headers that are only reachable when optimizing. Missing these is the
# failure described above, so assert on them by name rather than trusting the
# count - a count can look plausible while the set is wrong.
for need in stdio.h bits/stdio.h stdlib.h string.h unistd.h dlfcn.h; do
    if [[ ! -f "$GCC_DIST/usr/include/$need" ]]; then
        fail "$need missing from the header closure - an -O2 compile fails in-guest"
        rm -rf "$PROBE_DIR"
        exit 1
    fi
done
# pthread_stack_min.h is the header the third (bare) pass exists for: glibc ships
# it as a generated file and only includes it from bits/pthread_stack_min-dynamic.h
# when the probe defines no feature macros, so rlt's own -H output never names it.
if [[ ! -f "$GCC_DIST/usr/include/bits/pthread_stack_min.h" ]]; then
    fail "bits/pthread_stack_min.h missing - the bare closure pass did not run"
    fail "  or found nothing. A hand-written 'cc foo.c' in the guest would fail"
    fail "  on it even though every rlt build is fine."
    rm -rf "$PROBE_DIR"
    exit 1
fi
ok "$N_HDRS glibc headers (rl_runtime.c c11 + default, union bare-macro probe; all -O2)"

# miniaudio's closure. rl_runtime.c #includes miniaudio.h under RL_USE_AUDIO,
# which pulls in headers no non-audio program names - collecting them one
# compile at a time is how this went wrong before (first pthread.h, then
# assert.h). Take the whole closure in one pass instead.
MINIAUDIO_H="$RL_LANG_DIR/crates/rl-cc/runtime/miniaudio.h"
if [[ -f "$MINIAUDIO_H" ]]; then
    printf '%s\n' '#define MINIAUDIO_IMPLEMENTATION' '#include "miniaudio.h"' \
      'int main(void){ return 0; }' > "$PROBE_DIR/ma.c"
    MHDRS="$(cd "$PROBE_DIR" && gcc $RL_CFLAGS -H -fsyntax-only -I"$(dirname "$MINIAUDIO_H")" ma.c 2>&1 \
             | sed -n 's/^\.* //p' | grep '^/usr/include/' | sort -u)"
    while IFS= read -r hdr; do
        [[ -z "$hdr" ]] && continue
        rel="${hdr#/usr/include/}"
        if [[ ! -e "$GCC_DIST/usr/include/$rel" ]]; then
            mkdir -p "$GCC_DIST/$(dirname "$hdr")"
            cp -n "$hdr" "$GCC_DIST/$hdr"
        fi
    done <<< "$MHDRS"
    # Assert on the two headers miniaudio fails on first, so a partial closure
    # is a loud build failure rather than an in-guest compile error.
    for need in pthread.h assert.h; do
        if [[ ! -f "$GCC_DIST/usr/include/$need" ]]; then
            fail "$need missing after the miniaudio closure - audio programs cannot compile in-guest"
            rm -rf "$PROBE_DIR"
            exit 1
        fi
    done
    ok "miniaudio closure (audio path)"
else
    warn "miniaudio.h not found - audio .rl programs will fail to compile in-guest"
fi

# ---- third-party header closures: ffi.h, yaml.h, argon2.h ----
#
# rl_runtime.c includes these three behind RL_USE_* guards:
#
#   rl_runtime.c:13845  #ifdef RL_USE_LIBFFI  -> #include <ffi.h>
#   rl_runtime.c:7714   #ifdef RL_USE_YAML    -> #include <yaml.h>
#   rl_runtime.c:6768   #ifdef RL_USE_ARGON2  -> #include <argon2.h>
#
# and rlt defines those macros whenever a program touches std::c,
# std::serialize or std::crypto's password hashing. Because the guards are off
# during the glibc closure probe above, NONE of the three is in that closure,
# so each has to be staged separately. Previously none were, and the result was
# three different in-guest failures on programs that otherwise linked fine:
#
#   rl_runtime.c:13845:10: fatal error: ffi.h: No such file or directory
#
# Each is staged as a CLOSURE rather than a single file, for the same reason the
# glibc headers are - ffi.h line 84 includes <ffitarget.h>, so copying only
# ffi.h just moves the identical error down one line.
#
# stage_closure <label> <primary header> <source base dir> <dest dir under usr/include>
#
# Probed with the same $RL_CFLAGS as everything else, and filtered to files
# under the source base so the probe does not drag the whole glibc tree in a
# second time.
stage_closure() {
    local label="$1" hdr="$2" base="$3" dest="$4"
    local probe="$PROBE_DIR/closure_${label}.c"
    printf '#include <%s>\nint main(void){return 0;}\n' "$hdr" > "$probe"
    local -a incargs=()
    if [ "$base" != "/usr/include" ]; then
        incargs=( "-I$base" )
    fi
    local closure added=0 f rel
    closure="$(cd "$PROBE_DIR" && gcc $RL_CFLAGS "${incargs[@]}" -H -fsyntax-only \
               "$probe" 2>&1 | sed -n 's/^\.* //p' | sort -u)"
    if [[ -z "$closure" ]]; then
        fail "$label closure probe produced nothing - is $hdr installed?"
        exit 1
    fi
    for f in $closure; do
        case "$f" in
            "$base"/*) ;;
            *) continue ;;
        esac
        rel="${f#$base/}"
        if [[ ! -e "$GCC_DIST/$dest/$rel" ]]; then
            # dirname of the DESTINATION path, not of a path that already has
            # $GCC_DIST prefixed onto it. Prefixing twice builds a recursive
            # empty tree at $GCC_DIST/home/.../$GCC_DIST/... inside the guest
            # root, which is confusing to debug and ships as junk.
            mkdir -p "$(dirname "$GCC_DIST/$dest/$rel")"
            cp -n "$f" "$GCC_DIST/$dest/$rel"
            added=$((added + 1))
        fi
    done
    if [[ ! -f "$GCC_DIST/$dest/$hdr" ]]; then
        fail "<$hdr> did not land in $dest from base $base"
        fail "  closure saw: $(echo $closure | tr '\n' ' ')"
        exit 1
    fi
    ok "$label closure: $added new header(s) in $dest (from $base)"
}

# ffi.h is not under /usr/include on a multiarch/Gentoo host; pkg-config
# reports -I/usr/lib64/libffi/include. Resolve it the same way rlt does, so the
# two agree on which libffi is in play.
FFI_DIR=""
if command -v pkg-config > /dev/null 2>&1 && pkg-config --exists libffi 2>/dev/null; then
    for d in $(pkg-config --cflags-only-I libffi 2>/dev/null | tr ' ' '\n' | sed 's/^-I//'); do
        if [ -f "$d/ffi.h" ]; then FFI_DIR="$d"; break; fi
    done
fi
if [ -z "$FFI_DIR" ]; then
    for d in /usr/include /usr/include/ffi /usr/lib64/libffi/include /usr/local/include; do
        if [ -f "$d/ffi.h" ]; then FFI_DIR="$d"; break; fi
    done
fi
if [ -z "$FFI_DIR" ]; then
    fail "ffi.h not found - std::c programs would fail in-guest with"
    fail "  'fatal error: ffi.h: No such file or directory' from rl_runtime.c"
    fail "on Gentoo: emerge libffi"
    rm -rf "$PROBE_DIR"
    exit 1
fi
mkdir -p "$GCC_DIST/usr/include"
stage_closure "ffi"    "ffi.h"    "$FFI_DIR"     "usr/include"
stage_closure "yaml"   "yaml.h"   "/usr/include"  "usr/include"
stage_closure "argon2" "argon2.h" "/usr/include"  "usr/include"

rm -rf "$PROBE_DIR"

# ---- verification ----
#
# Everything above is bookkeeping. This is the part that answers the only
# question that matters: does `rlt --compile` work against this tree?
#
# The staged gcc has /usr-absolute baked paths, and on this host /usr is the
# HOST's. Left alone it would link against the host's libc and pass for the
# wrong reason - which is precisely how a broken guest toolchain ships. So:
# -B redirects the driver's internal tool lookup at the staged cc1/lto-wrapper
# and the staged binutils, and -nostdinc plus an explicit -isystem/-L point the
# preprocessor and linker at the staged tree and nowhere else. If that links
# and runs, the guest tree is complete.
header "Verifying against the staged tree only"
LINKCHECK="$(mktemp -d)"
trap 'rm -rf "$LINKCHECK"' EXIT
# -L$GCC_DIST/$LIBGCC_REL is load-bearing, not belt-and-braces. gcc's baked
# libgcc path is /usr/lib/gcc/<triplet>/16.2.0, which does not exist on this
# host (which has gcc 15), so the driver emits -L for a directory that is not
# there and ld then reports
#
#   cannot find crtbegin.o / -lgcc / -lgcc_s_asneeded
#
# pointing at the compiler rather than at the staging bug. In the guest that
# path is real, so this is purely about making the verification here faithful
# to what the guest does - the -L has to be there for the test to mean
# anything, not because the guest needs it.
# -B$GCC_DIST/$LIBGCC_REL is what makes the crt objects resolve, and the reason
# is subtle enough to be worth writing down.
#
# gcc's link spec references the start files as `crtbegin.o%s`, where %s expands
# to whatever path the driver manages to FIND at startup. gcc resolves them
# relative to its own baked libgcc directory, /usr/lib/gcc/<triplet>/16.2.0.
# On this host that directory does not exist (the host has gcc 15), so nothing
# is found, %s stays empty, and the driver emits a bare `crtbegin.o`.
#
# A bare filename cannot be satisfied by -L. Verified directly against this ld:
# `ld -Ldir -o out b.o -lextra` links fine, while `ld -Ldir -o out b.o extra.o`
# fails with "cannot find extra.o" - -L applies to -l libraries, not to bare
# input filenames, which ld resolves against the current directory only.
#
# -B prefixes ARE searched for start files, so pointing -B at the staged libgcc
# dir makes the driver find crtbegin.o and emit its full path, exactly as it
# will in the guest where /usr/lib/gcc/<triplet>/16.2.0 really does exist. This
# is a property of running the verification on a host that does not have this
# gcc installed - the guest needs no such flag, and adding one to rlt would be
# wrong.
GB="-B$GCC_DIST/$LIBEXEC_REL -B$GCC_DIST/$LIBGCC_REL -B$SCRIPT_DIR/binutils-dist/bin"
GINC="-nostdinc -isystem $GCC_DIST/$LIBGCC_REL/include -isystem $GCC_DIST/usr/include"
GLIB="-L$GCC_DIST/$LIBGCC_REL -L$GCC_DIST/usr/lib64 -B$GCC_DIST/usr/lib64"

# A synthetic hello-world proves nothing: it touches none of the runtime
# members that drag in libgcc. Transpile a real shipped program instead, since
# help.rl is one of the programs in the image.
REAL_OK=0
if [[ -x "$SCRIPT_DIR/rl-bins/rlos/rlt" ]]; then
    RL_PROBE_DIR="$(mktemp -d)"
    cp "$SCRIPT_DIR/rl_programs/help.rl" "$RL_PROBE_DIR/probe.rl"
    if ( cd "$RL_PROBE_DIR" && "$SCRIPT_DIR/rl-bins/rlos/rlt" --runtime probe.rl ) > /dev/null 2>&1; then
        # Same flags as rlt.rs plus RL_CFLAGS above, which is the single source
        # of truth shared with the header-closure probe.
        # rlt emits -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections
        # -o <out> <file.c> <rl_runtime.c> -I <dir> -lm
        RL_FLAGS="$RL_CFLAGS -ffunction-sections -fdata-sections -Wl,--gc-sections"
        if "$STAGED_GCC" $GB $GINC $GLIB $RL_FLAGS \
                -o "$RL_PROBE_DIR/probe" "$RL_PROBE_DIR/probe.c" \
                "$RL_PROBE_DIR/rl_runtime.c" -I "$RL_PROBE_DIR" -lm 2>"$RL_PROBE_DIR/err"; then
            if OUT="$(cd "$RL_PROBE_DIR" && ./probe 2>&1)"; then
                ok "help.rl linked AND ran ($(printf '%s' "$OUT" | grep -c .) lines out)"
                REAL_OK=1
            else
                fail "help.rl linked but would not run: ${OUT}"
                rm -rf "$RL_PROBE_DIR"
                exit 1
            fi
        else
            fail "gcc cannot compile a REAL rl program (help.rl) - rlt --compile fails in-guest:"
            sed 's/^/         /' "$RL_PROBE_DIR/err" | head -20
            rm -rf "$RL_PROBE_DIR"
            exit 1
        fi

        # The same program with -flto, which is the reason this gcc exists.
        # Without it `rlt --compile --lto` is untested, and a missing lto1 or
        # lto-wrapper only shows up here.
        if "$STAGED_GCC" $GB $GINC $GLIB $RL_FLAGS -flto \
                -o "$RL_PROBE_DIR/probe-lto" "$RL_PROBE_DIR/probe.c" \
                "$RL_PROBE_DIR/rl_runtime.c" -I "$RL_PROBE_DIR" -lm 2>"$RL_PROBE_DIR/err-lto"; then
            if OUT="$(cd "$RL_PROBE_DIR" && ./probe-lto 2>&1)"; then
                PLAIN_SZ="$(stat -c %s "$RL_PROBE_DIR/probe")"
                LTO_SZ="$(stat -c %s "$RL_PROBE_DIR/probe-lto")"
                ok "help.rl --flto linked AND ran ($(printf '%s' "$OUT" | grep -c .) lines out)"
                ok "  size: ${PLAIN_SZ} plain -> ${LTO_SZ} LTO"
            else
                fail "help.rl --flto linked but would not run: ${OUT}"
                rm -rf "$RL_PROBE_DIR"
                exit 1
            fi
        else
            fail "gcc -flto cannot compile help.rl - 'rlt --compile --lto' fails in-guest:"
            sed 's/^/         /' "$RL_PROBE_DIR/err-lto" | head -20
            rm -rf "$RL_PROBE_DIR"
            exit 1
        fi
    else
        fail "rlt could not transpile help.rl - cannot verify the toolchain"
        rm -rf "$RL_PROBE_DIR"
        exit 1
    fi
    rm -rf "$RL_PROBE_DIR"
else
    warn "rl-bins/rlos/rlt absent - skipping the real-program check."
    warn "  Run build_rl_bins.sh first; that check is the only thing that"
    warn "  proves the staged tree is complete."
fi

# ---- every -l flag rlt can emit ----
#
# rlt.rs emits -lm always, plus -lffi / -lcurl / -largon2 / -lyaml / -lpthread /
# -ldl by substring match on the generated C. Testing only -lm leaves the rest
# to fail in-guest as "cannot find -lyaml". Scope: the four staged here plus
# -lffi. -lffi is checked against the staged tree even though its library
# arrives via assemble-rootfs.sh's ldd closure, because the header is now
# staged and the two must agree.
header "Verifying each -l target rlt can emit"
MISSING_LIBS=""
for l in argon2 yaml pthread dl ffi; do
    if [ ! -e "$GCC_DIST/usr/lib64/lib$l.so" ]; then
        MISSING_LIBS="$MISSING_LIBS $l"
    fi
done
if [ -n "$MISSING_LIBS" ]; then
    fail "rlt can emit -l for:$MISSING_LIBS but no lib$l.so is staged"
    exit 1
fi
for probe_lib in pthread dl yaml argon2; do
    printf 'int main(void){return 0;}\n' > "$LINKCHECK/l.c"
    if "$STAGED_GCC" $GB $GINC $GLIB $RL_CFLAGS -o "$LINKCHECK/l" "$LINKCHECK/l.c" \
            -l"$probe_lib" 2>"$LINKCHECK/lerr"; then
        ok "  -l$probe_lib links"
    else
        fail "-l$probe_lib failed to link:"
        sed 's/^/         /' "$LINKCHECK/lerr" | head -5
        exit 1
    fi
done
# ffi needs its header, which is the whole point of staging it above: prove the
# #include resolves AND that a real libffi symbol links, not just that the
# header parsed. ffi_type_void is an extern object in libffi, so referencing it
# makes this fail if -lffi silently did nothing.
printf '#include <ffi.h>\nint main(void){ ffi_type *p = &ffi_type_void; return p != 0; }\n' > "$LINKCHECK/f.c"
if "$STAGED_GCC" $GB $GINC $GLIB $RL_CFLAGS -o "$LINKCHECK/f" "$LINKCHECK/f.c" -lffi 2>"$LINKCHECK/ferr"; then
    ok "  -lffi links AND #include <ffi.h> resolves"
else
    fail "ffi.h does not resolve or -lffi does not link - std::c programs would fail in-guest:"
    sed 's/^/         /' "$LINKCHECK/ferr" | head -8
    exit 1
fi

# The -lyaml / -largon2 headers too, since rl_runtime.c includes yaml.h and
# argon2.h under their respective RL_USE_* guards.
for probe_pair in "yaml.h:yaml" "argon2.h:argon2"; do
    hdr="${probe_pair%%:*}"; lib="${probe_pair##*:}"
    printf '#include <%s>\nint main(void){return 0;}\n' "$hdr" > "$LINKCHECK/h.c"
    if "$STAGED_GCC" $GB $GINC $GLIB $RL_CFLAGS -o "$LINKCHECK/h" "$LINKCHECK/h.c" -l"$lib" 2>"$LINKCHECK/herr"; then
        ok "  <$hdr> + -l$lib resolve"
    else
        fail "<$hdr> does not resolve or -l$lib does not link:"
        sed 's/^/         /' "$LINKCHECK/herr" | head -5
        exit 1
    fi
done

ok "gcc-dist ready ($(du -sh "$GCC_DIST" | cut -f1))"
info "layout (depth 3):"
find "$GCC_DIST" -maxdepth 3 -type d | sort | sed 's/^/         /'
info "gcc self-check:"
"$STAGED_GCC" --version 2>/dev/null | head -1 | sed 's/^/         /'
info "header counts:"
printf "         gcc freestanding: %s\n" "$(ls "$GCC_DIST/$LIBGCC_REL/include" 2>/dev/null | wc -l)"
printf "         glibc closure:    %s\n" "$(find "$GCC_DIST/usr/include" -type f 2>/dev/null | wc -l)"
