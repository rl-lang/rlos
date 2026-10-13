#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$SCRIPT_DIR/linux"
KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
CONFIG_SRC="$SCRIPT_DIR/kernel.config"
OUT_BZIMAGE="$SCRIPT_DIR/kernel-images/rlos/bzImage"

source "$SCRIPT_DIR/build-lib.sh"

# Clean build by default.
# Set RLOS_NO_CLEAN=1 for an incremental build when iterating on C code with no
# config change.
header "Build mode"
if [[ "${RLOS_NO_CLEAN:-0}" == "1" ]]; then
    info "RLOS_NO_CLEAN=1: incremental build (only safe when kernel.config is unchanged)"
else
    info "forcing a clean build so a Kconfig change cannot be silently ignored..."
fi

header "Kernel source"
if [[ ! -f "$CONFIG_SRC" ]]; then
    fail "$CONFIG_SRC not found"
fi

if [[ -d "$KERNEL_DIR" ]]; then
    step "source already present at ./$KERNEL_DIR, skipping clone"
else
    step "cloning kernel source..."
    if ! git clone --depth 1 "$KERNEL_REPO" "$KERNEL_DIR"; then
        fail "kernel clone failed"
    fi
fi

cp "$CONFIG_SRC" "$KERNEL_DIR/.config"

pushd "$KERNEL_DIR" > /dev/null

# Must happen before olddefconfig, so the .config that is generated is the one
# the build actually uses.
if [[ "${RLOS_NO_CLEAN:-0}" != "1" ]]; then
    step "make clean..."
    make clean > /dev/null
fi

step "resolving config against current kernel version..."
if ! make olddefconfig; then
    fail "make olddefconfig failed"
fi

# olddefconfig drops any option whose dependencies it cannot satisfy and
# reports nothing. On this kernel the text console depends on a chain of
# symbols that get renamed over time (FB_CONSOLE -> FRAMEBUFFER_CONSOLE),
# and a stale name is dropped silently - which builds a kernel with no
# framebuffer console at all and a black screen on real hardware. So
# verify the chain actually resolved, and fail loudly if it did not.
REQUIRED_SYMS=(
    DRM
    DRM_EFIDRM
    DRM_FBDEV_EMULATION
    DRM_I915
    FB
    FB_CORE
    FRAMEBUFFER_CONSOLE
    FONT_8x16
    FONTS
    FONT_SUN12x22
    USB
    USB_XHCI_HCD
    USB_XHCI_PCI
    USB_EHCI_HCD
    USB_EHCI_PCI
    USB_OHCI_HCD
    USB_OHCI_HCD_PCI
    USB_UHCI_HCD
    USB_STORAGE
    USB_HID
    EFI_PARTITION
    SOUND
    SND
    SND_PCM
    SND_HDA
    SND_HDA_INTEL
    SND_HDA_CODEC_REALTEK
    SND_HDA_CODEC_HDMI
    USER_NS
    WLAN
    WLAN_VENDOR_ATH
    CFG80211
    MAC80211
    RFKILL
    ATH5K
    ATH5K_PCI
    ATH9K
    ATH9K_PCI
    ATH9K_HTC
    ATH6KL
    ATH10K
    ATH10K_PCI
    BT
    BT_RFCOMM
    BT_HCIBTUSB
    CRYPTO_USER_API
    CRYPTO_USER_API_HASH
    CRYPTO_USER_API_SKCIPHER
    CRYPTO_ECB
    CRYPTO_CBC
    CRYPTO_MD5
    CRYPTO_SHA1
    CRYPTO_SHA256
    CRYPTO_SHA512
    CRYPTO_AES
    CRYPTO_DES
    CRYPTO_CMAC
    CRYPTO_HMAC
    KEY_DH_OPERATIONS
)
MISSING=()
for sym in "${REQUIRED_SYMS[@]}"; do
    grep -qx "CONFIG_${sym}=y" .config || MISSING+=("$sym")
done
if [ ${#MISSING[@]} -ne 0 ]; then
    errmsg "these framebuffer/console/sound symbols did not survive olddefconfig:"
    for sym in "${MISSING[@]}"; do
        echo "  - $sym" >&2
    done
    echo "hint: a dependency is unsatisfiable, or the name is stale." >&2
    echo "      Check them in the source tree before assuming the name." >&2
    echo "      grep -rn 'config <SYMBOL>' --include=Kconfig .  (run from linux/)" >&2
    popd > /dev/null
    exit 1
fi
ok "framebuffer/console/sound config verified (${#REQUIRED_SYMS[@]} symbols)"

header "Building"
step "make -j$(nproc) (this can take a while)..."
if ! make -j"$(nproc)"; then
    fail "kernel build failed"
fi

popd > /dev/null

BUILT_IMAGE="$KERNEL_DIR/arch/x86/boot/bzImage"
if [[ ! -f "$BUILT_IMAGE" ]]; then
    fail "build finished but $BUILT_IMAGE not found"
fi

# Verify the LINKED kernel actually contains the driver.
if [[ ! -f "$KERNEL_DIR/vmlinux" ]]; then
    errmsg "$KERNEL_DIR/vmlinux not found after a successful build."
    echo "  Without it the USB drivers cannot be verified, and a kernel that" >&2
    echo "  silently lost them boots to a VFS panic on real hardware." >&2
    exit 1
fi
if ! command -v nm > /dev/null 2>&1; then
    errmsg "nm not found - cannot verify the built kernel contains the USB"
    echo "  PCI transport drivers. Install binutils, or the check is skipped and" >&2
    echo "  a broken kernel ships silently." >&2
    exit 1
fi

SYMS="$(nm "$KERNEL_DIR/vmlinux" 2>/dev/null || true)"
if [[ -z "$SYMS" ]]; then
    errmsg "nm produced no output for $KERNEL_DIR/vmlinux."
    echo "  The USB drivers cannot be verified, so refusing to ship the image." >&2
    exit 1
fi

missing_drivers=()
for drv in xhci_pci_driver ehci_pci_driver ohci_pci_driver; do
    grep -qE "[[:space:]]${drv}\$" <<< "$SYMS" || missing_drivers+=("$drv")
done
if [ ${#missing_drivers[@]} -ne 0 ]; then
    errmsg "built kernel is missing USB PCI transport drivers:"
    for drv in "${missing_drivers[@]}"; do
        echo "  - $drv" >&2
    done
    echo >&2
    echo "  .config asks for them, so this means the objects were not rebuilt." >&2
    echo "  This happens when make treats an already-built tree as current" >&2
    echo "  after a Kconfig-only change. compile_kernel.sh now runs make clean" >&2
    echo "  for exactly this reason; RLOS_NO_CLEAN=1 disables it." >&2
    echo >&2
    echo "  Symptom if shipped: the stick is invisible at boot and the kernel" >&2
    echo "  panics with 'VFS: unable to mount root fs on unknown-block(0,0)'." >&2
    exit 1
fi
ok "USB PCI transports verified in vmlinux (xhci/ehci/ohci)"

mkdir -p "$(dirname "$OUT_BZIMAGE")"
cp "$BUILT_IMAGE" "$OUT_BZIMAGE"
ok "done: $OUT_BZIMAGE"
