#!/usr/bin/env bash
# build_bluez.sh - stage bluetoothd and the BlueZ command-line tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/pins.sh"
SRC="$ROOT/bluesz-src"
PREFIX="$ROOT/bluesz-prefix"
DIST="$ROOT/bluesz-dist"
STAGE="$ROOT/bluesz-stage"

VER="5.87"
URL="https://github.com/bluez/bluez/archive/refs/tags/${VER}.tar.gz"

source "$ROOT/build-lib.sh"

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
pins_verify "$TARBALL" bluez

rm -rf "$DIST" "$PREFIX" "$STAGE" "$SRC/bluez-${VER}"
mkdir -p "$DIST" "$PREFIX"
tar -C "$SRC" -xzf "$TARBALL"
cd "$SRC/bluez-${VER}"

# ------------
header "configure"
if [ ! -x ./configure ]; then
    info "no configure in the tarball - running autoreconf (required for a tag tarball)"
    autoreconf -fi > "$SRC/bluez-autoreconf.log" 2>&1 \
        || { warn "autoreconf failed; tail:"; tail -25 "$SRC/bluez-autoreconf.log"; die "autoreconf"; }
fi

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
make install DESTDIR="$STAGE" >> "$SRC/bluez-build.log" 2>&1 \
    || { warn "install failed; tail:"; tail -40 "$SRC/bluez-build.log"; die "install"; }
info "bluez $VER built and installed into DESTDIR"

# ------------
header "staging"
mkdir -p "$DIST/usr/bin" "$DIST/usr/lib64" "$DIST/usr/libexec" "$DIST/etc/bluetooth"

BTD=""
for cand in "$STAGE$PREFIX/libexec/bluetooth/bluetoothd" "$STAGE$PREFIX/libexec/bluetoothd"; do
    [ -x "$cand" ] && { BTD="$cand"; break; }
done
  [ -n "$BTD" ] || die "bluetoothd not found under $STAGE$PREFIX/libexec"
  BTDIST_DIR="$DIST/usr/libexec/bluetooth"
  mkdir -p "$BTDIST_DIR" || die "cannot create $BTDIST_DIR"
  [ -d "$BTDIST_DIR" ] || die "$BTDIST_DIR is not a directory"
  cp -L "$BTD" "$BTDIST_DIR/bluetoothd" || die "cannot copy bluetoothd from $BTD"
  chmod 755 "$BTDIST_DIR/bluetoothd"
  info "bluetoothd staged at /usr/libexec/bluetooth/bluetoothd"


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

# ------------
header "dbus activation"
mkdir -p "$DIST/usr/share/dbus-1/system-services"
cat > "$DIST/usr/share/dbus-1/system-services/org.bluez.service" << 'SERVICE'
[D-BUS Service]
Name=org.bluez
Exec=/usr/libexec/bluetooth/bluetoothd
User=root
SystemdService=bluetooth.service
SERVICE
info "org.bluez.service staged"

# ------------
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

rm -f "$DIST/usr/lib64/libbluetooth.so"* 2>/dev/null || true

# ------------
header "verification"
fail=0
BTD="$DIST/usr/libexec/bluetooth/bluetoothd"
for f in "$BTD" "$DIST/usr/bin/bluetoothctl" "$DIST/usr/share/dbus-1/system-services/org.bluez.service"; do
    [ -e "$f" ] || { warn "missing $f"; fail=1; }
done

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

for elf in "$BTD" "$DIST/usr/bin/bluetoothctl"; do
    [ -f "$elf" ] || continue
    for so in $(objdump -p "$elf" | sed -n 's/^ *NEEDED *//p'); do
        [ -e "$DIST/usr/lib64/$so" ] || { warn "$(basename "$elf") needs $so, not staged"; fail=1; }
    done
done

[ "$fail" -eq 0 ] || die "bluesz-dist is incomplete"
printf '\n%s  done: BlueZ staged in %s (%s)%s\n' \
    "$GRN" "$DIST" "$(du -sh "$DIST" | cut -f1)" "$RST"
