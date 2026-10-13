#!/usr/bin/env bash
# build-lib.sh - the terminal output vocabulary shared by every rlos build,
# packaging and verification script.
#
# SOURCE THIS FILE. Do not execute it.
#
#   top-level script:  source "$(dirname "${BASH_SOURCE[0]}")/build-lib.sh"
#   subdirectory:      source "$(dirname "${BASH_SOURCE[0]}")/../build-lib.sh"
#
# Resolve that path BEFORE any `cd` in the caller: after a cd, a relative
# BASH_SOURCE no longer resolves, which is the same trap that broke
# rlos-disk/install.sh's SCRIPT_DIR.
#
# THE VOCABULARY
# --------------
#   header  "Xorg server 21.1.24"    a section. Bold cyan, blank line above.
#   step    "meson setup"            >>>         one level in
#   substep "libXpm: unpacking"      --->>>      two levels in
#   detail  "writing config"         ------>>>  three or more
#   info    "root=/ is on nvme0"    ::          a plain fact
#   ok      "i3 built"               [ OK ]      green
#   warn    "pinned v0.12"           [WARN]      yellow, on stderr
#   fail    "libXft not built"       [FAIL]      red, on stderr, exits 1
#   die     synonym for fail
#
# WHY ONE FILE
# ------------
# Every script used to carry its own copy of these functions, and they had
# drifted into four dialects: "== msg ==", ":: *", ":: msg", and a broken
# header() that printed a literal "::*" and discarded its argument, so the
# section title never appeared at all. One definition cannot drift from the
# others, and fixing header() fixes it everywhere at once.
#
# The nesting marker scales: 0 dashes at level 1, 3 at level 2, 6 at level 3.
# Use whichever depth the surrounding output calls for; there is no limit.
#
# Colour turns itself off when stdout is not a TTY (so a build log in a file or
# a pipe is plain text), or when NO_COLOR is set (https://no-color.org).

# --- colour ---
# Exported under two names because the scripts that predate this file used two
# conventions: the C_* names and the bare RED/GRN/YLW/DIM/RST names.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\e[1m';      C_DIM=$'\e[2m';       C_RESET=$'\e[0m'
  C_CYAN=$'\e[36m';     C_GREEN=$'\e[32m';    C_YELLOW=$'\e[33m'
  C_RED=$'\e[31m';      C_BLUE=$'\e[34m';     C_MAGENTA=$'\e[35m'
else
  C_BOLD=""; C_DIM=""; C_RESET=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""
  C_RED=""; C_BLUE=""; C_MAGENTA=""
fi
RED="$C_RED"; GRN="$C_GREEN"; YLW="$C_YELLOW"; DIM="$C_DIM"; RST="$C_RESET"

# nest <level> - the indentation marker for one nesting level, e.g. ">>> " at
# 1 and "--->>> " at 2. Level 0 or absent gives the bare marker.
nest() {
  local n=$(( (${1:-1} - 1) * 3 ))
  [ "$n" -gt 0 ] 2>/dev/null || n=0
  printf '%s>>> ' "$(printf '%*s' "$n" '' | tr ' ' '-')"
}

# --- sections and nesting ---
header() { printf '\n%s%s:: %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }
step()   { printf '  %s%s%s%s\n' "$C_CYAN" "$(nest 1)" "$*" "$C_RESET"; }
substep(){ printf '  %s%s%s%s\n' "$C_DIM"  "$(nest 2)" "$*" "$C_RESET"; }
detail() { printf '  %s%s%s%s\n' "$C_DIM"  "$(nest 3)" "$*" "$C_RESET"; }

# --- progress ---
# run_quiet <cmd...> - run quietly, printing the last 25 lines only on failure.
#
# Tool chatter is the enemy of a readable build log. xorriso alone prints a
# dozen lines of drive/media/UPDATE progress for an operation that either
# worked or did not; meson and ninja print hundreds more. Buried among them
# the build's own output becomes unreadable, so the chatter goes to a
# temporary file and the tail is shown only if the command fails.
run_quiet() {
    local log rc=0
    log="$(mktemp)"
    "$@" > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$log"
        return 0
    fi
    fail "failed: $*"
    tail -25 "$log" | sed 's/^/         /'
    rm -f "$log"
    return "$rc"
}

# watch_growth <file> <label> - print "<label>: <size> (<n>s)" every few seconds
# while <file> grows, on stderr, until killed.
#
# WHY A SEPARATE BACKGROUND PROCESS. The slow steps in these builds are
# pipelines - `tar ... | gzip -9n > out`, `find | cpio | gzip > out` - and bash
# cannot hand a pipeline to a function, so the watcher does not own the command.
# It runs alongside it:
#
#     watch_growth "$OUT" "initramfs.gz" & WATCH=$!
#     find . | cpio | gzip > "$OUT"
#     kill "$WATCH" 2>/dev/null; wait "$WATCH" 2>/dev/null || true
#
# Only prints when the size actually changed, so a finished or tiny file does
# not scroll. A step that is silent for minutes is indistinguishable from a
# hang otherwise, and the instinct is to Ctrl-C a build that is working.
watch_growth() {
    local f="$1" label="$2" t0 last="" size
    t0=$(date +%s)
    while :; do
        sleep 3
        size="$([ -e "$f" ] && du -h "$f" 2>/dev/null | cut -f1 || true)"
        [ -z "$size" ] && continue
        if [ "$size" != "$last" ]; then
            printf '    %s%s: %s (%ds elapsed)%s\n' \
                "$C_DIM" "$label" "$size" "$(( $(date +%s) - t0 ))" "$C_RESET" >&2
            last="$size"
        fi
    done
}

# --- status ---
info() { printf '  %s::%s %s\n'   "$C_DIM"    "$C_RESET" "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '  %s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
die()  { fail "$@"; }

# errmsg - the [FAIL] line of a diagnostic that continues. fail() exits, so a
# caller with cleanup to do (a popd, a trap to run, further explanation to
# print) uses errmsg for the first line and plain echo >&2 for the rest, then
# exits itself.
errmsg() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }