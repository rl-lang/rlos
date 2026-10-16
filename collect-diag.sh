#!/bin/sh
# collect-diag.sh - gather everything needed to diagnose why the -w (Wayland)
# backend does not reach a desktop, into /log/<name>/.
#
# Usage:
#     sudo ./collect-diag.sh [name]
#
# name defaults to a UTC timestamp. Output goes to /log/<name>/.
#
# WHY RUN sway BY HAND AT ALL. init starts sway with stdout/stderr inherited
# from the console, but that console is also the text-mode fallback, so by the
# time anyone reads it the compositor's real error has scrolled away. All init
# reports is "sway did not create /run/user/1000/wayland-0", which names neither
# the cause nor the device. Running sway in the foreground with a terminal
# attached is the difference between "it didn't work" and a diagnosis.
#
# Written for busybox sh: the guest has no bash.

set -u

NAME="${1:-}"
[ -n "$NAME" ] || NAME="$(date -u '+%Y%m%d-%H%M%SZ' 2>/dev/null || echo diag)"
# Constrain to something usable as a plain directory name.
NAME="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '_')"
OUT="/log/$NAME"

mkdir -p "$OUT" || { echo "cannot create $OUT (need root?)" >&2; exit 1; }
echo "collecting into $OUT ..."

# Every capture writes its own file and reports an rc, so a capture that fails is
# visibly empty rather than silently missing.
cap() {
    _n="$1"; shift
    echo "--- $_n ---" > "$OUT/$_n.txt" 2>&1
    "$@" >> "$OUT/$_n.txt" 2>&1
    _rc=$?
    echo "[$_n rc=$_rc]" >> "$OUT/$_n.txt"
}

sh_() { sh -c "$1"; }

# --- basics -----------------------------------------------------------------
cap date       sh_ 'date -u; uname -a; echo "--- version ---"; cat /etc/rlos-version 2>/dev/null'
cap mounts     sh_ 'cat /proc/mounts 2>/dev/null | head -20'

# --- kernel -----------------------------------------------------------------
# dmesg is the most useful file here: it carries init's own messages in order,
# plus any DRM/XKB kernel complaints.
cap dmesg_all  sh_ 'dmesg 2>/dev/null || cat /proc/kmsg 2>/dev/null'
cap dmesg_gfx  sh_ 'dmesg 2>/dev/null | grep -iE "drm|fbdev|fb0|virtio|vga|kms|gpu|simpledrm"'
cap dmesg_init sh_ 'dmesg 2>/dev/null | grep -iE "init:|sway|wlr|xkb|libinput"'
cap dmesg_inp  sh_ 'dmesg 2>/dev/null | grep -iE "input|evdev|hid|udev"'

# --- graphics devices -------------------------------------------------------
# ls -l, not ls: the permission bits matter. sway drops to uid 1000, and a card
# that is root-only looks fine under a plain ls.
cap drm_nodes  sh_ 'ls -l /dev/dri/ 2>&1; echo "--- fb ---"; ls -l /dev/fb* 2>&1; echo "--- input ---"; ls -l /dev/input/ 2>&1 | head -20'
cap drm_sysfs  sh_ 'for d in /sys/class/drm/card*; do [ -e "$d" ] || continue; echo "$d:"; cat "$d/device/uevent" 2>/dev/null; done; echo "--- all drm ---"; ls /sys/class/drm/ 2>&1'
cap modes      sh_ 'cat /sys/class/drm/card0/modes 2>&1; echo "--- enabled ---"; cat /sys/class/drm/card0/enabled 2>&1'
cap fb         sh_ 'cat /proc/fb 2>&1; echo "--- fbcon ---"; dmesg 2>/dev/null | grep -i fbcon'

# --- runtime data the input stack needs ------------------------------------
# libinput and xkbcommon have their BUILD PREFIX compiled in as a data search
# path. If the guest copies are missing they fall through to it and report
# "failed to find data files" - which is exactly what happened, and which no
# build gate could see, because a compiled-in data path is invisible to
# readelf -d (only RPATH/RUNPATH are checked).
cap xkb_data   sh_ 'ls -l /usr/share/X11/xkb/rules/evdev 2>&1; echo "--- counts ---"; for d in rules symbols keycodes types compat geometry; do printf "%-9s " "$d"; ls /usr/share/X11/xkb/$d 2>/dev/null | wc -l; done'
cap xkb_root   sh_ 'XKB_CONFIG_ROOT=/usr/share/X11/xkb; export XKB_CONFIG_ROOT; xkbcomp -version 2>&1 | head -1; echo "--- lookup ---"; setxkbmap -query 2>&1 | head -5'
cap libin_data sh_ 'ls /usr/share/libinput 2>&1 | head -20; echo "--- count ---"; ls /usr/share/libinput 2>/dev/null | wc -l'
# The tell-tale: a /home/... path baked into a shipped library.
cap prefix_leak sh_ 'strings /usr/lib64/libinput.so.10 2>/dev/null | grep -E "^/(home|tmp)/" | sort -u | head; echo "--- xkbcommon ---"; strings /usr/lib64/libxkbcommon.so.0 2>/dev/null | grep -E "^/(home|tmp)/" | sort -u | head'

# --- libraries --------------------------------------------------------------
cap libs       sh_ 'for l in libwlroots-0.20.so libEGL.so.1 libgbm.so.1 libGLESv2.so.2 libgallium-26.2.4.so libinput.so.10 libxkbcommon.so.0 liblua5.4.so.0 libzstd.so.1 libstdc++.so.6 libgcc_s.so.1; do printf "%-26s " "$l"; [ -e "/usr/lib64/$l" ] && echo present || echo MISSING; done'
# Which compiler built the C++ runtime: ours should say 16.2.0.
cap libstdcxx  sh_ 'strings /usr/lib64/libstdc++.so.6 2>/dev/null | grep -oE "GCC: \(GNU\) [0-9.]+" | head -1'
cap versions   sh_ '/bin/sway --version 2>&1 | head -1; /bin/foot --version 2>&1 | head -1; /bin/swaybar --version 2>&1 | head -1'

# --- session environment ---------------------------------------------------
# XDG_RUNTIME_DIR must exist, be 0700 and be owned by uid 1000 or the compositor
# cannot bind its socket. ls -ld shows all three at once.
cap runtimedir sh_ 'ls -ld /run/user /run/user/1000 2>&1; echo "--- contents ---"; ls -l /run/user/1000/ 2>&1'
cap config     sh_ 'cat /etc/sway/config 2>&1'

# --- init's own console output ---------------------------------------------
# init writes to /dev/console, NOT to the kernel log, so dmesg never contains
# "sway did not create ...". That message is the whole of what init says and it
# names no cause, so it is worth capturing directly if anything recorded it.
#
# With no serial console configured the text console holds it and nothing writes
# it to a file. The kernel ring buffer is the only record, so grab what is there
# and say plainly when it is empty rather than leaving a blank file.
cap init_console sh_ 'grep -a "init:" /proc/kmsg 2>/dev/null; echo "--- kmsg ---"; cat /proc/kmsg 2>/dev/null | grep -a "init:"; echo "(if both are empty, init writes only to /dev/console and nothing recorded it - read it off the screen)"; echo "--- dmesg sway ---"; dmesg 2>/dev/null | grep -aiE "sway|wlr|assert|abort"'

# --- sway's OWN log, written by init -----------------------------------------
# init now tees sway's stderr to /var/log/sway.log as well as the console. This
# is the compositor's real output from the boot that just happened - i.e. from
# init's own launch, not from a manual re-run, which makes it the one artifact
# that reflects the actual failure.
cap swaylog      sh_ 'cat /var/log/sway.log 2>&1'
cap swaylog_tail sh_ 'tail -40 /var/log/sway.log 2>&1'

# --- process state, while the session is still up ----------------------------
# WHY: procs.log came back empty on a boot where clients provably lost their
# Wayland socket, which means no child of init ever exited. So "sway died" was
# never established - either sway is alive and something else broke the
# connection, or it died in a way supervise() never saw. These capture which.
# The count matters most: two compositors on one seat is a different fault
# entirely from one compositor misbehaving.
cap procs     sh_ 'ps 2>/dev/null | head -40'
cap sway_pids sh_ 'ps 2>/dev/null | grep -a "[s]way" ; echo "--- count: $(ps 2>/dev/null | grep -ac "[s]way") ---"'
cap sway_stat sh_ 'for p in $(ps 2>/dev/null | grep -a "[s]way" | awk "{print \$1}"); do echo "=== pid $p ==="; cat /proc/$p/status 2>/dev/null | head -8; echo "--- wchan/state ---"; cat /proc/$p/wchan 2>/dev/null; echo; done'
cap sway_oom  sh_ 'for p in $(ps 2>/dev/null | grep -a "[s]way" | awk "{print \$1}"); do echo "=== pid $p limits ==="; grep -aE "Max open files" /proc/$p/limits 2>/dev/null; done'
# procs.log is init'"'"'s record of every child death. Empty is itself a result.
cap child_deaths sh_ 'cat /log/procs.log 2>&1 | tail -40; echo "--- lines: $(cat /log/procs.log 2>/dev/null | wc -l) ---"'
# The socket itself: inode, and whether anyone is still listening on it.
cap wl_socket  sh_ 'ls -l /run/user/1000/ 2>&1; echo "--- ss ---"; ss -x 2>/dev/null | grep -a wayland || echo "(ss unavailable)"'
cap shm_state  sh_ 'df -h /dev/shm 2>&1; echo "--- count ---"; ls /dev/shm 2>/dev/null | wc -l'

# --- THE ACTUAL TEST --------------------------------------------------------
# sway in the foreground, as init would run it, terminal attached.
#   WLR_BACKENDS forced: wlroots autodetects, and its autodetection is what
#     walked into the nested-compositor confusion (it saw WAYLAND_DISPLAY and
#     tried to attach to a parent compositor that did not exist).
#   WAYLAND_DISPLAY deliberately unset - sway must not think it is nested.
# Run sway several ways. The renderer is the variable that matters: this image's
# Mesa is built -Dgallium-drivers=softpipe only, so on an Intel GPU EGL asks for
# "iris", finds it absent, and wlroots dies at renderer creation:
#
#   iris: driver missing
#   MESA-EGL: warning: egl: failed to create dri2 screen
#   [wlr] [render/wlr_renderer.c:279] Could not initialize renderer
#
# init passes WLR_RENDERER=pixman, which should skip EGL entirely. Whether that
# actually produces a session is the question these runs answer.
sway_run() {
    _label="$1"; shift
    echo "=== $_label ==="
    echo "cmd: sway -c /etc/sway/config   [WLR_RENDERER=${WLR_RENDERER:-<unset>}]"
    timeout 8 /bin/sway -c /etc/sway/config 2>&1
    echo "--- rc=$? ---"
}

run_sway() {
    echo "### three attempts: default, forced pixman, forced software ###"
    echo
    XDG_RUNTIME_DIR=/run/user/1000
    export XDG_RUNTIME_DIR
    WLR_BACKENDS=drm,libinput
    export WLR_BACKENDS
    unset WAYLAND_DISPLAY
    unset DISPLAY
    # Clean stale sockets first. wl_display_add_socket_auto() takes the first
    # FREE name, so a socket left behind by a previous failed run makes the next
    # one bind wayland-1 instead of wayland-0 - which is exactly what happened,
    # and it makes init's wait for wayland-0 unreliable across reboots.
    ls -l /run/user/1000/ 2>&1
    rm -f /run/user/1000/wayland-* /run/user/1000/*.lock /run/user/1000/sway-ipc.* 2>/dev/null
    echo "cleared stale sockets"
    echo
    sway_run "1. WLR_RENDERER unset (what init does NOT do)"
    echo
    WLR_RENDERER=pixman; export WLR_RENDERER
    sway_run "2. WLR_RENDERER=pixman (what init DOES)"
    echo
    WLR_RENDERER_FORCE_SOFTWARE=1; export WLR_RENDERER_FORCE_SOFTWARE
    unset WLR_RENDERER
    sway_run "3. WLR_RENDERER_FORCE_SOFTWARE=1"
    echo
    echo "### sockets left behind ###"
    ls -l /run/user/1000/ 2>&1
}
cap sway_manual run_sway

# --- summary ----------------------------------------------------------------
{
    echo "name: $NAME"
    echo "when: $(date -u 2>/dev/null)"
    echo "host: $(uname -a 2>/dev/null)"
} > "$OUT/SUMMARY.txt" 2>&1

echo
echo "collected into $OUT :"
ls -1 "$OUT" 2>/dev/null | sed 's/^/  /'
echo
echo "start with:"
echo "  cat $OUT/sway_manual.txt"
echo "  cat $OUT/dmesg_gfx.txt"
echo "  cat $OUT/xkb_data.txt"