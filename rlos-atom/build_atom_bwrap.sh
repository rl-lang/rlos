#!/usr/bin/env bash
# build_atom_bwrap.sh - stage bubblewrap + libcap for rlos-atom.
#
# bubblewrap is the sandbox constructor rlos-atom uses to run a service inside a
# running rlOS. It is the right tool rather than podman/runc/systemd-nspawn
# because it is not a container manager: there is no daemon, no image store, no
# conmon, and no cgroup bookkeeping. It takes a rootfs directory you already
# have and a list of binds, which is exactly what build_atom_rootfs.sh produces.
#
#   size: 84K binary + libcap.so.2. That is the entire runtime cost.
#
# Output:
#
#   bwrap-dist/bin/bwrap
#   bwrap-dist/usr/lib64/libcap.so.2
#
# Staged standalone (not folded into nettools-dist) because bwrap belongs to
# rlos-atom, and rlOS itself only needs it in order to *host* an atom container
# - it is never used by the desktop or the base system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/rlos-atom/bwrap-dist"

info() { echo "  $*"; }
ok()   { echo "ok: $*"; }
warn() { echo "warn: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
header() {
  echo
  echo "== $* =="
}

header "clean"
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/usr/bin" "$DIST/usr/lib64"
echo "  $DIST"

header "binary"
if [ ! -x /usr/bin/bwrap ]; then
    fail "bwrap not found on this host - install bubblewrap to build rlos-atom"
fi
# busybox applet shadowing check, same class of bug as the lsblk one: whichever
# lands first in /bin wins and the other silently becomes unreachable.
if [ -x "$ROOT/busybox-dist/bin/busybox" ] && \
   "$ROOT/busybox-dist/bin/busybox" --list 2>/dev/null | awk '{print $1}' | grep -qx bwrap; then
    fail "busybox also provides a bwrap applet - one would shadow the other"
fi
cp -L /usr/bin/bwrap "$DIST/bin/bwrap"
cp -L /usr/bin/bwrap "$DIST/usr/bin/bwrap"   # so `command -v` and /usr/bin paths both work
chmod 755 "$DIST/bin/bwrap"
ok "bin/bwrap ($(du -h "$DIST/bin/bwrap" | cut -f1))"

# Not setuid, and deliberately so.
#
# bubblewrap removed its setuid mode upstream ("Historically, bubblewrap also
# supported a setuid mode for systems where unprivileged user namespaces were
# not supported. However, this has been removed."). It relies on
# CONFIG_USER_NS instead, which rlos-atom's kernel enables. Shipping a setuid
# bwrap would be both impossible and undesirable.
if [ -u "$DIST/bin/bwrap" ]; then
    warn "staged bwrap is setuid - stripping, atom does not need or want that"
    chmod u-s "$DIST/bin/bwrap"
fi

header "ldd closure"
CLOSURE_SEEN=""
collect() {
  local target="$1" lib
  for lib in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
    case " $CLOSURE_SEEN " in *" $lib "*) continue ;; esac
    CLOSURE_SEEN="$CLOSURE_SEEN $lib"
    collect "$lib"
  done
}
collect "$DIST/bin/bwrap"

N=0
for lib in $CLOSURE_SEEN; do
  base="$(basename "$lib")"
  # copy -L: dereference so a real ELF lands in the guest rather than a symlink
  # chain pointing at a host-only path.
  cp -L "$lib" "$DIST/usr/lib64/$base"
  N=$((N + 1))
done
info "closure: $N libraries, $(du -sh "$DIST/usr/lib64" | cut -f1)"
ls "$DIST/usr/lib64" | sed 's/^/         /'

# Every staged .so must be a real ELF. A distro that ships a linker script under
# a .so name (or a symlink chain into a build path) produces a guest that fails
# at load time with a loader error rather than anything actionable.
for f in "$DIST"/usr/lib64/*.so*; do
  [ -e "$f" ] || continue
  if ! file -b "$f" | grep -q ELF; then
    fail "$(basename "$f") is not a real ELF ($(file -b "$f" | cut -c1-40))"
  fi
done
ok "all staged libs are real ELF"

header "self-check"
# Run the staged bwrap against a throwaway tree. This is the only check that
# answers the question that matters - does the loader resolve everything from
# usr/lib64 - and it does not need a guest or root.
TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT
mkdir -p "$TESTROOT/rootfs/bin" "$TESTROOT/rootfs/usr/lib64" "$TESTROOT/rootfs/proc" "$TESTROOT/rootfs/dev"
cp -L /usr/bin/busybox "$TESTROOT/rootfs/bin/busybox" 2>/dev/null || cp -L /bin/sh "$TESTROOT/rootfs/bin/sh"
cp -L "$DIST"/usr/lib64/*.so* "$TESTROOT/rootfs/usr/lib64/" 2>/dev/null || true

if env LD_LIBRARY_PATH="$DIST/usr/lib64" "$DIST/bin/bwrap" \
     --ro-bind / / --dev /dev --proc /proc --unshare-pid --new-session \
     /bin/true 2>/dev/null; then
  ok "staged bwrap runs and creates namespaces"
else
  warn "bwrap self-check failed - loader problem in the staged closure?"
  env LD_LIBRARY_PATH="$DIST/usr/lib64" "$DIST/bin/bwrap" \
     --ro-bind / / --dev /dev --proc /proc --unshare-pid --new-session \
     /bin/true 2>&1 | head -3 | sed 's/^/         /'
  exit 1
fi

# --unshare-user is only reachable with CONFIG_USER_NS=y in the kernel that will
# eventually run this. Cannot be tested here (this host does have userns, but
# that proves nothing about atom's kernel), so it is asserted in
# compile_atom_kernel.sh's REQUIRED_SYMS instead.
info "unshare-user availability is enforced by the atom kernel config, not here"

header "done"
ok "bwrap staged ($(du -sh "$DIST" | cut -f1))"
info "next: build_atom_rootfs.sh stages this into the atom rootfs, and the"
info "      main rlOS gets it too so it can host atom containers."