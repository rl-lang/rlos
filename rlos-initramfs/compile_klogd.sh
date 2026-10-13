#!/usr/bin/env bash
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

source "$HERE/../build-lib.sh"

SRC="klogd.c"
OUT="klogd"

if ! command -v gcc > /dev/null 2>&1; then
  fail "gcc not found on PATH"
fi

if [[ ! -f "$SRC" ]]; then
  fail "$SRC not found in current directory"
fi

step "compiling $SRC..."
if ! gcc -static -O2 "$SRC" -o "$OUT"; then
  fail "compilation failed"
fi

if [[ ! -x "$OUT" ]]; then
  fail "build finished but $OUT is missing or not executable"
fi

ok "$OUT"
