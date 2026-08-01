#!/usr/bin/env bash
set -euo pipefail

KERNEL_DIR="linux"
KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
CONFIG_SRC="kernel.config"
OUT_BZIMAGE="bzImage"

if [[ ! -f "$CONFIG_SRC" ]]; then
    echo "error: $CONFIG_SRC not found in current directory" >&2
    exit 1
fi

if [[ -d "$KERNEL_DIR" ]]; then
    echo "kernel source already present at ./$KERNEL_DIR, skipping clone"
else
    echo "cloning kernel source..."
    if ! git clone --depth 1 "$KERNEL_REPO" "$KERNEL_DIR"; then
        echo "error: kernel clone failed" >&2
        exit 1
    fi
fi

cp "$CONFIG_SRC" "$KERNEL_DIR/.config"

pushd "$KERNEL_DIR" > /dev/null

echo "resolving config against current kernel version..."
if ! make olddefconfig; then
    echo "error: make olddefconfig failed" >&2
    popd > /dev/null
    exit 1
fi

echo "building kernel (this can take a while)..."
if ! make -j"$(nproc)"; then
    echo "error: kernel build failed" >&2
    popd > /dev/null
    exit 1
fi

popd > /dev/null

BUILT_IMAGE="$KERNEL_DIR/arch/x86/boot/bzImage"
if [[ ! -f "$BUILT_IMAGE" ]]; then
    echo "error: build finished but $BUILT_IMAGE not found" >&2
    exit 1
fi

cp "$BUILT_IMAGE" "$OUT_BZIMAGE"
echo "done: $OUT_BZIMAGE"
