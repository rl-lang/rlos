#!/usr/bin/env bash
set -euo pipefail

X11ROOT="x11root"
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

for tool in pacman ldd strace; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

XORG_BIN="$X11ROOT/usr/bin/Xorg"

if [[ -f "$XORG_BIN" ]]; then
    echo "==> $XORG_BIN already present, skipping pacman install"
else
    echo "==> initializing isolated pacman root at $X11ROOT"
    sudo mkdir -p "$X11ROOT/var/lib/pacman"

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

    if ! sudo pacman-key --init --gpgdir "$X11ROOT/etc/pacman.d/gnupg" 2>/dev/null; then
        echo "note: pacman-key init skipped or already done"
    fi

    echo "==> installing xorg-server, mesa, qxl driver into $X11ROOT"
    if ! sudo pacman -Sy --config "$PACCONF" --root "$X11ROOT" --dbpath "$X11ROOT/var/lib/pacman" \
        --noconfirm xorg-server mesa xf86-video-qxl; then
        echo "error: pacman install into $X11ROOT failed" >&2
        rm -f "$PACCONF"
        exit 1
    fi
    rm -f "$PACCONF"

    if [[ ! -f "$XORG_BIN" ]]; then
        echo "error: $XORG_BIN not found after install" >&2
        exit 1
    fi

    echo "==> fixing ownership of $X11ROOT back to $(whoami)"
    sudo chown -R "$(id -u):$(id -g)" "$X11ROOT"
fi

if [[ -f "$ROOTFS/usr/bin/Xorg" ]]; then
    echo "==> $ROOTFS/usr/bin/Xorg already present, skipping copy"
else
    echo "==> copying Xorg and its dependencies into $ROOTFS"
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib"
    cp "$XORG_BIN" "$ROOTFS/usr/bin/"
    [[ -d "$X11ROOT/usr/lib/xorg" ]] && cp -r "$X11ROOT/usr/lib/xorg" "$ROOTFS/usr/lib/"
fi

copy_deps_from_root() {
    local bin="$1"
    local pkgroot="$2"
    local deps
    deps="$(ldd "$bin" 2>/dev/null | awk '{print $3}' | grep '^/' || true)"
    for lib in $deps; do
        local src="$pkgroot$lib"
        if [[ -f "$src" ]]; then
            mkdir -p "$ROOTFS$(dirname "$lib")"
            cp -n "$src" "$ROOTFS$(dirname "$lib")/" 2>/dev/null || true
        else
            echo "warning: $lib not found under $pkgroot, skipping" >&2
        fi
    done
}

copy_deps_from_root "$XORG_BIN" "$X11ROOT"

echo "==> tracing rl's GUI runtime dependencies (software rendering forced)"
TRACE_LOG="$(mktemp)"
LIBGL_ALWAYS_SOFTWARE=1 strace -f -e trace=open,openat "$RL_BIN" --version \
    > /dev/null 2> "$TRACE_LOG" || true

GUI_DEPS="$(grep -oE '/usr/lib/[^"]+\.so[^"]*' "$TRACE_LOG" | sort -u || true)"
rm -f "$TRACE_LOG"

if [[ -z "$GUI_DEPS" ]]; then
    echo "warning: no GUI .so dependencies captured - trace this manually against your actual GUI test program if needed"
else
    for lib in $GUI_DEPS; do
        src="$X11ROOT$lib"
        if [[ -f "$src" ]]; then
            cp -n "$src" "$ROOTFS/usr/lib/" 2>/dev/null || true
        elif [[ -f "$lib" ]]; then
            echo "note: $lib taken from host, not $X11ROOT (not packaged there)" >&2
        else
            echo "warning: $lib not found anywhere, skipping" >&2
        fi
    done
fi

echo "==> done. Reminder: repack initramfs and boot with a real display, e.g."
echo "    ./compile_initramfs.sh"
echo "    qemu-system-x86_64 -kernel bzImage -initrd initramfs.img -vga qxl -display gtk -m 512"
echo "Inside rlsh: export LIBGL_ALWAYS_SOFTWARE=1 && Xorg :0 & DISPLAY=:0 rl your_gui_test.rl"
