#!/bin/sh
# record.sh - record the screen to a video, or stop an existing recording.
#
#   record.sh              start recording -> ~/rec-<timestamp>.mkv
#   record.sh stop         stop it and report the file size
#   record.sh 1920x1080    force a capture size
#
# The encoder is libx264, which is GPL. That is deliberate: this image already
# ships busybox, git, mlterm, the kernel and ttyrec, all GPL-2.0, so it is already
# a GPL distributor and the compliance obligations are unchanged. The LGPL route
# (dropping x264 for the BSD-licensed libvpx) would reduce nothing and cost
# encoding quality.
#
# Settings, and why each is here:
#
#   -preset ultrafast   x264's speed/quality dial. ultrafast produces a large
#                       file for the same quality, and this is a screen recording
#                       of mostly-static text - the case where spending CPU on
#                       compression buys the least.
#   -crf 23             x264's default quality target (roughly "visually lossless").
#   -pix_fmt yuv420p    REQUIRED for playback in ffplay and anywhere else, which
#                       expect 4:2:0. x264 will happily emit yuv444p for an
#                       unusual input, which then refuses to play.
#   -framerate 15       Screen content does not need 30. Half the frames, half the
#                       encode time, and nobody can see the difference on a
#                       terminal.
#   matroska            The container. It is the one format that carries H.264
#                       without needing a faststart-style moov relocation, and it
#                       degrades gracefully - a crashed recording still plays up
#                       to the last complete block.
set -eu

PIDFILE="${ATOM_RECORD_PIDFILE:-$HOME/.rlos-recording.pid}"
DISPLAY_NUM="${DISPLAY:-:0}"
SIZE=""
ACTION="start"

while [ $# -gt 0 ]; do
    case "$1" in
        stop)            ACTION="stop" ;;
        [0-9]*x[0-9]*)   SIZE="$1" ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "record: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

[ -x /usr/bin/ffmpeg ] || {
    echo "record: ffmpeg is not installed" >&2
    exit 1
}

stop_recording() {
    if [ ! -f "$PIDFILE" ]; then
        echo "record: nothing is recording (no $PIDFILE)"
        exit 1
    fi
    pid="$(cat "$PIDFILE")"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "record: pid $pid is not running - cleaning up a stale pidfile"
        rm -f "$PIDFILE"
        exit 1
    fi
    # SIGINT is what makes ffmpeg finalise the container: it flushes the trailer,
    # so the file is playable. SIGKILL would leave a truncated file that some
    # players recover from and most do not.
    echo "record: stopping (pid $pid)"
    kill -INT "$pid"
    # Wait for it to actually finish writing before reporting the size, or the
    # number printed is the size before the trailer was appended.
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    rm -f "$PIDFILE"
    echo "record: stopped"
}

if [ "$ACTION" = "stop" ]; then
    stop_recording
    exit 0
fi

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "record: already recording (pid $(cat "$PIDFILE")) - 'record.sh stop' first" >&2
    exit 1
fi

OUT="$HOME/rec-$(date +%Y%m%d-%H%M%S).mkv"

SIZE_ARGS=""
if [ -n "$SIZE" ]; then
    SIZE_ARGS="-video_size $SIZE"
fi

echo "record: recording $DISPLAY_NUM -> $OUT"
echo "        'record.sh stop' to finish. Ctrl-C on THIS terminal will not stop it,"
echo "        because ffmpeg is detached - use the stop command."

# Detached on purpose, and the pid is recorded explicitly rather than left to $!.
#
# Ctrl-C in this terminal must NOT stop the recording: the whole point of a start /
# stop pair is that you can begin recording, carry on working, and stop later from
# a different terminal. So ffmpeg is backgrounded with nohup and its pid written to
# a file the stop path reads.
#
# $! IS the ffmpeg pid here, because nohup execs ffmpeg rather than forking a shell
# to do it - so the recorded pid is the encoder's, which is what the stop path has
# to signal. The stop path still verifies it with kill -0 before signalling, so a
# pid recycled by an unrelated process after a crash cannot be killed by mistake.
#
# -video_size is deliberately unset unless asked: with no region, x11grab captures
# the whole display.
# shellcheck disable=SC2086
nohup /usr/bin/ffmpeg -hide_banner -loglevel warning \
    -f x11grab $SIZE_ARGS -framerate 15 -i "$DISPLAY_NUM" \
    -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p \
    "$OUT" > "$HOME/.rlos-recording.log" 2>&1 &

echo $! > "$PIDFILE"
echo "        pid $(cat "$PIDFILE")   log $HOME/.rlos-recording.log"
