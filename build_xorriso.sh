#!/usr/bin/env bash
# build_xorriso.sh - build GNU xorriso (host tool) into host-tools/
#
# Gentoo does not package xorriso (no app-cdr/xorriso ebuild, verified
# against upstream master 2026-09), but grub-mkrescue needs it as a
# backend for rlos-iso/mkiso.sh. So we vendor it like gcc and git:
# pinned tarball, local prefix, no root, no host pollution.
#
# Output is a host tool tree in host-tools/:
#   bin/xorriso               the ISO creator grub-mkrescue calls
#   bin/osirrox, bin/xorrecord, ...  sibling tools from the same tree
#   share/man, share/info, ...       docs (harmless)
# mkiso.sh auto-prepends host-tools/bin to PATH when present.
#
# Pinned to the tested upstream tarball below for reproducibility.
#
# Usage:
#   ./build_xorriso.sh                    # build (default)
#   ./build_xorriso.sh -j 8               # 8 parallel jobs
#   ./build_xorriso.sh --clean            # remove host-tools/ before building
#
# Needs on the host: gcc, make, curl or wget, zlib headers, readline
# headers (both ship with a normal Gentoo desktop/main install).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pinned upstream release (ftp.gnu.org/gnu/xorriso/).
XORRISO_VER="1.5.8"
XORRISO_URL="https://ftp.gnu.org/gnu/xorriso/xorriso-${XORRISO_VER}.tar.gz"
XORRISO_SRC="$SCRIPT_DIR/xorriso-src"
XORRISO_DIST="$SCRIPT_DIR/host-tools"
CLEAN=0
JOBS=""

# --- Colors ---
if [ -t 1 ] && [ -t 2 ]; then
  C_RESET=$'\e[0m'
  C_BOLD=$'\e[1m'
  C_DIM=$'\e[2m'
  C_CYAN=$'\e[36m'
  C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'
  C_RED=$'\e[31m'
  C_MAGENTA=$'\e[35m'
  C_BLUE=$'\e[34m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_MAGENTA="" C_BLUE=""
fi

info()  { printf "${C_DIM}  ::${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}  [ OK ]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}  [FAIL]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}  [WARN]${C_RESET} %s\n" "$*"; }
header(){ printf "\n${C_BOLD}${C_CYAN}:: %s${C_RESET}\n" "*"; }

usage() {
  printf "\n"
  printf "${C_BOLD}Usage:${C_RESET} ${C_CYAN}build_xorriso.sh${C_RESET} [OPTIONS]\n"
  printf "\n"
  printf "Build GNU xorriso (%s) into host tool tree ${C_BOLD}host-tools/${C_RESET}.\n" "$XORRISO_VER"
  printf "\n"
  printf "${C_BOLD}Options:${C_RESET}\n"
  printf "  ${C_YELLOW}-j, --jobs${C_RESET} ${C_CYAN}N${C_RESET}       Number of parallel jobs\n"
  printf "  ${C_RED}--clean${C_RESET}            Remove host-tools/ before building\n"
  printf "  ${C_BLUE}-h, --help${C_RESET}         Show this help\n"
  printf "\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs)  JOBS="$2"; shift 2 ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          fail "unknown option: $1"; exit 1 ;;
  esac
done

JOBS_FLAG=""
if [ -n "$JOBS" ]; then
  JOBS_FLAG="-j $JOBS"
fi

for tool in gcc make; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    fail "$tool not found on PATH (host build tool)"
    exit 1
  fi
done
FETCHER=""
if command -v curl > /dev/null 2>&1; then
  FETCHER="curl -fSL -o"
elif command -v wget > /dev/null 2>&1; then
  FETCHER="wget -O"
else
  fail "neither curl nor wget found on PATH (need one to fetch the tarball)"
  exit 1
fi

if [ "$CLEAN" = "1" ]; then
  header "Cleaning"
  info "removing host-tools/ and xorriso-src/"
  rm -rf "$XORRISO_DIST" "$XORRISO_SRC"
  ok "cleaned"
fi

header "Build config"
info "pin:    ${C_BOLD}${XORRISO_VER}${C_RESET}"
info "url:    ${C_BOLD}${XORRISO_URL}${C_RESET}"
info "output: ${C_BOLD}host-tools/${C_RESET} (host tool tree)"
info "jobs:   ${C_BOLD}${JOBS:-auto}${C_RESET}"

header "Fetching source"
mkdir -p "$XORRISO_SRC"
TARBALL="$XORRISO_SRC/xorriso-${XORRISO_VER}.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  info "downloading..."
  # shellcheck disable=SC2086
  if ! $FETCHER "$TARBALL" "$XORRISO_URL"; then
    fail "download failed - check network and the pinned version"
    exit 1
  fi
  ok "downloaded ($(du -h "$TARBALL" | cut -f1))"
else
  ok "tarball already present, skipping download"
fi

header "Building xorriso (prefix = host-tools, host untouched)"
rm -rf "$XORRISO_SRC/build"
mkdir -p "$XORRISO_SRC/build"
tar -xzf "$TARBALL" -C "$XORRISO_SRC/build" --strip-components=1
( cd "$XORRISO_SRC/build" && \
  ./configure --prefix="$XORRISO_DIST" > /dev/null && \
  make $JOBS_FLAG > /dev/null && \
  make install > /dev/null )
ok "xorriso built and installed"

header "Results"
ok "host-tools ready ($(du -sh "$XORRISO_DIST" | cut -f1))"
info "self-check:"
"$XORRISO_DIST/bin/xorriso" -version 2>&1 | head -3 | sed 's/^/         /'
