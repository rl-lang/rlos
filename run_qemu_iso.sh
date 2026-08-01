#!/usr/bin/env bash
set -euo pipefail

ISO="rlos.iso"


if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
  echo "error: qemu-system-x86_64 not found on PATH" >&2
  exit 1
fi

if [[ ! -f "$ISO" ]]; then
  echo "error: $ISO not found - run build_iso.sh first" >&2
  exit 1
fi

qemu-system-x86_64 \
  -cdrom "$ISO" \
  -nographic \
  -m 512
