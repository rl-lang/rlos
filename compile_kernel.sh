#!/usr/bin/env bash
set -euo pipefail

# Absolute, resolved before any cd. The verification at the end reads vmlinux
# after this script has returned to the starting directory, and a relative
# KERNEL_DIR silently fails to resolve there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$SCRIPT_DIR/linux"
KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
CONFIG_SRC="$SCRIPT_DIR/kernel.config"
OUT_BZIMAGE="$SCRIPT_DIR/kernel-images/rlos/bzImage"

# Clean build by default. This is not a performance decision, it is a
# correctness one.
#
# make's dependency tracking does not reliably rebuild objects when only a
# Kconfig symbol changed. The symptom is nasty because every step reports
# success: `make` prints "bzImage is ready", bzImage gets a fresh timestamp,
# and the config still says =y - but the object files were compiled against the
# previous config and are simply relinked. That happened here with
# CONFIG_USB_XHCI_PCI: the build "succeeded", and the resulting kernel still
# could not see USB, panicking with "VFS: unable to mount root fs on
# unknown-block(0,0)". Every drivers/usb/host/*.o predated the config edit.
#
# A config check cannot catch that, because .config genuinely does contain the
# symbol. Only rebuilding from scratch, or inspecting the linked binary, can.
#
# Set RLOS_NO_CLEAN=1 for an incremental build when iterating on C code with no
# config change - that is the only case where incremental is actually correct.
if [[ "${RLOS_NO_CLEAN:-0}" == "1" ]]; then
    echo "RLOS_NO_CLEAN=1: incremental build (only safe when kernel.config is unchanged)"
else
    echo "forcing a clean build so a Kconfig change cannot be silently ignored..."
fi

if [[ ! -f "$CONFIG_SRC" ]]; then
    echo "error: $CONFIG_SRC not found" >&2
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

# Must happen before olddefconfig, so the .config that is generated is the one
# the build actually uses.
if [[ "${RLOS_NO_CLEAN:-0}" != "1" ]]; then
    echo "make clean..."
    make clean > /dev/null
fi

echo "resolving config against current kernel version..."
if ! make olddefconfig; then
    echo "error: make olddefconfig failed" >&2
    popd > /dev/null
    exit 1
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
    # i915 is verified here for the same reason as the framebuffer symbols
    # above: olddefconfig drops unsatisfiable options silently, and a kernel
    # built without i915 boots fine - it just falls back to the EFI
    # framebuffer, which is the unaccelerated path we added it to escape.
    DRM_I915
    FB
    FB_CORE
    FRAMEBUFFER_CONSOLE
    FONT_8x16
    FONTS
    FONT_SUN12x22
    # USB host controllers, and critically their PCI transports. An HCD without
    # its PCI glue compiles and links cleanly, then never binds to hardware - so
    # the stick is invisible and the kernel panics with "VFS: unable to mount
    # root fs on unknown-block(0,0)". This is checked here because the ISO
    # hides it (it has an initramfs) while an installed stick does not.
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
    # GPT, needed to resolve root=PARTUUID= on a partitioned target.
    EFI_PARTITION
    # Sound. rl-std/audio.rs reaches hardware through rodio -> cpal -> ALSA,
    # which needs /dev/snd/* from a bound driver. Checked for the same reason
    # as the symbols above: a silently dropped SND_HDA_INTEL still builds a
    # "working" kernel that has no sound at all.
    SOUND
    SND
    SND_PCM
    SND_HDA
    SND_HDA_INTEL
    # Codec umbrellas. With no codec bound the controller finds no analog pins
    # and every PCM open returns -112 "Host is down", which reads as "no sound
    # card" even though the card shows up in /proc/asound/cards.
    SND_HDA_CODEC_REALTEK
    SND_HDA_CODEC_HDMI
    # User namespaces. bubblewrap (rlos-atom) needs them for unprivileged
    # containers; without it bwrap only works as root skipping CLONE_NEWUSER,
    # so an escaped container is a root escape. Checked here so a silently
    # dropped USER_NS is a build failure rather than a runtime surprise.
    USER_NS
    # Wireless. Checked for the same reason as the symbols above, and it is the
    # one area where a silent drop is most likely. CFG80211 and MAC80211 live in
    # net/wireless/Kconfig and are reachable on their own, but every VENDOR menu -
    # WLAN_VENDOR_ATH and the ath drivers under it - sits behind `if WLAN` in
    # drivers/net/wireless/Kconfig. Enable cfg80211 without WLAN and the result is
    # a kernel with a full wireless stack that can never bind a single adapter:
    # wlan0 simply never appears, and no error is printed, because nothing
    # requested a driver that was never offered.
    WLAN
    WLAN_VENDOR_ATH
    CFG80211
    MAC80211
    RFKILL
    # ath9k is this machine's adapter (QCA6174). The rest cover the USB/SDIO
    # Atheros parts so the same ISO works on other machines.
    ATH5K
    ATH5K_PCI
    ATH9K
    ATH9K_PCI
    ATH9K_HTC
    ATH6KL
    # ath10k alongside ath9k: "QCA6174" is sold under one name across two
    # silicon families that need entirely different firmware. Verified here for
    # the same silent-drop reason - a kernel with ath9k but no ath10k binds
    # nothing on a 168c:0042 card and reports no error.
    ATH10K
    ATH10K_PCI
    # Bluetooth. BT alone compiles with no transport at all, which produces a
    # stack that enumerates nothing: bluetoothd starts, `bluetoothctl list` is
    # empty, and there is no controller to power on. BT_HCIBTUSB is the transport
    # that makes a USB dongle enumerate.
    BT
    BT_RFCOMM
    BT_HCIBTUSB
    # Crypto over AF_ALG, which iwd requires. Checked because iwd's failure here
    # is unusually well disguised: it exits 1 before touching any interface, so
    # the only symptom is "no wifi", which points at the wireless driver and not
    # at the crypto subsystem. Without these in REQUIRED_SYMS, dropping one is
    # silent - the kernel builds, the ISO builds, and wireless is simply absent.
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
    echo "error: these framebuffer/console/sound symbols did not survive olddefconfig:" >&2
    for sym in "${MISSING[@]}"; do
        echo "  - $sym" >&2
    done
    echo "hint: a dependency is unsatisfiable, or the name is stale." >&2
    echo "      Check them in the source tree before assuming the name." >&2
    echo "      grep -rn 'config <SYMBOL>' --include=Kconfig .  (run from linux/)" >&2
    popd > /dev/null
    exit 1
fi
echo "framebuffer/console/sound config verified (${#REQUIRED_SYMS[@]} symbols)"

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

# Verify the LINKED kernel actually contains the driver, not just that .config
# asks for it. This is not paranoia: make can decide nothing needs recompiling
# when only a Kconfig symbol changed, so `bzImage` gets re-linked from object
# files compiled against the old config and the symbol is present in .config but
# absent from the binary. That happened here - CONFIG_USB_XHCI_PCI=y was set,
# the build reported success, `bzImage` was freshly timestamped, and the kernel
# still could not see USB because every drivers/usb/host/*.o predated the change.
# A config check cannot catch this; only looking at the linked image can.
#
# vmlinux is the authoritative artifact: bzImage is a compressed copy of it.
# Mandatory, not conditional: a check that quietly skips itself is indistinguishable
# from one that passed, which is exactly the failure mode this whole section exists
# to catch.
if [[ ! -f "$KERNEL_DIR/vmlinux" ]]; then
    echo "error: $KERNEL_DIR/vmlinux not found after a successful build." >&2
    echo "  Without it the USB drivers cannot be verified, and a kernel that" >&2
    echo "  silently lost them boots to a VFS panic on real hardware." >&2
    exit 1
fi
if ! command -v nm > /dev/null 2>&1; then
    echo "error: nm not found - cannot verify the built kernel contains the USB" >&2
    echo "  PCI transport drivers. Install binutils, or the check is skipped and" >&2
    echo "  a broken kernel ships silently." >&2
    exit 1
fi

# One nm pass, captured into a variable, then matched against that.
#
# Do NOT write this as `nm ... | grep -q PATTERN`. nm emits tens of megabytes of
# symbols and grep -q exits at the FIRST match, which closes the pipe while nm is
# still writing. nm then dies of SIGPIPE, and because this script runs under
# `set -o pipefail`, the pipeline reports failure even though the pattern WAS
# found - so the check reports drivers missing while they are present in the
# binary. That is not hypothetical: it rejected a clean 10-minute build here,
# which is how it was found. Capturing first removes the early-exit pipe entirely,
# and also runs nm once instead of three times.
SYMS="$(nm "$KERNEL_DIR/vmlinux" 2>/dev/null || true)"
if [[ -z "$SYMS" ]]; then
    echo "error: nm produced no output for $KERNEL_DIR/vmlinux." >&2
    echo "  The USB drivers cannot be verified, so refusing to ship the image." >&2
    exit 1
fi

missing_drivers=()
for drv in xhci_pci_driver ehci_pci_driver ohci_pci_driver; do
    grep -qE "[[:space:]]${drv}\$" <<< "$SYMS" || missing_drivers+=("$drv")
done
if [ ${#missing_drivers[@]} -ne 0 ]; then
    echo "error: built kernel is missing USB PCI transport drivers:" >&2
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
echo "USB PCI transports verified in vmlinux (xhci/ehci/ohci)"

# The output directory is created here rather than assumed. A `cp` into a
# missing directory fails with a bare "No such file or directory" after a
# successful multi-minute build, which is the worst possible time to discover it.
mkdir -p "$(dirname "$OUT_BZIMAGE")"
cp "$BUILT_IMAGE" "$OUT_BZIMAGE"
echo "done: $OUT_BZIMAGE"
