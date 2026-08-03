#!/usr/bin/env bash
# Boot the persistent disk: GRUB in the image loads the kernel, the kernel
# mounts root=/dev/vda2 and runs /sbin/init. No -kernel: this tests the true
# bootloader path, not just the kernel.
# Runs from rlos-disk/.
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"

DISK="disk.img"

usage() {
    cat << 'USAGE'
Boot the persistent disk image under QEMU (BIOS).

  ./run_qemu.sh            headless: output on the terminal via serial
  ./run_qemu.sh --video    open a real display window, so the VGA text
                           console path actually gets exercised
USAGE
}

VIDEO=0
case "${1:-}" in
    --video) VIDEO=1 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 1 ;;
esac

if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
    echo "error: qemu-system-x86_64 not found on PATH" >&2
    exit 1
fi

if [[ ! -f "$DISK" ]]; then
    echo "error: $DISK not found - run ./mkdisk.sh then ./install.sh first" >&2
    exit 1
fi

ACCEL_ARGS=(-enable-kvm -cpu host)
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "warning: no KVM access (try: sudo gpasswd -a \$USER kvm, then re-login) - falling back to software emulation" >&2
    ACCEL_ARGS=(-accel tcg -cpu max)
fi

if [[ "$VIDEO" == "1" ]]; then
    # This image is BIOS-only, so the screen path is the plain VGA text
    # console (VGA_CONSOLE) continuing from GRUB's text mode - no
    # framebuffer driver involved.
    VIDEO_ARGS=(-vga std -display gtk,show-cursor=on)
else
    VIDEO_ARGS=(-vga none -nographic)
fi

qemu-system-x86_64 \
    -drive file="$DISK",format=raw,if=virtio \
    "${VIDEO_ARGS[@]}" \
    -serial mon:stdio \
    -m 1024 \
    "${ACCEL_ARGS[@]}"
