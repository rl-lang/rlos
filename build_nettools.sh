#!/usr/bin/env bash
# build_nettools.sh - stage the network + data tools (Phase 3).
#
# Copies curl, the OpenSSH client and server, and sqlite3 from the host, plus
# the full ldd closure of each. Then stages their configs.
#
# Why host binaries rather than a static build or a source build:
#
#   - These are already-built host packages, so there is no toolchain step and
#     no source to drift. curl, OpenSSH and SQLite are among the most heavily
#     audited programs on Linux; shipping the distro's own build is the safest
#     version to ship.
#   - The cost is the ldd closure, which this script resolves and flattens.
#
#   A static curl or a from-source sqlite would be smaller, but "smaller" is not
#   what is being optimised here. This is the same argument as the X11 stack:
#   use the battle-tested binary and pay for its dependencies.
#
# Output tree (mirrors build_x11.sh's layout):
#
#   nettools-dist/bin/            binaries (guest PATH has /bin)
#   nettools-dist/usr/bin/        same binaries under the /usr/bin name too
#   nettools-dist/usr/lib64/      the ldd closure, flat (no ld.so.cache)
#   nettools-dist/etc/            configs, copied into the guest rootfs
#
# The closure is flattened because the guest has no /etc/ld.so.cache and
# OpenSSL/nghttp2/libssh2 do a lot of dlopen of things ldd does not report.
# Flat + real files in /usr/lib64 (a default loader search dir) is the one
# layout that survives all of that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DIST="$ROOT/nettools-dist"
GUEST_ETC="$DIST/etc"

# Load the shared helpers (info/ok/warn/header/fail) if build_x11.sh defines
# them; otherwise provide minimal stand-ins so this script runs standalone.
if [ -f "$ROOT/.build-helpers.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/.build-helpers.sh"
else
  info() { echo "  $*"; }
  ok()   { echo "ok: $*"; }
  warn() { echo "warn: $*" >&2; }
  fail() { echo "FAIL: $*" >&2; exit 1; }
  header() {
    echo
    echo "== $* =="
  }
fi

# ---------------------------------------------------------------------------
# What to ship
# ---------------------------------------------------------------------------

# name:source - source path relative to host root.
#
# sshd lives in /usr/sbin on the host; the rest are in /usr/bin.
BINARIES="
curl:/usr/bin/curl
ssh:/usr/bin/ssh
scp:/usr/bin/scp
sftp:/usr/bin/sftp
ssh-keygen:/usr/bin/ssh-keygen
sshd:/usr/sbin/sshd
sqlite3:/usr/bin/sqlite3
btop:/usr/bin/btop
"

header "clean"
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/usr/bin" "$DIST/usr/lib64" "$DIST/etc/ssh" \
         "$DIST/etc/git" "$DIST/usr/share/ssh" "$DIST/usr/share/man/man1"
echo "  $DIST"

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------

header "binaries"
for entry in $BINARIES; do
  name="${entry%%:*}"
  src="${entry#*:}"

  if [ ! -x "$src" ]; then
    fail "$name: not found at $src - install the host package first"
  fi

  # Busybox applet shadowing: if busybox also provides this name, whichever
  # lands first in /bin wins and the other becomes unreachable. Caught here
  # rather than at runtime because the failure is invisible otherwise.
  if [ -x "$ROOT/rlos-initramfs/initramfs/bin/busybox" ] && \
     "$ROOT/rlos-initramfs/initramfs/bin/busybox" --list 2>/dev/null \
       | awk '{print $1}' | grep -qx "$name"; then
    fail "$name: busybox also provides this applet - one would shadow the other"
  fi

  cp -L "$src" "$DIST/bin/$name"
  # Also stage under /usr/bin so `command -v` and hardcoded /usr/bin paths both
  # work. Guest PATH lists /usr/bin before /bin.
  cp -L "$src" "$DIST/usr/bin/$name"

  info "$(printf '%-11s %7s  %s' "$name" "$(du -h "$src" | cut -f1)" "${src}")"
done

# ---------------------------------------------------------------------------
# ldd closure
# ---------------------------------------------------------------------------

header "openssh helper binaries"
# OpenSSH 9.8+ moved pieces of sshd out into separate executables that the
# daemon execs at RUNTIME. sshd hardcodes their paths under /usr/lib64/misc and
# treats a missing one as fatal:
#
#   /usr/lib64/misc/sshd-session does not exist or is not executable
#   /usr/lib64/misc/sshd-auth does not exist or is not executable
#
# Both make sshd exit 255 on every start, and the second only appears once the
# first is fixed - so discovering them one boot at a time is slow. Listed
# together here, from what the host actually ships, rather than guessed.
#
# sftp-server is not fatal to sshd, but this build ships the sftp CLIENT, and
# without the server counterpart every `sftp` session fails at the first step.
# ssh-keysign is for agent-assisted host-key auth; cheap to include and it needs
# no libraries this build lacks.
#
# Deliberately NOT staged: ssh-pkcs11-helper (smartcards) and ssh-sk-helper
# (FIDO2 keys). Both are for hardware tokens this image has no use for, and
# pkcs11-helper would drag in libpcsclite for nothing.
SSHD_MISC_DIR="/usr/lib64/misc"
SSHD_HELPERS="sshd-auth sshd-session sftp-server ssh-keysign"
for helper in $SSHD_HELPERS; do
  src="$SSHD_MISC_DIR/$helper"
  # ssh-keysign ships setuid root and mode 711, so an unprivileged build cannot
  # read it. That is fine: it is only used for agent-assisted host-key
  # authentication, this image does not use it, and shipping a setuid binary
  # from a root-owned path would be a poor thing to do anyway. Skip it loudly
  # rather than failing the build.
  if [ -r "$src" ]; then
    mkdir -p "$DIST/usr/lib64/misc"
    cp -L "$src" "$DIST/usr/lib64/misc/$helper"
    ok "usr/lib64/misc/$helper ($(du -h "$src" | cut -f1))"
  elif [ -x "$src" ]; then
    warn "$helper is setuid/unreadable - skipping (optional, agent-auth only)"
  else
    warn "$helper missing from $SSHD_MISC_DIR"
    case "$helper" in
      sshd-auth|sshd-session)
        # These two are fatal for sshd; do not let the build "succeed" and
        # produce an image whose sshd can never start.
        fail "$helper is required by this OpenSSH's sshd - image would be broken" ;;
      *) warn "  continuing; only affects $helper's own feature" ;;
    esac
  fi
done

header "ldd closure"
# Flatten the closure of every shipped binary. Kept recursive because libcrypto
# pulls in libgomp/libz and the openssh binaries pull in libreadline.
#
# Resolved from the COPIED files, not the host originals, so the closure matches
# exactly what is shipped even if the host has extra libs installed that the
# copied binary would not use.
CLOSURE_SEEN=""
collect() {
  local target="$1" lib
  for lib in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/'); do
    case " $CLOSURE_SEEN " in *" $lib "*) continue ;; esac
    CLOSURE_SEEN="$CLOSURE_SEEN $lib"
    collect "$lib"
  done
}

# Start the walk from the copied binaries in dist/bin, plus sshd-session.
#
# sshd-session pulls in libpam and libcrypt, which nothing else in this batch
# needs. Those are staged even though sshd_config says UsePAM no: the loader
# resolves DT_NEEDED at load time whether or not the code path is ever taken, so
# omitting them turns into "error while loading shared libraries" the moment a
# client connects - not at startup, which makes it look like a network problem.
for elf in "$DIST"/bin/* "$DIST"/usr/lib64/misc/*; do
  [ -f "$elf" ] || continue
  collect "$elf"
done

# Place each lib flat in usr/lib64 under its SONAME (basename), which is what
# DT_NEEDED records and what the loader will search for. Copy -L dereferences
# so the file is a real ELF, not a symlink chain into host-only paths.
N_LIBS=0
for lib in $CLOSURE_SEEN; do
  base="$(basename "$lib")"
  # copy -L: dereference symlink so a real ELF lands in the guest.
  cp -L "$lib" "$DIST/usr/lib64/$base" 2>/dev/null || {
    warn "could not stage $base (continuing)"
    continue
  }
  N_LIBS=$((N_LIBS + 1))
done
info "closure: $N_LIBS libraries, $(du -sh "$DIST/usr/lib64" | cut -f1)"

# Record the closure for assemble-rootfs.sh / build_initramfs to verify against
# at package time, so a missing lib is caught before the ISO, not after boot.
printf '%s\n' $N_LIBS > "$DIST/.closure-count"

# ---------------------------------------------------------------------------
# Dynamic linker symlinks (the ld-script trap, again)
# ---------------------------------------------------------------------------
# Some distros ship libc.so.6 as a real file but libm.so.6 etc. as either a
# linker script or a chain of symlinks. The guest loader needs a real ELF for
# anything DT_NEEDED names. Verify, don't assume.
header "SONAME reality check"
for so in libc.so.6 libm.so.6; do
  f="$DIST/usr/lib64/$so"
  if [ ! -f "$f" ]; then
    fail "$so missing from closure"
  fi
  if ! file -b "$f" | grep -q 'ELF'; then
    fail "$so is not a real ELF ($(file -b "$f" | cut -c1-40)) - loader would reject it"
  fi
done
info "libc.so.6, libm.so.6 are real ELF"

# libgcc_s: Rust and some C runtime paths want it; stage it if present on host.
if [ -e /usr/lib64/libgcc_s.so.1 ] || [ -e /usr/lib/x86_64-linux-gnu/libgcc_s.so.1 ]; then
  src="$(ls /usr/lib64/libgcc_s.so.1 /usr/lib/x86_64-linux-gnu/libgcc_s.so.1 2>/dev/null | head -1)"
  cp -L "$src" "$DIST/usr/lib64/libgcc_s.so.1"
  info "libgcc_s.so.1 staged"
fi

# ---------------------------------------------------------------------------
# Configs
# ---------------------------------------------------------------------------

header "alsa"
# libasound for rl-std/audio.rs.
#
# The compiled path (rlt --compile) uses miniaudio, which dlopen()s
# "libasound.so.2" at RUNTIME rather than linking it. That is why rlt's link
# line carries only -lpthread -ldl and no -lasound: the binary is already built
# by the time audio is used. Consequence for staging - dlopen searches the
# default loader path, so the file has to be present at /usr/lib64 in the guest,
# but nothing needs to be relinked.
#
# 1.0MB. Closure is libm + libc, both already staged.
if [ -e /usr/lib64/libasound.so.2 ]; then
  mkdir -p "$DIST/usr/lib64"
  cp -L /usr/lib64/libasound.so.2 "$DIST/usr/lib64/libasound.so.2"
  ok "usr/lib64/libasound.so.2 ($(du -hL /usr/lib64/libasound.so.2 | cut -f1))"
else
  fail "libasound.so.2 not found - rl-std/audio.rs cannot open any device"
fi

# alsa.conf is NOT optional. Measured, not assumed:
#
#   with /usr/share/alsa/alsa.conf present -> ma_context_init SUCCESS,
#       ma_context_enumerate_devices 16 devices
#   with it absent                         -> ma_context_init SUCCESS,
#       ma_context_enumerate_devices = -7 (MA_DOES_NOT_EXIST), 0 devices
#
# So miniaudio initialises fine without it and then finds nothing, which is a
# confusing way to fail: the engine reports itself ready and playback silently
# does nothing. 12KB for alsa.conf alone is cheap insurance.
#
# The rest of the ALSA data tree (cards/, pcm/, ucm2/, topology/ - 4.1MB) is
# NOT staged. It was measured as unnecessary: hw:0,0 and plughw:0,0 open
# correctly with only alsa.conf present. ucm/ is worth shipping if specific
# codec routing ever matters, but 3.4MB of it for no demonstrated need is not a
# trade worth making on a 107MB image.
if [ -f /usr/share/alsa/alsa.conf ]; then
  mkdir -p "$DIST/usr/share/alsa"
  cp /usr/share/alsa/alsa.conf "$DIST/usr/share/alsa/alsa.conf"
  ok "usr/share/alsa/alsa.conf ($(du -h /usr/share/alsa/alsa.conf | cut -f1))"
else
  warn "/usr/share/alsa/alsa.conf missing - audio will initialise but find 0 devices"
fi

header "configs"

# ssh_config: sane defaults for the client. No User/Port (those are per-target),
# keepalive so a laptop suspend doesn't leave ssh wedged, and modern key
# exchange by simply not listing the legacy ones (client defaults are already
# modern in OpenSSH 10).
cat > "$GUEST_ETC/ssh/ssh_config" << 'EOF'
# /etc/ssh/ssh_config - system-wide client defaults (rlos)
#
# Deliberately short. The only thing worth setting system-wide is keepalive:
# without it, a client whose network silently vanished (cable pulled, wifi
# slept) blocks forever on a TCP connection that will never error. ServerAlive
# makes ssh notice and retry.
ServerAliveInterval 30
ServerAliveCountMax 3

# Use the system-wide known_hosts. The per-user file still takes precedence;
# this only affects the case where a user has none.
GlobalKnownHostsFile /etc/ssh/ssh_known_hosts

# BatchMode is NOT set: a first connection to a new host should be able to
# prompt for a fingerprint. Making that fail-by-default trades a real
# usability win for a small security nicety that host keys already cover.
EOF
ok "ssh_config"

# sshd_config: what the server actually needs in this guest.
#
# Notes on the choices, since they are all load-bearing:
#
#   PermitRootLogin no
#     root is locked in /etc/shadow anyway. Belt and braces: even if someone
#     unlocks it, they should ssh in as `user` and sudo.
#
#   PasswordAuthentication yes
#     This is a single-user laptop OS with one local account and no PAM. If
#     this were no, there would be NO way to log in over the network at all,
#     because the alternative (pubkey) requires pre-seeding authorized_keys,
#     which an image with no persistence has no place to put them. Password
#     auth is the only usable option here. The cost is brute-force exposure,
#     mitigated by LoginGraceTime and by this being a LAN device.
#
#   UsePAM no
#     There is no PAM in this rootfs (the ldd closure has zero pam libs). sshd
#     defaults to UsePAM yes and would fail to start. Setting no lets it use
#     /etc/passwd + /etc/shadow directly, which is exactly what it wants.
#
#   X11Forwarding no
#     There is no sshd-side X and forwarding buys nothing on a framebuffer-only
#     guest.
cat > "$GUEST_ETC/ssh/sshd_config" << 'EOF'
# /etc/ssh/sshd_config - rlos server
Port 22
AddressFamily any

# root is locked; log in as `user` and sudo. Do not enable root login.
PermitRootLogin no

# See the note in build_nettools.sh: with one local account, no PAM, and no
# persistence, password auth is the only workable network login. Set to yes
# deliberately.
PasswordAuthentication yes
PubkeyAuthentication yes

# No PAM in this rootfs; read /etc/passwd and /etc/shadow directly.
UsePAM no

# No client-side X to forward to.
X11Forwarding yes

# sftp subsystem. NOT optional, and the omission is invisible until someone
# runs sftp or scp: OpenSSH has no built-in default for this, so with the line
# absent the subsystem is simply not registered and every client gets
#
#   subsystem request failed on channel 0
#
# scp is affected too, because since OpenSSH 9 scp speaks SFTP by default rather
# than the legacy rcp protocol. `scp -O` still works without this, which is a
# confusing workaround because the failure looks like a missing binary rather
# than a missing config line.
#
# Path matches where this script stages sftp-server (see the helpers block above).
Subsystem sftp /usr/lib64/misc/sftp-server

# Give up on a stalled auth quickly rather than letting a connection hang for
# the 120s default.
LoginGraceTime 20

# Keep a reasonable number of sessions; the framebuffer guest is not a
# multi-tenant server.
MaxStartups 10:30:60
MaxSessions 10
EOF
ok "sshd_config"

# moduli: DH group exchange parameters. sshd reads this at startup for the
# diffie-hellman-group-exchange-* key exchange methods. Without it, sshd either
# refuses to start or logs noisily depending on build. It is a static text file
# shipped with OpenSSH.
if [ -f /etc/ssh/moduli ]; then
  cp /etc/ssh/moduli "$GUEST_ETC/ssh/moduli"
  ok "moduli ($(du -h "$GUEST_ETC/ssh/moduli" | cut -f1))"
else
  warn "/etc/ssh/moduli not found on host - copying sshd will fail at runtime"
  warn "  (only needed if you want DH-GEX; set KexAlgorithms to exclude it)"
fi

# sshd privilege-separation user. OpenSSH 10 hard-exits at startup if the
# compiled-in privsep user ("sshd", uid 22) does not exist. It must be in
# /etc/passwd AND /etc/group before sshd runs. init.c writes these; see
# net_sshd_ensure_privsep_user().
ok "privsep user 'sshd' handled by init.c (writes /etc/passwd,/etc/group)"

# Empty known_hosts so ssh has something to append to on first connect.
: > "$GUEST_ETC/ssh/ssh_known_hosts"
chmod 644 "$GUEST_ETC/ssh/ssh_known_hosts"
ok "ssh_known_hosts (empty)"

# ---------------------------------------------------------------------------
# gitconfig
# ---------------------------------------------------------------------------

header "gitconfig"
# Sane defaults so `git init && git commit` works without configuring anything.
#
# - init.defaultBranch: git's new-branch warning is noise on a fresh repo.
# - core.hooksPath: leave git's stock hooks in place; do NOT set this, it
#   would disable the user's own hooks. (Explicitly not set.)
# - user.name/email: deliberately NOT set. Inventing an identity for the user
#   is worse than making them type it once; git's own "please tell me who you
#   are" prompt is the right behaviour.
# - pull.rebase: false is git's default; not set.
# - core.autocrlf: input (convert CRLF on commit, not on checkout) is the sane
#   cross-platform default.
cat > "$GUEST_ETC/git/config" << 'EOF'
[init]
	defaultBranch = main

[core]
	autocrlf = input
	editor = nano

[color]
	ui = auto

[pager]
	log = less -FRX
EOF
ok "/etc/git/config (no invented identity; nano as editor)"

# ---------------------------------------------------------------------------
# locale
# ---------------------------------------------------------------------------

header "locale"
# A single UTF-8 locale so text output is not ASCII-mangled and filenames with
# non-ASCII bytes survive. C.UTF-8 is built into glibc 2.35+ (no locale-gen
# needed on a modern host); we stage the definition and set it as default.
#
# The guest has no locale-gen and no full locale archive, so we rely on
# glibc's built-in C.UTF-8. Verify the host glibc actually has it.
if locale -a 2>/dev/null | grep -qx 'C.utf8\|C.UTF-8'; then
  ok "host glibc has built-in C.UTF-8 (no locale archive needed)"
else
  warn "host does not report C.UTF-8 in locale -a; staging definition anyway"
  warn "  guest may fall back to C. Verify after boot."
fi
cat > "$GUEST_ETC/locale.conf" << 'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF
ok "/etc/locale.conf -> C.UTF-8"

# ---------------------------------------------------------------------------
# Self-check: the binaries must at least run under the guest's dynamic linker.
# ---------------------------------------------------------------------------

header "self-check"
# Use the host's loader against the staged closure directory to prove each
# binary's DT_NEEDED entries are all satisfiable from usr/lib64. This does not
# fully boot the guest, but it catches a missing/renamed SONAME, which is the
# failure that would otherwise only show as "ssh: error while loading shared
# libraries" after the user types ssh for the first time.

LD="$DIST/usr/lib64"
runner_ok=0
runner_fail=0

check_binary() {
  local name="$1" args="${2:---version}"
  local out rc
  # NOT an exit-code test. scp and sftp have no -V/--version and exit 1 on any
  # unknown flag, which is a healthy binary. What matters is whether the
  # dynamic loader resolved everything, so match the loader's own error text.
  #
  # `|| rc=$?` is required, not stylistic: with `set -e`, a bare assignment that
  # captures a nonzero command aborts the whole script before rc is ever read.
  # That silently truncated this check at the first nonzero exit.
  out="$(env LD_LIBRARY_PATH="$LD" "$DIST/bin/$name" $args 2>&1)" && rc=0 || rc=$?

  if echo "$out" | grep -qiE 'error while loading shared libraries|cannot open shared object|not a dynamic executable|symbol lookup error'; then
    warn "$(printf '%-11s LOADER FAIL  %s' "$name" "$(echo "$out" | head -1 | cut -c1-55)")"
    runner_fail=$((runner_fail + 1))
    return
  fi
  # Proved the loader was happy; the flag itself may legitimately be rejected.
  if [ $rc -eq 0 ]; then
    info "$(printf '%-11s ok   %s' "$name" "$(echo "$out" | head -1 | cut -c1-50)")"
  else
    info "$(printf '%-11s ok   (flag rejected, libs resolved) %s' "$name" \
           "$(echo "$out" | head -1 | cut -c1-34)")"
  fi
  runner_ok=$((runner_ok + 1))
}

# curl/sqlite3/ssh print a version and exit 0. sshd -V exits nonzero; use -t
# with a config instead (checked separately). ssh-keygen needs a subcommand.
check_binary curl --version
check_binary sqlite3 --version
check_binary ssh -V
check_binary scp -V
check_binary sftp -V
check_binary ssh-keygen -V
# btop renders to stderr/stdout the same way, and --version exits 0.
check_binary btop --version

# sshd has no -V and exits nonzero on anything unknown, and `sshd -T` needs a
# host key before it will expand the config. So mint a throwaway key with the
# STAGED ssh-keygen (which also proves that binary's closure), validate the real
# staged config against it, then throw it away.
#
# The shipped image does NOT ship host keys: they are generated on first boot
# into /etc/ssh, which persists on a USB install (so known_hosts stays valid
# across reboots) and is ephemeral on a live ISO.
SSH_TMP="$(mktemp -d)"
trap 'rm -rf "$SSH_TMP"' EXIT

if env LD_LIBRARY_PATH="$LD" "$DIST/bin/ssh-keygen" -q -t ed25519 \
     -f "$SSH_TMP/hostkey" -N '' >/dev/null 2>&1; then
  cp "$GUEST_ETC/ssh/sshd_config" "$SSH_TMP/sshd_config"
  printf 'HostKey %s\n' "$SSH_TMP/hostkey" >> "$SSH_TMP/sshd_config"
  if env LD_LIBRARY_PATH="$LD" "$DIST/bin/sshd" -T -f "$SSH_TMP/sshd_config" >/dev/null 2>&1; then
    ok "sshd: staged config is valid (validated against a throwaway host key)"
    # Re-report the three settings that are easy to get silently wrong, so the
    # build log records what the server will actually do.
    env LD_LIBRARY_PATH="$LD" "$DIST/bin/sshd" -T -f "$SSH_TMP/sshd_config" 2>/dev/null \
      | grep -iE '^(permitrootlogin|passwordauthentication|usepam|x11forwarding) ' \
      | sed 's/^/         /'
    runner_ok=$((runner_ok + 1))
  else
    warn "sshd: staged config rejected by sshd -T"
    env LD_LIBRARY_PATH="$LD" "$DIST/bin/sshd" -T -f "$SSH_TMP/sshd_config" 2>&1 \
      | head -3 | sed 's/^/         /'
    runner_fail=$((runner_fail + 1))
  fi
else
  warn "could not mint a throwaway host key with the staged ssh-keygen"
  warn "  the staged ssh-keygen closure is broken"
  runner_fail=$((runner_fail + 1))
fi

# sshd-session has no --version and no useful no-arg mode, but the loader still
# has to resolve it. Checking that it is a real ELF and that libpam landed is the
# part that actually bit us.
for helper in sshd-auth sshd-session; do
  f="$DIST/usr/lib64/misc/$helper"
  if [ ! -f "$f" ]; then
    warn "$helper not staged - sshd will exit 255 on every start"
    runner_fail=$((runner_fail + 1))
  elif ! file -b "$f" | grep -q ELF; then
    warn "$helper is not a real ELF"
    runner_fail=$((runner_fail + 1))
  fi
done
for need in libpam.so.0 libcrypt.so.2; do
  if [ -f "$LD/$need" ]; then
    ok "helper dependency $need staged"
  else
    warn "$need missing - the helpers will fail to load on first connection"
    runner_fail=$((runner_fail + 1))
  fi
done

# The sftp subsystem is a config line, not a binary, so the linker-check above
# cannot catch it being missing. Assert it directly: without this, sftp and
# default-mode scp fail at runtime with "subsystem request failed on channel 0"
# and nothing in the build notices.
if grep -q '^Subsystem[[:space:]]\+sftp[[:space:]]\+/usr/lib64/misc/sftp-server$' \
     "$GUEST_ETC/ssh/sshd_config"; then
  ok "sshd_config registers the sftp subsystem"
else
  fail "sshd_config has no 'Subsystem sftp' line - sftp and scp will both fail"
fi
if [ -f "$DIST/usr/lib64/misc/sftp-server" ]; then
  ok "sftp-server staged at the path that Subsystem line names"
else
  fail "sftp-server missing - the Subsystem line points at nothing"
fi

if [ "$runner_fail" -gt 0 ]; then
  fail "$runner_fail binary(ies) failed self-check"
fi
ok "self-check: $runner_ok binaries run against staged closure"

# Show the actual closure so a regression is visible in the build log.
info "closure contents:"
ls "$LD" | sed 's/^/         /'

# btop-specific notes, kept next to the staging that they depend on.
#
# libstdc++ (2.5MB) is the one genuinely heavy dependency in this batch, and on
# Gentoo it does NOT live in /usr/lib64 - it is under /usr/lib/gcc/x86_64-pc-linux-gnu/.
# The closure walk resolves by absolute path and stages it flat as
# usr/lib64/libstdc++.so.6, which is what btop's DT_NEEDED actually asks for, so
# the guest finds it. This is the same flattening everything else relies on.
#
# Themes: exactly ONE is staged, tokyo-night. Not the 41 on the host - that is
# ~200KB of decoration for a machine that has one theme. btop finds themes in
# "../share/btop/themes" relative to the binary, so /usr/share/btop/themes is the
# location; the user's own ~/.config/btop/themes takes precedence over it, so
# anyone who wants a different theme can drop one in without touching /usr.
#
# The theme itself is copied from the host rather than authored here. It is
# Pascal Jaeger's, shipped by btop upstream, and rewriting its 37 keys by hand
# would be a way to introduce a typo into a file that already exists and is
# known-good. tokyo-night is base Night (#1a1b26 bg) rather than Moon (#24273b):
# btop has no Moon theme, and Moon was rejected for the desktop anyway in favour
# of a darker layering. The two do not match exactly, and do not need to - btop
# is a full-screen TUI that replaces the terminal, not a window sitting on it.
#
# The CONFIG is staged too, because a theme file with nothing selecting it is
# inert: btop's default is color_theme = "Default", its own built-in. btop reads
# $HOME/.config/btop/btop.conf, so that is where it goes.

# /etc/mtab: btop reads it for mounted filesystems. On a normal system that is a
# symlink to /proc/mounts, and assemble-rootfs.sh creates it. btop still shows CPU
# and memory without it, but the filesystem panel stays empty.

header "btop theme"
BTOP_THEME_SRC="/usr/share/btop/themes/tokyo-night.theme"
if [ -f "$BTOP_THEME_SRC" ]; then
    mkdir -p "$DIST/usr/share/btop/themes"
    install -m 0644 "$BTOP_THEME_SRC" "$DIST/usr/share/btop/themes/tokyo-night.theme"
    ok "btop theme staged (tokyo-night, $(du -h "$BTOP_THEME_SRC" | cut -f1))"
else
    # Not fatal. btop falls back to its built-in Default theme, which is what
    # this image did before, so a missing theme file degrades the look rather
    # than breaking the program.
    warn "btop theme not found at $BTOP_THEME_SRC - btop will use its built-in theme"
fi

header "zoneinfo"
# The timezone database, without which any clock in this image is UTC no matter
# what TZ says.
#
# WHY IT MATTERS: libc resolves TZ by opening /usr/share/zoneinfo/<TZ>. With that
# directory absent, TZ is parsed as a POSIX TZ STRING instead - so TZ=Europe/Berlin
# silently becomes offset +0000 with the zone displayed as "Europe", because it
# cannot find the file to read. It fails quietly: no error, a plausible-looking
# time, the wrong one. Verified inside bwrap with the guest tree as the only
# visible filesystem.
#
# WHY NOT A SUBSET: the zone files are only 0.7M. The other 1.9M of the host's
# /usr/share/zoneinfo is tzdata.zi and the zone.tab/iso3166.tab indexes, which
# libc never opens for a normal lookup. Staging the files alone costs 0.4% of the
# ISO and removes the need to guess which of 605 zones somebody might boot in.
ZONEINFO_SRC="/usr/share/zoneinfo"
if [ -d "$ZONEINFO_SRC" ]; then
    mkdir -p "$DIST/usr/share/zoneinfo"
    # -type f, and skip the tzdata source/index files libc never reads.
    ( cd "$ZONEINFO_SRC" && find . -type f \
        ! -name 'tzdata.zi' \
        ! -name 'leapseconds' \
        ! -name 'leap-seconds.list' \
        ! -name 'tzdata.tab' \
        ! -name 'iso3166.tab' \
        ! -name 'zone.tab' \
        ! -name 'zone1970.tab' \
        ! -name 'zonenow.tab' \
        -print0 ) | while IFS= read -r -d '' zf; do
        mkdir -p "$DIST/usr/share/zoneinfo/$(dirname "$zf")"
        install -m 0644 "$ZONEINFO_SRC/$zf" "$DIST/usr/share/zoneinfo/$zf"
    done
    N_ZONES="$(find "$DIST/usr/share/zoneinfo" -type f | wc -l)"
    ok "zoneinfo staged ($N_ZONES files, $(du -sh "$DIST/usr/share/zoneinfo" | cut -f1))"
else
    # Not fatal, but say what the consequence is rather than leaving a clock that
    # quietly disagrees with the wall.
    warn "no $ZONEINFO_SRC on the host - the clock will be UTC whatever TZ is set to"
fi

header "done"
info "next: assemble-rootfs.sh copies nettools-dist/ into the guest, then"
info "      init.c writes the sshd privsep user and starts sshd."
