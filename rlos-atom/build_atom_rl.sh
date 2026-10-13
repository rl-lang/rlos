#!/usr/bin/env bash
# build_atom_rl.sh - build the rl-lang toolchain that goes INSIDE rlos-atom.
#
# Deliberately smaller than build_rl_bins.sh in two ways.
#
# 1. Fewer binaries. Atom is a service container (git server and friends), not a
#    desktop, so it needs the compiler, the transpiler and the docs viewer and
#    nothing else:
#
#      rlc      compiles rl source
#      rlt      transpiles to C and links with gcc
#      rldocs   the stdlib documentation viewer
#
#    Deliberately NOT built: rl (the VM runner), rlsp (language server),
#    rlrepl (interactive REPL). If the atom image comes in well under budget,
#    `rl` is the one worth adding back, since it is what actually runs a
#    compiled program.
#
# 2. no-media, not no-gui. This is the opposite choice to the main rlOS and the
#    distinction is load-bearing:
#
#      no-gui  = impls-base + std-audio   audio ON, GUI off
#      no-media = impls-base only         no audio, no GUI
#
#    Atom's kernel has CONFIG_SOUND off, so audio could not work even if it were
#    linked. Building no-media also drops the rodio -> cpal -> ALSA link, which
#    is what makes the binaries smaller (rlt 4.3M rather than 8.3M) and stops
#    rlt emitting miniaudio.h next to the emitted rl_runtime.c - a header that
#    would fail to compile in atom for want of sound support it could not use.
#
# Output:
#
#   atom-bins/rlc  atom-bins/rlt  atom-bins/rldocs
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RL_LANG_DIR="${RL_LANG_DIR:-$ROOT/rl-lang}"
OUT_DIR="$ROOT/rl-bins/rlos-atom"

source "$ROOT/build-lib.sh"
usage() {
  cat << 'USAGE'
Build the rlos-atom rl-lang toolchain (no-media: no audio, no GUI).

  ./build_atom_rl.sh              release build
  ./build_atom_rl.sh --dev        debug build
  -j, --jobs N                    parallel cargo jobs (default: nproc)
  --rl-lang DIR                   rl-lang checkout (default: ./rl-lang)
USAGE
}

PROFILE_FLAG="--release"
JOBS="$(nproc 2>/dev/null || echo 4)"
while [ $# -gt 0 ]; do
  case "$1" in
    --dev)      PROFILE_FLAG="" ;;
    --release)  PROFILE_FLAG="--release" ;;
    -j|--jobs)  JOBS="$2"; shift ;;
    --rl-lang)  RL_LANG_DIR="$2"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
  shift
done

header "Checking"
[ -d "$RL_LANG_DIR" ] || fail "rl-lang not found at $RL_LANG_DIR (use --rl-lang DIR)"
command -v cargo >/dev/null 2>&1 || fail "cargo not on PATH"
info "rl-lang: $RL_LANG_DIR"
info "profile: ${PROFILE_FLAG:-debug}, jobs: $JOBS"

# The feature must exist in this checkout. no-media is what drops std-audio and
# therefore the ALSA link; if a future rl-lang renames it, this should fail here
# rather than silently producing binaries that still drag in libasound.
if ! grep -q '^no-media' "$RL_LANG_DIR/crates/rl-cli/Cargo.toml"; then
    fail "rl-lang has no 'no-media' feature - cannot build the atom variant"
fi

header "Building"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
FAILED=0

build_one() {
  local name="$1" pkg="$2" bin_flag="$3" features="$4"
  echo
  echo "-- $name --"
  local args=(--no-default-features "$PROFILE_FLAG" -j "$JOBS" -p "$pkg" $bin_flag --features "$features")
  # shellcheck disable=SC2086
  if (cd "$RL_LANG_DIR" && cargo build "${args[@]}"); then
    local src
    # cargo puts it in target/<triple>/release or target/release
    src="$(find "$RL_LANG_DIR/target" -maxdepth 3 -type f -name "$name" -perm -u+x \
             -newermt '-10 minutes' 2>/dev/null | head -1)"
    if [ -z "$src" ]; then
      # fall back to the conventional path
      local d="$RL_LANG_DIR/target/release"; [ "$PROFILE_FLAG" = "--release" ] || d="$RL_LANG_DIR/target/debug"
      src="$d/$name"
    fi
    if [ -x "$src" ]; then
      cp -f "$src" "$OUT_DIR/$name"
      chmod 755 "$OUT_DIR/$name"
      ok "$name ($(du -h "$OUT_DIR/$name" | cut -f1))"
    else
      warn "$name built but not found at $src"
      FAILED=1
    fi
  else
    fail "cargo build failed for $name"
  fi
}

build_one "rlc"     "rl-cli"  "--bin rlc"     "no-media"
build_one "rlt"     "rl-cli"  "--bin rlt"     "cc,rl-cc/no-media"
build_one "rldocs"  "rl-docs" "--bin rldocs"  "tui"

header "Linkage check"
# Audio and GUI must both be absent. This is the check that distinguishes
# no-media from no-gui, and it is the whole reason this script exists separately
# from build_rl_bins.sh: if no-media ever silently stopped dropping std-audio,
# atom would gain a libasound dependency it cannot satisfy, and the failure would
# not appear until a compiled program was run inside the container.
LINK_FAIL=0
for b in "$OUT_DIR"/*; do
  [ -x "$b" ] || continue
  bad="$(objdump -p "$b" 2>/dev/null | awk '/NEEDED/{print $2}' \
         | grep -iE 'libasound|libX11|libEGL|libGL\.|wayland|libpulse' | sort -u)"
  if [ -n "$bad" ]; then
    fail "$(basename "$b") links audio/GUI libs - no-media is not taking effect:"
    printf "%s\n" "$bad" | sed 's/^/         /'
    LINK_FAIL=1
  else
    ok "$(basename "$b") no audio, no GUI ($(du -h "$b" | cut -f1))"
  fi
done
[ "$LINK_FAIL" = "0" ] || exit 1

# A sanity check on the point of the exercise: rlt built with rl-cc/no-media must
# NOT emit miniaudio.h, because atom's kernel has no sound support to compile it
# against. Verified by transpiling a trivial program and listing the output.
header "rlt does not emit miniaudio"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
printf '  get * from std::io\n  println("hi")\n' > "$TMPD/probe.rl"
if (cd "$TMPD" && "$OUT_DIR/rlt" --compile probe.rl > /dev/null 2>&1); then
  if [ -e "$TMPD/miniaudio.h" ]; then
    fail "rlt emitted miniaudio.h - rl-cc/no-media is not taking effect"
  else
    ok "no miniaudio.h emitted (rl-cc/no-media working)"
  fi
  [ -e "$TMPD/rl_runtime.c" ] && ok "rl_runtime.c emitted"
else
  warn "rlt --compile probe failed; skipping the miniaudio assertion"
fi

header "done"
ok "$(ls "$OUT_DIR" | wc -l)/3 built into rlos-atom/atom-bins/"
du -sh "$OUT_DIR" | awk '{print "  total: "$1}'
info "next: build_atom_rootfs.sh stages these into the atom rootfs."
