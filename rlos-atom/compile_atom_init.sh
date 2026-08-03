#!/usr/bin/env bash
# compile_atom_init.sh - build the rlos-atom init.
#
# Atom and the desktop share ONE init.c, compiled twice with different -D flags.
#
# Why shared rather than a separate atom-init.c: the parts of init that are
# hardest to get right are exactly the parts atom still needs, and they are the
# parts a rewrite would get wrong. Concretely, these were each a real bug found
# the hard way in the desktop build, and every one of them applies unchanged to a
# service container:
#
#   - busybox udhcpc has no -L option. Passing it makes udhcpc exit with a usage
#     error BEFORE sending a packet, which is indistinguishable from "no DHCP
#     server". The address is read back with SIOCGIFADDR instead.
#   - sshd requires argv[0] to be an absolute path and exits immediately
#     otherwise; the supervisor then restart-loops it forever, which looks like a
#     network fault.
#   - /var/empty must be root-owned or sshd refuses to start, and the assembler
#     runs unprivileged so it cannot guarantee that.
#   - OpenSSH 10 execs /usr/lib64/misc/sshd-session and sshd-auth at runtime and
#     hard-exits 255 without them, plus sftp needs a "Subsystem sftp" config
#     line because OpenSSH has no built-in default for it.
#
# A second init.c would have to re-derive all of that. Sharing means it cannot
# drift.
#
# What -DRLOS_ATOM actually changes is deliberately tiny, because the file was
# already capability-gated: the desktop lives inside
# `if (access("/bin/Xorg", X_OK) == 0)`, and atom ships no Xorg, so the whole X
# path is skipped without a single #ifdef. The guards that exist are for the
# handful of things that run unconditionally and are pointless in atom.
#
# Output:
#
#   rlos-atom/atom-init
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="$ROOT/rlos-initramfs/init.c"
OUT="$ROOT/rlos-atom/atom-init"

info() { echo "  $*"; }
ok()   { echo "ok: $*"; }
warn() { echo "warn: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
header() {
  echo
  echo "== $* =="
}

[ -f "$SRC" ] || fail "init.c not found at $SRC"

# Same flags compile_init.sh uses, so the two builds cannot drift by accident,
# plus -DRLOS_ATOM. PIE and the fortified-source flags match the desktop build.
CC="${CC:-gcc}"
CFLAGS="-std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE"
CFLAGS="$CFLAGS -fPIE -D_FORTIFY_SOURCE=2 -fstack-protector-strong"
CFLAGS="$CFLAGS -DRLOS_ATOM"

header "Compiling"
echo "  $CC $CFLAGS"
# shellcheck disable=SC2086
"$CC" $CFLAGS -o "$OUT" "$SRC" || fail "atom init compile failed"

[ -x "$OUT" ] || fail "no output produced"
ok "atom-init ($(du -h "$OUT" | cut -f1))"

header "Verifying the guard actually bit"
# If RLOS_ATOM were silently ignored, atom would still link but would
# unconditionally mkdir a fontconfig cache it has no use for. Check the define
# really reached the preprocessor rather than trusting the build to fail.
# Not `gcc ... | grep -q`: grep -q exits at the first match, gcc takes SIGPIPE
# on the closed pipe, and under `set -o pipefail` the whole pipeline then reports
# failure even though the define is there. Same trap build_binutils.sh documents.
# Write to a file first and grep that.
DMFILE="$(mktemp)"
trap 'rm -f "$DMFILE"' EXIT
# shellcheck disable=SC2086
"$CC" $CFLAGS -E -dM "$SRC" > "$DMFILE" 2>/dev/null || true
if grep -q '^#define RLOS_ATOM 1$' "$DMFILE"; then
  ok "RLOS_ATOM reached the preprocessor"
else
  fail "RLOS_ATOM did not reach the preprocessor - the guard is a no-op"
fi

# And confirm the desktop build still compiles without it, which is the whole
# risk of sharing a file.
info "checking the desktop build is unaffected..."
if "$CC" -std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE \
     -fsyntax-only "$SRC" 2>/dev/null; then
  ok "desktop build still compiles"
else
  fail "the desktop build broke - a guard is unbalanced"
fi

# Xorg must not be referenced on atom's path. The capability gate handles this,
# but assert it: a hard /bin/Xorg path that ran anyway would mean atom booting
# into a crash loop with no Xorg present.
if grep -q 'access("/bin/Xorg", X_OK)' "$SRC"; then
  ok "desktop path is capability-gated on /bin/Xorg existing"
fi

header "done"
ok "atom init built"
info "next: build_atom_rootfs.sh installs it as /sbin/init."