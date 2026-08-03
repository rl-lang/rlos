#!/bin/sh
# shot.sh - screenshot this machine with ffmpeg.
#
# ffmpeg rather than a dedicated screenshot tool, because ffmpeg is already here
# and a dedicated one is not. The historical alternative here was maim, which is
# smaller - and which this build cannot use: every current maim hard-requires
# SLOP and GLM for an OpenGL magnifier, and this image has no GL stack at all. imv
# had the same problem plus a 30MB ICU dependency. So ffmpeg's x11grab, which
# needs neither.
#
# ffmpeg's screen-capture device is x11grab on the command line but xcbgrab in the
# build system. Same thing - libavdevice/xcbgrab.c sets .p.name = "x11grab" - so
# "-f x11grab" is correct here and "--enable-indev=x11grab" would silently
# configure nothing.
#
#   shot.sh                  whole screen -> ~/shot-<timestamp>.png
#   shot.sh 5                5-second countdown first
#   shot.sh out.png          choose the filename
#   shot.sh 1920x1080        force a capture size
set -eu

OUT=""
DELAY=0
SIZE=""
DISPLAY_NUM="${DISPLAY:-:0}"

while [ $# -gt 0 ]; do
    case "$1" in
        # A WxH argument is a size, not a delay: 1080x1920 is unambiguous and
        # guessing wrong on "1920x1080" would mean an 83-hour sleep.
        [0-9]*x[0-9]*) SIZE="$1" ;;
        [0-9]*)        DELAY="$1" ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) OUT="$1" ;;
    esac
    shift
done

[ -x /usr/bin/ffmpeg ] || {
    echo "shot: ffmpeg is not installed" >&2
    exit 1
}

[ -n "$OUT" ] || OUT="$HOME/shot-$(date +%Y%m%d-%H%M%S).png"

if [ "$DELAY" -gt 0 ]; then
    echo "shot: ${DELAY}s..."
    sleep "$DELAY"
fi

# -video_size is only meaningful for a REGION. Given no region, x11grab defaults
# to the whole display, so omitting it is both correct and one less thing to get
# wrong. There is deliberately no xdpyinfo call here to discover the display
# size: xdpyinfo, xwininfo and xdotool are all absent from this image, and a
# script that shells out to a missing tool to compute a value it does not need is
# a script that breaks for no reason.
#
# x264 is not involved - this is a still, and the png encoder is what runs.
# -update 1 is what makes the output ONE file: without it the image2 muxer writes
# a numbered sequence, which is the usual reason a screenshot command produces
# shot-001.png instead of shot.png.
if [ -n "$SIZE" ]; then
    ffmpeg -hide_banner -loglevel error -y \
        -f x11grab -video_size "$SIZE" -i "$DISPLAY_NUM" \
        -frames:v 1 -update 1 "$OUT"
else
    ffmpeg -hide_banner -loglevel error -y \
        -f x11grab -i "$DISPLAY_NUM" \
        -frames:v 1 -update 1 "$OUT"
fi

echo "shot: wrote $OUT ($(du -h "$OUT" | cut -f1))"
