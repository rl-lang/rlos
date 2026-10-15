#!/usr/bin/env bash
# build_wl.sh - build the Wayland backend into wayland-dist/.
#
# THE THIRD BACKEND
#
# rlOS has three: text (default), -x (X11/i3), and this one (-w, sway). The text
# console stays the default on purpose; -w is opt-in like -x.
#
# WHY A SEPARATE SCRIPT, AND WHY NOT PART OF build_x11.sh
#
# X11 and Wayland are different stacks that happen to share a desktop idea.
# build_x11.sh grew Xorg, its DDX, i3, mlterm, libinput, eudev, ffmpeg and an
# SDL2 stack. None of that is what sway needs, and coupling them is exactly the
# mistake that put sudo and ttyrec behind the -x flag until they were moved out
# into base-dist.
#
# The overlap is small and deliberate: xapps-dist (feh, xfiles, xmenu) is already
# staged for ANY non-text backend because under -w those run through XWayland.
# That staging lives in assemble-rootfs.sh, not here.
#
# BUILD ORDER IS THE DEPENDENCY ORDER
#
#   libffi      <- wayland (closures need it)
#   wayland     <- everything: libwayland-client, libwayland-server,
#                  libwayland-cursor, and the EGL extension interface
#   libdrm      <- mesa, wlroots (mode setting, dumb buffers, gbm)
#   pixman      <- wlroots' software renderer
#   mesa        <- GLES2 renderer: libEGL, libgbm, and a software GL driver
#   libinput    <- wlroots (the analogue of build_x11.sh's; see below)
#   xkbcommon   <- wlroots
#   libseat     <- wlroots
#   wlroots     <- sway
#   sway        <- swaybar, swaybg
#
# libinput and eudev are the one real wrinkle. build_x11.sh already builds
# libinput and eudev into x11-dist, so an -x -w combination could reuse them -
# but a text-only or -w-only image has no x11-dist at all, so depending on it
# would put a desktop flag back in the path. They are therefore built here too.
# That is duplication on the -x -w path and it is the lesser evil; sharing one
# build across two dists is a bigger refactor than this script should attempt
# before the backend works at all.
#
# Output:
#   wayland-dist/usr/bin/{sway,swaybar,swaybg}
#   wayland-dist/usr/lib64/                 + the ldd closure of all of the above
#   wayland-dist/usr/lib/x86_64-linux-gnu/  (same, for anything that lands there)
#   wayland-dist/usr/share/wayland-sessions/
#
# Usage:
#   ./build_wl.sh            # build (default)
#   ./build_wl.sh -j 8       # 8 parallel jobs
#   ./build_wl.sh --stage N  # stop after stage N (1=foundation, 2=wlroots, ...)
#   ./build_wl.sh --clean    # remove wl-src/ wl-prefix/ wayland-dist/
#
# Needs on the host: gcc, make, cmake, ninja, meson, python3, git, curl,
# pkg-config, wayland-scanner is NOT needed - it is built here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WL_SRC="$SCRIPT_DIR/wl-src"
WL_PREFIX="$SCRIPT_DIR/wl-prefix"
WL_DIST="$SCRIPT_DIR/wayland-dist"
CLEAN=0
STAGE=99
JOBS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j) JOBS="$2"; shift 2 ;;
        --stage) STAGE="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument '$1'" >&2; exit 1 ;;
    esac
done

header() { printf "\n:: %s\n" "$*"; }
step()   { printf "  >>> %s\n" "$*"; }
substep(){ printf "  --->>> %s\n" "$*"; }
ok()     { printf "  [ OK ] %s\n" "$*"; }
# skip: a component deliberately not built, with the reason inline. Distinct from
# warn() on purpose - a skip is a decision recorded in the build, and it should
# not look like a problem the user has to notice in a log.
skip()   { printf "  [SKIP] %s\n" "$*"; }
info()   { printf "  :: %s\n" "$*"; }
fail()   { printf "  [FAIL] %s\n" "$*" >&2; exit 1; }

NPROC="$(nproc 2>/dev/null || echo 4)"
[[ -n "$JOBS" ]] || JOBS="$NPROC"
JOBS_FLAG="-j $JOBS"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_DIM=""; C_RST=""
fi

if [[ "$CLEAN" == "1" ]]; then
    echo "removing wl-src/ wl-prefix/ wayland-dist/"
    rm -rf "$WL_SRC" "$WL_PREFIX" "$WL_DIST"
    exit 0
fi

# ---------------------------------------------------------------------------
# Versions. All pinned in pins.lock; these are only the names the tarballs
# unpack under and the URLs they come from.
# ---------------------------------------------------------------------------
LIBFFI_VER="3.4.7"
LIBFFI_URL="https://github.com/libffi/libffi/releases/download/v${LIBFFI_VER}/libffi-${LIBFFI_VER}.tar.gz"

WAYLAND_VER="1.26.0"
WAYLAND_URL="https://gitlab.freedesktop.org/wayland/wayland/-/releases/${WAYLAND_VER}/downloads/wayland-${WAYLAND_VER}.tar.xz"

LIBDRM_VER="2.4.133"
LIBDRM_URL="https://dri.freedesktop.org/libdrm/libdrm-${LIBDRM_VER}.tar.xz"

PIBMAN_VER="0.46.4"
PIBMAN_URL="https://gitlab.freedesktop.org/pixman/pixman/-/archive/pixman-${PIBMAN_VER}/pixman-pixman-${PIBMAN_VER}.tar.gz"

# ---------------------------------------------------------------------------
# Fetch and unpack helpers.
# ---------------------------------------------------------------------------
# pins_fetch <url> <dest> <key> - download unless present, then verify sha256.
# Verification is not optional: a silently wrong tarball produces an image that
# boots and misbehaves three weeks later, which is far worse than a failed build.
pins_fetch() {
    local url="$1" dest="$2" key="$3" want got
    if [ -f "$dest" ]; then
        info "have $(basename "$dest")"
    else
        info "fetching $(basename "$dest")"
        curl -fL --retry 3 --retry-delay 2 --max-time 300 -o "$dest" "$url" \
            || fail "download failed: $url"
    fi
    # `curl -f` only rejects 4xx and 5xx. A host that answers a bad archive path
    # with 200 and an HTML error or sign-in page sails straight through, and the
    # result is an "archive" that unpacks to nothing. Checking that the download
    # is actually an archive is what caught that here.
    case "$(file -b "$dest")" in
        *HTML*|*JSON*|*ASCII*|*text*)
            fail "$(basename "$dest") is not an archive - it downloaded as $(file -b "$dest" | cut -c1-30)"
            fail "  the URL probably needs authentication, or the version does not exist there"
            exit 1
            ;;
    esac
    want="$(source "$SCRIPT_DIR/pins.sh"; pins_get "$key.sha256")"
    [ -n "$want" ] || fail "no sha256 for '$key' in pins.lock - record it before building"
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        fail "sha256 mismatch for $key"
        fail "  expected $want"
        fail "  got      $got"
        exit 1
    fi
    ok "$(basename "$dest") sha256 verified"
}

# unpack <tarball> <dest-dir> - extract with the top directory stripped into a
# named directory. NEVER `tar --strip-components=1 -C "$WL_SRC"`: that drops the
# top directory and then flattens the tree across every other component's build
# directory in there. That mistake is made once and then remembered.
unpack() {
    local tarball="$1" dir="$2"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xf "$tarball" -C "$dir" --strip-components=1 || fail "unpack failed: $(basename "$tarball")"
}

# prefix_lib <name> - print the path of an installed file inside the prefix's
# library directories, or nothing.
#
# Why this exists rather than a hardcoded "$WL_PREFIX/lib": the two halves of
# this chain disagree about where libraries go. Autotools projects (libffi here)
# honour the host's convention and install into lib64 on Gentoo; meson projects
# (wayland, libdrm, pixman) install into lib or lib/x86_64-linux-gnu. Hardcoding
# one of them produces a build that installs successfully and then fails its
# own verification, with an error that blames the wrong thing entirely.
prefix_lib() {
    local n="$1" d
    for d in lib lib64 lib/x86_64-linux-gnu; do
        [ -e "$WL_PREFIX/$d/$n" ] && { printf '%s' "$WL_PREFIX/$d/$n"; return 0; }
    done
    return 1
}

# need <name> <what> - assert an installed artifact exists, in whichever libdir.
need() {
    local n="$1" what="$2" p
    p="$(prefix_lib "$n")" \
        || fail "$what: $WL_PREFIX/{lib,lib64}/$n not found"
    substep "$what -> ${p#$WL_PREFIX/}"
}

# need_bin - same assertion for executables. Kept separate rather than teaching
# need() to search bin/ too: need() is used 14 times for shared objects, and
# letting it silently succeed on a name that happens to exist in bin/ would
# make a missing library look like it was found.
need_bin() {
    local n="$1" what="$2"
    [ -x "$WL_PREFIX/bin/$n" ] \
        || fail "$what: $WL_PREFIX/bin/$n not found or not executable"
    substep "$what -> bin/$n"
}

header "Host prerequisites"
MISSING=""
for tool in gcc make cmake ninja meson python3 git curl pkg-config; do
    command -v "$tool" > /dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
    fail "missing host tools:$MISSING"
    fail "on Gentoo: emerge dev-build/{cmake,meson,ninja,pkgconfig} dev-vcs/git net-misc/curl"
    exit 1
fi
ok "gcc make cmake ninja meson python3 git curl pkg-config present"

rm -rf "$WL_DIST"
# bin/ (not usr/bin/) is where the executables land: build_x11.sh puts Xorg and
# i3 in x11-dist/bin/ and init.c invokes /bin/sway, so the Wayland dist follows
# the same convention. usr/lib64 is the flattened closure, matching x11-dist.
mkdir -p "$WL_SRC" "$WL_PREFIX" "$WL_DIST/bin" "$WL_DIST/usr/lib64" \
         "$WL_DIST/usr/share" "$WL_DIST/etc"

export PKG_CONFIG_PATH="$WL_PREFIX/lib/pkgconfig:$WL_PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_SYSROOT_DIR=""

# LD_LIBRARY_PATH is deliberately NOT exported here.
#
# Linking does not need it: meson and autotools derive -L$prefix/lib from
# --prefix on their own, and the closure is resolved later against an explicit
# path (WL_RUNTIME_LD_PATH).
#
# Exporting it does real damage. Build tools are host binaries, and the prefix
# holds libraries that deliberately differ from the host's. The host python3
# imports xml.parsers.expat for glib's gdbus-codegen; with the prefix on
# LD_LIBRARY_PATH it binds OUR libexpat 2.6.3 instead of the host's 2.7.x and
# dies on
#   undefined symbol: XML_SetAllocTrackerActivationThreshold
# which glib reports as two FAILED: steps with no mention of expat at all.
# Build-time needs headers and archives, not a runtime search path.
WL_RUNTIME_LD_PATH="$WL_PREFIX/lib:$WL_PREFIX/lib64"

# CFLAGS/CXXFLAGS/LDFLAGS are deliberately NOT exported here.
#
# meson and autotools both add -I$prefix/include and -L$prefix/lib themselves
# from --prefix, so exporting them bought nothing - and it actively broke the
# build. A Gentoo gcc spec defines _FORTIFY_SOURCE by default, meson defines it
# again from its own hardening options, and libseat compiles with -Werror, so the
# second definition is a hard error:
#
#   <command-line>: error: '_FORTIFY_SOURCE' redefined [-Werror]
#   <built-in>: note: this is the location of the previous definition
#
# PKG_CONFIG_PATH is still needed: that one has no equivalent, and without it
# meson finds the HOST's wayland and xkbcommon instead of the pinned ones.

# ===========================================================================
# STAGE 1 - foundation
# ===========================================================================
if [[ "$STAGE" -ge 1 ]]; then

header "libffi ${LIBFFI_VER}"
LIBFFI_TARBALL="$WL_SRC/libffi-${LIBFFI_VER}.tar.gz"
pins_fetch "$LIBFFI_URL" "$LIBFFI_TARBALL" "libffi"
unpack "$LIBFFI_TARBALL" "$WL_SRC/libffi-${LIBFFI_VER}"
step "configure + make"
# --disable-docs keeps the doc toolchain (docbook, xmlto) off the host
# requirement list; nothing in this dist ships documentation.
( cd "$WL_SRC/libffi-${LIBFFI_VER}" && \
  ./configure --prefix="$WL_PREFIX" --disable-docs --enable-shared \
    > "$SCRIPT_DIR/.wl-libffi.log" 2>&1 && \
  make $JOBS_FLAG >> "$SCRIPT_DIR/.wl-libffi.log" 2>&1 && \
  make install >> "$SCRIPT_DIR/.wl-libffi.log" 2>&1 ) \
  || { fail "libffi build failed"; tail -25 "$SCRIPT_DIR/.wl-libffi.log" | sed 's/^/         /'; exit 1; }
need libffi.so "libffi"
ok "libffi built ($(du -sh "$WL_PREFIX/lib" | cut -f1))"

header "wayland ${WAYLAND_VER} (libwayland + wayland-scanner)"
WAYLAND_TARBALL="$WL_SRC/wayland-${WAYLAND_VER}.tar.xz"
pins_fetch "$WAYLAND_URL" "$WAYLAND_TARBALL" "wayland"
unpack "$WAYLAND_TARBALL" "$WL_SRC/wayland-${WAYLAND_VER}"
step "meson + ninja"
# wayland-scanner is built and installed here rather than taken from the host,
# because the protocol XML that sway and wlroots compile against is interpreted
# by it: a host scanner and a pinned libwayland disagreeing is a class of bug
# that shows up as mystery structs in generated code.
( cd "$WL_SRC/wayland-${WAYLAND_VER}" && \
  # Only these four exist in wayland 1.26: libraries, scanner, tests,
  # documentation. Passing an option meson does not know is a hard ERROR, not a
  # warning, so an option list has to match the version being built.
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      -Ddocumentation=false -Dtests=false \
      > "$SCRIPT_DIR/.wl-wayland.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-wayland.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-wayland.log" 2>&1 ) \
  || { fail "wayland build failed"; tail -25 "$SCRIPT_DIR/.wl-wayland.log" | sed 's/^/         /'; exit 1; }
for so in libwayland-client.so libwayland-server.so libwayland-cursor.so libwayland-egl.so; do
    need "$so" "wayland"
done
[ -x "$WL_PREFIX/bin/wayland-scanner" ] || fail "wayland-scanner not installed"
ok "wayland built (client, server, cursor, egl + wayland-scanner)"

header "libdrm ${LIBDRM_VER}"
LIBDRM_TARBALL="$WL_SRC/libdrm-${LIBDRM_VER}.tar.gz"
pins_fetch "$LIBDRM_URL" "$LIBDRM_TARBALL" "libdrm"
unpack "$LIBDRM_TARBALL" "$WL_SRC/libdrm-${LIBDRM_VER}"
step "meson + ninja"
( cd "$WL_SRC/libdrm-${LIBDRM_VER}" && \
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      -Dtests=false -Dinstall-test-programs=false \
      > "$SCRIPT_DIR/.wl-libdrm.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-libdrm.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-libdrm.log" 2>&1 ) \
  || { fail "libdrm build failed"; tail -25 "$SCRIPT_DIR/.wl-libdrm.log" | sed 's/^/         /'; exit 1; }
need libdrm.so "libdrm"
ok "libdrm built (mode setting, dumb buffers, gbm)"

header "pixman ${PIBMAN_VER} (the software renderer)"
PIBMAN_TARBALL="$WL_SRC/pixman-${PIBMAN_VER}.tar.gz"
pins_fetch "$PIBMAN_URL" "$PIBMAN_TARBALL" "pixman"
unpack "$PIBMAN_TARBALL" "$WL_SRC/pixman-${PIBMAN_VER}"
step "meson + ninja"
# OpenVG and GTK tests off: nothing in this image uses either.
( cd "$WL_SRC/pixman-${PIBMAN_VER}" && \
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      -Dtests=disabled -Dgtk=disabled -Ddemos=disabled -Dopenmp=disabled \
      > "$SCRIPT_DIR/.wl-pixman.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-pixman.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-pixman.log" 2>&1 ) \
  || { fail "pixman build failed"; tail -25 "$SCRIPT_DIR/.wl-pixman.log" | sed 's/^/         /'; exit 1; }
need libpixman-1.so "pixman"
ok "pixman built (wlroots' pixman renderer needs this)"

fi

# ===========================================================================
# STAGE 2 - the compositor stack, pixman only.
#
# No Mesa here, on purpose. wlroots' renderers option offers only gles2 and
# vulkan, and its gbm allocator needs Mesa's gbm - so a Mesa-free build means
# renderers=[] and allocators=[udmabuf], leaving wlroots' pixman renderer.
#
# That renderer is still in the tree at render/pixman/, built unconditionally
# whenever pixman-1 >= 0.46 is present, which is stage 1. It is absent from the
# renderers CHOICES list only because it is not optional - there is no way to
# turn it off, which is why it does not appear there.
#
# So the first thing this produces is a compositor that actually runs and can be
# booted and screenshotted, with Mesa deferred to stage 3. Getting sway onto a
# screen is the thing most likely to surface init.c and input problems; a
# software GL driver is not.
# ===========================================================================
if [[ "$STAGE" -ge 2 ]]; then

# git_clone <url> <tag-or-commit> <dir>
#
# Git components are pinned BY COMMIT in pins.lock's [git] section, which is
# the mechanism that already covers xfiles, libXft and Imlib2. A commit hash is
# a pin; a branch name is not.
git_clone() {
    local url="$1" ref="$2" dir="$3"
    if [ -d "$dir/.git" ]; then
        info "have $(basename "$dir")"
        return 0
    fi
    info "cloning $(basename "$dir") at $ref"
    GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$ref" "$url" "$dir" \
        || GIT_TERMINAL_PROMPT=0 git clone --quiet "$url" "$dir" \
        || fail "clone failed: $url"
}

header "eudev 3.2.15 (udev implementation - libinput needs one)"
EUDEV_TARBALL="$WL_SRC/eudev-3.2.15.tar.gz"
pins_fetch "https://codeload.github.com/eudev-project/eudev/tar.gz/refs/tags/v3.2.15" \
           "$EUDEV_TARBALL" "eudev"
unpack "$EUDEV_TARBALL" "$WL_SRC/eudev-3.2.15"
step "autogen + configure + make"
# AUTOTOOLS, not meson - the tarball ships no meson.build at all, and the
# meson invocation fails with the misleading "neither source directory 'build'
# nor build directory None contain a build file meson.build". Same build
# sequence build_x11.sh already proves works, including --libdir=/usr/lib64,
# which is what puts the rules where this tree's udevd will look for them.
#
# ./autogen.sh runs autoreconf only - it does NOT invoke configure, so configure
# is a separate step. That is a two-step that looks like one and is not.
( cd "$WL_SRC/eudev-3.2.15" && \
  ./autogen.sh > "$SCRIPT_DIR/.wl-eudev.log" 2>&1 && \
  ./configure --prefix="$WL_PREFIX" --libdir="$WL_PREFIX/lib64" --disable-manpages \
      >> "$SCRIPT_DIR/.wl-eudev.log" 2>&1 && \
  make $JOBS_FLAG >> "$SCRIPT_DIR/.wl-eudev.log" 2>&1 && \
  make install >> "$SCRIPT_DIR/.wl-eudev.log" 2>&1 ) \
  || { fail "eudev build failed"; tail -25 "$SCRIPT_DIR/.wl-eudev.log" | sed 's/^/         /'; exit 1; }
need libudev.so.1 "eudev"
# The daemon is the part that matters: libinput attaches devices by watching the
# udev database, so a library without a running daemon is useless at runtime.
# Located by search rather than by path: --libdir moves the LIBRARY to
# lib64/udev/, but the daemon's location comes from configure's sbindir and is
# still sbin/. Hardcoding either one is how this check ends up reporting a
# successful build as a missing binary.
UDEVD_BIN="$(find "$WL_PREFIX" -name 'udevd' -type f 2>/dev/null | head -1)"
[ -n "$UDEVD_BIN" ] || fail "eudev's udevd binary not built - libinput will attach no devices"
ok "eudev built (library + udevd at ${UDEVD_BIN#"$WL_PREFIX"/})"

header "zlib, bzip2, expat, libpng (transitive runtime deps)"
# None of these are needed to COMPILE anything here - they turn up only when you
# follow the DT_NEEDED entries at runtime. Left unbuilt, pango/cairowfontconfig
# silently bind to whatever the build host happens to have, which is precisely
# the unpinned dependency pins.lock exists to prevent. Small, so the size cost of
# carrying them is far less than the cost of an image that only runs on one
# machine.

# zlib: cairo's PNG and font paths, and libpng's codec backend.
pins_fetch "https://zlib.net/fossils/zlib-1.3.1.tar.gz" "$WL_SRC/zlib-1.3.1.tar.gz" "zlib"
unpack "$WL_SRC/zlib-1.3.1.tar.gz" "$WL_SRC/zlib-1.3.1"
step "configure + make (zlib has no meson)"
# -Dshared so the runtime finds libz.so.1; zlib defaults to static on Linux.
( cd "$WL_SRC/zlib-1.3.1" && \
  ./configure --prefix="$WL_PREFIX" --shared > "$SCRIPT_DIR/.wl-zlib.log" 2>&1 && \
  make -j"$(nproc)" >> "$SCRIPT_DIR/.wl-zlib.log" 2>&1 && \
  make install >> "$SCRIPT_DIR/.wl-zlib.log" 2>&1 ) \
  || { fail "zlib build failed"; tail -20 "$SCRIPT_DIR/.wl-zlib.log" | sed 's/^/         /'; exit 1; }
need libz.so "zlib"
ok "zlib built"

# bzip2: fontconfig reaches it for compressed font files.
pins_fetch "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz" "$WL_SRC/bzip2-1.0.8.tar.gz" "bzip2"
unpack "$WL_SRC/bzip2-1.0.8.tar.gz" "$WL_SRC/bzip2-1.0.8"
step "make (autotools)"
# -fPIC because these land in a shared library's closure, not just the main binary.
# Makefile-libbz2_so has no install target - it only knows how to build and link
# the shared object. Install by hand: the real file first, then the two SONAME
# names pointing at it. cpio cannot follow symlinks, so the closure walk copies
# the resolved file and recreates the links itself later.
( cd "$WL_SRC/bzip2-1.0.8" && \
  make -f Makefile-libbz2_so CFLAGS="-fPIC -O2 -D_FILE_OFFSET_BITS=64" \
      >> "$SCRIPT_DIR/.wl-bzip2.log" 2>&1 ) \
  || { fail "bzip2 build failed"; tail -20 "$SCRIPT_DIR/.wl-bzip2.log" | sed 's/^/         /'; exit 1; }
for d in "$WL_PREFIX/lib" "$WL_PREFIX/lib64"; do
    [ -d "$d" ] || continue
    cp -f "$WL_SRC/bzip2-1.0.8/libbz2.so.1.0.8" "$d/" \
      || fail "bzip2: cannot install into $d"
    ln -sf libbz2.so.1.0.8 "$d/libbz2.so.1.0"
    ln -sf libbz2.so.1.0   "$d/libbz2.so.1"
done
ok "bzip2 built"

# expat: fontconfig's XML parser. Without it fontconfig links host expat.
[ -d "$WL_SRC/expat" ] || git_clone "https://github.com/libexpat/libexpat" "R_2_6_3" "$WL_SRC/expat"
step "cmake + make"
# The R_2_6_3 tag nests the actual project one level down, inside expat/. The
# top of the checkout has only packaging metadata - no CMakeLists.txt - so
# pointing cmake at $WL_SRC/expat fails with "does not appear to contain
# CMakeLists.txt". Build the real source directory, not the repository root.
( cd "$WL_SRC/expat/expat" && \
  cmake -B build -DCMAKE_INSTALL_PREFIX="$WL_PREFIX" -DEXPAT_BUILD_TOOLS=OFF \
        -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release > "$SCRIPT_DIR/.wl-expat.log" 2>&1 && \
  cmake --build build -j"$(nproc)" >> "$SCRIPT_DIR/.wl-expat.log" 2>&1 && \
  cmake --install build >> "$SCRIPT_DIR/.wl-expat.log" 2>&1 ) \
  || { fail "expat build failed"; tail -20 "$SCRIPT_DIR/.wl-expat.log" | sed 's/^/         /'; exit 1; }
need libexpat.so "expat"
ok "expat built"

# libpng: cairo's image surface backend.
[ -d "$WL_SRC/libpng" ] || git_clone "https://github.com/pnggroup/libpng" "v1.6.45" "$WL_SRC/libpng"
step "cmake + make"
( cd "$WL_SRC/libpng" && \
  cmake -B build -DCMAKE_INSTALL_PREFIX="$WL_PREFIX" \
        -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
        -DCMAKE_BUILD_TYPE=Release > "$SCRIPT_DIR/.wl-libpng.log" 2>&1 && \
  cmake --build build -j"$(nproc)" >> "$SCRIPT_DIR/.wl-libpng.log" 2>&1 && \
  cmake --install build >> "$SCRIPT_DIR/.wl-libpng.log" 2>&1 ) \
  || { fail "libpng build failed"; tail -20 "$SCRIPT_DIR/.wl-libpng.log" | sed 's/^/         /'; exit 1; }
need libpng16.so "libpng"
ok "libpng built"

header "xkbcommon (keyboard/keymap compiler - wlroots and libinput need it)"
# Built from the tree in wl-src/, pinned by the commit the script asserts below.
# xkbcommon's git lives on GitHub, which some hosts reach only over ssh; the
# checkout is expected to be present rather than fetched.
[ -d "$WL_SRC/libxkbcommon" ] || fail "$WL_SRC/libxkbcommon is missing - xkbcommon must be checked out there"
XKBCOMMON_EXPECT="e6b9c1d784cf5485b3bd9647e2da8ad828b0e135"
XKBCOMMON_GOT="$(cd "$WL_SRC/libxkbcommon" && git rev-parse HEAD)"
if [ "$XKBCOMMON_GOT" != "$XKBCOMMON_EXPECT" ]; then
    warn "xkbcommon is at $XKBCOMMON_GOT, expected $XKBCOMMON_EXPECT"
    fail "that is the commit pins.lock records for xkbcommon"
fi
step "meson + ninja"
# The option list, and two of these are load-bearing rather than tidy:
#
#   -Denable-wayland=true   REQUIRED. This is the option that compiles the
#                           Wayland keymap support wlroots calls into. Passing
#                           anything else here looks fine and produces a
#                           libxkbcommon that wlroots links and then cannot
#                           get a keymap out of.
#   -Denable-x11=false       the old option name was enable-xkcbrec; it was
#                           renamed, and meson treats an unknown option as a
#                           hard ERROR rather than ignoring it. Dropped anyway:
#                           it is the only thing here that would want libX11,
#                           and there is no X in this build.
#   -Denable-xkbregistry=false  the registry daemon talks to an X server.
#   -Denable-tools=false     xkbcli; nothing here calls it.
( cd "$WL_SRC/libxkbcommon" && \
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      -Denable-wayland=true -Denable-x11=false \
      -Denable-xkbregistry=false -Denable-tools=false -Denable-docs=false \
      -Denable-bash-completion=false -Denable-zsh-completion=false \
      > "$SCRIPT_DIR/.wl-xkbcommon.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-xkbcommon.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-xkbcommon.log" 2>&1 ) \
  || { fail "xkbcommon build failed"; tail -25 "$SCRIPT_DIR/.wl-xkbcommon.log" | sed 's/^/         /'; exit 1; }
need libxkbcommon.so.0 "xkbcommon"
ok "xkbcommon built (commit ${XKBCOMMON_GOT:0:12})"

# 1.31.3, not 1.32.0. libinput 1.32 added LIBINPUT_CONFIG_SCROLL_CIRCULAR to
# its scroll-method enum; sway 1.12's ipc-json.c switches over that enum without
# a case for the new value, so it fails to build under -Werror=switch. The fix
# landed on sway master but not in the 1.12 tag, so the pairing is what it is:
# newest libinput sway 1.12 can compile against. wlroots 0.20.2 only asks for
# >= 1.19.0, so it does not care.
LIBINPUT_TAG="1.31.3"
header "libinput ${LIBINPUT_TAG} (input event handling)"
[ -d "$WL_SRC/libinput" ] || git_clone "https://gitlab.freedesktop.org/libinput/libinput" "$LIBINPUT_TAG" "$WL_SRC/libinput"
step "meson + ninja"
( cd "$WL_SRC/libinput" && \
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      -Dtests=false -Ddocumentation=false -Dlibwacom=false \
      -Ddebug-gui=false -Dmtdev=false -Dcoverity=false \
      > "$SCRIPT_DIR/.wl-libinput.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-libinput.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-libinput.log" 2>&1 ) \
  || { fail "libinput build failed"; tail -25 "$SCRIPT_DIR/.wl-libinput.log" | sed 's/^/         /'; exit 1; }
# -Ddebug-gui=false is load-bearing: without it libinput builds
# libinput-debug-gui and links it against the HOST's GTK-4, which fails on a
# version-skewed glib. This image has no GTK and does not want one - the debug GUI
# is a developer tool that needs a running X server, neither of which exists here.
need libinput.so.10 "libinput"
ok "libinput built"

header "wayland-protocols (protocol XML - wlroots and sway generate code from these)"
WPROTO_VER="1.49"
WPROTO_TARBALL="$WL_SRC/wayland-protocols-${WPROTO_VER}.tar.xz"
pins_fetch "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/${WPROTO_VER}/downloads/wayland-protocols-${WPROTO_VER}.tar.xz" \
           "$WPROTO_TARBALL" "wayland-protocols"
unpack "$WPROTO_TARBALL" "$WL_SRC/wayland-protocols-${WPROTO_VER}"
step "meson + ninja"
( cd "$WL_SRC/wayland-protocols-${WPROTO_VER}" && \
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      > "$SCRIPT_DIR/.wl-wproto.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-wproto.log" 2>&1 ) \
  || { fail "wayland-protocols build failed"; tail -20 "$SCRIPT_DIR/.wl-wproto.log" | sed 's/^/         /'; exit 1; }
[ -d "$WL_PREFIX/share/wayland-protocols" ] || fail "wayland-protocols data not installed"
ok "wayland-protocols ${WPROTO_VER} (XML in the prefix, not the host's)"

header "libdisplay-info (EDID/connector parsing - wlroots hard-links this)"
# This one is genuinely required, not just a transitive nicety: it shows up in
# wlroots' DT_NEEDED list, so wlroots will not even start without it. Left out,
# wlroots binds to the host's copy and the image carries whatever version the
# build machine happened to have.
# Built inline rather than via meson_build(): this block sits above the helper's
# definition in the file, and bash would fail at runtime with
# "meson_build: command not found" rather than at parse time.
[ -d "$WL_SRC/libdi" ] || git_clone "https://gitlab.freedesktop.org/emersion/libdisplay-info" "0.2.0" "$WL_SRC/libdi"
step "meson + ninja"
( cd "$WL_SRC/libdi" && \
  # 0.2.0 declares no meson options at all - the test/ and tool/ subprojects are
  # unconditional, and passing any -D here is a hard "Unknown option" error.
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
        > "$SCRIPT_DIR/.wl-libdi.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-libdi.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-libdi.log" 2>&1 ) \
  || { fail "libdisplay-info build failed"; tail -20 "$SCRIPT_DIR/.wl-libdi.log" | sed 's/^/         /'; exit 1; }
need libdisplay-info.so "libdisplay-info"
ok "libdisplay-info built"

header "libseat 0.9.3 (session management - wlroots REFUSES drm/libinput without it)"
# Not optional and not deferrable, despite being small. wlroots' backend/
# meson.build:14 is explicit:
#
#   Problem encountered: Session support is required for the DRM or libinput
#   backends
#
# so disabling it does not mean "no session", it means "no backends",
# and sway then has nothing to open a DRM device on. That error is the reason
# this component exists rather than an optimisation.
#
# libseat's logind backend needs no logind here: with none running it falls back
# to its noop backend, which is exactly right for a live system where init.c is
# PID 1 and there is no session manager to talk to.
[ -d "$WL_SRC/seatd" ] || git_clone "https://github.com/kennylevinsen/seatd" "0.9.3" "$WL_SRC/seatd"
step "meson + ninja"
# -Dhardening=false, and this is a genuine conflict rather than a preference.
#
# This host's gcc spec already defines _FORTIFY_SOURCE, and meson defines it
# again when it turns its own hardening on (which it does for release/plain
# buildtypes, and not for debug - which is why the same command without
# -Dbuildtype=release builds fine). Two definitions on one command line is a
# redefinition warning everywhere else in this script, but libseat compiles with
# -Werror, so for this one component it is a hard stop:
#
#   <command-line>: error: '_FORTIFY_SOURCE' redefined [-Werror]
#   <built-in>: note: this is the location of the previous definition
#
# Turning werror off does NOT weaken the result: it only stops a duplicate
# macro definition from being fatal. The host spec is still applying its own
# hardening; meson is simply not told to apply a second copy. meson's own
# `hardening` option is unavailable here - seatd pins a meson_version older than
# the builtin was added - so this is the way to reach the same outcome.
#
# Turning meson hardening off would NOT mean the build loses hardening: the
# host spec is still applying its own. It only stops it being applied twice.
( cd "$WL_SRC/seatd" && \
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      -Dwerror=false -Dlibseat-logind=disabled \
      > "$SCRIPT_DIR/.wl-libseat.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-libseat.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-libseat.log" 2>&1 ) \
  || { fail "libseat build failed"; tail -25 "$SCRIPT_DIR/.wl-libseat.log" | sed 's/^/         /'; exit 1; }
need libseat.so.1 "libseat"
ok "libseat built"


fi
# ===========================================================================
# STAGE 3 - sway itself, and the text stack it renders with.
#
# sway links pango, cairo and gdk-pixbuf. That is not decoration: the status bar
# is Pango-rendered text, the cursor theme is loaded through gdk-pixbuf, and
# sway's configure refuses to continue without all three. The order is strictly
# bottom-up:
#
#   freetype      font rasteriser; everything above needs it
#   fontconfig    where fonts get found; needs freetype
#   glib          the object system under pango and gdk-pixbuf
#   cairo         2D drawing; needs freetype and fontconfig
#   gdk-pixbuf    decodes cursor and icon images for sway
#   pango         text shaping and layout; needs glib, cairo and harfbuzz
#
# cairo is a git checkout rather than a tarball: its release tarballs live on a
# host this machine cannot reliably reach, but its GitLab tags are complete, and
# pins.lock's [git] section pins a commit hash just as well as a sha256.
#
# Still deferred: Mesa (stage 4, GLES2 renderer) and XWayland (stage 5).
# ===========================================================================
if [[ "$STAGE" -ge 3 ]]; then

GLIB_VER="2.84.4";       GLIB_URL="https://download.gnome.org/sources/glib/2.84/glib-${GLIB_VER}.tar.xz"
FREETYPE_VER="2.13.3";   FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VER}.tar.xz"
FONTCONFIG_VER="2.16.0"; FONTCONFIG_URL="https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/${FONTCONFIG_VER}/fontconfig-${FONTCONFIG_VER}.tar.gz"
GDKPB_VER="2.44.2";      GDKPB_URL="https://download.gnome.org/sources/gdk-pixbuf/2.44/gdk-pixbuf-${GDKPB_VER}.tar.xz"
PANGO_VER="1.56.4";      PANGO_URL="https://download.gnome.org/sources/pango/1.56/pango-${PANGO_VER}.tar.xz"

# meson_build <name> <srcdir> <logname> <meson args...>
#
# Eight projects share this shape, so the failure handling is factored out
# rather than retyped - it has to be identical each time or one of them quietly
# stops showing its error.
meson_build() {
    local name="$1" dir="$2" log="$3"; shift 3
    [ -d "$dir" ] || fail "$dir is missing"
    substep "source: ${dir#"$WL_SRC"/}"
    ( cd "$dir" && \
      meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release "$@" \
          > "$SCRIPT_DIR/$log" 2>&1 && \
      ninja -C build >> "$SCRIPT_DIR/$log" 2>&1 && \
      ninja -C build install >> "$SCRIPT_DIR/$log" 2>&1 ) \
      || { fail "$name build failed"; tail -25 "$SCRIPT_DIR/$log" | sed 's/^/         /'; exit 1; }
}

header "freetype ${FREETYPE_VER} (font rasteriser - cairo and pango need it)"
pins_fetch "$FREETYPE_URL" "$WL_SRC/freetype-${FREETYPE_VER}.tar.xz" "freetype"
unpack "$WL_SRC/freetype-${FREETYPE_VER}.tar.xz" "$WL_SRC/freetype-${FREETYPE_VER}"
step "meson + ninja"
# -Dharfbuzz=disabled: pango builds its own harfbuzz, and two copies in one
# prefix is a link-time mess for no benefit.
meson_build freetype "$WL_SRC/freetype-${FREETYPE_VER}" ".wl-freetype.log" \
    -Dharfbuzz=disabled -Dtests=disabled -Dpng=disabled -Dbrotli=disabled
need libfreetype.so.6 "freetype"
ok "freetype built"

header "fontconfig ${FONTCONFIG_VER} (font discovery)"
# 2.16, not something newer. fontconfig 2.17 moved the FreeType API out of
# fontconfig.h and into fcfreetype.h and stopped including it, and pango
# includes only <fontconfig/fontconfig.h>. The symptom is an implicit-declaration
# error on FcFreeTypeQueryAll, which is the function pango uses to ask fontconfig
# for every font in one file:
#
#   pangofc-fontmap.c:4010: error: implicit declaration of function
#   'FcFreeTypeQueryAll' [-Wimplicit-function-declaration]
#
# 2.15 and 2.16 both still have fontconfig.h include fcfreetype.h; 2.17 does not.
# This is pango 1.56's ceiling, not a preference.
pins_fetch "$FONTCONFIG_URL" "$WL_SRC/fontconfig-${FONTCONFIG_VER}.tar.gz" "fontconfig"
unpack "$WL_SRC/fontconfig-${FONTCONFIG_VER}.tar.gz" "$WL_SRC/fontconfig-${FONTCONFIG_VER}"
step "meson + ninja"
meson_build fontconfig "$WL_SRC/fontconfig-${FONTCONFIG_VER}" ".wl-fontconfig.log" \
    -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled -Dnls=disabled
need libfontconfig.so.1 "fontconfig"
ok "fontconfig built"

header "pcre2 (regex engine - glib links this, and glib is everywhere here)"
# glib hard-links libpcre2-8. An x11 build happens to have it staged because
# something else in the X stack wanted it, but a Wayland-only build has no
# reason to, and glib would silently bind the host's copy.
pins_fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.46/pcre2-10.46.tar.gz" \
           "$WL_SRC/pcre2-10.46.tar.gz" "pcre2"
unpack "$WL_SRC/pcre2-10.46.tar.gz" "$WL_SRC/pcre2-10.46"
step "cmake + make"
# Only the 8-bit library: glib wants libpcre2-8, and the 16/32-bit variants are
# dead weight in an image this size.
( cd "$WL_SRC/pcre2-10.46" && \
  cmake -B build -DCMAKE_INSTALL_PREFIX="$WL_PREFIX" \
        -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF \
        -DPCRE2_SUPPORT_JIT=ON -DBUILD_SHARED_LIBS=ON \
        -DPCRE2_SUPPORT_PCRE2GREP=OFF -DCMAKE_BUILD_TYPE=Release \
        > "$SCRIPT_DIR/.wl-pcre2.log" 2>&1 && \
  cmake --build build -j"$(nproc)" >> "$SCRIPT_DIR/.wl-pcre2.log" 2>&1 && \
  cmake --install build >> "$SCRIPT_DIR/.wl-pcre2.log" 2>&1 ) \
  || { fail "pcre2 build failed"; tail -20 "$SCRIPT_DIR/.wl-pcre2.log" | sed 's/^/         /'; exit 1; }
need libpcre2-8.so "pcre2"
ok "pcre2 built"

header "glib ${GLIB_VER} (object system - pango and gdk-pixbuf sit on this)"
pins_fetch "$GLIB_URL" "$WL_SRC/glib-${GLIB_VER}.tar.xz" "glib"
unpack "$WL_SRC/glib-${GLIB_VER}.tar.xz" "$WL_SRC/glib-${GLIB_VER}"
step "meson + ninja"
# No libmount or selinux: init.c mounts what is needed itself, and a D-Bus
# activator would try to talk to a bus that only exists after the desktop starts.
meson_build glib "$WL_SRC/glib-${GLIB_VER}" ".wl-glib.log" \
    -Dtests=false -Ddocumentation=false -Dman-pages=disabled \
    -Dintrospection=disabled -Dselinux=disabled -Dlibmount=disabled
need libglib-2.0.so.0 "glib"
ok "glib built"

header "cairo 1.18.6 (2D drawing - sway's status bar goes through this)"
CAIRO_VER="1.18.6"
[ -d "$WL_SRC/cairo" ] || git_clone "https://gitlab.freedesktop.org/cairo/cairo" "$CAIRO_VER" "$WL_SRC/cairo"
step "meson + ninja"
# X11 and the GL/gles2 renderers are off: the X ones because there is no X
# in this build, and GL because it would want Mesa, which is stage 4.
# cairo's image surface is all sway uses, and that needs no GL at all.
meson_build cairo "$WL_SRC/cairo" ".wl-cairo.log" \
    -Dtests=disabled -Dxlib=disabled -Dxcb=disabled -Dxlib-xcb=disabled -Dgtk2-utils=disabled \
    -Dsymbol-lookup=disabled -Dspectre=disabled
need libcairo.so.2 "cairo"
ok "cairo built"

header "gdk-pixbuf ${GDKPB_VER} (cursor and icon decoding for sway)"
pins_fetch "$GDKPB_URL" "$WL_SRC/gdk-pixbuf-${GDKPB_VER}.tar.xz" "gdk-pixbuf"
unpack "$WL_SRC/gdk-pixbuf-${GDKPB_VER}.tar.xz" "$WL_SRC/gdk-pixbuf-${GDKPB_VER}"
step "meson + ninja"
# Only the loaders sway can actually hit: png for cursors and wallpapers, and
# jpeg because swaybg accepts any image. tiff, gif and the glycin sandbox are a
# decoder each for formats this system has no use for - glycin needs its own
# library and fails the build outright when it is merely enabled.
meson_build gdk-pixbuf "$WL_SRC/gdk-pixbuf-${GDKPB_VER}" ".wl-gdkpb.log" \
    -Dtests=false -Ddocumentation=false -Dintrospection=disabled \
    -Dman=false -Dinstalled_tests=false -Dthumbnailer=disabled -Dothers=disabled \
    -Dpng=enabled -Djpeg=enabled -Dtiff=disabled -Dgif=disabled -Dglycin=disabled
need libgdk_pixbuf-2.0.so.0 "gdk-pixbuf"
ok "gdk-pixbuf built"

header "harfbuzz 11.2.1 (text shaping - pango's core)"
pins_fetch "https://github.com/harfbuzz/harfbuzz/releases/download/11.2.1/harfbuzz-11.2.1.tar.xz" \
           "$WL_SRC/harfbuzz-11.2.1.tar.xz" "harfbuzz"
unpack "$WL_SRC/harfbuzz-11.2.1.tar.xz" "$WL_SRC/harfbuzz-11.2.1"
step "meson + ninja"
# No ICU, no GObject introspection, no tests: pango uses the plain C API and
# nothing here introspects it. FreeType and glib are already in the prefix.
meson_build harfbuzz "$WL_SRC/harfbuzz-11.2.1" ".wl-harfbuzz.log" \
    -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled -Dicu=disabled \
    -Dglib=enabled -Dgobject=enabled -Dcairo=enabled -Dfreetype=enabled
need libharfbuzz.so.0 "harfbuzz"
ok "harfbuzz built"

header "fribidi 1.0.16 (bidi text - pango needs it for correct RTL ordering)"
pins_fetch "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz" \
           "$WL_SRC/fribidi-1.0.16.tar.xz" "fribidi"
unpack "$WL_SRC/fribidi-1.0.16.tar.xz" "$WL_SRC/fribidi-1.0.16"
step "meson + ninja"
meson_build fribidi "$WL_SRC/fribidi-1.0.16" ".wl-fribidi.log" \
    -Ddocs=false -Dtests=false -Ddeprecated=false -Dbin=false -Dfuzzer_ldflags=false
need libfribidi.so.0 "fribidi"
ok "fribidi built"

header "pango ${PANGO_VER} (text shaping - the status bar is Pango-rendered text)"
pins_fetch "$PANGO_URL" "$WL_SRC/pango-${PANGO_VER}.tar.xz" "pango"
unpack "$WL_SRC/pango-${PANGO_VER}.tar.xz" "$WL_SRC/pango-${PANGO_VER}"
step "meson + ninja"
meson_build pango "$WL_SRC/pango-${PANGO_VER}" ".wl-pango.log" \
    -Dbuild-testsuite=false -Dbuild-examples=false -Ddocumentation=false \
    -Dgtk_doc=false -Dman-pages=false -Dintrospection=disabled
need libpango-1.0.so.0 "pango"
ok "pango built"

header "libevdev (evdev device access - sway reads input devices through it)"
# Built here rather than taken from the host for the same reason as everything
# else: sway links -levdev, and an unpinned host libevdev would end up in the
# image. All three options are meson 'feature' type, so they take enabled or
# disabled rather than true or false.
[ -d "$WL_SRC/libevdev" ] || git_clone "https://gitlab.freedesktop.org/libevdev/libevdev" "1.14.3" "$WL_SRC/libevdev"
step "meson + ninja"
meson_build libevdev "$WL_SRC/libevdev" ".wl-libevdev.log" \
    -Dtests=disabled -Dtools=disabled -Ddocumentation=disabled
need libevdev.so "libevdev"
ok "libevdev built"

header "json-c (sway's IPC protocol - sway links it unconditionally)"
[ -d "$WL_SRC/jsonc" ] || fail "$WL_SRC/jsonc is missing - json-c must be checked out there"
JSONC_GOT="$(cd "$WL_SRC/jsonc" && git rev-parse HEAD)"
step "meson + ninja"
# The option is build_apps, and there is no tests or documentation option at
# all - passing either is a hard "Unknown option" error from meson, not a
# warning. Static because json-c is small and linked into sway; a shared copy
# would be one more thing in the closure for no benefit.
meson_build json-c "$WL_SRC/jsonc" ".wl-jsonc.log" \
    -Dbuild_apps=false -Ddefault_library=static
ok "json-c built (commit ${JSONC_GOT:0:12}, static)"

# ---------------------------------------------------------------------------
# Mesa: EGL + GLES2 + GBM.
#
# wlroots can run on the pixman renderer alone - that is what everything above
# proves - but "pixman only" also means no hardware acceleration and no EGL at
# all. This stage adds the second path.
#
# llvm is disabled on purpose, and that choice FORCES softpipe rather than
# llvmpipe. Mesa 26.2 says so itself:
#   meson.build:249: Feature llvm cannot be disabled:
#   LLVMPipe Gallium driver requires LLVM
# Every other Gallium driver that does real GL work is LLVM- or hardware-
# specific, so the only remaining software rasteriser is softpipe - pure C, no
# JIT, no GPU required.
#
# softpipe is meaningfully slower than llvmpipe. That is the correct trade here:
# LLVM is the single most expensive dependency in this build by a wide margin,
# and a live image that boots in minutes is worth more than GLES2 that is fast
# on a machine with no GPU anyway. The pixman renderer remains available and is
# what wlroots will actually use in most sessions; this exists so GLES2 is
# present as an option at all.
# ---------------------------------------------------------------------------

# Read before the header prints it: `set -u` makes an unset variable a hard error,
# and putting the assignment first is the only order that works.
MESA_VERSION="$(cat "$WL_SRC/mesa/VERSION" 2>/dev/null || echo unknown)"
header "Mesa ${MESA_VERSION} (EGL + GLES2 + GBM, softpipe software GL)"
step "meson + ninja"
# -Dgallium-drivers=softpipe is forced by -Dllvm=disabled rather than chosen for
#   its own sake: llvmpipe is Mesa's faster software rasteriser but it is a JIT
#   built on LLVM, and meson.build:249 refuses outright when llvm is disabled -
#   "Feature llvm cannot be disabled: LLVMPipe Gallium driver requires LLVM".
#   softpipe is the remaining pure-software driver.
# -Dshared-glapi=disabled: the GL dispatch table is only needed for desktop GL,
#   which nothing here uses, and it is a separate library to carry.
# -Dglx/dri/x11 off: there is no X11 in a Wayland image. platforms=wayland is the
#   only one that matters and it is what EGL's wayland platform binds to.
# Type matters here and meson enforces it: gles2/egl/gbm/llvm/shared-glapi/glvnd/
# valgrind are feature options taking enabled/disabled/auto, while opengl and
# build-tests are plain booleans taking true/false. -Dopengl=disabled is a hard
# "value disabled is not boolean" error, not a warning.
meson_build mesa "$WL_SRC/mesa" ".wl-mesa.log" \
    -Dllvm=disabled -Dgallium-drivers=softpipe -Dshared-glapi=disabled \
    -Dgles2=enabled -Dopengl=false -Degl=enabled -Dgbm=enabled \
    '-Dvulkan-drivers=[]' -Dglx=disabled -Dgles1=disabled \
    -Dglvnd=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
    -Dmesa-clc=system -Dspirv-tools=disabled \
    -Dplatforms=wayland -Dbuild-tests=false '-Dtools=[]' \
    -Dshared-llvm=disabled
need libEGL.so "Mesa EGL"
need libGLESv2.so "Mesa GLESv2"
need libgbm.so "Mesa gbm"
ok "Mesa built (softpipe: software GLES2, no LLVM)"

header "wlroots 0.20.2 (the compositor library)"
[ -d "$WL_SRC/wlroots" ] || git_clone "https://gitlab.freedesktop.org/wlroots/wlroots" "0.20.2" "$WL_SRC/wlroots"
step "meson + ninja"
# The option list is the whole story of this stage:
#
#   renderers=[]        no gles2, no vulkan -> no Mesa needed yet. The pixman
#                       renderer is built anyway by render/meson.build.
#   allocators=[udmabuf] gbm comes from Mesa, so it goes too. udmabuf is a
#                       kernel memfd-backed allocator that needs no userspace
#                       library at all.
#   backends=drm,libinput  the two sway actually uses. x11 is excluded so
#                       nothing in this build can find an X server.
#   session=false       libseat is a separate dependency and a compositor with
#                       no logind can still take input directly.
#   xwayland=false       deferred to stage 4. It is the heaviest single item in
#                       the Wayland backend and nothing about sway itself needs it.
#
# -Dcolor-management=disabled drops lcms2, which is only meaningful with a
# calibrated display and pulls another library.
( cd "$WL_SRC/wlroots" && \
  meson setup build --prefix="$WL_PREFIX" -Dbuildtype=release \
      '-Drenderers=gles2' '-Dallocators=gbm' \
      -Dbackends=drm,libinput \
      -Dsession=enabled -Dxwayland=disabled \
      -Dcolor-management=disabled -Dexamples=false \
      > "$SCRIPT_DIR/.wl-wlroots.log" 2>&1 && \
  ninja -C build >> "$SCRIPT_DIR/.wl-wlroots.log" 2>&1 && \
  ninja -C build install >> "$SCRIPT_DIR/.wl-wlroots.log" 2>&1 ) \
  || { fail "wlroots build failed"; tail -30 "$SCRIPT_DIR/.wl-wlroots.log" | sed 's/^/         /'; exit 1; }
need libwlroots-0.20.so "wlroots"

# wlroots 0.20 installs its pkg-config file as wlroots-0.20.pc, but sway asks
# pkg-config for plain "wlroots" and gets Dependency "wlroots" not found. The
# unversioned name was what wlroots shipped before 0.20, and consumers still use
# it, so the alias is written here rather than by patching sway's meson.build.
for pcdir in "$WL_PREFIX/lib/pkgconfig" "$WL_PREFIX/lib64/pkgconfig"; do
    if [ -f "$pcdir/wlroots-0.20.pc" ]; then
        cp -f "$pcdir/wlroots-0.20.pc" "$pcdir/wlroots.pc"
    fi
done
PKG_CONFIG_PATH="$WL_PREFIX/lib/pkgconfig:$WL_PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
    pkg-config --exists wlroots \
    || fail "wlroots.pc alias written but pkg-config still cannot see it"
ok "wlroots built (pixman + gles2 renderers, drm + libinput backends)"
info "renderer: pixman always, gles2 via Mesa softpipe. wlroots is linked against:"
objdump -p "$WL_PREFIX/lib64/libwlroots-0.20.so" 2>/dev/null | sed -n "s/^ *NEEDED *//p" | grep -E "wlr|pixman" | sed "s/^/  /"


header "sway 1.12 (the compositor)"
# From github.com/swaywm/sway, not git.sr.ht/~sircmpwn/sway. That repository
# stopped at 1.1-rc2 and the project moved; the GitHub one is current.
#
# The version is not cosmetic either. sway 1.0 does not compile against
# wlroots 0.20 at all - that release reorganised its headers, and the result is
# a wall of "wlr/types/wlr_box.h: No such file or directory". sway and wlroots
# move together, so they are pinned as a compatible pair rather than at their
# respective latest.
[ -d "$WL_SRC/sway" ] || git_clone "https://github.com/swaywm/sway" "1.12" "$WL_SRC/sway"
step "meson + ninja"
# sway builds swaybar as part of its own tree - it stopped being a separate
# repository - so this one build produces both binaries.
#
# -Dxwayland=disabled is stage 5. Nothing in sway itself needs it and it is the
# heaviest single item in this backend.
# sway 1.12 has no xwayland option at all - the support is unconditional now and
# it simply execs Xwayland at startup if it finds one. That is acceptable while
# XWayland is still stage 5: with no Xwayland binary present, sway starts without
# it rather than failing.
#
# -Dtray=disabled and -Dswaynag=false drop the status-notifier tray (which needs
# a tray host to talk to) and the dialog tool, neither of which this image has a
# use for. -Dsd-bus-provider=libelogind because every choice is systemd, and there
# is no systemd here - init.c is PID 1.
meson_build sway "$WL_SRC/sway" ".wl-sway.log" \
    -Dswaybar=true -Dtray=disabled -Dswaynag=false -Dsd-bus-provider=libelogind \
    -Dman-pages=disabled -Ddefault-wallpaper=false \
    -Dzsh-completions=false -Dbash-completions=false -Dfish-completions=false
need_bin sway "sway"
need_bin swaybar "swaybar"
need_bin swaymsg "swaymsg"
ok "sway built ($(du -h "$WL_PREFIX/bin/sway" 2>/dev/null | cut -f1))"

fi





# ---------------------------------------------------------------------------
# Stage: session tools.
#
# sway and swaybar are the compositor and its bar, both built from the sway tree.
# These four are separate projects that speak the same protocol:
#
#   swaybg        wallpaper daemon - paints a colour or image on the root layer
#   grim          screenshot, via the wlr-screencopy protocol
#   wf-recorder   screen + audio recorder, also wlr-screencopy
#   foot          terminal emulator
#
# All four are built here rather than left to a distro package because the point
# of the exercise is that nothing in the image resolves against the build host.
# ---------------------------------------------------------------------------

header "swaybg (wallpaper daemon)"

[ -d "$WL_SRC/swaybg" ] || git_clone "https://github.com/swaywm/swaybg" "v1.2.2" "$WL_SRC/swaybg"
step "meson + ninja"
# gdk-pixbuf on: swaybg loads its image through it, and the library is already
# staged for sway's cursor handling, so there is nothing new to carry.
meson_build swaybg "$WL_SRC/swaybg" ".wl-swaybg.log" -Dgdk-pixbuf=enabled -Dman-pages=disabled
need_bin swaybg "swaybg"
ok "swaybg built"

header "grim (screenshot - wlr-screencopy)"

[ -d "$WL_SRC/grim" ] || git_clone "https://gitlab.freedesktop.org/emersion/grim" "v1.5.0" "$WL_SRC/grim"
step "meson + ninja"
# -Djpeg=disabled: grim writes PNG by default and libpng is already staged for
# cairo. Enabling jpeg would add libjpeg to the closure for a format nothing in
# this image produces. Completions off - there is no bash or zsh here.
meson_build grim "$WL_SRC/grim" ".wl-grim.log" \
    -Djpeg=disabled -Dman-pages=disabled \
    -Dfish-completions=false -Dbash-completions=false
need_bin grim "grim"
ok "grim built"

header "wf-recorder (screen and audio recorder)"

# SKIPPED, and deliberately so: wf-recorder hard-requires ffmpeg.
#
# meson.build:111-118 lists libavutil, libavcodec, libavformat, libavfilter and
# gbm, and every one but libavdevice is dependency(..., ) with no
# required: false - there is no option to build without them. So a wf-recorder
# binary means an ffmpeg in the image, and ffmpeg from source is the single
# largest build in this whole chain by a wide margin (x264/x265 if not disabled,
# plus every codec/demuxer). It is stage 6 work, on its own, not something to
# drag in alongside the compositor.
#
# gbm is the smaller half of the same problem: it comes from Mesa, which is
# stage 4 and not built yet either.
#
# Recording is genuinely useful in a compositor image, so this is a real gap and
# not a "nice to have" - but shipping a recorder that links the build host's
# ffmpeg, which is what happens if this is merely left enabled, would be exactly
# the unpinned dependency the whole prefix exists to avoid. Skipping is the
# honest state; it is not a silent one.
WL_SKIP_WFRECORDER=1

if [ -n "$WL_SKIP_WFRECORDER" ]; then
    skip "wf-recorder deferred: needs ffmpeg (stage 6) and Mesa's gbm (stage 4)"
fi

# The rest of the block is kept, correct and commented, so that turning the skip
# off after stage 4 and 6 land is a one-line change rather than a reconstruction.
if [ -z "$WL_SKIP_WFRECORDER" ]; then
[ -d "$WL_SRC/wf-recorder" ] || git_clone "https://gitlab.freedesktop.org/emersion/wf-recorder" "v0.6.0" "$WL_SRC/wf-recorder"
step "meson + ninja"
# Audio is disabled deliberately and this needs saying. Both backends are D-Bus
# clients: pipewire over the session bus, pulse over its own protocol. This
# image has no D-Bus daemon, no pipewire and no pulseaudio, and none of them are
# in scope for a compositor image - so a recorder built with pulse enabled would
# carry the whole dependency chain and then fail at runtime with an error about
# a daemon that does not exist.
#
# default_audio_backend=auto, not a named backend: there is no "none" choice, and
# meson.build:70-77 hard-errors if the named default's support is disabled or its
# dependency is missing. "auto" is the only value that tolerates both backends
# being off, and with both disabled have_audio stays false - so the binary is
# built without HAVE_PIPEWIRE/HAVE_PULSE and records video only, which is what
# -g selects at runtime anyway.
meson_build wf-recorder "$WL_SRC/wf-recorder" ".wl-wfrec.log" \
    -Ddefault_audio_backend=auto -Dpulse=disabled -Dpipewire=disabled
need_bin wf-recorder "wf-recorder"
ok "wf-recorder built (video only: no pipewire or pulse in this image)"
fi

header "tllist + fcft (foot's font rasteriser, and its intrusive list library)"

# These exist only because foot needs them, and both were found on the build host
# by foot's own meson: `dependency('fcft', version: ['>=3.3.1', '<4.0.0'],
# fallback: 'fcft')` and tllist with `fallback: 'tllist'`. The fallback means
# meson would have built them as subprojects if they were absent - but they were
# present, so it used the host's copies and foot ended up with libfcft.so.4 in
# its DT_NEEDED pointing at a library this build never produced. The staging gate
# is what caught it, which is the gate earning its keep.

[ -d "$WL_SRC/tllist" ] || git_clone "https://codeberg.org/dnkl/tllist" "" "$WL_SRC/tllist"
step "meson + ninja"
# Header-only, so there is no library to assert with need().
meson_build tllist "$WL_SRC/tllist" ".wl-tllist.log"

[ -d "$WL_SRC/fcft" ] || git_clone "https://codeberg.org/dnkl/fcft" "3.3.3" "$WL_SRC/fcft"
step "meson + ninja"
# run-shaping off: it would pull libutf8proc for grapheme segmentation, which
# foot only reaches through the option below that is also off.
# These are feature-type options, so the values are enabled/disabled/auto -
# passing "false" is a hard "not one of the choices" error from meson.
meson_build fcft "$WL_SRC/fcft" ".wl-fcft.log" \
    -Dgrapheme-shaping=disabled -Drun-shaping=disabled -Ddocs=disabled
need libfcft.so "fcft"
ok "fcft built"

header "foot (terminal emulator)"

[ -d "$WL_SRC/foot" ] || git_clone "https://gitlab.freedesktop.org/foot/foot" "1.27.0" "$WL_SRC/foot"
step "meson + ninja"
# -Dime=false: input-method support links fcitx/ibus, neither of which this image
#   has. Left on, foot drags in a whole input stack to service a feature that
#   could never be reached.
# -Dutmp-backend=none: utmp logging is for recording who logged into a getty.
#   There is no getty in this image - init registers shells directly - so
#   libutempter would be staged for nothing.
# -Dterminfo=disabled: foot falls back to its builtin ncurses terminfo, which
#   avoids shipping a second terminfo database alongside the staged one.
meson_build foot "$WL_SRC/foot" ".wl-foot.log" \
    -Dime=false -Ddocs=disabled -Dtests=false -Dthemes=false \
    -Dutmp-backend=none -Dterminfo=disabled -Dgrapheme-clustering=disabled
need_bin foot "foot"
ok "foot built"

# ---------------------------------------------------------------------------
# Stage: dist. Nothing above this point touches wayland-dist/ except mkdir.
# Everything below exists to turn wl-prefix/ (a pile of 70-odd libraries built
# against each other) into wayland-dist/ (a self-contained tree assemble-rootfs.sh
# can copy into the initramfs).
#
# The layout mirrors x11-dist/ exactly, because the guest's loader behaviour
# dictates it:
#
#   usr/bin/     executables
#   usr/lib64/   the flattened ldd closure
#
# Flat, because the guest has no ld.so.cache. The dynamic loader searches its
# default directories and finds a library by FILENAME alone, so a lib in
# wl-prefix/lib/pixman-1/ that nothing can find is the same as a lib that was
# never staged.
# ---------------------------------------------------------------------------

header "Stage: dist (staging wayland-dist/ from wl-prefix/)"

# sway, swaybar and swaymsg are the whole user-visible surface for now.
# wl-surface/session files and the seatd helper get added below.
for b in sway swaybar swaymsg swaybg foot grim wf-recorder; do
    # wf-recorder is skipped above and simply will not exist; the others must.
    if [ -x "$WL_PREFIX/bin/$b" ]; then
        cp -f "$WL_PREFIX/bin/$b" "$WL_DIST/bin/"
    fi
done
# wayland-sessions: sway.desktop, installed by meson into share/. Staged whole
# rather than file-by-file so a future sway release adding a session file does
# not silently lose it.
if [ -d "$WL_PREFIX/share/wayland-sessions" ]; then
    mkdir -p "$WL_DIST/usr/share/wayland-sessions"
    cp -rf "$WL_PREFIX/share/wayland-sessions/." "$WL_DIST/usr/share/wayland-sessions/"
fi
# seatd/libseat backend: wlroots opens a logind session when it can, and falls
# back to direct DRM + its own seat otherwise. Staging it costs one small binary
# and makes the "did libseat find a seat?" question answerable in the guest.
if [ -x "$WL_PREFIX/bin/seatd" ]; then
    cp -f "$WL_PREFIX/bin/seatd" "$WL_DIST/bin/"
fi

# sway's config is WRITTEN, not copied.
#
# The upstream one that meson installed into wl-prefix/etc/sway/ cannot be used,
# for three reasons, each of which fails quietly rather than loudly:
#
#   1. It contains a build-host path. meson baked the configure prefix into the
#      wallpaper line:
#        output * bg /home/.../wl-prefix/share/backgrounds/sway/Sway_Wallpaper...png
#      In the guest that path does not exist, so the wallpaper silently does not
#      appear - and the same prefix leak my staging gate looks for in binaries is
#      just as wrong in a text file.
#   2. It binds $mod+Shift+e to `swaynag`, which is not built here
#      (-Dswaynag=false), and $mod+d to `wmenu-run`, which was never a target at
#      all. Both keybindings would run nothing.
#   3. It has no `exec` line, so it opens a desktop with no terminal and no
#      launcher.
#
# It also wants swaybg for an image wallpaper. This image stages no wallpaper
# file, so the background is set with sway's own `background` command instead -
# one fewer daemon to supervise for a solid colour.
#
# The config is the session's own description of what to run, so `exec foot`
# belongs here rather than in init.c. init starts the compositor; the compositor
# starts its session. Putting the terminal in init as well would mean two
# owners for one process.
mkdir -p "$WL_DIST/etc/sway"
cat > "$WL_DIST/etc/sway/config" <<'SWAY_CONFIG'
# /etc/sway/config - rlOS Wayland session
#
# Written by build_wl.sh, not shipped by sway. See the comment above about the
# build-host path in upstream's copy and the two keybindings that call binaries
# this image does not contain.

### Variables
set $mod Mod4
set $left h
set $down j
set $up k
set $right l
set $term foot

### Output
# A solid colour, not an image. `output * bg ... fill` with a file needs a
# wallpaper staged into the image; nothing is, so sway's `background` command is
# the honest way to get a flat backdrop with no extra daemon running.
background #1c1c1c solid_color

### Autostart
# The session's terminal. sway execs this and keeps it as a child, so it dies
# with the compositor and restarts with it - which is why it is here and not
# registered in init.c's supervised table.
exec $term

### Keys
    bindsym $mod+Return exec $term
    bindsym $mod+Shift+q kill
    bindsym $mod+Shift+c reload

    # Focus and move. Vim keys under Mod4, arrows under Mod1.
    bindsym $mod+$left  focus left
    bindsym $mod+$down   focus down
    bindsym $mod+$up     focus up
    bindsym $mod+$right  focus right
    bindsym $mod+Left    focus left
    bindsym $mod+Down    focus down
    bindsym $mod+Up      focus up
    bindsym $mod+Right   focus right
    bindsym $mod+Shift+$left focus move left
    bindsym $mod+Shift+$down  focus move down
    bindsym $mod+Shift+$up    focus move up
    bindsym $mod+Shift+$right focus move right
    bindsym $mod+Shift+Left   move left
    bindsym $mod+Shift+Down   move down
    bindsym $mod+Shift+Up     move up
    bindsym $mod+Shift+Right  move right

    # Split containers, then the orientation to apply to new ones.
    bindsym $mod+b splith
    bindsym $mod+v splitv
    bindsym $mod+s layout stacking
    bindsym $mod+w layout tabbed
    bindsym $mod+e layout toggle split

    # Fullscreen and floating.
    bindsym $mod+f fullscreen
    bindsym $mod+Shift+space floating toggle
    floating_modifier $mod normal

### Input
input * {
    repeat_delay 300
    repeat_rate 50
}

### Output layout
# Single output, filling it. QEMU presents one connector; spelling it out means
# sway does not have to guess when there is no EDID to read.
output * bg #1c1c1c solid_color
SWAY_CONFIG

# Assert it exists and is not the upstream one we rejected - if a future change
# ever copies wl-prefix/etc/sway/ back over this, the assertion catches it.
[ -s "$WL_DIST/etc/sway/config" ] \
    || fail "sway config was not written to $WL_DIST/etc/sway/config"
if grep -q "$WL_PREFIX" "$WL_DIST/etc/sway/config"; then
    fail "the staged sway config contains the build prefix $WL_PREFIX"
fi
for absent in swaynag wmenu-run; do
    grep -q "$absent" "$WL_DIST/etc/sway/config" \
        && fail "the staged sway config invokes $absent, which this image does not build"
done
# fontconfig configuration, shared with the X11 backend.
#
# etc-rlos/fonts.conf is the single copy - build_x11.sh reads the same file - so
# the monospace/sans-serif aliases and the JetBrainsMono Nerd Font mapping cannot
# drift between the two backends. assemble-rootfs.sh copies it to
# etc/fonts/fonts.conf for -w exactly as it does for -x.
#
# It is not optional: foot resolves its default face through fontconfig during
# startup, and with no config a terminal either renders every glyph as a box or
# exits outright.
[[ -f "$SCRIPT_DIR/etc-rlos/fonts.conf" ]] || fail "etc-rlos/fonts.conf missing"
mkdir -p "$WL_DIST/usr/share/rlos"
cp -f "$SCRIPT_DIR/etc-rlos/fonts.conf" "$WL_DIST/usr/share/rlos/fonts.conf"
ok "fonts.conf staged ($(wc -l < "$WL_DIST/usr/share/rlos/fonts.conf") lines)"

ok "sway config written ($(wc -l < "$WL_DIST/etc/sway/config") lines, no build-host paths)"

# ---- ldd closure ------------------------------------------------------------
# Resolve with LD_LIBRARY_PATH pointed at the prefix. Without it ldd falls back
# to the host's default search path and cheerfully resolves our libraries to
# the host's identically-named ones, which is precisely the bug this whole
# staging step exists to catch.
export LD_LIBRARY_PATH="$WL_RUNTIME_LD_PATH"

CLOSURE_SEEN=""
collect_wl() {
    local target="$1" lib
    for lib in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
        case " $CLOSURE_SEEN " in *" $lib "*) continue ;; esac
        CLOSURE_SEEN="$CLOSURE_SEEN $lib"
        collect_wl "$lib"
    done
}
# $WL_DIST/usr/bin may not exist yet, and find exits 1 on a missing path. Under
# `set -e` that kills the script with no message at all - which is exactly how
# this first failed, with the log ending at the line above and nothing after.
# Point find only at directories that exist.
WL_ELF_DIRS="$WL_DIST/bin"
[ -d "$WL_DIST/usr/bin" ] && WL_ELF_DIRS="$WL_ELF_DIRS $WL_DIST/usr/bin"
ALL_WL_ELFS="$(find $WL_ELF_DIRS -type f 2>/dev/null || true)"
for elf in $ALL_WL_ELFS; do
    [ -f "$elf" ] || continue
    collect_wl "$elf"
done

N_WL_LIBS=0
WL_FROM_PREFIX=""
WL_FROM_HOST=""
for lib in $CLOSURE_SEEN; do
    [ -f "$lib" ] || continue
    base="$(basename "$lib")"
    case "$lib" in
        "$WL_PREFIX"/*)
            # Ours. Stage the real file, then recreate the SONAME links by hand:
            # cp -P would preserve the absolute build path, and cp without it
            # would dereference the link and leave the SONAME name missing. The
            # guest resolves libfoo.so.1 by name, so the name must exist as a
            # file or a link pointing at a file that is also there.
            real="$(readlink -f "$lib")"
            cp -f "$real" "$WL_DIST/usr/lib64/$base"
            WL_FROM_PREFIX="$WL_FROM_PREFIX $base"
            ;;
        /usr/*|/lib/*|/lib64/*)
            # Resolved from the HOST. Three of these have a from-source copy in
            # gcc-dist/, built by the same toolchain as the rest of the image, and
            # those MUST win over the host's - see the substitution below.
            WL_FROM_HOST="$WL_FROM_HOST $base"
            ;;
    esac
    N_WL_LIBS=$((N_WL_LIBS + 1))
done

# Prefer this project's own C++ runtime over the build host's.
#
# Mesa's libgallium-26.2.4.so has libstdc++.so.6 in DT_NEEDED, so ldd resolves
# it to /usr/lib64/libstdc++.so.6 - the build host's, compiled by whatever
# distro gcc the host has. Staging that is the exact unpinned-host dependency
# every gate in this script exists to prevent, and it is worse than useless: a
# libstdc++ built by a different compiler than the one that produced the
# neighbouring libgcc_s is a version-skew crash at runtime rather than a link
# error.
#
# gcc-dist/usr/lib64/libstdc++.so.6 is this project's own, from the pinned
# GCC 16.2.0 (GLIBCXX_3.4.36). Overwrite whatever ldd pointed at.
GCC_DIST="$SCRIPT_DIR/gcc-dist"
if [ -f "$GCC_DIST/usr/lib64/libstdc++.so.6" ]; then
    cp -f "$GCC_DIST/usr/lib64/libstdc++.so.6" "$WL_DIST/usr/lib64/libstdc++.so.6"
    ln -sf libstdc++.so.6 "$WL_DIST/usr/lib64/libstdc++.so"
    WL_FROM_HOST="$(echo "$WL_FROM_HOST" | tr ' ' '\n' |
        grep -vx 'libstdc++.so.6' | grep -v '^$' | tr '\n' ' ')"
    WL_FROM_GCC="libstdc++.so.6 (from gcc-dist, $(strings "$WL_DIST/usr/lib64/libstdc++.so.6" 2>/dev/null |
        grep -oE 'GCC: \(GNU\) [0-9]+\.[0-9]+\.[0-9]+' | head -1))"
    ok "libstdc++.so.6 staged from gcc-dist, not the build host"
else
    warn "gcc-dist/usr/lib64/libstdc++.so.6 not found; libstdc++.so.6 will be"
    warn "  the BUILD HOST's. Run ./build_gcc.sh first for a version-consistent"
    warn "  C++ runtime - Mesa's libgallium links it and will fail otherwise."
fi

# Copy every distinct real file behind the prefix libs we referenced, plus the
# SONAME aliases each one needs. Walking the whole prefix (rather than only
# CLOSURE_SEEN) is deliberate: a library reachable only by dlopen will not
# appear in CLOSURE_SEEN, and this is where it gets picked up anyway.
for real in $(find "$WL_PREFIX/lib" "$WL_PREFIX/lib64" -maxdepth 1 -type f \
                 -name '*.so*' 2>/dev/null | sort); do
    base="$(basename "$real")"
    [ -e "$WL_DIST/usr/lib64/$base" ] || cp -f "$real" "$WL_DIST/usr/lib64/$base"
done
# Recreate symlink chains as real links inside the dist.
for lnk in $(find "$WL_PREFIX/lib" "$WL_PREFIX/lib64" -maxdepth 1 -type l 2>/dev/null); do
    base="$(basename "$lnk")"
    tgt="$(basename "$(readlink -f "$lnk")")"
    if [ -e "$WL_DIST/usr/lib64/$tgt" ] && [ ! -e "$WL_DIST/usr/lib64/$base" ]; then
        ln -sf "$tgt" "$WL_DIST/usr/lib64/$base"
    fi
done
N_WL_LIBS="$(find "$WL_DIST/usr/lib64" -name '*.so*' | wc -l | tr -d ' ')"
ok "$N_WL_LIBS shared objects in usr/lib64/ ($(du -sh "$WL_DIST/usr/lib64" | cut -f1))"

# ---- the gate ---------------------------------------------------------------
# Everything above stages; this is the part that can still be wrong, and it is
# the only check that reflects how the GUEST resolves rather than how the host
# does. ldd on the host is useless as a verdict: it will happily fall back to
# /usr/lib64 for anything missing and report success.
#
# The guest has no ld.so.cache, so the loader finds a library by filename in its
# default dirs. Check DT_NEEDED names against usr/lib64/ directly.
WL_MISSING=""
for elf in $ALL_WL_ELFS; do
    [ -f "$elf" ] || continue
    for need in $(objdump -p "$elf" 2>/dev/null | sed -n 's/^ *NEEDED *//p'); do
        case "$need" in
            # Kernel-provided, or staged into the guest by build_gcc.sh.
            linux-vdso*|linux-gate*|ld-linux*) continue ;;
            libc.so.6|libm.so.6|libpthread.so.0) continue ;;
        esac
        [ -e "$WL_DIST/usr/lib64/$need" ] || WL_MISSING="$WL_MISSING $need"
    done
done
WL_MISSING="$(printf '%s\n' $WL_MISSING | sort -u | grep '[^[:space:]]' | tr '\n' ' ' || true)"
if [ -n "$WL_MISSING" ]; then
    # Print first, fail last. fail() calls exit, so a fail() before the echo
    # swallows the actual list and leaves "not staged:" with nothing after it -
    # which is exactly the shape of bug this repository already has in
    # build-lib.sh's run_quiet. The names are the whole point of this message.
    echo "  [FAIL] these shared objects are needed by something we ship but are not staged:" >&2
    echo "    $WL_MISSING" >&2
    fail "the guest has no ld.so.cache, so they will not be found at runtime"
fi
ok "every DT_NEEDED of every shipped ELF resolves inside usr/lib64/"

# The same argument for dlopen: not visible to DT_NEEDED, and a silent failure
# at runtime - the process starts, draws nothing, and the reason is on a
# stderr the desktop has already covered. Match strings against names ldconfig
# could actually supply, so a coincidental libfoo.so.1 in some data blob does
# not become a false positive.
WL_DLOPEN_MISSING=""
for elf in $ALL_WL_ELFS; do
    [ -f "$elf" ] || continue
    for need in $(strings -a "$elf" 2>/dev/null |
                  grep -oE 'lib[A-Za-z0-9_.+-]{2,40}\.so(\.[0-9]+)*' |
                  sort -u |
                  while read -r n; do
                      ldconfig -p 2>/dev/null | grep -q "[[:space:]]$n[[:space:]]" && echo "$n"
                  done | sort -u); do
        case "$need" in
            linux-vdso*|linux-gate*|ld-linux*) continue ;;
            libc.so.6|libm.so.6|libpthread.so.0) continue ;;
            # Unversioned aliases: the loader resolves the versioned soname,
            # and dlsym probes the short name before the long one.
            libGL.so|libEGL.so|libgbm.so|libxkbcommon.so) continue ;;
            # Probes, not dependencies. swaybar and sway check whether a GPU
            # GL stack is reachable; with no Mesa in this build there is
            # nothing to find, and staging the host's would defeat the pinning.
            libGL.so.1|libEGL.so.1|libgbm.so.1|libvulkan.so.1) continue ;;
        esac
        [ -e "$WL_DIST/usr/lib64/$need" ] || WL_DLOPEN_MISSING="$WL_DLOPEN_MISSING $need"
    done
done
WL_DLOPEN_MISSING="$(printf '%s\n' $WL_DLOPEN_MISSING | sort -u | grep '[^[:space:]]' | tr '\n' ' ' || true)"
if [ -n "$WL_DLOPEN_MISSING" ]; then
    echo "  [FAIL] these are dlopen'd at runtime by something we ship but are not staged:" >&2
    echo "    $WL_DLOPEN_MISSING" >&2
    fail "DT_NEEDED cannot see these - they are invisible to the check above"
fi
ok "every dlopen'd library of every shipped ELF resolves inside usr/lib64/"

# ---- versioned symbol requirements -----------------------------------------
# A DT_NEEDED can carry a VERSION requirement: libfoo.so.1(FOO_1.2). If the
# library staged under that name does not define that version node, ld.so refuses
# to load the binary - "version 'FOO_1.2' not found (required by ...)".
#
# Not hypothetical here. It happened once: pcre2 was added to the prefix AFTER
# sway had already been built, so sway recorded the BUILD HOST's version tag
# (PCRE2_10.47) against libpcre2-8.so.0, while the pcre2 actually staged defines
# no version node at all. The DT_NEEDED gate above passed, because by name the
# library WAS staged. It broke only at run time, on every execution, and only
# announced itself as a warning on stderr that happened to get noticed.
#
# So verify the requirement itself, not just the library's name. readelf -V
# prints the needs table as "File: <lib>" followed by one "Name: <version>" per
# requirement, so pair them up and check the staged copy defines each node.
WL_BADVER=""
for elf in $ALL_WL_ELFS; do
    [ -f "$elf" ] || continue
    while read -r vfile vname; do
        [ -n "$vfile" ] && [ -n "$vname" ] || continue
        [ -e "$WL_DIST/usr/lib64/$vfile" ] || continue
        if ! readelf -V "$WL_DIST/usr/lib64/$vfile" 2>/dev/null |
             grep -q "Name: $vname\$"; then
            WL_BADVER="$WL_BADVER $(basename "$elf")->$vfile($vname)"
        fi
    done < <(readelf -V "$elf" 2>/dev/null |
             awk '/File: lib/ {f=$2; next}
                  /Name: / && f {print f, $2; f=""}')
done
WL_BADVER="$(printf '%s\n' $WL_BADVER | sort -u | grep '[^[:space:]]' | tr '\n' ' ' || true)"
if [ -n "$WL_BADVER" ]; then
    echo "  [FAIL] these binaries require a symbol version the staged library does not define:" >&2
    echo "    $WL_BADVER" >&2
    fail "ld.so would refuse to load them; rebuild the dependents against the prefix"
fi
ok "every symbol-version requirement resolves against a staged library"

# ---- and the absolute-path check --------------------------------------------
# A DT_NEEDED, RPATH or RUNPATH holding an absolute BUILD path means the binary
# was staged out of a build tree instead of an install tree. It would work on
# this machine and nowhere else, which is the exact failure mode a from-source
# reproducible build is supposed to make impossible.
WL_LEAKED=""
for elf in $ALL_WL_ELFS; do
    [ -f "$elf" ] || continue
    if readelf -d "$elf" 2>/dev/null | grep -qE '(RPATH|RUNPATH).*(/home/|/tmp/|\.build)'; then
        WL_LEAKED="$WL_LEAKED $elf"
    fi
done
if [ -n "$WL_LEAKED" ]; then
    fail "these staged binaries carry a build-host path in RPATH/RUNPATH:"
    echo "    $WL_LEAKED"
    exit 1
fi
ok "no staged binary references the build host"

# ---- what came from where, for the log --------------------------------------
if [ -n "${WL_FROM_GCC:-}" ]; then
    info "staged from gcc-dist: $WL_FROM_GCC"
fi
if [ -n "$WL_FROM_HOST" ]; then
    info "resolved against the host (staged by basename): $(echo $WL_FROM_HOST | tr ' ' '\n' | wc -l | tr -d ' ') lib(s)"
    info "  $(echo $WL_FROM_HOST)"
    info "libc/libm are expected here: build_gcc.sh stages those into the guest."
fi

header "Stage $STAGE complete"
ok "prefix: $(du -sh "$WL_PREFIX" | cut -f1) in wl-prefix/"
ok "dist:   $(du -sh "$WL_DIST" | cut -f1) in wayland-dist/"
info "layout:"
find "$WL_DIST" -maxdepth 2 -type d | sort | sed 's/^/       /'
info "binaries:"
for b in $(ls "$WL_DIST/bin" 2>/dev/null); do
    printf "       %-14s %s\n" "$b" "$(du -h "$WL_DIST/bin/$b" | cut -f1)"
done
info "renderers: pixman always; GLES2 available through Mesa softpipe"
info "still to do:"
info "  - XWayland (stage 5), which unblocks xapps-dist: feh, xfiles, xmenu"
info "  - ffmpeg (stage 6), which unblocks wf-recorder"
info "  - a QEMU boot test of -w; nothing has run the compositor yet"
