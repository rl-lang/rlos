#!/usr/bin/env bash
set -euo pipefall

SRC="init.c"
OUT="init"

if ! command -v gcc > /dev/null 2>&1; then
  echo "error: gcc not found on PATH" >&2
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "error: $SRC not found in current directory"
  exit 1
fi

echo "compiling $SRC..."
if ! gcc -static "$SRC" -o "$OUT"; then
  echo "error: compilation failed" >&2
  exit 1
fi

if [[ ! -x "$OUT" ]] then
  echo "error: build finished but $OUT is missing or not executable" >&2
  exit 1
fi

echo "done: $OUT"
