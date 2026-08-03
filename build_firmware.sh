#!/usr/bin/env bash
# build_firmware.sh - stage the kernel firmware needed for wireless + bluetooth.
#
# WHY A SPARSE CHECKOUT AND NOT A RELEASE TARBALL.
#
# linux-firmware's release tarballs are ~500MB and this image needs a few
# megabytes out of them. Downloading 500MB to extract 3MB on every clean build is
# slow and pointless, so this does a blobless shallow clone and then restricts the
# working tree to the four directories actually staged. The .git objects for
# everything else are never fetched.
#
# WHICH DIRECTORIES, AND WHY THESE FOUR.
#
#   ath9k/    the driver for the QCA6174 when it is the AR9565/AR9287 variant
#             (PCI ID 168c:002b). Tiny - a handful of .fw files, all small.
#   ath6k/    the older Atheros parts. Small.
#   qca/      the Qualcomm Atheros blobs that ath6kl (and some ath10k boards)
#             load directly. This is the big one - tens of megabytes - and it is
#             staged because it is the only way a QCA board works without
#             ath10k's own blob set.
#   ath10k/   the QCA6174 when it is the AR10xx variant (PCI ID 168c:0042). One
#             board's blob is ~600KB.
#
# "QCA6174" is one marketing name across two silicon families with completely
# different firmware requirements, and nothing at build time can tell which one a
# given machine has. Both driver sets are staged and the kernel carries both
# drivers; whichever binds wins. The cost of being wrong is a machine with a
# Wi-Fi driver and no firmware, which loads the module, fails to find its blob,
# and leaves wlan0 permanently absent with the reason buried in dmesg.
#
# DELIBERATELY NOT STAGED: ath11k/ath12k. Those are large, they need a different
# driver pair that this kernel does not enable, and no supported machine here uses
# them.
#
# BLUETOOTH NEEDS NO FIRMWARE. Worth stating because it is a common assumption:
# a USB Bluetooth dongle is a plain USB device with a 0000:0000 vendor ID and
# loads its firmware over USB from the controller's own on-board memory. The
# CONFIG_BT_FIRMWARE option exists for the handful of controllers that ship with
# a separate blob and they are SDIO/PCI, not the USB dongle in question.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/fw-src/linux-firmware"
DIST="$ROOT/fw-dist"
FWURL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"

# Directory-shaped blobs, staged as-is.
DIRS=(ath6k ath10k ath9k_htc qca)

# ath9k's OWN firmware is not under ath9k/ - in current linux-firmware the ar*.fw
# blobs sit at the REPOSITORY ROOT and the loader looks for them at the root of
# /lib/firmware. Checked against the tree rather than assumed, because
# sparse-checkout "/ath9k" matches a directory that does not exist and produces a
# clean, silent, empty result - which is exactly what the first run of this script
# did.
#
# Note what is NOT here any more: ar9485*.fw and ar9565*.fw have been removed
# upstream, leaving ar9271.fw as the ath9k blob still published. If a machine's
# AR9565 turns out to want a blob that no longer exists in linux-firmware, that is
# a missing-blob problem at the driver level and not something this script can
# invent - it is called out in the verification output rather than hidden.
ROOT_FW=(ar9271.fw ar7010.fw ar7010_1_1.fw ar9170-1.fw ar9170-2.fw
         ath3k-1.fw htc_7010.fw htc_9271.fw)

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
header() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }
info()  { printf '%s  %s%s\n' "$GRN" "$1" "$RST"; }
warn()  { printf '%s  %s%s\n' "$YLW" "$1" "$RST"; }
die()   { printf '%serror:%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

command -v git >/dev/null || die "git not found"

# ---------------------------------------------------------------------------
# Blobless shallow clone, then restrict the tree
# ---------------------------------------------------------------------------
header "sparse checkout"
if [ ! -d "$SRC/.git" ]; then
    info "cloning linux-firmware (blobless, depth 1)"
    mkdir -p "$(dirname "$SRC")"
    # --filter=blob:none means git resolves the tree without fetching file
    # contents; only the paths actually checked out download their blobs.
    # --depth 1 avoids the full history, which is most of the repository's size.
    git clone --filter=blob:none --depth 1 --no-checkout "$FWURL" "$SRC" \
        || die "clone failed (network?)"
else
    info "reusing existing clone; refreshing refs"
    git -C "$SRC" fetch --depth 1 origin || warn "fetch failed, using what is present"
fi

cd "$SRC"
git sparse-checkout init --no-cone 2>/dev/null || true
# gitignore-style, --no-cone: a bare "/dir" matches the directory and everything
# under it. Explicit arguments only - the --stdin form of sparse-checkout is not
# available across git versions, and the xargs/tr pipeline that fed it silently
# produced an EMPTY pattern set, which checked out nothing and reported success.
git sparse-checkout set --no-cone $(printf '/%s ' "${DIRS[@]}") $(printf '/%s ' "${ROOT_FW[@]}") \
    || die "sparse-checkout set failed"
git read-tree -mu HEAD 2>/dev/null || git checkout -q \
    || die "could not materialise the sparse checkout"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
git checkout -q "$BRANCH" 2>/dev/null || true
info "checked out: $(git rev-parse --short HEAD 2>/dev/null || echo unknown) on $BRANCH"

for d in "${DIRS[@]}"; do
    [ -d "$d" ] || warn "$d/ not present in this revision - skipping"
done

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------
header "staging"
rm -rf "$DIST"
mkdir -p "$DIST/lib/firmware"

total=0
for d in "${DIRS[@]}"; do
    [ -d "$d" ] || continue
    mkdir -p "$DIST/lib/firmware/$d"
    # Real files only: a sparse checkout still populates directory entries, and an
    # empty subdirectory in /lib/firmware is harmless but noise.
    find "$d" -type f \( -name '*.fw' -o -name '*.bin' -o -name '*.txt' -o -name '*.cal' -o -name '*.ini' \) \
        -print0 | while IFS= read -r -d '' f; do
        rel="${f#$d/}"
        mkdir -p "$DIST/lib/firmware/$d/$(dirname "$rel")"
        cp -f "$f" "$DIST/lib/firmware/$d/$rel"
    done
    sz="$(du -sh "$DIST/lib/firmware/$d" 2>/dev/null | cut -f1)"
    n="$(find "$DIST/lib/firmware/$d" -type f 2>/dev/null | wc -l)"
    info "$d: $n files, $sz"
done

# Root-level .fw files, staged at the root of /lib/firmware because that is where
# the firmware loader looks for them. NOT under a subdirectory: ath9k requests
# "ar9271.fw" by bare name, and a file at lib/firmware/ath9k/ar9271.fw is simply
# not found - which presents as an adapter that binds and then never brings its
# interface up.
n_root=0
for f in "${ROOT_FW[@]}"; do
    if [ -f "$f" ]; then
        cp -f "$f" "$DIST/lib/firmware/$f"
        n_root=$((n_root + 1))
    fi
done
info "root-level blobs: $n_root of ${#ROOT_FW[@]} requested"
for f in "${ROOT_FW[@]}"; do
    [ -f "$f" ] || warn "  $f not published in this linux-firmware revision"
done

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
header "verification"
fail=0
FW="$DIST/lib/firmware"

# The single most useful assertion: ath9k cannot work without at least one of
# these, and its absence is the classic "wlan0 never appears" cause.
ath9k_n="$(find "$FW" -maxdepth 1 -name 'ar*.fw' 2>/dev/null | wc -l)"
if [ "$ath9k_n" -eq 0 ]; then
    warn "no ath9k .fw at the root of lib/firmware - ath9k binds but never brings an interface up"
    fail=1
else
    info "ath9k: $ath9k_n root-level .fw blobs"
fi

# ath10k board blobs.
ath10k_n="$(find "$FW/ath10k" -name '*.bin' 2>/dev/null | wc -l)"
[ "$ath10k_n" -gt 0 ] && info "ath10k: $ath10k_n board blobs" \
                       || warn "no ath10k .bin blobs staged"

total_size="$(du -sh "$DIST" | cut -f1)"
total_files="$(find "$DIST" -type f | wc -l)"
info "total: $total_files files, $total_size"

# Spot-check that the most commonly needed ath9k blobs really are present by name.
# Checking a count is necessary but not sufficient: a sparse-checkout pattern that
# matches the directory but not its contents would produce a non-zero count of the
# wrong files.
for want in ar9271.fw ar9565_2.fw; do
    if [ -f "$FW/$want" ]; then
        info "  found $want"
    else
        warn "  $want absent - upstream linux-firmware no longer publishes it"
    fi
done

[ "$fail" -eq 0 ] || warn "firmware may be incomplete - see above"
printf '\n%s  done: firmware staged in %s (%s)%s\n' "$GRN" "$DIST" "$total_size" "$RST"
