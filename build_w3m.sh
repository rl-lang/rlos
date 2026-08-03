#!/usr/bin/env bash
# build_w3m.sh - stage w3m, a text-mode web browser, and its library closure.
#
# WHY w3m AND NOT A GRAPHICAL BROWSER.
#
# NetSurf was the original target and is gone, and the reason is worth recording
# so it is not re-attempted. Current NetSurf ships exactly these frontends:
#
#     amiga atari beos framebuffer gtk monkey qt riscos windows
#
# There is no X11 frontend. frontends/x11 existed once and was removed years ago,
# so "NetSurf on X11" means "NetSurf on GTK", and GTK3 drags in a large closure -
# glib, gobject, gio, pango, cairo, harfbuzz, fribidi, atk, atspi, gdk-pixbuf,
# epoxy and the X11 extensions - plus gsettings schemas, the Adwaita icon theme and
# the gdk-pixbuf loader cache. For an image whose entire premise is a small,
# auditable, built-in-kernel rootfs, that is a bad trade for a browser.
#
# w3m needs ncurses-era terminfo, OpenSSL, zlib and libbsd, of which this image
# already had all but one. It renders in the mlterm that is already the desktop's
# terminal, so it needs no new display machinery at all.
#
# It is launched as a plain command - `w3m` - deliberately with no desktop entry
# and no keybinding. See the note in assemble-rootfs.sh.
#
# THREE THINGS THIS SCRIPT HAS TO GET RIGHT, NONE OF THEM OBVIOUS.
#
# 1. w3m REQUIRES Boehm GC. This is not a soft dependency. configure contains
#
#         test x"$with_gc" = xno && as_fn_error ... "You can not build w3m without GC"
#
#    so --without-gc is a hard error and the build stops. GC is therefore built
#    here too, from source, STATIC ONLY (--disable-shared), because a shared
#    libgc.so would become a runtime dependency of the browser for no benefit:
#    nothing else in this image uses GC. Static keeps the dependency out of the
#    image entirely, which is verified below rather than assumed.
#
# 2. w3m does not compile under a modern compiler's default standard. GCC 15
#    defaults to -std=gnu23, in which an empty parameter list means (void)
#    rather than "unspecified". w3m is 2000s-era code full of K&R-style
#    declarations, so this breaks the build immediately and uninformatively:
#
#        w3mbookmark.c:186: error: conflicting types for 'getenv'
#        char_conv.c:19: error: too many arguments to function '...char_conv'
#
#    The second one is a struct member, libwc/wc_types.h:66 `Str (*char_conv)()`,
#    so it is not a stray local declaration - it is in the public header. The fix
#    is -std=gnu17, which keeps the pre-C23 "unspecified arguments" meaning while
#    still being new enough for the OpenSSL 3.5 headers. -std=gnu89 is the more
#    "period correct" choice and does not work: OpenSSL 3.x headers need C99+.
#    This is a compiler flag rather than a source patch on purpose - there are
#    many such declarations and patching them one at a time is whack-a-mole.
#
# 3. w3m hardcodes -lnsl, which is dead weight. Its Makefile has
#
#        LIBS = -lm -lbsd -lnsl -ldl
#
#    -lnsl is the Sun Network Services Library and it pulls in libtirpc.so.3 as a
#    transitive dependency. w3m imports ZERO symbols from either: verified by
#    intersecting w3m's undefined dynamic symbols against the two libraries'
#    exports, which came back empty. Two legacy libraries were being staged to
#    satisfy a link-time requirement that nothing reads. The -lnsl is removed and
#    the result is checked to still link.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/w3m-src"
PREFIX="$ROOT/w3m-prefix"
DIST="$ROOT/w3m-dist"
GC_SRC="$ROOT/gc-src"
GC_PREFIX="$ROOT/gc-dist"

W3M_VER="0.5.3-git20230121"
W3M_TAG="v0.5.3+git20230121"
W3M_URL="https://github.com/tats/w3m/archive/refs/tags/${W3M_TAG}.tar.gz"
GC_VER="8.2.12"
GC_URL="https://github.com/ivmai/bdwgc/archive/refs/tags/v${GC_VER}.tar.gz"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
header() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }
info()  { printf '%s  %s%s\n' "$GRN" "$1" "$RST"; }
warn()  { printf '%s  %s%s\n' "$YLW" "$1" "$RST"; }
die()   { printf '%serror:%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

fetch() {
    local url="$1" out="$2"
    command -v curl >/dev/null || die "curl not found"
    if [ -s "$out" ]; then
        info "cached $(basename "$out")"
        return 0
    fi
    info "fetching $(basename "$out")"
    curl -fsSL --retry 3 --max-time 300 -o "$out.part" "$url" \
        || die "download failed: $url"
    mv "$out.part" "$out"
}

# Unpack a GitHub tag tarball and echo the directory it created.
#
# The directory name is NOT reconstructed from the tag on purpose. GitHub names it
# "<repo>-<tag with the leading v stripped>", and this tag is
# v0.5.3+git20230121 - so the real directory is "w3m-0.5.3+git20230121", with a
# "+" where the tag has one and no leading "v". That is exactly the kind of
# string to let tar tell us rather than reimplement in shell, which is how the
# first run of this script died with "cd: .../w3m-v0.5.3+git20230121: No such file
# or directory".
unpack() {
    local tarball="$1" dest="$2"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -C "$dest" -xzf "$tarball"
    local d
    d="$(find "$dest" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [ -n "$d" ] || die "no directory in $tarball"
    printf '%s' "$d"
}

mkdir -p "$SRC" "$GC_SRC"

# ---------------------------------------------------------------------------
# Boehm GC - static only
# ---------------------------------------------------------------------------
header "boehm gc (static, required by w3m)"
fetch "$GC_URL" "$GC_SRC/bdwgc-${GC_VER}.tar.gz"
rm -rf "$GC_PREFIX"
mkdir -p "$GC_PREFIX"
GC_SRCDIR="$(unpack "$GC_SRC/bdwgc-${GC_VER}.tar.gz" "$GC_SRC/gc-x")"
cd "$GC_SRCDIR"

# A tag tarball has no configure; autogen.sh is required, not a fallback.
if [ ! -x ./configure ]; then
    ./autogen.sh > "$GC_SRC/gc-autogen.log" 2>&1 \
        || { warn "autogen.sh failed; tail:"; tail -20 "$GC_SRC/gc-autogen.log"; die "gc autogen"; }
fi

# --disable-shared is the important one. If a libgc.so ever appears here, w3m
# would link it and the browser would need it at runtime on a machine with no
# package manager.
./configure --prefix="$GC_PREFIX" \
    --enable-static --disable-shared --enable-threads=posix --with-pic \
    > "$SRC/gc-configure.log" 2>&1 \
    || { warn "gc configure failed; tail:"; tail -25 "$SRC/gc-configure.log"; die "gc configure"; }
make -j"$(nproc)" > "$SRC/gc-build.log" 2>&1 \
    || { warn "gc build failed; tail:"; tail -30 "$SRC/gc-build.log"; die "gc build"; }
make install > "$SRC/gc-build.log" 2>&1 \
    || { warn "gc install failed; tail:"; tail -20 "$SRC/gc-build.log"; die "gc install"; }

[ -f "$GC_PREFIX/lib/libgc.a" ] || die "libgc.a not produced"
if ls "$GC_PREFIX"/lib/libgc.so* >/dev/null 2>&1; then
    die "a shared libgc was built - it would become a runtime dependency"
fi
info "libgc.a built (static only, $(du -h "$GC_PREFIX/lib/libgc.a" | cut -f1))"

# ---------------------------------------------------------------------------
# w3m
# ---------------------------------------------------------------------------
header "w3m $W3M_VER"
fetch "$W3M_URL" "$SRC/w3m-${W3M_VER}.tar.gz"
rm -rf "$DIST" "$PREFIX"
mkdir -p "$DIST"
W3M_SRCDIR="$(unpack "$SRC/w3m-${W3M_VER}.tar.gz" "$SRC/w3m-x")"
cd "$W3M_SRCDIR"

# FLAG NOTES, in the order they matter.
#
#   --disable-image     Not only smaller: without it configure GUESSES an image
#                       library and picks "gtk2 gdk-pixbuf imlib imlib2" on a
#                       host that happens to have them. That is exactly the
#                       toolkit dependency this build exists to avoid, and it
#                       arrives silently. A terminal browser has no use for
#                       inline images anyway.
#   --disable-nls       no gettext catalogs.
#   --with-ssl=openssl  HTTPS. Verified on in the staged binary below.
#   CFLAGS -std=gnu17   see the header, point 2. Do not drop this.
./configure --prefix="$PREFIX" \
    --with-gc="$GC_PREFIX" \
    --with-ssl=openssl \
    --disable-image \
    --disable-nls \
    CFLAGS="-O2 -std=gnu17" \
    > "$SRC/w3m-configure.log" 2>&1 \
    || { warn "configure failed; tail:"; tail -35 "$SRC/w3m-configure.log"; die "configure"; }

# Drop -lnsl. See the header, point 3. Matched on the whole line so a reordering
# of the variable does not silently skip this.
if grep -qE '^LIBS = .*-lnsl' Makefile; then
    sed -i 's/^LIBS = \(.*\)-lnsl \(.*\)$/LIBS = \1\2/' Makefile
    info "removed -lnsl from LIBS (was: $(grep -m1 '^LIBS = ' Makefile | tr -s ' '))"
else
    warn "LIBS has no -lnsl - upstream may have fixed this, check by hand"
fi

make -j"$(nproc)" > "$SRC/w3m-build.log" 2>&1 \
    || { warn "build failed; tail:"; tail -40 "$SRC/w3m-build.log"; die "build"; }
make install > "$SRC/w3m-build.log" 2>&1 \
    || { warn "install failed; tail:"; tail -30 "$SRC/w3m-build.log"; die "install"; }

[ -x "$PREFIX/bin/w3m" ] || die "w3m binary not produced at $PREFIX/bin/w3m"

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------
header "staging"
mkdir -p "$DIST/usr/bin" "$DIST/usr/lib64" "$DIST/usr/share/w3m"
cp -L "$PREFIX/bin/w3m" "$DIST/usr/bin/w3m"
chmod 755 "$DIST/usr/bin/w3m"
# w3m's help pages are plain HTML read by w3m itself; shipping them means the
# built-in help works offline instead of failing on a missing file.
for f in w3mhelp.html; do
    [ -f "$PREFIX/share/w3m/$f" ] && cp -L "$PREFIX/share/w3m/$f" "$DIST/usr/share/w3m/$f"
done
info "w3m staged at /usr/bin/w3m ($(du -h "$DIST/usr/bin/w3m" | cut -f1))"

# ---------------------------------------------------------------------------
# Closure
# ---------------------------------------------------------------------------
header "ldd closure"
CLOSURE=""
collect() {
    local target="$1" lib
    for lib in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
        case " $CLOSURE " in *" $lib "*) continue ;; esac
        CLOSURE="$CLOSURE $lib"
        collect "$lib"
    done
}
collect "$DIST/usr/bin/w3m"
n=0
for lib in $CLOSURE; do
    base="$(basename "$lib")"
    cp -L "$lib" "$DIST/usr/lib64/$base" 2>/dev/null || { warn "skipped $base"; continue; }
    n=$((n + 1))
done
info "closure: $n libraries ($(du -sh "$DIST/usr/lib64" | cut -f1))"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
header "verification"
fail=0

# The static-GC claim, checked rather than assumed.
if ldd "$DIST/usr/bin/w3m" | grep -q 'libgc'; then
    warn "w3m links libgc dynamically - GC was not built static"
    fail=1
else
    info "GC is statically linked (no libgc.so at runtime)"
fi

# Every DT_NEEDED must be resolvable from the staged set.
for so in $(objdump -p "$DIST/usr/bin/w3m" | sed -n 's/^ *NEEDED *//p'); do
    case "$so" in
        ld-linux*|libc.so.6) continue ;;
    esac
    if [ ! -e "$DIST/usr/lib64/$so" ] && [ ! -e "$DIST/usr/lib64/$so.6" ] \
       && ! ls "$DIST/usr/lib64/$so."* >/dev/null 2>&1; then
        warn "w3m needs $so, not staged"
        fail=1
    fi
done

# Load and render, against the staged libraries only. A render check is used
# rather than -version because -version can succeed on a binary whose terminal
# layer is unusable, and it is the terminal layer that is the point here.
out="$(LD_LIBRARY_PATH="$DIST/usr/lib64" TERM=xterm \
       timeout 20 "$DIST/usr/bin/w3m" -dump file:///dev/null 2>&1 || true)"
if printf '%s' "$out" | grep -q 'shared object\|error while loading'; then
    warn "w3m cannot load its staged libraries:"
    printf '%s\n' "$out" | head -3 | sed 's/^/    /'
    fail=1
else
    info "w3m loads and renders against the staged closure"
fi

# HTTPS and UTF-8 are the two features most likely to be lost to a build flag,
# and both are silent when missing: no HTTPS means every https:// page fails to
# load, and no m17n means non-ASCII pages are mojibake.
ver="$(LD_LIBRARY_PATH="$DIST/usr/lib64" "$DIST/usr/bin/w3m" -version 2>&1 || true)"
printf '%s' "$ver" | grep -q 'ssl-verify' \
    && info "HTTPS enabled (ssl-verify present)" \
    || { warn "no ssl-verify in w3m - HTTPS may be broken"; fail=1; }
printf '%s' "$ver" | grep -q 'm17n' \
    && info "UTF-8/m17n enabled" \
    || { warn "no m17n in w3m - non-ASCII pages will be mojibake"; fail=1; }

[ "$fail" -eq 0 ] || die "w3m-dist is incomplete"
printf '\n%s  done: w3m staged in %s (%s)%s\n' \
    "$GRN" "$DIST" "$(du -sh "$DIST" | cut -f1)" "$RST"
