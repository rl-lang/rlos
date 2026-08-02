#!/usr/bin/env bash
set -euo pipefail

ROOTFS="rootfs"
KERNEL="bzImage"
OUT="disk.img"
SIZE_MB=1024

for tool in parted mkfs.ext4 losetup grub-install; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

if [[ ! -d "$ROOTFS" ]]; then
    echo "error: $ROOTFS not found - run build_rootfs.sh first" >&2
    exit 1
fi

if [[ ! -f "$KERNEL" ]]; then
    echo "error: $KERNEL not found - run compile_kernel.sh first" >&2
    exit 1
fi

echo "creating $SIZE_MB MB disk image..."
rm -f "$OUT"
truncate -s "${SIZE_MB}M" "$OUT"

echo "partitioning..."
parted -s "$OUT" mklabel gpt
parted -s "$OUT" mkpart bios_grub 1MiB 2MiB
parted -s "$OUT" set 1 bios_grub on
parted -s "$OUT" mkpart primary ext4 2MiB 100%
parted -s "$OUT" set 2 boot on

LOOP="$(sudo losetup --show -fP "$OUT")"
trap 'sudo losetup -d "$LOOP"' EXIT

echo "formatting ${LOOP}p2..."
sudo mkfs.ext4 -q "${LOOP}p2"

MNT="$(mktemp -d)"
sudo mount "${LOOP}p2" "$MNT"

echo "copying rootfs..."
sudo cp -a "$ROOTFS"/. "$MNT"/

echo "installing kernel + grub config..."
sudo mkdir -p "$MNT/boot/grub"
sudo cp "$KERNEL" "$MNT/boot/bzImage"
sudo tee "$MNT/boot/grub/grub.cfg" > /dev/null << 'EOF'
set timeout=5
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial

menuentry "rlOS" {
  linux /boot/bzImage root=/dev/vda2 rootfstype=ext4 rw console=ttyS0 earlyprintk=serial,ttyS0,115200
}
EOF

echo "installing grub bootloader onto $LOOP..."
sudo grub-install --target=i386-pc --boot-directory="$MNT/boot" "$LOOP"

sudo umount "$MNT"
rmdir "$MNT"

echo "done: $OUT"
