#!/usr/bin/env bash
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"

SRC="klogd.c"
OUT="klogd"

if ! command -v gcc > /dev/null 2>&1; then
  echo "error: gcc not found on PATH" >&2
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "error: $SRC not found in current directory" >&2
  exit 1
fi

echo "compiling $SRC..."
if ! gcc -static -O2 "$SRC" -o "$OUT"; then
  echo "error: compilation failed" >&2
  exit 1
fi

if [[ ! -x "$OUT" ]]; then
  echo "error: build finished but $OUT is missing or not executable" >&2
  exit 1
fi

echo "done: $OUT"
