#!/usr/bin/env bash
# build_bluez.sh - stage bluetoothd and the BlueZ command-line tools.
#
# WHY SOURCE-BUILT.
#
# bluetoothctl and btmon exist on the build host, but bluetoothd - the daemon
# that actually owns the adapter - does not, and copying the two clients without
# the daemon would produce a bluetoothctl that lists nothing forever with no
# error. Worse, a host's client and a freshly built daemon would be different
# BlueZ versions speaking different D-Bus interface revisions, which fails at
# connect time with an unhelpful "org.bluez.Error.NotReady". So the whole tree
# is built from one source release and the clients come from the same build.
#
# BlueZ 5.87 is AUTOTOOLS, not meson. That was checked against the tarball rather
# than assumed - BlueZ has been moving build systems and the meson build landed
# later, so a script written from memory with meson options fails at the first
# command. The option list below was read out of configure.ac.
#
# WHAT IS TURNED OFF, AND WHY EACH ONE MATTERS.
#
# Most of these are not about size. Each is a runtime dependency this image does
# not have, and a daemon compiled to expect one tends to fail as a silent no-op
# rather than an error, which is the worst failure mode there is:
#
#   --disable-systemd      no systemd. Without this, bluetoothd tries to talk to
#                          systemd for adapter power and logs nothing useful when
#                          it cannot.
#   --disable-udev         no udev rules, no /run/udev. Bluetooth device
#                          permissions are set up by init instead (see the udev
#                          note in init.c). udev rules are also the single biggest
#                          reason a distro bluetoothd "starts" and then reports no
#                          adapters.
#   --disable-cups         no printer stack.
#   --disable-obex         no OBEX file transfer.
#   --disable-mesh         no mesh support; needs newer controllers to mean
#                          anything and drags in provisioning paths.
#   --disable-nfc          no NFC.
#   --disable-hid          no HID profile: this image has no bluetooth input
#                          device handling, and a half-working HID stack is worse
#                          than none because the cursor problem it would cause is
#                          indistinguishable from a graphics fault.
#   --disable-manpages     no consumers.
#   --disable-datafiles    stages policy/config files this image writes itself.
#
# KEPT: --enable-debug=no (default), --enable-library (libbluetooth is used by
# nothing here, so it is left at its default and simply not staged), and the
# protocol plugins (a2dp/avrcp/hfp/etc), which are compiled in and harmless - they
# are what makes a paired phone actually do something once connected.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/bluesz-src"
PREFIX="$ROOT/bluesz-prefix"
DIST="$ROOT/bluesz-dist"
# DESTDIR for the staged install. Declared with the rest of the paths because the
# rm -rf below runs before any staging happens and `set -u` will abort on a use
# before definition.
STAGE="$ROOT/bluesz-stage"

VER="5.87"
URL="https://github.com/bluez/bluez/archive/refs/tags/${VER}.tar.gz"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
header() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }
info()  { printf '%s  %s%s\n' "$GRN" "$1" "$RST"; }
warn()  { printf '%s  %s%s\n' "$YLW" "$1" "$RST"; }
die()   { printf '%serror:%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

mkdir -p "$SRC"
TARBALL="$SRC/bluez-${VER}.tar.gz"
if [ ! -s "$TARBALL" ]; then
    command -v curl >/dev/null || die "curl not found"
    info "fetching bluez ${VER}"
    curl -fsSL --retry 3 --max-time 300 -o "$TARBALL.part" "$URL" || die "download failed: $URL"
    mv "$TARBALL.part" "$TARBALL"
else
    info "cached bluez-${VER}.tar.gz"
fi

rm -rf "$DIST" "$PREFIX" "$STAGE" "$SRC/bluez-${VER}"
mkdir -p "$DIST" "$PREFIX"
tar -C "$SRC" -xzf "$TARBALL"
cd "$SRC/bluez-${VER}"

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------
header "configure"
# A release tarball from a tag has no configure script - autotools output is not
# committed. autoreconf therefore is not a fallback here, it is required.
if [ ! -x ./configure ]; then
    info "no configure in the tarball - running autoreconf (required for a tag tarball)"
    autoreconf -fi > "$SRC/bluez-autoreconf.log" 2>&1 \
        || { warn "autoreconf failed; tail:"; tail -25 "$SRC/bluez-autoreconf.log"; die "autoreconf"; }
fi

# Every --with dir MUST be inside the prefix. These are install destinations, not
# lookups: passing the runtime path (/etc/dbus-1, /lib/udev, /usr/lib/systemd)
# makes make install write into the build host, which fails unprivileged and
# silently pollutes the machine when run as root.
./configure --prefix="$PREFIX" \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-static \
    --disable-systemd \
    --disable-udev \
    --disable-cups \
    --disable-obex \
    --disable-mesh \
    --disable-nfc \
    --disable-hid \
    --disable-manpages \
    --disable-datafiles \
    --with-dbusconfdir="$PREFIX/etc/dbus-1" \
    --with-dbussystembusdir="$PREFIX/share/dbus-1/system-services" \
    --with-dbussessionbusdir="$PREFIX/share/dbus-1/services" \
    --with-udevdir="$PREFIX/lib/udev" \
    --with-systemdsystemunitdir="$PREFIX/lib/systemd/system" \
    --with-systemduserunitdir="$PREFIX/lib/systemd/user" \
    CFLAGS="-O2 -Wno-error" \
    > "$SRC/bluez-configure.log" 2>&1 \
    || { warn "configure failed; tail of log:"; tail -35 "$SRC/bluez-configure.log"; die "configure"; }

# Report what it actually decided, because the whole point of the flags above is
# that a silently-ignored one changes nothing. --disable-udev in particular can
# be dropped by an option rename, and the resulting bluetoothd binds no adapter
# for reasons that appear nowhere in the log.
# Verify the flags took effect by reading config.h, which is authoritative, not
# config.log. config.log only echoes the command line, so every check against it
# trivially passes - which is precisely the failure this is meant to catch.
# A feature left enabled compiles in a runtime dependency this image does not have,
# and it fails as a silent no-op rather than an error.
missing=0
for opt in udev systemd cups obex mesh nfc hid; do
    if grep -qE "^#define ENABLE_$(echo "$opt" | tr a-z A-Z)_SUPPORT" config.h 2>/dev/null; then
        echo "    *** $opt is STILL COMPILED IN - the flag was ignored ***"
        missing=1
    fi
done
if [ "$missing" -eq 0 ]; then
    info "all 7 --disable flags took effect (config.h has no ENABLE_*_SUPPORT)"
else
    warn "at least one --disable flag was ignored - see above"
    exit 1
fi

header "build"
make -j"$(nproc)" > "$SRC/bluez-build.log" 2>&1 \
    || { warn "build failed; tail:"; tail -40 "$SRC/bluez-build.log"; die "build"; }
# DESTDIR IS REQUIRED, NOT COSMETIC.
#
# BlueZ's own install step ends with a target that hardcodes the *configured*
# paths:
#
#     bluetoothd-fix-permissions:
#             install -dm755 $(DESTDIR)$(confdir)
#             install -dm700 $(DESTDIR)$(statedir)
#
# Without DESTDIR that is `install -dm755 /etc/bluetooth`, which chmods a
# directory on the machine doing the building - it fails outright when
# unprivileged (how this was found) and silently mutates the build host when run
# as root. Every --with path above is already prefix-relative, but this target is
# the one that reaches outside the prefix, so it is the one that decides whether
# the build is hermetic.
#
# Staged install also means the binary and its data files are taken from the same
# DESTDIR tree, so they cannot drift apart.
make install DESTDIR="$STAGE" >> "$SRC/bluez-build.log" 2>&1 \
    || { warn "install failed; tail:"; tail -40 "$SRC/bluez-build.log"; die "install"; }
info "bluez $VER built and installed into DESTDIR"

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------
header "staging"
mkdir -p "$DIST/usr/bin" "$DIST/usr/lib64" "$DIST/usr/libexec" "$DIST/etc/bluetooth"

# bluetoothd lands in $PREFIX/libexec/bluetooth/bluetoothd, not libexec directly.
# The nested path is preserved because that is where its compiled-in default is,
# and the D-Bus service file we stage below refers to it by that exact path.
BTD=""
for cand in "$STAGE$PREFIX/libexec/bluetooth/bluetoothd" "$STAGE$PREFIX/libexec/bluetoothd"; do
    [ -x "$cand" ] && { BTD="$cand"; break; }
done
  [ -n "$BTD" ] || die "bluetoothd not found under $STAGE$PREFIX/libexec"
  # Create the destination explicitly and verify it, rather than relying on
  # `mkdir -p "$(dirname ...)"` inline: when cp reported "cannot create regular
  # file" for the destination the parent was in fact already there, which means
  # the failure was not a missing directory and should not have been papered over
  # by adding one more mkdir. Checking makes the real cause visible next time.
  BTDIST_DIR="$DIST/usr/libexec/bluetooth"
  mkdir -p "$BTDIST_DIR" || die "cannot create $BTDIST_DIR"
  [ -d "$BTDIST_DIR" ] || die "$BTDIST_DIR is not a directory"
  cp -L "$BTD" "$BTDIST_DIR/bluetoothd" || die "cannot copy bluetoothd from $BTD"
  chmod 755 "$BTDIST_DIR/bluetoothd"
  info "bluetoothd staged at /usr/libexec/bluetooth/bluetoothd"


# Clients from the SAME build as the daemon - see the header for why mixing a
# host's bluetoothctl with a built daemon is a bad idea.
for tool in bluetoothctl btmon btmgmt; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$src" ] && [ ! -x "$PREFIX/bin/$tool" ]; then
        : # prefer the freshly built one below
    fi
    if [ -x "$STAGE$PREFIX/bin/$tool" ]; then
        cp -L "$STAGE$PREFIX/bin/$tool" "$DIST/usr/bin/$tool"
        chmod 755 "$DIST/usr/bin/$tool"
        info "$tool staged (from this build)"
    elif [ -n "$src" ]; then
        cp -L "$src" "$DIST/usr/bin/$tool"
        chmod 755 "$DIST/usr/bin/$tool"
        warn "$tool not built here - copied from the host (version skew risk)"
    else
        warn "$tool unavailable, not staged"
    fi
done

# ---------------------------------------------------------------------------
# D-Bus service file
# ---------------------------------------------------------------------------
header "dbus activation"
# org.bluez.service. Without it the bus cannot start bluetoothd on demand, so a
# client that asks for net.weld's name gets "service unknown". init starts the
# daemon directly, so this is belt and braces - but it is what makes
# `busctl status org.bluez` behave, and it costs nothing.
mkdir -p "$DIST/usr/share/dbus-1/system-services"
cat > "$DIST/usr/share/dbus-1/system-services/org.bluez.service" << 'SERVICE'
[D-BUS Service]
Name=org.bluez
Exec=/usr/libexec/bluetooth/bluetoothd
User=root
SystemdService=bluetooth.service
SERVICE
info "org.bluez.service staged"

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
for elf in "$DIST"/usr/bin/* "$DIST/usr/libexec/bluetooth/bluetoothd"; do
    [ -f "$elf" ] || continue
    collect "$elf"
done
n=0
for lib in $CLOSURE; do
    base="$(basename "$lib")"
    cp -L "$lib" "$DIST/usr/lib64/$base" 2>/dev/null || { warn "skipped $base"; continue; }
    n=$((n + 1))
done
info "closure: $n libraries ($(du -sh "$DIST/usr/lib64" | cut -f1))"

# libbluetooth is built by default and linked by nothing staged above. Drop it if
# it got pulled in - it is a socket API wrapper and would only add weight.
rm -f "$DIST/usr/lib64/libbluetooth.so"* 2>/dev/null || true

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
header "verification"
fail=0
BTD="$DIST/usr/libexec/bluetooth/bluetoothd"
for f in "$BTD" "$DIST/usr/bin/bluetoothctl" "$DIST/usr/share/dbus-1/system-services/org.bluez.service"; do
    [ -e "$f" ] || { warn "missing $f"; fail=1; }
done

# bluetoothd exits non-zero for --help, so the check is "the loader succeeded",
# not "the exit status was zero". Distinguishing them matters: a load failure and
# a usage error look identical if only the status is examined.
for elf in "$BTD" "$DIST/usr/bin/bluetoothctl"; do
    [ -f "$elf" ] || continue
    out="$(LD_LIBRARY_PATH="$DIST/usr/lib64" timeout 10 "$elf" --help 2>&1 || true)"
    if printf '%s' "$out" | grep -q 'shared object\|error while loading'; then
        warn "$(basename "$elf") cannot load its libraries:"
        printf '%s\n' "$out" | head -3 | sed 's/^/    /'
        fail=1
    else
        info "$(basename "$elf") loads ($(printf '%s' "$out" | head -1 | cut -c1-50))"
    fi
done

# Every DT_NEEDED present. bluetoothd links glib and libudev; if either is
# missing the failure is at service start, on a machine with no package manager,
# as "cannot open shared object file".
for elf in "$BTD" "$DIST/usr/bin/bluetoothctl"; do
    [ -f "$elf" ] || continue
    for so in $(objdump -p "$elf" | sed -n 's/^ *NEEDED *//p'); do
        [ -e "$DIST/usr/lib64/$so" ] || { warn "$(basename "$elf") needs $so, not staged"; fail=1; }
    done
done

[ "$fail" -eq 0 ] || die "bluesz-dist is incomplete"
printf '\n%s  done: BlueZ staged in %s (%s)%s\n' \
    "$GRN" "$DIST" "$(du -sh "$DIST" | cut -f1)" "$RST"
