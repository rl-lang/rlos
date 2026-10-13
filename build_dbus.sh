#!/usr/bin/env bash
# build_dbus.sh - stage the D-Bus system bus.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dbus-dist"
ETC="$DIST/etc"
CONF_DIR="$DIST/etc/dbus-1"

source "$ROOT/build-lib.sh"

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
if [ -e "$ETC/machine-id" ]; then
    die "machine-id exists in dist - it must be generated at boot, never baked"
fi
info "left absent on purpose: init.c generates it on first boot"

# ---------------------------------------------------------------------------
# system.conf
# ---------------------------------------------------------------------------
header "system.conf"
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
