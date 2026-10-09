#!/usr/bin/env bash
# build_rl_bins.sh - build the rl-lang binaries for rlos
#
# Builds the toolchain with the `no-gui` feature set where it exists.
#
# no-gui, not no-media: no-gui is impls-base + std-audio, so audio is ON and only
# the GUI is off. That is the right trade here - the kernel now has HDA audio and
# libasound + alsa.conf are staged, and rl-std/audio.rs is 19 native functions
# that are dead code without this. GUI stays off because eframe needs GL, which
# this image does not have.
# (full runtime except `std-audio`/`std-gui`: no libasound, no X11/GUI
# linkage) and places the results in rl-bins/rlos/ for build_initramfs.sh.
#
# rl-bins/ is split per image because the two need different builds:
#   rl-bins/rlos/       no-gui  (audio on, GUI off)  - the desktop image
#   rl-bins/rlos-atom/  no-media (no audio, no GUI)  - the atom container
# Building them together every time would mean recompiling the whole of rl-lang
# to change one feature flag, which is why they are separate directories with
# separate scripts (build_rl_bins.sh and rlos-atom/build_atom_rl.sh).
# to install into the guest.
#
# Binaries: rl, rlc, rlt (rl-cli), rldocs (rl-docs), rlrepl (rl-repl),
#           rlsp (rl-lsp).
#
# Usage:
#   ./build_rl_bins.sh                    # release build (default)
#   ./build_rl_bins.sh --dev-release      # faster build, bigger binaries
#   ./build_rl_bins.sh --dev              # debug build
#   ./build_rl_bins.sh -j 8               # 8 parallel jobs
#   ./build_rl_bins.sh --rl-lang DIR      # rl-lang checkout elsewhere
#   ./build_rl_bins.sh --clean-bins      # remove rl-bins/rlos/ before building
#
# RL_LANG_DIR env var also works:  RL_LANG_DIR=~/dev/rl/rl-lang ./build_rl_bins.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RL_LANG_DIR="${RL_LANG_DIR:-$SCRIPT_DIR/rl-lang}"
PROFILE="release"
CLEAN_BINS=0
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
header(){ printf "\n${C_BOLD}${C_CYAN}:: %s${C_RESET}\n" "$*"; }

usage() {
  printf "\n"
  printf "${C_BOLD}Usage:${C_RESET} ${C_CYAN}build_rl_bins.sh${C_RESET} [OPTIONS]\n"
  printf "\n"
  printf "Build the no-gui rl-lang binaries into ${C_BOLD}rl-bins/rlos/${C_RESET}.\n"
  printf "\n"
  printf "${C_BOLD}Options:${C_RESET}\n"
  printf "  ${C_GREEN}--release${C_RESET}          Build with --release ${C_DIM}(default)${C_RESET}\n"
  printf "  ${C_GREEN}--dev-release${C_RESET}      Build with --profile dev-release ${C_DIM}(fast, bigger)${C_RESET}\n"
  printf "  ${C_GREEN}--dev${C_RESET}              Build without --release ${C_DIM}(debug)${C_RESET}\n"
  printf "  ${C_GREEN}--rl-lang${C_RESET} ${C_CYAN}DIR${C_RESET}     rl-lang checkout ${C_DIM}(default: ./rl-lang)${C_RESET}\n"
  printf "  ${C_YELLOW}-j, --jobs${C_RESET} ${C_CYAN}N${C_RESET}       Number of parallel cargo jobs\n"
  printf "  ${C_RED}--clean-bins${C_RESET}       Remove rl-bins/rlos/ before building\n"
  printf "  ${C_BLUE}-h, --help${C_RESET}         Show this help\n"
  printf "\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --release)     PROFILE="release"; shift ;;
    --dev-release) PROFILE="dev-release"; shift ;;
    --dev)         PROFILE="dev"; shift ;;
    --rl-lang)     RL_LANG_DIR="$2"; shift 2 ;;
    -j|--jobs)     JOBS="$2"; shift 2 ;;
    --clean-bins)  CLEAN_BINS=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             fail "unknown option: $1"; exit 1 ;;
  esac
done

OUT_DIR="$SCRIPT_DIR/rl-bins/rlos"

if [ "$CLEAN_BINS" = "1" ]; then
  header "Cleaning"
  info "removing rl-bins/rlos/"
  rm -rf "$OUT_DIR"
  ok "cleaned"
fi

mkdir -p "$OUT_DIR"

# Build profile flag
case "$PROFILE" in
  release)     PROFILE_FLAG="--release";           PROFILE_DIR="target/release" ;;
  dev-release) PROFILE_FLAG="--profile dev-release"; PROFILE_DIR="target/dev-release" ;;
  dev)         PROFILE_FLAG="";                    PROFILE_DIR="target/debug" ;;
esac

JOBS_FLAG=""
if [ -n "$JOBS" ]; then
  JOBS_FLAG="-j $JOBS"
fi

if [ ! -f "$RL_LANG_DIR/Cargo.toml" ]; then
  fail "no Cargo.toml in '$RL_LANG_DIR' (use --rl-lang DIR)"
  exit 1
fi
if ! command -v cargo > /dev/null 2>&1; then
  fail "cargo not found on PATH"
  exit 1
fi

header "Build config"
info "profile: ${C_BOLD}${PROFILE}${C_RESET}"
info "rl-lang: ${C_BOLD}${RL_LANG_DIR}${C_RESET}"
info "output:  ${C_BOLD}${OUT_DIR}/${C_RESET}"
info "jobs:    ${C_BOLD}${JOBS:-auto}${C_RESET}"

# Track failures
FAILED=0
BUILT=0

build_one() {
  local name="$1" pkg="$2" bin_flag="${3:-}" features="${4:-}"

  local feat_flag=""
  if [ -n "$features" ]; then
    feat_flag="--features $features"
  fi
  # shellcheck disable=SC2086
  local cmd="cargo build $PROFILE_FLAG $JOBS_FLAG $bin_flag $feat_flag -p $pkg"

  printf "\n${C_CYAN}  ::${C_RESET} ${C_BOLD}building %-8s${C_RESET}\n" "$name"
  printf "${C_DIM}     %s${C_RESET}\n" "$cmd"

  if ( cd "$RL_LANG_DIR" && eval "$cmd" ); then
    printf "${C_GREEN}  [ OK ]${C_RESET} cargo %s\n" "$name"
  else
    printf "${C_RED}  [FAIL]${C_RESET} cargo %s\n" "$name"
    FAILED=1
    return
  fi

  local src="$RL_LANG_DIR/$PROFILE_DIR/$name"
  if [ ! -f "$src" ]; then
    fail "could not find $name binary in $RL_LANG_DIR/$PROFILE_DIR/"
    FAILED=1
    return
  fi

  cp "$src" "$OUT_DIR/$name"
  chmod +x "$OUT_DIR/$name"

  # Strip anything but debug builds
  if [ "$PROFILE" != "dev" ]; then
    strip "$OUT_DIR/$name" 2>/dev/null || true
  fi
  BUILT=$((BUILT + 1))
}

header "Building binaries"

  # rl + rlc: no-gui runtime (vm code + impls-base + std-audio, no std-gui)
build_one "rl"  "rl-cli" "--no-default-features --bin rl"  "no-gui"
build_one "rlc" "rl-cli" "--no-default-features --bin rlc" "no-gui"
  # rlt: C transpiler only, and deliberately NOT rl-cc/no-media.
  #
  # rl-cc/no-media is a single emit gate: it skips writing miniaudio.h next to
  # rl_runtime.c (crates/rl-cc/src/lib.rs, gated on
  # #[cfg(not(feature = "no-media"))]). Without that header next to the emitted
  # rl_runtime.c, the transpiled program fails at its own
  # `#include "miniaudio.h"`. So for rlt the feature has to be OFF to get audio
  # - the opposite of the rl/rlc line above, where the runtime links rodio
  # directly rather than embedding miniaudio.
  build_one "rlt" "rl-cli" "--no-default-features --bin rlt" "cc"
# rldocs: docs viewer with TUI (needs ratatui/crossterm - fine, no audio/GUI)
build_one "rldocs" "rl-docs" "--bin rldocs" "tui"
  # rlrepl: interactive REPL, no-gui runtime
build_one "rlrepl" "rl-repl" "--no-default-features --bin rlrepl" "no-gui"
# rlsp: language server (signatures only, no media deps by construction)
build_one "rlsp" "rl-lsp" "--bin rlsp" ""

header "Results"

if [ "$FAILED" = "1" ]; then
  fail "some builds failed"
  exit 1
fi

ok "${BUILT}/6 built"
info "binaries in ${C_BOLD}${OUT_DIR}/${C_RESET}:"
ls -lh "$OUT_DIR/" | tail -n +2

  # GUI libs must stay out. libasound is now EXPECTED on rl/rlc/rlrepl: rodio ->
  # cpal -> ALSA links it directly, unlike the compiled path where miniaudio
  # dlopen()s it at runtime. So audio is allowed and reported; GUI is a failure.
  header "Linkage check"
  LINK_FAIL=0
  for bin in "$OUT_DIR"/*; do
    [ -x "$bin" ] || continue
    AUDIO="$(ldd "$bin" 2>/dev/null | grep -oiE 'libasound[^ ]*' | sort -u | tr '\n' ' ')"
    BAD_LIBS="$(ldd "$bin" 2>/dev/null | grep -oiE "libX11|libEGL|libGL\.|libwayland|libeframe" | sort -u || true)"
    if [ -n "$BAD_LIBS" ]; then
      fail "$(basename "$bin") links GUI libs (no-gui should prevent this):"
      printf "%s\n" "$BAD_LIBS"
      LINK_FAIL=1
    elif [ -n "$AUDIO" ]; then
      ok "$(basename "$bin") no-GUI, audio via ${AUDIO% } ($(du -h "$bin" | cut -f1))"
    else
      ok "$(basename "$bin") clean, no audio link ($(du -h "$bin" | cut -f1))"
    fi
  done

if [ "$LINK_FAIL" = "1" ]; then
  exit 1
fi
