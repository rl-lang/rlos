#!/usr/bin/env bash
set -euo pipefail

ROOTFS="rootfs"
INIT_BIN="init"
PROGRAMS="rl_programs"

require_bin() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required binary '$1' not found on PATH" >&2
        exit 1
    fi
}

require_program_source() {
    if [[ ! -f "$PROGRAMS/$1.rl" ]]; then
        echo "error: required program source code '$1.rl' not found in '$PROGRAMS'" >&2
        exit 1
    fi
}

# require_bin busybox
require_bin rl
require_program_source rlsh
require_program_source hostname
require_program_source whoami
require_program_source ls

if [[ ! -f "$INIT_BIN" ]]; then
    echo "error: $INIT_BIN not found - run compile_init.sh first" >&2
    exit 1
fi

echo "creating rootfs directory tree..."
mkdir -p "$ROOTFS"/{bin,dev,proc,sys,lib64,usr/lib}

cp "$INIT_BIN" "$ROOTFS/init"

# echo "installing busybox shell..."
# cp "$(command -v busybox)" "$ROOTFS/bin/"
# ln -sf busybox "$ROOTFS/bin/sh"

echo "installing rl..."
RL_PATH="$(command -v rl)"
cp "$RL_PATH" "$ROOTFS/bin/"

echo "copying rl's runtime library dependencies..."
DEPS="$(ldd "$RL_PATH" | awk '{print $3}' | grep '^/' || true)"
if [[ -z "$DEPS" ]]; then
    echo "warning: no dynamic dependencies found for rl (statically linked?)"
else
    for lib in $DEPS; do
        if [[ -f "$lib" ]]; then
            cp -n "$lib" "$ROOTFS/usr/lib/"
        else
            echo "warning: dependency $lib listed by ldd but not found on disk" >&2
        fi
    done
fi

LD_LINUX="/lib64/ld-linux-x86-64.so.2"
if [[ -f "$LD_LINUX" ]]; then
    cp "$LD_LINUX" "$ROOTFS/lib64/"
else
    echo "error: dynamic linker $LD_LINUX not found" >&2
    exit 1
fi

echo "packaging rl-programs..."
echo "installing rlsh..."
"$ROOTFS/bin/rl" package "$PROGRAMS/rlsh.rl" -o "$ROOTFS/bin/rlsh"
echo "installing rl-whoami..."
"$ROOTFS/bin/rl" package "$PROGRAMS/whoami.rl" -o "$ROOTFS/bin/whoami"
echo "installing rl-hostname..."
"$ROOTFS/bin/rl" package "$PROGRAMS/hostname.rl" -o "$ROOTFS/bin/hostname"
echo "installing rl-ls..."
"$ROOTFS/bin/rl" package "$PROGRAMS/ls.rl" -o "$ROOTFS/bin/ls"

echo "done: $ROOTFS populated"
