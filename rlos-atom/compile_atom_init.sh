#!/usr/bin/env bash
# compile_atom_init.sh - build the rlos-atom init.
#
# Atom and the desktop now share one Rust implementation: the rlos-init crate
# at the repo root (symlink; the source lives outside the tree). The differences
# are compile-time features, not a second source file:
#
#   desktop: cargo build --release
#   atom:    cargo build --release --features atom
#
# What --features atom changes is deliberately tiny. The desktop is already
# capability-gated at runtime on /bin/Xorg existing, and atom ships no Xorg, so
# the whole X path is skipped without a feature. The one guard that exists is
# for the fontconfig cache: atom has no fonts and no fontconfig, so it must not
# create or chown /tmp/fccache. Doing it as a cfg rather than a runtime test
# means the atom binary physically cannot acquire that path.
#
# init.c remains in rlos-initramfs as the reference implementation and as the
# desktop script's fallback when the crate is absent. It is not built here.
#
# Output:
#
#   rlos-atom/atom-init
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CRATE="$ROOT/rlos-init"
BIN="$CRATE/target/release/rlos-init"
OUT="$ROOT/rlos-atom/atom-init"

source "$ROOT/build-lib.sh"

[ -d "$CRATE" ] || fail "rlos-init crate not found at $CRATE - add the repo-root symlink"
[ -f "$CRATE/Cargo.toml" ] || fail "$CRATE has no Cargo.toml"
command -v cargo > /dev/null 2>&1 || fail "cargo not found on PATH"
command -v objdump > /dev/null 2>&1 || fail "objdump not found on PATH"

rm -f "$OUT"

header "Building"
info "cargo build --release --features atom"
# cd into the crate so cargo reads its .cargo/config.toml (baseline CPU,
# offline). CARGO_TARGET_DIR is explicit so $BIN is always the artifact just
# produced, even if the caller exported a shared target directory.
if ! ( cd "$CRATE" && CARGO_TARGET_DIR="$CRATE/target" \
         cargo build --release --offline --features atom ); then
  fail "atom init build failed"
fi

[ -f "$BIN" ] || fail "cargo succeeded but $BIN is missing"
cp -f "$BIN" "$OUT"
chmod 755 "$OUT"

header "Verifying the feature actually bit"
# The desktop-only /tmp/fccache string must be absent. grep -a reads the ELF as
# text; no pipe means no SIGPIPE-under-pipefail trap (the old C script had to
# use a temp file for exactly that reason).
if grep -aq '/tmp/fccache' "$OUT"; then
  fail "atom feature did not bite: /tmp/fccache is still present in $OUT"
fi
ok "atom build has no /tmp/fccache path (desktop-only code compiled out)"

# PID 1 must be static: there is no dynamic loader this early. And it must not
# be PIE: -no-pie is what lets _start run before any relocation processing.
if ! readelf -h "$OUT" | grep -qE 'Type:[[:space:]]+EXEC'; then
  fail "$OUT is not a non-PIE executable"
fi
if readelf -d "$OUT" 2>/dev/null | grep -q NEEDED; then
  fail "$OUT has dynamic dependencies - atom-init must be statically linked"
fi
ok "static, non-PIE"

# Same no-AVX contract as the desktop init: this binary is PID 1 on arbitrary
# x86-64 CPUs, including QEMU's qemu64 model. A match is a hard failure, not a
# warning - there is no libc here to blame.
if objdump -d "$OUT" \
     | grep -qE '\bv(zeroall|zeroupper|mov[a-z]*|pxor|broadcast[a-z]*)\b'; then
  fail "$OUT contains AVX instructions - PID 1 would SIGILL on a pre-AVX CPU"
fi
ok "no AVX instructions"

header "done"
ok "atom-init ($(du -h "$OUT" | cut -f1))"
info "next: build_atom_rootfs.sh installs it as /sbin/init."
