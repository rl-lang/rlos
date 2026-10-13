#!/usr/bin/env bash
# build_x11.sh - vendor the X11 guest stack into x11-dist/
#
# WHY two video drivers and not one: a GPU-less machine (or firmware that only
# exports a framebuffer) is served by xf86-video-fbdev, which is enough on its
# own because DRM_EFIDRM + DRM_FBDEV_EMULATION hand us a real /dev/fb0 at
# 32bpp XRGB8888 (verified by fbtest: 1280x800, pitch 5120, 4MB, write/read
# round-trip ok). On the actual laptop hardware there is an Intel GPU, so
# i915 + modesetting is the real path and fbdev is the fallback. init.c picks
# between two complete xorg.conf templates at boot by reading the driver symlink
# under /sys/class/drm/card0/device/driver. Both drivers are staged because which
# one is right is a property of the machine, not of the build.
#
# Userspace is i3 (WM) + mlterm (terminal), no multiplexer. Both replaced
# the suckless stack (dwm/st/dvtm) and then Alacritty, none of which is still
# built or staged. Xorg is the only large piece, built with GLX/glamor/DRI off.
#
# Output is a guest-root tree in x11-dist/:
#   bin/Xorg                    the server (prefix=/usr so module paths match)
#   bin/i3 i3bar i3-msg ...     window manager and the tools to drive it
#   bin/mlterm                  the terminal i3's $term points at
#   bin/setrootcursor           themes the root cursor; see x11-drv/
#   bin/setrootbg               fills the root window with a solid colour

#   usr/lib64/xorg/modules/     fbdev_drv.so, fbdevhw.so + core video/input
#   usr/lib64/                  the ldd closure, flat (guest has no ld.so.cache)
#   usr/bin/xkbcomp             the server shells out to this at startup
#   usr/share/X11/xkb/          xkeyboard-config (a real runtime requirement)
#   usr/share/fonts/            2x JetBrainsMono Nerd Font Mono
#   usr/share/icons/            Bibata-Modern-Ice xcursor theme (as "default")
#   usr/share/terminfo/         linux + vt100 (text consoles) + mlterm +
#                               mlterm-256color + xterm-256color (tic)
#   usr/share/rlos/xorg.conf    pins the fbdev driver explicitly
#   usr/share/rlos/fonts.conf   fontconfig, maps monospace -> JetBrainsMono
#
# Only libXft is built from git; everything else is a pinned tarball or is
# copied off the host. See build_gcc.sh for the sibling convention where a
# local tree is symlinked in - that is for code you own, this is dependencies.
#
# Usage:
#   ./build_x11.sh                    # build (default)
#   ./build_x11.sh -j 8               # 8 parallel jobs
#   ./build_x11.sh --clean            # remove x11-src/ x11-prefix/ x11-dist/
#
# Needs on the host: gcc, make, meson, ninja, pkg-config, git, curl, tic,
# infocmp, patchelf, pkg-config-visible
# x11/xrender/fontconfig/freetype2/xproto/xkbcomp/xkeyboard-config, and the
# host's /usr/share/fonts/nerdfonts/ for the TTFs.
#
# mlterm is a fetched, pinned upstream tarball. It is plain Xlib (no Xt/Xaw)
# and links only libXft/fontconfig/freetype/X11, so it needs no GL and no
# dlopen'd modules once built with --disable-shared. See MLTERM_VER.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11_SRC="$SCRIPT_DIR/x11-src"
X11_PREFIX="$SCRIPT_DIR/x11-prefix"
X11_DIST="$SCRIPT_DIR/x11-dist"
CLEAN=0
JOBS=""

# --- pinned sources ---
XORG_SERVER_VER="21.1.24"
XORG_SERVER_URL="https://www.x.org/releases/individual/xserver/xorg-server-${XORG_SERVER_VER}.tar.xz"
FBDEV_VER="0.5.1"
FBDEV_URL="https://www.x.org/releases/individual/driver/xf86-video-fbdev-${FBDEV_VER}.tar.xz"
LIBXFT_REPO="https://gitlab.freedesktop.org/xorg/lib/libXft.git"
LIBXFT_TAG="libXft-2.3.9"
# Input. xorg-server 21.x removed the built-in "mouse" and "kbd" DDX drivers,
# so a server without an input driver attaches nothing and logs, per device:
#     (EE) No input driver matching `mouse'
#     (II) Falling back to input driver `libinput'
#     (EE) Failed to load module "libinput" (module does not exist, 0)
# This project first shipped its own evdev reader (x11-drv/rlos_evdev.c) to
# avoid this dependency tree. It worked under QEMU and failed twice on real
# laptop hardware, which is the point: libinput's touchpad, scroll and
# tap-to-click handling is years of work that a few hundred lines will not
# reproduce, and a bespoke driver has to be right about every device a machine
# happens to have. Cost measured on this host: 4.7MB of libraries, of which
# libc and libm already shipped. libwacom and libmtdev are optional and off.
# Note the source is the GitLab release archive, not a freedesktop.org tarball:
# www.freedesktop.org/software/libinput/ does not carry 1.31.x and answers 404.
LIBINPUT_VER="1.31.3"
LIBINPUT_URL="https://gitlab.freedesktop.org/libinput/libinput/-/archive/${LIBINPUT_VER}/libinput-${LIBINPUT_VER}.tar.gz"
LIBINPUT_DRV_VER="1.5.0"
LIBINPUT_DRV_URL="https://www.x.org/releases/individual/driver/xf86-input-libinput-${LIBINPUT_DRV_VER}.tar.xz"
# eudev: a standalone udev, no systemd. Not optional - libinput hard-requires it.
# src/path-seat.c open_restricted() resolves each device with
# udev_device_new_from_devnum() and then waits for udev_device_get_is_initialized()
# to become true, polling up to 200 times at 10ms before giving up with
#   libinput bug: udev device never initialized (/dev/input/eventN)
# "Initialized" means an entry exists in the udev database under
# /run/udev/data, and only a running udevd writes those. With no udev, libinput
# refuses to open every device, so it attaches nothing. This is also what
# populates ID_INPUT_KEYBOARD / ID_INPUT_MOUSE / ID_INPUT_TOUCHPAD, and what
# would later carry LIBINPUT_CONFIG_TAP_TO_CLICK and friends.
EUDEV_VER="3.2.15"
EUDEV_URL="https://codeload.github.com/eudev-project/eudev/tar.gz/refs/tags/v${EUDEV_VER}"

# mlterm: replaces Alacritty (which replaced st). Pinned to an upstream release
# tarball, not a git checkout: it is a small C/Xlib terminal with a stable
# configure, so there is nothing a working tree buys us.
#
# Built --disable-shared on purpose. By default mlterm dlopen()s its type
# engines (xcore/xft/cairo), ctl modules and scrollbar plugins as libtool
# modules, which would mean staging a handful of plugin .so files and hoping
# the baked module path resolves in the guest. Static builds fold all of that
# into the one binary, so the only runtime dependencies are the four libraries
# in its DT_NEEDED, all of which the guest already has (libXft is staged from
# the same x11-prefix that builds i3bar).
MLTERM_VER="3.9.1"
MLTERM_URL="https://codeload.github.com/arakiken/mlterm/tar.gz/refs/tags/rel-3_9_1"
MLTERM_SRC="$X11_SRC/mlterm-${MLTERM_VER}"

# --- image viewer: giflib -> Imlib2 -> feh -------------------------------------
# feh is an Imlib2 client, so Imlib2 has to exist first, and Imlib2's GIF loader
# needs giflib, which the host does not have. Three builds for one viewer; the
# point of each pin is below.
#
# Sources are the Debian pool rather than upstream. Imlib2 has no reachable
# GitHub home any more (git.enlightenment.org answers "Not found" for every
# path, and the freedesktop gitlab sits behind an anti-bot challenge), and the
# Debian pool carries verbatim upstream tarballs at pinned versions. Same
# bytes upstream would have shipped, from a mirror that resolves.
GIFLIB_VER="5.2.2"
GIFLIB_URL="http://deb.debian.org/debian/pool/main/g/giflib/giflib_${GIFLIB_VER}.orig.tar.gz"

# Imlib2's loaders are dlopen'd modules in $(libdir)/imlib2/loaders, NOT linked
# into libImlib2. That is why ldd will not notice them and why the staging below
# copies them by hand: forget one and the format fails at runtime with no link
# error to explain it.
#
# Source is a git clone at a PINNED COMMIT, not a tarball, and this is not a
# stylistic choice. The 1.12.6 and 1.12.4 tarballs in the Debian pool have their
# entire data/ directory stripped - no data/Makefile.in, no data/fonts, no
# data/images - while configure.ac still lists data/Makefile in AC_CONFIG_FILES
# (line 329). configure therefore dies with "cannot find input file:
# data/Makefile.in", and autoreconf cannot fix it because data/fonts/Makefile.am
# and data/images/Makefile.am are gone too. There is no upstream tarball that
# resolves from here either: git.enlightenment.org answers "Not found" for every
# path including legacy/imlib2.git, and download.enlightenment.org has no
# imlib2 release directory.
#
# So: a mirror that carries the full git tree. It is pinned to a commit rather
# than to a branch because a branch can move, and a build that silently changes
# under you is worse than one that fails. This commit is imlib2 1.12.7 - the same
# version Gentoo currently packages - and it is the tree that configures, builds,
# and honours every --without-<format> below.
IMLIB2_REPO="https://github.com/gijsbers/imlib2.git"
IMLIB2_REF="fc333014c37b7ad9534e5e50c4df12964a1b84f7"   # 1.12.7, 2026-09-03
IMLIB2_SRC="$X11_SRC/imlib2"
# Only these three, chosen deliberately: PNG and JPEG are what screen capture
# and ordinary screenshots produce, GIF is what shared terminal screenshots are.
# Everything else is excluded below, and the host has libtiff and libwebp
# installed, so without explicit --without flags Imlib2 would silently build
# TIFF and WebP loaders too.
IMLIB2_LOADERS_KEEP="gif jpeg png"

# feh's Makefile takes flags, not configure options. curl=0 and xinerama=0 are
# the defaults that would otherwise drag in libcurl and libXinerama for features
# (fetching https images, multi-monitor) that mean nothing here. help=1 compiles
# the keybind reference INTO the binary, which matters because this image ships
# no man pages and no `man`.
# Pinned to a release tag, not master: the sha256 in pins.lock is what makes
# that safe. Note this is a CHANGE from the master snapshot this image was last
# built from (see the feh note in pins.lock).
FEH_REF="3.13.1"
FEH_URL="https://codeload.github.com/derf/feh/tar.gz/refs/tags/${FEH_REF}"
FEH_MAKE_FLAGS="curl=0 xinerama=0 exif=0 magic=0 install_fonts=0 help=1"

# --- ffmpeg: screen capture (ffmpeg) and playback (ffplay) -------------------
# One build covers both halves of "record a video and then watch it", because
# ffplay - the player - ships inside the same tarball as the recorder. That is
# the whole argument for using ffmpeg here rather than a dedicated pair of
# tools: the second tool is free.
#
# x264 is GPL-2.0-or-later, so this binary is GPL. That is deliberate, not an
# oversight: rlOS already ships busybox, git, mlterm and the Linux kernel, all
# GPL-2.0, so it is already a GPL distributor and the compliance obligations are
# the same ones. Going LGPL instead would mean dropping x264 for the
# BSD-licensed libvpx and taking worse encoding quality for NO reduction in
# obligations - busybox alone would keep them. GPL is also strictly EASIER to
# comply with than LGPL, because LGPL additionally obliges you to let recipients
# relink the library.
#
# The kernel has no CONFIG_VA_API_*, so decoding is software-only. Fine for
# 1080p, not fine for 4K. Hardware decode would need a kernel rebuild.
FFMPEG_VER="9.0.2"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"

# --disable-everything, then an explicit allowlist. A default ffmpeg build is
# ~35MB of codecs for formats this image will never encounter, and the list
# below is the honest answer to "what does this image actually need": capture a
# screen, and play back what that capture produced plus the usual things a
# person downloads.
#
# COMMA-separated, not space-separated. This is not a style preference: ffmpeg's
# configure parses these as one option value, so a space-separated list matches
# nothing, prints a single "did not match anything" WARNING, and configures
# SUCCESSFULLY with every demuxer, decoder, encoder, parser, muxer and filter
# switched off. The build then produces a working-looking ffmpeg that cannot
# encode or decode anything at all. --enable-gpl, --enable-libx264 and
# --enable-sdl2 are not lists and take no commas.
FFMPEG_PROTOCOLS="file,pipe"
# xcbgrab, NOT x11grab. They are two different names for what a user types:
# libavdevice/xcbgrab.c registers .p.name = "x11grab", so the CLI is still
# `-f x11grab`, but the build-system symbol is CONFIG_XCBGRAB_INDEV. Passing
# --enable-indev=x11grab matches nothing and silently drops screen capture. It
# is XCB-based now rather than Xlib-based, which suits this image - the libxcb-*
# libraries are already staged.
FFMPEG_INDEV="xcbgrab"
FFMPEG_DEMUXERS="matroska,mov,avi,flv,mpegts,ogg,wav,aiff,mp3,image2,image2pipe,gif"
# rawvideo is not optional decoration: x11grab hands rawvideo frames to the
# encoder, so without it every capture fails with "Decoding requested, but no
# decoder found for: rawvideo". That is the one entry here that exists purely to
# serve another entry.
FFMPEG_DECODERS="rawvideo,h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,mjpeg,png,apng,gif,aac,ac3,eac3,mp3,flac,vorbis,opus,alac,pcm_s16le,pcm_u8,tta,wavpack"
FFMPEG_PARSERS="h264,hevc,av1,vp9,aac,ac3,mpegaudio,mpegvideo,h263"
FFMPEG_ENCODERS="libx264,mjpeg,png,gif"
FFMPEG_MUXERS="matroska,mp4,image2,gif,null,rawvideo"
# scale is what makes -vf scale=1920:-1 work; without it ffmpeg cannot resize a
# capture. format does pixfmt conversion.
FFMPEG_FILTERS="scale,format"

# ffplay's only output backend is SDL2. The host has SDL2 2.32.8, and rlOS
# already stages libasound.so.2 + alsa.conf, so SDL2's audio path needs nothing
# new - but SDL2 also pulls libwayland-client/-cursor/-egl and libva in as
# DT_NEEDED, and this image has none of those. All of them are staged below.
#
# Measured cost of ffplay: 12M binary + ~2.1M of SDL2/Wayland/VA libraries.
# Dropping it is the lever if that ever matters; ffmpeg alone still records.
SDL2_MAJOR="2.32.8"

# --- file manager: libXpm -> XFiles -------------------------------------------
# Every graphical X11 file manager wants a toolkit - Thunar and pcmanfm want
# GTK, qfm wants Qt, xfe wants FOX. rlOS has none of those and adding one would
# cost more than every other tool in this file combined. XFiles is the exception:
# it is plain Xlib, so the only library it needs that this image does not already
# stage is libXpm, for its XPM icons.
#
# XFiles is also MIT, like the rest of rlOS, delegates every file operation to a
# script you write, and is deliberately uncluttered - which is either exactly
# right for an i3 desktop or completely wrong, depending on taste. Its man page
# and the two helper scripts are staged with it; without xfilesctl it can draw
# icons but cannot copy, move or delete anything.
XPM_VER="3.5.19"
XPM_URL="http://deb.debian.org/debian/pool/main/libx/libxpm/libxpm_${XPM_VER}.orig.tar.gz"

# Pinned by commit in pins.lock. xfiles has no usable tagged releases - the pin
# is 100 commits past v1.1.1, carrying scrollmode, pgup/pgdown and focus fixes
# this image was built against, so the tag would be a regression.
XFILES_REPO="https://github.com/phillbush/xfiles.git"
XFILES_SRC="$X11_SRC/xfiles"

# --- i3 and the three libraries it needs that the host lacks -------------------
# The window manager. Everything else it wants is on the host
# (xcb, xcb-util*, xkbcommon, pcre2, cairo, pangocairo, glib, gobject, libev);
# these three are not installed anywhere reachable on this machine and there is
# no tarball URL for them that resolves, so they are built into x11-prefix the
# same way libXft already is below.
I3_REF="4.25"
I3_URL="https://github.com/i3/i3.git"

# yajl 2.1.0: JSON for i3's command replies (src/commands.c uses yajl_gen_*).
# Its CMakeLists.txt says CMAKE_MINIMUM_REQUIRED(VERSION 2.6), which cmake 4
# refuses outright, so it is compiled directly rather than via cmake.
YAJL_REF="2.1.0"
YAJL_URL="https://github.com/lloyd/yajl.git"

# xcb-util-xrm 1.3: X resources for i3's config parser and DPI handling
# (src/config_parser.c, libi3/dpi.c). Split out of xcb-util long ago and
# absent from the host. Its autogen.sh wants xorg-macros >= 1.16.0, another
# dependency, so the five C files are compiled directly too.
XCBXRM_URL="https://github.com/Airblader/xcb-util-xrm.git"

# libstartup-notification 0.12: D-Bus startup notification, used by i3's core
# (src/startup.c, src/handlers.c). Unconditional from i3 4.19 on. Built with
# autotools, which works fine - unlike the two above it needs no xorg-macros.
LIBSN_URL="https://github.com/bbidulock/startup-notification.git"

BIBATA_TAG="v2.0.7"
BIBATA_THEME="Bibata-Modern-Ice"
BIBATA_URL="https://github.com/ful1e5/Bibata_Cursor/releases/download/${BIBATA_TAG}/${BIBATA_THEME}.tar.xz"
FONT_FILES=("JetBrainsMonoNerdFontMono-Regular.ttf" "JetBrainsMonoNerdFontMono-Bold.ttf"
            "JetBrainsMonoNerdFontMono-Italic.ttf" "JetBrainsMonoNerdFontMono-BoldItalic.ttf")
HOST_FONT_DIR="/usr/share/fonts/nerdfonts"

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

# Sourced after the colour helpers so pins_verify can report failures through
# fail() rather than raw stderr. See pins.lock for what is pinned and why.
source "$SCRIPT_DIR/pins.sh"

usage() {
  printf "\n"
  printf "${C_BOLD}Usage:${C_RESET} ${C_CYAN}build_x11.sh${C_RESET} [OPTIONS]\n"
  printf "\n"
  printf "Vendor the X11 guest stack (Xorg + fbdev DDX + i3 + mlterm) into\n"
  printf "guest-root ${C_BOLD}x11-dist/${C_RESET}.\n"
  printf "\n"
  printf "${C_BOLD}Options:${C_RESET}\n"
  printf "  ${C_YELLOW}-j, --jobs${C_RESET} ${C_CYAN}N${C_RESET}       Number of parallel jobs\n"
  printf "  ${C_RED}--clean${C_RESET}            Remove x11-src/ x11-prefix/ x11-dist/\n"
  printf "  ${C_BLUE}-h, --help${C_RESET}         Show this help\n"
  printf "\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs)  JOBS="$2"; shift 2 ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          fail "unknown option: $1"; exit 1 ;;
  esac
done

NPROC="$(nproc 2>/dev/null || echo 4)"
JOBS_FLAG=""
if [ -n "$JOBS" ]; then
  JOBS_FLAG="-j $JOBS"
elif command -v nproc > /dev/null 2>&1; then
  JOBS_FLAG="-j $NPROC"
fi

header "Host prerequisites"
MISSING=""
for tool in gcc make meson ninja pkg-config git curl tic infocmp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    MISSING="$MISSING $tool"
  fi
done
if [ -n "$MISSING" ]; then
  fail "missing host tools:$MISSING"
  exit 1
fi
ok "build tools present"
info "tic: $(tic -V 2>&1 | head -1)"

# X pkg-config modules. libXft is deliberately NOT in this list: we build it
# below, because the host has freetype/fontconfig headers but not libXft.
XPC_MODS="x11 xrender fontconfig freetype2 xproto xkbcomp xkeyboard-config"
MISSING_PC=""
for m in $XPC_MODS; do
  pkg-config --exists "$m" 2>/dev/null || MISSING_PC="$MISSING_PC $m"
done
if [ -n "$MISSING_PC" ]; then
  fail "missing pkg-config modules:$MISSING_PC"
  fail "on Gentoo: emerge x11-libs/libX11 x11-libs/libXrender media-libs/fontconfig"
  fail "                media-libs/freetype x11-proto/xorg-proto x11-misc/xkbcomp"
  fail "                x11-misc/xkeyboard-config"
  exit 1
fi
ok "X pkg-config modules present"
info "xkeyboard-config: $(pkg-config --modversion xkeyboard-config)"

for f in "${FONT_FILES[@]}"; do
  if [ ! -f "$HOST_FONT_DIR/$f" ]; then
    fail "host font missing: $HOST_FONT_DIR/$f"
    fail "the Nerd Fonts are on the host already - keep them there, or point"
    fail "HOST_FONT_DIR in this script at wherever they live"
    exit 1
  fi
done
ok "host fonts present (${FONT_FILES[0]}, ${FONT_FILES[1]})"

if [ "$CLEAN" = "1" ]; then
  header "Cleaning"
  info "removing x11-src/ x11-prefix/ x11-dist/"
  rm -rf "$X11_SRC" "$X11_PREFIX" "$X11_DIST"
  ok "cleaned"
fi

mkdir -p "$X11_SRC" "$X11_PREFIX"

# fetch <url> <dest> [pin-key] - download unless already present
#
# With a pin-key, the file is verified against pins.lock whether it was just
# downloaded or already cached. Verifying a cache hit matters as much as
# verifying a fresh download: a truncated or edited tarball in x11-src/ would
# otherwise be reused silently, and the build would fail hours later in a
# compiler with a message that points nowhere near the real cause.
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

header "Xorg server ${XORG_SERVER_VER} (GLX/glamor/DRI off)"
fetch "$XORG_SERVER_URL" "$X11_SRC/xorg-server-${XORG_SERVER_VER}.tar.xz" "xorg-server"
if [ ! -d "$X11_SRC/xorg-server-${XORG_SERVER_VER}" ]; then
  tar -xf "$X11_SRC/xorg-server-${XORG_SERVER_VER}.tar.xz" -C "$X11_SRC"
fi
XORG_BUILD="$X11_SRC/xorg-server-${XORG_SERVER_VER}/build"
rm -rf "$XORG_BUILD"
# prefix=/usr so the baked module path is /usr/lib/xorg/modules, which is
# where we stage it - dlopen uses an absolute path so ld.so.cache is irrelevant.
# Everything graphics-accelerated is off: no GLX, no glamor, no DRI1/2/3.
info "meson setup (xorg only, no xvfb/xephyr/xnest, no GL)"
# Option names verified against this release's meson_options.txt: SELinux is
# `xselinux`, logind is `systemd_logind`. XvMC is off because it needs GLX.
# udev AND udev_kms must both be off: config_odev_probe() calls
# config_udev_odev_probe() under `#if defined(CONFIG_UDEV_KMS)` but that
# function is only declared under `#ifdef CONFIG_UDEV` in
# config/config-backends.h, so udev=false with the default udev_kms=true
# fails to compile with an implicit declaration.
# shellcheck disable=SC2086
meson setup "$XORG_BUILD" "$X11_SRC/xorg-server-${XORG_SERVER_VER}" \
  -Dprefix=/usr \
  -Dxorg=true -Dxvfb=false -Dxephyr=false -Dxnest=false \
  -Dxwin=false -Dxquartz=false \
  -Dglx=false -Dglamor=false -Dxvmc=false \
  -Ddri1=false -Ddri2=false -Ddri3=false \
  -Ddocs=false -Ddevel-docs=false -Ddocs-pdf=false \
  -Dsecure-rpc=false -Dpciaccess=true -Ddrm=true \
  -Dudev=false -Dudev_kms=false -Dxselinux=false \
  -Dsystemd_logind=false -Dlibunwind=false \
  -Dxkb_dir=/usr/share/X11/xkb > /dev/null
run_quiet ninja -C "$XORG_BUILD" $JOBS_FLAG
DESTDIR="$X11_SRC/xorg-pkg" run_quiet ninja -C "$XORG_BUILD" install
ok "Xorg built"
XORG_BIN="$X11_SRC/xorg-pkg/usr/bin/Xorg"
[ -x "$XORG_BIN" ] || { fail "Xorg binary missing after build"; exit 1; }
info "$(du -h "$XORG_BIN" | cut -f1)  $XORG_BIN"

header "xf86-video-fbdev ${FBDEV_VER} (the fbdev DDX)"
fetch "$FBDEV_URL" "$X11_SRC/xf86-video-fbdev-${FBDEV_VER}.tar.xz" "xf86-video-fbdev"
if [ ! -d "$X11_SRC/xf86-video-fbdev-${FBDEV_VER}" ]; then
  tar -xf "$X11_SRC/xf86-video-fbdev-${FBDEV_VER}.tar.xz" -C "$X11_SRC"
fi
FBDEV_SRC="$X11_SRC/xf86-video-fbdev-${FBDEV_VER}"
# Out-of-tree driver build against the DESTDIR-installed server.
#
# Two things to get right:
#   1. xorg-server.pc bakes prefix=/usr, so -I/usr/include/xorg and
#      -L/usr/lib64 point at the HOST, not at the tree we just installed.
#      Rewrite the variables to the staged paths.
#   2. xorg-macros.pc does not exist on the host and the server's meson build
#      does not install one, but the fbdev driver requires it in
#      PKG_CHECK_MODULES. It is only a pkg-config existence marker - the
#      m4 macros are already baked into the tarball's shipped aclocal.m4
#      (XORG_PROG_RAWCPP, XORG_MANPAGE_SECTIONS and friends are defined
#      there), so a stub is enough.
XORG_PC="$X11_SRC/xorg-pc"
rm -rf "$XORG_PC" && mkdir -p "$XORG_PC"
sed -e "s|^libdir=.*|libdir=$X11_SRC/xorg-pkg/usr/lib64|" \
    -e "s|^includedir=.*|includedir=$X11_SRC/xorg-pkg/usr/include|" \
    -e "s|^sdkdir=.*|sdkdir=$X11_SRC/xorg-pkg/usr/include/xorg|" \
    -e "s|^datarootdir=.*|datarootdir=$X11_SRC/xorg-pkg/usr/share|" \
    "$X11_SRC/xorg-pkg/usr/lib64/pkgconfig/xorg-server.pc" > "$XORG_PC/xorg-server.pc"
cat > "$XORG_PC/xorg-macros.pc" << 'PCEOF'
prefix=/usr
Name: xorg-macros
Description: X.Org build macros (existence marker for out-of-tree drivers)
Version: 1.1.6
PCEOF
# shellcheck disable=SC2086
( cd "$FBDEV_SRC" && \
  PKG_CONFIG_PATH="$XORG_PC:${PKG_CONFIG_PATH:-}" \
  run_quiet ./configure --prefix=/usr --libdir=/usr/lib64 && \
  run_quiet make $JOBS_FLAG && \
  run_quiet make DESTDIR="$X11_SRC/xorg-pkg" install )
ok "fbdev DDX built"
[ -f "$X11_SRC/xorg-pkg/usr/lib64/xorg/modules/drivers/fbdev_drv.so" ] \
  || { fail "fbdev_drv.so not installed - X11 on fbdev will not work"; exit 1; }
ok "fbdev_drv.so present"

header "libXft ${LIBXFT_TAG} (the only piece the host lacks)"
# Everything else libXft needs is already on the host: freetype2 and
# fontconfig headers, libX11, libXrender, xproto. This is a git clone because
# there is no tarball URL for it that resolves; the web UI is behind an
# anti-bot challenge but git-over-HTTPS is not.
if [ ! -d "$X11_SRC/libXft/.git" ]; then
  info "cloning $LIBXFT_REPO"
  git clone --depth 1 --branch "$LIBXFT_TAG" "$LIBXFT_REPO" "$X11_SRC/libXft" \
    || { fail "libXft clone failed"; exit 1; }
fi
info "libXft at $(cd "$X11_SRC/libXft" && git rev-parse --short HEAD)"
( cd "$X11_SRC/libXft" && \
  run_quiet meson setup build --prefix=/usr --libdir=/usr/lib64 \
    -Ddefault_library=shared && \
  run_quiet ninja -C build $JOBS_FLAG && \
  DESTDIR="$X11_PREFIX" run_quiet ninja -C build install )
XFT_LIB="$(find "$X11_PREFIX" -name 'libXft.so*' -type f 2>/dev/null | head -1)"
[ -n "$XFT_LIB" ] || { fail "libXft.so not built - i3bar and mlterm will fall back"; fail "to X core bitmap fonts, and the JetBrainsMono TTF does nothing"; exit 1; }
ok "libXft built ($(du -h "$XFT_LIB" | cut -f1))"

# i3bar and mlterm must link -lXft, which does not exist on the host linker
# looks. LD_LIBRARY_PATH is used instead of an rpath so no unusable path gets
# baked into the binaries: at runtime the guest loader finds libXft.so.2 in
# /usr/lib64, which is a default search directory, so no rpath is needed.
export LD_LIBRARY_PATH="$X11_PREFIX/usr/lib64:${LD_LIBRARY_PATH:-}"

header "i3 dependencies (yajl, xcb-util-xrm, libstartup-notification)"
# i3 needs three libraries that are not installed on this host and have no
# tarball URL that resolves. They go into X11_PREFIX so i3 can link them, and
# the guest closure flattens them into /usr/lib64 by soname afterwards.
#
# SONAME MATTERS and is easy to get wrong: gcc -shared does not set one, and a
# library with no SONAME makes the linker record its full path in DT_NEEDED.
# That bakes /home/crimson/dev/rl/rlos/x11-prefix/usr/lib64/... into the binary,
# which does not exist in the guest, so i3 would fail to start there with no
# clue why. Hence the explicit -Wl,-soname on both hand-built libraries.

# --- yajl ---
if [ ! -d "$X11_SRC/yajl/.git" ]; then
  info "cloning yajl"
  git clone --depth 1 --branch "$YAJL_REF" "$YAJL_URL" "$X11_SRC/yajl" \
    || { fail "yajl clone failed"; exit 1; }
fi
# yajl's headers include each other as <yajl/foo.h> but live flat in src/api,
# so stage them under a yajl/ subdirectory.
mkdir -p "$X11_SRC/yajl/build-include/yajl"
cp "$X11_SRC/yajl/src/api/"*.h "$X11_SRC/yajl/build-include/yajl/"
# Only four of the six headers in src/api are checked in. yajl_version.h is
# generated from yajl_version.h.cmake, and yajl_config.h is not in the repo at
# all - nothing includes it, so it does not need to exist. src/yajl_version.c
# does need yajl_version.h, so generate it from the template with the version
# this build is actually pinned to.
sed -e 's/${YAJL_MAJOR}/2/' -e 's/${YAJL_MINOR}/1/' -e 's/${YAJL_MICRO}/0/' \
  "$X11_SRC/yajl/src/api/yajl_version.h.cmake" > "$X11_SRC/yajl/build-include/yajl/yajl_version.h"
grep -q 'YAJL_MAJOR 2' "$X11_SRC/yajl/build-include/yajl/yajl_version.h" \
  || { fail "yajl_version.h was not generated correctly"; exit 1; }
run_quiet gcc -shared -fPIC -O2 -I "$X11_SRC/yajl/build-include" -I "$X11_SRC/yajl/src" \
  -Wl,-soname,libyajl.so.2 \
  -o "$X11_PREFIX/usr/lib64/libyajl.so.2.1.0" \
  "$X11_SRC/yajl/src/yajl.c" "$X11_SRC/yajl/src/yajl_alloc.c" \
  "$X11_SRC/yajl/src/yajl_buf.c" "$X11_SRC/yajl/src/yajl_encode.c" \
  "$X11_SRC/yajl/src/yajl_gen.c" "$X11_SRC/yajl/src/yajl_lex.c" \
  "$X11_SRC/yajl/src/yajl_parser.c" "$X11_SRC/yajl/src/yajl_tree.c" \
  "$X11_SRC/yajl/src/yajl_version.c"
ln -sf libyajl.so.2.1.0 "$X11_PREFIX/usr/lib64/libyajl.so.2"
ln -sf libyajl.so.2 "$X11_PREFIX/usr/lib64/libyajl.so"
mkdir -p "$X11_PREFIX/usr/include/yajl"
cp "$X11_SRC/yajl/build-include/yajl/"*.h "$X11_PREFIX/usr/include/yajl/"
cat > "$X11_PREFIX/usr/lib64/pkgconfig/yajl.pc" << 'PCEOF'
prefix=${X11_PREFIX}
exec_prefix=${prefix}
libdir=${prefix}/usr/lib64
includedir=${prefix}/usr/include

Name: YAJL
Description: Yet Another JSON Library
Version: 2.1.0
Libs: -L${libdir} -lyajl
Cflags: -I${includedir}
PCEOF
ok "yajl built"

# --- xcb-util-xrm ---
# Pinned commit. Not --depth 1: a shallow clone only carries the branch tip, so
# it cannot check out an arbitrary SHA. pins_clone clones full history and
# fetches the pinned commit if needed, then asserts HEAD matches the pin.
pins_clone "$XCBXRM_URL" "$X11_SRC/xcb-util-xrm" xcb-util-xrm
run_quiet gcc -shared -fPIC -O2 -I "$X11_SRC/xcb-util-xrm/include" -I "$X11_SRC/xcb-util-xrm/src" \
  $(pkg-config --cflags xcb xcb-aux) -Wl,-soname,libxcb-xrm.so.0 \
  -o "$X11_PREFIX/usr/lib64/libxcb-xrm.so.0.0.0" "$X11_SRC/xcb-util-xrm/src/"*.c \
  $(pkg-config --libs xcb)
ln -sf libxcb-xrm.so.0.0.0 "$X11_PREFIX/usr/lib64/libxcb-xrm.so.0"
ln -sf libxcb-xrm.so.0 "$X11_PREFIX/usr/lib64/libxcb-xrm.so"
mkdir -p "$X11_PREFIX/usr/include/xcb"
cp "$X11_SRC/xcb-util-xrm/include/xcb_xrm.h" "$X11_PREFIX/usr/include/xcb/"
cat > "$X11_PREFIX/usr/lib64/pkgconfig/xcb-xrm.pc" << 'PCEOF'
prefix=${X11_PREFIX}
exec_prefix=${prefix}
libdir=${prefix}/usr/lib64
includedir=${prefix}/usr/include

Name: XCB XRM library
Description: XCB X resource manager utility functions
Version: 1.3
Requires: xcb
Requires.private: xcb-aux
Libs: -L${libdir} -lxcb-xrm
Cflags: -I${includedir}
PCEOF
ok "xcb-util-xrm built"

# --- libstartup-notification ---
# The one of the three that builds with autotools, because unlike the others it
# needs no xorg-macros.
# Pinned commit, and --recursive is preserved on both the clone and the fetch:
# this repo has submodules, so a shallow non-recursive clone cannot build, and
# a fetch that skips them leaves the working tree without them too.
pins_clone "$LIBSN_URL" "$X11_SRC/libstartup-notification" libstartup-notification --recursive
( cd "$X11_SRC/libstartup-notification" && \
  run_quiet ./autogen.sh --prefix="$X11_PREFIX" --libdir="$X11_PREFIX/usr/lib64" && \
  run_quiet make -j"$(nproc)" && \
  run_quiet make install )
[ -e "$X11_PREFIX/usr/lib64/libstartup-notification-1.so.0" ] \
  || { fail "libstartup-notification did not install"; exit 1; }
ok "libstartup-notification built"

# Kept for the staging step below: the guest loader searches by SONAME in
# /usr/lib64, and these live in the build prefix, so they have to be copied in
# by name the same way libXft is.
I3_EXTRA_LIBS=""
for l in "$X11_PREFIX/usr/lib64/libyajl.so.2" \
         "$X11_PREFIX/usr/lib64/libxcb-xrm.so.0" \
         "$X11_PREFIX/usr/lib64/libstartup-notification-1.so.0"; do
  [ -e "$l" ] || { fail "expected $l from the i3 dependency builds"; exit 1; }
  I3_EXTRA_LIBS="$I3_EXTRA_LIBS $l"
done

export PKG_CONFIG_PATH="$X11_PREFIX/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
for pc in yajl xcb-xrm libstartup-notification-1.0; do
  pkg-config --exists "$pc" || { fail "pkg-config cannot resolve $pc"; exit 1; }
done
ok "i3 dependencies resolve via pkg-config"


header "i3 ${I3_REF}"
if [ ! -d "$X11_SRC/i3-${I3_REF}/.git" ]; then
  info "cloning i3"
  git clone --depth 1 --branch "$I3_REF" "$I3_URL" "$X11_SRC/i3-${I3_REF}" \
    || { fail "i3 clone failed"; exit 1; }
fi
I3_SRC="$X11_SRC/i3-${I3_REF}"
info "i3 at $(cd "$I3_SRC" && git rev-parse --short HEAD)"
# CFLAGS supplies -I for xcb_xrm.h. i3's meson.build declares the xrm dependency
# for the i3 binary but not for the libi3 static library that actually compiles
# libi3/dpi.c, so meson never adds the include path. On a normal system the
# header sits in /usr/include/xcb and is found by the default search path,
# which is why upstream never notices. Here it is one directory deeper, so the
# path has to be injected - patching i3 itself would be worse than an env var.
rm -rf "$I3_SRC/build"
( cd "$I3_SRC" && \
  CFLAGS="-I$X11_PREFIX/usr/include" \
  LDFLAGS="-L$X11_PREFIX/usr/lib64 -Wl,-rpath-link,$X11_PREFIX/usr/lib64" \
  run_quiet meson setup build --prefix=/usr --libdir=/usr/lib64 && \
  run_quiet ninja -C build -j"$(nproc)" && \
  DESTDIR="$X11_SRC/i3-pkg" run_quiet ninja -C build install )

# Stage the INSTALLED binary, not the one in the build tree.
#
# meson's default rpath behaviour is the whole problem here: build_rpath picks up
# the absolute path of any external shared library, which for i3's yajl,
# xcb-util-xrm and libstartup-notification is $X11_PREFIX/usr/lib64 - a path on
# THIS machine. install_rpath defaults to empty, so the installed binary carries
# no absolute path at all and resolves those three libs through the default
# loader path, which in the guest is /usr/lib64 where the closure already put
# them.
#
# Staging the build-tree binary instead meant DT_RUNPATH=[/home/crimson/dev/rl/
# rlos/x11-prefix/usr/lib64] was baked into five shipped binaries, and because
# DT_RUNPATH is searched BEFORE the default directories, that leaked path was
# not merely cosmetic - it was the path i3 was actually loading its libraries
# from at runtime.
I3_PKG_BIN="$X11_SRC/i3-pkg/usr/bin"
[ -d "$I3_PKG_BIN" ] || fail "i3 DESTDIR install produced nothing at $I3_PKG_BIN"
# No shipped i3 binary may name this machine's filesystem.
#
# Two distinct ways that happens, and the original guard only caught the first:
#
#   DT_NEEDED with an absolute path - a library was linked without a SONAME, so
#     the path went into DT_NEEDED. Caught below.
#   DT_RUNPATH / DT_RPATH with an absolute path - ordinary meson build_rpath. NOT
#     caught originally, which is how /home/crimson/dev/rl/rlos/x11-prefix ended
#     up recreated inside the guest by the closure pass in build_initramfs.sh.
#     Checked now.
#
# Both are asserted over every i3 binary rather than just i3, because i3bar and
# i3-msg link the same three libraries and leak identically.
for i3bin in i3 i3bar i3-msg i3-input i3-nagbar; do
  dpath="$I3_PKG_BIN/$i3bin"
  [ -x "$dpath" ] || fail "installed $i3bin missing"
  if readelf -d "$dpath" 2>/dev/null | grep -E 'NEEDED|RPATH|RUNPATH' | grep -q "$X11_PREFIX"; then
    fail "$i3bin still references this machine's build prefix ($X11_PREFIX)"
    fail "  run: readelf -d $dpath | grep -E 'RPATH|RUNPATH|NEEDED'"
    exit 1
  fi
done
ok "no i3 binary references the build prefix (DT_NEEDED, RPATH and RUNPATH all clean)"
ok "i3 built ($(du -h "$I3_SRC/build/i3" | cut -f1)), i3bar and i3-msg too"

header "mlterm ${MLTERM_VER}"
fetch "$MLTERM_URL" "$X11_SRC/mlterm-${MLTERM_VER}.tar.gz" "mlterm"
# codeload names the top dir after the TAG (<name>-<tag>), not the version:
# rel-3_9_1 unpacks as mlterm-rel-3_9_1. Strip it into $MLTERM_SRC instead of
# guessing, so the version can change without this silently unpacking a tree
# the rest of the script does not look at.
if [ ! -d "$MLTERM_SRC" ]; then
  mkdir -p "$MLTERM_SRC"
  tar -xf "$X11_SRC/mlterm-${MLTERM_VER}.tar.gz" -C "$MLTERM_SRC" --strip-components=1
fi
[ -f "$MLTERM_SRC/configure" ] || { fail "mlterm did not unpack"; exit 1; }

# --disable-shared folds the type engines, ctl modules and scrollbar plugins
# into the binary (see the MLTERM_VER comment near the top). Xft is the only
# type engine worth building: cairo is off in this Xorg and would pull a whole
# dependency tree, and the xcore engine alone cannot use the JetBrainsMono TTF
# that fontconfig is configured to hand out. Everything else optional is
# disabled explicitly so a host package appearing later (fribidi, libssh2, an
# input method) cannot silently change what the binary links.
#
# -Wno-incompatible-pointer-types: mlterm 3.9.1 predates GCC 14, which promoted
# this diagnostic to an error, and it fires in baselib/bl_conf.c's hash macro.
# Without it the build stops in baselib before it reaches any terminal code.
#
# The injected -I/-L are the same trick i3 needs just above: xft.pc was
# installed into x11-prefix with DESTDIR but bakes prefix=/usr, so pkg-config
# reports the host's include and lib dirs, where libXft does not exist.
( cd "$MLTERM_SRC" && \
  PKG_CONFIG_PATH="$X11_PREFIX/usr/lib64/pkgconfig" \
  run_quiet ./configure \
    --prefix=/usr --libdir=/usr/lib64 \
    --disable-shared \
    --with-gui=xlib --with-type-engines=xcore,xft \
    --without-tools \
    --disable-fribidi --disable-otl --disable-ssh2 \
    --disable-uim --disable-iiimf --disable-m17nlib --disable-ibus \
    --disable-fcitx --disable-scim --disable-canna --disable-wnn --disable-skk \
    CFLAGS="-O2 -Wno-incompatible-pointer-types -Wno-int-conversion -I$X11_PREFIX/usr/include" \
    LDFLAGS="-L$X11_PREFIX/usr/lib64" && \
  run_quiet make -j"$(nproc)" )
MLTERM_BIN="$MLTERM_SRC/main/mlterm"
[ -x "$MLTERM_BIN" ] || { fail "mlterm binary missing at $MLTERM_BIN"; exit 1; }
# Same SONAME gate as i3: an absolute DT_NEEDED means something linked without
# one, and that path does not exist in the guest.
if readelf -d "$MLTERM_BIN" | grep NEEDED | grep -q "$SCRIPT_DIR"; then
  fail "mlterm has a DT_NEEDED pointing at a host path - a dependency was linked"
  fail "without a SONAME"
  exit 1
fi
# ~2MB, but this goes into a gzipped read-only initramfs where every MB costs
# real boot time.
run_quiet strip "$MLTERM_BIN"
ok "mlterm built ($(du -h "$MLTERM_BIN" | cut -f1), stripped)"

# mlterm deliberately has NO dlopen'd runtime libraries here: --disable-shared
# compiled the type engine, ctl and scrollbar code straight into the binary, so
# its DT_NEEDED is the complete runtime closure. The generic dlopen scan at the
# bottom of this script still runs over every shipped ELF and would catch a
# future build that changes that (e.g. an accidental --enable-shared).

# --- help.rl must not drift from the real keymaps -----------------------------
# help.rl is written by hand and the bindings live in etc-rlos/i3.config (plus
# the terminal's own compiled-in/default keys), so the two can disagree: rename
# a binding in i3.config and the cheat sheet keeps telling people the old key.
#
# This used to check dwm/st/dvtm's config.h files. Those are gone, and the check
# matters MORE now, not less: i3's compiled-in defaults are a real fallback that
# help.rl never mentions, and the whole point of the i3 config is that it is
# explicit about what it binds. So this verifies every combination help.rl
# prints is bound in the config we actually ship.
#
# Deliberately not exhaustive. A wrong check that fails the build is worse than
# none, so this covers the keys a newcomer presses first, and it checks them
# against the staged config rather than against a second copy of the truth.
python3 - "$SCRIPT_DIR/etc-rlos/i3.config" "$SCRIPT_DIR/rl_programs/help.rl" << 'HELPEOF'
import re, sys

i3_cfg, help_rl = sys.argv[1:3]
i3 = open(i3_cfg).read()
help_txt = open(help_rl).read()

problems = []

def check(desc, ok, hint=''):
    if not ok:
        problems.append('%s%s' % (desc, (' - ' + hint) if hint else ''))

def bound(keysym, action):
    """True if i3.config binds keysym, under some modifier combination, to
    action.

    i3 syntax is `bindsym [$mod+][Shift+][Ctrl+][Alt+]KEY ACTION args`, with
    $mod defined by `set $mod Mod4`. The rows in help.rl are written in terms of
    Super because that is what $mod expands to. The modifier prefix is matched
    loosely on purpose: this check is here to catch a binding being RENAMED or
    DELETED while help.rl still advertises it, not to police which modifiers
    are legal on which action. Pinning the exact modifier chain would also mean
    re-stating i3.config in a second place, which is the drift this gate exists
    to prevent.

    re.escape on both halves, not literals: "Return" must not be read as a
    carriage-return escape and a one-letter keysym must not swallow the
    character after it.
    """
    mods = r'(?:\$mod\+)?(?:(?:Shift|Ctrl|Alt|Super)\+)*'
    pat = (r'^\s*bindsym\s+' + mods + re.escape(keysym) +
           r'\b[^\n]*\b' + re.escape(action) + r'\b')
    return re.search(pat, i3, re.M) is not None

# The help binding itself, which is the one that matters most: if this drifts,
# nothing else in the sheet is reachable.
check('i3: Super+Shift+? does not run help.rl',
      re.search(r'bindsym\s+\$mod\+Shift\+question\b.*help\.rl', i3) is not None,
      'help.rl is bound by this key but i3.config does not')

# $mod must actually be Mod4 (Super) or every row below says "Super" wrongly.
check('i3: $mod is not Mod4 as help.rl claims',
      re.search(r'^\s*set\s+\$mod\s+Mod4\b', i3, re.M) is not None,
      'help.rl says the modifier is Super')

# The window-manager rows, in the order help.rl prints them.
for keysym, action, what in [
        ('Return',       'exec',              'terminal'),
        ('h',            'focus',             'focus left'),
        ('j',            'focus',             'focus down'),
        ('k',            'focus',             'focus up'),
        ('l',            'focus',             'focus right'),
        ('space',        'floating',          'floating toggle'),
        ('d',            'layout',            'split'),
        ('s',            'layout',            'stacking'),
        ('w',            'layout',            'tabbed'),
        ('f',            'fullscreen',        'fullscreen'),
        ('c',            'reload',            'reload'),
        ('e',            'restart',           'restart'),
        ('q',            'kill',              'kill'),
        ('Left',         'workspace',         'previous workspace'),
        ('Right',        'workspace',         'next workspace')]:
    check('i3: %s (%s) is not bound' % (keysym, what), bound(keysym, action))

# Every workspace digit help.rl mentions must exist as a binding.
for digit in range(1, 10):
    check('i3: Super+%d is not bound' % digit,
          re.search(r'^\s*bindsym\s+\$mod\+%d\s+workspace\s+%d\b' % (digit, digit),
                    i3, re.M) is not None)

# The terminal rows are NOT checked here, and that is a real gap rather than an
# oversight: mlterm's default keys are compiled in (the key table in
# uitoolkit/), and the config we stage does not restate them. Asserting against
# mlterm's C source would mean parsing its key table for no gain. The defaults
# are verified by reading that tree; if they change, help.rl is where it shows.

if problems:
    print('  help.rl has drifted from i3.config:')
    for p in problems:
        print('         - %s' % p)
    sys.exit(1)
print('  help.rl matches i3.config (%d bindings checked)' % 27)
HELPEOF

header "Staging xkbcomp + xkeyboard-config"
# Downloaded and built rather than copied. The host has xkeyboard-config.pc and
# an xkb-config-root variable, but /usr/share/X11/xkb is 4K of EMPTY directories
# - the data package is not actually installed. xkbcomp and the rules data are
# a hard runtime requirement of the server, so this cannot be skipped.
#
# It has to be built, not just unpacked: rules/ ships as XML plus .part source
# files and the .lst rule lists are generated at build time. No release from
# 2.38 to 2.48 ships them prebuilt. The generator is scripts/registry.py, and
# xkbcli is only pulled in by the non-latin-layouts-list option, which is off
# by default - so a plain meson build needs nothing the host lacks.
# Where the host keeps compose files. Used only as a data source; nothing from
# the host is copied into the guest except this read-only data tree.
HOST_XKB_LOCALE_DIR="/usr/share/X11/locale"
XKB_VER="2.48"
XKB_URL="https://www.x.org/releases/individual/data/xkeyboard-config/xkeyboard-config-${XKB_VER}.tar.xz"
command -v xkbcomp > /dev/null 2>&1 || { fail "xkbcomp not on host"; exit 1; }
fetch "$XKB_URL" "$X11_SRC/xkeyboard-config-${XKB_VER}.tar.xz" "xkeyboard-config"
XKB_TREE="$X11_SRC/xkeyboard-config-${XKB_VER}"
if [ ! -f "$XKB_TREE/meson.build" ]; then
  tar -xf "$X11_SRC/xkeyboard-config-${XKB_VER}.tar.xz" -C "$X11_SRC"
fi
[ -f "$XKB_TREE/meson.build" ] || { fail "xkeyboard-config did not unpack"; exit 1; }
XKB_BUILD="$XKB_TREE/build"
rm -rf "$XKB_BUILD"
run_quiet meson setup "$XKB_BUILD" "$XKB_TREE" \
  -Dprefix=/usr -Dnls=false -Dcompat-rules=false -Dnon-latin-layouts-list=false
run_quiet ninja -C "$XKB_BUILD" $JOBS_FLAG
DESTDIR="$X11_SRC/xkb-pkg" run_quiet ninja -C "$XKB_BUILD" install
# It installs share/xkeyboard-config-<major>/ (major only - "2", not "2.48")
# plus an absolute symlink at share/X11/xkb pointing there. Stage the real
# contents so there is no dangling symlink in the initramfs, and glob for the
# dir rather than assuming the version string.
XKB_DATA="$(find "$X11_SRC/xkb-pkg/usr/share" -maxdepth 1 -type d -name 'xkeyboard-config-*' | head -1)"
[ -n "$XKB_DATA" ] || { fail "xkeyboard-config data dir missing after install"; exit 1; }
[ -f "$XKB_DATA/rules/evdev.lst" ] \
  || { fail "no rules/evdev.lst - the keyboard will not work"; exit 1; }
info "xkeyboard-config ${XKB_VER} built ($(du -sh "$XKB_DATA" | cut -f1))"
ok "rules generated: $(ls "$XKB_DATA/rules"/*.lst 2>/dev/null | wc -l) .lst files (incl. evdev.lst)"

header "Assembling guest tree"
rm -rf "$X11_DIST"
# NB: the meson build puts modules in /usr/lib64/xorg/modules, so the
# server's baked module path is /usr/lib64/xorg/modules - stage them there,
# not under usr/lib. dlopen uses an absolute path, so ld.so.cache is irrelevant.
mkdir -p "$X11_DIST/bin" "$X11_DIST/usr/bin" "$X11_DIST/usr/lib64/xorg/modules" \
         "$X11_DIST/usr/lib64" "$X11_DIST/usr/share/fonts" \
         "$X11_DIST/usr/share/icons" "$X11_DIST/usr/share/terminfo" \
         "$X11_DIST/usr/share/X11/xkb" "$X11_DIST/usr/share/rlos"

cp "$XORG_BIN" "$X11_DIST/bin/Xorg"
# i3 and the tools you need to drive and debug it. i3bar is a separate binary
# that the "bar" block in the config execs; i3-msg is how config changes get
# made at runtime and how status can be queried.
for i3bin in i3 i3bar i3-msg i3-input i3-nagbar; do
  if [ ! -x "$I3_PKG_BIN/$i3bin" ]; then
    fail "installed i3 is missing $i3bin (looked in $I3_PKG_BIN)"
    exit 1
  fi
  cp "$I3_PKG_BIN/$i3bin" "$X11_DIST/bin/$i3bin"
done
# The terminal i3's $term points at.
cp "$MLTERM_BIN" "$X11_DIST/bin/mlterm"
strip "$X11_DIST"/bin/* 2>/dev/null || true

# mlterm's system config. The binary's SYSCONFDIR is /usr/etc (the default
# ${prefix}/etc, not /etc), so that is where it looks for mlterm/main and
# mlterm/aafont. This is not optional cosmetic setup:
#
#   - termtype upstream default is "xterm", which would overwrite the TERM
#     init sets for its shell and drop the guest onto an entry that describes
#     fewer capabilities than the terminal emits.
#   - type_engine's compiled default here is xcore (core X bitmap fonts), and
#     the guest stages a TTF and no bitmap font path, so xcore cannot draw at
#     all. xft is the engine this build was compiled with and the one fontconfig
#     can feed.
#   - use_aafont selects the aafont (anti-aliased) font file; with it unset
#     mlterm reads the xcore font file instead.
mkdir -p "$X11_DIST/usr/etc/mlterm"
cat > "$X11_DIST/usr/etc/mlterm/main" << 'MLTERMEOF'
# Staged by build_x11.sh - do not edit in place.
#
# Tokyo Night Moon. The desktop is deliberately DARKER than the terminal: see
# etc/i3.config for the layering (bar #16161e, desktop #1a1b26, window #24273b).
# The window being the lightest surface is what makes a borderless terminal read
# as a window instead of a hole in the desktop.
termtype = mlterm-256color
type_engine = xft
use_aafont = true
# Force the fontconfig engine even if aafont were somehow not used, so a
# bitmap-font fallback can never happen in a guest that ships no bitmap fonts.
use_anti_alias = true
# 16 is mlterm's own default; the earlier 12 was a mistake and looked tiny.
fontsize = 16
# 10000 lines is plenty for a debugging session and costs nothing until used -
# mlterm allocates the scrollback as it is filled, not up front.
scrollback_lines = 10000
# Colours. mlterm resolves these through XParseColor (uitoolkit/xlib/ui_color.c),
# which is why "#rrggbb" works here and not just a colour name.
#
#   bg #24273b is Moon's background, and is deliberately LIGHTER than the #1a1b26
#      desktop behind it, so the window has a visible edge with borders off.
#   fg #cad3f5 is Moon's foreground.
#   cursor #7dcfff is the same accent the i3 bar uses for the focused workspace,
#      so the caret and the bar highlight are the one colour.
bg_color = #24273b
fg_color = #cad3f5
cursor_fg_color = #24273b
cursor_bg_color = #7dcfff
# Bold and italic are real font faces here, not synthetic: build_x11.sh stages
# JetBrainsMonoNerdFontMono-{Italic,BoldItalic}.ttf alongside Regular and Bold.
# Without those two files these keys would still work, but Xft would draw a
# slanted synthetic oblique instead of the typeface's own italic.
use_bold_font = true
use_italic_font = true
# No `scrollbar`: the bar is already the tallest thing on screen and a second
# always-visible scrollbar competes with the text for the right edge.
scrollbar = false
# Deliberately NOT set: alpha (needs a 32-bit ARGB visual AND a compositor -
# this image has neither, so it would be an inert line that looks like it works)
# and border_width (i3 sets border none on every window, so a 2px mlterm border
# would make the terminal the only framed window in the session).
MLTERMEOF
cat > "$X11_DIST/usr/etc/mlterm/aafont" << 'MLTERMEOF'
# Staged by build_x11.sh - the one family the guest ships. fontconfig's
# monospace/sans-serif aliases in etc/fonts/fonts.conf point here too.
#
# Both keys are given. ui_font_config.c stores a DEFAULT entry separately and
# falls back to it for any charset without its own line, but naming the Unicode
# charset explicitly as well removes any doubt about which line an ASCII cell
# in a UTF-8 session actually resolves through.
DEFAULT = JetBrainsMono Nerd Font Mono
ISO10646_UCS4_1 = JetBrainsMono Nerd Font Mono
MLTERMEOF

# Xorg modules: the fbdev DDX plus whatever the server dlopens at runtime.
# Copy the whole modules tree rather than a hand-picked list - a missing
# auxiliary module is a startup failure that is painful to diagnose later.
if [ -d "$X11_SRC/xorg-pkg/usr/lib64/xorg/modules" ]; then
  cp -a "$X11_SRC/xorg-pkg/usr/lib64/xorg/modules/." "$X11_DIST/usr/lib64/xorg/modules/"
fi
info "modules: $(find "$X11_DIST/usr/lib64/xorg/modules" -name '*.so' | wc -l) .so files"

# --- input: libinput + xf86-input-libinput ---
# See the pin comments above for why this replaced a bespoke evdev driver.
#
# libwacom, mtdev and lua-plugins are switched off deliberately. All three are
# optional in libinput's meson build, none is a dependency this guest uses, and
# each is a whole extra runtime library: wacom for tablets, mtdev for legacy
# multitouch protocol A, and the Lua plugin support otherwise links liblua into
# libinput.so.10 itself. Switching them off is the difference between a
# four-library closure and a nine-library one.
header "libinput ${LIBINPUT_VER}"
fetch "$LIBINPUT_URL" "$X11_SRC/libinput-${LIBINPUT_VER}.tar.gz" "libinput"
if [ ! -d "$X11_SRC/libinput-${LIBINPUT_VER}" ]; then
  tar -xf "$X11_SRC/libinput-${LIBINPUT_VER}.tar.gz" -C "$X11_SRC"
fi
LIBINPUT_SRC="$X11_SRC/libinput-${LIBINPUT_VER}"
( cd "$LIBINPUT_SRC" && \
  run_quiet meson setup build --prefix=/usr --libdir=/usr/lib64 \
    -Ddefault_library=shared \
    -Dtests=false -Ddocumentation=false -Ddebug-gui=false \
    -Dlibwacom=false -Dmtdev=false -Dlua-plugins=disabled && \
  run_quiet ninja -C build $JOBS_FLAG && \
  DESTDIR="$X11_PREFIX" run_quiet ninja -C build install )
LIBINPUT_LIB="$(find "$X11_PREFIX" -name 'libinput.so*' -type f 2>/dev/null | head -1)"
[ -n "$LIBINPUT_LIB" ] || { fail "libinput.so not built - there is no input driver"; exit 1; }
ok "libinput built ($(du -h "$LIBINPUT_LIB" | cut -f1))"

header "eudev ${EUDEV_VER} (required by libinput)"
# Order matters: libinput is unusable until something populates /run/udev/data,
# so eudev is built before the driver and run by init.c before Xorg.
#
# Autotools, not meson. Note the tag name has a leading "v" and the tree unpacks
# to "eudev-$EUDEV_VER" without it, which is renamed below. The GitLab archive
# endpoint for this project answers with an HTML challenge page rather than a
# tarball, and Gentoo's distfiles mirror has no eudev; codeload's pinned tag is
# what resolves.
fetch "$EUDEV_URL" "$X11_SRC/eudev-${EUDEV_VER}.tar.gz" "eudev"
if [ ! -d "$X11_SRC/eudev-${EUDEV_VER}" ]; then
  tar -xf "$X11_SRC/eudev-${EUDEV_VER}.tar.gz" -C "$X11_SRC"
fi
EUDEV_SRC="$X11_SRC/eudev-${EUDEV_VER}"
# autogen.sh only runs autoreconf - it does not invoke configure, so configure is
# a separate step. --disable-manpages because we ship no man pages.
# libudev is already on this host (libinput needs it too), so the shared library
# is reused rather than built twice. The daemon and its rules are what we ship.
( cd "$EUDEV_SRC" && \
  run_quiet ./autogen.sh && \
  run_quiet ./configure --prefix=/usr --libdir=/usr/lib64 --disable-manpages && \
  run_quiet make $JOBS_FLAG && \
  run_quiet make DESTDIR="$X11_PREFIX" install )
EUDEV_BIN="$(find "$X11_PREFIX" -name 'udevd' -type f 2>/dev/null | head -1)"
[ -n "$EUDEV_BIN" ] || { fail "eudev's udevd binary not built - libinput will attach no"; fail "devices, because it requires a udev database"; exit 1; }
ok "udevd built ($(du -h "$EUDEV_BIN" | cut -f1))"

# Collect every rule into the ONE directory udevd is compiled to look in.
# udevd has no --rules-dir option: its search path is compiled in (see
# strings on the binary), and building with --libdir=/usr/lib64 makes that
# /usr/lib64/udev/rules.d. eudev installs its rules there, but libinput
# installed its own two under /usr/lib/udev/rules.d because libinput's meson
# build hardcodes /usr/lib. Merging them here is simpler and less fragile than
# teaching the daemon a new path.
UDEV_RULES="$X11_DIST/usr/lib64/udev/rules.d"
mkdir -p "$UDEV_RULES"
for from in "$X11_PREFIX/usr/lib64/udev/rules.d" "$X11_PREFIX/usr/lib/udev/rules.d"; do
  [ -d "$from" ] || continue
  cp -f "$from"/*.rules "$UDEV_RULES"/ 2>/dev/null || true
done
# 60-input-id is the load-bearing one: it sets ID_INPUT, ID_INPUT_KEYBOARD,
# ID_INPUT_MOUSE, ID_INPUT_TOUCHPAD and ID_SEAT, which is how libinput tells a
# keyboard from a mouse from a touchpad. Without it every device would look
# alike and libinput would attach the wrong things.
N_RULES="$(find "$UDEV_RULES" -name '*.rules' | wc -l)"
[ "$N_RULES" -gt 20 ] || { fail "only $N_RULES udev rules collected into $UDEV_RULES"; exit 1; }
[ -f "$UDEV_RULES/60-input-id.rules" ] \
  || { fail "60-input-id.rules missing - nothing will set ID_INPUT*, and libinput"; fail "cannot classify devices without it"; exit 1; }
[ -f "$UDEV_RULES/80-libinput-device-groups.rules" ] \
  || { fail "libinput's own rules missing - device groups and fuzz override"; fail "would be lost"; exit 1; }
ok "udev rules merged into usr/lib64/udev/rules.d ($N_RULES files, incl. 60-input-id + libinput)"
# udevadm is not optional here. The kernel emitted the input devices' "add"
# uevents seconds before udevd started, so udevd has nothing to process until
# something replays them - that is `udevadm trigger`, and `udevadm settle` is how
# init knows when the replay is done. Without both, the database stays empty and
# libinput refuses every device. udevd's other helpers (ata_id and friends) are
# not shipped: nothing in this OS calls them.
install -Dm755 "$EUDEV_BIN" "$X11_DIST/usr/sbin/udevd"
UDEVADM_BIN="$(find "$X11_PREFIX" -name 'udevadm' -type f 2>/dev/null | head -1)"
[ -n "$UDEVADM_BIN" ] || { fail "udevadm not built - init cannot replay device events,"; fail "so the udev database would stay empty"; exit 1; }
install -Dm755 "$UDEVADM_BIN" "$X11_DIST/usr/bin/udevadm"
ok "udevd + udevadm staged"
# The guest has no udevd. libinput's udev backend queries ID_INPUT_KEYBOARD,
# ID_INPUT_MOUSE, ID_INPUT_TOUCHPAD and ID_SEAT, which udev rules normally write
# into /run/udev/data. Without a running udevd a device found by scanning sysfs
# has none of them, so this is a real risk of the driver attaching nothing -
# not a theoretical one. It is settled by the QEMU boot test rather than
# assumed here, because QEMU's own PS/2 devices also arrive with no udev
# properties and so exercise exactly the same path.
export PKG_CONFIG_PATH="$X11_PREFIX/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$X11_PREFIX/usr/lib64:${LD_LIBRARY_PATH:-}"

header "xf86-input-libinput ${LIBINPUT_DRV_VER}"
XORG_INC="$X11_SRC/xorg-pkg/usr/include/xorg"
XORG_CFG="$X11_SRC/xorg-server-${XORG_SERVER_VER}/build/include/xorg-config.h"
[ -d "$XORG_INC" ] || { fail "xorg headers missing at $XORG_INC"; exit 1; }
[ -f "$XORG_CFG" ] || { fail "xorg build config missing at $XORG_CFG"; exit 1; }
fetch "$LIBINPUT_DRV_URL" "$X11_SRC/xf86-input-libinput-${LIBINPUT_DRV_VER}.tar.xz" "xf86-input-libinput"
if [ ! -d "$X11_SRC/xf86-input-libinput-${LIBINPUT_DRV_VER}" ]; then
  tar -xf "$X11_SRC/xf86-input-libinput-${LIBINPUT_DRV_VER}.tar.xz" -C "$X11_SRC"
fi
LIBINPUT_DRV_SRC="$X11_SRC/xf86-input-libinput-${LIBINPUT_DRV_VER}"
# Autotools, not meson: 1.5.0's release tarball ships configure/Makefile.am
# with no meson.build. Same shape as the fbdev DDX above - it is an out-of-tree
# x.org driver and needs the same two pkg-config stubs (xorg-server.pc pointing
# at the staged server, xorg-macros.pc as an existence marker), plus libinput.pc
# from the build above and pixman from the host.
#
# shellcheck disable=SC2086
( cd "$LIBINPUT_DRV_SRC" && \
  PKG_CONFIG_PATH="$XORG_PC:$X11_PREFIX/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}" \
  run_quiet ./configure --prefix=/usr --libdir=/usr/lib64 && \
  run_quiet make $JOBS_FLAG && \
  run_quiet make DESTDIR="$X11_PREFIX" install )
LIBINPUT_DRV="$(find "$X11_PREFIX" -name 'libinput_drv.so' -type f 2>/dev/null | head -1)"
[ -n "$LIBINPUT_DRV" ] || { fail "libinput_drv.so not built - the X session will"; fail "attach no input devices at all"; exit 1; }
mkdir -p "$X11_DIST/usr/lib64/xorg/modules/input"
cp "$LIBINPUT_DRV" "$X11_DIST/usr/lib64/xorg/modules/input/libinput_drv.so"
ok "xf86-input-libinput built ($(du -h "$LIBINPUT_DRV" | cut -f1))"

# Reproduce xf86NormalizeName() and check the file we staged is the name the
# loader will actually ask for. Getting this wrong is silent and confusing: the
# server reports "No input driver matching `libinput'" and attaches nothing,
# which reads like a broken driver rather than a misnamed file.
NORMALISED="$(printf '%s' "libinput" | tr -d '_ \t' | tr '[:upper:]' '[:lower:]')"
WANTED="$X11_DIST/usr/lib64/xorg/modules/input/${NORMALISED}_drv.so"
if [ ! -f "$WANTED" ]; then
  fail "driver is named 'libinput' so the loader looks for ${NORMALISED}_drv.so, which is not staged"
  ls -1 "$X11_DIST/usr/lib64/xorg/modules/input/" >&2 || true
  exit 1
fi
ok "module filename matches the normalised driver name (${NORMALISED}_drv.so)"

# The loader also looks the module's XF86ModuleData up *by symbol name*, derived
# from the same normalised name. A mismatch is reported only as "Module X does
# not have a XModuleData data object", which reads like a corrupt module rather
# than a misnamed export.
DRV_SYMS="$(nm -D --defined-only "$WANTED" 2>/dev/null || true)"
grep -qE " ${NORMALISED}ModuleData\$" <<< "$DRV_SYMS" || {
  fail "driver does not export ${NORMALISED}ModuleData; the loader looks it up by that exact name"
  nm -D --defined-only "$WANTED" | grep -i moduledata >&2 || true
  exit 1
}
ok "exports ${NORMALISED}ModuleData"

# Diagnostic for the st font failure. See x11-drv/rlfc.c: host-side
# reproductions load the host's fontconfig, so they cannot answer what the
# guest resolves. This runs in the guest and prints it. Links the same
# libfontconfig the X clients use, so its answer is the relevant one.
# Linked against OUR libXft rather than the host's, so the Xft under diagnosis
# is the one that ships. Headers come from the libXft checkout we already build
# from, since the host has no Xft dev package. This uses the built copy
# because at this point the staged one does not exist yet - it is copied into
# usr/lib64 further down, and it is the same file either way.
# The checkout splits them: the generated Xft.h lands in build/, while the
# hand-written headers stay in include/X11/Xft/.
XFT_HDR="-I$X11_SRC/libXft/build -I$X11_SRC/libXft/include"
[ -f "$XFT_LIB" ] || { fail "libXft not built: $XFT_LIB"; exit 1; }
gcc -O2 -Wall -Wextra \
    $XFT_HDR \
    -o "$X11_DIST/usr/bin/rlfc" \
    "$SCRIPT_DIR/x11-drv/rlfc.c" \
    "$XFT_LIB" \
    $(pkg-config --cflags --libs fontconfig x11 xrender) \
  || { fail "rlfc diagnostic failed to build"; exit 1; }
ok "rlfc diagnostic built (run it to inspect the guest font match)"

# x11-drv/setrootcursor.c: Xorg refuses to theme the root cursor (dix/cursor.c
# CreateRootCursor opens a font named "cursor"; there is no libXcursor support in
# the server at all), so a client has to do it. This logic was a patch inside
# (dwm used to do it); i3 does not either, so it is a standalone program init
# runs once before the window manager.
gcc -O2 -Wall -Wextra \
    -o "$X11_DIST/usr/bin/setrootcursor" \
    "$SCRIPT_DIR/x11-drv/setrootcursor.c" \
    -lX11 -lXcursor \
  || { fail "setrootcursor failed to build"; exit 1; }
ok "setrootcursor built (init runs it once before the WM)"

# x11-drv/setrootbg.c: paint the desktop background. Neither Xorg nor i3 will
# do this from a config file, so like the cursor it has to be a client, run once
# before the WM. It fills a solid colour (the i3bar background) rather than
# decoding an image, so it needs nothing from libX11 that is not already in the
# closure - no libpng, no wallpaper file in the initramfs.
gcc -O2 -Wall -Wextra \
    -o "$X11_DIST/usr/bin/setrootbg" \
    "$SCRIPT_DIR/x11-drv/setrootbg.c" \
    $(pkg-config --cflags --libs x11) \
  || { fail "setrootbg failed to build"; exit 1; }
ok "setrootbg built (init runs it once before the WM)"
N_MODULES="$(find "$X11_DIST/usr/lib64/xorg/modules" -name 'fbdev_drv.so' | wc -l)"
[ "$N_MODULES" = "1" ] || { fail "fbdev_drv.so missing from the staged module tree"; exit 1; }

# The fbdev DDX calls into the xserver's shared DDX helpers (fbdevHWSave,
# shadowRemove, ...) which are separate modules one directory up. meson links
# the driver without recording a DT_NEEDED for them, so dlopen leaves those
# symbols unresolved and the server aborts with
#   (EE) Failed to load module "fbdev" (loader failed, 0)
#   (EE) no screens found
# which gives no hint that this is a packaging problem, not a config one.
# Add the dependencies and an rpath of $ORIGIN/.. so the driver finds them.
# Verify it worked: a module with a dangling symbol is silent until runtime.
FBDEV_DRV="$X11_DIST/usr/lib64/xorg/modules/drivers/fbdev_drv.so"
for aux in libfbdevhw libshadow libshadowfb libint10 libexa libvgahw libwfb; do
  [ -f "$X11_DIST/usr/lib64/xorg/modules/$aux.so" ] || continue
  patchelf --add-needed "$aux.so" "$FBDEV_DRV"
done
patchelf --set-rpath '$ORIGIN/..' "$FBDEV_DRV"
# A dangling symbol in a DDX module is silent until the server dlopens it, and
# then all you get is "Failed to load module" with no hint it is a packaging
# problem. Check it here instead. Every symbol the driver needs must come from
# one of two places: the server binary, which exports the whole DDX API and
# resolves it through its own loader, or one of the auxiliary modules.
UNDEF_FILE="$(mktemp)"; PROVIDED_FILE="$(mktemp)"; trap 'rm -f "$UNDEF_FILE" "$PROVIDED_FILE"' EXIT
nm -D --undefined-only "$FBDEV_DRV" 2>/dev/null | awk '{print $2}' | sed 's/@.*//' | sort -u \
  | grep -vE '^(_ITM_.*|__gmon_start__)$' > "$UNDEF_FILE"
{ nm -D --defined-only "$X11_DIST/bin/Xorg" 2>/dev/null
  find "$X11_DIST/usr/lib64/xorg/modules" -name '*.so' -exec nm -D --defined-only {} + 2>/dev/null
  # The driver also links plain libc, which is a DT_NEEDED entry rather than a
  # staged module.
  LIBC="$(ldd "$FBDEV_DRV" 2>/dev/null | awk '/=> \/.*\/libc\.so/ {print $3; exit}')"
  [ -n "$LIBC" ] && nm -D --defined-only "$LIBC" 2>/dev/null
} | awk '{print $3}' | sed 's/@.*//' | sort -u > "$PROVIDED_FILE"
MISSING="$(comm -23 "$UNDEF_FILE" "$PROVIDED_FILE" | grep -v '^[[:space:]]*$' || true)"
if [ -n "$MISSING" ]; then
  fail "fbdev_drv.so has symbols the server and modules cannot supply:"
  echo "$MISSING" | sed 's/^/    /'
  exit 1
fi
info "fbdev_drv.so: DT_NEEDED on the shared DDX helpers added, symbols verified"
ok "fbdev_drv.so staged"

cp "$(command -v xkbcomp)" "$X11_DIST/usr/bin/xkbcomp"
cp -a "$XKB_DATA/." "$X11_DIST/usr/share/X11/xkb/"

# The compose files, which xkeyboard-config does NOT provide and libxkbcommon
# needs anyway. This is a separate install tree: /usr/share/X11/locale, a
# sibling of the xkb dir, shipped by xkeyboard-config on most distros but built
# out of the meson install here (its meson.build has no locale/compose target at
# all - verified, not assumed).
#
# WHY IT MATTERS. libxkbcommon resolves a compose file through
# locale compose.dir, which maps locale -> Compose file: line 261 of the host's
# copy maps C.UTF-8 to en_US.UTF-8/Compose. With the dir missing, xkbcommon
# logs
#   [XKB-679] no compose file for locale "C.UTF-8"
# and a client that treats compose setup as fatal then dies rather than
# degrading. Since init sets LANG/LC_ALL to C.UTF-8, every launch hits it.
# mlterm itself is Xlib/XIM and does not read this, but libxkbcommon is still
# linked by i3 (and shipped), so the data stays until that is no longer true.
#
# Staged whole rather than trimming to the C.UTF-8 target: the mapping is read
# from compose.dir at runtime, so which locale resolves to what is a data
# question, and hardcoding one entry would break silently the moment LANG
# changes. 1.6M, and the C/ and en_US.UTF-8/ entries are tiny.
[ -d "$HOST_XKB_LOCALE_DIR" ] \
  || { fail "no compose dir on host ($HOST_XKB_LOCALE_DIR) - cannot stage compose data"; exit 1; }
[ -f "$HOST_XKB_LOCALE_DIR/compose.dir" ] \
  || { fail "compose.dir missing - libxkbcommon-compose will fail at runtime"; exit 1; }
mkdir -p "$X11_DIST/usr/share/X11/locale"
cp -a "$HOST_XKB_LOCALE_DIR/." "$X11_DIST/usr/share/X11/locale/"
# The C.UTF-8 entry the guest actually resolves, checked rather than assumed:
# grep -q on the locale's own line so a re-ordered compose.dir cannot pass.
grep -Eq "^en_US.UTF-8/Compose[[:space:]]+C.UTF-8$" "$X11_DIST/usr/share/X11/locale/compose.dir" \
  || { fail "compose.dir has no C.UTF-8 mapping - libxkbcommon-compose will fail"; exit 1; }
[ -f "$X11_DIST/usr/share/X11/locale/en_US.UTF-8/Compose" ] \
  || { fail "en_US.UTF-8/Compose missing - libxkbcommon-compose will fail"; exit 1; }
ok "xkbcomp + xkeyboard-config staged"
ok "compose files staged ($(du -sh "$X11_DIST/usr/share/X11/locale" | cut -f1), C.UTF-8 -> en_US.UTF-8/Compose)"

header "Fonts"
for f in "${FONT_FILES[@]}"; do
  cp "$HOST_FONT_DIR/$f" "$X11_DIST/usr/share/fonts/$f"
done
# fontconfig maps monospace -> the shipped TTF, so i3bar (and any other client
# that asks fontconfig for a default) picks it up without naming the family in
# three places. mlterm's own font is named explicitly in usr/etc/mlterm/aafont.
cat > "$X11_DIST/usr/share/rlos/fonts.conf" << 'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <cachedir>/tmp/fccache</cachedir>
  <match target="pattern">
    <test name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>JetBrainsMono Nerd Font Mono</string>
    </edit>
  </match>
  <match target="pattern">
    <test name="family"><string>fixed</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>JetBrainsMono Nerd Font Mono</string>
    </edit>
  </match>
  <match target="pattern">
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>JetBrainsMono Nerd Font Mono</string>
    </edit>
  </match>
  <!-- st asks for "JetBrainsMono Nerd Font Mono", which is the font's
       *typographic* family (name ID 16). Its legacy family (name ID 1) is
       "JetBrainsMono NFM", and which of the two fontconfig indexes depends on
       its version - so with no alias the request simply fails to match and st
       exits with "can't open font ...". Bind the two names together and it
       resolves either way. -->
  <alias binding="same">
    <family>JetBrainsMono Nerd Font Mono</family>
    <accept><family>JetBrainsMono NFM</family></accept>
  </alias>
  <alias binding="same">
    <family>JetBrainsMono NFM</family>
    <accept><family>JetBrainsMono Nerd Font Mono</family></accept>
  </alias>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>
</fontconfig>
FCEOF
# Terminfo. mlterm sets TERM in its child from its own termtype config, which
# the staged usr/etc/mlterm/main pins to mlterm-256color. Unlike Alacritty,
# mlterm does not probe for an entry and fall back - it simply putenv()s the
# configured string - so a missing entry would leave the shell with a TERM that
# resolves to nothing and every curses app would misbehave. Compile the entry it
# names, and the base "mlterm" entry too so overriding termtype to plain mlterm
# still resolves.
#
# xterm-256color is kept as the general fallback for clients started without
# mlterm having set TERM, and as a safety net.
#
# Both mlterm entries come from the host's compiled db via infocmp, the same way
# xterm-256color always has: tic cannot read a compiled entry as input ("This is
# not a text-file"), and regenerating the text from the host's copy means the
# guest gets the same capabilities the host has rather than a hand-written guess.
if command -v tic > /dev/null 2>&1; then
  TI_OK=""
  TI_BAD=""
  # linux and vt100 are for the text consoles, not the X session.
  #
  # init sets TERM=linux for the tty1 rescue shell and for the login shells on
  # Ctrl-Alt-F3..F6, and those entries were NOT staged - only the three X-session
  # ones were. So TERM=linux resolved to nothing and every curses program on a
  # text console failed: nano, `rldocs --tui` and `rlrepl` all report "can't open
  # terminal" or silently fall back to line mode. It was invisible because the
  # desktop's own terminals take TERM from mlterm's config and never consult this
  # database - the breakage was confined to the consoles nobody watches, which is
  # exactly where it stays unnoticed.
  #
  # vt100 is staged alongside as a fallback for the same consoles: it is the
  # lowest common denominator and does not depend on the fbcon driver having the
  # capabilities `linux` claims.
  for ti in linux vt100 mlterm mlterm-256color xterm-256color; do
    if infocmp -1 "$ti" > "$X11_SRC/$ti.info" 2>/dev/null \
       && tic -x -o "$X11_DIST/usr/share/terminfo" "$X11_SRC/$ti.info" \
            > /dev/null 2>&1; then
      TI_OK="$TI_OK $ti"
    else
      TI_BAD="$TI_BAD $ti"
    fi
  done
  # mlterm-256color is what the staged config names, so its absence is fatal
  # rather than a warning: the terminal would start with a TERM that has no
  # entry at all.
  case " $TI_BAD " in
    *" mlterm-256color "*)
      fail "mlterm-256color terminfo failed to compile - mlterm's TERM will not resolve"
      exit 1
      ;;
  esac
  [ -n "$TI_OK" ] && ok "terminfo:$TI_OK"
  [ -n "$TI_BAD" ] && warn "terminfo failed to compile:$TI_BAD"
else
  warn "tic missing - cannot compile terminfo; TERM will not resolve"
fi
ok "fonts staged ($(du -sh "$X11_DIST/usr/share/fonts" | cut -f1))"

header "Cursor theme: ${BIBATA_THEME}"
fetch "$BIBATA_URL" "$X11_SRC/${BIBATA_THEME}.tar.xz" "Bibata-Modern-Ice"
BIBATA_TMP="$X11_SRC/bibata-x"
rm -rf "$BIBATA_TMP" && mkdir -p "$BIBATA_TMP"
tar -xf "$X11_SRC/${BIBATA_THEME}.tar.xz" -C "$BIBATA_TMP" --strip-components=1
# The release tarball is a flat <theme>/ tree; X wants it under share/icons.
if [ -d "$BIBATA_TMP/$BIBATA_THEME" ]; then
  cp -a "$BIBATA_TMP/$BIBATA_THEME" "$X11_DIST/usr/share/icons/"
elif [ -d "$BIBATA_TMP" ]; then
  cp -a "$BIBATA_TMP" "$X11_DIST/usr/share/icons/$BIBATA_THEME"
fi
if [ -f "$X11_DIST/usr/share/icons/$BIBATA_THEME/cursor.theme" ]; then
  RAW_SIZE="$(du -sh "$X11_DIST/usr/share/icons/$BIBATA_THEME" | cut -f1)"
  # 28MB -> 1.5MB. The release ships 56 real cursor files plus 89 symlinks, and
  # each real file is an .xcursor container holding ~756 nominal sizes (one
  # left_ptr file is 9.4MB on its own). We only ever ask X for one size, so the
  # rest is dead weight in a read-only initramfs. Rewrite each container in
  # place, keeping only the sizes we use - filenames are content hashes and
  # cursor.theme refers to them by name, so only the bytes inside change.
  info "pruning $BIBATA_THEME: $RAW_SIZE -> sizes 24 and 32 only"
  python3 - "$X11_DIST/usr/share/icons/$BIBATA_THEME/cursors" << 'PRUNEEOF'
import os, struct, sys

IMAGE = 0xfffd0002
KEEP = {24, 32}

def prune(path):
    with open(path, 'rb') as fh:
        data = fh.read()
    orig = len(data)
    if len(data) < 16 or data[:4] != b'Xcur':
        return orig, orig, False
    hsz, ver, ntoc = struct.unpack_from('<III', data, 4)
    if hsz + ntoc * 12 > orig:
        return orig, orig, False
    toc = [struct.unpack_from('<III', data, hsz + i * 12) for i in range(ntoc)]

    chunks = []
    for i, (ctype, csub, cpos) in enumerate(toc):
        # Bound the chunk by the next TOC entry. TOC positions ascend, and
        # slicing each chunk to EOF instead is quadratic - that is what OOM-killed
        # the first attempt at this.
        end = toc[i + 1][2] if i + 1 < ntoc else orig
        if end < cpos:
            end = orig
        if ctype == IMAGE and csub not in KEEP:
            continue
        chunks.append((ctype, csub, data[cpos:end]))

    if not any(c[0] == IMAGE for c in chunks):
        return orig, 0, True

    pos = hsz + len(chunks) * 12
    new_toc, body = [], []
    for ctype, csub, blob in chunks:
        new_toc.append(struct.pack('<III', ctype, csub, pos))
        body.append(blob)
        pos += len(blob)
    # The header carries ntoc, so it has to be rewritten to match the new TOC;
    # leaving the old count makes X read past the end of the table.
    hdr = data[:4] + struct.pack('<III', hsz, ver, len(new_toc)) + data[16:hsz]
    out = hdr + b''.join(new_toc) + b''.join(body)
    with open(path, 'wb') as fh:
        fh.write(out)
    return orig, len(out), True

cursordir = sys.argv[1]
before = after = 0
kept = dropped = skipped = links = 0
for name in sorted(os.listdir(cursordir)):
    p = os.path.join(cursordir, name)
    if os.path.islink(p):
        # 89 of the 145 entries alias the same handful of real files; pruning
        # each target once covers every alias.
        links += 1
        continue
    if not os.path.isfile(p):
        continue
    b, a, is_xcur = prune(p)
    if not is_xcur:
        skipped += 1
        continue
    before += b
    if a == 0:
        os.remove(p)
        dropped += 1
    else:
        after += a
        kept += 1
print(f"         {kept} rewritten, {dropped} dropped, {links} symlinks, {skipped} skipped")
print(f"         {before/1048576:.1f} MB -> {after/1048576:.1f} MB")
PRUNEEOF
  # The prune step above rewrites every .xcursor container it touches, and it
  # rewrote them wrongly the first time: it mixed byte orders and left headers
  # libXcursor could not parse. Nothing failed visibly - the files were simply
  # unusable, so the cursor fell back and came out black. Check the container
  # structure of every real cursor file now, while a failure is still a build
  # error rather than a mystery on someone's laptop.
  #
  # libXcursor writes these headers in NATIVE byte order, which is why the
  # struct format here is '<'. Reading it big-endian gives nonsense (a header
  # size of 268435456) and looks like corruption that is not there.
  python3 - "$X11_DIST/usr/share/icons/$BIBATA_THEME/cursors" << 'XCUREOF'
import os, struct, sys
d = sys.argv[1]
IMAGE = 0xfffd0002
bad, checked, sizes = [], 0, set()
for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    if os.path.islink(p) or not os.path.isfile(p):
        continue
    data = open(p, 'rb').read()
    if data[:4] != b'Xcur' or len(data) < 16:
        bad.append('%s: not an Xcursor container' % name)
        continue
    hsz, ver, ntoc = struct.unpack_from('<III', data, 4)
    if hsz != 16:
        bad.append('%s: header size %d, expected 16' % (name, hsz))
        continue
    if ver != 0x10000:
        bad.append('%s: version 0x%x, expected 0x10000' % (name, ver))
        continue
    if ntoc == 0 or hsz + ntoc * 12 > len(data):
        bad.append('%s: TOC of %d entries overruns the %d byte file' % (name, ntoc, len(data)))
        continue
    for i in range(ntoc):
        ctype, csub, pos = struct.unpack_from('<III', data, hsz + i * 12)
        if ctype != IMAGE:
            continue
        sizes.add(csub)
        end = len(data)
        for j in range(ntoc):
            _, _, p2 = struct.unpack_from('<III', data, hsz + j * 12)
            if p2 > pos:
                end = min(end, p2)
        # XcursorImageChunk header is 8 unsigned longs + 4 unsigned ints = 44B,
        # then width*height pixels of ARGB. A chunk shorter than that is a
        # truncated image, which renders as a solid block.
        need = 44 + 4 * 64 * 64
        if end - pos < 44:
            bad.append('%s: size-%d image chunk is %d bytes, cannot hold a header'
                       % (name, csub, end - pos))
        elif end - pos > need:
            bad.append('%s: size-%d image chunk is implausibly large (%d bytes)'
                       % (name, csub, end - pos))
    checked += 1

if checked == 0:
    sys.exit('no real cursor files found in %s' % d)
if bad:
    print('  these cursor files are structurally broken:')
    for b in bad[:12]:
        print('         - %s' % b)
    sys.exit('%d of %d cursor files are broken' % (len(bad), checked))
print('         %d cursor files structurally valid, sizes %s'
      % (checked, sorted(sizes)))
XCUREOF
  ok "$BIBATA_THEME staged ($(du -sh "$X11_DIST/usr/share/icons/$BIBATA_THEME" | cut -f1))"
else
  warn "cursor.theme not found after extraction - inspect $BIBATA_TMP"
  find "$BIBATA_TMP" -maxdepth 2 | head -10 | sed 's/^/         /'
fi

# Make the theme resolvable under the name "default".
#
# This is the half of the cursor fix that i3 needs and XCURSOR_THEME cannot
# provide. i3 sets the root cursor through libxcb-cursor, which does NOT read
# XCURSOR_THEME - it looks for an icon theme literally named "default" (having
# no Xcursor.theme resource to read) and otherwise falls back to a solid "core"
# cursor, which is the black block. A `default` symlink in /usr/share/icons is
# in libxcb-cursor's built-in search path, so from now on its own lookup finds
# the same staged Bibata files mlterm's libXcursor already uses. Symlink, not a
# copy: one set of pruned cursors in the image, two names for it.
if [ -d "$X11_DIST/usr/share/icons/$BIBATA_THEME" ]; then
  ln -sfn "$BIBATA_THEME" "$X11_DIST/usr/share/icons/default"
  ok "cursor theme reachable as 'default' -> $BIBATA_THEME"
fi
# Pin the driver. Xorg probes hardware-specific -> fbdev -> vesa -> modesetting,
# and we DO have a KMS device via DRM_EFIDRM, so leaving this to autodetect is
# ambiguous. Without the BusID, the server dies with "Cannot run in
# framebuffer mode. Please specify busIDs for all framebuffer devices".
# The Device/Screen pair is NOT here. Which driver to use depends on what the
# kernel found at boot, and that is not knowable at build time:
#
#   /dev/dri/card* exists  -> i915 (or any other KMS driver) bound. Use
#                             modesetting: it programs the GPU directly, and
#                             only it gets damage-tracked updates. On the
#                             fbdev DDX every screen update is a full-screen
#                             memcpy into the framebuffer, which is slow
#                             enough to be felt in the cursor and at the
#                             keyboard.
#   no /dev/dri/card*       -> no GPU driver bound (VM, or a machine whose
#                             firmware only handed over a memory framebuffer).
#                             Fall back to fbdev on /dev/fb0, which works.
#
# Two complete templates, one per graphics path, rather than one template with
# a placeholder that init has to substitute into at boot.
#
# Doing it by substitution was a bad design: it meant the file that decides
# whether X starts was assembled by string surgery in init.c, and any mistake
# there surfaces only as Xorg's one-line
#   (EE) Error parsing the config file
# with nothing pointing at init. Init's whole job on this path is now "copy the
# right file, then append the input sections" - no rewriting.
#
# The input sections and ServerLayout are still appended by init, because the
# set of event nodes is only knowable on the machine at boot. Both templates
# therefore carry the Device/Screen pair and nothing else - no InputDevice, no
# ServerLayout - so appending cannot create a duplicate section.
cat > "$X11_DIST/usr/share/rlos/xorg.conf.ms.base" << 'XORGEOF'
Section "ServerFlags"
  # No VT switching: init owns the console, and the text console stays
  # reachable on Ctrl-Alt-F2.
  Option "AutoAddGPU" "off"
  Option "DontZap" "off"
EndSection

Section "Device"
  Identifier  "modeset0"
  Driver      "modesetting"
EndSection

Section "Screen"
  Identifier  "screen0"
  Device      "modeset0"
EndSection
XORGEOF

cat > "$X11_DIST/usr/share/rlos/xorg.conf.fbdev.base" << 'XORGEOF'
Section "ServerFlags"
  # No VT switching: init owns the console, and the text console stays
  # reachable on Ctrl-Alt-F2.
  Option "AutoAddGPU" "off"
  Option "DontZap" "off"
EndSection

Section "Device"
  Identifier  "fbdev0"
  Driver      "fbdev"
  Option      "fbdev" "/dev/fb0"
EndSection

Section "Screen"
  Identifier  "screen0"
  Device      "fbdev0"
  # Depth 24 on a 32bpp framebuffer, and that is not a typo.
  #
  # /dev/fb0 is 32bpp XRGB8888, but DRM_FBDEV_EMULATION does not report
  # FB_VISUAL_TRUECOLOR, so fbdevHWGetDepth() in fbdevhw.c falls through to
  # bits_per_pixel and hands the server depth 32. xf86SetWeight() in
  # xf86Helper.c has no `case 32:` and so leaves the weight at 000, and its
  # consistency check (depth must equal r+g+b) aborts startup with
  #   (EE) FBDEV(0): Weight given (000) is inconsistent with the depth (32)
  #   (EE) Screen(s) found, but none have a usable configuration.
  #   (EE) Fatal server error: no screens found
  # Asking for depth 24 makes the 8/8/8 default apply and the check pass. The
  # 32nd bit per pixel is just the unused X byte, so a depth 24 TrueColor
  # visual maps straight onto the framebuffer with no conversion.
  #
  # The modesetting template deliberately has NO DefaultDepth: it takes its
  # depth from the real DRM mode, and xf86SetDepthBpp skips the config's
  # DefaultDepth entirely when -depth or -fbbpp is present, so a hardcoded
  # value here would override the mode the hardware actually reported.
  DefaultDepth 24
  SubSection "Display"
    Depth 24
    Visual "TrueColor"
  EndSubSection
EndSection
XORGEOF
ok "xorg.conf.base + fonts.conf written"

# Verify the config that was just generated, not a hand-edited copy. This file
# is regenerated on every build, so a fix applied directly to x11-dist/ is
# silently undone by the next ./build_x11.sh - and the symptom appears only in
# the guest, as "no screens found". Check the two things that must hold for the
# fbdev driver to accept this framebuffer.
# Verify the templates that were just written, not a hand-edited copy. These
# are regenerated on every build, so a fix applied directly to x11-dist/ is
# silently undone by the next ./build_x11.sh - and the symptom appears only in
# the guest.
#
# Each template must be individually complete (ServerFlags, Device, Screen) and
# individually free of the two sections init appends. If a template already
# contained an InputDevice or a ServerLayout, init's append would produce a
# duplicate section, and Xorg's parser reports that only as
#   (EE) Error parsing the config file
# which says nothing about which file or which line.
CONF_PROBLEM=""
for tmpl in ms fbdev; do
    t="$X11_DIST/usr/share/rlos/xorg.conf.$tmpl.base"
    grep -q 'Section "ServerFlags"' "$t" || CONF_PROBLEM="$CONF_PROBLEM $tmpl-no-serverflags"
    grep -q 'Section "Device"' "$t" || CONF_PROBLEM="$CONF_PROBLEM $tmpl-no-device"
    grep -q 'Section "Screen"' "$t" || CONF_PROBLEM="$CONF_PROBLEM $tmpl-no-screen"
    grep -q 'Section "InputDevice"' "$t" && CONF_PROBLEM="$CONF_PROBLEM $tmpl-has-input"
    grep -q 'Section "ServerLayout"' "$t" && CONF_PROBLEM="$CONF_PROBLEM $tmpl-has-layout"
done

if [ -n "$CONF_PROBLEM" ]; then
  fail "an xorg.conf template is wrong ($CONF_PROBLEM ) - X will not start"
  exit 1
fi
ok "both xorg.conf templates checked: device+screen only, no input/ServerLayout"

# xauth: the X11 authentication cookie generator --------------------------
#
# This is what lets init replace Xorg's `-ac` with real authentication.
#
# `-ac` disables the server's host-based access control entirely, which means
# ANY local process can connect to the display and read the screen, send
# synthetic key events, and snoop what is typed. The reason it was used is
# written out in init.c: "There is no xauth in this guest to hand out a cookie" -
# the server runs as root (it must, for DRM) but the clients run unprivileged,
# and without a cookie the only way to let them in is to let everyone in.
#
# With xauth staged, init does what a normal session does:
#   xauth add :0 MIT-MAGIC-COOKIE-1 <random>   -> /run/Xauthority
#   Xorg   -auth /run/Xauthority
#   clients get XAUTHORITY=/run/Xauthority
#
# and `-ac` comes off. xauth is a good fit for this guest specifically: it is
# 104KB and links against NOTHING (verified - `ldd` reports zero shared libs),
# so it adds no new runtime dependency and no closure to stage.
#
# Source is the X.Org git. Do not confuse it with the unrelated
# github.com/xauth/xauth, which is a dead JavaScript web-login library that
# happens to share the name.
XAUTH_REPO="https://gitlab.freedesktop.org/xorg/app/xauth.git"

# Built from master, not the 1.1.5 tag. Reason: the tagged 1.1.5 is an autotools
# release whose meson.build does not exist yet - meson landed after the tag -
# and its autotools build needs host xorg-macros (not installed here, and an
# extra host package to require). Master's meson.build needs only the six
# pkg-config modules already checked above, which this host has.
#
# Pinned by commit in pins.lock, not by branch: xauth has no release tag, and
# master moving under a build is worse than a build that fails. The commit is
# the tip of master as of the pin; the build still verifies the result actually
# generates a cookie, so a wrong pin cannot silently ship.
header "xauth (MIT-MAGIC-COOKIE-1, replaces Xorg -ac)"
XAUTH_PKG_MODS="x11 xau xext xmuu xproto xtrans"
MISSING_XA=""
for m in $XAUTH_PKG_MODS; do
  pkg-config --exists "$m" 2>/dev/null || MISSING_XA="$MISSING_XA $m"
done
if [ -n "$MISSING_XA" ]; then
  fail "xauth needs pkg-config modules:$MISSING_XA"
  fail "on Gentoo: emerge x11-libs/libX11 x11-libs/libXau x11-libs/libXext"
  fail "                x11-libs/libXmu x11-proto/xorg-proto"
  exit 1
fi

pins_clone "$XAUTH_REPO" "$X11_SRC/xauth" xauth
XAUTH_SRC="$X11_SRC/xauth"
info "xauth at $(cd "$XAUTH_SRC" && git rev-parse --short HEAD)"

rm -rf "$XAUTH_SRC/build"
if ! meson setup "$XAUTH_SRC/build" "$XAUTH_SRC" --prefix=/usr > /dev/null; then
  fail "xauth meson setup failed"
  exit 1
fi
if ! run_quiet ninja -C "$XAUTH_SRC/build"; then
  fail "xauth build failed (ninja)"
  exit 1
fi
XAUTH_BIN="$XAUTH_SRC/build/xauth"
[ -x "$XAUTH_BIN" ] || { fail "xauth binary not produced"; exit 1; }
strip "$XAUTH_BIN" 2>/dev/null || true

# Prove it generates a cookie before shipping it. A silently broken xauth would
# leave init unable to start X at all, and that failure is on the framebuffer,
# where the log is already covered.
XA_PROBE="$(mktemp)"
if XAUTHORITY="$XA_PROBE" "$XAUTH_BIN" add :0 MIT-MAGIC-COOKIE-1 \
      0123456789abcdef0123456789abcdef > /dev/null 2>&1 \
   && XAUTHORITY="$XA_PROBE" "$XAUTH_BIN" list 2>/dev/null | grep -q MIT-MAGIC-COOKIE-1; then
  ok "xauth generates a valid cookie"
else
  fail "xauth could not generate a MIT-MAGIC-COOKIE-1 - the desktop would not start"
  rm -f "$XA_PROBE"
  exit 1
fi
rm -f "$XA_PROBE"

cp "$XAUTH_BIN" "$X11_DIST/usr/bin/xauth"
chmod 755 "$X11_DIST/usr/bin/xauth"

# xauth on master links libXmuu for XmuGetHostname. libXmuu is 18KB and is not
# in the xorg-pkg tree, so it has to be staged explicitly. The alternative -
# avoiding the dependency - would mean patching a third-party build to drop one
# call, which is a worse trade than 18KB. The ldd closure below picks it up from
# here automatically, because it walks every ELF in usr/bin.
XAUTH_EXTRA_LIBS=""
for m in xmuu; do
  for so in $(pkg-config --libs-only-L --libs-only-l "$m" 2>/dev/null | tr ' ' '\n' | grep -E '^-l' | sed 's/^-l//'); do
    # `continue` rather than a bare `if`: under `set -e` an `if` with no else
    # returns non-zero when its condition is false, which kills the script. That
    # is why this exited silently right after the cookie check.
    if [ -e "$X11_DIST/usr/lib64/lib${so}.so" ]; then
      continue
    fi
    # `|| true` everywhere: this whole block is "find it if you can". Under
    # `set -o pipefail` a search pipeline that matches nothing (ldconfig grep
    # finds no entry, or ls hits no glob) returns non-zero and `set -e` kills
    # the build silently - no message, exit 1, and the last thing in the log is
    # the previous step's success.
    cand="$(ldconfig -p 2>/dev/null | grep -m1 -oE "/[^ ]*/lib${so}\.so\.[0-9.]+ \(libc6,x86-64\)" | awk '{print $1}' || true)"
    if [ -z "$cand" ]; then
      cand="$(ls /usr/lib64/lib${so}.so.* 2>/dev/null | head -1 || true)"
    fi
    if [ -z "$cand" ]; then
      cand="$(ls /usr/lib/lib${so}.so.* 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$cand" ] && [ -f "$cand" ]; then
      cp -n "$cand" "$X11_DIST/usr/lib64/"
      XAUTH_EXTRA_LIBS="$XAUTH_EXTRA_LIBS $(basename "$cand")"
      ok "staged $(basename "$cand") for xauth ($(du -h "$cand" | cut -f1))"
    fi
  done
done

# What xauth links, for the log. NOT verified here: the real check is the ldd
# closure's "every DT_NEEDED of every shipped ELF resolves inside usr/lib64/"
# assertion, which runs after this and covers xauth like everything else.
# Checking it here instead would be checking too early - libXext is not staged
# at this point, it arrives via the closure two steps below.
XAUTH_DT="$(objdump -p "$X11_DIST/usr/bin/xauth" | sed -n 's/^ *NEEDED *//p' | tr '\n' ' ')"
info "xauth links: ${XAUTH_DT:- nothing}"
[ -n "$XAUTH_EXTRA_LIBS" ] && info "xauth extra libs staged:$XAUTH_EXTRA_LIBS"
ok "xauth staged ($(du -h "$X11_DIST/usr/bin/xauth" | cut -f1))"

# ---------------------------------------------------------------------------
# image viewer: giflib -> Imlib2 -> feh
# ---------------------------------------------------------------------------
# Everything here builds into x11-prefix rather than the host, for the same
# reason libXft does above: the host has no giflib, and installing into the host
# would make the guest's dependency set depend on the build machine's package
# list. LD_LIBRARY_PATH is already exported by the libXft stage, and pkg-config
# needs to look there too or Imlib2 will not find the giflib we are about to
# build. That is what the PKG_CONFIG_PATH line is for.
export PKG_CONFIG_PATH="$X11_PREFIX/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

header "giflib ${GIFLIB_VER} (host has none; Imlib2's GIF loader needs it)"
# Not fetched from upstream: giflib lives on SourceForge, whose download URLs are
# redirect chains that break often. The Debian pool carries the verbatim
# upstream tarball and resolves reliably.
#
# No configure, and that is not a mistake on this script's part: giflib 5.x
# dropped autotools for a hand-written Makefile. There is no ./configure in the
# tarball. PREFIX/LIBDIR/DESTDIR are all overridable on the make command line, so
# prefix=/usr libdir=/usr/lib64 works without any configure step.
#
# Only install-lib is invoked, deliberately. Plain `make install` would also
# install gif2rgb, giftext, giftext2gif, gifbuild and giffix - five utilities for
# authoring GIFs that a media *viewer* has no use for.
fetch "$GIFLIB_URL" "$X11_SRC/giflib-${GIFLIB_VER}.tar.gz" "giflib"
if [ ! -d "$X11_SRC/giflib-${GIFLIB_VER}" ]; then
  tar -xf "$X11_SRC/giflib-${GIFLIB_VER}.tar.gz" -C "$X11_SRC" \
    || { fail "giflib did not unpack"; exit 1; }
fi
GIFLIB_SRC="$X11_SRC/giflib-${GIFLIB_VER}"
[ -f "$GIFLIB_SRC/Makefile" ] || { fail "giflib has no Makefile at $GIFLIB_SRC"; exit 1; }
# Only the shared library target, never `all`. `all` also descends into doc/,
# which regenerates the HTML docs and the logo by running ImageMagick's
# `convert` on the source tree - not installed here, and not something a library
# this image only dlopens needs. SOEXTENSION is resolved rather than assumed so
# the target name is right even if a future giflib changes it.
GIFLIB_SOEXT="$(make -pn -C "$GIFLIB_SRC" 2>/dev/null | grep -m1 '^SOEXTENSION ' | sed 's/.*=[[:space:]]*//' || true)"
[ -n "$GIFLIB_SOEXT" ] || GIFLIB_SOEXT="so"
run_quiet make -C "$GIFLIB_SRC" -j"$JOBS" "libgif.${GIFLIB_SOEXT}" LIBDIR=/usr/lib64
DESTDIR="$X11_PREFIX" run_quiet make -C "$GIFLIB_SRC" install-lib \
  PREFIX=/usr LIBDIR=/usr/lib64
GIFLIB_LIB="$(find "$X11_PREFIX" -name 'libgif.so*' 2>/dev/null | head -1 || true)"
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
# is freetype-based, so freetype has to come along; it is already staged in this
# image for libXft, so the marginal cost is nil.
#
# --disable-filters drops the filter modules, which feh does not use.
IMLIB2_WITHOUT=""
for fmt in avif heif j2k jxl ps raw svg tiff webp y4m; do
  IMLIB2_WITHOUT="$IMLIB2_WITHOUT --without-$fmt"
done
# Pinned-commit clone, same shape as the libXft stage above: shallow, and
# verified against the pin rather than trusted to be the right tree.
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
DESTDIR="$X11_PREFIX" run_quiet make -C "$IMLIB2_SRC" install
IMLIB2_LIB="$(find "$X11_PREFIX" -name 'libImlib2.so*' -type f 2>/dev/null | head -1 || true)"
[ -n "$IMLIB2_LIB" ] || { fail "libImlib2 not built - feh cannot work without it"; exit 1; }
ok "libImlib2 built ($(du -h "$IMLIB2_LIB" | cut -f1))"

# Imlib2 installs its loaders to $(libdir)/imlib2/loaders, and resolves that path
# from the PACKAGE_LIB_DIR it was compiled with - so with libdir=/usr/lib64 the
# guest path is /usr/lib64/imlib2/loaders and NO environment variable is needed.
# Verify that assumption now rather than discovering it as a runtime "unsupported
# format" error: if the loaders are not exactly there, nothing will ever load a
# PNG and no link error will explain why.
IMLIB2_LOADER_DIR="$X11_PREFIX/usr/lib64/imlib2/loaders"
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
# x11-prefix via LD_LIBRARY_PATH, and CFLAGS/LDFLAGS point the headers at it.
fetch "$FEH_URL" "$X11_SRC/feh.tar.gz" "feh"
if [ ! -d "$X11_SRC/feh" ]; then
  # derf/feh's tarball unpacks as feh-<ref>, which is "feh-master" when built
  # from a branch and "feh-3.13.1" from a tag. Strip it so the path stays stable
  # across either.
  rm -rf "$X11_SRC/feh"
  mkdir -p "$X11_SRC/feh"
  tar -xf "$X11_SRC/feh.tar.gz" -C "$X11_SRC/feh" --strip-components=1 \
    || { fail "feh did not unpack"; exit 1; }
fi
FEH_SRC="$X11_SRC/feh"
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
# `+=` both behave correctly. The -L for our x11-prefix copy of Imlib2 goes in
# LDFLAGS, which src/Makefile's link rule (${CC} ${LDFLAGS} ${CFLAGS} -o ... )
# uses and config.mk never assigns.
# shellcheck disable=SC2086
CFLAGS="-g -Os -Wall -I$X11_PREFIX/usr/include" \
run_quiet make -C "$FEH_SRC" -j"$JOBS" $FEH_MAKE_FLAGS \
  PREFIX=/usr DESTDIR="$X11_PREFIX" \
  LDFLAGS="-L$X11_PREFIX/usr/lib64"
DESTDIR="$X11_PREFIX" run_quiet make -C "$FEH_SRC" install $FEH_MAKE_FLAGS \
  PREFIX=/usr DESTDIR="$X11_PREFIX"
FEH_BIN="$X11_PREFIX/usr/bin/feh"
[ -x "$FEH_BIN" ] || { fail "feh not built"; exit 1; }
install -m 0755 "$FEH_BIN" "$X11_DIST/usr/bin/feh"
# No DT_NEEDED may point at the build machine. feh is linked against our
# x11-prefix copy of Imlib2, and baking that absolute path in would stage a
# nonsense /home/... tree in the initramfs - the same class of bug the i3
# RUNPATH assertion catches below.
if objdump -p "$X11_DIST/usr/bin/feh" | grep -q "$X11_PREFIX"; then
  fail "feh has a DT_NEEDED pointing into $X11_PREFIX - host path leaked"
fi
ok "feh staged ($(du -h "$X11_DIST/usr/bin/feh" | cut -f1), $FEH_MAKE_FLAGS)"

header "ffmpeg ${FFMPEG_VER} (screen capture + ffplay)"
# GPL-2.0-or-later via libx264; see the pin's comment for why that is the right
# call rather than the safe-looking LGPL one. Built into x11-prefix like
# everything else here, and stripped - a default build carries symbols nobody
# in this image will ever resolve.
fetch "$FFMPEG_URL" "$X11_SRC/ffmpeg-${FFMPEG_VER}.tar.xz" "ffmpeg"
if [ ! -d "$X11_SRC/ffmpeg-${FFMPEG_VER}" ]; then
  tar -xf "$X11_SRC/ffmpeg-${FFMPEG_VER}.tar.xz" -C "$X11_SRC" \
    || { fail "ffmpeg did not unpack"; exit 1; }
fi
FFMPEG_SRC="$X11_SRC/ffmpeg-${FFMPEG_VER}"
[ -x "$FFMPEG_SRC/configure" ] || { fail "ffmpeg has no configure"; exit 1; }
info "configure (--disable-everything, then allowlist; this is the size lever)"
# --enable-indev=xcbgrab (see the pin: the CLI name x11grab is NOT the build
# name). x264 and SDL2 are found through pkg-config, which is why PKG_CONFIG_PATH
# was pointed at the prefix before the Imlib2 stage.
#
# configure is NOT run through run_quiet here, because its failure mode is a
# WARNING on stderr followed by exit 0. The warnings have to be read, and
# ffbuild/config.log does not contain them - only stderr does - so the output is
# captured explicitly and grepped. Getting this wrong is how you ship an ffmpeg
# that builds clean and cannot encode or decode a single frame.
FF_CONFIG_LOG="$(mktemp)"
# shellcheck disable=SC2086
if ! ( cd "$FFMPEG_SRC" && ./configure \
    --prefix=/usr --libdir=/usr/lib64 \
    --disable-everything \
    --disable-doc --disable-debug --disable-ffprobe \
    --enable-ffmpeg --enable-ffplay \
    --enable-gpl --enable-libx264 \
    --enable-sdl2 \
    --enable-protocol="$FFMPEG_PROTOCOLS" \
    --enable-indev="$FFMPEG_INDEV" \
    --enable-demuxer="$FFMPEG_DEMUXERS" \
    --enable-decoder="$FFMPEG_DECODERS" \
    --enable-parser="$FFMPEG_PARSERS" \
    --enable-encoder="$FFMPEG_ENCODERS" \
    --enable-muxer="$FFMPEG_MUXERS" \
    --enable-filter="$FFMPEG_FILTERS" ) > "$FF_CONFIG_LOG" 2>&1; then
  fail "ffmpeg configure failed"
  tail -20 "$FF_CONFIG_LOG" | sed 's/^/         /'
fi
FF_WARNINGS="$(grep '^WARNING' "$FF_CONFIG_LOG" || true)"
if [ -n "$FF_WARNINGS" ]; then
  echo "FAIL: ffmpeg configure warned; an option name is wrong and was silently dropped" >&2
  echo "$FF_WARNINGS" | head -10 | sed 's/^/         /' >&2
  echo "         (ffmpeg exits 0 on unmatched --enable-X; a wrong list name is not an error)" >&2
  rm -f "$FF_CONFIG_LOG"
  exit 1
fi
rm -f "$FF_CONFIG_LOG"
ok "ffmpeg configure clean (no silently-dropped options)"
run_quiet make -C "$FFMPEG_SRC" -j"$JOBS"
DESTDIR="$X11_PREFIX" run_quiet make -C "$FFMPEG_SRC" install
for b in ffmpeg ffplay; do
  [ -x "$X11_PREFIX/usr/bin/$b" ] || { fail "ffmpeg: $b not built"; exit 1; }
  install -m 0755 "$X11_PREFIX/usr/bin/$b" "$X11_DIST/usr/bin/$b"
done
# The build did not configure x11grab, or capture is impossible - and it fails
# at RUN time, not link time, so nothing above would have complained.
if ! "$X11_DIST/usr/bin/ffmpeg" -hide_banner -devices 2>/dev/null | grep -q 'x11grab'; then
  fail "ffmpeg built but has no x11grab - it cannot capture the screen"
fi
ok "ffmpeg + ffplay staged ($(du -h "$X11_DIST/usr/bin/ffmpeg" | cut -f1) + $(du -h "$X11_DIST/usr/bin/ffplay" | cut -f1))"

header "SDL2 ${SDL2_MAJOR} (ffplay's only output backend)"
# Staged rather than built: the host has SDL2 2.32.8, so there is nothing to
# compile, only shared objects to copy.
#
# SDL2's own DT_NEEDED reaches well past X11 - libwayland-client, -cursor and
# -egl, plus libdecor - and ffplay additionally pulls libva/libva-drm through
# SDL2's video init. All of it is listed in DT_NEEDED, so all of it must exist at
# load time even though this image will never open a Wayland surface: a missing
# soname stops ffplay before it reaches main(), with a loader error rather than
# anything resembling a useful diagnosis.
SDL2_LIBS="libSDL2-2.0.so.0 libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1 libva.so.2 libva-drm.so.2 libdecor-0.so.0 libXrandr.so.2 libXinerama.so.1"
N_SDL2_STAGED=0
for l in $SDL2_LIBS; do
  p="$(ldconfig -p 2>/dev/null | awk -v s="$l" '$1==s{print $NF; exit}' || true)"
  if [ -n "$p" ] && [ -f "$p" ]; then
    if [ ! -f "$X11_DIST/usr/lib64/$l" ]; then
      install -m 0644 "$p" "$X11_DIST/usr/lib64/$l"
      N_SDL2_STAGED=$((N_SDL2_STAGED + 1))
    fi
  else
    fail "$l not found on host and not already staged - ffplay would fail to load"
  fi
done
ok "SDL2 + $N_SDL2_STAGED more libraries staged for ffplay"

header "libXpm ${XPM_VER} (XFiles' only missing library)"
# libXpm is in no reachable upstream home either: x.org has no individual/libXpm
# release directory, the GitHub hits are a Windows fork (winlibs) and distro
# packaging repos, and the Debian pool does carry it but only as
# libxpm_3.5.19.orig.tar.gz - note the lowercase 'x' in the filename, which is why
# a probe for libXpm-3.5.19.tar.gz finds nothing.
fetch "$XPM_URL" "$X11_SRC/libXpm-${XPM_VER}.tar.gz" "libXpm"
if [ ! -d "$X11_SRC/libXpm-${XPM_VER}" ]; then
  # The tarball's own top-level directory is already libXpm-<ver>, so no
  # --strip-components is wanted or needed here.
  tar -xf "$X11_SRC/libXpm-${XPM_VER}.tar.gz" -C "$X11_SRC" \
    || { fail "libXpm did not unpack"; exit 1; }
fi
XPM_SRC="$X11_SRC/libXpm-${XPM_VER}"
# configure MUST be run with the source directory as the working directory, like
# the Imlib2 stage above. This is not tidiness - libXpm's configure writes its
# Makefiles relative to the CWD, so invoking it by absolute path from the parent
# exits 0, prints nothing at all, and leaves no Makefile behind. The failure then
# surfaces one line later as "make: *** No targets specified and no makefile
# found", which points at make and not at the real cause. The `( cd ... && ... )`
# subshell is what makes it work.
( cd "$XPM_SRC" && run_quiet ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static )
[ -f "$XPM_SRC/Makefile" ] || { fail "libXpm configure produced no Makefile in $XPM_SRC"; exit 1; }
run_quiet make -C "$XPM_SRC" -j"$JOBS"
DESTDIR="$X11_PREFIX" run_quiet make -C "$XPM_SRC" install
XPM_LIB="$(find "$X11_PREFIX" -name 'libXpm.so*' -type f 2>/dev/null | head -1 || true)"
[ -n "$XPM_LIB" ] || { fail "libXpm not built - XFiles cannot link"; exit 1; }
install -m 0644 "$XPM_LIB" "$X11_DIST/usr/lib64/$(basename "$XPM_LIB")"
XPM_SONAME="$(objdump -p "$XPM_LIB" | sed -n 's/^ *SONAME *//p' | head -1 || true)"
if [ -n "$XPM_SONAME" ] && [ ! -f "$X11_DIST/usr/lib64/$XPM_SONAME" ]; then
  install -m 0644 "$XPM_LIB" "$X11_DIST/usr/lib64/$XPM_SONAME"
fi
ok "libXpm staged ($(du -h "$XPM_LIB" | cut -f1))"

header "XFiles $(pins_get xfiles.sha | cut -c1-12) (file manager, plain Xlib)"
# POSIX make with brace expansion, no configure. Its Makefile hardcodes
# PROG_LDFLAGS as "-lfontconfig -lXft -lX11 -lXext -lXcursor -lXrender -lXpm
# -lpthread", so the prefix's libraries are found via -L in LDFLAGS and the
# headers via CPPFLAGS rather than by editing the Makefile.
pins_clone "$XFILES_REPO" "$XFILES_SRC" xfiles
info "XFiles at $(git -C "$XFILES_SRC" rev-parse --short HEAD) ($(git -C "$XFILES_SRC" log -1 --format=%cd --date=short))"
run_quiet make -C "$XFILES_SRC" -j"$JOBS" \
  CPPFLAGS="-I$X11_PREFIX/usr/include -I/usr/include/freetype2" \
  LDFLAGS="-L$X11_PREFIX/usr/lib64"
[ -x "$XFILES_SRC/xfiles" ] || { fail "XFiles did not build"; exit 1; }
install -m 0755 "$XFILES_SRC/xfiles" "$X11_DIST/usr/bin/xfiles"
# xfilesctl is not optional decoration: XFiles performs no file operations of its
# own, it execs xfilesctl with the selected paths. Ship it or the file manager
# draws icons and then does nothing when you press Delete.
for s in xfilesctl xfilesthumb; do
  [ -f "$XFILES_SRC/examples/$s" ] || { fail "XFiles: examples/$s missing - file operations would not work"; exit 1; }
  install -m 0755 "$XFILES_SRC/examples/$s" "$X11_DIST/usr/bin/$s"
done
# The X resource file is what gives it our colours and font instead of its
# defaults, so it is staged as data rather than left in the source tree.
mkdir -p "$X11_DIST/usr/share/xfiles"
if [ -f "$XFILES_SRC/examples/Xresources" ]; then
  install -m 0644 "$XFILES_SRC/examples/Xresources" "$X11_DIST/usr/share/xfiles/Xresources"
fi
ok "xfiles staged ($(du -h "$X11_DIST/usr/bin/xfiles" | cut -f1)) + xfilesctl/xfilesthumb"

# ---------------------------------------------------------------------------
# stage Imlib2 and its loaders
# ---------------------------------------------------------------------------
# This runs BEFORE the closure below, not after. libImlib2.so.7 does not need
# staging here: feh is in the tree already, LD_LIBRARY_PATH resolves Imlib2 for
# ldd, and the closure flattens it into usr/lib64 by basename like everything
# else. Installing it early as well is harmless (the closure uses cp -n) and
# makes the dependency legible next to the loaders that need it.
#
# The loaders are the reason this block exists at all. They are dlopen'd by
# name, not linked, so they appear in no DT_NEEDED and no ldd output anywhere -
# neither here nor in the closure. Nothing else in the build will ever place
# them, and omitting them yields a libImlib2 that loads no formats at all and
# reports it as an unsupported-format error rather than as a missing module.
header "Staging Imlib2 + its dlopen'd loaders"
install -m 0755 "$IMLIB2_LIB" "$X11_DIST/usr/lib64/$(basename "$IMLIB2_LIB")"
# Also place the SONAME, as a real copy rather than a symlink. Every loader
# links libImlib2.so.1, and libImlib2.so.1.12.7 alone would not satisfy it - the
# loader looks up the soname exactly. The closure would flatten one in later, but
# relying on that ordering is how the loader-dependency walk below spent its first
# run reporting libImlib2.so.1 missing for all eighteen loaders when the finished
# tree in fact had it. Copied, not symlinked, because a symlink into a cpio needs
# its target present and the closure's own copies are files for the same reason.
IMLIB2_SONAME="$(objdump -p "$IMLIB2_LIB" | sed -n 's/^ *SONAME *//p' | head -1 || true)"
if [ -n "$IMLIB2_SONAME" ] && [ "$IMLIB2_SONAME" != "$(basename "$IMLIB2_LIB")" ]; then
  if [ ! -f "$X11_DIST/usr/lib64/$IMLIB2_SONAME" ]; then
    install -m 0755 "$IMLIB2_LIB" "$X11_DIST/usr/lib64/$IMLIB2_SONAME"
    info "staged soname $IMLIB2_SONAME (loaders link this, not the versioned file)"
  fi
fi
# gif and the base loaders (bmp, ico, tga, xbm, xpm, pnm, argb) are compiled
# unconditionally by Imlib2's Makefile.am, so stage every .so the build produced
# rather than an allowlist - an allowlist would silently drop bmp and ico, which
# are free, and would need editing every time a base loader is added.
mkdir -p "$X11_DIST/usr/lib64/imlib2/loaders"
for l in "$IMLIB2_LOADER_DIR"/*.so; do
  [ -f "$l" ] || continue
  install -m 0644 "$l" "$X11_DIST/usr/lib64/imlib2/loaders/$(basename "$l")"
done
N_STAGED_LOADERS="$(find "$X11_DIST/usr/lib64/imlib2/loaders" -name '*.so' | wc -l)"
[ "$N_STAGED_LOADERS" -gt 0 ] || { fail "no Imlib2 loaders staged - feh would load nothing"; exit 1; }
# The exact failure this block exists to prevent: a libImlib2 present but no
# loaders beside it loads no formats whatsoever, and reports it as an
# unsupported-format error rather than as a missing module.
for fmt in $IMLIB2_LOADERS_KEEP; do
  [ -f "$X11_DIST/usr/lib64/imlib2/loaders/$fmt.so" ] \
    || { fail "loader $fmt.so not staged - $fmt would fail to load at runtime"; exit 1; }
done
ok "libImlib2 + $N_STAGED_LOADERS loaders staged (feh needs: $IMLIB2_LOADERS_KEEP)"

# The loaders are dlopen'd, so nothing above has a DT_NEEDED edge to them and the
# closure below cannot see them or what THEY link. That makes this the one place
# in the whole script where a missing library produces no build error at all and
# no runtime error either - just a format that quietly stops working, reported as
# "unsupported format" rather than as the missing module it actually is.
#
# So the loader's own dependencies are walked explicitly, here.
IMLIB2_LOADER_MISSING=""
for l in "$X11_DIST/usr/lib64/imlib2/loaders"/*.so; do
  [ -f "$l" ] || continue
  for dep in $(objdump -p "$l" | sed -n 's/^ *NEEDED *//p'); do
    base="$(basename "$dep")"
    # Skip the interpreter line and anything that is not a bare soname.
    case "$base" in ld-*|linux-vdso*) continue ;; esac
    # Already staged by the closure (libpng, libX11 and friends are reachable
    # from feh itself), or is one of ours already placed by basename.
    [ -f "$X11_DIST/usr/lib64/$base" ] && continue
    found="$(ldconfig -p 2>/dev/null | awk -v s="$base" '$1==s{print $NF; exit}' || true)"
    if [ -n "$found" ] && [ -f "$found" ]; then
      install -m 0644 "$found" "$X11_DIST/usr/lib64/$base"
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

header "ldd closure"
# The guest has no ld.so.cache, so every shared object must be a real file in
# /usr/lib64 (a default loader search dir). Flatten the closure of everything
# we ship - binaries AND modules, since a module can need something a binary
# does not. Keep the absolute path too, so a dlopen of an absolute path works.
CLOSURE_SEEN=""
collect() {
  local target="$1" lib
  for lib in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
    case " $CLOSURE_SEEN " in *" $lib "*) continue ;; esac
    CLOSURE_SEEN="$CLOSURE_SEEN $lib"
    collect "$lib"
  done
}
ALL_ELFS="$(find "$X11_DIST/bin" "$X11_DIST/usr/bin" "$X11_DIST/sbin" "$X11_DIST/usr/sbin" \
  -type f 2>/dev/null; find "$X11_DIST/usr/lib64/xorg/modules" -name '*.so' -type f)"
for elf in $ALL_ELFS; do
  [ -f "$elf" ] || continue
  collect "$elf"
done
# A dlopen-only library (none in this stack today, but the generic scan below
# still guards against one) is NOT reachable from any shipped binary by ldd, so
# the recursive collect above would never visit it. There is no fixed list to
# feed in any more; the generic scan further down still covers anything a
# future terminal or driver starts loading at runtime.
N_LIBS=0
for lib in $CLOSURE_SEEN; do
  [ -f "$lib" ] || continue
  # Flat into usr/lib64, which is a default loader search dir, so the guest's
  # missing ld.so.cache does not matter.
  cp -n "$lib" "$X11_DIST/usr/lib64/$(basename "$lib")" 2>/dev/null || true
  # Also keep the real absolute path, but only for genuine system paths. A lib
  # that lives under a build prefix (our own x11-prefix, or a ~/dev checkout)
  # would otherwise stage a nonsense /home/... tree in the initramfs.
  case "$lib" in
    /usr/*|/lib/*|/lib64/*)
      mkdir -p "$X11_DIST$(dirname "$lib")"
      cp -n "$lib" "$X11_DIST$lib" 2>/dev/null || true
      ;;
  esac
  N_LIBS=$((N_LIBS + 1))
done
# libXft came from our own build prefix, not the host loader's search path, so
# ldd never found it. Add it by basename only - its absolute build path is not
# a guest path. libinput is the same situation: ldd resolves it through
# LD_LIBRARY_PATH, but if that ever stops being true the driver is dlopened with
# no DT_NEEDED resolution and silently attaches nothing.
for EXTRA_LIB in "$XFT_LIB" "$LIBINPUT_LIB" $I3_EXTRA_LIBS; do
  [ -n "$EXTRA_LIB" ] || continue
  cp -n "$EXTRA_LIB" "$X11_DIST/usr/lib64/$(basename "$EXTRA_LIB")" 2>/dev/null || true
done
ok "$N_LIBS shared objects in usr/lib64/ ($(du -sh "$X11_DIST/usr/lib64" | cut -f1))"

# Verify the closure the way the guest will actually resolve it. The guest has
# no ld.so.cache, so the loader only searches its default dirs and a library is
# found solely by filename. ldd on the host happily resolves things from the
# host's own directories, which hides exactly the failure we care about: a
# binary whose dependency was never staged. That is not hypothetical - it is how
# xkbcomp shipped without libxkbfile.so.1 and made the whole X session fail with
#   /usr/bin/xkbcomp: error while loading shared libraries: libxkbfile.so.1
#   (EE) Fatal server error: Failed to activate virtual core keyboard: 2
# Check each shipped ELF's DT_NEEDED names against usr/lib64/ directly.
MISSING_LIBS=""
for elf in $ALL_ELFS; do
  [ -f "$elf" ] || continue
  for need in $(objdump -p "$elf" 2>/dev/null |
                sed -n 's/^ *NEEDED *//p'); do
    case "$need" in
      # Provided by the kernel, or by the C runtime assemble-rootfs.sh stages.
      linux-vdso*|linux-gate*|ld-linux*|libc.so.6|libm.so.6|libpthread.so.0) continue ;;
    esac
    [ -e "$X11_DIST/usr/lib64/$need" ] || MISSING_LIBS="$MISSING_LIBS $need"
  done
done
MISSING_LIBS="$(printf '%s\n' $MISSING_LIBS | sort -u | grep '[^[:space:]]' | tr '\n' ' ' || true)"
if [ -n "$MISSING_LIBS" ]; then
  fail "these shared objects are needed by something we ship but are not staged:"
  echo "    $MISSING_LIBS"
  fail "the guest has no ld.so.cache, so they will not be found at runtime"
  exit 1
fi
ok "every DT_NEEDED of every shipped ELF resolves inside usr/lib64/"

# ---- and the dlopen'd libraries, which DT_NEEDED cannot see -------------------
# The gate above is necessary and NOT sufficient. A library opened with dlopen()
# at runtime never appears in DT_NEEDED, so nothing above can notice its absence.
#
# Nothing in the stack this script builds dlopens a library today: Xorg's modules
# are reached through the absolute module path and are staged whole, and mlterm
# is built --disable-shared so its type engine and ctl code are linked in. This
# gate is kept because that has not always been true (Alacritty reached GL
# through glutin, and libGL.so.1 appeared in no ELF header), and because the
# failure mode is silent: the process starts, draws nothing useful, and dies with
# the reason on a stderr the desktop has already covered.
#
# How the list is found: dlopen targets are NUL-terminated C strings, so scan the
# binary for anything shaped like a soname and keep the ones the host actually
# has. Matching against ldconfig's list is what keeps this from dragging in
# false positives - a random string that looks like libfoo.so.1 is only
# interesting if the host could actually supply it.
DLOPEN_MISSING=""
for elf in $ALL_ELFS; do
  [ -f "$elf" ] || continue
  for need in $(strings -a "$elf" 2>/dev/null |
                grep -oE 'lib[A-Za-z0-9_.+-]{2,40}\.so(\.[0-9]+)*' |
                sort -u |
                while read -r n; do
                  # only names the host can actually resolve are interesting
                  ldconfig -p 2>/dev/null | grep -q "[[:space:]]$n[[:space:]]" && echo "$n"
                done | sort -u); do
    case "$need" in
      linux-vdso*|linux-gate*|ld-linux*|libc.so.6|libm.so.6|libpthread.so.0) continue ;;
# Unversioned aliases: the loader resolves libfoo.so via the versioned
        # soname, and dlsym probes the short name before the long one.
        libGL.so|libXi.so|libXcursor.so|libxkbcommon.so|libxkbcommon-x11.so) continue ;;
        # SDL2 probes for the Vulkan loader while it builds its list of available
        # video renderers, exactly as it probes for libGL. This image has no GPU
        # stack at all - GLX, glamor and DRI are all off in the Xorg build - so
        # SDL2's x11 driver is the only one that can ever be selected and
        # libvulkan is unreachable. It is a probe for hardware that does not
        # exist here, not a dependency, and staging the Vulkan loader to satisfy
        # a string match would add a GL-adjacent stack this image deliberately
        # does not have.
        libvulkan.so|libvulkan.so.1) continue ;;
    esac
    [ -e "$X11_DIST/usr/lib64/$need" ] || DLOPEN_MISSING="$DLOPEN_MISSING $need"
  done
done
DLOPEN_MISSING="$(printf '%s\n' $DLOPEN_MISSING | sort -u | grep '[^[:space:]]' | tr '\n' ' ' || true)"
if [ -n "$DLOPEN_MISSING" ]; then
  fail "these are dlopen'd at runtime by something we ship but are not staged:"
  echo "    $DLOPEN_MISSING"
  fail "DT_NEEDED cannot see these - they are invisible to the check above"
  exit 1
fi
ok "every dlopen'd library of every shipped ELF resolves inside usr/lib64/"

# libc/libm/ld-linux are already in the guest via assemble-rootfs.sh; say so
# rather than let the size look surprising.
for already in libc.so.6 libm.so.6 ld-linux-x86-64.so.2; do
  if [ -e "$X11_DIST/usr/lib64/$already" ]; then
    info "$already is also staged (harmless, assemble-rootfs.sh already ships it)"
  fi
done

header "Results"
ok "x11-dist ready ($(du -sh "$X11_DIST" | cut -f1))"
info "layout:"
find "$X11_DIST" -maxdepth 3 -type d | sort | sed 's/^/         /'
info "binaries:"
for b in Xorg i3 i3bar i3-msg mlterm setrootcursor setrootbg; do
  if [ -f "$X11_DIST/bin/$b" ]; then
    printf "         %-14s %s\n" "$b" "$(du -h "$X11_DIST/bin/$b" | cut -f1)"
  fi
done
# setrootcursor links against the host's libXcursor because it is compiled here
# and staged; that it resolves in the guest is the whole point of checking it.
#
# Resolved by find, not a hardcoded bin/ path: setrootcursor is staged into
# usr/bin while the rest are in bin, and ldd on a nonexistent path exits
# nonzero, which under `set -o pipefail` aborted the whole build in the results
# section - after all the real work had already succeeded. Asking the filesystem
# also keeps this honest if a binary moves again.
for b in i3 i3bar mlterm setrootcursor setrootbg; do
  info "$b linkage:"
  p="$(find "$X11_DIST" -type f -name "$b" -perm -u+x | head -1)"
  if [ -z "$p" ]; then
    warn "$b not found anywhere under $X11_DIST - staged layout changed?"
    continue
  fi
  info "         at ${p#$X11_DIST/}"
  ldd "$p" 2>/dev/null | awk '{print $1}' | grep '^lib' | sort -u \
    | sed 's/^/         /' || true
done
info "terminfo (all five resolve in-guest):"
{ ls "$X11_DIST/usr/share/terminfo/l/" 2>/dev/null
  ls "$X11_DIST/usr/share/terminfo/v/" 2>/dev/null
  ls "$X11_DIST/usr/share/terminfo/m/" 2>/dev/null
  ls "$X11_DIST/usr/share/terminfo/x/" 2>/dev/null; } | tr '\n' ' ' \
  | sed 's/^/         /'
echo
# `linux` is the one whose absence is silent, so it is checked rather than
# listed. It is what init sets for the text consoles; without it every curses
# program there fails, and nothing else in the image would reveal that.
if [ -f "$X11_DIST/usr/share/terminfo/l/linux" ]; then
  info "         'linux' staged - TERM=linux on the text consoles will resolve"
else
  fail "'linux' terminfo missing - TERM=linux resolves to nothing in the guest"
  exit 1
fi
info "next: assemble-rootfs.sh copies x11-dist/ into the guest, then"
info "      rlos-initramfs/init.c starts the X session (Step 4)."
