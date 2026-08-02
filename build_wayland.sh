#!/usr/bin/env bash
set -euo pipefail

WLROOT="wlroot"
ROOTFS="rootfs"
RL_BIN="$(command -v rl || true)"

if [[ ! -d "$ROOTFS" ]]; then
    echo "error: $ROOTFS not found - run build_rootfs.sh first" >&2
    exit 1
fi

if [[ -z "$RL_BIN" ]]; then
    echo "error: rl not found on PATH" >&2
    exit 1
fi

for tool in pacman readelf find; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

CAGE_BIN="$WLROOT/usr/bin/cage"
FOOT_BIN="$WLROOT/usr/bin/foot"
SEATD_BIN="$WLROOT/usr/bin/seatd"
SEATD_LAUNCH_BIN="$WLROOT/usr/bin/seatd-launch"

if [[ -f "$CAGE_BIN" && -f "$FOOT_BIN" ]]; then
    echo "==> $CAGE_BIN and $FOOT_BIN already present, skipping pacman install"
else
    echo "==> initializing isolated pacman root at $WLROOT"
    sudo mkdir -p "$WLROOT/var/lib/pacman"

    PACCONF="$(mktemp)"
    cat > "$PACCONF" << 'EOF'
[options]
DownloadUser = root
Architecture = auto
SigLevel = Never
[core]
SigLevel = Never
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
[extra]
SigLevel = Never
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF

    if ! sudo pacman-key --init --gpgdir "$WLROOT/etc/pacman.d/gnupg" 2>/dev/null; then
        echo "note: pacman-key init skipped or already done"
    fi

    echo "==> installing cage, foot, seatd, and wayland/EGL runtime libs into $WLROOT"
    if ! sudo pacman -Sy --config "$PACCONF" --root "$WLROOT" --dbpath "$WLROOT/var/lib/pacman" \
        --noconfirm cage foot wayland libxkbcommon mesa seatd ttf-dejavu systemd xkeyboard-config libx11; then
        echo "error: pacman install into $WLROOT failed" >&2
        rm -f "$PACCONF"
        exit 1
    fi
    rm -f "$PACCONF"

    if [[ ! -f "$CAGE_BIN" || ! -f "$FOOT_BIN" ]]; then
        echo "error: cage or foot not found after install" >&2
        exit 1
    fi

    echo "==> fixing ownership of $WLROOT back to $(whoami)"
    sudo chown -R "$(id -u):$(id -g)" "$WLROOT"
fi

echo "==> copying cage and foot into $ROOTFS"
mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib" "$ROOTFS/usr/share/foot"
cp "$CAGE_BIN" "$ROOTFS/usr/bin/"
cp "$FOOT_BIN" "$ROOTFS/usr/bin/"
[[ -d "$WLROOT/usr/share/foot" ]] && cp -r "$WLROOT/usr/share/foot"/. "$ROOTFS/usr/share/foot/" 2>/dev/null || true

echo "==> copying seatd and seatd-launch into $ROOTFS"
[[ -f "$SEATD_BIN" ]] && cp "$SEATD_BIN" "$ROOTFS/usr/bin/" || echo "warning: $SEATD_BIN not found, skipping"
[[ -f "$SEATD_LAUNCH_BIN" ]] && cp "$SEATD_LAUNCH_BIN" "$ROOTFS/usr/bin/" || echo "warning: $SEATD_LAUNCH_BIN not found, skipping"

copy_deps_from_root() {
    local bin="$1"
    local pkgroot="$2"
    local needed
    needed="$(readelf -d "$bin" 2>/dev/null | grep NEEDED | sed -E 's/.*\[(.*)\].*/\1/')" || true
    for soname in $needed; do
        local found
        found="$(find "$pkgroot/usr/lib" "$pkgroot/lib" -name "$soname" 2>/dev/null | head -n1)" || true
        if [[ -z "$found" ]]; then
            echo "warning: $soname not found under $pkgroot, skipping" >&2
            continue
        fi
        local dest_dir="$ROOTFS$(dirname "${found#$pkgroot}")"
        mkdir -p "$dest_dir"
        # resolve symlink chain and copy the real target too, not just the link
        local real
        real="$(readlink -f "$found")"
        if [[ ! -f "$dest_dir/$(basename "$real")" ]]; then
            cp -n "$real" "$dest_dir/" 2>/dev/null || true
        fi
        if [[ ! -e "$dest_dir/$(basename "$found")" ]]; then
            cp -Pn "$found" "$dest_dir/" 2>/dev/null || true
        fi
        copy_deps_from_root "$real" "$pkgroot"
    done
}

echo "==> copying cage's own deps"
copy_deps_from_root "$CAGE_BIN" "$WLROOT"
echo "==> copying foot's own deps"
copy_deps_from_root "$FOOT_BIN" "$WLROOT"
echo "==> copying rl's own Wayland/EGL deps"
copy_deps_from_root "$RL_BIN" "$WLROOT"
echo "==> copying seatd's own deps"
[[ -f "$SEATD_BIN" ]] && copy_deps_from_root "$SEATD_BIN" "$WLROOT"
echo "==> copying seatd-launch's own deps"
[[ -f "$SEATD_LAUNCH_BIN" ]] && copy_deps_from_root "$SEATD_LAUNCH_BIN" "$WLROOT"

echo "==> copying EGL vendor config and mesa's runtime-loaded drivers"
# libEGL.so.1 (already copied above as a NEEDED dep of cage) is just a
# glvnd dispatch loader: at runtime it reads JSON ICD files under
# /usr/share/glvnd/egl_vendor.d/ and dlopen()s the driver named inside
# (libEGL_mesa.so.0), which then itself dlopen()s the Gallium/DRI module
# matching the kernel driver name (virtio_gpu_dri.so). None of that shows
# up in a readelf NEEDED walk, so it has to be copied explicitly.
mkdir -p "$ROOTFS/usr/share/glvnd/egl_vendor.d" "$ROOTFS/usr/lib/dri"

if [[ -d "$WLROOT/usr/share/glvnd/egl_vendor.d" ]]; then
    cp -a "$WLROOT/usr/share/glvnd/egl_vendor.d/." "$ROOTFS/usr/share/glvnd/egl_vendor.d/"
else
    echo "warning: no EGL vendor.d configs found under $WLROOT - EGL will find no driver" >&2
fi

for lib in "$WLROOT"/usr/lib/libEGL_mesa.so* "$WLROOT"/usr/lib/libGLX_mesa.so* "$WLROOT"/usr/lib/libglapi.so*; do
    [[ -e "$lib" ]] || continue
    real="$(readlink -f "$lib")"
    [[ -f "$real" ]] && cp -n "$real" "$ROOTFS/usr/lib/" 2>/dev/null || true
    cp -Pn "$lib" "$ROOTFS/usr/lib/" 2>/dev/null || true
    copy_deps_from_root "$real" "$WLROOT"
done

DRI_DRIVER="$(find "$WLROOT/usr/lib/dri" -name 'virtio_gpu_dri.so' 2>/dev/null | head -n1)"
if [[ -n "$DRI_DRIVER" ]]; then
    cp -n "$DRI_DRIVER" "$ROOTFS/usr/lib/dri/"
    copy_deps_from_root "$DRI_DRIVER" "$WLROOT"
else
    echo "warning: virtio_gpu_dri.so not found under $WLROOT/usr/lib/dri - EGL rendering will still fail" >&2
fi
# swrast as a software fallback in case the virtio_gpu 3D path still
# doesn't pan out (host without working virgl, etc).
SWRAST_DRIVER="$(find "$WLROOT/usr/lib/dri" -name 'swrast_dri.so' 2>/dev/null | head -n1)"
if [[ -n "$SWRAST_DRIVER" ]]; then
    cp -n "$SWRAST_DRIVER" "$ROOTFS/usr/lib/dri/"
    copy_deps_from_root "$SWRAST_DRIVER" "$WLROOT"
fi

echo "==> copying GBM's own DRI loader module"
# libgbm has its own, separate plugin convention from libEGL: it looks
# for <driver>_gbm.so under /usr/lib/gbm specifically, not /usr/lib/dri.
# Same dlopen()-not-linked story as above, so copy it explicitly too.
mkdir -p "$ROOTFS/usr/lib/gbm"
if [[ -d "$WLROOT/usr/lib/gbm" ]]; then
    for gbmlib in "$WLROOT"/usr/lib/gbm/*_gbm.so; do
        [[ -e "$gbmlib" ]] || continue
        cp -n "$gbmlib" "$ROOTFS/usr/lib/gbm/"
        copy_deps_from_root "$gbmlib" "$WLROOT"
    done
else
    echo "warning: $WLROOT/usr/lib/gbm not found - gbm_create_device will fail" >&2
fi

echo "==> copying libinput device-quirks database"
# libinput refuses to enumerate any input devices without its quirks
# data files (keyboard/mouse/touchpad heuristics), which live under
# /usr/share/libinput and aren't linked by anything - just read from
# disk by path at startup.
mkdir -p "$ROOTFS/usr/share/libinput"
if [[ -d "$WLROOT/usr/share/libinput" ]]; then
    cp -a "$WLROOT/usr/share/libinput/." "$ROOTFS/usr/share/libinput/"
else
    echo "warning: $WLROOT/usr/share/libinput not found - libinput will find no input devices" >&2
fi

echo "==> copying X11 locale/Compose data (libxkbcommon compose-table support)"
mkdir -p "$ROOTFS/usr/share/X11/locale"
if [[ -d "$WLROOT/usr/share/X11/locale" ]]; then
    cp -a "$WLROOT/usr/share/X11/locale/." "$ROOTFS/usr/share/X11/locale/"
else
    echo "warning: $WLROOT/usr/share/X11/locale not found - compose table will fail to load and dead keys/some apps may crash on it" >&2
fi

echo "==> copying xkeyboard-config data (keymaps for xkbcommon)"
mkdir -p "$ROOTFS/usr/share/xkeyboard-config-2"
if [[ -d "$WLROOT/usr/share/xkeyboard-config-2" ]]; then
    cp -a "$WLROOT/usr/share/xkeyboard-config-2/." "$ROOTFS/usr/share/xkeyboard-config-2/"
else
    echo "error: $WLROOT/usr/share/xkeyboard-config-2 not found - is xkeyboard-config installed there?" >&2
    exit 1
fi

echo "==> copying systemd-udevd, udevadm, and udev rules/hwdb"
UDEVD_BIN="$WLROOT/usr/lib/systemd/systemd-udevd"
UDEVADM_BIN="$WLROOT/usr/bin/udevadm"
mkdir -p "$ROOTFS/usr/lib/systemd" "$ROOTFS/usr/lib/udev/rules.d"
if [[ -f "$UDEVD_BIN" && -f "$UDEVADM_BIN" ]]; then
    cp "$UDEVD_BIN" "$ROOTFS/usr/lib/systemd/"
    cp "$UDEVADM_BIN" "$ROOTFS/usr/bin/"
    copy_deps_from_root "$UDEVD_BIN" "$WLROOT"
    copy_deps_from_root "$UDEVADM_BIN" "$WLROOT"
else
    echo "error: systemd-udevd or udevadm not found under $WLROOT - did pacman install systemd?" >&2
    exit 1
fi
[[ -d "$WLROOT/usr/lib/udev/rules.d" ]] && cp -a "$WLROOT/usr/lib/udev/rules.d/." "$ROOTFS/usr/lib/udev/rules.d/"
HWDB_BIN="$(find "$WLROOT/usr/lib/udev" "$WLROOT/etc/udev" -name 'hwdb.bin' 2>/dev/null | head -n1)"
if [[ -n "$HWDB_BIN" ]]; then
    mkdir -p "$ROOTFS/$(dirname "${HWDB_BIN#$WLROOT}")"
    cp "$HWDB_BIN" "$ROOTFS/$(dirname "${HWDB_BIN#$WLROOT}")/"
else
    echo "warning: hwdb.bin not found under $WLROOT - run 'systemd-hwdb update' there first" >&2
fi

echo "==> copying C.utf8 locale into the rootfs"
# glibc itself ships a pre-compiled C.utf8 locale directory (added in
# glibc 2.35) - no localedef needed, just copy it straight out of
# wlroot. Directory name on disk is lowercase "C.utf8" (glibc's normal
# locale-naming convention); setlocale(LC_CTYPE, "C.UTF-8") at runtime
# still matches it fine, same as en_US.UTF-8 matching en_US.utf8.
mkdir -p "$ROOTFS/usr/lib/locale"
if [[ -d "$WLROOT/usr/lib/locale/C.utf8" ]]; then
    cp -a "$WLROOT/usr/lib/locale/C.utf8" "$ROOTFS/usr/lib/locale/"
else
    echo "error: C.utf8 locale not found under $WLROOT/usr/lib/locale - is glibc installed there?" >&2
    exit 1
fi

echo "==> copying fontconfig config, fonts, and cache into the rootfs"
mkdir -p "$ROOTFS/etc/fonts" "$ROOTFS/usr/share/fonts" "$ROOTFS/var/cache/fontconfig"
if [[ -d "$WLROOT/etc/fonts" ]]; then
    cp -a "$WLROOT/etc/fonts/." "$ROOTFS/etc/fonts/"
else
    echo "error: $WLROOT/etc/fonts not found - is fontconfig installed there?" >&2
    exit 1
fi
if [[ -d "$WLROOT/usr/share/fonts" ]]; then
    cp -a "$WLROOT/usr/share/fonts/." "$ROOTFS/usr/share/fonts/"
else
    echo "error: $WLROOT/usr/share/fonts not found - is ttf-dejavu installed there?" >&2
    exit 1
fi
# reuse the cache pacman's post-install hook already generated in wlroot,
# so foot doesn't have to scan/rebuild it itself at boot
[[ -d "$WLROOT/var/cache/fontconfig" ]] && cp -a "$WLROOT/var/cache/fontconfig/." "$ROOTFS/var/cache/fontconfig/"

echo "==> done. rebuild disk.img to pick these up: ./build_disk.sh"
