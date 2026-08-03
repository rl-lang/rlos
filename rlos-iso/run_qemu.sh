#!/usr/bin/env bash
# Boot the live ISO from virtual CD-ROM (BIOS/SeaBIOS path).
# Runs from rlos-iso/.
set -euo pipefail

# Always operate in this script's directory, wherever it is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
    cat << 'USAGE'
Boot the live ISO under QEMU (BIOS/SeaBIOS).

  ./run_qemu.sh            headless: output on the terminal via serial
  ./run_qemu.sh --video    open a real display window, so the framebuffer
                           console path actually gets exercised
  ./run_qemu.sh --ssh      forward the guest's sshd to the host (see below)

Networking: the guest always gets a NIC (QEMU's implicit user-mode default),
so it always DHCPs and sshd always starts. Without --ssh that sshd is
unreachable, because user-mode networking has no inbound path from the host.

  ./run_qemu.sh --ssh              forward host :2222 -> guest :22
  RLOS_SSH_PORT=2300 ./run_qemu.sh --ssh    forward a different port

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

The default is headless, which is why a broken video path can go unnoticed
until the same ISO is booted on bare metal.
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

if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
    echo "error: qemu-system-x86_64 not found on PATH" >&2
    exit 1
fi

if [[ ! -f "$ISO" ]]; then
    echo "error: $ISO not found - run mkiso.sh first" >&2
    exit 1
fi

ACCEL_ARGS=(-enable-kvm -cpu host)
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "warning: no KVM access (try: sudo gpasswd -a \$USER kvm, then re-login) - falling back to software emulation" >&2
    ACCEL_ARGS=(-accel tcg -cpu max)
fi

# A real display device. The kernel needs something to claim a framebuffer
# from: DRM_EFIDRM on UEFI, VGA_CONSOLE on legacy BIOS. Note that a BIOS boot
# gives no EFI GOP framebuffer, so /dev/fb0 will not exist and the X session
# cannot start - use run_qemu_uefi.sh for anything graphical.
# shellcheck source=qemu_display.sh
. ./qemu_display.sh
rlos_pick_display "$([[ "$VIDEO" == "1" ]] && echo video || echo headless)"
VIDEO_ARGS=("${DISPLAY_ARGS[@]}")

# Guest networking.
#
# No -net flags at all means QEMU creates its implicit default: one e1000 on
# user-mode (slirp) networking, with slirp's built-in DHCP handing out 10.0.2.15
# and a default route via 10.0.2.2. That is enough for the guest to DHCP, start
# sshd, and reach the internet - and CONFIG_E1000=y is builtin, so it binds with
# no modules to load.
#
# What it cannot do is accept an inbound connection: slirp is one-way unless you
# forward a port. So --ssh adds the forward.
#
# Passing -netdev/-device explicitly SUPPRESSES QEMU's implicit default NIC
# rather than adding a second one, which is what we want - net_up() takes the
# first non-loopback interface, and two NICs would make that a race.
NET_ARGS=()
if [[ "$SSH" == "1" ]]; then
    SSH_PORT="${RLOS_SSH_PORT:-2222}"
    SSH_BIND="${RLOS_SSH_BIND:-}"
    # Empty bind means all interfaces. That is the documented default because
    # it is the useful one when testing from a second machine or a phone.
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
    -cdrom "$ISO" \
    -boot d \
    "${VIDEO_ARGS[@]}" \
    -serial mon:stdio \
    -m 2048 \
    "${NET_ARGS[@]}" \
    "${ACCEL_ARGS[@]}"
