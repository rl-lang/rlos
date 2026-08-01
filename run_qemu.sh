#!/usr/bin/env bash
set -euo pipefail

DISK="disk.img"

if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
    echo "error: qemu-system-x86_64 not found on PATH" >&2
    exit 1
fi

if [[ ! -f "$DISK" ]]; then
    echo "error: $DISK not found - run build_disk.sh first" >&2
    exit 1
fi

qemu-system-x86_64 \
    -drive file="$DISK",format=raw,if=virtio \
    -nographic \
    -m 512
