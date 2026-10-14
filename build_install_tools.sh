#!/usr/bin/env bash
# build_install_tools.sh - stage the tools rlos-install.sh needs, into
# installer-dist/.
#
# WHAT IS HERE AND WHY
#
#   sfdisk       writes the GPT or MBR partition table
#   mke2fs       makes the root filesystem (ext2 or journalled ext4)
#   tune2fs      adjusts filesystem parameters after the fact
#   resize2fs    grows or shrinks the root filesystem without a reboot
#   e2fsck       checks and repairs it
#
# The partitioner is the only one that is not optional: busybox's fdisk has GPT
# support but is driven interactively, and the guest has no mkfs.ext4, no
# resize2fs and no fsck for ext4 at all. Without these, an in-guest install
# could create a table but not a usable filesystem on it.
#
# WHY THE HOST COPY AND NOT A SOURCE BUILD
#
# Every binary here is a single file from a host package, not a library stack
# that has to be compiled against pinned headers. util-linux and e2fsprogs are
# both large autotools projects; building either for four executables would mean
# fetching tens of megabytes of tarball and a full build each, to produce
# something the host already has installed. This is the same approach
# build_fastfetch.sh takes for fastfetch.
#
# The versions are reported rather than pinned: a host package is not a fetched
# artefact, so pins.lock has nothing to check it against. They are printed in the
# build output so a difference from another machine is visible rather than silent.
#
# The price is that the host's build options are inherited, which is why libread-
# line and libtinfow come along with sfdisk. A --disable-readline build of
# util-linux would not have them; that is a few hundred KB of image size in
# exchange for not compiling a project this image otherwise never touches.
#
# Usage:
#   ./build_install_tools.sh            # build (default)
#   ./build_install_tools.sh --clean    # remove installer-dist/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
DIST="$SCRIPT_DIR/installer-dist"

# name -> purpose, printed so the output says what each tool is for
TOOLS="sfdisk:write a GPT or MBR partition table
mke2fs:make the root filesystem
tune2fs:adjust filesystem parameters
resize2fs:grow or shrink a filesystem
e2fsck:check and repair a filesystem
grub-install:write a BIOS bootloader that can actually find the kernel"

# grub-install ships because the BIOS bootloader cannot be produced by copying
# files onto a disk. boot.img is not a generic MBR stub: it carries a blocklist
# saying where core.img lives, and that list is empty until grub-bios-setup
# patches it. A hand-rolled "dd boot.img, then dd core.img into bios_grub"
# installs both halves correctly and produces a disk that prints GRUB and hangs,
# because stage 1 has nothing to jump to. grub-install does the patching, and is
# the same mechanism rlos-disk/install.sh already proves works in QEMU.
GRUB_PLATFORM_DIR=""
for cand in /usr/lib/grub/i386-pc /usr/share/grub/i386-pc; do
    if [ -d "$cand" ]; then GRUB_PLATFORM_DIR="$cand"; break; fi
done

# What grub-install needs, versus what it merely benefits from. The first four
# are required - grub-install builds core.img with grub-mkimage, locates the
# embed partition with grub-probe, and patches the MBR blocklist with
# grub-bios-setup, so without any of them the BIOS bootloader cannot be made.
# The rest are staged when the host has them. grub-mkdevicemap is deliberately
# absent: it was removed in GRUB 2.x and is not needed.
GRUB_REQUIRED="grub-install grub-mkimage grub-bios-setup grub-probe"
GRUB_OPTIONAL="grub-editenv grub-mkstandalone"

GRUB_TOOLS="$GRUB_REQUIRED"
for t in $GRUB_OPTIONAL; do
    command -v "$t" > /dev/null 2>&1 && GRUB_TOOLS="$GRUB_TOOLS $t"
done

if [ "${1:-}" = "--clean" ]; then
    echo "removing installer-dist/"
    rm -rf "$DIST"
    echo "cleaned"
    exit 0
fi

ok()   { printf "  [ OK ] %s\n" "$*"; }
fail() { printf "  [FAIL] %s\n" "$*" >&2; exit 1; }
info() { printf "  :: %s\n" "$*"; }
header() { printf "\n:: %s\n" "$*"; }

source "$SCRIPT_DIR/build-lib.sh"

header "Host prerequisites"
MISSING=""
for t in sfdisk mke2fs tune2fs resize2fs e2fsck $GRUB_TOOLS; do
    command -v "$t" > /dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
    fail "missing host tools:$MISSING"
    fail "on Gentoo: emerge sys-apps/util-linux sys-fs/e2fsprogs sys-boot/grub"
    exit 1
fi
ok "sfdisk mke2fs tune2fs resize2fs e2fsck grub-install present"
info "sfdisk     $(sfdisk --version 2>&1 | head -1)"
info "e2fsprogs  $(mke2fs -V 2>&1 | head -1)"
info "grub       $(grub-install --version 2>&1 | head -1)"

header "Assembling guest tree"
rm -rf "$DIST"
mkdir -p "$DIST/usr/bin" "$DIST/usr/lib64"

# Resolve each binary before copying: /usr/bin/<tool> may be a symlink, and cp
# would then copy the link, which dangles in a guest with no /usr/bin.
for t in sfdisk mke2fs tune2fs resize2fs e2fsck $GRUB_TOOLS; do
    src="$(command -v "$t")"
    install -m 0755 "$(readlink -f "$src")" "$DIST/usr/bin/$t"
    strip "$DIST/usr/bin/$t" 2> /dev/null || true
    printf "         %-12s %6s\n" "$t" "$(du -h "$DIST/usr/bin/$t" | cut -f1)"
done
ok "$(echo "$TOOLS" | wc -l) tools staged in usr/bin/"

# One closure over ALL of them rather than one per tool, because they share most
# of their libraries: every one of the e2fsprogs links libext2fs, and the whole
# set shares libblkid and libuuid with sfdisk. Per-tool closures would copy those
# repeatedly, and `cp -n` would then leave whichever tool happened to be staged
# first as the winner.
#
# libc is skipped: assemble-rootfs.sh's own closure pass stages it for the whole
# image, so a second copy here would only waste space.
SKIP="libc.so.6 libm.so.6 ld-linux-x86-64.so.2 linux-vdso.so.1"
DEPS=""
for elf in "$DIST/usr/bin/"*; do
    [ -x "$elf" ] || continue
    DEPS="$DEPS $(ldd "$elf" 2>/dev/null | awk '{print $3}' | grep '^/' || true)"
done
DEPS="$(printf '%s\n' $DEPS | sort -u | grep '[^[:space:]]' || true)"
[ -n "$DEPS" ] || fail "no dynamic dependencies found - nothing to stage"

for lib in $DEPS; do
    base="$(basename "$lib")"
    case " $SKIP " in
        *" $base "*) continue ;;
    esac
    # Every library here is a SONAME SYMLINK to a versioned file - libfdisk.so.1
    # -> libfdisk.so.1.1.0, libext2fs.so.2 -> libext2fs.so.2.0.0, and so on.
    # Copying the symlink would dangle in the guest, and copying only the target
    # would leave the tool asking for a name that is not there. Both are needed,
    # and both are real files rather than links, because a symlink into a cpio
    # needs its target present.
    real="$(readlink -f "$lib" 2>/dev/null || echo "$lib")"
    [ -f "$real" ] || fail "dependency $lib listed by ldd but not found on disk"
    cp -f "$real" "$DIST/usr/lib64/$base"
    if [ "$(basename "$real")" != "$base" ]; then
        cp -f "$real" "$DIST/usr/lib64/$(basename "$real")"
    fi
done
N_LIBS="$(find "$DIST/usr/lib64" -name '*.so*' | wc -l)"
ok "$N_LIBS library files in usr/lib64/ ($(du -sh "$DIST/usr/lib64" | cut -f1))"

# The GRUB platform tree. Staged whole and at the path grub-install expects on
# this distro, so that `--target=i386-pc` resolves it in the guest with no
# argument pointing at it.
header "GRUB platform directory"
GRUB_DEST="$DIST/usr/lib/grub/i386-pc"
mkdir -p "$DIST/usr/lib/grub"
cp -a "$GRUB_PLATFORM_DIR" "$GRUB_DEST"
ok "i386-pc staged at usr/lib/grub/i386-pc/ ($(du -sh "$GRUB_DEST" | cut -f1))"
for req in boot.img kernel.img biosdisk.mod part_gpt.mod ext2.mod; do
    [ -e "$GRUB_DEST/$req" ] || fail "$req missing from $GRUB_PLATFORM_DIR - grub-install would build a core.img that cannot boot"
done
ok "boot.img kernel.img biosdisk.mod part_gpt.mod ext2.mod all present"

header "Verify: every DT_NEEDED resolves inside usr/lib64"
# ldd on the host resolves everything from the host, so a closure that silently
# dropped a soname would still run here and fail only inside the guest. That is
# the exact bug class this check exists for: xkbcomp once shipped without
# libxkbfile.so.1 and took the whole X session down with it.
MISSING=""
for elf in "$DIST/usr/bin/"* "$DIST"/usr/lib64/*.so*; do
    [ -f "$elf" ] || continue
    for need in $(objdump -p "$elf" 2>/dev/null | sed -n 's/^ *NEEDED *//p'); do
        case "$need" in
            linux-vdso*|linux-gate*|ld-linux*|libc.so.6|libm.so.6) continue ;;
        esac
        [ -e "$DIST/usr/lib64/$need" ] || MISSING="$MISSING $need"
    done
done
MISSING="$(printf '%s\n' $MISSING | sort -u | grep '[^[:space:]]' | tr '\n' ' ' || true)"
if [ -n "$MISSING" ]; then
    errmsg "needed but not staged:"
    printf '    %s\n' "$MISSING"
    errmsg "the guest has no ld.so.cache, so they will not be found at runtime"
    exit 1
fi
ok "every DT_NEEDED of every staged ELF resolves inside usr/lib64/"

header "Self-check: do they run from the staged tree?"
CHK="$(mktemp -d)"
trap 'rm -rf "$CHK"' EXIT
mkdir -p "$CHK/lib" "$CHK/bin"
cp "$DIST"/usr/bin/* "$CHK/bin/"
cp "$DIST"/usr/lib64/*.so* "$CHK/lib/" 2>/dev/null || true
# libc is not staged here, so borrow the host's for the test.
for t in sfdisk mke2fs tune2fs resize2fs e2fsck; do
    libc="$(ldd "$(command -v "$t")" | awk '/libc\.so/{print $3; exit}')"
    [ -f "$libc" ] && cp -f "$libc" "$CHK/lib/" 2>/dev/null
done
run_ok=0
for t in sfdisk mke2fs tune2fs resize2fs e2fsck; do
    # Run each with NO arguments and read the failure mode rather than picking a
    # flag per tool. These five have no common version option - tune2fs and
    # resize2fs have none at all, and both exit nonzero on no arguments by
    # printing their usage - so a "does --version work" probe would test the
    # command line, not the thing that can actually break.
    #
    # What matters is only whether the LOADER succeeded. A tool that complains
    # about its arguments still proves every DT_NEEDED resolved; a tool that says
    # "error while loading shared libraries" proves one did not, and that is the
    # failure this is here to catch.
    err="$(LD_LIBRARY_PATH="$CHK/lib" "$CHK/bin/$t" 2>&1 || true)"
    case "$err" in
        *"error while loading shared libraries"*)
            warn "$t cannot load its libraries from the staged tree:"
            printf '%s\n' "$err" | sed 's/^/         /' | head -3
            ;;
        *)
            ok "$t loads and runs"
            run_ok=$((run_ok + 1))
            ;;
    esac
done
[ "$run_ok" -eq 5 ] || fail "$run_ok of 5 tools run from the staged tree"

# mke2fs is the one whose behaviour the installer depends on, and getting ext4
# silently wrong is not something rlos-install can detect later - the filesystem
# would be perfectly valid, just ext2, and the user would only find out when
# journaling turned out not to be there. So it is checked here, where the answer
# costs one small file.
#
# Read as SINGLE BYTES deliberately. `od -tx4` prints a word in the host's byte
# order, so on little-endian it hands back 000022c2 for a value of 0xc2220000,
# and bash then reads that as octal and dies on the 'c'. One byte at a time has
# neither problem.
#
# Offsets are from the ext2 superblock, which lives 1024 bytes into the volume.
# s_magic is 0xEF53 at +0x38 (low byte 0x53, high 0xEF). s_feature_compat is at
# +0x5C, and its 0x04 bit is EXT2_FEATURE_COMPAT_HAS_JOURNAL. Those positions
# were confirmed against a filesystem made by the host's own mkfs.ext4 rather
# than taken from memory: a real ext4 reports compat=0x103c (bit set) and
# ro_compat=0x46b, where 0x40 is EXT2_FEATURE_RO_COMPAT_FILESYSTEM_EXT.
sb_byte() { od -An -tx1 -N1 -j$((1024 + $2)) "$1" 2>/dev/null | tr -d ' \n'; }

FS="$(mktemp)"
head -c 48M /dev/zero > "$FS"
if ! LD_LIBRARY_PATH="$CHK/lib" "$CHK/bin/mke2fs" -q -t ext4 "$FS" > /dev/null 2>&1; then
    rm -f "$FS"
    fail "mke2fs -t ext4 failed on a plain file - journalled ext4 is not usable in-guest"
fi
if [ "$(sb_byte "$FS" 0x38)$(sb_byte "$FS" 0x39)" != "53ef" ]; then
    rm -f "$FS"
    fail "mke2fs produced something without an ext superblock (magic != 0xEF53)"
fi
COMPAT="$(sb_byte "$FS" 0x5C)"
if [ $(( 0x$COMPAT & 0x04 )) -ne 0 ]; then
    ok "mke2fs makes a journalled ext4 (s_feature_compat=0x$COMPAT, HAS_JOURNAL set)"
else
    rm -f "$FS"
    fail "mke2fs -t ext4 produced a filesystem with NO journal (compat=0x$COMPAT)"
    fail "rlos-install --fs ext4 would be a lie"
fi
rm -f "$FS"

header "Results"
ok "installer-dist ready ($(du -sh "$DIST" | cut -f1))"
find "$DIST" -type f | sort | sed 's/^/         /'
echo
info "next: assemble-rootfs.sh stages installer-dist/ when -i is given."