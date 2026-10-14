#!/usr/bin/env bash
# Shared by run_qemu.sh and run_qemu_uefi.sh: work out how to show the guest's
# framebuffer on whatever QEMU build is actually installed.
#
# Why this exists: a GUI desktop test needs a real display device, and the flag
# that does that is not portable. QEMU's GUI backends are optional build-time
# dependencies, so a source build (Gentoo, for instance) can easily have none of
# them even though the version number is recent - version 10.2.3 here offers
# only "none", "curses" and "dbus". Hardcoding "-display gtk,show-cursor=on"
# makes such a build fail outright instead of degrading, which reads like the
# ISO is broken when it is not.
#
# The framebuffer itself is a separate concern and never changes: -vga std is
# what OVMF programs a GOP on, and the kernel claims that GOP via DRM_EFIDRM.
# Only the viewer is negotiated here.

# Prints the available -display backend names, one per line. The command
# substitution swallows the exit status for the same pipefail reason as below.
qemu_display_backends() {
    local help
    help="$(qemu-system-x86_64 -display help 2>&1 || true)"
    sed -n '/^Available display backend types:/,/^$/p' <<< "$help" | tail -n +2
}

# QEMU major.minor, e.g. "10.2". Used for the few options that arrived in a
# particular release rather than being available on all builds.
qemu_version() {
    local v
    v="$(qemu-system-x86_64 --version 2>&1 || true)"
    sed -n '1s/.*version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' <<< "$v"
}

# rlos_pick_gpu <video|headless>
#
# Sets the global array GPU_ARGS. Separate from the display choice because the
# two answer different questions. -vga std gives the guest an EFI GOP
# framebuffer, which the kernel claims through DRM_EFIDRM and which the text
# console draws on. That is NOT a modesetting DRM device, and for a Wayland
# compositor it is not enough:
#
#   wlroots' DRM backend enumerates connectors over KMS. EFI-GOP exposes no
#   connectors - no modes, no EDID, nothing to scan out. sway starts, finds zero
#   outputs, and exits with "No outputs detected". The X11 path never noticed,
#   because Xorg is perfectly content with a plain framebuffer.
#
# So the video path also gets a real modesetting device: virtio-gpu, which
# presents a KMS device with a connector and a mode list. It needs no host GPU
# and no host KMS driver, so it behaves identically under TCG and KVM.
#
# Headless gets nothing. -vga none already removes the framebuffer device, and
# adding a card nobody can look at would cost memory for no benefit - a text
# backend has no use for one.
rlos_pick_gpu() {
    local mode="$1"
    if [[ "$mode" != "video" ]]; then
        GPU_ARGS=()
        return 0
    fi
    # virtio-gpu-pci rather than the virtio-gpu alias: naming the transport
    # keeps the device on the PCI bus where the kernel's virtio-pci driver finds
    # it, instead of depending on virtio-mmio auto-detection.
    GPU_ARGS=(-device virtio-gpu-pci)
}

# rlos_pick_display <video|headless>
#
# Sets the global array DISPLAY_ARGS. In headless mode that is the plain serial
# console. In video mode it is a real display plus whatever viewer is needed.
rlos_pick_display() {
    local mode="$1"
    local backends version

    if [[ "$mode" != "video" ]]; then
        DISPLAY_ARGS=(-vga none -nographic)
        return 0
    fi

    backends="$(qemu_display_backends)"
    version="$(qemu_version)"

    if grep -qx 'gtk' <<< "$backends"; then
        # show-cursor arrived in 6.1; asking for it on anything older is a
        # hard startup failure, so gate it on the version. sort -V puts the
        # lower of the two first, so "6.1 comes first" means version >= 6.1.
        if [[ -n "$version" ]] &&
           [[ "$(printf '%s\n%s\n' "$version" 6.1 | sort -V | head -1)" == "6.1" ]]; then
            DISPLAY_ARGS=(-vga std -display gtk,show-cursor=on)
        else
            DISPLAY_ARGS=(-vga std -display gtk)
        fi
        return 0
    fi

    if grep -qx 'sdl' <<< "$backends"; then
        DISPLAY_ARGS=(-vga std -display sdl)
        return 0
    fi

    # No GUI backend, but -vnc is a separate option from -display and is
    # usually still compiled in. That still gives a real framebuffer, viewable
    # in any VNC client, which is what the test actually needs.
    # "qemu -vnc help" prints its option list and then exits 1. That matters
    # here: both launchers run under `set -o pipefail`, so testing it as
    # `qemu ... | grep -q` takes the pipeline status from qemu and always
    # reports "no VNC" even on a build that has it. Capture the output first
    # and match on that instead.
    local vnc_help
    vnc_help="$(qemu-system-x86_64 -vnc help 2>&1 || true)"
    if grep -q 'vnc options' <<< "$vnc_help"; then
        local port="${RLOS_VNC_PORT:-0}"
        DISPLAY_ARGS=(-vga std -display none -vnc "127.0.0.1:${port},share=ignore")
        cat >&2 <<EOF
note: this QEMU has no GUI display backend compiled in (only: $(tr '\n' ' ' <<< "$backends")).
note: exposing the framebuffer over VNC on 127.0.0.1:$((5900 + port)).
note: connect a VNC viewer to that port to see the desktop, e.g.
note:     virt-viewer vnc://127.0.0.1:$((5900 + port))
note: override with RLOS_VNC_PORT=<n>.
EOF
        return 0
    fi

    echo "error: this QEMU cannot show a graphical display (backends: $(tr '\n' ' ' <<< "$backends"))" >&2
    echo "hint: install a QEMU built with GTK or SDL, or use a VNC-capable build" >&2
    return 1
}
