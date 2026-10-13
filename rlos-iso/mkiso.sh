#!/usr/bin/env bash
# Build a hybrid live ISO (BIOS + UEFI, dd-able to a USB stick):
# GRUB vehicle carrying bzImage + initramfs.gz, root stays in RAM.
#
# Usage:
#   ./mkiso.sh              text-only image (the default)
#   ./mkiso.sh -x           same, plus the X11 desktop
#   ./mkiso.sh --no-rebuild pack the existing initramfs.gz untouched
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

source "$HERE/../build-lib.sh"

usage() {
    cat >&2 << EOF
usage: mkiso.sh [-x|--x11] [--no-rebuild]

  -x, --x11       include the X11 desktop in the ISO. Without it the ISO is
                  text-only. Requires build_x11.sh to have been run.
  --no-rebuild    pack the existing rlos-initramfs/initramfs.gz as-is instead
                  of rebuilding it. For iterating on a hand-edited initramfs;
                  the ISO's contents are then whatever that file holds.
EOF
}

WITH_X11=0
REBUILD=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        -x|--x11) WITH_X11=1; shift ;;
        --no-rebuild) REBUILD=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done
X11_FLAG=""
[[ "$WITH_X11" == "1" ]] && X11_FLAG="-x"

# Prefer the vendored xorriso (built by ../build_xorriso.sh) when present -
# Gentoo ships no xorriso ebuild, so the host one usually does not exist.
if [[ -x "../host-tools/bin/xorriso" && ":$PATH:" != *":$(cd ../host-tools/bin && pwd):"* ]]; then
    export PATH="$(cd ../host-tools/bin && pwd):$PATH"
fi

KERNEL="../kernel-images/rlos/bzImage"
INITRAMFS="../rlos-initramfs/initramfs.gz"
BUILD_INITRAMFS="../rlos-initramfs/build_initramfs.sh"
STAGE="isostage"
OUT="rlos.iso"

for tool in grub-mkrescue xorriso mcopy; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        fail "required tool '$tool' not found on PATH"
        info  "hint: emerge app-cdr/xorriso sys-fs/mtools, then retry"
    fi
done

if [[ ! -f "$KERNEL" ]]; then
    fail "$KERNEL not found - run ../compile_kernel.sh first"
fi

# The initramfs is the whole system: the rootfs lives inside it, so X11 has to
# be decided here or not at all. Rebuild it rather than trusting whatever the
# last run left behind, otherwise "no -x" would silently inherit a desktop.
if [[ "$REBUILD" == "1" ]]; then
    step "building initramfs (${X11_FLAG:-text-only})..."
    "$BUILD_INITRAMFS" $X11_FLAG
elif [[ ! -f "$INITRAMFS" ]]; then
    fail "$INITRAMFS not found and --no-rebuild was given"
    info  "hint: drop --no-rebuild, or run ../rlos-initramfs/build_initramfs.sh"
else
    warn "--no-rebuild: packing $INITRAMFS as-is, contents unverified"
fi

if [[ ! -f "$INITRAMFS" ]]; then
    fail "$INITRAMFS not found - run ../rlos-initramfs/build_initramfs.sh first"
fi

step "staging boot files..."
rm -rf "$STAGE"
mkdir -p "$STAGE/boot/grub"
cp "$KERNEL" "$STAGE/boot/bzImage"
cp "$INITRAMFS" "$STAGE/boot/initramfs.gz"
cat > "$STAGE/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial gfxterm

# Solid background, matching the desktop the menu boots into. GRUB cannot do a
# solid fill without the gfxmenu background module and a theme, which is a lot
# of machinery for a boot menu that is on screen for five seconds; the default
# grey is fine and the desktop behind it is set by /usr/bin/setrootbg.

# Under UEFI the kernel takes over the framebuffer the firmware already
# set up (DRM_EFIDRM), so gfxterm is the right output here. Do NOT add
# nomodeset: the fbcon text console needs that framebuffer to exist.
#
# fbcon=font: takes the name from struct font_desc, matched case-sensitively
# by find_font(). A typo is NOT reported - it falls back to VGA8x16 (8x16 and
# 12x22 both score pref=0 on x86, and VGA8x16 comes first in the table). So
# check the console size to confirm it applied: 12x22 gives 160x49 at
# 1920x1080, whereas the 8x16 fallback gives 240x67.

# console= is listed twice on purpose: the kernel registers every console
# it is given, so messages land on serial and screen alike, but /dev/console
# resolves to the LAST one - so tty0 is what the shell and klogd get.
menuentry "rlOS (live)" {
  linux /boot/bzImage rootwait console=ttyS0,115200 console=tty0 loglevel=3 fbcon=font:SUN12x22
  initrd /boot/initramfs.gz
}

# Headless: for the -nographic QEMU runs, where tty0 is not visible.
menuentry "rlOS (live, serial)" {
  linux /boot/bzImage rootwait console=ttyS0,115200 loglevel=3
  initrd /boot/initramfs.gz
}

# Verbose, for diagnosing a hang on bare metal. earlyprintk catches the
# window before the framebuffer console is registered, but only if a
# serial cable is actually attached.
menuentry "rlOS (live, debug)" {
  linux /boot/bzImage rootwait console=ttyS0,115200 console=tty0 loglevel=7 earlyprintk=serial,ttyS0,115200 fbcon=font:SUN12x22
  initrd /boot/initramfs.gz
}
EOF

# Only emitted for -x. The entry runs rlin, which is staged by
# build_base_tools.sh into base-dist/ and so is present in both backends, but
# it is a diagnostic for the X input driver: without X starting there is no
# driver to diagnose, and init's rlos.diag path would report on an input stack
# nothing is going to consume.
if [[ "$WITH_X11" == "1" ]]; then
cat >> "$STAGE/boot/grub/grub.cfg" << 'EOF'

# Input diagnostics, for when the desktop comes up but nothing responds to the
# keyboard or touchpad. rlos.diag makes init report what the input layer
# exposes and then deliberately NOT start X.
#
# The reason for a separate entry rather than always logging: the report that
# explains a dead keyboard is written while X is starting, and X covers the
# text console with a desktop that cannot be typed into. The user is then asked
# for a log they have no way to read, where the only way to see it is the
# keyboard that is broken. With no X, the report stays on the framebuffer and
# can simply be photographed. console=tty0 first so it goes to the screen.
menuentry "rlOS (live, diagnose input)" {
  linux /boot/bzImage rootwait console=tty0 console=ttyS0,115200 loglevel=3 fbcon=font:SUN12x22 rlos.diag
  initrd /boot/initramfs.gz
}
EOF
fi

cat >> "$STAGE/boot/grub/grub.cfg" << 'EOF'

# One-shot diagnostics: run /bin/fbtest as PID 1 instead of the real init, so
# the framebuffer probe reports and the machine stops. Needs a display device
# (run_qemu_uefi.sh --video, or real hardware) because /dev/fb0 only exists
# when the firmware handed us a framebuffer.
#
# rdinit= and not init=: the kernel tries the ramdisk's /init first
# (init/main.c:1590) and only falls back to init= (:1604), so init= cannot
# override an initramfs that has its own /init. rdinit= sets that first path
# directly.
#
# ttyS0 goes LAST here on purpose: /dev/console resolves to the final
# console= argument, so this makes fbtest's stdout the serial port and the
# report is readable without a screen. The normal entries want the opposite
# order. There is no init supervising anything here, and the kernel panics
# once fbtest exits - that is expected.
menuentry "rlOS (fbtest)" {
  linux /boot/bzImage rootwait console=tty0 console=ttyS0,115200 loglevel=7 rdinit=/bin/fbtest
  initrd /boot/initramfs.gz
}
EOF

step "creating $OUT (BIOS + UEFI hybrid)..."
# run_quiet, not a bare pipe: xorriso prints a dozen lines of drive/media/UPDATE
# progress for an operation that either worked or did not. If it fails, run_quiet
# shows the tail, which is where xorriso's actual diagnostic is.
run_quiet grub-mkrescue -o "$OUT" "$STAGE"

if [[ ! -f "$OUT" ]]; then
    fail "build finished but $OUT is missing"
fi

ok "$OUT ($(du -h "$OUT" | cut -f1))"
if [[ "$WITH_X11" == "1" ]]; then
    info  "backend: X11 desktop (built with -x)"
else
    info  "backend: text-only (no -x)"
fi
if [[ "$REBUILD" == "0" ]]; then
    warn  "--no-rebuild, so this reflects initramfs.gz's previous contents"
fi
info "write to USB with: sudo dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
warn "triple-check /dev/sdX first - dd to the wrong device destroys data"
