#!/usr/bin/env bash
set -euo pipefail

KERNEL="bzImage"
INITRD="initramfs.img"
GRUB_CFG="grub.cfg"
ISO_DIR="iso"
OUT="rlos.iso"

if [[ ! -f "$KERNEL" ]]; then
    echo "error: $KERNEL not found - run compile_kernel.sh first" >&2
    exit 1
fi

if [[ ! -f "$INITRD" ]]; then
    echo "error: $INITRD not found - run compile_initramfs.sh first" >&2
    exit 1
fi

if [[ ! -f "$GRUB_CFG" ]]; then
    echo "error: $GRUB_CFG not found in current directory" >&2
    exit 1
fi

for tool in grub-mkrescue xorriso; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

echo "assembling iso tree..."
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/grub"
cp "$KERNEL" "$ISO_DIR/boot/"
cp "$INITRD" "$ISO_DIR/boot/"
cp "$GRUB_CFG" "$ISO_DIR/boot/grub/"

echo "building $OUT..."
if ! grub-mkrescue -o "$OUT" "$ISO_DIR"; then
    echo "error: grub-mkrescue failed" >&2
    exit 1
fi

if [[ ! -s "$OUT" ]]; then
    echo "error: $OUT was not created or is empty" >&2
    exit 1
fi

echo "done: $OUT ($(du -h "$OUT" | cut -f1))"
