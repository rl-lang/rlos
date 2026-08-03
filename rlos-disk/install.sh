#!/usr/bin/env bash
# install.sh - populate disk.img with the shared rootfs + kernel + GRUB
#
# The inner loop: assemble fresh rootfs -> loop-mount p2 -> copy tree in ->
# bzImage to /boot -> grub.cfg (root by LABEL) -> grub-install (BIOS) ->
# unmount. No repartitioning (see mkdisk.sh). Re-runnable anytime.
# Runs from rlos-disk/; shared inputs live one level up in rlos/.
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="disk.img"
KERNEL="../kernel-images/rlos/bzImage"
LABEL="rlos-root"
WORK="rootfs-staging"

for tool in losetup grub-install; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "error: required binary '$tool' not found on PATH" >&2
        exit 1
    fi
done

if [[ ! -f "$OUT" ]]; then
    echo "error: $OUT not found - run ./mkdisk.sh first" >&2
    exit 1
fi
if [[ ! -f "$KERNEL" ]]; then
    echo "error: $KERNEL not found - run ../compile_kernel.sh first" >&2
    exit 1
fi

echo "assembling fresh rootfs..."
"$SCRIPT_DIR/../assemble-rootfs.sh" "$WORK"

LOOP="$(sudo losetup --show -fP "$OUT")"
# shellcheck disable=SC2064
trap "sudo umount '$LOOP'p2 2>/dev/null || true; sudo losetup -d '$LOOP'" EXIT

MNT="$(mktemp -d)"
sudo mount "${LOOP}p2" "$MNT"
# shellcheck disable=SC2064
trap "sudo umount '$MNT' 2>/dev/null || true; sudo losetup -d '$LOOP'; rmdir '$MNT'" EXIT

echo "copying rootfs..."
sudo cp -a "$WORK"/. "$MNT"/

echo "installing kernel + grub config..."
sudo mkdir -p "$MNT/boot/grub"
sudo cp "$KERNEL" "$MNT/boot/bzImage"
# NOTE: root=LABEL= does NOT work here - label resolution needs userspace
# (blkid), which doesn't exist yet at this point. PARTUUID= is resolved by
# the kernel itself, so bake the partition's GPT UUID into grub.cfg.
PARTUUID="$(sudo blkid -s PARTUUID -o value "${LOOP}p2")"
if [[ -z "$PARTUUID" ]]; then
    echo "error: could not read PARTUUID of ${LOOP}p2" >&2
    exit 1
fi
echo "root partition PARTUUID: $PARTUUID"
sudo tee "$MNT/boot/grub/grub.cfg" > /dev/null << EOF
set timeout=5
serial --unit=0 --speed=115200
terminal_input serial console

# This disk image is BIOS-only (grub-install --target=i386-pc, bios_grub
# partition), so there is no EFI framebuffer to claim. Keep GRUB in the
# plain VGA text console - NOT gfxterm - and the kernel's VGA_CONSOLE
# continues from the same text buffer. gfxterm here would put GRUB into
# a VBE graphics mode that VGA_CONSOLE cannot write text into, leaving
# a blank screen after handover.
terminal_output serial console

# Two console= entries: the kernel registers both, so messages reach
# serial and screen, but /dev/console is the LAST one, so the shell and
# klogd land on tty0.
menuentry "rlOS" {
  linux /boot/bzImage root=PARTUUID=$PARTUUID rootfstype=ext4 rw console=ttyS0,115200 console=tty0 loglevel=3
}

# Headless: for the -nographic QEMU runs, where tty0 is not visible.
menuentry "rlOS (serial)" {
  linux /boot/bzImage root=PARTUUID=$PARTUUID rootfstype=ext4 rw console=ttyS0,115200 loglevel=3
}

menuentry "rlOS (debug)" {
  linux /boot/bzImage root=PARTUUID=$PARTUUID rootfstype=ext4 rw console=ttyS0,115200 console=tty0 loglevel=7 earlyprintk=serial,ttyS0,115200
}
EOF

echo "installing GRUB bootloader onto $LOOP..."
sudo grub-install --target=i386-pc --modules="part_gpt ext2" \
    --boot-directory="$MNT/boot" "$LOOP"

sudo umount "$MNT"
rmdir "$MNT"
sudo losetup -d "$LOOP"
trap - EXIT

echo "done: $OUT ready - boot with ./run_qemu.sh"
