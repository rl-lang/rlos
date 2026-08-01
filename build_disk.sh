#!/usr/bin/env bash
set -euo pipefail

ROOTFS="rootfs"
OUT="disk.img"
SIZE_MB=512

for tool in parted mkfs.ext4 losetup; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

if [[ ! -d "$ROOTFS" ]]; then
    echo "error: $ROOTFS directory not found - run build_rootfs.sh first" >&2
    exit 1
fi

echo "creating $SIZE_MB MB disk image..."
rm -f "$OUT"
truncate -s "${SIZE_MB}M" "$OUT"

echo "partitioning..."
parted -s "$OUT" mklabel gpt
parted -s "$OUT" mkpart primary ext4 1MiB 100%

LOOP="$(sudo losetup --show -fP "$OUT")"
trap 'sudo losetup -d "$LOOP"' EXIT

echo "formatting ${LOOP}p1..."
sudo mkfs.ext4 -q "${LOOP}p1"

MNT="$(mktemp -d)"
sudo mount "${LOOP}p1" "$MNT"
echo "copying rootfs into disk image..."
sudo cp -a "$ROOTFS"/. "$MNT"/
sudo umount "$MNT"
rmdir "$MNT"

echo "done: $OUT"
