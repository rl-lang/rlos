#!/usr/bin/env bash
# mkusb.sh - install rlOS to a real USB stick, persistent, bootable BIOS + UEFI.
#
# Unlike install.sh, which fills a disk.img file for the QEMU runs, this targets
# an actual block device and erases it. Everything after the partitioning step is
# the same idea: assemble the shared rootfs, put it on an ext4 partition, put the
# kernel and a GRUB config where the bootloader that runs will find them.
#
# Layout (GPT):
#   p1  bios_grub  1MiB    GRUB core.img. No filesystem - this is only ever
#                          read by legacy BIOS, which cannot read GPT and so
#                          needs somewhere to keep the core image.
#   p2  EFI        512MiB  FAT32. The ONLY partition UEFI firmware is permitted
#                          to read, so it has to be here. Holds the EFI
#                          binaries plus its own copy of the kernel and config.
#   p3  rlos-root  rest     ext4. The system itself.
#
# WHY THE BOOT FILES ARE DUPLICATED
# ---------------------------------
# bzImage and grub.cfg exist on both p2 and p3 - once for the UEFI path, once for
# the BIOS path. Each bootloader reads the copy sitting on the partition it
# booted from, so neither has to go looking for the other filesystem.
#
# The alternative is to keep them only on the FAT ESP and teach the BIOS
# core.img to search for it, which is the conventional layout (/boot IS the ESP)
# and does mean one copy. It was not chosen because it would mean rewriting the
# BIOS boot chain that install.sh already proves works in QEMU, in order to save
# 14 MiB on a stick with tens of gigabytes free.
#
# Note the two grub.cfg files are NOT the same file, deliberately. They differ in
# terminal_output, and getting that wrong is what leaves a blank screen after
# handover:
#
#   BIOS  terminal_output serial console   - GRUB is in the VGA text buffer.
#   UEFI  terminal_output serial gfxterm   - the firmware left a framebuffer
#                                            (DRM_EFIDRM) for the kernel, so
#                                            gfxterm is correct here.
#
# GRUB --removable writes EFI/BOOT/BOOTX64.EFI where firmware looks by default,
# with no NVRAM entry. That means the stick boots on the first try on machines
# that have never had efibootmgr run against them.

set -euo pipefail

# SCRIPT_DIR has to be made absolute before the cd below, otherwise
# dirname of a relative $0 stops resolving once we have moved.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../build-lib.sh"
cd "$SCRIPT_DIR"

DEVICE=""
# Root partition size. Default is 16G rather than "fill the stick": most rlOS
# installs (a 144MB rootfs) fit easily, and a smaller p3 means mkfs and the
# rootfs copy touch far less flash - which matters on the cheap sticks that
# overstate their capacity and die partway through a large write. Override with
# --size 8G / 32G / max.
SIZE="16G"

usage() {
    cat >&2 << EOF
usage: sudo $0 /dev/sdX [--size SIZE] [-x|--x11 | -w|--wayland]

Installs rlOS to a whole block device. THE DEVICE IS ERASED.

  /dev/sdX      the USB stick, e.g. /dev/sda or /dev/sdb
  --size SIZE   root partition size (default: 16G). Accepts 8G, 32G, 512M,
                or 'max' to use the rest of the stick.
  -x, --x11     install the X11 desktop. Without it the stick boots to the
                text console, even when x11-dist/ exists. Requires
                build_x11.sh to have been run.
  -w, --wayland install the Wayland desktop (sway). Without it the stick boots
                to the text console, even when wayland-dist/ exists. Requires
                build_wl.sh to have been run. Mutually exclusive with -x.

Find it with 'lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS'. The one with TRAN=usb
and nothing mounted is usually the stick.
EOF
}

WITH_X11=""
WITH_WAYLAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)
            [[ $# -ge 2 ]] || { echo "error: --size needs a value" >&2; exit 1; }
            SIZE="$2"; shift 2 ;;
        --size=*) SIZE="${1#*=}"; shift ;;
        -x|--x11) WITH_X11="-x"; shift ;;
        -w|--wayland) WITH_WAYLAND="-w"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "error: unknown option '$1'" >&2; usage; exit 1 ;;
        *)
            [[ -z "$DEVICE" ]] || { echo "error: too many arguments" >&2; usage; exit 1; }
            DEVICE="$1"; shift ;;
    esac
done

# Reject -x -w here, before anything destructive happens. assemble-rootfs.sh
# refuses the combination too, but by then the stick has already been
# partitioned and written to - and "the script would have caught it" is not a
# good reason to have wiped a device.
if [[ -n "$WITH_X11" && -n "$WITH_WAYLAND" ]]; then
    echo "error: -x and -w are mutually exclusive; pick one desktop" >&2
    usage
    exit 1
fi

# Say so early and specifically when the desktop was asked for but not built.
# Without this, a missing wayland-dist/ surfaces much later as a generic
# assemble-rootfs.sh failure, after the partitions exist.
if [[ -n "$WITH_WAYLAND" && ! -d "$SCRIPT_DIR/../wayland-dist/bin" ]]; then
    echo "error: -w given but wayland-dist/ has no bin/ - run ./build_wl.sh first" >&2
    exit 1
fi
if [[ -n "$WITH_X11" && ! -d "$SCRIPT_DIR/../x11-dist" ]]; then
    echo "error: -x given but x11-dist/ is missing - run ./build_x11.sh first" >&2
    exit 1
fi

ESP_SIZE=512M

# Never written to, even when nothing is mounted, so a spare disk that happens
# to carry one of these names is still protected. Extend this on a new host.
REFUSE_DISKS=(/dev/sda)


if [[ $EUID -ne 0 ]]; then
    echo "usage: sudo $0 /dev/sdX [--size SIZE] [-x|--x11 | -w|--wayland]" >&2
    die "must run as root (mkfs and mount need it)"
fi

if [[ -z "$DEVICE" ]]; then
    usage
    exit 1
fi

# Normalise and sanity check SIZE. sfdisk accepts K/M/G/T suffixes; 'max' is
# turned into an empty size field, which sfdisk reads as "to the end of the
# device".
case "$SIZE" in
    max|MAX|Max) SIZE="" ;;
    *[0-9]*) ;;
    *) die "--size '$SIZE' is not a size (try 8G, 16G, 32G, or max)" ;;
esac

# Required. lsblk and blkid are not obvious here but are load-bearing: the
# mounted-filesystem guard, the REFUSE_DISKS check and the running-root check all
# shell out to lsblk, and every one of those calls sends stderr to /dev/null and
# fails open on a missing binary. Requiring lsblk is what stops those guards from
# silently becoming no-ops on a host without util-linux.
missing=()
for tool in sfdisk mkfs.vfat mkfs.ext4 mount umount grub-install wipefs lsblk blkid mountpoint; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
    echo "error: missing required binaries: ${missing[*]}" >&2
    echo "  Gentoo: emerge sys-apps/util-linux sys-apps/e2fsprogs sys-apps/dosfstools sys-boot/grub" >&2
    exit 1
fi

# Not required. These only ask the kernel to re-read a partition table that
# sfdisk has just written, and they are tried in order and all optional - the
# poll for /dev/disk/by-partlabel below is the actual guarantee that the new
# nodes exist. Gentoo hosts without partprobe still have partx and blockdev.
[[ -f "$SCRIPT_DIR/../kernel-images/rlos/bzImage" ]] || die "kernel-images/rlos/bzImage not found - run ../compile_kernel.sh first"

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
# Each of these is a way of destroying a disk, so they are checked before
# anything is written and in the order that gives the best message first.

[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"

# Sanity: if someone accidentally wrote to /dev/sdX (creating a regular file),
# -b will be true only for the kernel-created block node. But a regular file
# shadowing it would be gone if we rm'd it; also check it's not a regular file
# in a way that could be ambiguous. More directly: block devices in /dev are
# character/block special - confirm it's a block special.
if [[ ! -b "$DEVICE" ]]; then
    : # already failed
fi
# Extra guard: ensure it's not a regular file masquerading (we just saw this).
if [[ -f "$DEVICE" ]]; then
    die "$DEVICE is a regular file, not a block device. If this is the stray
      node you just created, remove it: sudo rm -f $DEVICE"
fi

# A mounted filesystem underneath means either another process is using the
# stick or it is someone's data disk. Either way, not ours to erase.
#
# lsblk rather than grepping /proc/mounts, because lsblk reports the MOUNTPOINT
# of everything stacked on the device - including a LUKS or LVM volume sitting
# on one of its partitions, which /proc/mounts lists as /dev/mapper/... and a
# path grep would sail straight past.
MOUNTED=$(lsblk -nrpo NAME,MOUNTPOINT "$DEVICE" 2>/dev/null | awk '$2 != "" {print "      " $1 "  ->  " $2}')
if [[ -n "$MOUNTED" ]]; then
    die "$DEVICE has mounted filesystems - unmount them first:
$MOUNTED"
fi

# Hard refusal list. Checked against the disk that physically owns $DEVICE, so
# passing a partition of a refused disk, or a /dev/disk/by-id/... symlink
# pointing at it, is refused too.
#
# CAVEAT: /dev names are assigned per machine and can change across reboots or
# firmware updates. Treat this as a floor, not a ceiling - it is a specific
# machine's belt-and-braces on top of the mounted-filesystem check above, and
# needs re-checking if this script moves to another host.
resolve_disk() {
    local node parent
    node="$(readlink -f "$1" 2>/dev/null)" || return 1
    parent="$(lsblk -nrpo PKNAME,TYPE "$node" 2>/dev/null | awk '$2 == "part" { print $1; exit }')"
    if [[ -n "$parent" ]]; then printf '%s\n' "$parent"; else printf '%s\n' "$node"; fi
}
TARGET_DISK="$(resolve_disk "$DEVICE")"
for refused in "${REFUSE_DISKS[@]}"; do
    if [[ "$TARGET_DISK" == "$(readlink -f "$refused")" ]]; then
        die "$TARGET_DISK is listed in REFUSE_DISKS in mkusb.sh and will not be touched
      (remove it from that list there if you really mean to install to it)"
    fi
done

# Refuse the disk the running system booted from, in case it is currently
# unmounted. Resolved with lsblk -s (the inverse tree), because a LUKS or LVM
# root resolves to itself under PKNAME and would otherwise never be compared
# against the physical disk underneath it.
ROOT_SRC=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
if [[ -n "$ROOT_SRC" ]]; then
    ROOT_DISK=$(lsblk -s -nrpo NAME,TYPE "$ROOT_SRC" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')
    if [[ -n "$ROOT_DISK" && "$ROOT_DISK" == "$TARGET_DISK" ]]; then
        die "$DEVICE is the disk this system booted from (/)"
    fi
fi

# Describe what is about to be destroyed, so the confirmation means something.
INFO_NAME=$(lsblk -nrdo MODEL "$DEVICE" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
INFO_SIZE=$(lsblk -bdndo SIZE "$DEVICE" 2>/dev/null | head -1 || true)
INFO_SERIAL=$(cat "/sys/class/block/$(basename "$DEVICE")/device/serial" 2>/dev/null || true)
INFO_REMOVE=$(cat "/sys/class/block/$(basename "$DEVICE")/removable" 2>/dev/null || echo 0)
if [[ -n "$INFO_SIZE" ]]; then
    INFO_SIZE=$(awk -v b="$INFO_SIZE" 'BEGIN{printf "%.1f GiB", b/1073741824}')
fi

echo
echo "About to ERASE: $DEVICE"
[[ -n "$INFO_NAME" ]] && echo "  model:  $INFO_NAME"
[[ -n "$INFO_SIZE" ]] && echo "  size:   $INFO_SIZE"
[[ -n "$INFO_SERIAL" ]] && echo "  serial: $INFO_SERIAL"
[[ "$INFO_REMOVE" == 1 ]] && echo "  (reports as removable)"
echo
read -r -p "Type the device path to confirm (e.g. $DEVICE): " CONFIRM
if [[ "$CONFIRM" != "$DEVICE" ]]; then
    echo "aborted."
    exit 1
fi

# ---------------------------------------------------------------------------
# Partition
# ---------------------------------------------------------------------------
info "erasing previous signatures on $DEVICE"
wipefs -a "$DEVICE" > /dev/null 2>&1 || true

info "partitioning (GPT: bios_grub, EFI, rlos-root${SIZE:+, root=$SIZE})"
# The GUIDs are read back afterwards with `sfdisk --json`, which is an output-only
# flag and so cannot be combined with a script on stdin. sfdisk assigns a fresh
# random GPT GUID to every partition on every run, and blkid -s PARTUUID depends
# on the KERNEL's in-memory partition table - so if that table has not been
# re-read yet, blkid hands back the PREVIOUS run's GUID, grub.cfg gets written
# with it, and the kernel boots looking for a partition that does not exist:
#
#   VFS: unable to mount root fs on unknown-block(0,0)
#
# That is not hypothetical - it is what this exact install produced once, with
# grub.cfg saying 6762b4c5-... while the disk actually carried abaf245b-....
# sfdisk's own dump is the authoritative record of what it just wrote, so there
# is no cache to race against. blkid is used later to cross-check.
sfdisk "$DEVICE" > /dev/null << EOF || die "sfdisk failed to partition $DEVICE"
label: gpt
start=1MiB, size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="bios_grub"
start=2MiB, size=$ESP_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
start=514MiB${SIZE:+, size=$SIZE}, type=linux, name="rlos-root"
EOF

# Settle udev before reading anything back, so the cross-check below compares
# like with like rather than racing the re-read.
udevadm settle 2>/dev/null || true

# The kernel may still be caching the old partition table, and without a re-read
# the new /dev nodes never appear. partprobe alone can refuse if the device is
# busy, so fall back to partx -u (updates only, never removes) and then to a
# reread of the table. Best effort: the wait below is the real guarantee, since
# it polls for the nodes rather than trusting any one of these to have worked.
partprobe "$DEVICE" 2>/dev/null || partx -u "$DEVICE" 2>/dev/null || blockdev --rereadpt "$DEVICE" 2>/dev/null || true

# Capture the table sfdisk just wrote, before any chance of a cache mismatch.
sfdisk --json "$DEVICE" > "$SCRIPT_DIR/.sfdisk.json" 2>/dev/null || \
    die "could not read back the partition table sfdisk just wrote to $DEVICE"

# Resolve partitions by their GPT names rather than by concatenating a suffix.
# The suffix is p for NVMe and mmc and nothing for sd, so sda1 vs nvme0n1p1 vs
# mmcblk0p1 are three different answers to the same question. /dev/disk/by-partlabel
# is uniform, and waiting for it also waits for the kernel to finish creating
# the nodes.
part_dev() {
    local name="$1" i=0
    while (( i < 100 )); do
        if [[ -b "/dev/disk/by-partlabel/$name" ]]; then
            readlink -f "/dev/disk/by-partlabel/$name"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

P2=$(part_dev EFI) || die "partition 'EFI' never appeared under /dev/disk/by-partlabel"
P3=$(part_dev rlos-root) || die "partition 'rlos-root' never appeared under /dev/disk/by-partlabel"
info "p2 = $P2    p3 = $P3"

info "formatting $P2 as FAT32 (EFI System Partition)"
mkfs.vfat -F32 -n EFI "$P2" > /dev/null

info "formatting $P3 as ext4 (rlos-root)"
# The two mkfs calls get individual error handling because they are the two most
# likely places for the hardware to fall over underneath us. On a failing stick
# mke2fs reports only "Input/output error while writing out and closing file
# system", which says nothing about the cause; the reason is in dmesg.
#
# This has been seen for real on a 128GB stick whose firmware advertised more
# capacity than its flash had: mkfs got ~99GB in (the offsets in dmesg's
# "device offline error" lines), then the device stopped answering and vanished
# from the bus entirely. mke2fs was fine. Hence the diagnostic below.
if ! mkfs.ext4 -q -F -L rlos-root "$P3"; then
    echo >&2
    echo "error: mkfs.ext4 failed on $P3." >&2
    echo >&2
    echo "  This is nearly always the stick failing mid-write, not this script." >&2
    echo "  Check the kernel log for what actually happened:" >&2
    echo >&2
    echo "      sudo dmesg | tail -40" >&2
    echo >&2
    echo "  'device offline error' or 'Buffer I/O error' means the hardware stopped" >&2
    echo "  answering. Also suspect a stick overstating its capacity, which is" >&2
    echo "  common at 64-128GB: the firmware reports more sectors than the flash" >&2
    echo "  has, so writes fail partway through." >&2
    echo >&2
    echo "  Try a different stick. To check one before committing to it:" >&2
    echo >&2
    echo "      sudo dd if=/dev/urandom of=/dev/sdX bs=4M oflag=direct status=progress" >&2
    echo >&2
    echo "  A stick that dies partway through a full-size write is not trustworthy." >&2
    exit 1
fi

# Authoritative source: the GUID sfdisk itself wrote. Parsed out of the JSON
# dump rather than the text dump because in the JSON, "uuid" comes BEFORE "name"
# within each partition object - so a "find the name, then look forward for the
# uuid" approach silently reads the wrong partition's GUID.
#
# Lowercased on the way out: sfdisk prints uppercase, blkid lowercase, and the
# kernel's PARTUUID= matcher is case-insensitive but a string comparison in the
# verification below would not be.
ROOT_PARTUUID=$(tr 'A-Z' 'a-z' < "$SCRIPT_DIR/.sfdisk.json" | awk '
    /"node"/ { u = ""; n = "" }
    /"uuid":/ {
        if (match($0, /"uuid": *"[0-9A-Fa-f-]+"/)) {
            line = substr($0, RSTART, RLENGTH)
            sub(/.*"uuid": *"/, "", line); sub(/".*/, "", line)
            u = line
        }
    }
    /"name":/ {
        if (match($0, /"name": *"[^"]*"/)) {
            line = substr($0, RSTART, RLENGTH)
            sub(/.*"name": *"/, "", line); sub(/".*/, "", line)
            n = line
        }
    }
    /}/ {
        if (n == "rlos-root" && u != "") { print u; exit }
    }
')
rm -f "$SCRIPT_DIR/.sfdisk.json"
[[ -n "$ROOT_PARTUUID" ]] || die "could not read the rlos-root GUID out of sfdisk's own JSON output
  (leaving grub.cfg without a correct root= would guarantee a VFS panic at boot)"

# Cross-check against the kernel's view, and only warn. The two can legitimately
# disagree for a moment after a re-read, which is exactly why the sfdisk value is
# the one that goes into grub.cfg - but a persistent disagreement means the table
# on disk is not the one sfdisk wrote, and the install should not be trusted.
BLKID_PARTUUID=$(blkid -s PARTUUID -o value "$P3" 2>/dev/null || true)
BLKID_PARTUUID="${BLKID_PARTUUID,,}"
if [[ -n "$BLKID_PARTUUID" && "$BLKID_PARTUUID" != "$ROOT_PARTUUID" ]]; then
    echo "  warning: kernel reports PARTUUID $BLKID_PARTUUID" >&2
    echo "  warning: sfdisk wrote             $ROOT_PARTUUID" >&2
    echo "  warning: using the sfdisk value; if this persists the table is not what was written" >&2
fi
info "root PARTUUID: $ROOT_PARTUUID"

# ---------------------------------------------------------------------------
# Populate
# ---------------------------------------------------------------------------
info "assembling rootfs (${WITH_X11:-text-only})"
# Staged next to this script rather than in /tmp: /tmp is a RAM-backed tmpfs on a
# lot of machines and the assembled rootfs is ~160 MB, which can fail there for
# no obvious reason. assemble-rootfs.sh rm -rf's and re-creates the target itself.
STAGE="${RLOS_STAGE:-$SCRIPT_DIR/rootfs-staging-usb}"
ROOT_MNT="$(mktemp -d)"
EFI_MNT="$(mktemp -d)"
cleanup() {
    umount "$EFI_MNT" 2>/dev/null || true
    umount "$ROOT_MNT" 2>/dev/null || true
    # rm -rf rather than rmdir: $STAGE holds a full rootfs copy, and rmdir
    # would silently leave ~150 MB behind in /tmp on every run.
    rm -rf "$STAGE" "$ROOT_MNT" "$EFI_MNT" 2>/dev/null || true
}
trap cleanup EXIT

"$SCRIPT_DIR/../assemble-rootfs.sh" $WITH_X11 $WITH_WAYLAND "$STAGE"

info "copying rootfs onto $P3"
mount "$P3" "$ROOT_MNT"
cp -a "$STAGE"/. "$ROOT_MNT"/

info "mounting $P2"
mount "$P2" "$EFI_MNT"

# grub-install infers which disk to write to from the filesystem that
# --boot-directory sits on. That is what makes it work here, but it is also a
# trap: given a boot-directory that is not really a mountpoint, it silently falls
# back to the HOST's root disk. Confirmed on this machine - pointed at a plain
# directory, grub-install resolved to /dev/dm-0 (the running system's LUKS volume)
# and tried to install onto it. So check before calling it, rather than trusting
# the mount to have worked.
for m in "$ROOT_MNT" "$EFI_MNT"; do
    mountpoint -q "$m" || die "$m is not a mountpoint - refusing to run grub-install
  (it would resolve --boot-directory against the HOST's disk, not the stick)"
done

KERNEL="$SCRIPT_DIR/../kernel-images/rlos/bzImage"

# ------------------------------------------------------------------ BIOS ---
# Read from the ext4 root, because that is where legacy BIOS GRUB can reach with
# only part_gpt and ext2 loaded.
#
# NO gfxterm here. GRUB is in the VGA text buffer at this point, and switching it
# to a VBE graphics mode would leave the kernel's VGA_CONSOLE with no text buffer
# to write into, so the handover would be a blank screen. That is a comment from
# install.sh and it is load-bearing.
#
# No initrd either: CONFIG_DEVTMPFS_MOUNT=y in kernel.config means the kernel
# mounts devtmpfs itself when there is no initramfs, so /dev/console exists by the
# time /sbin/init runs. The whole userspace is already on the ext4 partition.
info "writing BIOS boot files"
mkdir -p "$ROOT_MNT/boot/grub"
cp "$KERNEL" "$ROOT_MNT/boot/bzImage"
# rootwait is REQUIRED on a disk install, not optional.
#
# There is no initramfs here - the userspace is already on this ext4 partition -
# so root is mounted by the kernel's own early boot path in init/do_mounts.c:
#
#   end = ktime_add_ms(ktime_get_raw(), root_wait);
#   while (!driver_probe_done() || early_lookup_bdev(root, &ROOT_DEV) < 0) {
#           msleep(5);
#           if (root_wait > 0 && ktime_after(...)) break;
#   }
#
# `static int root_wait;` is zero-initialised and only set by the rootwait
# parameter. Left at 0, the deadline is already expired, so that loop breaks
# after ONE 5ms sleep and the kernel panics:
#
#   VFS: unable to mount root fs on unknown-block(0,0)
#
# That is exactly what happened here - with the partition table correct, the USB
# drivers compiled in, and the PARTUUID verified against the disk. USB
# enumeration takes far longer than 5ms, so the kernel gives up before the disk
# exists. LFS documents this same failure and suggests rootdelay for it; rootwait
# is the better tool because it retries until the device actually appears instead
# of guessing a delay, and it can be bounded: rootwait=30 gives up after 30s.
#
# Why the live ISO does not need this: its rootfs is in the initramfs, so nothing
# has to be found at this early stage. The stick has no initramfs, which is the
# whole difference between working and not.
cat > "$ROOT_MNT/boot/grub/grub.cfg" << EOF
set timeout=5
serial --unit=0 --speed=115200
terminal_input serial console

# BIOS GRUB is in the VGA text buffer. gfxterm would move it to a VBE graphics
# mode that the kernel's VGA_CONSOLE cannot write text into, so the handover
# would be blank. Plain console is correct for this path.
terminal_output serial console

# Two console= entries on purpose: the kernel registers both so messages reach
# serial and screen alike, but /dev/console resolves to the LAST one, so tty0 is
# what the shell and klogd get.
menuentry "rlOS" {
  linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rw rootwait console=ttyS0,115200 console=tty0 loglevel=3 fbcon=font:SUN12x22
}

# Headless: for serial-only or headless machines, where tty0 is not visible.
menuentry "rlOS (serial)" {
  linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rw rootwait console=ttyS0,115200 loglevel=3
}

menuentry "rlOS (debug)" {
  linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rw rootwait console=ttyS0,115200 console=tty0 loglevel=7 earlyprintk=serial,ttyS0,115200
}
EOF

# ------------------------------------------------------------------ UEFI ---
# Read from the FAT ESP, because that is the only filesystem UEFI firmware can
# hand to GRUB at all - it is a firmware specification requirement, not a
# preference.
#
# gfxterm IS correct here. Under UEFI the kernel inherits the framebuffer the
# firmware set up (DRM_EFIDRM), so GRUB drawing into it and the kernel continuing
# from it is the intended path.
info "writing UEFI boot files"
mkdir -p "$EFI_MNT/boot/grub"
cp "$KERNEL" "$EFI_MNT/boot/bzImage"
cat > "$EFI_MNT/boot/grub/grub.cfg" << EOF
set timeout=5
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial gfxterm

# No fbcon=font: here. Under UEFI the kernel prefers DRM_I915 when it finds the
# GPU, and falls back to DRM_EFIDRM otherwise; the framebuffer that GRUB drew
# into is not necessarily the one the console ends up on. Forcing a font size
# across that handover is fragile, and its failure mode is exactly a bare cursor
# with no text. The font is cosmetic, so it is not requested by default here.
menuentry "rlOS" {
  linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rw rootwait console=ttyS0,115200 console=tty0 loglevel=3
}

# Recovery entry for a screen that shows only a bare cursor after handover.
# nomodeset forces legacy VGA text mode, so console=tty0 has something to write
# into even when the UEFI framebuffer is unusable. Also drops the fbcon font
# request and raises loglevel. Use this to separate "the kernel ran but the video
# handover failed" from "the kernel never reached root" - the latter prints VFS
# errors here, the former prints nothing.
menuentry "rlOS (text mode / nomodeset)" {
  linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rw rootwait nomodeset console=tty0 loglevel=7
}

menuentry "rlOS (serial)" {
  linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rw rootwait console=ttyS0,115200 loglevel=3
}

menuentry "rlOS (debug)" {
  linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rw rootwait console=ttyS0,115200 console=tty0 loglevel=7 earlyprintk=serial,ttyS0,115200
}
EOF

# ---------------------------------------------------------------------------
# Bootloaders
# ---------------------------------------------------------------------------
# --removable writes EFI/BOOT/BOOTX64.EFI, which is the path firmware falls back
# to when it has no NVRAM boot entry for this stick. Without it a stick that has
# never been booted from would present no bootable device on a machine with no
# efibootmgr entry, which is most machines the first time.
#
# i386-efi as well: 32-bit UEFI firmware loads BOOTIA32.EFI and falls back to
# BOOTX64.EFI otherwise, and some of it only looks at the 32-bit name.
# EFI_MNT is the ESP root, so --efi-directory must be EFI_MNT itself - that is
# what makes grub-install create EFI_MNT/EFI/BOOT/BOOTX64.EFI. Pointing it at
# "$EFI_MNT/EFI" is wrong twice over: that subdirectory is never created (the
# only dir made on the ESP is EFI_MNT/boot), so GRUB 2.14 aborts with
# "failed to get canonical path of .../EFI", and even if it existed it would
# nest the tree as EFI/EFI/BOOT.
#
# mkdir -p as well, so the fallback layout exists even if grub-install skips
# creating it.
mkdir -p "$EFI_MNT/EFI/BOOT"

info "installing GRUB (UEFI, x86_64)"
grub-install --target=x86_64-efi --efi-directory="$EFI_MNT" \
    --boot-directory="$EFI_MNT/boot" --removable "$DEVICE"

info "installing GRUB (UEFI, i386)"
grub-install --target=i386-efi --efi-directory="$EFI_MNT" \
    --boot-directory="$EFI_MNT/boot" --removable "$DEVICE" || \
    echo "  warning: i386-efi install failed, continuing (x86_64 fallback covers most firmware)"

info "installing GRUB (legacy BIOS)"
grub-install --target=i386-pc --modules="part_gpt ext2" \
    --boot-directory="$ROOT_MNT/boot" "$DEVICE"

# Read the GUID back off the disk now that udev has certainly caught up, and
# refuse to declare success unless it matches what went into grub.cfg. This is the
# check that would have caught the stale-PARTUUID panic: the failure mode is a
# stick that installs "successfully" and then panics at boot with
# "VFS: unable to mount root fs on unknown-block(0,0)", which is a miserable
# thing to debug after the fact and trivial to prevent here.
ON_DISK_PARTUUID=$(blkid -s PARTUUID -o value "$P3")
ON_DISK_PARTUUID="${ON_DISK_PARTUUID,,}"
if [[ "$ON_DISK_PARTUUID" != "$ROOT_PARTUUID" ]]; then
    echo >&2
    echo "error: refusing to report success." >&2
    echo "  grub.cfg points root= at : $ROOT_PARTUUID" >&2
    echo "  the disk actually carries : ${ON_DISK_PARTUUID:-<none>}" >&2
    echo >&2
    echo "  Boot would panic with:" >&2
    echo "    VFS: unable to mount root fs on unknown-block(0,0)" >&2
    echo >&2
    echo "  This means the partition table changed under us. Unplug the stick," >&2
    echo "  re-insert it, and run this again." >&2
    exit 1
fi

# Same check for the two grub.cfg files we just wrote: if either says something
# other than the verified GUID, the install is broken regardless of the table.
for cfg in "$ROOT_MNT/boot/grub/grub.cfg" "$EFI_MNT/boot/grub/grub.cfg"; do
    if ! grep -q "root=PARTUUID=$ROOT_PARTUUID" "$cfg"; then
        die "$cfg does not contain root=PARTUUID=$ROOT_PARTUUID - install is inconsistent"
    fi
done

cleanup
trap - EXIT
sync

echo
ok "$DEVICE is now a bootable, persistent rlOS stick"
echo
echo "  root=PARTUUID=$ROOT_PARTUUID (verified against the disk after writing)"
echo "  boot from it in your firmware's boot menu (F12/Esc/F1 at power on)"
echo "  everything you write under /home/user persists across reboots"
echo "  to reinstall, wipe your files and run this script again"