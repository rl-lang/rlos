#!/usr/bin/env bash
set -euo pipefail

KERNEL="bzImage"
INITRD="initramfs.img"
DISK="disk.img"

if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
    echo "error: qemu-system-x86_64 not found on PATH" >&2
    exit 1
fi

if [[ ! -f "$KERNEL" ]]; then
    echo "error: $KERNEL not found - run compile_kernel.sh first" >&2
    exit 1
fi

if [[ ! -f "$INITRD" ]]; then
    echo "error: $INITRD not found - run compile_initramfs.sh first" >&2
    exit 1
fi

if [[ ! -f "$DISK" ]]; then
    echo "error: $DISK not found - run build_disk.sh first" >&2
    exit 1
fi

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -drive file="$DISK",format=raw,if=virtio \
    -append "root=/dev/vda1 rootfstype=ext4 console=ttyS0" \
    -nographic \
    -m 512
