#!/bin/sh
# rlos-install.sh - install this running rlOS system onto a disk.
#
# WHAT IT DOES
#
# Run from a live ISO or live USB stick. It copies the running system onto a
# block device and installs a bootloader, so the machine boots that disk next
# time instead of the medium. EVERYTHING ON THE TARGET IS ERASED.
#
# WHY THIS IS A SCRIPT YOU CAN EDIT
#
# Same reasoning as atom-shell.sh: partitioning is the part that destroys data,
# so it is the part that must not be hidden behind a wrapper. Every step below
# prints the command it is about to run, and --dry-run prints all of them
# without executing any. Read it, change it, copy it.
#
# THE INSTALLED SYSTEM, AND WHY THERE IS NO initramfs.gz
#
# The target gets /boot/bzImage and /boot/grub/grub.cfg and nothing else from
# this script's point of view, because the root filesystem IS the running
# filesystem, copied across. /init there is a symlink to /sbin/init, which is
# the rlOS init itself, so the kernel's root=PARTUUID= finds a normal Linux
# system with a real init and runs it. This is the layout rlos-disk/install.sh
# already produces, and the one mkusb.sh ships.
#
# This matters because there is no initramfs.gz to copy. The live system's / is
# the unpacked initramfs; the compressed original lives only where GRUB read it
# from, and nothing mounts the ISO afterwards (the kernel has no iso9660
# support, and a USB stick is not an ISO to begin with). The kernel itself IS
# reachable, because mkiso -i copies it into the image at /boot/bzImage - which
# is also why this script has nothing to do about kernels.
#
# CONFIGURATION
#
# Defaults are below. Three layers, later winning:
#
#   1. the defaults in this file
#   2. /etc/rlos-install.conf        (shipped with the image)
#   3. ~/.rlos-install.conf          (yours)
#
# and then any flag on the command line, which wins over all three. Config
# files are plain KEY=value shell syntax and are sourced, so # comments work.
#
#   DEVICE        block device, e.g. /dev/sdb. Empty means "ask, from a list".
#   TABLE         gpt (default) or mbr
#   ROOT_SIZE     root partition size - a number with G/M suffix, or "max"
#   ESP_SIZE      EFI System Partition size; 0 means no ESP and BIOS only
#   FS_TYPE       ext4 (default, journalled) or ext2
#   FS_LABEL      filesystem label for the root partition
#   BOOT_MODE     both (default), bios, or efi
#   HOSTNAME      hostname for the installed system
#   USER_PASSWORD password for the `user` account
#   CMDLINE_EXTRA extra words appended to every kernel command line
#   HOOK          script to run INSIDE the installed system, chrooted, after
#                 the rootfs is in place and before it is unmounted
#
# THE SAFEGUARDS, AND WHY THERE ARE NOT MORE
#
# Refuses: a read-only device, a device with anything mounted on it, a device
# too small to hold this system, and any device whose path you have not typed
# back in full.
#
# What it deliberately does NOT refuse is the medium you booted from. That
# looks like an oversight and is the opposite of one: this system's root is in
# RAM, so nothing on the boot medium is being read at this moment, and
# overwriting it cannot disturb the running session. Installing onto the stick
# you booted from is the normal case. mkusb.sh refuses that device because it
# runs from that device; the reasoning does not transfer to a RAM-rooted guest.

set -eu

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEVICE=""
TABLE="gpt"
ROOT_SIZE="max"
ESP_SIZE="512M"
FS_TYPE="ext4"
FS_LABEL="rlos-root"
BOOT_MODE="both"
HOSTNAME=""
USER_PASSWORD=""
CMDLINE_EXTRA=""
HOOK=""
ASSUME_YES=0
DRY_RUN=0

CONF_SYSTEM="/etc/rlos-install.conf"
CONF_USER="$HOME/.rlos-install.conf"
GRUB_DIR="/usr/share/rlos/grub"
MNT=/mnt/rlos-install

# ---------------------------------------------------------------------------
# Colour. Same vocabulary and the same gate as build-lib.sh, so the installer
# looks like the rest of the tooling rather than like a separate tool.
#
# POSIX sh has no $'\e', so the escape sequences are assembled from a literal
# ESC built with printf. `[ -t 1 ]` means "stdout is a terminal", which is the
# point at which colour is worth having: piped into a file or captured by an
# SSH command, escape codes would be litter rather than emphasis. NO_COLOR is
# honoured per https://no-color.org.
#
# There is no `tput`/`infocmp` check either. Those depend on TERM being set
# and on a terminfo database being present in the guest, and rlOS ships neither
# reliably; a terminal that does not understand these particular sequences will
# show them literally, which is a rarer problem than the one being fixed here.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    ESC=$(printf '\033')
    BOLD="$ESC[1m"; DIM="$ESC[2m"; RST="$ESC[0m"
    CYN="$ESC[36m"; GRN="$ESC[32m"; YLW="$ESC[33m"
    RED="$ESC[31m"; MAG="$ESC[35m"
else
    BOLD=""; DIM=""; RST=""
    CYN=""; GRN=""; YLW=""; RED=""; MAG=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RST"; }
warn() { printf '%sWARNING:%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# run <cmd...>
#
# The single place anything is actually executed. Every destructive step goes
# through here, so --dry-run is honoured everywhere by construction instead of
# by remembering to check a flag at each of them.
run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '    %s[dry-run]%s %s%s%s\n' "$MAG" "$RST" "$DIM" "$*" "$RST"
        return 0
    fi
    printf '    %s%s%s\n' "$DIM" "$*" "$RST"
    "$@"
}

# stdin variants, for the heredocs that feed sfdisk.
run_stdin() {
    if [ "$DRY_RUN" = "1" ]; then
        # $* not $1: the device is the second argument, and printing only the
        # command name hides which disk the preview would be written to.
        printf '    %s[dry-run]%s %s%s <<EOF%s\n' "$MAG" "$RST" "$DIM" "$*" "$RST"
        cat
        printf '%sEOF%s\n' "$DIM" "$RST"
        return 0
    fi
    "$@"
}

usage() {
    cat >&2 << 'EOF'
usage: rlos-install.sh [options]

  --disk DEV      install onto DEV (e.g. /dev/sdb). Omit to pick from a list.
  --table gpt|mbr partition table type                      [gpt]
  --root-size S   root partition size, or "max"             [max]
  --esp-size S    EFI partition size, or 0 for BIOS only    [512M]
  --fs ext4|ext2  root filesystem                           [ext4]
  --label NAME    filesystem label                          [rlos-root]
  --boot M        both | bios | efi                         [both]
  --hostname N    hostname on the installed system
  --password P    password for the `user` account
  --cmdline "S"   extra words for every kernel command line
  --hook PATH     script to run inside the installed system before unmount
  --yes, -y       skip the "type the device path back" confirmation
  --dry-run, -n   print every command, change nothing
  --help, -h      this text

Settings also come from /etc/rlos-install.conf and ~/.rlos-install.conf.
EOF
}

# to_mib 512M -> 512, 1G -> 1024, 4096K -> 4, 512 -> 512
# Integer arithmetic only; bc is not in the live system.
to_mib() {
    case "$1" in
        *[Kk]) echo $(( ${1%[Kk]} / 1024 )) ;;
        *[Mm]) echo ${1%[Mm]} ;;
        *[Gg]) echo $(( ${1%[Gg]} * 1024 )) ;;
        *[!0-9]*) die "cannot read '$1' as a size (try 512M, 8G)" ;;
        *)     echo $1 ;;
    esac
}

need_tools() {
    missing=""
    # mkfs.vfat is busybox's mkdosfs, which is already in every image and makes
    # FAT32 at this size - verified, and no dosfstools needed on the ISO.
    for t in sfdisk mke2fs mkfs.vfat dd tar; do
        command -v "$t" > /dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] && return 0
    die "missing$missing - this image has no installer"
    die "rebuild the image with 'mkiso.sh -i'"
}

# busybox also provides mke2fs and tune2fs, and with the guest's PATH
# (/bin first) the applet in /bin beat the e2fsprogs build in /usr/bin. busybox's
# mke2fs has no -t and can only make ext2, so `mke2fs -t ext4` died with
# "invalid option -- 't'" halfway through an install. build_busybox.sh now
# excludes both applets, so this should be the real one - assert it anyway,
# because the failure without this check is baffling and arrives late.
check_mke2fs() {
    mke2fs -h 2>&1 | grep -q -- '-t fs-type' && return 0
    die "the mke2fs on PATH is busybox's applet, which cannot create ext4"
    die "rebuild busybox with MKE2FS excluded, or install e2fsprogs"
}

# ---------------------------------------------------------------------------
# Options: config files first, so flags override them
# ---------------------------------------------------------------------------
need_tools
check_mke2fs

[ -f "$CONF_SYSTEM" ] && . "$CONF_SYSTEM"
[ -f "$CONF_USER" ] && . "$CONF_USER"

while [ $# -gt 0 ]; do
    case "$1" in
        --disk)       DEVICE="${2:?--disk needs a value}"; shift 2 ;;
        --table)      TABLE="${2:?--table needs a value}"; shift 2 ;;
        --root-size)  ROOT_SIZE="${2:?}"; shift 2 ;;
        --esp-size)   ESP_SIZE="${2:?}"; shift 2 ;;
        --fs)         FS_TYPE="${2:?}"; shift 2 ;;
        --label)      FS_LABEL="${2:?}"; shift 2 ;;
        --boot)       BOOT_MODE="${2:?}"; shift 2 ;;
        --hostname)   HOSTNAME="${2:?}"; shift 2 ;;
        --password)   USER_PASSWORD="${2:?}"; shift 2 ;;
        --cmdline)    CMDLINE_EXTRA="${2:?}"; shift 2 ;;
        --hook)       HOOK="${2:?}"; shift 2 ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --dry-run|-n) DRY_RUN=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

case "$TABLE"   in gpt|mbr) ;; *) die "--table must be gpt or mbr, not '$TABLE'" ;; esac
case "$FS_TYPE" in ext4|ext2) ;; *) die "--fs must be ext4 or ext2, not '$FS_TYPE'" ;; esac
case "$BOOT_MODE" in both|bios|efi) ;; *) die "--boot must be both, bios or efi, not '$BOOT_MODE'" ;; esac
case "$ROOT_SIZE" in max|*[0-9]*[KMGkmg]|[0-9]*) ;; *) die "cannot read --root-size '$ROOT_SIZE'" ;; esac

WITH_ESP=1
case "$BOOT_MODE" in
    bios) WITH_ESP=0
          [ "$ESP_SIZE" != "512M" ] && warn "--boot bios ignores --esp-size" ;;
    efi)  [ "$ESP_SIZE" = "0" ] && die "--boot efi with --esp-size 0 contradicts itself" ;;
esac
[ "$ESP_SIZE" = "0" ] && WITH_ESP=0

# MBR plus UEFI is not something worth supporting: firmware that wants an EFI
# system partition off an MBR disk gets it read unreliably, and the failure is
# a machine that simply does not boot. Refusing here is kinder than that.
if [ "$TABLE" = "mbr" ] && [ "$WITH_ESP" = "1" ]; then
    die "--table mbr with an ESP is not supported (use --table gpt, or --boot bios)"
fi

[ -f /boot/bzImage ] || die "no /boot/bzImage in this image - it was built without -i"

say "rlOS installer"
say "  table=$TABLE  root=$ROOT_SIZE  fs=$FS_TYPE  boot=$BOOT_MODE"
[ "$WITH_ESP" = "1" ] && say "  esp=$ESP_SIZE  label=$FS_LABEL"
[ -n "$HOSTNAME" ] && say "  hostname=$HOSTNAME"
[ -n "$CMDLINE_EXTRA" ] && say "  cmdline extra: $CMDLINE_EXTRA"
[ -n "$HOOK" ] && say "  hook: $HOOK"
[ "$DRY_RUN" = "1" ] && say "  *** DRY RUN - nothing will be written ***"

# ---------------------------------------------------------------------------
# Guards. Each one is a way to destroy something that was not meant to be
# destroyed, so they all run before anything is written.
# ---------------------------------------------------------------------------
list_disks() {
    printf 'block devices:\n\n'
    for s in /sys/block/*/size; do
        d="/sys/block/$(basename "$(dirname "$s")")"
        n=$(basename "$d")
        case "$n" in loop*|ram*|zram*|sr*|dm-*) continue ;; esac
        sz=$(cat "$s" 2>/dev/null || echo 0)
        [ "$sz" -gt 0 ] || continue
        [ -f "$d/removable" ] && kind=$(cat "$d/removable") || kind=0
        [ "$kind" = "1" ] && kind="removable" || kind="fixed"
        printf '  /dev/%-8s %6s  %s\n' "$n" \
            "$(awk -v s="$sz" 'BEGIN{printf "%.1fG", s*512/1048576}')" "$kind"
    done
    printf '\n'
}

if [ -z "$DEVICE" ]; then
    list_disks
    printf 'install onto which device? (e.g. /dev/sdb): '
    read -r DEVICE
fi

case "$DEVICE" in
    /dev/*) ;;
    *) die "DEVICE must be a full path like /dev/sdb, not '$DEVICE'" ;;
esac
[ -b "$DEVICE" ] || die "$DEVICE is not a block device"

DISK=$(basename "$DEVICE")

# Partition node names are not "<disk><n>". The kernel inserts a "p" whenever
# the disk name itself ends in a digit, so sda1 and vda1 but loop0p1 and
# nvme0n1p1. Building these by concatenation silently looks for /dev/nvme01,
# which never exists, so the installer would sit in wait_for_nodes until it
# gave up. This is the kernel's own naming rule, not a special case.
case "$DISK" in
    *[0-9]) PSEP="p" ;;
    *)     PSEP="" ;;
esac

SECT_SIZE=512
DISK_SECTORS=$(cat "/sys/block/$DISK/size" 2>/dev/null || echo 0)
DISK_KB=$(( DISK_SECTORS * SECT_SIZE / 1024 ))

# A size of zero means there is no medium behind this name, and there is nothing
# to install onto. This has to be fatal rather than a warning, because
# "[ -b $DEVICE ]" does not catch it: devtmpfs keeps /dev/loop0..7 present
# whether or not anything is attached to them, so an unattached loop device
# passes the block-device test and then fails later, at dd, with
# "No space left on device" - a confusing way to learn you forgot losetup.
if [ "$DISK_SECTORS" -le 0 ]; then
    die "$DEVICE has no medium attached (the kernel reports it as 0 bytes)"
    case "$DISK" in
        loop*)
            printf '  loop devices need a backing file, and partitions need --partscan:\n' >&2
            printf '      losetup --partscan %s /path/to/disk.img\n' "$DEVICE" >&2
            ;;
    esac
    printf '  if this is real hardware, the drive may be unplugged or uninitialised.\n' >&2
    exit 1
fi

# Read-only: an optical disc, a write-protected stick. /sys is authoritative and
# beats asking the user, who is the thing most likely to be wrong.
if [ -f "/sys/block/$DISK/ro" ] && [ "$(cat "/sys/block/$DISK/ro")" = "1" ]; then
    die "$DEVICE is read-only (this is what the kernel reports, and it is right)"
fi

# Something mounted underneath is someone's data, not ours.
MOUNTED=$(awk -v d="$DEVICE" '$1==d || index($1, d)==1 {print "      " $1 " -> " $2}' /proc/mounts 2>/dev/null || true)
if [ -n "$MOUNTED" ]; then
    die "$DEVICE has mounted filesystems - unmount them first:"
    printf '%s\n' "$MOUNTED" >&2
    exit 1
fi

# Room for the system plus filesystem overhead. 1.6x covers the journal and the
# slack a fresh filesystem reserves.
NEED_KB=$(( $(du -sk / 2>/dev/null | cut -f1) * 16 / 10 ))
if [ "$DISK_KB" -gt 0 ] && [ "$DISK_KB" -lt "$NEED_KB" ]; then
    say "  this system needs about $(( NEED_KB / 1024 ))M, $DEVICE is $(( DISK_KB / 1024 ))M"
    die "$DEVICE is too small"
fi

# The guard that actually protects people: type the path back.
if [ "$ASSUME_YES" != "1" ]; then
    printf '\nEVERYTHING ON %s WILL BE ERASED.\n' "$DEVICE"
    printf 'Type the device path to confirm: '
    read -r CONFIRM
    [ "$CONFIRM" = "$DEVICE" ] || die "no match - aborted, nothing was written"
fi

say ""
say "Installing rlOS to $DEVICE ($(( DISK_KB / 1024 ))M, $FS_TYPE, boot=$BOOT_MODE)"

# ---------------------------------------------------------------------------
# 1. Erase what is there
#
# dd, not wipefs, which this system does not have. The first 4 MiB is the
# primary GPT and partition table; the BACKUP GPT lives in the last 33 sectors
# and matters just as much, because a stale one is exactly what makes a disk
# appear to still have partitions on it after they have been overwritten.
# ---------------------------------------------------------------------------
step "Erasing $DEVICE"
run dd if=/dev/zero of="$DEVICE" bs=1M count=4 conv=fsync
if [ "$TABLE" = "gpt" ]; then
    run dd if=/dev/zero of="$DEVICE" bs=512 count=33 \
        seek=$(( DISK_SECTORS - 33 )) conv=fsync
fi

# ---------------------------------------------------------------------------
# 2. Partition
#
# The GPT layout is mkusb.sh's: 1 MiB bios_grub, then the ESP, then root. The
# bios_grub partition exists because BIOS GRUB cannot read GPT - core.img has to
# live somewhere the firmware chain will hand over to it. The ESP is FAT because
# it is the only filesystem UEFI firmware is required to read.
#
# On MBR there is no bios_grub partition: the 1 MiB gap after the MBR is where
# core.img goes, which is what grub-bios-setup does.
# ---------------------------------------------------------------------------
step "Writing a $TABLE partition table"

ROOT_SIZE_ARG=""
[ "$ROOT_SIZE" != "max" ] && ROOT_SIZE_ARG=", size=$ROOT_SIZE"

if [ "$TABLE" = "gpt" ] && [ "$WITH_ESP" = "1" ]; then
    ESP_MIB=$(to_mib "$ESP_SIZE")
    run_stdin sfdisk "$DEVICE" << EOF
label: gpt
start=1MiB, size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="bios_grub"
start=2MiB, size=${ESP_MIB}MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
start=$(( 2 + ESP_MIB ))MiB${ROOT_SIZE_ARG:+, size=$ROOT_SIZE}, type=linux, name="rlos-root"
EOF
    P_BIOS=/dev/${DISK}${PSEP}1
    P_ESP=/dev/${DISK}${PSEP}2
    P_ROOT=/dev/${DISK}${PSEP}3
elif [ "$TABLE" = "gpt" ]; then
    run_stdin sfdisk "$DEVICE" << EOF
label: gpt
start=1MiB, size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="bios_grub"
start=2MiB${ROOT_SIZE_ARG:+, size=$ROOT_SIZE}, type=linux, name="rlos-root"
EOF
    P_BIOS=/dev/${DISK}${PSEP}1
    P_ESP=""
    P_ROOT=/dev/${DISK}${PSEP}2
else
    run_stdin sfdisk "$DEVICE" << EOF
label: dos
start=1MiB, type=linux, name="rlos-root"
EOF
    P_BIOS=""
    P_ESP=""
    P_ROOT=/dev/${DISK}${PSEP}1
fi

# sfdisk already tries BLKRRPART itself and prints what happened, but it treats
# failure as advisory and carries on. On most hardware the kernel accepts the
# re-read immediately and the nodes are there by the time we look. Where it does
# not - a loop device, most often - the nodes never appear at all, so it is worth
# asking again ourselves before giving up.
#
# Both of these are advisory. There is no partx in this image, and none of the
# three is required: the poll below is the actual guarantee, not these calls.
reread_pt() {
    command -v blockdev > /dev/null 2>&1 && blockdev --rereadpt "$DEVICE" 2>/dev/null && return 0
    command -v partprobe > /dev/null 2>&1 && partprobe "$DEVICE" 2>/dev/null && return 0
    return 1
}

# The kernel has not necessarily re-read the table yet. Polling for the device
# nodes is the real guarantee, and it is why this does not use
# /dev/disk/by-partlabel: that directory is made by udev, and udev only ships in
# X11 images, so on a text-only -i image it does not exist.
wait_for_nodes() {
    n=0
    while [ "$n" -lt 50 ]; do
        missing=0
        for p in "$@"; do
            [ -b "$p" ] || missing=1
        done
        [ "$missing" = "0" ] && return 0
        sleep 0.1 2>/dev/null || sleep 1
        n=$(( n + 1 ))
    done

    # Diagnose rather than restate. The overwhelmingly common cause is a loop
    # device, and the fix is not anything this script can do from here: the loop
    # driver only registers partitions at all when the device was opened with
    # --partscan, so the nodes are unreachable until losetup is re-run with -P.
    die "the partition device nodes never appeared - the kernel did not re-read the table"
    case "$DISK" in
        loop*)
            printf '  %s is a loop device. Those only get partitions if they were\n' "$DEVICE" >&2
            printf '  set up with --partscan, so this cannot be fixed from inside:\n' >&2
            printf '      losetup -d %s\n' "$DEVICE" >&2
            printf '      losetup --partscan %s <backing-file>\n' "$DEVICE" >&2
            ;;
    esac
    printf '  sfdisk reported the re-read failing above; on real hardware this can also\n' >&2
    printf '  mean the device is held open, or needs partx -a %s\n' "$DEVICE" >&2
    exit 1
}

if [ "$DRY_RUN" != "1" ]; then
    reread_pt || true
    # P_BIOS is included because the BIOS step dd's into it, and a dd whose
    # output node does not exist is a failure with no useful message. The
    # kernel creates all three nodes in one go, so this is belt-and-braces
    # rather than a race worth worrying about.
    wait_for_nodes "$P_ROOT" ${P_ESP:+"$P_ESP"} ${P_BIOS:+"$P_BIOS"}
fi

# PARTUUID, read from sfdisk's own JSON rather than from blkid. busybox blkid
# cannot report PARTUUID at all, and mkusb.sh's comment records what happens
# when you ask the kernel instead: it hands back the PREVIOUS run's GUID until
# its in-memory table catches up. sfdisk wrote the table, so sfdisk knows.
partuuid_of() {
    sfdisk --json "$DEVICE" 2>/dev/null | awk -F'"' -v want="$1" \
        '/"uuid"/{u=$4} /"name"/ && $4==want {print u; exit}'
}

ROOT_PARTUUID=$(partuuid_of "rlos-root")
if [ -z "$ROOT_PARTUUID" ]; then
    # In a dry run there is no table yet, so there is no GUID to read - the
    # value only exists after the very step the dry run declined to perform.
    # Dying here made --dry-run useless: it stopped at the first step that
    # depends on real state and never previewed the other half. Substitute a
    # placeholder so the rest of the sequence can still be shown.
    if [ "$DRY_RUN" = "1" ]; then
        ROOT_PARTUUID="<read-from-sfdisk-after-the-write>"
        say "  root PARTUUID: (dry run - assigned by sfdisk when the table is written)"
    else
        die "could not read the PARTUUID of rlos-root"
    fi
else
    say "  root PARTUUID: $ROOT_PARTUUID"
fi

# ---------------------------------------------------------------------------
# 3. Filesystems
# ---------------------------------------------------------------------------
step "Creating filesystems"
# -F because mke2fs otherwise stops to ask when it finds a filesystem already
# on the partition ("Proceed anyway? (y,N)"). Every guard above this point has
# already established that erasing is what was asked for - the device is not
# read-only, nothing is mounted on it, it is big enough, and its path was typed
# back by hand. Stopping to ask again at this depth is not caution, it is a
# prompt with no good default: answer N and the install half-completes, answer
# anything else and nobody is really there to answer.
run mke2fs -q -F -t "$FS_TYPE" -L "$FS_LABEL" "$P_ROOT"
if [ -n "$P_ESP" ]; then
    run mkfs.vfat -n EFI "$P_ESP"
fi

# ---------------------------------------------------------------------------
# 4. Copy the running system across
#
# tar with excludes rather than cp -a, because / in a live session has live
# kernel state mounted on it: copying /proc would copy a running kernel's idea
# of itself, and copying /dev would copy the nodes of THIS machine's disks onto
# the new one's /dev. Pseudo-filesystems are excluded wholesale.
# ---------------------------------------------------------------------------
step "Copying the system to $P_ROOT"
# These two mkdirs are the only writes outside run(), so they need the dry-run
# check themselves. --dry-run promises it writes nothing, and creating
# /mnt/rlos-install is a write.
run mkdir -p "$MNT"
run mount "$P_ROOT" "$MNT"
run mkdir -p "$MNT/boot" "$MNT/etc"

if [ "$DRY_RUN" = "1" ]; then
    printf '    %s[dry-run]%s %s%star: copy / to %s excluding pseudo-filesystems%s\n' \
        "$MAG" "$RST" "$DIM" "$MNT" "$RST"
else
    # shellcheck disable=SC2164
    ( cd / && tar -cf - \
        --exclude=./proc --exclude=./proc/\* \
        --exclude=./sys  --exclude=./sys/\* \
        --exclude=./dev  --exclude=./dev/\* \
        --exclude=./run  --exclude=./run/\* \
        --exclude=./tmp  --exclude=./tmp/\* \
        --exclude=./mnt  --exclude=./mnt/\* \
        . ) | ( cd "$MNT" && tar -xpf - ) \
        || die "the copy failed - unmount $MNT by hand before retrying"

    # Everything copied just now is owned by whoever built the image, because
    # assemble-rootfs.sh runs unprivileged and tar -p faithfully preserves that.
    # On a live ISO it is merely untidy - init runs as root and ignores it, and
    # the tree is RAM that disappears at power-off.
    #
    # On disk it is not untidy, it is broken. init.c notes the same thing when
    # it fixes up /var/empty at every boot: "sshd refuses to start unless this
    # directory is owned by root and is not group- or world-writable". That is
    # the privilege-separation check, and with /var/empty owned by uid 1000
    # sshd simply refuses to start - no login over the network, and init's
    # warning scrolls past among its own output. /sbin/init, /etc/shadow and
    # the whole of /usr/bin would likewise be writable by the `user` account.
    #
    # chown rather than fixing it in assemble-rootfs.sh, because that script
    # cannot: it runs unprivileged, so it has no business setting uid 0 on
    # anything. Here we are root and writing onto a mounted target, which is
    # exactly the position that makes the chown legitimate.
    #
    # This includes /home/user, which therefore lands root-owned and is then
    # handed back to the user account by init.c's chown_tree("/home/user") at
    # boot. That is not redundant work: init.c does it every boot regardless,
    # and it is what keeps the live and installed systems agreeing.
    chown -R 0:0 "$MNT" || die "chown failed - the installed tree would be left owned by uid 1000"

    # The mount points themselves, which the tar copy above deliberately does NOT
    # bring across - it excludes ./proc, ./sys, ./dev, ./run and ./tmp wholesale
    # so that live kernel state is not copied.
    #
    # Excluding the CONTENTS is right. Excluding the DIRECTORIES is not: the
    # target then boots with no /dev, no /proc and no /sys at all, and nothing
    # downstream can recover, because each of those filesystems is mounted onto a
    # directory that has to exist first. The whole failure cascade comes from
    # this one omission:
    #
    #   /dev missing       -> devtmpfs has nowhere to mount -> no /dev/null, no
    #                         /dev/console, no /dev/pts, no network interfaces
    #   /proc missing      -> procfs will not mount -> klogd: cannot open
    #                         /proc/kmsg, and it respawns in a loop
    #   /sys missing       -> sysfs will not mount -> no NIC enumeration, hence
    #                         "no wired interface found - skipping DHCP"
    #   /dev/pts missing   -> no PTY allocation, so no interactive login
    #
    # and the visible result was a system that boots, reaches a shell, and is
    # visibly broken in ways that have nothing to do with each other.
    #
    # Empty directories with root ownership are all that is needed: devtmpfs and
    # the kernel mount over the top of them at boot and supply the contents.
    run mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT/tmp" \
        || die "could not create the mount points on the installed root"
    chown 0:0 "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT/tmp" 2>/dev/null || true
    say "  mount points created: /dev /proc /sys /run /tmp (empty; the kernel mounts over them)"
fi

# ---------------------------------------------------------------------------
# 5. Make it this machine, not this session
# ---------------------------------------------------------------------------
step "Applying your settings"

if [ -n "$HOSTNAME" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        printf '    [dry-run] write hostname %s\n' "$HOSTNAME"
    else
        printf '%s\n' "$HOSTNAME" > "$MNT/etc/hostname"
        say "  hostname: $HOSTNAME"
    fi
fi

if [ -n "$USER_PASSWORD" ]; then
    # /etc was overwritten by the copy above, so this edits the installed copy
    # and not the live session's. mkpasswd is busybox's, and it does sha-512.
    if [ "$DRY_RUN" = "1" ]; then
        printf '    [dry-run] set the `user` password\n'
    else
        HASH=$(printf '%s' "$USER_PASSWORD" | mkpasswd -m sha-512) \
            || die "mkpasswd failed - password not set"
        sed -i "s|^user:[^:]*:|user:$HASH:|" "$MNT/etc/shadow"
        say "  user password set (sha-512)"
    fi
fi

# ---------------------------------------------------------------------------
# 6. grub.cfg
#
# root=PARTUUID=, not root=LABEL=. PARTUUID is resolved by the kernel itself;
# a label needs userspace blkid to look up, and there is no userspace yet at
# this point in a boot. Two console= entries so messages land on both the
# serial port and the screen.
# ---------------------------------------------------------------------------
# console=tty0 FIRST and console=ttyS0,115200 LAST, which is the reverse of
# what this used to say and of what mkiso.sh says for the live ISO.
#
# The order is not cosmetic. /dev/console resolves to the LAST registered
# console, and that is where init writes everything: warn() and friends go to
# fd 2. With tty0 last, /dev/console is tty0 - and under a headless QEMU
# (-vga none) that is a dead display, so init appears completely silent while
# the kernel keeps logging happily to every console. The symptom is a booted
# system with no sign of life past dbus-daemon.
#
# Kernel messages are unaffected either way, because the kernel emits to all
# registered consoles rather than to the preferred one. Only init's own output
# moves, which is exactly why this looks like a hang rather than a config bug.
#
# The live ISO keeps its own order in mkiso.sh because there the VGA console is
# real, and on a machine with a screen tty0 is the one people want.
if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] write %s/boot/grub/grub.cfg with root=PARTUUID=%s\n' \
        "$MNT" "$ROOT_PARTUUID"
else
    cat > "$MNT/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial gfxterm

menuentry "rlOS" {
    linux /boot/bzImage root=PARTUUID=$ROOT_PARTUUID rootfstype=$FS_TYPE rw rootwait console=tty0 console=ttyS0,115200 loglevel=3 $CMDLINE_EXTRA
}
EOF
    say "  grub.cfg: root=PARTUUID=$ROOT_PARTUUID"
fi

# ---------------------------------------------------------------------------
# 7. Bootloaders
# ---------------------------------------------------------------------------
if [ "$BOOT_MODE" != "efi" ]; then
    step "Installing the BIOS bootloader"
    # grub-install, and this is not a stylistic preference.
    #
    # boot.img is NOT a generic 512-byte MBR stub. It carries a blocklist naming
    # the sectors where core.img lives, and that list is EMPTY in the file GRUB
    # ships - grub-bios-setup writes it at install time, once it knows where
    # core.img actually landed. So "dd boot.img to sector 0, then dd core.img
    # into bios_grub" installs both halves correctly and produces a disk that
    # prints a bare "GRUB" and hangs forever: stage 1 loads, finds an empty
    # blocklist, and has nowhere to jump. That is not a near miss, it is a disk
    # with no bootloader on it at all.
    #
    # biosdisk is in the module list because it is the INT 13h driver - the only
    # thing there that can read a disk. Without it core.img cannot see the
    # medium it is installed on, and you get the same bare "GRUB".
    command -v grub-install > /dev/null 2>&1 \
        || die "grub-install not found - this image was built without it (mkiso.sh -i)"
    # --modules is deliberately the same minimal list rlos-disk/install.sh uses.
    #
    # It first looked reasonable to be generous - "biosdisk ahci ata part_gpt
    # part_msdos ext2 fat normal linux" - and that produced a core.img which
    # booted, found itself, and then could not enumerate a single partition on a
    # perfectly valid GPT: (hd0) existed, (hd0,gpt1) did not. grub-install
    # appends 'ext2 part_gpt biosdisk' to whatever is passed here, so this list
    # is already equivalent to omitting the flag. The extras were the whole
    # problem: ahci and ata register their own disk backends, and loading them
    # alongside biosdisk leaves the disk present with an empty partition map.
    #
    # Verified by reading the real invocation back off a booted guest:
    #   grub-mkimage ... 'part_gpt' 'ext2' 'ext2' 'part_gpt' 'biosdisk'
    run grub-install --target=i386-pc \
        --modules="part_gpt ext2" \
        --boot-directory="$MNT/boot" \
        "$DEVICE"
else
    say ""
    say "  BIOS boot skipped (--boot efi)"
fi

if [ -n "$P_ESP" ] && [ "$BOOT_MODE" != "bios" ]; then
    step "Installing the UEFI bootloader"
    run mkdir -p "$MNT/boot/efi"
    run mount "$P_ESP" "$MNT/boot/efi"
    run mkdir -p "$MNT/boot/efi/EFI/BOOT"
    # BOOTX64.EFI rather than an NVRAM entry: no efibootmgr on a machine that
    # has never had one run, which is most of them.
    run cp "$GRUB_DIR/grubx64.efi" "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    if [ -f "$GRUB_DIR/grubia32.efi" ]; then
        run cp "$GRUB_DIR/grubia32.efi" "$MNT/boot/efi/EFI/BOOT/BOOTIA32.EFI"
    fi
    run umount "$MNT/boot/efi"
else
    say ""
    say "  UEFI boot skipped"
fi

# ---------------------------------------------------------------------------
# 8. Your hook, inside the installed system
# ---------------------------------------------------------------------------
if [ -n "$HOOK" ]; then
    step "Running your hook inside the installed system"
    [ -f "$HOOK" ] || die "hook $HOOK does not exist"
    if [ "$DRY_RUN" = "1" ]; then
        printf '    [dry-run] chroot %s /bin/sh %s\n' "$MNT" "$HOOK"
    else
        cp "$HOOK" "$MNT/tmp/rlos-install-hook.sh"
        chmod +x "$MNT/tmp/rlos-install-hook.sh"
        chroot "$MNT" /bin/sh /tmp/rlos-install-hook.sh \
            || die "your hook failed - the disk is left mounted at $MNT, nothing was unmounted"
        rm -f "$MNT/tmp/rlos-install-hook.sh"
    fi
fi

# ---------------------------------------------------------------------------
# 9. Done
# ---------------------------------------------------------------------------
step "Unmounting"
run umount "$MNT"

# The unmount is where a broken filesystem finally admits it, and everything
# before this point can succeed on one that will never boot: blkid only reads
# the superblock, which is written early and stays intact, while the damage
# sits in the extents and the journal. Worse, the kernel reports the failure
# asynchronously and umount still exits 0 - so without this check the script
# cheerfully prints "Done" over a disk that cannot be mounted. An installer
# that reports success over a corrupt filesystem is worse than one that fails.
if [ "$DRY_RUN" != "1" ] && command -v e2fsck > /dev/null 2>&1; then
    step "Checking the installed filesystem"
    if E2F_OUT=$(e2fsck -f -n "$P_ROOT" 2>&1); then
        say "  $P_ROOT is clean"
    else
        warn "$P_ROOT did not survive the install:"
        printf '%s\n' "$E2F_OUT" | sed 's/^/    /' >&2
        die "the installed filesystem is corrupt - do not trust this install"
    fi
fi

rmdir "$MNT" 2>/dev/null || true

say ""
printf '%sDone.%s %s now boots rlOS.\n' "$GRN" "$RST" "$DEVICE"
say "  root=PARTUUID=$ROOT_PARTUUID"
say "  root filesystem: $FS_TYPE, label $FS_LABEL"
if [ "$BOOT_MODE" != "efi" ]; then say "  BIOS bootloader: installed"; else say "  ${DIM}BIOS bootloader: skipped${RST}"; fi
if [ -n "$P_ESP" ] && [ "$BOOT_MODE" != "bios" ]; then say "  UEFI bootloader: installed"; else say "  ${DIM}UEFI bootloader: skipped${RST}"; fi
say ""
say "Pull the stick out and reboot."
