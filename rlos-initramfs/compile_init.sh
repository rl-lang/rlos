#!/usr/bin/env bash
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

source "$HERE/../build-lib.sh"

OUT="init"
# The crate lives outside the repository and is symlinked in as ./rlos-init.
# Keeping it outside keeps rustc's target/ directory out of the tree; the
# symlink makes the location stable regardless of where the checkout lives.
CRATE="$HERE/../rlos-init"
RUST_BIN="$CRATE/target/release/rlos-init"

# Clear any stale $OUT before building. A previous version of this script
# documented gcc following a dangling symlink at ./init; Rust's cp has the same
# hazard, so remove whatever is there first.
rm -f "$OUT"

if [[ -d "$CRATE" ]]; then
  # Rust path. init is PID 1 and runs before any libc exists, so this is a
  # freestanding no_std binary: rustix's linux_raw backend plus a handful of
  # raw syscalls, statically linked with -nostdlib. See the crate's build.rs
  # and .cargo/config.toml for the link contract.
  if ! command -v cargo > /dev/null 2>&1; then
    fail "cargo not found on PATH (needed to build rlos-init)"
  fi
  if [[ ! -f "$CRATE/Cargo.toml" ]]; then
    fail "$CRATE exists but has no Cargo.toml"
  fi

  step "building rlos-init (Rust, no_std)..."
  # cd into the crate: cargo discovers .cargo/config.toml relative to the
  # working directory, not to --manifest-path, and that config pins the
  # baseline CPU. CARGO_TARGET_DIR is explicit so $RUST_BIN above is always
  # the file cargo just produced.
  if ! ( cd "$CRATE" && CARGO_TARGET_DIR="$CRATE/target" \
           cargo build --release --offline ); then
    fail "cargo build failed"
  fi

  if [[ ! -f "$RUST_BIN" ]]; then
    fail "cargo succeeded but $RUST_BIN is missing"
  fi
  cp -f "$RUST_BIN" "$OUT"
  chmod 755 "$OUT"

  # The old C build inherited an AVX floor from the host's glibc.a. The Rust
  # binary must not: on a CPU without AVX it would take SIGILL on the first
  # vzeroupper, before printing anything, and the kernel would panic with
  # "Attempted to kill init!". x86-64 (baseline) is what the crate's
  # .cargo/config.toml pins. Unlike
  # the C fallback below, a match here is a hard failure - this build has no
  # libc to blame, so AVX means the flags regressed.
  if objdump -d "$OUT" \
       | grep -qE '\bv(zeroall|zeroupper|mov[a-z]*|pxor|broadcast[a-z]*)\b'; then
    fail "$OUT contains AVX instructions - PID 1 would SIGILL on a pre-AVX CPU.
       Check -C target-cpu=x86-64 in rlos-init/.cargo/config.toml and the
       link flags in rlos-init/build.rs."
  fi

  # PID 1 must not depend on a dynamic loader: execve of an ELF with
  # PT_INTERP has nothing to satisfy it this early. -no-pie is likewise
  # deliberate; a PIE would require ASLR relocations before _start runs.
  if ! readelf -h "$OUT" | grep -qE 'Type:[[:space:]]+EXEC'; then
    fail "$OUT is not a non-PIE executable"
  fi
  if readelf -d "$OUT" 2>/dev/null | grep -q NEEDED; then
    fail "$OUT has dynamic dependencies - init must be statically linked"
  fi

  ok "$OUT ($(du -h "$OUT" | cut -f1))"
else
  # C fallback. init.c is kept as the reference implementation and as a way to
  # bring up a tree where the external crate is not present (a fresh clone with
  # no symlink). If the crate is present but broken, fail above rather than
  # silently falling back: a broken Rust change must not ship an unnoticed C
  # binary.
  SRC="init.c"
  if ! command -v gcc > /dev/null 2>&1; then
    fail "gcc not found on PATH (and $CRATE is absent)"
  fi
  if [[ ! -f "$SRC" ]]; then
    fail "$SRC not found in current directory"
  fi

  step "rlos-init crate absent; compiling $SRC (C fallback)..."
  # -march/-mtune are pinned deliberately and MUST NOT be left to the host
  # toolchain. Gentoo's gcc defaults to a recent -march, which emitted ~4300
  # AVX instructions into this binary. init is PID 1 and runs before anything
  # else, so on any CPU without AVX it took SIGILL on the first vzeroupper and
  # the kernel panicked with "Attempted to kill init! exitcode=0x00000004".
  # x86-64 is the baseline every x86-64 CPU since 2004 satisfies.
  # -ffunction-sections plus --gc-sections is a backstop for stdio.
  if ! gcc -static -march=x86-64 -mtune=generic -fno-pie -no-pie \
       -ffunction-sections -fdata-sections -Wl,--gc-sections \
       -Wall -Wextra -Wno-unused-parameter "$SRC" -o "$OUT"; then
    fail "compilation failed"
  fi

  # -march controls the code gcc emits for init.c only. It cannot reach the AVX
  # already compiled into the host's libc.a (Gentoo builds that for x86-64-v3),
  # so the fallback still has an AVX floor via glibc's stdio. Report it rather
  # than pretend the flag alone fixed it - the Rust build above is the fix.
  if objdump -d "$OUT" | grep -qE '\bv(zeroall|zeroupper|mov[a-z]*|pxor|broadcast[a-z]*)\b'; then
    echo "warning: $OUT still contains AVX instructions from the host libc.a;" >&2
    echo "warning: it will SIGILL on a CPU without AVX (e.g. QEMU -cpu qemu64)." >&2
    echo "warning: build the rlos-init crate instead of using this fallback." >&2
  fi

  ok "$OUT (C fallback)"
fi

if [[ ! -x "$OUT" ]]; then
  fail "build finished but $OUT is missing or not executable"
fi
