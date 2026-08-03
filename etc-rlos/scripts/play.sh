#!/bin/sh
# play.sh - play a recording made by record.sh (or any video ffplay can open).
#
#   play.sh                     newest ~/rec-*.mkv
#   play.sh ~/rec-20260104-101500.mkv
#   play.sh ~/rec-*.mkv         a specific one from the glob
#
# ffplay ships inside the ffmpeg build, so "record a video and watch it back"
# needs no second piece of software. That is the reason ffmpeg was chosen over
# a dedicated screen recorder in the first place: the player is free.
#
# CAVEAT WORTH KNOWING BEFORE YOU TRUST IT: ffplay is minimal. No playlist, no
# configuration file, no on-screen controls. Arrows seek, space pauses, q quits.
# It is a player for "check that the recording worked", not a media library. If
# you want frame-accurate scrubbing and subtitle support, that is mpv, which is
# about 30MB more and wants a GPU this image does not have.
#
# SDL2 is the only output backend ffplay has, and SDL2 pulls in Wayland and VA-API
# libraries at load time whether or not they are ever used. All of them are
# staged, so this resolves; it is just worth knowing why `ldd ffplay` lists so
# much for something that draws one window.
set -eu

[ -x /usr/bin/ffplay ] || {
    echo "play: ffplay is not installed" >&2
    exit 1
}

FILE="${1:-}"

if [ -z "$FILE" ]; then
    # Newest first. `ls -t` is the portable way; a glob sorted alphabetically
    # would pick the oldest recording, which is the wrong one often enough to be
    # annoying.
    FILE="$(ls -t "$HOME"/rec-*.mkv 2>/dev/null | head -1)"
    if [ -z "$FILE" ]; then
        echo "play: no ~/rec-*.mkv found - record something first:" >&2
        echo "      ~/scripts/record.sh    then    ~/scripts/record.sh stop" >&2
        exit 1
    fi
fi

if [ ! -f "$FILE" ]; then
    echo "play: no such file: $FILE" >&2
    exit 1
fi

echo "play: $FILE ($(du -h "$FILE" | cut -f1))"
echo "      space pause, arrows seek, q quit"

# -autoexit so ffplay returns instead of sitting there after the last frame, which
# matters here because these run from a terminal rather than from a desktop
# click. -window-title so the window is identifiable when several are open.
exec /usr/bin/ffplay -autoexit -window-title "rlos: $FILE" "$FILE"
