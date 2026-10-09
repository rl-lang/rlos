#!/usr/bin/env bash
# pins.sh - shared access to pins.lock
#
# Sourced by the build scripts. This is deliberately NOT a script you run: it
# defines three functions and nothing else happens at source time.
#
# Every build script has its own colour helpers (fail/info/warn) and its own
# fetch() or $FETCHER, so this file does not depend on any of them. It only
# needs sha256sum and git on PATH.
#
#   pins_get   <key>            -> value, or empty if absent
#   pins_fetch <url> <dest> <key>  -> fetch if absent, then verify sha256
#   pins_verify <file> <key>    -> verify an already-present file
#
# Every verification failure aborts the build and names both hashes. A silently
# wrong tarball is worse than a failed build: it produces an image that boots
# and misbehaves three weeks later.

PINS_LOCK="${PINS_LOCK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pins.lock}"
PINS_LOADED=""

# _pins_die <msg...> - abort. Scripts that source this define their own fail(),
# so use it when present and fall back to stderr otherwise.
_pins_die() {
    if command -v fail >/dev/null 2>&1; then
        fail "$@"
    else
        printf 'error: %s\n' "$*" >&2
    fi
    exit 1
}

_pins_info() {
    if command -v info >/dev/null 2>&1; then
        info "$@"
    else
        printf '  %s\n' "$*" >&2
    fi
}

# pins_get <key> - look up a key in the [git] or [tarball] section.
pins_get() {
    local key="$1"
    [ -n "$PINS_LOADED" ] || _pins_load
    printf '%s\n' "${PINS_VALUES[$key]:-}"
}

# _pins_load - parse pins.lock into PINS_VALUES once per shell.
#
# keys are unique across both sections because the namespace encodes the type
# (.sha / .repo / .url / .sha256 / .note), so a flat map cannot collide.
_pins_load() {
    if [ ! -r "$PINS_LOCK" ]; then
        _pins_die "pins.lock not readable at $PINS_LOCK"
    fi
    declare -gA PINS_VALUES=()
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*|'['*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        PINS_VALUES["$key"]="$value"
    done < "$PINS_LOCK"
    PINS_LOADED=1
}

# _pins_sha256 <file> - print the hash, or empty if we cannot compute one.
_pins_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1
    else
        return 1
    fi
}

# pins_verify <file> <key> - check <file> against the sha256 recorded under
# <key> in pins.lock. A missing pin is an error: it means an upstream was added
# to a build script without being recorded, which is exactly the drift this file
# exists to prevent.
pins_verify() {
    local file="$1" key="$2"
    local want got

    [ -f "$file" ] || _pins_die "pins_verify: no such file: $file"

    want="$(pins_get "${key}.sha256")"
    if [ -z "$want" ]; then
        _pins_die "no sha256 for '$key' in $PINS_LOCK - record it before building"
    fi

    got="$(_pins_sha256 "$file")" || _pins_die "need sha256sum or shasum to verify $key"

    if [ "$got" != "$want" ]; then
        _pins_die "$key sha256 mismatch for $(basename "$file")
  expected $want
  actual   $got
  This is upstream content that does not match pins.lock. Either the URL now
  serves something else, or the file is truncated or tampered with. Refusing
  to continue - an image built from unverified input is not reproducible."
    fi
    return 0
}

# pins_fetch <url> <dest> <key> - download <url> to <dest> if <dest> is absent,
# then verify. An existing file is still verified, so a corrupted or
# half-downloaded cache is caught rather than silently reused.
#
# If the calling script already has a fetch() or $FETCHER, prefer calling that
# and then pins_verify; this exists for the scripts that have neither.
pins_fetch() {
    local url="$1" dest="$2" key="$3"
    local name
    name="$(basename "$dest")"

    if [ -f "$dest" ]; then
        _pins_info "have $name"
    else
        _pins_info "fetching $name"
        command -v curl >/dev/null 2>&1 \
            || _pins_die "need curl to fetch $key"
        # Download to a .part first so an interrupted transfer never leaves a
        # truncated file that a later run treats as a valid cache hit.
        curl -fL --retry 3 --retry-delay 2 --max-time 300 \
            -o "${dest}.part" "$url" \
            || { rm -f "${dest}.part"; _pins_die "download failed: $url"; }
        mv -f "${dest}.part" "$dest" || _pins_die "could not move $name into place"
    fi

    pins_verify "$dest" "$key"
}

# pins_clone <repo> <srcdir> <key> [--recursive]
#
# Clone-and-pin for git upstreams. A `--depth 1` clone cannot check out an
# arbitrary SHA, because a shallow clone only carries the branch tip, so this
# clones full history and lets git fetch the pinned commit if it is missing.
#
# The post-checkout rev-parse assertion is the point: if upstream force-pushed
# and the pin is no longer reachable, the build stops here naming both SHAs
# rather than building whatever master now points at.
pins_clone() {
    local repo="$1" srcdir="$2" key="$3" recursive="${4:-}"
    local want got rc=0

    want="$(pins_get "${key}.sha")"
    [ -n "$want" ] || _pins_die "no sha for '$key' in $PINS_LOCK - record it before building"

    if [ ! -d "$srcdir/.git" ]; then
        _pins_info "cloning $key (pinned commit)"
        rm -rf "$srcdir"
        # shellcheck disable=SC2086
        git clone --quiet $recursive "$repo" "$srcdir" \
            || _pins_die "$key clone failed: $repo"
    fi

    if ! git -C "$srcdir" cat-file -e "${want}^{commit}" 2>/dev/null; then
        _pins_info "fetching pinned commit for $key"
        # shellcheck disable=SC2086
        git -C "$srcdir" fetch --quiet --tags $recursive origin \
            || _pins_die "$key fetch failed - the pinned commit may have been garbage-collected upstream"
    fi

    git -C "$srcdir" checkout --quiet --force "$want" 2>/dev/null || rc=1
    [ "$rc" -eq 0 ] || _pins_die "$key has no commit $want - the pin is wrong or was rewritten"

    got="$(git -C "$srcdir" rev-parse HEAD 2>/dev/null)"
    [ "$got" = "$want" ] \
        || _pins_die "$key at $got, expected $want"

    _pins_info "$key at ${want:0:12}"
    return 0
}

# pins_checkout <srcdir> <key> - verify an existing checkout is at its pin
# without cloning or fetching. Used for the trees you symlink in by hand
# (gcc, binutils, git, rl-lang), so the build can tell you when you are on the
# wrong commit instead of quietly producing a different toolchain.
pins_checkout() {
    local srcdir="$1" key="$2"
    local want got
    want="$(pins_get "${key}.sha")"
    [ -n "$want" ] || _pins_die "no sha for '$key' in $PINS_LOCK"
    [ -e "$srcdir/.git" ] || return 1
    got="$(git -C "$srcdir" rev-parse HEAD 2>/dev/null)"
    [ "$got" = "$want" ]
}

# pins_warn_drift <srcdir> <key> - advisory version of pins_checkout: prints a
# warning and returns 0. For symlinked trees, where being on a different commit
# is the user's business (they may be mid-development) but silently building a
# different toolchain is not something they intended.
pins_warn_drift() {
    local srcdir="$1" key="$2"
    local want got
    want="$(pins_get "${key}.sha")"
    got="$(git -C "$srcdir" rev-parse HEAD 2>/dev/null)"
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
        if command -v warn >/dev/null 2>&1; then
            warn "$key is at ${got:0:12}, pins.lock says ${want:0:12} - building with the checked-out tree"
        else
            printf 'warning: %s is at %.12s, pins.lock says %.12s\n' \
                "$key" "$got" "$want" >&2
        fi
        return 0
    fi
    return 0
}

# pins_clone_hint <key> <path> - the two-line "clone this, symlink it" message
# used by the build scripts that refuse to continue without a hand-made
# symlink. Generated from the lock so the suggested command always names the
# pinned commit instead of whatever the tree looked like when it was written.
pins_clone_hint() {
    local key="$1" path="$2"
    local repo want
    repo="$(pins_get "${key}.repo")"
    want="$(pins_get "${key}.sha")"
    [ -n "$repo" ] || return 0
    printf 'no %s tree at %s - symlink it first:\n' "$key" "$path" >&2
    printf '  git clone %s <dir>\n' "$repo" >&2
    printf '  git -C <dir> checkout %s\n' "${want:0:12}" >&2
    printf '  ln -s <dir> %s\n' "$path" >&2
    printf '  (the pinned commit is %s in pins.lock)\n' "${want:0:12}" >&2
}
