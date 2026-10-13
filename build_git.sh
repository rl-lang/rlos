#!/usr/bin/env bash
# build_git.sh - build git for the rlos guest
#
# Uses the local tree at git-src/ (symlink it: ln -s ~/dev/c/git git-src),
# builds with a guest-sane config (no Tcl/Tk, no gettext, no perl -
# https via curl kept for when guest networking arrives), and stages a
# guest-root tree in git-dist/:
#   bin/git + bin/git-*          main binary + links
#   usr/libexec/git-core/        helpers (clone/push/pull need these)
#   usr/share/git-core/templates init templates
# build_initramfs.sh copies git-dist/ into the guest and collects the
# shared libs (curl/ssl/crypto/...) via its ldd loop.
#
# Usage:
#   ./build_git.sh                    # build (default)
#   ./build_git.sh -j 8               # 8 parallel jobs
#   ./build_git.sh --clean            # remove git-dist/ before building
#                                     (never touches git-src/)
#
# Needs rlos/git-src symlinked to a git tree, e.g.:
#   ln -s ~/dev/c/git git-src
#
# Needs on the host: gcc, make (build only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_TAG="v2.55.0"
GIT_SRC="$SCRIPT_DIR/git-src"
GIT_DIST="$SCRIPT_DIR/git-dist"
CLEAN=0
JOBS=""

source "$SCRIPT_DIR/build-lib.sh"

# Sourced after the message helpers so pins_clone_hint can report through fail().
# shellcheck source=pins.sh
source "$SCRIPT_DIR/pins.sh"

usage() {
  printf "\n"
  printf "${C_BOLD}Usage:${C_RESET} ${C_CYAN}build_git.sh${C_RESET} [OPTIONS]\n"
  printf "\n"
  printf "Build git (%s) into guest-root ${C_BOLD}git-dist/${C_RESET}.\n" "$GIT_TAG"
  printf "\n"
  printf "${C_BOLD}Options:${C_RESET}\n"
  printf "  ${C_YELLOW}-j, --jobs${C_RESET} ${C_CYAN}N${C_RESET}       Number of parallel cargo jobs\n"
  printf "  ${C_RED}--clean${C_RESET}            Remove git-dist/ before building\n"
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

if [ "$CLEAN" = "1" ]; then
  header "Cleaning"
  info "removing git-dist/ (never touches git-src/)"
  rm -rf "$GIT_DIST"
  ok "cleaned"
fi

header "Build config"
info "tag:    ${C_BOLD}${GIT_TAG}${C_RESET}"
info "output: ${C_BOLD}git-dist/${C_RESET} (guest root)"
info "jobs:   ${C_BOLD}${JOBS:-auto}${C_RESET}"

header "Checking git tree"
if [[ ! -f "$GIT_SRC/Makefile" ]]; then
  # This one had no clone URL at all before, only a reference to a path on the
  # original author's machine. Generated from pins.lock now.
  pins_clone_hint git "$GIT_SRC"
  fail "build_git.sh needs a git checkout ($GIT_TAG). Symlink one at ./git-src and re-run."
  exit 1
fi
if [[ -d "$GIT_SRC/.git" ]]; then
  HAVE_TAG="$(cd "$GIT_SRC" && git describe --tags 2>/dev/null || git rev-parse --short HEAD)"
  if [[ "$HAVE_TAG" != "$GIT_TAG" ]]; then
    warn "tree is at $HAVE_TAG, script expects $GIT_TAG - building anyway"
  else
    ok "at expected tag $HAVE_TAG"
  fi
else
  warn "not a git tree - building as-is"
fi

header "Building git"
info "guest-sane flags: NO_TCLTK + NO_GETTEXT + NO_PERL (https kept)"
# shellcheck disable=SC2086
( cd "$GIT_SRC" && \
  make $JOBS_FLAG prefix=/usr NO_TCLTK=1 NO_GETTEXT=1 NO_PERL=1 > /dev/null && \
  make install DESTDIR="$SCRIPT_DIR/git-pkg" prefix=/usr NO_TCLTK=1 NO_GETTEXT=1 NO_PERL=1 > /dev/null )
ok "git built"

header "Assembling guest tree"
rm -rf "$GIT_DIST"
mkdir -p "$GIT_DIST/bin" "$GIT_DIST/usr/libexec" "$GIT_DIST/usr/share"
cp -a "$SCRIPT_DIR/git-pkg/usr/bin/." "$GIT_DIST/bin/"
cp -a "$SCRIPT_DIR/git-pkg/usr/libexec/git-core" "$GIT_DIST/usr/libexec/"
if [[ -d "$SCRIPT_DIR/git-pkg/usr/share/git-core" ]]; then
  cp -a "$SCRIPT_DIR/git-pkg/usr/share/git-core" "$GIT_DIST/usr/share/"
fi
# Drop perl helpers (no perl in-guest) and .poda files; keep the rest -
# git fails confusingly when a helper it shells out to is missing.
find "$GIT_DIST/usr/libexec/git-core" -name "*.perl" -delete 2>/dev/null || true
rm -rf "$SCRIPT_DIR/git-pkg"
strip "$GIT_DIST"/bin/* "$GIT_DIST"/usr/libexec/git-core/* 2>/dev/null || true
ok "guest tree ready ($(du -sh "$GIT_DIST" | cut -f1))"

header "Results"
info "self-check: main binary linkage:"
ldd "$GIT_DIST/bin/git" | awk '{print $1}' | grep "^lib" | sort -u | sed 's/^/         /'
info "helper count: $(ls "$GIT_DIST/usr/libexec/git-core" | wc -l)"
