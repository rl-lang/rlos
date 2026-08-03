#!/usr/bin/env bash
# rlos-atom/mkiso.sh - build rlos-atom.iso.
#
# The bootable form of atom. Atom also exists as a plain directory
# (atom-rootfs/) that a running rlOS mounts with bubblewrap, and this ISO is
# the same rootfs with a kernel and a bootloader around it so it can be dd'd to
# a stick and booted on its own.
#
# Two ways to use atom, one rootfs:
#
#   inside a running rlOS   bwrap + atom-rootfs.tar.gz   (see ATOM-BWRAP.md)
#   on its own              dd this ISO     (atom kernel + this rootfs)
#
# Usage:
#   ./mkiso.sh              build rlos-atom.iso
#   ./mkiso.sh --force      rebuild even if rlos-atom.iso looks current
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"

ROOTFS="$HERE/atom-rootfs"
KERNEL="$ROOT/kernel-images/rlos-atom/bzImage"
STAGE="isostage"
OUT="rlos-atom.iso"

info() { echo "  $*"; }
ok()   { echo "ok: $*"; }
warn() { echo "warn: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
header() {
  echo
  echo "== $* =="
}

FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "mkiso.sh: unknown option '$a'" >&2; exit 1 ;;
  esac
done

header "Checking"
[ -d "$ROOTFS" ] || fail "atom-rootfs/ missing - run build_atom_rootfs.sh first"
[ -f "$KERNEL" ] || fail "kernel-images/rlos-atom/bzImage missing - run compile_atom_kernel.sh first"
# Gentoo does not package xorriso, and grub-mkrescue shells out to it. The repo
# builds it from source into host-tools/ (see build_xorriso.sh) for exactly this
# reason, so use that copy rather than failing with grub-mkrescue's own opaque
# "xorriso not found".
if [[ -x "$ROOT/host-tools/bin/xorriso" && ":$PATH:" != *":$ROOT/host-tools/bin:"* ]]; then
    export PATH="$ROOT/host-tools/bin:$PATH"
    info "using host-tools/bin/xorriso"
fi
for tool in grub-mkrescue xorriso cpio gzip; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "$tool not found on PATH (host-tools/bin is added automatically if present)"
done

UNCOMPRESSED="$(du -sh "$ROOTFS" | cut -f1)"
info "rootfs:  $UNCOMPRESSED"
info "kernel:  $(du -h "$KERNEL" | cut -f1)"

# A stale atom kernel built from an older atom/kernel.config is a confusing
# failure: the rootfs is new and the kernel is not, and the mismatch only shows
# up as something not being found at boot.
if [ "$KERNEL" -ot "$HERE/kernel.config" ]; then
  warn "atom kernel image is older than rlos-atom/kernel.config - rebuild it"
fi
if [ -f "$OUT" ] && [ "$FORCE" = "0" ] && [ "$OUT" -nt "$ROOTFS/sbin/init" ]; then
  info "rlos-atom.iso is newer than the rootfs; --force to rebuild anyway"
fi

header "Packing the rootfs into an initramfs"
# The root goes into a gzipped cpio archive, root lives in RAM - exactly how
# rlos-iso/mkiso.sh does it, and the reason is size. Atom's rootfs is 95M
# uncompressed; putting it on the ISO raw produced a 134M image, which is
# absurd for a system whose entire purpose is to be small. Compressed it is
# 40M.
#
# The alternative - root=/atom reading the ISO directly - needs a real
# filesystem driver on the medium, and ISO9660 cannot host a writable root
# anyway, so atom would still be limited. An initramfs sidesteps both and keeps
# the standalone-boot path identical to the container path: same bytes either
# way.
rm -rf "$STAGE"
mkdir -p "$STAGE/boot/grub"

info "packing rootfs with cpio + gzip -9 ..."
# Braces OUTSIDE the quotes: inside quotes there is no brace expansion and the
# shell creates one directory literally named "{...}", which fails much later as
# a confusing "No such file or directory".
mkdir -p "$STAGE"/work/{bin,dev,proc,sys,tmp,run,root}
cp -a "$ROOTFS/." "$STAGE/work/"

# gzip -9 is worth the time here: this runs once per release, and the difference
# between -6 and -9 on a tree full of already-compressed ELF binaries is several
# megabytes.
( cd "$STAGE/work" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 ) \
    > "$STAGE/boot/initramfs.gz"
rm -rf "$STAGE/work"
ok "initramfs.gz ($(du -h "$STAGE/boot/initramfs.gz" | cut -f1))"

cp "$KERNEL" "$STAGE/boot/bzImage"
info "kernel staged ($(du -h "$KERNEL" | cut -f1))"

header "GRUB config"
# A smaller menu than the desktop's: atom has no display, so there is nothing to
# see, and the useful knobs (the bwrap invocation, --no-net) all live on the rlOS
  # side and are documented in /usr/share/doc/ATOM-BWRAP.md.
#
# console= appears twice on purpose, as in the desktop build: the kernel
# registers every console it is told about, so messages land on serial and screen
# alike, but /dev/console resolves to the LAST one - which is what the shell and
# klogd get.
cat > "$STAGE/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

# Root is the initramfs, which already contains the whole atom filesystem, so
# there is no root= and no initrd= line - rdinit defaults to /init, which is
# atom's own /sbin/init.
menuentry "rlos-atom" {
    linux /boot/bzImage console=ttyS0,115200 console=tty0 loglevel=4
}

menuentry "rlos-atom (serial, verbose)" {
    linux /boot/bzImage console=ttyS0,115200 loglevel=7
}
EOF
ok "grub.cfg"

header "Building the ISO"
grub-mkrescue -o "$OUT" "$STAGE" 2>&1 | grep -vE '^$' || true
[ -f "$OUT" ] || fail "grub-mkrescue produced nothing"

header "done"
ISO_SZ="$(du -h "$OUT" | cut -f1)"
ok "rlos-atom.iso: $ISO_SZ"
echo
echo "  rootfs uncompressed:  $UNCOMPRESSED"
echo "  iso (hybrid, gzip):  $ISO_SZ"
echo
echo "  write to USB with:"
echo "    sudo dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
echo "    (triple-check /dev/sdX - dd to the wrong device destroys data)"
echo
info "to run it inside a running rlOS instead, unpack atom-rootfs.tar.gz and bind it with bwrap"
  info "  (see /usr/share/doc/ATOM-BWRAP.md)"

# Leave the staging tree: it is 94M and rebuilding it is the slow part of a
# second iteration, so keeping it is the useful default.
info "staging tree kept at $STAGE (rm -rf to clean)"