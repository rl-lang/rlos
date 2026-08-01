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

    echo "==> installing cage, foot, and wayland/EGL runtime libs into $WLROOT"
    if ! sudo pacman -Sy --config "$PACCONF" --root "$WLROOT" --dbpath "$WLROOT/var/lib/pacman" \
        --noconfirm cage foot wayland libxkbcommon mesa; then
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

copy_deps_from_root() {
    local bin="$1"
    local pkgroot="$2"
    local needed
    needed="$(readelf -d "$bin" 2>/dev/null | grep NEEDED | sed -E 's/.*\[(.*)\].*/\1/')"
    for soname in $needed; do
        local found
        found="$(find "$pkgroot/usr/lib" "$pkgroot/lib" -name "$soname" 2>/dev/null | head -n1)"
        if [[ -z "$found" ]]; then
            echo "warning: $soname not found under $pkgroot, skipping" >&2
            continue
        fi
        local dest_dir="$ROOTFS$(dirname "${found#$pkgroot}")"
        mkdir -p "$dest_dir"
        if [[ ! -f "$dest_dir/$(basename "$found")" ]]; then
            cp -Pn "$found" "$dest_dir/" 2>/dev/null || true
            copy_deps_from_root "$found" "$pkgroot"
        fi
    done
}

echo "==> copying cage's own deps"
copy_deps_from_root "$CAGE_BIN" "$WLROOT"

echo "==> copying foot's own deps"
copy_deps_from_root "$FOOT_BIN" "$WLROOT"

echo "==> copying rl's own Wayland/EGL deps"
copy_deps_from_root "$RL_BIN" "$WLROOT"

echo "==> done. rebuild disk.img to pick these up: ./build_disk.sh"
