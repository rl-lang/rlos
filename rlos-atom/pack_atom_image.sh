#!/usr/bin/env bash
# pack_atom_image.sh - pack the staged atom root filesystem into the single file
# that containers are started from.
#
# Why an archive, when bwrap bind-mounts directories?
#
# bwrap cannot consume an archive. There is no --squashfs, no --image, and no
# generic --mount type=, so nothing here can ever be what bwrap binds directly.
# What the archive buys is that the image is ONE file: copyable, shippable,
# versionable, scp-able. Unpack it once to a directory and that single directory
# then backs any number of concurrent containers, because bwrap --ro-bind
# shares the pages instead of copying them - the tenth container costs no extra
# memory.
#
# So: unpack once, bind many. This script builds the file; the unpacking and
# binding commands are written out in rlos-atom/ATOM-BWRAP.md.
#
# gzip, not zstd and not xz. The guest has tar, gunzip, xz and cpio but NOT
# zstd, so a .tar.zst would be a file that nothing on the system can read. And
# gzip decompresses roughly an order of magnitude faster than xz, which is what
# matters when the unpack target is RAM.
#
# Verification is the whole reason this script exists. An archive that unpacks
# to something subtly wrong is worse than no archive at all, because the damage
# shows up as a mystery inside a running service rather than here. So the
# archive is extracted to a scratch tree and compared against the original:
# every path, type, mode, symlink target, hardlink grouping, and byte. Any
# difference fails the build.
#
# Usage:
#   ./pack_atom_image.sh [ROOTFS_DIR] [OUTPUT]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="${1:-$ROOT/rlos-atom/atom-rootfs}"
OUT="${2:-$ROOT/rlos-atom/atom-rootfs.tar.gz}"

source "$ROOT/build-lib.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

header "Checking inputs"
[ -d "$SRC" ] || fail "$SRC missing - run rlos-atom/build_atom_rootfs.sh first"
[ -x "$SRC/bin/busybox" ] || fail "$SRC/bin/busybox missing - $SRC is not an atom rootfs"
info "source: $SRC ($(du -sh "$SRC" | cut -f1))"

header "Packing"
mkdir -p "$(dirname "$OUT")"
# Fixed order, ownership and timestamps, so an unchanged rootfs packs to a
# byte-identical archive and a changed archive always means a real change.
# --format=gnu is safe here because the longest path in the tree is 75
# characters, under gnu's 100-character name limit; it also avoids pax headers
# recording atime/ctime, which would defeat the reproducibility.
step "$(find "$SRC" -type f | wc -l) files -> $(du -sh "$SRC" | cut -f1) source"
substep "gzip -9n is the slow part and prints nothing until it finishes"
info "several minutes on a tree this size - this is not hung"
watch_growth "$OUT" "$(basename "$OUT")" & WATCH=$!
tar --format=gnu \
    --sort=name \
    --mtime='@0' \
    --owner=0 --group=0 --numeric-owner \
    -cf - -C "$SRC" . | gzip -9n > "$OUT"
kill "$WATCH" 2> /dev/null; wait "$WATCH" 2> /dev/null || true
ok "$(basename "$OUT"): $(du -h "$OUT" | cut -f1) (from $(du -sh "$SRC" | cut -f1))"

header "Extracting for verification"
mkdir -p "$SCRATCH/tree"
# -p is load-bearing, not decoration. Without it tar restores every directory as
# 755, which quietly turns atom-rootfs/tmp from 1777 into a directory no
# unprivileged process can write. That is the one directory in this tree with a
# non-default mode, and it happens to be the one that matters most. The guest
# command in ATOM-BWRAP.md uses -p for exactly this reason.
tar -xzpf "$OUT" -C "$SCRATCH/tree"
ok "extracted to scratch"

# One manifest per property, diffed between the original and the extracted copy.
# diff -r on its own is not enough: it dereferences symlinks, so a symlink
# repointed at different content sails through.
manifest_types() { find . -mindepth 1 -printf '%y %m %p\n'; }
manifest_links() { find . -type l -printf '%p -> %l\n'; }
manifest_hard()  { find . -type f -links +1 -printf '%n %p\n'; }
manifest_hash()  { find . -type f -printf '%p\0' | sort -z | xargs -0 -r sha256sum; }

compare() {
  local what="$1" fn="$2"
  ( cd "$SRC" && "$fn" ) | LC_ALL=C sort > "$SCRATCH/a"
  ( cd "$SCRATCH/tree" && "$fn" ) | LC_ALL=C sort > "$SCRATCH/b"
  if diff -u "$SCRATCH/a" "$SCRATCH/b" > "$SCRATCH/d"; then
    ok "$what"
  else
    echo "FAIL: $what differ between the tree and the archive" >&2
    head -20 "$SCRATCH/d" >&2
    return 1
  fi
}

header "Verifying the round trip"
compare "paths, types and modes"       manifest_types || fail "bad archive"
compare "symlink targets"             manifest_links || fail "bad archive"
compare "hardlink groupings"           manifest_hard  || fail "bad archive"
compare "content of every regular file" manifest_hash || fail "bad archive"

header "done"
ok "single-file atom image at $OUT"
info "next: assemble-rootfs.sh stages it into the desktop image."