#!/usr/bin/env bash
# build_xapps.sh - stage the X11 GUIs into the guest, into xapps-dist/.
#
# WHY THIS IS SEPARATE FROM build_x11.sh
#
# feh and xfiles are X11 applications, not part of an X11 server stack, and they
# now need to ship in the Wayland backend too (there, through XWayland). Leaving
# them in build_x11.sh would tie them to the -x flag, which is exactly the
# coupling that put sudo and ttyrec behind a desktop flag until they were moved
# out into base-dist.
#
# xapps-dist/ is SELF-CONTAINED: it runs its own ldd closure and stages the X
# libraries its binaries link (libX11, libXft, libXext, libXrender, libXcursor,
# libXpm, libfontconfig, libpng16) itself, rather than relying on whichever
# desktop dist is present to have staged them. That costs a duplicate in the
# BUILD TREE only - no image ever carries two desktop dists, so image size is
# unaffected - and it means this dist can be built and tested standalone.
#
# The chain is giflib -> Imlib2 -> feh, plus xfiles. Imlib2 exists only because
# both apps are Imlib2 clients.
#
# Output:
#   xapps-dist/usr/bin/feh
#   xapps-dist/usr/bin/xfiles, xfilesctl, xfilesthumb
#   xapps-dist/usr/lib64/imlib2/loaders/*.so   (dlopen'd; ldd cannot see these)
#   xapps-dist/usr/lib64/libImlib2.so*, libgif.so*
#   xapps-dist/usr/lib64/ + the ldd closure of all of the above
#   xapps-dist/usr/share/xfiles/Xresources
#
# Usage:
#   ./build_xapps.sh            # build (default)
#   ./build_xapps.sh -j 8       # 8 parallel jobs
#   ./build_xapps.sh --clean    # remove xapps-src/ xapps-prefix/ xapps-dist/
#
# Needs on the host: gcc, make, git, curl, and pkg-config modules
# x11, xext, xrender, xproto. No meson, no ninja, no fonts, no tic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
XAPPS_SRC="$SCRIPT_DIR/xapps-src"
XAPPS_PREFIX="$SCRIPT_DIR/xapps-prefix"
XAPPS_DIST="$SCRIPT_DIR/xapps-dist"

CLEAN=0
JOBS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs)  JOBS="$2"; shift 2 ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)
      sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "build_xapps.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

NPROC="$(nproc 2>/dev/null || echo 4)"
JOBS_FLAG=""
if [ -n "$JOBS" ]; then
  JOBS_FLAG="-j $JOBS"
elif command -v nproc > /dev/null 2>&1; then
  JOBS_FLAG="-j $NPROC"
fi

# --- Colors ---
if [ -t 1 ] && [ -t 2 ]; then
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_BOLD=""; C_DIM=""; C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
RED="$C_RED"; GRN="$C_GREEN"; YLW="$C_YELLOW"; DIM="$C_DIM"; RST="$C_RESET"

info()  { printf "${C_DIM}  ::${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}  [ OK ]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}  [FAIL]${C_RESET} %s\n" "$*"; exit 1; }
warn()  { printf "${C_YELLOW}  [WARN]${C_RESET} %s\n" "$*" >&2; }
header(){ printf "\n${C_BOLD}${C_CYAN}:: %s${C_RESET}\n" "*"; }
die()   { fail "$@"; }

source "$SCRIPT_DIR/pins.sh"
source "$SCRIPT_DIR/build-lib.sh"

usage() {
  cat >&2 << EOF
usage: build_xapps.sh [-j|--jobs N] [--clean]

Builds the X11 GUI applications (feh, xfiles) into xapps-dist/.

  -j, --jobs N   Number of parallel jobs
  --clean        Remove xapps-src/ xapps-prefix/ xapps-dist/
EOF
}

# fetch <url> <dest> [pin-key] - download unless already present.
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

# --- Versions ---------------------------------------------------------------
#
# GIFLIB_VER / IMLIB2_REF / FEH_REF / XFILES_REPO are all pinned in pins.lock;
# these are only the names the tarballs unpack under.

# giflib lives on SourceForge, whose download URLs are redirect chains that
# break often. The Debian pool carries the verbatim upstream tarball and
# resolves reliably.
GIFLIB_VER="5.2.2"
GIFLIB_URL="http://deb.debian.org/debian/pool/main/g/giflib/giflib_${GIFLIB_VER}.orig.tar.gz"

# Imlib2 has no reachable release directory (git.enlightenment.org answers "Not
# found"; the freedesktop gitlab is behind an anti-bot challenge), so it is a
# git clone at a pinned commit like xfiles and libXft.
IMLIB2_REPO="https://github.com/gijsbers/imlib2.git"
IMLIB2_REF="fc333014c37b7ad9534e5e50c4df12964a1b84f7"   # 1.12.7, 2026-09-03
IMLIB2_SRC="$XAPPS_SRC/imlib2"
# Only the formats this image actually shows. The host HAS libtiff and libwebp,
# so without an explicit --without-* Imlib2 would quietly build TIFF and WebP
# loaders we would then have to carry.
IMLIB2_LOADERS_KEEP="gif jpeg png"

# feh's Makefile takes flags, not configure options. curl=0 and xinerama=0 are
# the defaults that would otherwise drag in libcurl and libXinerama for features
# (fetching https images, multi-monitor) that mean nothing here. help=1 compiles
# the keybind reference INTO the binary, which matters because this image ships
# no man pages and no `man`.
FEH_REF="3.13.1"
FEH_URL="https://codeload.github.com/derf/feh/tar.gz/refs/tags/${FEH_REF}"
FEH_MAKE_FLAGS="curl=0 xinerama=0 exif=0 magic=0 install_fonts=0 help=1"

# xfiles has no usable tagged releases - the pin is deliberately past v1.1.1,
# carrying scrollmode, pgup/pgdown and focus fixes this image was built against.
XFILES_REPO="https://github.com/phillbush/xfiles.git"
XFILES_SRC="$XAPPS_SRC/xfiles"

# xmenu is xfiles' sibling: same author, same plain-Xlib style. It DOES tag
# (v4.6.1), but the pin sits 51 commits past it, for the reasons in pins.lock.
XMENU_REPO="https://github.com/phillbush/xmenu.git"
XMENU_SRC="$XAPPS_SRC/xmenu"

# libXpm exists for one reason: xfiles draws its icons in XPM and links libXpm for
# it. Every graphical X11 file manager wants a real toolkit - Thunar and pcmanfm
# want GTK, qfm wants Qt, xfe wants FOX - and rlOS has none of those, because one
# would cost more than every other tool in this script combined. XFiles is the
# exception: it is plain Xlib, so libXpm is the only library it needs that this
# image does not otherwise stage.
XPM_VER="3.5.19"
XPM_URL="http://deb.debian.org/debian/pool/main/libx/libxpm/libxpm_${XPM_VER}.orig.tar.gz"

# libXft is not xfiles-specific - build_x11.sh builds it for i3bar and mlterm
# too - but xfiles links it, and this dist is self-contained by design, so it is
# built here as well. That is a duplicated build in the BUILD TREE only: no
# image ever carries both dists, so nothing is shipped twice.
LIBXFT_REPO="https://gitlab.freedesktop.org/xorg/lib/libXft.git"
LIBXFT_TAG="libXft-2.3.9"

header "Host prerequisites"
MISSING=""
# meson and ninja are needed only for libXft.
for tool in gcc make git curl pkg-config meson ninja; do
  command -v "$tool" > /dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  fail "missing host tools:$MISSING"
  fail "on Gentoo: emerge sys-devel/gcc sys-devel/make dev-vcs/git net/curl"
  fail "                dev-build/meson dev-build/ninja"
  exit 1
fi
ok "gcc make git curl pkg-config meson ninja present"

# Only the X11 modules these apps need. Not the whole XPC_MODS list build_x11.sh
# wants - no xkbcomp, no xkeyboard-config, neither of which any of these link.
# freetype2 is here for libXft, which needs its headers.
XAPPS_PC_MODS="x11 xext xrender xproto freetype2 fontconfig"
MISSING_PC=""
for m in $XAPPS_PC_MODS; do
  pkg-config --exists "$m" 2>/dev/null || MISSING_PC="$MISSING_PC $m"
done
if [ -n "$MISSING_PC" ]; then
  fail "missing pkg-config modules:$MISSING_PC"
  fail "on Gentoo: emerge x11-libs/libX11 x11-libs/libXext media-libs/libpng"
  fail "                media-libs/freetype media-libs/fontconfig x11-proto/xorg-proto"
  exit 1
fi
ok "X pkg-config modules present"

if [ "$CLEAN" = "1" ]; then
  header "Cleaning"
  info "removing xapps-src/ xapps-prefix/ xapps-dist/"
  rm -rf "$XAPPS_SRC" "$XAPPS_PREFIX" "$XAPPS_DIST"
  ok "cleaned"
  exit 0
fi

mkdir -p "$XAPPS_SRC" "$XAPPS_PREFIX"
rm -rf "$XAPPS_DIST"
mkdir -p "$XAPPS_DIST/usr/bin" "$XAPPS_DIST/usr/lib64" \
         "$XAPPS_DIST/usr/share" "$XAPPS_DIST/bin"

# ---------------------------------------------------------------------------
header "giflib ${GIFLIB_VER} (host has none; Imlib2's GIF loader needs it)"
# No configure, and that is not a mistake on this script's part: giflib 5.x
# dropped autotools for a hand-written Makefile. There is no ./configure in the
# tarball. PREFIX/LIBDIR/DESTDIR are all overridable on the make command line, so
# prefix=/usr libdir=/usr/lib64 works without any configure step.
#
# Only install-lib is invoked, deliberately. Plain `make install` would also
# install gif2rgb, giftext, giftext2gif, gifbuild and giffix - five utilities for
# authoring GIFs that a media *viewer* has no use for.
fetch "$GIFLIB_URL" "$XAPPS_SRC/giflib-${GIFLIB_VER}.tar.gz" "giflib"
if [ ! -d "$XAPPS_SRC/giflib-${GIFLIB_VER}" ]; then
  tar -xf "$XAPPS_SRC/giflib-${GIFLIB_VER}.tar.gz" -C "$XAPPS_SRC" \
    || { fail "giflib did not unpack"; exit 1; }
fi
GIFLIB_SRC="$XAPPS_SRC/giflib-${GIFLIB_VER}"
[ -f "$GIFLIB_SRC/Makefile" ] || { fail "giflib has no Makefile at $GIFLIB_SRC"; exit 1; }
# Only the two library targets, never `all`. `all` also descends into doc/,
# which regenerates the HTML docs and the logo by running ImageMagick's
# `convert` on the source tree - not installed here, and not something a library
# this image only dlopens needs. SOEXTENSION is resolved rather than assumed so
# the target name is right even if a future giflib changes it.
#
# BOTH libgif.a and libgif.so are built, and libgif.a is not optional: install-lib
# installs both, and giflib's Makefile has them as two independent targets. The
# predecessor of this code built only the .so and then ran install-lib, which
# fails with `install: cannot stat 'libgif.a'` on a tree that has never had a
# full build in it - it only appeared to work because the cached source tree
# happened to carry a stale libgif.a from an earlier run.
GIFLIB_SOEXT="$(make -pn -C "$GIFLIB_SRC" 2>/dev/null | grep -m1 '^SOEXTENSION ' | sed 's/.*=[[:space:]]*//' || true)"
[ -n "$GIFLIB_SOEXT" ] || GIFLIB_SOEXT="so"
run_quiet make -C "$GIFLIB_SRC" -j"$JOBS" libgif.a "libgif.${GIFLIB_SOEXT}" LIBDIR=/usr/lib64
DESTDIR="$XAPPS_PREFIX" run_quiet make -C "$GIFLIB_SRC" install-lib \
  PREFIX=/usr LIBDIR=/usr/lib64
GIFLIB_LIB="$(find "$XAPPS_PREFIX" -name 'libgif.so*' 2>/dev/null | head -1 || true)"
[ -n "$GIFLIB_LIB" ] || { fail "libgif not built - Imlib2's GIF loader will be dropped"; exit 1; }
# The .so is what Imlib2's GIF loader links against, so a static-only libgif.a
# would leave GIF silently unloadable.
case "$GIFLIB_LIB" in *.a) fail "only libgif.a was built; Imlib2's GIF loader needs the shared object"; exit 1 ;; esac
ok "libgif built ($(du -h "$GIFLIB_LIB" | cut -f1))"

header "Imlib2 ${IMLIB2_REF:0:7} 1.12.7 (png + jpeg + gif only, no tools)"
# Why the exclusions are explicit rather than incidental: the host HAS libtiff
# and libwebp installed, so an Imlib2 configured on its own would quietly build
# TIFF and WebP loaders we then have to carry. --without-* is the only way to say
# "not this time" to a library that is present.
#
# --disable-progs drops the imlib2-apps command line tools (identify, imfill,
# imconvert): nothing in the guest calls them and they are a few hundred KB.
#
# --disable-text is deliberately NOT passed. An earlier version of this comment
# claimed feh draws its own text through Xft and has no use for Imlib2's text
# engine, so text was disabled to save the freetype dependency. That was wrong:
# feh calls imlib_load_font() and imlib_add_path_to_font_path() for its thumbnail
# mode, and with --disable-text the link fails on both - undefined references to
# exactly those two symbols, in thumbnail.o and options.o. Imlib2's text engine
# is freetype-based, so freetype has to come along; feh and xfiles both link
# freetype-backed Xft anyway, so the marginal cost is nil.
#
# --disable-filters drops the filter modules, which feh does not use.
IMLIB2_WITHOUT=""
for fmt in avif heif j2k jxl ps raw svg tiff webp y4m; do
  IMLIB2_WITHOUT="$IMLIB2_WITHOUT --without-$fmt"
done
# Pinned-commit clone: shallow, and verified against the pin rather than trusted
# to be the right tree.
if [ ! -d "$IMLIB2_SRC/.git" ]; then
  info "cloning Imlib2 (pinned commit)"
  git clone --quiet "$IMLIB2_REPO" "$IMLIB2_SRC" || { fail "Imlib2 clone failed"; exit 1; }
fi
if ! git -C "$IMLIB2_SRC" cat-file -e "${IMLIB2_REF}^{commit}" 2>/dev/null; then
  git -C "$IMLIB2_SRC" fetch --quiet origin || { fail "Imlib2 fetch failed"; exit 1; }
fi
git -C "$IMLIB2_SRC" checkout --quiet "$IMLIB2_REF" \
  || { fail "Imlib2 has no commit $IMLIB2_REF - the pin is wrong or was rewritten"; exit 1; }
# Confirm we got the tree we pinned, and that it is the tree that builds. The
# broken Debian tarballs fail at configure with a missing data/Makefile.in, and
# checking for data/Makefile.am here turns that into an error that names its own
# cause instead of surfacing 90 lines later as a config.status complaint.
IMLIB2_SHA="$(git -C "$IMLIB2_SRC" rev-parse HEAD)"
[ "$IMLIB2_SHA" = "$IMLIB2_REF" ] || { fail "Imlib2 at $IMLIB2_SHA, expected $IMLIB2_REF"; exit 1; }
[ -f "$IMLIB2_SRC/data/Makefile.am" ] \
  || { fail "Imlib2 tree has no data/Makefile.am - this is a stripped tarball, not the git tree"; exit 1; }
info "Imlib2 at ${IMLIB2_SHA:0:7} ($(git -C "$IMLIB2_SRC" log -1 --format=%cd --date=short))"
info "configure (loaders kept: $IMLIB2_LOADERS_KEEP)"
# shellcheck disable=SC2086
( cd "$IMLIB2_SRC" && run_quiet ./configure --prefix=/usr --libdir=/usr/lib64 \
    --disable-static --enable-shared \
    --disable-progs --disable-filters --disable-doc-build \
    $IMLIB2_WITHOUT )
run_quiet make -C "$IMLIB2_SRC" -j"$JOBS"
DESTDIR="$XAPPS_PREFIX" run_quiet make -C "$IMLIB2_SRC" install
IMLIB2_LIB="$(find "$XAPPS_PREFIX" -name 'libImlib2.so*' -type f 2>/dev/null | head -1 || true)"
[ -n "$IMLIB2_LIB" ] || { fail "libImlib2 not built - feh cannot work without it"; exit 1; }
ok "libImlib2 built ($(du -h "$IMLIB2_LIB" | cut -f1))"

# Imlib2 installs its loaders to $(libdir)/imlib2/loaders, and resolves that path
# from the PACKAGE_LIB_DIR it was compiled with - so with libdir=/usr/lib64 the
# guest path is /usr/lib64/imlib2/loaders and NO environment variable is needed.
# Verify that assumption now rather than discovering it as a runtime "unsupported
# format" error: if the loaders are not exactly there, nothing will ever load a
# PNG and no link error will explain why.
IMLIB2_LOADER_DIR="$XAPPS_PREFIX/usr/lib64/imlib2/loaders"
[ -d "$IMLIB2_LOADER_DIR" ] \
  || { fail "Imlib2 loaders not at $IMLIB2_LOADER_DIR - feh would load no formats at all"; exit 1; }
N_LOADERS=0
for fmt in $IMLIB2_LOADERS_KEEP; do
  # gif/jpeg/png ship as <name>.so once libtool's .la wrappers are dropped.
  if [ ! -f "$IMLIB2_LOADER_DIR/$fmt.so" ]; then
    fail "Imlib2 $fmt loader missing from $IMLIB2_LOADER_DIR"
  fi
  N_LOADERS=$((N_LOADERS + 1))
done
# Anything we meant to exclude and are staging anyway is a bug in the exclusion
# list above, not a harmless extra.
for fmt in avif heif j2k jxl tiff webp svg; do
  if [ -f "$IMLIB2_LOADER_DIR/$fmt.so" ]; then
    fail "Imlib2 $fmt loader was built despite --without-$fmt - exclusion list is wrong"
  fi
done
ok "loaders present: $(cd "$IMLIB2_LOADER_DIR" && ls *.so | tr '\n' ' ')"

header "feh ${FEH_REF} (image viewer, minimal)"
# feh is plain make. The host's libpng satisfies its -lpng; libImlib2 comes from
# xapps-prefix via LD_LIBRARY_PATH, and CFLAGS/LDFLAGS point the headers at it.
fetch "$FEH_URL" "$XAPPS_SRC/feh.tar.gz" "feh"
if [ ! -d "$XAPPS_SRC/feh" ]; then
  # derf/feh's tarball unpacks as feh-<ref>, which is "feh-master" when built
  # from a branch and "feh-3.13.1" from a tag. Strip it so the path stays stable
  # across either.
  rm -rf "$XAPPS_SRC/feh"
  mkdir -p "$XAPPS_SRC/feh"
  tar -xf "$XAPPS_SRC/feh.tar.gz" -C "$XAPPS_SRC/feh" --strip-components=1 \
    || { fail "feh did not unpack"; exit 1; }
fi
FEH_SRC="$XAPPS_SRC/feh"
[ -f "$FEH_SRC/Makefile" ] || { fail "feh has no Makefile at $FEH_SRC"; exit 1; }
# CFLAGS goes in the ENVIRONMENT, not on the make command line, and that
# distinction is load-bearing. config.mk does `CFLAGS += -DPACKAGE=...` and
# `LDLIBS += -lm -lpng -lX11 -lImlib2`, and config.mk contains no `override`
# directives - so in GNU make, assigning either variable on the command line
# discards the makefile's `+=` entirely. Passing CFLAGS= on the command line
# produced feh failing to compile with "expected ')' before string constant" at
# snprintf(str, ..., PACKAGE " index - %d thumbnails"), because PACKAGE was
# never defined. Passing LDLIBS= the same way would have dropped -lImlib2 and
# broken the link instead.
#
# An environment assignment is a weaker binding than a makefile one, so `?=` and
# `+=` both behave correctly. The -L for our xapps-prefix copy of Imlib2 goes in
# LDFLAGS, which src/Makefile's link rule (${CC} ${LDFLAGS} ${CFLAGS} -o ... )
# uses and config.mk never assigns.
# shellcheck disable=SC2086
CFLAGS="-g -Os -Wall -I$XAPPS_PREFIX/usr/include" \
run_quiet make -C "$FEH_SRC" -j"$JOBS" $FEH_MAKE_FLAGS \
  PREFIX=/usr DESTDIR="$XAPPS_PREFIX" \
  LDFLAGS="-L$XAPPS_PREFIX/usr/lib64"
DESTDIR="$XAPPS_PREFIX" run_quiet make -C "$FEH_SRC" install $FEH_MAKE_FLAGS \
  PREFIX=/usr DESTDIR="$XAPPS_PREFIX"
FEH_BIN="$XAPPS_PREFIX/usr/bin/feh"
[ -x "$FEH_BIN" ] || { fail "feh not built"; exit 1; }
install -m 0755 "$FEH_BIN" "$XAPPS_DIST/usr/bin/feh"
# No DT_NEEDED may point at the build machine. feh is linked against our
# xapps-prefix copy of Imlib2, and baking that absolute path in would stage a
# nonsense /home/... tree in the initramfs.
if objdump -p "$XAPPS_DIST/usr/bin/feh" | grep -q "$XAPPS_PREFIX"; then
  fail "feh has a DT_NEEDED pointing into $XAPPS_PREFIX - host path leaked"
fi
ok "feh staged ($(du -h "$XAPPS_DIST/usr/bin/feh" | cut -f1), $FEH_MAKE_FLAGS)"

header "libXft ${LIBXFT_TAG} (xfiles links it; the host has none)"
# Everything else libXft needs is already on the host: freetype2 and fontconfig
# headers, libX11, libXrender, xproto. This is a git clone because there is no
# tarball URL for it that resolves; the web UI is behind an anti-bot challenge but
# git-over-HTTPS is not.
#
# Duplicated from build_x11.sh on purpose, so that xapps-dist does not depend on
# a prefix another script owns. See XPM_VER's comment for why a file manager
# that is plain Xlib still needs a library built from source here.
if [ ! -d "$XAPPS_SRC/libXft/.git" ]; then
  info "cloning $LIBXFT_REPO"
  git clone --depth 1 --branch "$LIBXFT_TAG" "$LIBXFT_REPO" "$XAPPS_SRC/libXft" \
    || { fail "libXft clone failed"; exit 1; }
fi
info "libXft at $(git -C "$XAPPS_SRC/libXft" rev-parse --short HEAD)"
( cd "$XAPPS_SRC/libXft" && \
  run_quiet meson setup build --prefix=/usr --libdir=/usr/lib64 \
    -Ddefault_library=shared && \
  run_quiet ninja -C build $JOBS_FLAG && \
  DESTDIR="$XAPPS_PREFIX" run_quiet ninja -C build install )
XFT_LIB="$(find "$XAPPS_PREFIX" -name 'libXft.so*' -type f 2>/dev/null | head -1)"
[ -n "$XFT_LIB" ] || { fail "libXft.so not built - xfiles will not link"; exit 1; }
ok "libXft built ($(du -h "$XFT_LIB" | cut -f1))"

header "libXpm ${XPM_VER} (xfiles' icons)"
# libXpm is in no reachable upstream home either: x.org has no
# individual/libXpm directory, and every tarball mirror a probe for
# libXpm-3.5.19.tar.gz finds nothing. The Debian pool carries the verbatim
# upstream tarball.
fetch "$XPM_URL" "$XAPPS_SRC/libXpm-${XPM_VER}.tar.gz" "libXpm"
if [ ! -d "$XAPPS_SRC/libXpm-${XPM_VER}" ]; then
  # The tarball's own top-level directory is already libXpm-<ver>, so no
  # --strip-components is needed here.
  tar -xf "$XAPPS_SRC/libXpm-${XPM_VER}.tar.gz" -C "$XAPPS_SRC" \
    || { fail "libXpm did not unpack"; exit 1; }
fi
XPM_SRC="$XAPPS_SRC/libXpm-${XPM_VER}"
# configure MUST be run with the source directory as the working directory. This
# is not tidiness - libXpm's configure writes its Makefiles relative to the CWD,
# so invoking it by absolute path from the parent exits 0, prints nothing at all,
# and leaves no Makefile behind. The failure then surfaces one line later as
# "make: *** No targets specified and no makefile found", which points at make
# and not at the real cause. The `( cd ... && ... )` subshell is what makes it
# work.
( cd "$XPM_SRC" && run_quiet ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static )
[ -f "$XPM_SRC/Makefile" ] || { fail "libXpm configure produced no Makefile in $XPM_SRC"; exit 1; }
run_quiet make -C "$XPM_SRC" -j"$JOBS"
DESTDIR="$XAPPS_PREFIX" run_quiet make -C "$XPM_SRC" install
XPM_LIB="$(find "$XAPPS_PREFIX" -name 'libXpm.so*' -type f 2>/dev/null | head -1 || true)"
[ -n "$XPM_LIB" ] || { fail "libXpm not built - XFiles cannot link"; exit 1; }
ok "libXpm built ($(du -h "$XPM_LIB" | cut -f1))"

header "XFiles $(pins_get xfiles.sha | cut -c1-12) (file manager, plain Xlib)"
# POSIX make with brace expansion, no configure. Its Makefile hardcodes
# PROG_LDFLAGS as "-lfontconfig -lXft -lX11 -lXext -lXcursor -lXrender -lXpm
# -lpthread", so the prefix's libraries are found via -L in LDFLAGS and the
# headers via CPPFLAGS rather than by editing the Makefile.
pins_clone "$XFILES_REPO" "$XFILES_SRC" xfiles
info "XFiles at $(git -C "$XFILES_SRC" rev-parse --short HEAD) ($(git -C "$XFILES_SRC" log -1 --format=%cd --date=short))"
run_quiet make -C "$XFILES_SRC" -j"$JOBS" \
  CPPFLAGS="-I$XAPPS_PREFIX/usr/include -I/usr/include/freetype2" \
  LDFLAGS="-L$XAPPS_PREFIX/usr/lib64"
[ -x "$XFILES_SRC/xfiles" ] || { fail "XFiles did not build"; exit 1; }
install -m 0755 "$XFILES_SRC/xfiles" "$XAPPS_DIST/usr/bin/xfiles"
# xfilesctl is not optional decoration: XFiles performs no file operations of its
# own, it execs xfilesctl with the selected paths. Ship it or the file manager
# draws icons and then does nothing when you press Delete.
for s in xfilesctl xfilesthumb; do
  [ -f "$XFILES_SRC/examples/$s" ] || { fail "XFiles: examples/$s missing - file operations would not work"; exit 1; }
  install -m 0755 "$XFILES_SRC/examples/$s" "$XAPPS_DIST/usr/bin/$s"
done
# The X resource file is what gives it our colours and font instead of its
# defaults, so it is staged as data rather than left in the source tree.
mkdir -p "$XAPPS_DIST/usr/share/xfiles"
if [ -f "$XFILES_SRC/examples/Xresources" ]; then
  install -m 0644 "$XFILES_SRC/examples/Xresources" "$XAPPS_DIST/usr/share/xfiles/Xresources"
fi
ok "xfiles staged ($(du -h "$XAPPS_DIST/usr/bin/xfiles" | cut -f1)) + xfilesctl/xfilesthumb"

header "XMenu $(pins_get xmenu.sha | cut -c1-12) (application menu, plain Xlib)"
# Reads a menu specification on stdin, shows it, and prints the chosen entry to
# stdout - the same read-in/write-out shape as everything else by this author.
# The spec is generated by etc-rlos/scripts/xmenu.sh, which is staged by the
# glob in assemble-rootfs.sh alongside the atom-* helpers.
#
# Plain make with no configure, like xfiles. Its link line hardcodes
# -lfontconfig -lXft -lX11 -lXinerama -lXrender -lImlib2, so the prefix's
# libraries come from -L in LDFLAGS and the headers from CPPFLAGS.
#
# -lImlib2 resolves against our own prefix - which is the reason xapps.sh builds
# Imlib2 in the first place now that both feh and xmenu want it. -lXinerama is
# the only thing xmenu needs that nothing else here does; it is a host library,
# so the closure below picks it up and stages it like any other.
pins_clone "$XMENU_REPO" "$XMENU_SRC" xmenu
info "XMenu at $(git -C "$XMENU_SRC" rev-parse --short HEAD) ($(git -C "$XMENU_SRC" log -1 --format=%cd --date=short))"
run_quiet make -C "$XMENU_SRC" -j"$JOBS" \
  CPPFLAGS="-I$XAPPS_PREFIX/usr/include -I/usr/include/freetype2" \
  LDFLAGS="-L$XAPPS_PREFIX/usr/lib64"
[ -x "$XMENU_SRC/xmenu" ] || { fail "XMenu did not build"; exit 1; }
install -m 0755 "$XMENU_SRC/xmenu" "$XAPPS_DIST/usr/bin/xmenu"
# Same host-path check feh gets: a DT_NEEDED pointing into xapps-prefix would
# stage a nonsense /home/... tree in the initramfs.
if objdump -p "$XAPPS_DIST/usr/bin/xmenu" | grep -q "$XAPPS_PREFIX"; then
  fail "xmenu has a DT_NEEDED pointing into $XAPPS_PREFIX - host path leaked"
fi
# The X resource file gives it our font and colours instead of its defaults, and
# xmenu reads Xresources at runtime, so it has to be staged as data.
if [ -f "$XMENU_SRC/examples/Xresources" ]; then
  mkdir -p "$XAPPS_DIST/usr/share/xmenu"
  install -m 0644 "$XMENU_SRC/examples/Xresources" "$XAPPS_DIST/usr/share/xmenu/Xresources"
  info "staged usr/share/xmenu/Xresources"
else
  warn "xmenu ships no examples/Xresources - it will use its built-in defaults"
fi
ok "xmenu staged ($(du -h "$XAPPS_DIST/usr/bin/xmenu" | cut -f1))"

# ---------------------------------------------------------------------------
header "Staging Imlib2 + its dlopen'd loaders"
install -m 0755 "$IMLIB2_LIB" "$XAPPS_DIST/usr/lib64/$(basename "$IMLIB2_LIB")"
install -m 0644 "$GIFLIB_LIB" "$XAPPS_DIST/usr/lib64/$(basename "$GIFLIB_LIB")"
# libXft and libXpm are built into our prefix, not found by the host's loader, so
# ldd below never visits them - exactly the situation the EXTRA_LIB hand-add
# further down exists for. Their sonames go in as real copies, since that is what
# xfiles' DT_NEEDED names.
for lib in "$XFT_LIB" "$XPM_LIB"; do
  [ -n "$lib" ] || continue
  cp -n "$lib" "$XAPPS_DIST/usr/lib64/$(basename "$lib")" 2>/dev/null || true
  soname="$(objdump -p "$lib" | sed -n 's/^ *SONAME *//p' | head -1 || true)"
  if [ -n "$soname" ] && [ ! -f "$XAPPS_DIST/usr/lib64/$soname" ]; then
    install -m 0644 "$lib" "$XAPPS_DIST/usr/lib64/$soname"
    info "staged $soname (built here, not on the host's loader path)"
  fi
done
# Also place the SONAME, as a real copy rather than a symlink. Every loader
# links libImlib2.so.1, and libImlib2.so.1.12.7 alone would not satisfy it - the
# loader looks up the soname exactly. The closure would flatten one in later, but
# relying on that ordering is how the loader-dependency walk below spent its first
# run reporting libImlib2.so.1 missing for all eighteen loaders when the finished
# tree in fact had it. Copied, not symlinked, because a symlink into a cpio needs
# its target present and the closure's own copies are files for the same reason.
IMLIB2_SONAME="$(objdump -p "$IMLIB2_LIB" | sed -n 's/^ *SONAME *//p' | head -1 || true)"
if [ -n "$IMLIB2_SONAME" ] && [ "$IMLIB2_SONAME" != "$(basename "$IMLIB2_LIB")" ]; then
  if [ ! -f "$XAPPS_DIST/usr/lib64/$IMLIB2_SONAME" ]; then
    install -m 0755 "$IMLIB2_LIB" "$XAPPS_DIST/usr/lib64/$IMLIB2_SONAME"
    info "staged soname $IMLIB2_SONAME (loaders link this, not the versioned file)"
  fi
fi
# gif and the base loaders (bmp, ico, tga, xbm, xpm, pnm, argb) are compiled
# unconditionally by Imlib2's Makefile.am, so stage every .so the build produced
# rather than an allowlist - an allowlist would silently drop bmp and ico, which
# are free, and would need editing every time a base loader is added.
mkdir -p "$XAPPS_DIST/usr/lib64/imlib2/loaders"
for l in "$IMLIB2_LOADER_DIR"/*.so; do
  [ -f "$l" ] || continue
  install -m 0644 "$l" "$XAPPS_DIST/usr/lib64/imlib2/loaders/$(basename "$l")"
done
N_STAGED_LOADERS="$(find "$XAPPS_DIST/usr/lib64/imlib2/loaders" -name '*.so' | wc -l)"
[ "$N_STAGED_LOADERS" -gt 0 ] || { fail "no Imlib2 loaders staged - feh would load nothing"; exit 1; }
# The exact failure this block exists to prevent: a libImlib2 present but no
# loaders beside it loads no formats whatsoever, and reports it as an
# unsupported-format error rather than as a missing module.
for fmt in $IMLIB2_LOADERS_KEEP; do
  [ -f "$XAPPS_DIST/usr/lib64/imlib2/loaders/$fmt.so" ] \
    || { fail "loader $fmt.so not staged - $fmt would fail to load at runtime"; exit 1; }
done
ok "libImlib2 + $N_STAGED_LOADERS loaders staged (feh needs: $IMLIB2_LOADERS_KEEP)"

# ---------------------------------------------------------------------------
header "ldd closure"
# The guest has no ld.so.cache, so every shared object must be a real file in
# /usr/lib64 (a default loader search dir). Flatten the closure of everything
# we ship - binaries AND modules, since a module can need something a binary
# does not. Keep the absolute path too, so a dlopen of an absolute path works.
#
# This closure is what makes xapps-dist self-contained: feh and xfiles link
# libX11, libXft, libXext, libXrender, libXcursor, libXpm, libfontconfig and
# libpng16, and none of those are assumed to come from a desktop dist.
CLOSURE_SEEN=""
collect() {
  local target="$1" lib
  for lib in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
    case " $CLOSURE_SEEN " in *" $lib "*) continue ;; esac
    CLOSURE_SEEN="$CLOSURE_SEEN $lib"
    collect "$lib"
  done
}
ALL_ELFS="$(find "$XAPPS_DIST/usr/bin" -type f 2>/dev/null; find "$XAPPS_DIST/usr/lib64/imlib2/loaders" -name '*.so' -type f)"
for elf in $ALL_ELFS; do
  [ -f "$elf" ] || continue
  collect "$elf"
done
N_LIBS=0
for lib in $CLOSURE_SEEN; do
  [ -f "$lib" ] || continue
  # Flat into usr/lib64, which is a default loader search dir, so the guest's
  # missing ld.so.cache does not matter.
  cp -n "$lib" "$XAPPS_DIST/usr/lib64/$(basename "$lib")" 2>/dev/null || true
  # Also keep the real absolute path, but only for genuine system paths. A lib
  # that lives under a build prefix would otherwise stage a nonsense /home/...
  # tree in the initramfs.
  case "$lib" in
    /usr/*|/lib/*|/lib64/*)
      mkdir -p "$XAPPS_DIST$(dirname "$lib")"
      cp -n "$lib" "$XAPPS_DIST$lib" 2>/dev/null || true
      ;;
  esac
  N_LIBS=$((N_LIBS + 1))
done
ok "$N_LIBS shared objects in usr/lib64/ ($(du -sh "$XAPPS_DIST/usr/lib64" | cut -f1))"

# Verify the closure the way the guest will actually resolve it. The guest has
# no ld.so.cache, so the loader only searches its default dirs and a library is
# found solely by filename. ldd on the host happily resolves things from the
# host's own directories, which hides exactly the failure we care about: a
# binary whose dependency was never staged.
MISSING_LIBS=""
for elf in $ALL_ELFS; do
  [ -f "$elf" ] || continue
  for need in $(objdump -p "$elf" 2>/dev/null |
                sed -n 's/^ *NEEDED *//p'); do
    case "$need" in
      # Provided by the kernel, or by the C runtime assemble-rootfs.sh stages.
      linux-vdso*|linux-gate*|ld-linux*|libc.so.6|libm.so.6|libpthread.so.0) continue ;;
    esac
    [ -e "$XAPPS_DIST/usr/lib64/$need" ] || MISSING_LIBS="$MISSING_LIBS $need"
  done
done
MISSING_LIBS="$(printf '%s\n' $MISSING_LIBS | sort -u | grep '[^[:space:]]' | tr '\n' ' ' || true)"
if [ -n "$MISSING_LIBS" ]; then
  # Print the list BEFORE any fail() call: fail() exits, so naming the problem
  # after it is dead code, and the error ends up saying only that something is
  # missing without saying what.
  errmsg "these shared objects are needed by something we ship but are not staged:"
  printf '    %s\n' "$MISSING_LIBS"
  errmsg "the guest has no ld.so.cache, so they will not be found at runtime"
  exit 1
fi
ok "every DT_NEEDED of every shipped ELF resolves inside usr/lib64/"

# The loaders are dlopen'd, so nothing above has a DT_NEEDED edge to them and the
# closure cannot see them or what THEY link. That makes this the one place in
# this script where a missing library produces no build error at all and no
# runtime error either - just a format that quietly stops working, reported as
# "unsupported format" rather than as the missing module it actually is.
#
# So the loader's own dependencies are walked explicitly, here.
IMLIB2_LOADER_MISSING=""
for l in "$XAPPS_DIST/usr/lib64/imlib2/loaders"/*.so; do
  [ -f "$l" ] || continue
  for dep in $(objdump -p "$l" | sed -n 's/^ *NEEDED *//p'); do
    base="$(basename "$dep")"
    # Skip the interpreter line and anything that is not a bare soname.
    case "$base" in ld-*|linux-vdso*) continue ;; esac
    # Already staged by the closure (libpng, libX11 and friends are reachable
    # from feh itself), or is one of ours already placed by basename.
    [ -f "$XAPPS_DIST/usr/lib64/$base" ] && continue
    found="$(ldconfig -p 2>/dev/null | awk -v s="$base" '$1==s{print $NF; exit}' || true)"
    if [ -n "$found" ] && [ -f "$found" ]; then
      install -m 0644 "$found" "$XAPPS_DIST/usr/lib64/$base"
      info "staged $base (needed by $(basename "$l"), reachable only through dlopen)"
    else
      IMLIB2_LOADER_MISSING="$IMLIB2_LOADER_MISSING $base(of $(basename "$l"))"
    fi
  done
done
if [ -n "$IMLIB2_LOADER_MISSING" ]; then
  fail "loaders need libraries that are neither staged nor on the host:$IMLIB2_LOADER_MISSING"
fi
ok "every Imlib2 loader's own dependencies staged"

# ---------------------------------------------------------------------------
# NO RUNTIME SMOKE TEST HERE, DELIBERATELY.
#
# feh cannot be run on this host to prove it decodes anything: it is a GUI
# program, so it aborts on "cannot open display" before it reaches its loaders.
# The usual workaround is Xvfb, which is not installed here and would be a new
# host dependency for a build that otherwise needs only gcc, make and curl. So
# there is no honest runtime check to write, and a fake one would be worse than
# none.
#
# What stands in for it is above, and it is the part that actually fails in
# practice:
#
#   - the DT_NEEDED sweep, which is what catches "xfiles shipped without
#     libXpm.so.4" - the exact bug class that once took the whole X session
#     down with a loader error naming only one library;
#   - the explicit walk of every dlopen'd loader's own dependencies, since no
#     DT_NEEDED edge exists to them from any binary and a missing one produces
#     neither a build error nor a runtime error, just a format that quietly
#     stops working;
#   - the gif/jpeg/png staging assertions, which fail the build rather than
#     deferring to a user who discovers GIF is broken months later.
header "Results"
ok "xapps-dist ready ($(du -sh "$XAPPS_DIST" | cut -f1))"
info "layout:"
find "$XAPPS_DIST" -maxdepth 3 | sort | sed 's/^/         /'
echo
info "next: assemble-rootfs.sh stages xapps-dist/ whenever BACKEND != text."