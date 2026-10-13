#!/usr/bin/env bash
# clean_kernel.sh - clean one or both kernel trees.
#
# Two kernels are built from this repo and they must never share a tree:
#
#   linux/       rlos/kernel.config       -> kernel-images/rlos/bzImage
#   linux-atom/  rlos-atom/kernel.config  -> kernel-images/rlos-atom/bzImage
#
# They previously DID share linux/, and the result was an rlos bzImage silently
# missing CONFIG_USER_NS - because atom's build copied its own .config over the
# one rlos was compiling against. The symptom only appeared hours later, as
# bubblewrap refusing to start inside the booted image. Hence two trees, and
# compile_atom_kernel.sh refusing to be pointed at rlos's.
#
# Usage:
#   ./clean_kernel.sh              clean the rlos tree
#   ./clean_kernel.sh rlos-atom    clean the atom tree
#   ./clean_kernel.sh all          clean both
#   ./clean_kernel.sh all --purge  also delete the trees entirely (re-clone)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

TARGET="rlos"
PURGE=0
for a in "$@"; do
  case "$a" in
    rlos|rlos-atom|all) TARGET="$a" ;;
    --purge)            PURGE=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "clean_kernel.sh: unknown argument '$a'" >&2; exit 1 ;;
  esac
done

info() { echo "  $*"; }
ok()   { echo "ok: $*"; }
warn() { echo "warn: $*" >&2; }
header() {
  echo
  echo "== $* =="
}

SHARED_TREE="$ROOT/linux"

LOCKFILE="$ROOT/.kernel-build.lock"

# target -> tree, config, output image
tree_for()  { echo "$SHARED_TREE"; }
image_for() { case "$1" in rlos) echo "$ROOT/kernel-images/rlos/bzImage" ;;      rlos-atom) echo "$ROOT/kernel-images/rlos-atom/bzImage" ;; esac; }
config_for(){ case "$1" in rlos) echo "$ROOT/kernel.config" ;;      rlos-atom) echo "$ROOT/rlos-atom/kernel.config" ;; esac; }
builder_for(){ case "$1" in rlos) echo "$ROOT/compile_kernel.sh" ;;      rlos-atom) echo "$ROOT/rlos-atom/compile_atom_kernel.sh" ;; esac; }

TARGETS=("$TARGET")
[ "$TARGET" = "all" ] && TARGETS=(rlos rlos-atom)

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "error: another kernel build or clean holds $LOCKFILE" >&2
    echo "  if you are sure nothing is running: rm -f $LOCKFILE" >&2
    exit 1
fi

for t in "${TARGETS[@]}"; do
  d="$(tree_for "$t")"
  img="$(image_for "$t")"
  cfg="$(config_for "$t")"

  header "cleaning $t"
  info "tree:  $d  (shared by both kernels)"
  info "image: $img"

  if [ ! -d "$d" ]; then
      warn "no tree at $d - nothing to clean (it gets cloned on the next build)"
  elif [ "$PURGE" = "1" ]; then
      rm -rf "$d"
      ok "removed $d (will re-clone on next build - needs network)"
      if [ "$TARGET" = "all" ]; then
          warn "tree is shared; skipping the remaining purge targets"
          break
      fi
  else
      if make -C "$d" clean > /dev/null 2>&1; then
          ok "make clean in $d"
      else
          warn "make clean failed in $d - falling back to rm -rf"
          rm -rf "$d"
          ok "removed $d"
      fi
      if [ -f "$d/.config" ] && rm -f "$d/.config"; then
          info "removed $d/.config (a stale one is worse than none)"
      fi
  fi

  if [ -f "$img" ]; then
      rm -f "$img"
      ok "removed $(basename "$img") from $(dirname "$img")"
  else
      info "no built image to remove"
  fi
done

header "done"
ok "cleaned: ${TARGETS[*]}"
for t in "${TARGETS[@]}"; do
  b="$(builder_for "$t")"
  info "rebuild with: $b"
done
info "(or ./build_kernel.sh ${TARGETS[*]} to clean and build in one step)"
info "the tree is shared by both kernels, so only the output image is per-target"
info "kernel.config is never modified by cleaning - it is the source of truth"
