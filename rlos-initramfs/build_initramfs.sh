#!/usr/bin/env bash
# Build the initramfs RAM root: shared assembler -> cpio newc -> gzip.
# The kernel unpacks the resulting initramfs.gz as / and runs /init.
# Runs from rlos-initramfs/; shared inputs live one level up in rlos/.
#
# Usage:
#   ./build_initramfs.sh          text-only image (the default)
#   ./build_initramfs.sh -x       same, plus the X11 desktop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Always operate in this script's directory, wherever it is invoked from.
cd "$SCRIPT_DIR"
STAGE="initramfs"
OUT="initramfs.gz"

usage() {
    cat >&2 << EOF
usage: build_initramfs.sh [-x|--x11]

  -x, --x11   include the X11 desktop. Without it the initramfs is text-only,
              even when x11-dist/ exists. Requires build_x11.sh to have run.
EOF
}

WITH_X11=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -x|--x11) WITH_X11="-x"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

if ! command -v cpio > /dev/null 2>&1; then
    echo "error: required binary 'cpio' not found on PATH" >&2
    exit 1
fi
if ! command -v gzip > /dev/null 2>&1; then
    echo "error: required binary 'gzip' not found on PATH" >&2
    exit 1
fi

"$SCRIPT_DIR/../assemble-rootfs.sh" $WITH_X11 "$STAGE"

echo "packing $OUT (cpio newc + gzip -9)..."
( cd "$STAGE" && find . -mindepth 1 -print0 | LC_ALL=C sort -z | cpio -o -H newc --null 2> /dev/null | gzip -9 ) > "$OUT"

echo "done: $OUT ($(du -h "$OUT" | cut -f1))"
