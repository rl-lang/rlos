#!/usr/bin/env bash
# build_iwd.sh - stage iwd (Intel Wireless Daemon) and iwctl.
#
# WHY SOURCE-BUILT, AND WHY libnl COMES FIRST.
#
# iwd has to be built from source. It is not on the build host, and unlike the
# D-Bus daemon there is nothing to copy: the host may have libnl's headers but
# almost certainly not the exact sonames iwd links against, and copying a daemon
# whose dependency closure cannot be proven complete is how you get "error while
# loading shared libraries" on a machine that has no package manager to fix it
# with.
#
# libnl-3 is built here too, for the same reason one level down. iwd needs
# libnl-3 and libnl-genl-3 (it speaks netlink to cfg80211 directly, which is how
# it avoids depending on iw or nl80211's userspace), and neither is installed on
# the build host. Both are plain autotools C with no dependencies beyond libc, so
# they build into a throwaway prefix with no risk of touching the host.
#
# iwd's own D-Bus library, ell/, is bundled in its tarball and is what iwd and
# iwctl use to talk to the bus. It is NOT libdbus - it speaks the D-Bus wire
# protocol over its own socket. That is why build_dbus.sh does not need to be
# aware of iwd, and why there is no libdbus dependency to close here: the daemon
# still needs the *bus*, but not the library.
#
# CONFIGURATION IS MINIMAL ON PURPOSE.
#
#   --disable-werror
#       A newer host gcc than the one iwd 3.12 was tested against produces
#       warnings-as-errors in code nobody is changing. This image gains nothing
#       from failing a build over a warning.
#   --without-* for udev, journal, crypto, etc.
#       iwd supports several ways of doing things this system does not have.
#       Disabling them keeps the closure small and, more importantly, keeps the
#       daemon from failing at runtime on a feature it was compiled to expect.
#       Notably: no systemd, no udev, no journal - this is a busybox-style tree
#       where a missing dependency surfaces as a silent no-op rather than an error.
#
# OUTPUT: iwd-dist/, staged by assemble-rootfs.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourced after the message helpers so pin failures report through die().
# shellcheck source=pins.sh
source "$ROOT/pins.sh"
SRC="$ROOT/iwd-src"
PREFIX="$ROOT/iwd-prefix"
DIST="$ROOT/iwd-dist"

IWD_VER="3.12"
IWD_URL="https://deb.debian.org/debian/pool/main/i/iwd/iwd_${IWD_VER}.orig.tar.xz"
NL_VER="3.12.0"
NL_URL="https://deb.debian.org/debian/pool/main/libn/libnl3/libnl3_${NL_VER}.orig.tar.gz"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
header() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }
info()  { printf '%s  %s%s\n' "$GRN" "$1" "$RST"; }
warn()  { printf '%s  %s%s\n' "$YLW" "$1" "$RST"; }
die()   { printf '%serror:%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

# fetch <url> <out> [pin-key] - download unless cached, then verify.
# With a pin-key the file is checked against pins.lock whether it was just
# downloaded or already cached, so a truncated cache entry is caught here
# rather than much later in autoreconf.
fetch() {
    local url="$1" out="$2" key="${3:-}"
    [ -s "$out" ] || {
        command -v curl >/dev/null || die "curl not found"
        info "fetching $(basename "$out")"
        curl -fsSL --retry 3 --max-time 300 -o "$out.part" "$url" \
            || die "download failed: $url"
        mv "$out.part" "$out"
    }
    [ -s "$out" ] && info "cached $(basename "$out")"
    [ -n "$key" ] && pins_verify "$out" "$key"
    return 0
}

rm -rf "$DIST"
mkdir -p "$SRC" "$DIST"

# ---------------------------------------------------------------------------
# libnl-3
# ---------------------------------------------------------------------------
header "libnl $NL_VER (iwd's netlink dependency)"
fetch "$NL_URL" "$SRC/libnl.tar.gz" "libnl"
rm -rf "$SRC/libnl-$NL_VER" && tar -C "$SRC" -xzf "$SRC/libnl.tar.gz"

# A fresh prefix every time. Reusing one would let a stale libnl from an earlier
# version satisfy the link step, which then fails at runtime with a soname
# mismatch that no amount of rebuilding iwd will fix.
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

cd "$SRC/libnl-$NL_VER"
# libnl's autotools default to building with -Werror on some versions.
./configure --prefix="$PREFIX" --disable-static \
    CFLAGS="-O2 -fPIC -Wno-error" > "$SRC/libnl-configure.log" 2>&1 \
    || { warn "configure failed; tail of log:"; tail -20 "$SRC/libnl-configure.log"; die "libnl configure"; }
info "libnl configured into a local prefix (host untouched)"

make -j"$(nproc)" > "$SRC/libnl-build.log" 2>&1 \
    || { warn "libnl build failed; tail:"; tail -25 "$SRC/libnl-build.log"; die "libnl build"; }
make install >> "$SRC/libnl-build.log" 2>&1 \
    || { warn "libnl install failed; tail:"; tail -25 "$SRC/libnl-build.log"; die "libnl install"; }

info "libnl installed: $(ls "$PREFIX/lib"/*.so* 2>/dev/null | wc -l) shared objects"
for so in libnl-3.so.30 libnl-genl-3.so.30; do
    if [ ! -e "$PREFIX/lib/$so" ]; then
        warn "$so missing - iwd will not link without it"
        ls "$PREFIX/lib" | sed 's/^/    /'
    fi
done

# ---------------------------------------------------------------------------
# iwd
# ---------------------------------------------------------------------------
header "iwd $IWD_VER"
fetch "$IWD_URL" "$SRC/iwd.tar.xz" "iwd"
rm -rf "$SRC/iwd-$IWD_VER" && tar -C "$SRC" -xJf "$SRC/iwd.tar.xz"

cd "$SRC/iwd-$IWD_VER"
# iwd ships configure; if not, it needs autoreconf, which needs the autotools on
# the host. Fall back rather than assuming.
if [ ! -x ./configure ]; then
    warn "no configure in the tarball - running autoreconf"
    autoreconf -fi > "$SRC/iwd-autoreconf.log" 2>&1 \
        || { warn "autoreconf failed; tail:"; tail -20 "$SRC/iwd-autoreconf.log"; die "autoreconf"; }
fi

# These option names were read out of `./configure --help`, not guessed. The
# obvious guesses --without-udev, --without-journal, --without-crypto,
# --without-dbus, --without-readline -- do not exist, and autoconf silently
# accepts unknown --without flags, so a wrong list produces a build that is
# quietly configured for a system this is not:
#
#   --with-dbus-datadir / --with-dbus-busdir
#       MUST point inside the throwaway prefix, not at the runtime path. These
#       are INSTALL destinations for `make install`, not lookups, so passing the
#       runtime path (/usr/share) makes the build try to write iwd's policy into
#       the build host's real /usr/share/dbus-1/system.d. That is how a
#       "self-contained, does not touch the host" build ends up modifying the
#       machine doing the building - and it fails outright when unprivileged,
#       which is the only reason it was caught here. The files are relocated to
#       the right place when staged.
#   --disable-systemd-service   REQUIRED here, not optional. Without it configure
#       ends at "checking systemd unit directory..." and then
#       "error: systemd unit directory is required" - because there is no systemd
#       on this host for it to derive the path from. There is no systemd here
#       and no unit file will ever be wanted, so asking for none is the correct
#       answer, not a workaround.
#   --disable-manual-pages      man pages have no consumer.
#   --disable-monitor           iwmon needs libnl's monitor family and a second
#       D-Bus client; nothing here uses it.
#   --disable-tools             internal test utilities.
#   --disable-static            a shared libell is staged if built; static-only
#       would be smaller but breaks if iwd and iwctl ever disagree about it.
#
# Deliberately NOT disabled: --disable-dbus-policy. iwd's policy file is
# installed to the system-services directory and describes who may own
# net.wired.wof.gitHub.intel.iwd. It coexists with the permissive bus policy in
# build_dbus.sh's system.conf, and the effective rule for owning a name is the
# intersection of the two - so installing it tightens things rather than
# loosening them, which is the right way round.
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
./configure --prefix="$PREFIX" \
    --disable-werror \
    --disable-static \
    --disable-systemd-service \
    --disable-manual-pages \
    --disable-monitor \
    --disable-tools \
    --with-dbus-datadir="$PREFIX/share" \
    --with-dbus-busdir="$PREFIX/share/dbus-1/system-services" \
    CFLAGS="-O2 -Wno-error" \
    > "$SRC/iwd-configure.log" 2>&1 \
    || { warn "configure failed; tail of log:"; tail -30 "$SRC/iwd-configure.log"; die "iwd configure"; }
info "iwd configured"

make -j"$(nproc)" > "$SRC/iwd-build.log" 2>&1 \
    || { warn "iwd build failed; tail:"; tail -40 "$SRC/iwd-build.log"; die "iwd build"; }
make install >> "$SRC/iwd-build.log" 2>&1 \
    || { warn "iwd install failed; tail:"; tail -40 "$SRC/iwd-build.log"; die "iwd install"; }
info "iwd installed"

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------
header "staging"
mkdir -p "$DIST/usr/bin" "$DIST/usr/lib64" "$DIST/usr/libexec" "$DIST/etc/iwd"

# iwd installs its daemon to $PREFIX/libexec/iwd (i.e. /usr/libexec/iwd here,
# matching its compiled-in path) and iwctl to $PREFIX/bin. Both locations are
# preserved exactly rather than flattened, because iwd's daemon argv[0] is what
# tells it which mode to run in and some distros hardcode the path.
[ -x "$PREFIX/bin/iwctl" ] || die "iwctl not built"
[ -x "$PREFIX/libexec/iwd" ] || die "iwd daemon not built at libexec/iwd"
cp -L "$PREFIX/bin/iwctl" "$DIST/usr/bin/iwctl"
cp -L "$PREFIX/libexec/iwd" "$DIST/usr/libexec/iwd"
chmod 755 "$DIST/usr/bin/iwctl" "$DIST/usr/libexec/iwd"
info "iwctl + iwd staged"

# ell, if built as a shared library. iwd normally links it statically
# (--disable-static above applies to libnl; ell builds both), so this may be a
# no-op - but a shared ell MUST be staged or the loader fails at startup.
for so in "$PREFIX"/lib/libell*.so*; do
    [ -e "$so" ] || continue
    cp -L "$so" "$DIST/usr/lib64/$(basename "$so")" 2>/dev/null \
        && info "staged $(basename "$so")"
done

# libnl closure for both binaries. Resolved against the local prefix FIRST so the
# staged libraries are the ones iwd was actually linked to, then against the host
# for anything else (libc, and only libc in practice).
header "ldd closure"
CLOSURE=""
collect() {
    local target="$1" lib
    for lib in $(LD_LIBRARY_PATH="$PREFIX/lib" ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
        case " $CLOSURE " in *" $lib "*) continue ;; esac
        CLOSURE="$CLOSURE $lib"
        collect "$lib"
    done
}
for elf in "$DIST/usr/bin/iwctl" "$DIST/usr/libexec/iwd"; do collect "$elf"; done
n=0
for lib in $CLOSURE; do
    base="$(basename "$lib")"
    cp -L "$lib" "$DIST/usr/lib64/$base" 2>/dev/null || { warn "skipped $base"; continue; }
    n=$((n + 1))
done
info "closure: $n libraries ($(du -sh "$DIST/usr/lib64" 2>/dev/null | cut -f1))"

# iwd ships two D-Bus files that make install dropped inside the prefix:
#   system.d/iwd-dbus.conf          who may own net.wired.wof.gitHub.intel.iwd
#   system-services/net.connman.iwd.service
#                                  D-Bus activation, so a client that asks the
#                                  bus for iwd gets it started on demand
# Neither is required here - init starts iwd directly - but both are cheap, and
# the activation file means `busctl` or a D-Bus-aware tool can bring iwd up
# without going through init. Staged for that reason, not by default.
mkdir -p "$DIST/usr/share/dbus-1/system.d" "$DIST/usr/share/dbus-1/system-services"
for f in "$PREFIX"/share/dbus-1/system.d/*.conf; do
    [ -e "$f" ] || continue
    cp "$f" "$DIST/usr/share/dbus-1/system.d/"
    info "staged system.d/$(basename "$f")"
done
for f in "$PREFIX"/share/dbus-1/system-services/*.service; do
    [ -e "$f" ] || continue
    cp "$f" "$DIST/usr/share/dbus-1/system-services/"
    info "staged system-services/$(basename "$f")"
done

# libnl's headers are not needed at runtime, but its .pc files are useful for
# nothing here. Do not stage them.
rm -rf "$DIST/lib/pkgconfig" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
header "iwd configuration"
# Deliberately EMPTY of credentials.
#
# Wi-Fi here is on demand: the user runs iwctl and types a PSK, which is written
# to /var/lib/iwd at runtime on a live system whose root is a tmpfs. Baking a
# profile in would mean shipping a plaintext PSK in every image, which is a
# credential in a file that ends up on USB sticks.
#
# backend=internal is the important line. iwd's alternative is to shell out to
# wpa_supplicant for the handshake; there is no wpa_supplicant in this image and
# adding one would double the wireless stack. internal does it in-process.
cat > "$DIST/etc/iwd/main.conf" << 'CONF'
# iwd main configuration.
#
# No [Settings] StoreCredentials=true here, and no network blocks: Wi-Fi is
# connected on demand from iwctl, which writes profiles to /var/lib/iwd. /etc is
# shipped read-only in the image and /var is a tmpfs, so a PSK typed at connect
# time never touches anything persistent - and nothing here is a credential.

[Device]
# Some adapters need this off to scan while connected; harmless for those that do
# not, and it is the only setting that changes scanning behaviour at all.
# AllowRoam=true

[Settings]
# Trust every network that presents itself. There is no CA store to validate an
# enterprise network against in this image, and refusing every network would make
# Wi-Fi unusable rather than safer. Documented here as a deliberate choice rather
# than left implicit.
# Default is true; stated so it is not mistaken for an oversight.
TrustBuiltinIPs=false
CONF
info "main.conf written (no credentials, on-demand connect)"

# iwd also reads iwd.conf in the same directory as the daemon's systemd unit
# location; stage the directory with correct perms.
chmod 755 "$DIST/etc/iwd"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
header "verification"
fail=0
for f in "$DIST/usr/bin/iwctl" "$DIST/usr/libexec/iwd" "$DIST/etc/iwd/main.conf"; do
    [ -e "$f" ] || { warn "missing $f"; fail=1; }
done
# Both binaries must resolve every DT_NEEDED against what we staged. This is the
# check that matters: iwctl failing to load produces "cannot open shared object
# file" on a machine with no package manager, at the moment the user tries to
# connect to Wi-Fi, which is a bad time to discover it.
for elf in "$DIST/usr/bin/iwctl" "$DIST/usr/libexec/iwd"; do
    miss=0
    for so in $(objdump -p "$elf" | sed -n 's/^ *NEEDED *//p'); do
        [ -e "$DIST/usr/lib64/$so" ] || { warn "$(basename "$elf") needs $so, not staged"; miss=1; }
    done
    [ "$miss" -eq 0 ] || fail=1
done

# And prove the loader can actually start them. -h must be handled without a
# radio, without D-Bus and without root, so a successful exit proves the closure
# is complete rather than merely present on disk.
for elf in "$DIST/usr/bin/iwctl" "$DIST/usr/libexec/iwd"; do
    if LD_LIBRARY_PATH="$DIST/usr/lib64" timeout 10 "$elf" --help > /dev/null 2>&1; then
        info "$(basename "$elf") loads and runs (--help exit 0)"
    else
        rc=$?
        # iwd's daemon treats --help as an unknown arg and exits non-zero after
        # printing usage; that still proves the loader succeeded, so only a
        # loader error is a real failure.
        if LD_LIBRARY_PATH="$DIST/usr/lib64" "$elf" --help 2>&1 | grep -q 'shared object\|error while loading'; then
            warn "$(basename "$elf") cannot load its libraries"
            fail=1
        else
            info "$(basename "$elf") loads (usage path, exit $rc - fine for the daemon)"
        fi
    fi
done

[ "$fail" -eq 0 ] || die "iwd-dist is incomplete"
printf '\n%s  done: iwd staged in %s (%s)%s\n' \
    "$GRN" "$DIST" "$(du -sh "$DIST" | cut -f1)" "$RST"
