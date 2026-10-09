#!/usr/bin/env bash
# build_busybox.sh - build busybox for the rlos guest
#
# Why busybox is here
# -------------------
# The guest's userspace is rl-lang, and rl programs cover only the basics
# (sh, ls, rm, wc, whoami, hostname, log, shutdown, reboot, ...). That leaves
# ~22 everyday commands missing entirely: cat, cp, mv, grep, sed, find, ps,
# kill, mkdir, head, tail, du, df, date, chmod and so on. Those are not
# interesting to reimplement in rl and they are not what makes rlOS rlOS.
#
# busybox is the standard answer: one static binary, every applet, about 2MB.
# git and gcc are already vendored C toolchains here, so a vendored C tool is
# not a departure from how this project works.
#
# What lands in the guest
# -----------------------
#   bin/busybox              the static binary
#   bin/<applet>             one symlink per applet, named exactly as busybox
#                            names it, so `cat` is busybox's cat
#   bin/rescue               busybox's ash under a name that says what it is
#
# applets already implemented in rl (and the git/gcc links) are NOT symlinked,
# so the rl version wins and busybox's stays available as `busybox ls`. The
# exclusion list is in build_busybox.sh (EXCLUDE_APPLETS) and is mirrored in
# assemble-rootfs.sh, which creates the links.
#
# rlsh stays the login shell everywhere (init.c sets SHELL=/bin/rlsh). busybox's
# ash is reachable as `rescue`, deliberately not as `sh`.
#
# Usage:
#   ./build_busybox.sh               # build (default)
#   ./build_busybox.sh -j 8          # 8 parallel jobs
#   ./build_busybox.sh --clean       # remove busybox-dist/ first
#
# Needs on the host: gcc, make, curl, python3, file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BB_VER="1.37.0"
BB_TAR="busybox-${BB_VER}.tar.bz2"
BB_URL="https://busybox.net/downloads/${BB_TAR}"
BB_SRC="$SCRIPT_DIR/busybox-src"
BB_DIST="$SCRIPT_DIR/busybox-dist"
CLEAN=0
JOBS=""

# --- Colors ---
if [ -t 1 ] && [ -t 2 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_CYAN=$'\e[36m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

info()  { printf "${C_DIM}  ::${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}  [ OK ]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}  [FAIL]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}  [WARN]${C_RESET} %s\n" "$*"; }
header(){ printf "\n${C_BOLD}${C_CYAN}:: %s${C_RESET}\n" "$*"; }

# Sourced after the message helpers so pin failures report through fail().
# shellcheck source=pins.sh
source "$SCRIPT_DIR/pins.sh"

usage() {
  printf "\n${C_BOLD}Usage:${C_RESET} ${C_CYAN}build_busybox.sh${C_RESET} [OPTIONS]\n"
  printf "  ${C_GREEN}-j, --jobs${C_RESET} ${C_CYAN}N${C_RESET}       Number of parallel jobs\n"
  printf "  ${C_RED}--clean${C_RESET}           Remove busybox-dist/ before building\n"
  printf "  ${C_BLUE}-h, --help${C_RESET}         This help\n\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs) JOBS="$2"; shift 2 ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) fail "unknown option: $1"; exit 1 ;;
  esac
done

if [ "$CLEAN" = "1" ]; then
  header "Cleaning"
  rm -rf "$BB_DIST"
  ok "cleaned"
fi

for t in gcc make curl python3 file; do
  command -v "$t" > /dev/null 2>&1 || { fail "$t not found on PATH"; exit 1; }
done

JOBS_FLAG=""
[ -n "$JOBS" ] && JOBS_FLAG="-j $JOBS"

# Applets to leave out of the .config entirely, not merely out of the symlink
# list.
#
# INIT: rlOS has its own init, and a busybox "init" sitting in /bin is one
# confused boot away from taking over PID 1.
#
# TC: does not compile against a modern kernel. networking/tc.c uses TCA_CBQ_*,
# TCA_CBQ_RATE, struct tc_cbq_lssopt and friends, which were removed from the
# kernel's UAPI headers when CBQ traffic shaping was dropped upstream:
#   networking/tc.c:236:27: error: 'TCA_CBQ_MAX' undeclared
#   networking/tc.c:261:16: error: invalid application of 'sizeof' to incomplete
# This is a busybox bug against current headers, not a config mistake, and tc is
# a traffic shaper - there is no network stack in the guest to shape.
EXCLUDE_APPLETS="INIT TC"

header "Source"
mkdir -p "$BB_SRC"
if [ ! -f "$BB_SRC/$BB_TAR" ]; then
  info "downloading $BB_TAR"
  curl -fL --retry 3 --retry-delay 2 --max-time 300 -o "$BB_SRC/$BB_TAR" "$BB_URL" \
    || { fail "download failed: $BB_URL"; exit 1; }
else
  info "have $BB_TAR"
fi
# Verified whether cached or freshly downloaded: a truncated busybox tarball
# otherwise fails much later as a missing APPLYTS or a bad defconfig, which
# points at the build rather than at the download.
pins_verify "$BB_SRC/$BB_TAR" busybox

if [ ! -d "$BB_SRC/busybox-${BB_VER}" ]; then
  info "extracting"
  tar -xjf "$BB_SRC/$BB_TAR" -C "$BB_SRC"
fi
BB_TREE="$BB_SRC/busybox-${BB_VER}"
[ -d "$BB_TREE" ] || { fail "source tree $BB_TREE missing after extract"; exit 1; }

# busybox 1.37 ships one top-level Config.in and per-package Config.src files;
# the real */Config.in files are GENERATED from the //config: markers in the .c
# sources by gen_build_files.sh, which needs SRCTREE and OBJTREE as arguments.
# Without this there is exactly one Config.in in the tree and every applet
# symbol is undefined.
header "Generating Kconfig files"
( cd "$BB_TREE" && bash scripts/gen_build_files.sh "$(pwd)" "$(pwd)" ) > /dev/null 2>&1 || true
N_CFG="$(find "$BB_TREE" -name Config.in | wc -l)"
if [ "$N_CFG" -lt 5 ]; then
  fail "only $N_CFG Config.in files after gen_build_files.sh - applet symbols would be empty"
  exit 1
fi
ok "$N_CFG Config.in files generated"

header "Choosing applets"
# busybox declares every applet as
#     config SYMBOL
#         bool "appletname (12 kb)"
# so the size-in-kb suffix in the prompt is what distinguishes an applet from a
# feature (CONFIG_ASYNC, CONFIG_DESKTOP and friends have no such suffix).
# Deriving the list instead of hand-maintaining 400 symbols means a new busybox
# release picks up its new applets automatically.
APPL_CONF="$BB_DIST.applets.conf"
python3 - "$BB_TREE" "$APPL_CONF" "$EXCLUDE_APPLETS" << 'PYEOF'
import glob, os, re, sys
tree, out, exclude = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
applets = {}
for f in glob.glob(os.path.join(tree, '**', 'Config.in'), recursive=True):
    if os.path.abspath(f) == os.path.abspath(os.path.join(tree, 'Config.in')):
        continue  # the top-level file declares settings, not applets
    lines = open(f, errors='replace').read().split('\n')
    for i, line in enumerate(lines[:-1]):
        m = re.match(r'config ([A-Z0-9_]+)$', line.strip())
        if not m:
            continue
        b = re.match(r'\s*bool "([^"]+)"', lines[i + 1])
        if b and re.search(r'\(\d+(\.\d+)? (kb|KB)\)', b.group(1)):
            applets[m.group(1)] = b.group(1)

# An excluded applet has to be written out as explicitly OFF, not merely left
# out. Most busybox applets are declared
#     config TC
#         bool "tc (8.3 kb)"
#         default y
# so a symbol absent from .config is simply given its default by oldconfig -
# which means "omit it to exclude it" silently ENABLES it. That is exactly what
# happened the first time round: TC was left out of the list and came back as
# CONFIG_TC=y, and the build then failed on the undeclared TCA_CBQ_* UAPI.
with open(out, 'w') as fh:
    fh.write('# generated by build_busybox.sh - applet config symbols\n')
    for s in sorted(applets):
        if s in exclude:
            fh.write('# CONFIG_%s is not set\n' % s)
        else:
            fh.write('CONFIG_%s=y\n' % s)
print("         %d applets found, %d excluded (%s), %d enabled"
      % (len(applets), len(set(applets) & exclude),
         ','.join(sorted(set(applets) & exclude)),
         len(set(applets) - exclude)))
PYEOF
[ -s "$APPL_CONF" ] || { fail "no applets selected - refusing to build an empty busybox"; exit 1; }

header "Configuring"
pushd "$BB_TREE" > /dev/null
# Write a .config containing ONLY the symbols we want, overwriting whatever was
# there, and let oldconfig resolve it into the full canonical config.
#
# The obvious alternative - `make allnoconfig` then `cat >> .config` - is wrong:
# allnoconfig already writes every symbol out as "# CONFIG_X is not set", so
# appending CONFIG_X=y leaves each symbol listed twice and kconfig rejects the
# file with
#   .config:1205:warning: trying to reassign symbol ACPID
# ...for all 411 of them, and quietly discards everything. oldconfig then
# reports success and CONFIG_STATIC comes back unset. A .config that mentions
# only the symbols we care about is accepted as-is.
cat "$APPL_CONF" > .config
# Core requirements that are not applets, so the applet scan above misses them.
cat >> .config << 'CFGEOF'
# --- core requirements, not applets ---
CONFIG_STATIC=y
CONFIG_SH_IS_ASH=y
CONFIG_FEATURE_SH_STANDALONE=y
CONFIG_DESKTOP=y
CONFIG_LONG_OPTS=y
CONFIG_FEATURE_VERBOSE_USAGE=y
CFGEOF
yes '' 2>/dev/null | make oldconfig > /tmp/opencode/busybox-oldconfig.log 2>&1 || true
# kconfig drops unsatisfiable symbols without failing, so check the ones that
# would silently change the shape of the build.
REASSIGN="$(grep -c 'reassign symbol' /tmp/opencode/busybox-oldconfig.log || true)"
if [ "$REASSIGN" -ne 0 ]; then
  fail "oldconfig rejected the config ($REASSIGN duplicate symbols):"
  grep 'reassign symbol' /tmp/opencode/busybox-oldconfig.log | head -5 | sed 's/^/         /'
  popd > /dev/null; exit 1
fi
if ! grep -qx 'CONFIG_STATIC=y' .config; then
  fail "CONFIG_STATIC did not survive oldconfig - busybox would need host libc"
  popd > /dev/null; exit 1
fi
# The excluded applets must actually be off. Because applet symbols are declared
# `default y`, an exclusion that does not take effect here shows up much later as
# a compile error against host UAPI headers, a long way from the cause.
for ex in $EXCLUDE_APPLETS; do
  if grep -qx "CONFIG_${ex}=y" .config; then
    fail "excluded applet $ex is enabled in .config (applet symbols are 'default y',"
    fail "so the exclusion did not take) - busybox will fail to compile"
    popd > /dev/null; exit 1
  fi
done
ok "config resolved ($(grep -c '^CONFIG_.*=y' .config) symbols enabled)"

header "Building"
info "this can take a while..."
if ! make $JOBS_FLAG > /tmp/opencode/busybox-build.log 2>&1; then
  fail "make failed - tail of the log:"
  tail -25 /tmp/opencode/busybox-build.log | sed 's/^/         /'
  popd > /dev/null; exit 1
fi
popd > /dev/null

header "Staging"
rm -rf "$BB_DIST"
mkdir -p "$BB_DIST/bin"
cp "$BB_TREE/busybox" "$BB_DIST/bin/busybox"
chmod 755 "$BB_DIST/bin/busybox"

header "Verification"
# The guest has no busybox-compatible loader setup for a dynamic binary beyond
# what assemble-rootfs.sh stages, and a static binary is what initramfs tools
# should be anyway. `file` saying "dynamically linked" here is a hard stop.
if file "$BB_DIST/bin/busybox" | grep -q 'dynamically linked'; then
  fail "busybox is dynamically linked - expected a static binary"
  exit 1
fi
ok "static binary ($(du -h "$BB_DIST/bin/busybox" | cut -f1))"

# The applet list must come from the binary that was just built, not from the
# config we asked for: oldconfig drops unsatisfiable symbols silently, and
# assemble-rootfs.sh will symlink exactly what is written here.
"$BB_DIST/bin/busybox" --list | sort > "$BB_DIST/APPLYTS"
N_APPLETS="$(wc -l < "$BB_DIST/APPLYTS")"
if [ "$N_APPLETS" -lt 200 ]; then
  fail "only $N_APPLETS applets built - expected the full set"
  exit 1
fi
for must in ash cat grep sed find ps kill mount cp mv mkdir chmod; do
  grep -qx "$must" "$BB_DIST/APPLYTS" || { fail "applet '$must' missing from the build"; exit 1; }
done
ok "$N_APPLETS applets available (busybox-dist/APPLYTS)"

# `rescue` cannot be a symlink. busybox dispatches on argv[0]
# (libbb/appletlib.c: bb_get_last_path_component_nostrip) and there is no
# applet named "rescue", so a link would fail with
#   rescue: applet not found
# and exit 127. The interpreter in the shebang is what makes this work: the
# kernel execs /bin/busybox with argv[1]="ash", and busybox's own comment on
# that code path says it exists to allow "#!/bin/busybox"-style wrappers.
cat > "$BB_DIST/bin/rescue" << 'RESEOF'
#!/bin/busybox ash
# rescue - an emergency shell, this is busybox's ash.
#
# Not the login shell: init.c sets SHELL=/bin/rlsh and rlsh stays the default
# everywhere. This exists for when rlsh itself will not start, so it depends on
# nothing but the busybox binary sitting next to it.
exec /bin/busybox ash "$@"
RESEOF
chmod 755 "$BB_DIST/bin/rescue"
ok "rescue -> busybox ash"

header "Results"
ok "busybox ready ($(du -sh "$BB_DIST" | cut -f1))"
info "applets: $N_APPLETS"
info "excluded from the config: $EXCLUDE_APPLETS"
echo
info "next: assemble-rootfs.sh copies busybox-dist/ and symlinks the applets."