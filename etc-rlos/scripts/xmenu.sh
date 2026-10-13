#!/bin/sh
# xmenu.sh - the rlOS application menu.
#
# xmenu itself has no idea what rlOS contains: it reads a menu SPECIFICATION on
# stdin, draws it, and prints the chosen entry to stdout. This script is the
# specification - it is what turns a generic X11 menu tool into a menu of the
# programs this image actually ships.
#
# THE SPEC FORMAT, from xmenu's parsestdin():
#   - the number of LEADING TABS is the nesting level (strspn(buf, "\t"))
#   - fields within a line are separated by tabs
#   - an optional first field of the form IMG:/path/to/file supplies an icon
#   - a line may be just a label, in which case the label is also the command
#   - a lone ":" is a separator, or makes an item unselectable
#   - a label of '' at the same level as the previous line sets that item's
#     middle-click alternative action
#
# Tabs are written with printf rather than typed literally into this file,
# because the field separator is invisible: one space instead of one tab
# produces a menu that silently nests wrongly, or not at all.
#
# The selection is run with sh -c, as upstream's own examples/xmenu.sh does.
# Every command below is a literal string written here, never anything read
# from a file or from the environment.
set -eu

command -v xmenu > /dev/null 2>&1 || {
    echo "xmenu: not installed - this is not a desktop image" >&2
    exit 1
}

TAB="$(printf '\t')"
MENU=""

# add <label> [command] - a top-level entry.
add() {
    if [ $# -ge 2 ]; then
        MENU="${MENU}$1${TAB}$2
"
    else
        MENU="${MENU}$1
"
    fi
}

# sub <label> [command] - one level in.
sub() {
    if [ $# -ge 2 ]; then
        MENU="${MENU}${TAB}$1${TAB}$2
"
    else
        MENU="${MENU}${TAB}$1
"
    fi
}

sep() { MENU="${MENU}${TAB}:
"; }

# The terminal differs by backend - mlterm under X11, foot under Wayland - and
# this script is staged into EVERY image including the text-only one, so it
# cannot assume either exists. Entries are dropped rather than listed-and-broken.
if command -v foot > /dev/null 2>&1; then
    add "Applications"
    sub "Terminal" "foot"
elif command -v mlterm > /dev/null 2>&1; then
    add "Applications"
    sub "Terminal" "mlterm"
else
    add "Applications"
fi

command -v xfiles   > /dev/null 2>&1 && sub "Files"         "xfiles $HOME"
command -v w3m      > /dev/null 2>&1 && sub "Browser"       "w3m https://duckduckgo.com"
command -v feh      > /dev/null 2>&1 && sub "Image viewer"  "feh"
command -v ttyrec   > /dev/null 2>&1 && sub "Record session" "ttyrec $HOME/session.log"
sep

add "System"
command -v btop      > /dev/null 2>&1 && sub "Monitor"     "btop"
command -v fastfetch > /dev/null 2>&1 && sub "System info" "fastfetch"
[ -x "$HOME/scripts/atom-shell.sh" ] && sub "Atom container" "$HOME/scripts/atom-shell.sh"
sub "Login shell" "/bin/ash -l"
sep
sub "Reboot"    "reboot"
sub "Power off" "poweroff"

# -p takes a GEOMETRY, not a word: 50%+50% places the centre of the menu at the
# centre of the screen (the % makes each offset relative to the screen rather
# than to its top-left corner). "center" is not a valid -p argument - it is the
# value of the XMenu.alignment resource, which aligns text inside an entry.
CHOICE="$(printf '%s' "$MENU" | xmenu -p '50%+50%')"
[ -n "$CHOICE" ] || exit 0

# exec so the launched program replaces this script rather than leaving it
# waiting behind the program it just started.
exec sh -c "$CHOICE"