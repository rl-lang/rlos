#!/usr/bin/env bash
# mkdisk.sh - create the empty rlos disk image (run once)
#
# Layout (GPT, 1GB):
#   p1  1MiB-2MiB   bios_grub  (GRUB core area, filled by install.sh)
#   p2  2MiB-100%   ext4 "rlos-root"
# install.sh fills p2 and installs GRUB later; re-running this ERASES the disk.
# Runs from rlos-disk/; the kernel lives one level up in rlos/.
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

source "$HERE/../build-lib.sh"

OUT="disk.img"
SIZE_MB=1024
LABEL="rlos-root"

for tool in sfdisk mkfs.ext4 losetup; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        fail "required binary '$tool' not found on PATH"
    fi
done

if [[ -f "$OUT" ]]; then
    warn "$OUT exists and will be ERASED."
    read -r -p "type 'yes' to continue: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        fail "aborted"
    fi
fi

header "Create"
step "creating $SIZE_MB MB disk image..."
rm -f "$OUT"
truncate -s "${SIZE_MB}M" "$OUT"

step "partitioning (GPT)..."
sfdisk "$OUT" > /dev/null << 'EOF'
label: gpt
start=1MiB, size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="bios_grub"
start=2MiB, type=linux, name="rlos-root"
EOF

LOOP="$(sudo losetup --show -fP "$OUT")"
trap 'sudo losetup -d "$LOOP"' EXIT

step "formatting ${LOOP}p2 as ext4 ($LABEL)..."
sudo mkfs.ext4 -q -L "$LABEL" "${LOOP}p2"

sudo losetup -d "$LOOP"
trap - EXIT

# If the whole script was run under sudo, hand the image back to the
# invoking user - otherwise qemu (running as you) can't open it later.
if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER" "$OUT"
fi

ok "done: $OUT (empty, labeled $LABEL - run ./install.sh next)"
