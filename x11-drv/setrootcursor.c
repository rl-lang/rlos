/*
 * setrootcursor - point the X root window at a themed cursor.
 *
 * WHY THIS IS A SEPARATE PROGRAM
 * ------------------------------
 * Xorg will not theme the root cursor. dix/cursor.c:CreateRootCursor() opens a
 * font literally named "cursor" and builds a glyph cursor out of it, and the
 * whole xorg-server tree contains no reference to libXcursor or XCURSOR_THEME -
 * so the XCURSOR_THEME that init.c puts in the X environment does nothing for
 * the root window. It would only reach GTK and Qt clients, of which there are
 * none here. With no "cursor" font shipped, that glyph cursor degenerates and
 * the pointer is a black block.
 *
 * This was originally a patch inside dwm, and it worked. dwm is being replaced
 * by i3, and i3 does not theme the root cursor either - so if the code went away
 * with dwm the black cursor comes straight back. Hence its own program, which
 * any window manager can live with: init runs it once, before starting the WM,
 * and then gets out of the way.
 *
 * WHY NOT libXcursor's THEME API
 * -------------------------------
 * Because it is not public. The installed X11/Xcursor/Xcursor.h declares the
 * shape and file APIs; the theme functions (XcursorThemeLoadTheme and friends)
 * live in XcursorInt.h, which is not installed. XcursorFilenameLoadCursor IS
 * public, it takes a path, and it returns a ready Cursor - so the theme is
 * located by an explicit path instead of by libXcursor walking
 * $XDG_DATA_DIRS/icons, which is one less thing that can differ from what the
 * build staged.
 *
 * Failure is silent on purpose. If the file is missing or will not decode, the
 * worst case is the unthemed cursor that already existed; printing a warning to
 * a console nobody is watching changes nothing, and exiting non-zero would make
 * init's supervision loop restart this forever.
 */

#include <X11/Xlib.h>
#include <X11/Xcursor/Xcursor.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef CURSOR_PATH
#define CURSOR_PATH "/usr/share/icons/Bibata-Modern-Ice/cursors/left_ptr"
#endif

int
main(int argc, char **argv)
{
	const char *path = (argc > 1) ? argv[1] : CURSOR_PATH;
	Display *dpy;
	Window root;
	int screen;
	Cursor c;

	dpy = XOpenDisplay(NULL);
	if (!dpy) {
		/* No display yet, or DISPLAY is wrong. Nothing to do; not fatal,
		 * because this runs once at boot and the caller does not check. */
		return 0;
	}

	screen = DefaultScreen(dpy);
	root = RootWindow(dpy, screen);

	/* Returns a Cursor directly, doing the size selection internally: it picks
	 * the image closest to the display. */
	c = XcursorFilenameLoadCursor(dpy, path);
	if (c != None)
		XDefineCursor(dpy, root, c);

	XCloseDisplay(dpy);
	return 0;
}