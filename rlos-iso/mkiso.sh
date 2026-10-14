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
usage: mkiso.sh [-x|--x11 | -w|--wayland] [-i|--installer] [--no-rebuild]

  -x, --x11       include the X11 desktop in the ISO. Without it the ISO is
                  text-only. Requires build_x11.sh to have been run.
  -i, --installer include the in-guest installer (rlos-install + sfdisk +
                  the filesystem tools and the GRUB boot artifacts).
  --no-rebuild    pack the existing rlos-initramfs/initramfs.gz as-is instead
                  of rebuilding it. For iterating on a hand-edited initramfs;
                  the ISO's contents are then whatever that file holds.
EOF
}

WITH_X11=0
WITH_WAYLAND=0
WITH_INSTALLER=0
REBUILD=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        -x|--x11) WITH_X11=1; shift ;;
        -w|--wayland) WITH_WAYLAND=1; shift ;;
        -i|--installer) WITH_INSTALLER=1; shift ;;
        --no-rebuild) REBUILD=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done
if [[ "$WITH_X11" == "1" && "$WITH_WAYLAND" == "1" ]]; then
    fail "-x and -w are mutually exclusive - pick one desktop"
    exit 1
fi
X11_FLAG=""
[[ "$WITH_X11" == "1" ]] && X11_FLAG="-x"
WAYLAND_FLAG=""
[[ "$WITH_WAYLAND" == "1" ]] && WAYLAND_FLAG="-w"
INSTALLER_FLAG=""
[[ "$WITH_INSTALLER" == "1" ]] && INSTALLER_FLAG="-i"

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

# The GRUB boot artifacts the in-guest installer needs, staged into grub-dist/
# BEFORE the initramfs is built, because that build is what copies them in.
#
# WHY THESE HAVE TO BE GENERATED RATHER THAN READ OFF THE ISO: grub-mkrescue
# does not leave boot.img, core.img or the EFI loader as files on the image it
# produces. It embeds them - the BIOS boot code in the System Area, the EFI
# image as an El Torito entry - so an installer running inside a guest booted
# from that ISO has nothing to copy. They are rebuilt here with the same
# grub-mkimage that grub-install uses under the hood, which also means the
# guest does not need grub-install itself (a much larger thing to ship).
#
# The module list is deliberately generous. A trimmed set builds a smaller
# core.img and grubx64.efi, but the failure mode of trimming one module too few
# is an image that installs cleanly and then boots to nothing, with nothing in
# the installer's output to say why. mkusb.sh's --modules="part_gpt ext2" is the
# floor that is known to work; this is that plus what the normal command and the
# FAT driver need to read the ESP.
gen_grub_artifacts() {
    local out="$1" mod
    for mod in grub-mkimage; do
        command -v "$mod" > /dev/null 2>&1 \
            || { fail "$mod not found - the installer needs it to stage a bootloader"; \
                 fail "on Gentoo: emerge sys-boot/grub"; exit 1; }
    done
    rm -rf "$out"
    mkdir -p "$out"

    step "grub: BIOS core image"
    # biosdisk is LOAD-BEARING and was missing here until a boot test caught it.
    # It is the INT 13h driver - the only thing in this list that can read a disk
    # at all. Without it the rest of the list is partition parsers, filesystems
    # and a menu for a disk it cannot see, and the symptom is a bare "GRUB" with
    # no menu: `set timeout=5` lives in grub.cfg, so a GRUB that cannot read the
    # disk never gets far enough to show the countdown. ahci/ata are margin for
    # disks that do not surface through plain INT 13h.
    #
    # Note there is no virtio module to add: GRUB's i386-pc build has no virtio
    # support at all, and UEFI firmware generally cannot read virtio-blk either.
    # That is why run_qemu.sh attaches the scratch disk as AHCI and not virtio.
    grub-mkimage -O i386-pc -p '(hd0,msdos1)/boot/grub' \
        -o "$out/core.img" biosdisk ahci ata part_gpt part_msdos ext2 fat normal linux \
        || { fail "grub-mkimage -O i386-pc failed"; exit 1; }

    step "grub: EFI loader (x86_64)"
    grub-mkimage -O x86_64-efi -p /boot/grub \
        -o "$out/grubx64.efi" part_gpt fat normal linux \
        || { fail "grub-mkimage -O x86_64-efi failed"; exit 1; }

    # boot.img is the 512-byte MBR stub that chains to core.img, and diskboot.img
    # is its block-device variant. Both come from the host's GRUB installation
    # rather than being generated: grub-mkimage does not produce them, they are
    # shipped as part of the i386-pc platform directory, and there is no
    # supported way to regenerate them.
    step "grub: MBR boot stubs"
    local src
    for src in boot.img diskboot.img; do
        local from
        from="$(find /usr/lib/grub/i386-pc -maxdepth 1 -name "$src" 2>/dev/null | head -1)"
        [[ -n "$from" ]] || { fail "$src not found under /usr/lib/grub/i386-pc"; \
                              fail "the installer would install an MBR with no boot code"; exit 1; }
        install -m 0644 "$from" "$out/$src"
    done

    # An EFI install also wants the 32-bit loader: some firmware only looks at
    # BOOTIA32.EFI. mkusb.sh treats that one as optional, so it is too - but if
    # the host has it, shipping it costs nothing and covers those machines.
    local ia32
    ia32="$(find /usr/lib/grub/i386-efi -maxdepth 2 -name 'grubia32.efi' 2>/dev/null | head -1 || true)"
    [[ -n "$ia32" ]] && install -m 0644 "$ia32" "$out/grubia32.efi" \
        && info "staged the 32-bit EFI loader too"

    for f in core.img grubx64.efi boot.img diskboot.img; do
        [[ -s "$out/$f" ]] || { fail "grub artifact $f is missing or empty"; exit 1; }
    done
    ok "grub-dist ready ($(du -sh "$out" | cut -f1))"
}

if [[ "$WITH_INSTALLER" == "1" ]]; then
    header "Installer"
    gen_grub_artifacts "../grub-dist"
fi

# The initramfs is the whole system: the rootfs lives inside it, so X11 has to
# be decided here or not at all. Rebuild it rather than trusting whatever the
# last run left behind, otherwise "no -x" would silently inherit a desktop.
if [[ "$REBUILD" == "1" ]]; then
    step "building initramfs (${X11_FLAG:-text-only}${INSTALLER_FLAG:+, }${INSTALLER_FLAG:-})..."
    "$BUILD_INITRAMFS" $X11_FLAG $WAYLAND_FLAG $INSTALLER_FLAG
elif [[ ! -f "$INITRAMFS" ]]; then
    fail "$INITRAMFS not found and --no-rebuild was given"
    info  "hint: drop --no-rebuild, or run ../rlos-initramfs/build_initramfs.sh"
else
    warn "--no-rebuild: packing $INITRAMFS as-is, contents unverified"
    [[ "$WITH_INSTALLER" == "1" ]] && warn "--no-rebuild also skips regenerating grub-dist"
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

# The backend and installer lines describe what THIS invocation requested. With
# --no-rebuild that is not what the image contains, because the flags only reach
# the initramfs when it is rebuilt - so they are not printed as fact. Saying
# "backend: Wayland desktop" over an ISO whose initramfs was built for text is
# worse than saying nothing: it is the one line a person would act on.
if [[ "$REBUILD" == "0" && ( "$WITH_X11" == "1" || "$WITH_WAYLAND" == "1" || "$WITH_INSTALLER" == "1" ) ]]; then
    warn  "--no-rebuild: -x/-w/-i were not applied - the initramfs was NOT rebuilt."
    warn  "  Rebuild without --no-rebuild, or the ISO will not match these flags."
else
    if [[ "$WITH_X11" == "1" ]]; then
        info  "backend: X11 desktop (built with -x)"
    elif [[ "$WITH_WAYLAND" == "1" ]]; then
        info  "backend: Wayland desktop (built with -w)"
    else
        info  "backend: text-only (no -x, no -w)"
    fi
    if [[ "$WITH_INSTALLER" == "1" ]]; then
        info  "installer: yes - run ~/scripts/rlos-install.sh from the live session"
    else
        info  "installer: no (rebuild with -i to install from the running system)"
    fi
fi
# Only when no backend flag was given: otherwise the warning above has already
# said this, more specifically, and repeating it is noise.
if [[ "$REBUILD" == "0" && "$WITH_X11" != "1" && "$WITH_WAYLAND" != "1" && "$WITH_INSTALLER" != "1" ]]; then
    warn  "--no-rebuild, so this reflects initramfs.gz's previous contents"
fi
info "write to USB with: sudo dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
warn "triple-check /dev/sdX first - dd to the wrong device destroys data"
