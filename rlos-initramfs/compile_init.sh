#!/usr/bin/env bash
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

source "$HERE/../build-lib.sh"

SRC="init.c"
OUT="init"

if ! command -v gcc > /dev/null 2>&1; then
  fail "gcc not found on PATH"
fi

if [[ ! -f "$SRC" ]]; then
  fail "$SRC not found in current directory"
fi

# Clear any stale $OUT before compiling. gcc follows a symlink when opening its
# -o target, so if a previous run left ./init as a symlink pointing somewhere
# that no longer exists, gcc fails writing to the link target instead of
# replacing the link - which is how ./init ended up dangling at sbin/init and
# made assemble-rootfs.sh's "init not found" check fire on a source tree that
# was actually fine. rm -f covers both the symlink and a leftover directory.
rm -f "$OUT"

step "compiling $SRC..."
# -march/-mtune are pinned deliberately and MUST NOT be left to the host
# toolchain. Gentoo's gcc defaults to a recent -march, which emitted ~4300 AVX
# instructions into this binary. init is PID 1 and runs before anything else, so
# on any CPU without AVX it took SIGILL on the first vzeroupper and the kernel
# panicked with "Attempted to kill init! exitcode=0x00000004" - a blank screen
# with no console output at all, and no way to tell it apart from a bad build.
# x86-64 is the baseline every x86-64 CPU since 2004 satisfies. -ffunction-sections
# plus --gc-sections is a backstop: it lets the linker drop stdio entirely now
# that init.c no longer calls snprintf.
if ! gcc -static -march=x86-64 -mtune=generic -fno-pie -no-pie \
     -ffunction-sections -fdata-sections -Wl,--gc-sections \
     -Wall -Wextra -Wno-unused-parameter "$SRC" -o "$OUT"; then
  fail "compilation failed"
fi

# -march controls the code gcc emits for init.c only. It cannot reach the AVX
# already compiled into the host's libc.a (Gentoo builds that for x86-64-v3),
# so init still ends up with an AVX floor via glibc's stdio. Report it rather
# than pretend the flag alone fixed it - on a CPU without AVX, PID 1 takes
# SIGILL and the kernel panics with "Attempted to kill init! exitcode=0x4"
# before printing anything. Removing the floor for good needs a baseline libc
# (musl) or a freestanding init; see the note in init.c.
if objdump -d "$OUT" | grep -qE '\bv(zeroall|zeroupper|mov[a-z]*|pxor|broadcast[a-z]*)\b'; then
  echo "warning: $OUT still contains AVX instructions from the host libc.a;" >&2
  echo "warning: it will SIGILL on a CPU without AVX (e.g. QEMU -cpu qemu64)." >&2
  echo "warning: use -cpu host, or -cpu max under TCG, when running the ISO." >&2
fi

if [[ ! -x "$OUT" ]]; then
  fail "build finished but $OUT is missing or not executable"
fi

ok "$OUT"
