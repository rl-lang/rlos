#!/usr/bin/env bash
# Build the initramfs RAM root: shared assembler -> cpio newc -> gzip.
# The kernel unpacks the resulting initramfs.gz as / and runs /init.
# Runs from rlos-initramfs/; shared inputs live one level up in rlos/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Always operate in this script's directory, wherever it is invoked from.
cd "$SCRIPT_DIR"
STAGE="initramfs"
OUT="initramfs.gz"

if ! command -v cpio > /dev/null 2>&1; then
    echo "error: required binary 'cpio' not found on PATH" >&2
    exit 1
fi
if ! command -v gzip > /dev/null 2>&1; then
    echo "error: required binary 'gzip' not found on PATH" >&2
    exit 1
fi

"$SCRIPT_DIR/../assemble-rootfs.sh" "$STAGE"

echo "packing $OUT (cpio newc + gzip -9)..."
( cd "$STAGE" && find . -mindepth 1 -print0 | LC_ALL=C sort -z | cpio -o -H newc --null 2> /dev/null | gzip -9 ) > "$OUT"

echo "done: $OUT ($(du -h "$OUT" | cut -f1))"
