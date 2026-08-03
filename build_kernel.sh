#!/usr/bin/env bash
# build_kernel.sh - clean and build one or both kernels.
#
#   ./build_kernel.sh                rlos   (clean, then build)
#   ./build_kernel.sh rlos-atom      atom   (clean, then build)
#   ./build_kernel.sh all            both, atom first
#   ./build_kernel.sh rlos --no-clean  build without cleaning first
#   ./build_kernel.sh all --jobs 4
#
# Why atom first when building both: the two builds are independent now that
# they have separate trees, but atom's tree starts empty and needs a full clone,
# so starting it first means the clone overlaps with nothing and any failure is
# obviously atom's rather than a race.
#
# The actual building lives in compile_kernel.sh and rlos-atom/compile_atom_kernel.sh.
# This is a thin wrapper so there is one command to remember and one place where
# "clean then build" is decided.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

TARGET="rlos"
DO_CLEAN=1
JOBS="$(nproc 2>/dev/null || echo 4)"

info() { echo "  $*"; }
ok()   { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
header() {
  echo
  echo "== $* =="
}

while [ $# -gt 0 ]; do
  case "$1" in
    rlos|rlos-atom|all) TARGET="$1" ;;
    --no-clean)         DO_CLEAN=0 ;;
    -j|--jobs)          JOBS="$2"; shift ;;
    -h|--help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "build_kernel.sh: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done

# One shared tree for both kernels - see the note in
# rlos-atom/compile_atom_kernel.sh. What is separate is the OUTPUT.
tree_for()   { echo "$ROOT/linux"; }
LOCKFILE="$ROOT/.kernel-build.lock"
builder_for() { case "$1" in rlos) echo "$ROOT/compile_kernel.sh" ;;      rlos-atom) echo "$ROOT/rlos-atom/compile_atom_kernel.sh" ;; esac; }
image_for()  { case "$1" in rlos) echo "$ROOT/kernel-images/rlos/bzImage" ;;      rlos-atom) echo "$ROOT/kernel-images/rlos-atom/bzImage" ;; esac; }

TARGETS=("$TARGET")
if [ "$TARGET" = "all" ]; then
  # atom first, sequentially. Order matters only because atom's kernel is the
  # one nobody has booted yet; both write to their own output path, so either
  # order leaves the same two images behind.
  TARGETS=(rlos-atom rlos)
fi

for t in "${TARGETS[@]}"; do
  b="$(builder_for "$t")"
  [ -x "$b" ] || fail "$b not found or not executable"
done

# One build at a time, because the tree is shared.
#
# This lock is the whole reason a shared tree is safe. The bug that started this
# was two builds running at once: atom's build copied its own .config over the
# one rlos was compiling against, and the result was an rlos kernel silently
# missing CONFIG_USER_NS. Two sequential builds over one tree cannot do that.
#
# The lock is held by THIS script for the whole run, including the clean step, and
# clean_kernel.sh takes it too - so a standalone clean during a build also fails
# rather than corrupting it. flock is released automatically when the process
# exits, including on Ctrl-C, so there is no stale lock to clean up by hand.
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    fail "another kernel build or clean holds $LOCKFILE"
    fail "  if you are sure nothing is running: rm -f $LOCKFILE"
fi

for t in "${TARGETS[@]}"; do
  # Resolve the builder HERE, inside the loop.
  #
  # This was a real bug: `b` was assigned only in the validation loop above, so at
  # the start of the build loop it held the LAST target's builder. For
  # `build_kernel.sh all` that meant the atom phase silently ran
  # compile_kernel.sh and wrote kernel-images/rlos/bzImage, then failed the
  # post-build check looking for kernel-images/rlos-atom/bzImage. The check is
  # the only reason it was caught rather than shipping an atom kernel that was
  # really an rlos kernel.
  b="$(builder_for "$t")"
  header "=== $t ==="
  info "tree:   $(tree_for "$t")"
  info "image:  $(image_for "$t")"

  if [ "$DO_CLEAN" = "1" ]; then
      info "cleaning first..."
      # Deliberately NOT calling clean_kernel.sh: that script takes the same
      # flock this script already holds, so invoking it would deadlock. The lock
      # is the parent's job; the clean itself is three commands.
      if [ -d "$(tree_for "$t")" ]; then
          make -C "$(tree_for "$t")" clean > /dev/null 2>&1 || warn "make clean failed"
          # .config goes too. Leaving it is how a stale config survives a
          # "clean" and quietly builds the wrong kernel - the next build is
          # supposed to copy a fresh one in from kernel.config.
          rm -f "$(tree_for "$t")/.config"
          info "make clean + removed .config"
      fi
      rm -f "$(image_for "$t")"
  else
      info "--no-clean: building on whatever is in the tree"
  fi

  # Both builders honour RLOS_NO_CLEAN / ATOM_NO_CLEAN to skip their own internal
  # `make clean`, which clean_kernel.sh has already done. Passing it keeps the
  # tree from being cleaned twice, which would turn a rebuild into a full build.
  if [ "$t" = "rlos" ]; then
      RLOS_NO_CLEAN=1 "$ROOT/compile_kernel.sh" || fail "rlos kernel build failed"
  else
      ATOM_NO_CLEAN=1 "$b" || fail "rlos-atom kernel build failed"
  fi

  img="$(image_for "$t")"
  [ -f "$img" ] || fail "$t: build reported success but $img is missing"
  ok "$t kernel: $(du -h "$img" | cut -f1) -> ${img#"$ROOT"/}"
done

header "summary"
for t in "${TARGETS[@]}"; do
  printf '  %-10s %s\n' "$t" "$(du -h "$(image_for "$t")" | cut -f1)"
done
ok "kernel build complete"