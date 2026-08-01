#!/usr/bin/env bash
set -euo pipefail

ROOTFS="rootfs"
OUT="initramfs.img"

if [[ ! -d "$ROOTFS" ]]; then
    echo "error: $ROOTFS directory not found - run build_rootfs.sh first" >&2
    exit 1
fi

if [[ ! -e "$ROOTFS/init" ]]; then
    echo "error: $ROOTFS/init not found - rootfs looks incomplete" >&2
    exit 1
fi

for tool in cpio gzip; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

echo "packing $ROOTFS into $OUT..."
if ! (cd "$ROOTFS" && find . | cpio -o -H newc 2>/dev/null | gzip > "../$OUT"); then
    echo "error: packing failed" >&2
    exit 1
fi

if [[ ! -s "$OUT" ]]; then
    echo "error: $OUT was not created or is empty" >&2
    exit 1
fi

echo "done: $OUT ($(du -h "$OUT" | cut -f1))"

