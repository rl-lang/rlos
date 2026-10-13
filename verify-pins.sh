#!/usr/bin/env bash
# verify-pins.sh - check the build cache against pins.lock
#
# Every upstream the image is built from is pinned. This re-checks what is
# actually on disk right now, so drift is visible without running a build:
#
#   - a tarball whose sha256 no longer matches (truncated, edited, or the URL
#     now serves different bytes)
#   - a git checkout sitting on a commit other than the pin
#   - a pin recorded in pins.lock with no cached artefact to check
#
# Read-only. It never fetches, never builds, and never modifies the cache.
# Missing artefacts are reported as "not cached", not as failures - a fresh
# clone has almost nothing cached and that is not an error.
#
# Usage:
#   ./verify-pins.sh            check everything
#   ./verify-pins.sh --strict   also fail on anything not cached

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# For the colour variables and the section headings only. The per-item rows
# below are an aligned table (%-24s columns), not prose, so they keep their own
# printf rather than going through info/ok - running them through a prefixed
# helper would destroy the column alignment.
# shellcheck source=build-lib.sh
source "$SCRIPT_DIR/build-lib.sh"
# shellcheck source=pins.sh
source "$SCRIPT_DIR/pins.sh"

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

for tool in sha256sum shasum; do
    command -v "$tool" > /dev/null 2>&1 && { SHA=$tool; break; }
done
if [[ -z "${SHA:-}" ]]; then
    echo "error: need sha256sum or shasum to verify pins" >&2
    exit 1
fi

OK=0; MISMATCH=0; NOTCACHED=0; DRIFT=0
declare -a PROBLEMS=()

header "pins.lock"
printf "  ${DIM}%s${RST}\n" "$PINS_LOCK"

# ---------------------------------------------------------------------------
# tarballs
# ---------------------------------------------------------------------------
# The cache location per pin. These are the paths the build scripts actually
# download to, so "verified here" means the same thing as "verified in a build".
sha_of() {
    case "$1" in
        xorg-server)             echo "x11-src/xorg-server-21.1.24.tar.xz" ;;
        xf86-video-fbdev)        echo "x11-src/xf86-video-fbdev-0.5.1.tar.xz" ;;
        xf86-input-libinput)    echo "x11-src/xf86-input-libinput-1.5.0.tar.xz" ;;
        xkeyboard-config)        echo "x11-src/xkeyboard-config-2.48.tar.xz" ;;
        libinput)                echo "x11-src/libinput-1.31.3.tar.gz" ;;
        eudev)                   echo "x11-src/eudev-3.2.15.tar.gz" ;;
        mlterm)                  echo "x11-src/mlterm-3.9.1.tar.gz" ;;
        giflib)                  echo "xapps-src/giflib-5.2.2.tar.gz" ;;
        libXpm)                  echo "xapps-src/libXpm-3.5.19.tar.gz" ;;
        feh)                     echo "xapps-src/feh.tar.gz" ;;
        ttyrec)                  echo "base-src/ttyrec-1.1.7.1.tar.gz" ;;
        Bibata-Modern-Ice)       echo "x11-src/Bibata-Modern-Ice.tar.xz" ;;
        sudo)                    echo "base-src/sudo-1.9.17p2.tar.gz" ;;
        ffmpeg)                  echo "x11-src/ffmpeg-9.0.2.tar.xz" ;;
        busybox)                 echo "busybox-src/busybox-1.37.0.tar.bz2" ;;
        bluez)                   echo "bluesz-src/bluez-5.87.tar.gz" ;;
        iwd)                     echo "iwd-src/iwd.tar.xz" ;;
        libnl)                   echo "iwd-src/libnl.tar.gz" ;;
        w3m)                     echo "w3m-src/w3m-0.5.3-git20230121.tar.gz" ;;
        bdwgc)                   echo "gc-src/bdwgc-8.2.12.tar.gz" ;;
        xorriso)                 echo "xorriso-src/xorriso-1.5.8.tar.gz" ;;
        *)                       return 1 ;;
    esac
}

header "tarballs"
for key in $(cut -d= -f1 "$PINS_LOCK" | sed -n 's/^\([A-Za-z0-9._-]*\)\.url$/\1/p' | sort); do
    want="$(pins_get "${key}.sha256")"
    rel="$(sha_of "$key")" || { printf "  ${YLW}?${RST}    %-24s no known cache path\n" "$key"; continue; }
    file="$SCRIPT_DIR/$rel"
    if [[ ! -f "$file" ]]; then
        printf "  ${DIM}--${RST}    %-24s not cached\n" "$key"
        NOTCACHED=$((NOTCACHED + 1))
        [[ "$STRICT" -eq 1 ]] && PROBLEMS+=("not cached: $key ($rel)")
        continue
    fi
    got="$("$SHA" "$file" | cut -d' ' -f1)"
    if [[ "$got" == "$want" ]]; then
        printf "  ${GRN}ok${RST}    %-24s %s\n" "$key" "${want:0:12}"
        OK=$((OK + 1))
    else
        printf "  ${RED}BAD${RST}   %-24s expected %s got %s\n" "$key" "${want:0:12}" "${got:0:12}"
        MISMATCH=$((MISMATCH + 1))
        PROBLEMS+=("sha256 mismatch: $key ($rel)
  expected $want
  actual   $got
  delete the file and re-run the build to refetch it")
    fi
done

# ---------------------------------------------------------------------------
# git checkouts
# ---------------------------------------------------------------------------
# The cache location per pin. linux/ is deliberately absent: it is unpinned by
# design, because it is patched and rebased locally.
git_dir_of() {
    case "$1" in
        linux-firmware)     echo "fw-src/linux-firmware" ;;
        rl-lang)            echo "rl-lang" ;;
        gcc)                echo "gcc" ;;
        binutils)           echo "binutils" ;;
        git)                echo "git-src" ;;
        xfiles)             echo "xapps-src/xfiles" ;;
        xauth)              echo "x11-src/xauth" ;;
        xcb-util-xrm)       echo "x11-src/xcb-util-xrm" ;;
        libstartup-notification) echo "x11-src/libstartup-notification" ;;
        imlib2)             echo "xapps-src/imlib2" ;;
        linux)              return 1 ;;   # unpinned
        *)                  return 1 ;;
    esac
}

header "git checkouts"
for key in $(cut -d= -f1 "$PINS_LOCK" | sed -n 's/^\([A-Za-z0-9._-]*\)\.repo$/\1/p' | sort); do
    want="$(pins_get "${key}.sha")"
    rel="$(git_dir_of "$key")" || continue
    dir="$SCRIPT_DIR/$rel"

    if [[ -z "$want" ]]; then
        printf "  ${DIM}--${RST}    %-24s unpinned by design\n" "$key"
        continue
    fi
    if [[ ! -e "$dir/.git" ]]; then
        printf "  ${DIM}--${RST}    %-24s not present\n" "$key"
        NOTCACHED=$((NOTCACHED + 1))
        [[ "$STRICT" -eq 1 ]] && PROBLEMS+=("not present: $key ($rel)")
        continue
    fi
    got="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    if [[ "$got" == "$want" ]]; then
        printf "  ${GRN}ok${RST}    %-24s %s\n" "$key" "${want:0:12}"
        OK=$((OK + 1))
    else
        printf "  ${RED}DRIFT${RST} %-24s at %s, pinned %s\n" "$key" "${got:0:12}" "${want:0:12}"
        DRIFT=$((DRIFT + 1))
        PROBLEMS+=("commit drift: $key ($rel)
  on disk  ${got:-<unknown>}
  pinned   $want
  the build will use the on-disk tree")
    fi
done

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
header "summary"
printf "  %s%d ok%s" "$GRN" "$OK" "$RST"
[[ "$NOTCACHED" -gt 0 ]] && printf ", %s%d not cached%s" "$DIM" "$NOTCACHED" "$RST"
[[ "$DRIFT" -gt 0 ]] && printf ", %s%d drifted%s" "$RED" "$DRIFT" "$RST"
[[ "$MISMATCH" -gt 0 ]] && printf ", %s%d sha256 mismatch%s" "$RED" "$MISMATCH" "$RST"
printf "\n"

if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    printf "\n${RED}problems:${RST}\n"
    for p in "${PROBLEMS[@]}"; do
        printf "  - %s\n" "$p"
    done
    exit 1
fi

printf "\n%severy cached artefact matches pins.lock%s\n" "$GRN" "$RST"
exit 0
