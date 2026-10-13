#!/usr/bin/env bash
# Boot the initramfs sandbox: kernel + RAM root, serial console.
# Runs from rlos-initramfs/; the kernel lives one level up in rlos/.
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"


KERNEL="../kernel-images/rlos/bzImage"
INITRAMFS="initramfs.gz"

if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
    echo "error: qemu-system-x86_64 not found on PATH" >&2
    exit 1
fi

if [[ ! -f "$KERNEL" ]]; then
    echo "error: $KERNEL not found - run ../compile_kernel.sh first" >&2
    exit 1
fi

if [[ ! -f "$INITRAMFS" ]]; then
    echo "error: $INITRAMFS not found - run build_initramfs.sh first" >&2
    exit 1
fi

ACCEL_ARGS=(-enable-kvm -cpu host)
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "warning: no KVM access (try: sudo gpasswd -a \$USER kvm, then re-login) - falling back to software emulation" >&2
    ACCEL_ARGS=(-accel tcg -cpu max)
fi

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0,115200 loglevel=3" \
    -vga none \
    -nographic \
    -serial mon:stdio \
    -m 2048 \
    "${ACCEL_ARGS[@]}"
