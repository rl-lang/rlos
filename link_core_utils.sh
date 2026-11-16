#!/usr/bin/env bash
# link_core_utils.sh - mirror every core-utils applet into rl_programs/.
#
# rl_programs/ is what assemble-rootfs.sh installs into the image, and the
# applets there are SYMLINKS into a core-utils checkout rather than copies.
# That is deliberate: the two trees are edited independently, and a copy step
# that has to be remembered is a copy step that eventually is not, which shows
# up as an image running a program that does not match either source.
#
# Run this after adding or renaming a program in core-utils:
#
#     ./link_core_utils.sh
#
# It is idempotent, so running it after every core-utils change is harmless.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
source "$HERE/build-lib.sh"

PROGRAMS="$HERE/rl_programs"
# Sibling checkout. Overridable so the tree can be tested from elsewhere.
CORE_UTILS="${CORE_UTILS:-$HERE/../core-utils}"

usage() {
    cat << EOF
usage: link_core_utils.sh [-h|--help]

  Mirrors \$CORE_UTILS/*/<name>.rl into rl_programs/<name>.rl as relative
  symlinks. CORE_UTILS defaults to ../core-utils.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

[[ -d "$CORE_UTILS" ]] || fail "core-utils not found at $CORE_UTILS"
[[ -d "$PROGRAMS" ]]   || fail "rl_programs not found at $PROGRAMS"
CORE_UTILS="$(realpath "$CORE_UTILS")"
PROGRAMS="$(realpath "$PROGRAMS")"

# Source path inside core-utils for an applet. Most are <name>/<name>.rl, but
# rlsh is <name>/main.rl, so this cannot be pure convention.
source_for() {
    local name="$1"
    if [[ "$name" == "rlsh" ]]; then
        printf '%s/rlsh/main.rl' "$CORE_UTILS"
    else
        printf '%s/%s/%s.rl' "$CORE_UTILS" "$name" "$name"
    fi
}

# Link path inside rl_programs. nano keeps its subdirectory because its build
# inputs (nano.c, rl_runtime.c) live there.
link_for() {
    local name="$1"
    if [[ "$name" == "nano" ]]; then
        printf '%s/nano/nano.rl' "$PROGRAMS"
    else
        printf '%s/%s.rl' "$PROGRAMS" "$name"
    fi
}

created=0; updated=0; same=0; skipped=0

header "Linking core-utils applets"
for dir in "$CORE_UTILS"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    src="$(source_for "$name")"
    link="$(link_for "$name")"

    # An applet directory with no source yet is a work in progress, not a
    # failure. Say so, so an empty directory does not look like a linked applet.
    if [[ ! -f "$src" ]]; then
        info "skip $name (no ${src##*/})"
        skipped=$((skipped + 1))
        continue
    fi

    # Relative to the link's OWN directory, so nested links (nano/) get the
    # extra "../" they need. Absolute links would work here and break the moment
    # the checkout moves.
    rel="$(realpath --relative-to="$(dirname "$link")" "$src")"
    mkdir -p "$(dirname "$link")"

    if [[ -L "$link" ]]; then
        if [[ "$(readlink "$link")" == "$rel" ]]; then
            same=$((same + 1))
            continue
        fi
        ln -sfn "$rel" "$link"
        substep "relinked ${link#"$PROGRAMS"/} -> $rel"
        updated=$((updated + 1))
        continue
    fi

    if [[ -e "$link" ]]; then
        # A real file here is either a program core-utils does not carry, or a
        # local variant. Neither should be replaced by a script whose whole job
        # is to add links.
        warn "${link#"$PROGRAMS"/} is a regular file, not a link - leaving it alone"
        skipped=$((skipped + 1))
        continue
    fi

    ln -s "$rel" "$link"
    substep "linked ${link#"$PROGRAMS"/} -> $rel"
    created=$((created + 1))
done

# Dangling links are the failure this script exists to prevent: they make
# assemble-rootfs.sh install fewer programs than the tree appears to have.
broken=0
while IFS= read -r -d '' link; do
    if [[ ! -e "$link" ]]; then
        errmsg "broken link ${link#"$PROGRAMS"/} -> $(readlink "$link")"
        broken=$((broken + 1))
    fi
done < <(find "$PROGRAMS" -name '*.rl' -type l -print0)
if [[ "$broken" -ne 0 ]]; then
    fail "$broken link(s) do not resolve - fix the targets above"
fi

ok "$created created, $updated updated, $same already correct, $skipped skipped"
info "next: ./assemble-rootfs.sh copies these into the image"
