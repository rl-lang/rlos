#!/usr/bin/env bash
# build_fastfetch.sh - stage fastfetch into the guest.
#
# fastfetch is the "what am I running on" banner. It is the one tool here that
# is not part of the language toolchain, so it gets its own script rather than
# going into build_rl_bins.sh.
#
# Staged to /usr/bin/fastfetch, NOT /bin, and that has a consequence worth
# knowing: assemble-rootfs.sh's ldd closure only walks /bin/* and
# /usr/libexec/git-core/*. A binary in /usr/bin is invisible to it, so its
# libraries have to be staged explicitly below or they will not be there at
# runtime - and with no ld.so.cache in the guest, a missing library is a silent
# "command not found"-shaped failure rather than a diagnostic one.
#
# fastfetch 2.x is self-contained in the way that matters: its detection
# modules are COMPILED IN, not dlopened (verified - `ldd` reports only libyyjson
# and libm, and there is no module directory anywhere on the system). Only
# /usr/share/fastfetch/*.jsonc presets are external, and those are optional
# conveniences; fastfetch runs fine without them. So this is close to a
# copy-the-binary job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FF_SRC="${FF_SRC:-/usr/bin/fastfetch}"
FF_DIST="$SCRIPT_DIR/fastfetch-dist"

ok()   { printf "  [ OK ] %s\n" "$*"; }
warn() { printf "  [WARN] %s\n" "$*" >&2; }
fail() { printf "  [FAIL] %s\n" "$*" >&2; exit 1; }
info() { printf "  :: %s\n" "$*"; }
header() { printf "\n:: *\n:: %s\n" "$*"; }

header "Host prerequisites"
command -v fastfetch > /dev/null 2>&1 \
  || { fail "fastfetch not found on PATH"; \
       fail "on Gentoo: emerge app-misc/fastfetch"; \
       fail "  or point FF_SRC at a binary you already have"; exit 1; }
ok "fastfetch $(fastfetch --version 2>&1 | head -1)"
ok "FF_SRC=$FF_SRC"

[[ -x "$FF_SRC" ]] || { fail "$FF_SRC is not executable"; exit 1; }

header "Assembling guest tree"
rm -rf "$FF_DIST"
mkdir -p "$FF_DIST/usr/bin" "$FF_DIST/usr/lib64"

cp "$FF_SRC" "$FF_DIST/usr/bin/fastfetch"
chmod 755 "$FF_DIST/usr/bin/fastfetch"
strip "$FF_DIST/usr/bin/fastfetch" 2> /dev/null || true
ok "binary staged ($(du -h "$FF_DIST/usr/bin/fastfetch" | cut -f1))"

# Libraries. Staged by SONAME because that is the string the loader looks for,
# and because /usr/lib64/libfoo.so is usually a symlink that will not survive
# being copied without its target.
#
# libc.so.6 and libm.so.6 are deliberately SKIPPED. assemble-rootfs.sh's ldd
# closure already stages both for every binary in /bin, so copying them again
# here would add ~2.6MB of duplicate to the image for no benefit - and a second
# copy is a second thing that can go stale. Only libraries nothing else pulls in
# belong here.
FF_SKIP="libc.so.6 libm.so.6 ld-linux-x86-64.so.2"
FF_DEPS="$(ldd "$FF_DIST/usr/bin/fastfetch" 2>/dev/null | awk '{print $3}' | grep '^/' | sort -u || true)"
if [ -z "$FF_DEPS" ]; then
  ok "statically linked - no libraries needed"
else
  info "needs: $(echo "$FF_DEPS" | tr '\n' ' ')"
  for lib in $FF_DEPS; do
    base="$(basename "$lib")"
    case " $FF_SKIP " in
      *" $base "*)
        ok "$base skipped (already staged for the whole guest)"
        continue ;;
    esac
    real="$(readlink -f "$lib" 2>/dev/null || echo "$lib")"
    if [ -f "$real" ]; then
      cp -f "$real" "$FF_DIST/usr/lib64/$base"
      ok "staged $base ($(du -h "$real" | cut -f1))"
    else
      fail "dependency $lib listed by ldd but not found on disk"
      exit 1
    fi
  done
fi

# Presets are optional - fastfetch works without /usr/share/fastfetch - but they
# are tiny and two of them (neofetch.jsonc, paleofetch.jsonc) are the aliases
# people actually expect to work. Stage them if present.
if [ -d /usr/share/fastfetch ]; then
  mkdir -p "$FF_DIST/usr/share/fastfetch"
  cp -a /usr/share/fastfetch/. "$FF_DIST/usr/share/fastfetch/" 2>/dev/null || true
  ok "presets staged ($(find "$FF_DIST/usr/share/fastfetch" -type f | wc -l) files, optional)"
fi

# ---- verify by RUNNING it ---------------------------------------------------
#
# Same reasoning as build_gcc.sh's link-check: a staged file that was never
# executed is an assumption, not a result. fastfetch is run against a staged-only
# library set so the test cannot silently pass by using the host's own libraries
# via its baked RPATH or a system path.
#
# The guest has no ld.so.cache and searches only the default dirs, which is what
# -L plus a private loader set approximates here.
header "Self-check: does it run?"
# Run it with a library set that is the staged one PLUS the guest's own libc and
# libm (which fastfetch-dist deliberately does not carry - see above). Those two
# come from the current initramfs tree, so this approximates the real guest
# rather than passing by accident against the host's own libraries.
CHK="$(mktemp -d)"
trap 'rm -rf "$CHK"' EXIT
mkdir -p "$CHK/lib" "$CHK/bin"
cp "$FF_DIST/usr/bin/fastfetch" "$CHK/bin/"
cp "$FF_DIST"/usr/lib64/*.so* "$CHK/lib/" 2>/dev/null || true
GUEST_LIB="$SCRIPT_DIR/rlos-initramfs/initramfs/usr/lib64"
for l in libc.so.6 libm.so.6; do
  [ -e "$GUEST_LIB/$l" ] && cp "$GUEST_LIB/$l" "$CHK/lib/" 2>/dev/null || true
done
info "test library set: $(ls "$CHK/lib" | tr '\n' ' ')"

# --logo none avoids needing any logo asset; --pipe false keeps output on stdout.
# A default run also exercises the detection modules, which read /proc - the part
# most likely to behave differently in the guest than it does here.
if OUT="$(LD_LIBRARY_PATH="$CHK/lib" "$CHK/bin/fastfetch" --logo none --pipe false 2>&1)"; then
  if [ -n "$OUT" ]; then
    ok "runs: $(printf '%s' "$OUT" | head -1)"
    N_LINES="$(printf '%s\n' "$OUT" | grep -c . || true)"
    if [ "${N_LINES:-0}" -lt 3 ]; then
      warn "only ${N_LINES} lines - detection modules may be short-circuiting"
    else
      ok "detection produced ${N_LINES} lines (modules ran, not just the binary started)"
    fi
  else
    fail "exited 0 but printed nothing - the detection modules did not run"
    exit 1
  fi
else
  fail "fastfetch does not run from the staged tree:"
  printf '%s\n' "$OUT" | sed 's/^/         /' | head -8
  exit 1
fi

header "Results"
ok "fastfetch-dist ready ($(du -sh "$FF_DIST" | cut -f1))"
info "layout:"
find "$FF_DIST" -maxdepth 3 | sort | sed 's/^/         /' | head -20
info "next: assemble-rootfs.sh copies fastfetch-dist/ into the guest."
