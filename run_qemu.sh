#!/usr/bin/env bash
set -euo pipefail

KERNEL="bzImage"
INITRD="initramfs.img"

if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
  echo "errpr: qemu-system-x86_64 not found on PATH" >&2
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

qemu-system-x86_64 \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "console=ttyS0 earlyprintk=serial,ttyS0,115200" \
  -nographic \
  -m 512
