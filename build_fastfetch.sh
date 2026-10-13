#!/usr/bin/env bash
# build_fastfetch.sh - stage fastfetch into the guest.
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

if [ -d /usr/share/fastfetch ]; then
  mkdir -p "$FF_DIST/usr/share/fastfetch"
  cp -a /usr/share/fastfetch/. "$FF_DIST/usr/share/fastfetch/" 2>/dev/null || true
  ok "presets staged ($(find "$FF_DIST/usr/share/fastfetch" -type f | wc -l) files, optional)"
fi

header "Self-check: does it run?"
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
