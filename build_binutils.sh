#!/usr/bin/env bash
# build_binutils.sh - build GNU binutils for the rlos guest (as + ld + binutils)
#
# Output is a guest-root tree in binutils-dist/:
#   bin/{as,ld,ld.bfd,ar,nm,ranlib,objcopy,objdump,strip,readelf,size,strings}
#   bin/addr2line, bin/elfedit
#   lib64/ld-linux-x86-64.so.2       staged by assemble-rootfs.sh, referenced here
#
# Usage:
#   ./build_binutils.sh                    # build (default)
#   ./build_binutils.sh -j 8               # 8 parallel jobs
#   ./build_binutils.sh --clean            # remove binutils-dist/ before building
#
# Needs on the host: gcc, make, binutils (the host's own, for cross tools the
# build leans on).
#
# Needs rlos/binutils symlinked to a binutils-gdb tree at the release tag:
#   ln -s ~/dev/c/binutils-2.46.1 binutils

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINUTILS_PIN="5e56594815854de5eca35c7c04b11705d0f19c02" # binutils-2_46_1
BINUTILS_VER="2.46.1"
BINUTILS_SRC="$SCRIPT_DIR/binutils"
BINUTILS_DIST="$SCRIPT_DIR/binutils-dist"
PKG="$SCRIPT_DIR/binutils-pkg"
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

source "$SCRIPT_DIR/pins.sh"

usage() {
  printf "\n"
  printf "${C_BOLD}Usage:${C_RESET} ${C_CYAN}build_binutils.sh${C_RESET} [OPTIONS]\n"
  printf "\n"
  printf "Build GNU binutils (%s) into guest-root ${C_BOLD}binutils-dist/${C_RESET}.\n" "$BINUTILS_VER"
  printf "\n"
  printf "${C_BOLD}Options:${C_RESET}\n"
  printf "  ${C_YELLOW}-j, --jobs${C_RESET} ${C_CYAN}N${C_RESET}       Number of parallel jobs\n"
  printf "  ${C_RED}--clean${C_RESET}            Remove binutils-dist/ before building\n"
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
  info "removing binutils-dist/ (never touches your binutils/ tree)"
  rm -rf "$BINUTILS_DIST"
  ok "cleaned"
fi

header "Build config"
info "pin:    ${C_BOLD}${BINUTILS_PIN:0:12}${C_RESET} (binutils-2_46_1)"
info "output: ${C_BOLD}binutils-dist/${C_RESET} (guest root)"
info "jobs:   ${C_BOLD}${JOBS:-auto}${C_RESET}"

header "Checking binutils tree"
if [[ ! -f "$BINUTILS_SRC/configure" ]]; then
  pins_clone_hint binutils "$BINUTILS_SRC"
  fail "build_binutils.sh needs a binutils-gdb checkout. Symlink one at ./binutils and re-run."
  exit 1
fi
if [[ -d "$BINUTILS_SRC/.git" ]]; then
  HAVE_PIN="$(cd "$BINUTILS_SRC" && git rev-parse HEAD)"
  if [[ "$HAVE_PIN" == "$BINUTILS_PIN" ]]; then
    ok "at tested pin ${HAVE_PIN:0:12}"
  else
    warn "tree is at ${HAVE_PIN:0:12}, tested pin is ${BINUTILS_PIN:0:12} - building anyway"
  fi
else
  warn "not a git tree - building as-is"
fi

header "Configuring binutils"
( cd "$BINUTILS_SRC" && ./config.guess ) > "$PKG.triplet" 2>/dev/null || true
TRIPLET="$(cat "$PKG.triplet" 2>/dev/null || true)"
rm -f "$PKG.triplet"
if [[ -z "$TRIPLET" ]]; then
  fail "config.guess produced no triplet - cannot determine install layout"
  exit 1
fi
info "triplet: ${C_BOLD}${TRIPLET}${C_RESET} (native, not hardcoded)"

# --prefix=/usr bakes guest-correct absolute paths, DESTDIR keeps the host
# untouched. Without it, ld would bake this host's libdir layout into its
# default SEARCH_DIR list and in-guest links would look in the wrong places.
#
# --disable-gdb: gdb pulls in libdecnumber, readline and
# libsource-highlight, none of which the guest has, and none of which anything
# here links. Dropping them removes most of the build time and the entire
# chance of an unresolved dependency at stage time.
info "./configure --prefix=/usr --without-zstd --disable-debuginfod ..."
( cd "$BINUTILS_SRC" && make distclean > /dev/null 2>&1 || true
  ./configure --prefix=/usr \
    --disable-nls \
    --disable-werror \
    --disable-gdb \
    --disable-gdbserver \
    --disable-sim \
    --disable-libdecnumber \
    --disable-readline \
    --disable-libsource-highlight \
    --disable-debuginfod \
    --without-zstd \
    --disable-multilib > "$SCRIPT_DIR/.binutils-conf.log" 2>&1 && \
  make $JOBS_FLAG all-binutils all-gas all-ld > "$SCRIPT_DIR/.binutils-build.log" 2>&1 && \
  rm -rf "$PKG" && \
  make install-binutils install-gas install-ld DESTDIR="$PKG" >> "$SCRIPT_DIR/.binutils-build.log" 2>&1 ) || {
    fail "binutils build failed - tail of .binutils-build.log:"
    tail -25 "$SCRIPT_DIR/.binutils-build.log" 2>/dev/null | sed 's/^/         /'
    tail -25 "$SCRIPT_DIR/.binutils-conf.log" 2>/dev/null | sed 's/^/         /'
    exit 1
  }
ok "binutils $BINUTILS_VER built and staged to binutils-pkg/"

header "Assembling guest tree"
rm -rf "$BINUTILS_DIST"
mkdir -p "$BINUTILS_DIST/bin"

# The tools gcc's driver and rlt's link line actually exec.
STAGED_TOOLS="as ld ld.bfd ar nm ranlib objcopy strip size strings addr2line elfedit"
MISSING_TOOLS=""
for tool in $STAGED_TOOLS; do
    if [[ -x "$PKG/usr/bin/$tool" ]]; then
      cp -f "$PKG/usr/bin/$tool" "$BINUTILS_DIST/bin/$tool"
    else
      MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done
if [ -n "$MISSING_TOOLS" ]; then
    fail "not built by all-binutils/all-gas/all-ld:$MISSING_TOOLS"
    fail "installed in pkg: $(ls "$PKG/usr/bin" 2>/dev/null | tr '\n' ' ')"
    exit 1
fi
# Strip the staged copies. `strip` here is the HOST's strip acting on the
# freshly linked binaries, not the guest's - this saves ~8MB of the image and
# removes this host's build paths from the shipped tools.
strip --strip-unneeded "$BINUTILS_DIST"/bin/* 2>/dev/null || true
ok "$(ls "$BINUTILS_DIST/bin" | wc -l) tools: $(echo $STAGED_TOOLS)"

# ---- verification ----
header "Checking ELF interpreter"
EXPECT_INTERP="/lib64/ld-linux-x86-64.so.2"
BAD_INTERP=""
for tool in $STAGED_TOOLS; do
    interp="$(readelf -l "$BINUTILS_DIST/bin/$tool" 2>/dev/null \
              | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p' | head -1)"
    if [[ -z "$interp" ]]; then
      BAD_INTERP="$BAD_INTERP $tool(not-an-executable)"
    elif [[ "$interp" != "$EXPECT_INTERP" ]]; then
      BAD_INTERP="$BAD_INTERP $tool($interp)"
    fi
done
if [ -n "$BAD_INTERP" ]; then
    fail "wrong PT_INTERP on:$BAD_INTERP"
    fail "the guest loader is $EXPECT_INTERP - these would not exec in-guest"
    exit 1
fi
ok "all tools: PT_INTERP = $EXPECT_INTERP"

# ---- verification ----
header "Verifying as + ld actually work"
VERIFY="$(mktemp -d)"
trap 'rm -rf "$VERIFY"' EXIT
cat > "$VERIFY/t.s" << 'ASMEOF'
    .text
    .globl  _start
_start:
    mov     $60, %eax        # __NR_exit
    xor     %edi, %edi
    syscall
ASMEOF

if ! "$BINUTILS_DIST/bin/as" --64 -o "$VERIFY/t.o" "$VERIFY/t.s" 2>"$VERIFY/as-err"; then
    fail "staged as cannot assemble a trivial .s - no in-guest compile would work:"
    sed 's/^/         /' "$VERIFY/as-err" | head -10
    exit 1
fi
ok "as assembled a trivial .s"

# link with the exact interpreter the guest uses, so the link records the same
# PT_INTERP a real in-guest link would.
if ! "$BINUTILS_DIST/bin/ld" -m elf_x86_64 -o "$VERIFY/t" "$VERIFY/t.o" 2>"$VERIFY/ld-err"; then
    fail "staged ld cannot link a trivial .o:"
    sed 's/^/         /' "$VERIFY/ld-err" | head -10
    exit 1
fi
N_EMUL="$("$BINUTILS_DIST/bin/ld" -V 2>/dev/null | sed -n '/Supported emulations/,$p' | grep -c 'elf_')"
if ! "$BINUTILS_DIST/bin/ld" -V 2>/dev/null | grep -q 'elf_x86_64'; then
    fail "staged ld does not support elf_x86_64 - nothing could be linked in-guest"
    exit 1
fi
ok "ld linked it (elf_x86_64 present, $N_EMUL emulations)"

if "$VERIFY/t"; then
    ok "as + ld linked AND ran a freestanding binary"
else
    fail "as + ld produced a binary that would not run in-guest"
    exit 1
fi

header "ld default search dirs (guest /usr/lib64 must be reachable)"
"$BINUTILS_DIST/bin/ld" --verbose 2>/dev/null \
    | grep SEARCH_DIR | tr ' ' '\n' | grep -v '^$' | sed 's/^/         /'
if "$BINUTILS_DIST/bin/ld" --verbose 2>/dev/null \
     | grep -qE 'SEARCH_DIR\("=?/usr/lib64"\)'; then
    ok "ld searches /usr/lib64 by default - no -L needed for -lm/-lffi/etc"
else
    fail "ld does NOT default-search /usr/lib64."
    fail "  rlt emits -lm unconditionally and the guest's libs live in"
    fail "  /usr/lib64, so every in-guest link would fail to find it."
    exit 1
fi

# ---- verification ----
header "Shared-library deps (must be libc.so.6 only)"
DEPS_OK=1
for tool in $STAGED_TOOLS; do
    deps="$(ldd "$BINUTILS_DIST/bin/$tool" 2>/dev/null \
            | awk '/=> \//{print $3}' | xargs -r -n1 basename | sort -u)"
    unexpected="$(echo "$deps" | grep -v '^libc\.so\.6$' | grep -v '^$' || true)"
    if [ -n "$unexpected" ]; then
        fail "$(basename "$tool"): unexpected dep(s): $(echo $unexpected)"
        DEPS_OK=0
    fi
done
if [ "$DEPS_OK" = "0" ]; then
    fail "staged tools would fail to exec in-guest for want of those libraries."
    fail "Add the matching --without-* to configure above; do NOT stage the"
    fail "closure into binutils-dist (assemble-rootfs.sh owns /usr/lib64)."
    exit 1
fi
ok "all $(( $(echo $STAGED_TOOLS | wc -w) )) tools depend on libc.so.6 only"

rm -rf "$PKG"
ok "binutils-dist ready ($(du -sh "$BINUTILS_DIST" | cut -f1))"
info "layout:"
find "$BINUTILS_DIST" | sort | sed 's/^/         /'
