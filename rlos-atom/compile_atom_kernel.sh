#!/usr/bin/env bash
# compile_atom_kernel.sh - build the rlos-atom kernel.
#
# Atom is a stripped service container: no display, no sound. Its kernel is
# derived from rlos/kernel.config rather than being a second hand-maintained
# file, because two full .config files drift apart silently and the failure mode
# is a kernel missing something that only breaks on someone else's hardware.
#
# What changes relative to rlos/kernel.config:
#
#   DROPPED  the graphics stack (DRM, FB, fonts) - there is no X and no console
#            worth looking at; atom is reached over ssh or as a bwrap container
#   DROPPED  sound (SOUND, SND, HDA + codecs) - atom's rl binaries are built
#            no-media, so std-audio is not even linked and nothing needs /dev/snd
#   KEPT     USB storage + xHCI/EHCI/OHCI - mkiso.sh dd's the atom ISO to a
#            stick, so atom must be able to boot from one
#   KEPT     ISO9660 - the live ISO is read from it
#   KEPT     ext4 - the persistent USB install target
#   ADDED    USER_NS - already in rlos/kernel.config; asserted here because bwrap
#            is the entire point of atom and it cannot work without it
#
# Output:
#
#   kernel-images/rlos-atom/bzImage
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The SAME tree rlos uses. One clone, one kernel version, two configs.
#
# The separate-tree idea was a mistake. It was introduced to stop two builds
# racing - but the race was never caused by sharing the tree, it was caused by
# running the two builds CONCURRENTLY. Builds here are sequential by design
# (atom first, then rlos), so a shared tree is safe, and it is better:
#
#   - no second 3GB clone, and no network at all
#   - atom and rlos provably the same kernel version. A separate clone fetched
#     a different upstream commit, which would have meant the container runs on
#     a subtly different kernel from its host.
#   - one place to patch
#
# What actually protects the tree is the build lock in clean_kernel.sh and
# build_kernel.sh: `make clean` in a tree that is being compiled in is how you get
# a half-built kernel that still reports success.
#
# The OUTPUT is what is kept separate - kernel-images/rlos/bzImage and
# kernel-images/rlos-atom/bzImage - because that is what the two images consume,
# and because the atom image must be buildable without disturbing a good rlos one.
KERNEL_DIR="${ATOM_KERNEL_DIR:-$ROOT/linux}"
KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
CONFIG_SRC="$ROOT/kernel.config"
GENERATED="$ROOT/rlos-atom/kernel.config"
OUT="$ROOT/kernel-images/rlos-atom/bzImage"

info() { echo "  $*"; }
ok()   { echo "ok: $*"; }
warn() { echo "warn: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
header() {
  echo
  echo "== $* =="
}

# Symbols to remove. Each is a top-level "menu" symbol plus the drivers that
# only exist to serve it.
#
# DRM_EFIDRM is included because it is how the UEFI path gets a framebuffer; with
# no framebuffer there is nothing for it to do, and it is a large driver.
DROP_SYMS=(
  # graphics / display
  DRM DRM_I915 DRM_FBDEV_EMULATION FB FB_CORE FRAMEBUFFER_CONSOLE FONTS
  # sound
  SOUND SND SND_PCM SND_HDA SND_HDA_INTEL
  SND_HDA_CODEC_REALTEK SND_HDA_CODEC_HDMI SND_HDA_CODEC_CIRRUS
)

header "Generating atom config from rlos/kernel.config"
[ -f "$CONFIG_SRC" ] || fail "rlos/kernel.config not found"
info "source: kernel.config ($(wc -l < "$CONFIG_SRC") lines)"

python3 - "$CONFIG_SRC" "$GENERATED" "${DROP_SYMS[@]}" << 'PYEOF'
import sys

src, dst = sys.argv[1], sys.argv[2]
drop = set(sys.argv[3:])

kept, removed, disabled = [], [], 0

with open(src) as fh:
    for line in fh:
        line = line.rstrip('\n')
        sym = None
        if line.startswith('CONFIG_') and '=' in line:
            sym = line.split('=', 1)[0][len('CONFIG_'):]
        elif line.startswith('# CONFIG_') and 'is not set' in line:
            sym = line.split()[2][len('CONFIG_'):]

        if sym in drop:
            # "# CONFIG_X is not set" -> keep as an explicit negative so the
            # intent survives; "CONFIG_X=y" -> drop the line entirely.
            if line.startswith('# CONFIG_'):
                kept.append(line)
            else:
                disabled += 1
            removed.append(sym)
            continue
        kept.append(line)

with open(dst, 'w') as fh:
    fh.write('\n'.join(kept) + '\n')

print(f"  dropped {disabled} CONFIG_*=y lines for {len(set(removed))} symbols")
print(f"  kept explicit negatives for: {', '.join(sorted(set(x for x in removed if x)))}")
PYEOF

[ -f "$GENERATED" ] || fail "config generation produced nothing"
ok "generated rlos-atom/kernel.config"

header "Preparing the tree"
if [[ ! -d "$KERNEL_DIR" ]]; then
    info "cloning kernel source (shallow)..."
    git clone --depth 1 "$KERNEL_REPO" "$KERNEL_DIR" || fail "kernel clone failed"
else
    info "reusing $KERNEL_DIR"
fi

cp "$GENERATED" "$KERNEL_DIR/.config"

pushd "$KERNEL_DIR" > /dev/null

if [[ "${ATOM_NO_CLEAN:-0}" != "1" ]]; then
    info "make clean..."
    make clean > /dev/null
fi

info "resolving config against current kernel version..."
make olddefconfig > /dev/null || { fail "olddefconfig failed"; popd > /dev/null; exit 1; }

# Verify what atom actually needs. A silently dropped symbol produces a kernel
# that builds fine and fails on someone else's machine, so each of these is a
# hard error.
#
# USER_NS is the one that matters most: bubblewrap cannot create a sandbox
# without it, and bwrap is the reason atom exists.
REQUIRED_SYMS=(
  # Container substrate
  USER_NS
  NAMESPACES UTS_NS IPC_NS PID_NS NET_NS
  SECCOMP SECCOMP_FILTER
  CGROUPS
  # rootfs + storage, so it can boot from the ISO and from a USB stick
  EXT4_FS ISO9660_FS VFAT_FS BLK_DEV_LOOP
  USB USB_XHCI_HCD USB_XHCI_PCI USB_EHCI_HCD USB_EHCI_PCI
  USB_OHCI_HCD USB_OHCI_HCD_PCI USB_UHCI_HCD
  USB_STORAGE
  # EFI_PARTITION resolves root=PARTUUID= on a partitioned USB install
  EFI_PARTITION
  # serial console, which is how a headless atom is actually driven
  TTY SERIAL_8250 SERIAL_8250_CONSOLE
)

# A plain string rather than an array. Under `set -u`, expanding an EMPTY array
# ("${arr[@]}") is an unbound-variable error in older bash, so the reporting loop
# below died before printing which symbols were missing - producing exactly the
# useless error this check exists to avoid.
MISSING=""
for sym in "${REQUIRED_SYMS[@]}"; do
    grep -qx "CONFIG_${sym}=y" .config || MISSING="$MISSING $sym"
done
if [ -n "$MISSING" ]; then
    fail "these atom symbols did not survive olddefconfig:"
    for sym in $MISSING; do echo "  - $sym" >&2; done
    echo "hint: check the symbol name in the source tree before assuming it is" >&2
    echo "      stale.  grep -rn 'config <SYMBOL>' --include=Kconfig .  (from linux/)" >&2
    popd > /dev/null
    exit 1
fi
ok "atom config verified (${#REQUIRED_SYMS[@]} symbols)"

# The dropped symbols must actually be gone, or the "smaller kernel" claim is
# untrue. Verified rather than assumed.
STILL_ON=""
for sym in "${DROP_SYMS[@]}"; do
    grep -qx "CONFIG_${sym}=y" .config && STILL_ON="$STILL_ON $sym"
done
if [ -n "$STILL_ON" ]; then
    warn "these were meant to be dropped but olddefconfig kept them:$STILL_ON"
    warn "  atom's kernel will be larger than intended (not fatal)"
fi

header "Building"
info "this can take a while..."
make -j"$(nproc 2>/dev/null || echo 4)" bzImage || { fail "kernel build failed"; popd > /dev/null; exit 1; }

popd > /dev/null

[ -f "$KERNEL_DIR/arch/x86/boot/bzImage" ] || fail "bzImage not produced"
mkdir -p "$(dirname "$OUT")"
cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$OUT"

header "done"
ok "atom kernel: $(du -h "$OUT" | cut -f1) -> kernel-images/rlos-atom/bzImage"
if [ -f "$ROOT/bzImage" ]; then
  info "for comparison, the rlos kernel is $(du -h "$ROOT/bzImage" | cut -f1)"
fi
info "next: rlos-atom/mkiso.sh builds rlos-atom.iso from this."