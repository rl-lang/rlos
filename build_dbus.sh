#!/usr/bin/env bash
# build_dbus.sh - stage the D-Bus system bus.
#
# WHY THIS IS BUILT FIRST, BEFORE iwd AND BLUETOOTH.
#
# The obvious plan is "wireless and bluetooth", and it is tempting to start with
# iwd. But iwctl is only a D-Bus *client*: it does not touch the radio, it asks
# iwd to do it, and the only channel between them is the system bus. The same is
# true of bluetoothctl talking to bluetoothd. So there is no version of this work
# in which D-Bus is optional, and building it first means the two daemons can be
# tested against a bus that is already known to work, rather than two new things
# at once.
#
# It also settles a design question without needing a setuid helper. iwd has to
# run as root - it drives the interface directly - and iwctl must not. On a
# system with no working sudo helper on a TTY, "run the client as the user, give
# the daemon privilege" is only expressible over a bus that already does exactly
# that, which is the point of having it.
#
# WHY COPIED FROM THE HOST RATHER THAN BUILT.
# D-Bus is a C library plus three thin executables, it is already present on the
# build host, and it has a three-library dependency closure that the rest of this
# image already stages (libc, libexpat, and libdbus itself). Building it from
# source would add a meson dependency and a build directory to reproduce a binary
# that is already on the machine doing the building. iwd and BlueZ are different
# cases and are built from source.
#
# What is NOT copied:
#   - the host's /etc/dbus-1/system.conf. It includes SELinux policy and
#     distro-specific service directories, and baking a host's config into an
#     image is how you get a bus that starts and then refuses every connection.
#     The config is written fresh below, minimal, from what this image needs.
#   - the host's machine-id, for the reason in the note beside it below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dbus-dist"
ETC="$DIST/etc"
# Staged at /etc/dbus-1/system.conf to match the --config-file init passes and the
# path dbus-daemon treats as conventional. A different directory here means the
# daemon is handed a path that does not exist.
CONF_DIR="$DIST/etc/dbus-1"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
header() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }
info()  { printf '%s  %s%s\n' "$GRN" "$1" "$RST"; }
warn()  { printf '%s  %s%s\n' "$YLW" "$1" "$RST"; }
die()   { printf '%serror:%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST/usr/bin" "$DIST/usr/lib64" "$DIST/usr/share/dbus-1/system-services" "$CONF_DIR" "$ETC"

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------
header "binaries"
# dbus-daemon  the system bus daemon. This is the only one that is mandatory;
#              the other two are conveniences that would otherwise be missing
#              from a system where D-Bus is the substrate for everything else.
# dbus-uuidgen generates a machine-id. Kept because init needs to mint one on
#              first boot and doing it in C is cheaper than doing it in shell.
# dbus-send    lets a user poke the bus by hand. Without it, "is the bus up?" has
#              no answer that does not involve writing a program.
for tool in dbus-daemon dbus-uuidgen dbus-send; do
    src="$(command -v "$tool" 2>/dev/null)" || die "$tool not found on PATH"
    cp -L "$src" "$DIST/usr/bin/$tool"
    chmod 755 "$DIST/usr/bin/$tool"
    info "$tool staged ($(stat -c%s "$DIST/usr/bin/$tool") bytes)"
done

# ---------------------------------------------------------------------------
# ldd closure
# ---------------------------------------------------------------------------
header "ldd closure"
# Flat, by SONAME, into usr/lib64 - which is in the loader's default search path,
# so no RPATH and no ld.so.cache are needed. Resolved from the COPIED files so
# the closure is exactly what ships.
CLOSURE=""
collect() {
    local target="$1" lib
    for lib in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
        case " $CLOSURE " in *" $lib "*) continue ;; esac
        CLOSURE="$CLOSURE $lib"
        collect "$lib"
    done
}
for elf in "$DIST"/usr/bin/*; do collect "$elf"; done
n=0
for lib in $CLOSURE; do
    base="$(basename "$lib")"
    cp -L "$lib" "$DIST/usr/lib64/$base" 2>/dev/null || { warn "skipped $base"; continue; }
    n=$((n + 1))
done
info "closure: $n libraries ($(du -sh "$DIST/usr/lib64" | cut -f1))"

# ---------------------------------------------------------------------------
# machine-id
# ---------------------------------------------------------------------------
header "machine-id"
# NOT written here, and that omission is deliberate.
#
# The machine-id is the bus's identity. Two systems with the same one are the
# same system as far as D-Bus is concerned, so an image that ships one baked in
# gives every machine booted from it an identical identity - and any two of them
# on the same network will collide. The canonical advice is "delete /etc/machine-id
# from the image so it is generated on first boot", which is exactly right and
# is why this file simply does not exist after this script runs.
#
# init.c generates it on first boot instead. See machine_id_ensure() there.
if [ -e "$ETC/machine-id" ]; then
    die "machine-id exists in dist - it must be generated at boot, never baked"
fi
info "left absent on purpose: init.c generates it on first boot"

# ---------------------------------------------------------------------------
# system.conf
# ---------------------------------------------------------------------------
header "system.conf"
# Written fresh rather than copied, and deliberately much smaller than a distro's.
#
# Every policy the host ships is about letting packaged services own well-known
# names. This image has three D-Bus clients that it starts itself, so the only
# rules needed are: allow the bus to own its own name, and let anything that has
# successfully connected call methods. Anything more would be a policy written
# for a different system.
cat > "$CONF_DIR/system.conf" << 'CONF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>

  <!-- Only the system bus is run. There is no session bus: this is a live
       system with one user, and a per-user session bus would add a second
       daemon, a second socket and a second identity to keep working. -->
  <type>system</type>
  <listen>unix:path=/run/dbus/system_bus_socket</listen>

  <!-- Policy is deliberately permissive within the system bus. The bus is only
       reachable by processes already inside this system, and the alternative -
       a per-service allowlist - means every daemon added later is silently
       non-functional until someone remembers to edit a policy file. -->
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_type="method_call"/>
    <allow send_type="signal"/>
    <allow send_type="method_return"/>
    <allow send_type="error"/>
    <allow receive_type="method_call"/>
    <allow receive_type="method_return"/>
    <allow receive_type="error"/>
    <allow receive_type="signal"/>
  </policy>

  <!-- Root must be able to own the bus name and to authenticate, or nothing
       else gets to connect at all. -->
  <policy user="root">
    <allow own="org.freedesktop.DBus"/>
  </policy>

  <!-- Limits. The names are not free-form: dbus-daemon aborts at startup on an
       unrecognised one, and the error it prints ("There is no limit called X")
       names the limit rather than the file, so it reads like a version problem
       rather than a typo. The set below is the one dbus 1.16 actually accepts -
       verified with `strings dbus-daemon | grep ^max_`, not from memory. Note
       there is no "max_replies_pending": it is easy to assume it pairs with
       max_replies_per_connection and it does not exist. -->
  <limit name="max_message_size">134217728</limit>
  <limit name="max_incoming_bytes">1073741824</limit>
  <limit name="max_outgoing_bytes">1073741824</limit>
  <limit name="max_replies_per_connection">512</limit>
  <limit name="max_match_rules_per_connection">2048</limit>
  <limit name="max_names_per_connection">2048</limit>
</busconfig>
CONF
info "system.conf written (minimal: no service policy, no SELinux)"

# ---------------------------------------------------------------------------
# Service directory
# ---------------------------------------------------------------------------
header "service files"
# Empty, but it must EXIST: dbus-daemon refuses to start if the servicedir named
# in system.conf is missing, and the resulting error names a path rather than the
# config, so it reads like a packaging bug rather than "you forgot a directory".
mkdir -p "$DIST/usr/share/dbus-1/system-services"
: > "$DIST/usr/share/dbus-1/system-services/.keep"
info "system-services/ staged (empty by design; services are D-Bus activated by init)"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
header "verification"
fail=0
for tool in dbus-daemon dbus-uuidgen dbus-send; do
    [ -x "$DIST/usr/bin/$tool" ] || { warn "missing $tool"; fail=1; }
done
for lib in libdbus-1.so.3 libexpat.so.1 libc.so.6; do
    if [ ! -e "$DIST/usr/lib64/$lib" ]; then
        warn "closure is missing $lib"
        fail=1
    fi
done
[ -f "$CONF_DIR/system.conf" ] || { warn "system.conf missing at $CONF_DIR"; fail=1; }
[ -e "$ETC/machine-id" ] && { warn "machine-id was created - it must not be"; fail=1; }
[ "$fail" -eq 0 ] || die "dbus-dist is incomplete"

# Prove the ELF loader can actually start the daemon from what we staged, by
# running it against a throwaway config in a private directory. --print-address
# on its own still forks and binds, so this is a real startup, and it is the only
# way to catch a closure gap that ldd did not report (a dlopen'd plugin, a
# missing service dir, a config parse error) before the ISO exists.
header "smoke test: start the real daemon on a private socket"
SMOKE="$(mktemp -d)"
trap 'rm -rf "$SMOKE"' EXIT
sed "s#/run/dbus/system_bus_socket#$SMOKE/sock#" "$CONF_DIR/system.conf" > "$SMOKE/system.conf"
mkdir -p "$SMOKE/services"
if LD_LIBRARY_PATH="$DIST/usr/lib64" timeout 10 "$DIST/usr/bin/dbus-daemon" \
        --config-file="$SMOKE/system.conf" --nofork --print-address=1 \
        > "$SMOKE/addr" 2> "$SMOKE/err" &
then
    SPID=$!
    for _ in $(seq 20); do [ -s "$SMOKE/addr" ] && break; sleep 0.2; done
    if [ -s "$SMOKE/addr" ]; then
        ADDR="$(head -1 "$SMOKE/addr")"
        info "daemon started and bound: $ADDR"
        # Round-trip a real message over that socket, which is the only proof the
        # policy block above actually permits anything.
        if LD_LIBRARY_PATH="$DIST/usr/lib64" timeout 10 "$DIST/usr/bin/dbus-send" \
                --bus=unix:path="$SMOKE/sock" --dest=org.freedesktop.DBus \
                --print-reply=literal / org.freedesktop.DBus.ListNames > "$SMOKE/reply" 2>&1 \
           && grep -q 'org.freedesktop.DBus' "$SMOKE/reply"; then
            info "message round-trip OK (ListNames returned the bus name)"
        else
            warn "daemon bound but would not answer a message:"
            sed 's/^/    /' "$SMOKE/reply" | head -5
            fail=1
        fi
    else
        warn "daemon produced no address; stderr:"
        sed 's/^/    /' "$SMOKE/err" | head -5
        fail=1
    fi
    kill "$SPID" 2>/dev/null || true
    wait "$SPID" 2>/dev/null || true
else
    warn "could not even launch dbus-daemon:"
    sed 's/^/    /' "$SMOKE/err" | head -5
    fail=1
fi

[ "$fail" -eq 0 ] || die "dbus smoke test failed"
printf '\n%s  done: D-Bus staged in %s%s\n' "$GRN" "$DIST" "$RST"
