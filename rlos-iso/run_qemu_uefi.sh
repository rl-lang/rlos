#!/usr/bin/env bash
# Boot the live ISO via UEFI (OVMF) instead of BIOS.
# Runs from rlos-iso/; keeps a local writable VARS copy next to the script.
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
    cat << 'USAGE'
Boot the live ISO under QEMU using OVMF (UEFI).

  ./run_qemu_uefi.sh            headless: output on the terminal via serial
  ./run_qemu_uefi.sh --video    open a real display window
  ./run_qemu_uefi.sh --ssh      forward the guest's sshd to the host

Networking: the guest always gets a NIC (QEMU's implicit user-mode default),
so it always DHCPs and sshd always starts. Without --ssh that sshd is
unreachable, because user-mode networking has no inbound path from the host.

  ./run_qemu_uefi.sh --ssh              forward host :2222 -> guest :22
  RLOS_SSH_PORT=2300 ./run_qemu_uefi.sh --ssh    forward a different port

Then, from the host:

  ssh -p 2222 -o UserKnownHostsFile=/dev/null user@127.0.0.1

  password: root

  UserKnownHostsFile=/dev/null is not paranoia. The guest's host keys are
  generated into the initramfs at boot and discarded, so EVERY run presents a
  different key. Without this you get "REMOTE HOST IDENTIFICATION HAS CHANGED"
  on the second run, which reads exactly like a man-in-the-middle and is not one.

  The forward binds ALL host interfaces, so the guest's sshd is reachable from
  your whole LAN for as long as QEMU runs. Given the account password is "root",
  that is worth knowing. Narrow it with RLOS_SSH_BIND=127.0.0.1.

--video is the closest local approximation of booting the dd'd USB stick on
real UEFI hardware: OVMF sets up a GOP framebuffer, and the kernel takes it
over via DRM_EFIDRM exactly as it does on metal. It is also the ONLY path that
gets a framebuffer at all: a BIOS boot provides no EFI GOP framebuffer, so
/dev/fb0 never appears and the X session cannot start.
USAGE
}

VIDEO=0
SSH=0
case "${1:-}" in
    --video) VIDEO=1 ;;
    --ssh) SSH=1 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 1 ;;
esac

ISO="rlos.iso"
OVMF_DIR="/usr/share/edk2-ovmf"
CODE="$OVMF_DIR/OVMF_CODE.fd"
VARS_SRC="$OVMF_DIR/OVMF_VARS.fd"
VARS="ovmf_vars.fd"

if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
    echo "error: qemu-system-x86_64 not found on PATH" >&2
    exit 1
fi

if [[ ! -f "$ISO" ]]; then
    echo "error: $ISO not found - run mkiso.sh first" >&2
    exit 1
fi

if [[ ! -f "$CODE" || ! -f "$VARS_SRC" ]]; then
    echo "error: OVMF firmware not found under $OVMF_DIR" >&2
    echo "hint: emerge sys-firmware/edk2-ovmf, then retry" >&2
    exit 1
fi

if [[ ! -f "$VARS" ]]; then
    echo "creating local UEFI vars copy..."
    cp "$VARS_SRC" "$VARS"
fi

ACCEL_ARGS=(-enable-kvm -cpu host)
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "warning: no KVM access (try: sudo gpasswd -a \$USER kvm, then re-login) - falling back to software emulation" >&2
    ACCEL_ARGS=(-accel tcg -cpu max)
fi

# OVMF programs GOP on -vga std and hands the framebuffer to the kernel through
# the EFI GOP protocol, which is what DRM_EFIDRM binds to. How that framebuffer
# reaches you is negotiated, because QEMU's GUI backends are optional and a
# build without them cannot show a window at all.
# shellcheck source=qemu_display.sh
. ./qemu_display.sh
rlos_pick_display "$([[ "$VIDEO" == "1" ]] && echo video || echo headless)"
VIDEO_ARGS=("${DISPLAY_ARGS[@]}")
# A KMS device for the Wayland backend, on top of whatever framebuffer
# rlos_pick_display chose. See rlos_pick_gpu for why -vga std alone
# is not enough for a compositor to scan out to.
rlos_pick_gpu "$([[ "$VIDEO" == "1" ]] && echo video || echo headless)"
GPU_ARGS=("${GPU_ARGS[@]}")

# A QMP socket is always offered so the guest framebuffer can be captured
# without a VNC or GTK client, which matters because QEMU's GUI backends are
# optional and this build has none. ./shot.sh <out.png> uses it.
QMP_SOCK="${RLOS_QMP_SOCK:-$PWD/qmp.sock}"
rm -f "$QMP_SOCK"

# Guest networking. Identical rationale to run_qemu.sh - see the comments there.
# No -net flags means QEMU's implicit default: one e1000 on user-mode (slirp),
# which DHCPs (10.0.2.15) and routes via 10.0.2.2, but accepts no inbound
# connection. --ssh adds the only thing slirp needs for that, a forward.
#
# Explicit -netdev/-device suppresses the implicit default NIC rather than
# adding a second one, so the guest gets exactly one interface for net_up().
NET_ARGS=()
if [[ "$SSH" == "1" ]]; then
    SSH_PORT="${RLOS_SSH_PORT:-2222}"
    SSH_BIND="${RLOS_SSH_BIND:-}"
    if [[ -n "$SSH_BIND" ]]; then
        HOSTFWD="tcp:$SSH_BIND:$SSH_PORT-:22"
        BIND_DESC="$SSH_BIND"
    else
        HOSTFWD="tcp::$SSH_PORT-:22"
        BIND_DESC="all interfaces (0.0.0.0)"
    fi
    NET_ARGS=(-netdev "user,id=net0,hostfwd=$HOSTFWD" -device e1000,netdev=net0)

    cat >&2 << EOF
--ssh: host $BIND_DESC :$SSH_PORT  ->  guest :22
       ssh -p $SSH_PORT -o UserKnownHostsFile=/dev/null user@127.0.0.1
       (password: root; host key changes every boot - see --help)
EOF
    if [[ -z "$SSH_BIND" ]]; then
        cat >&2 << 'EOF'
warning: the ssh forward is exposed on every host interface, and the guest's
         account password is "root". Anything on your LAN can try it. Narrow it
         with RLOS_SSH_BIND=127.0.0.1 if that matters.
EOF
    fi
fi

qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -cdrom "$ISO" \
    -boot d \
    "${VIDEO_ARGS[@]}" \
    "${GPU_ARGS[@]}" \
    -qmp "unix:$QMP_SOCK,server=on,wait=off" \
    -serial mon:stdio \
    -m 2048 \
    "${NET_ARGS[@]}" \
    "${ACCEL_ARGS[@]}"
