/* setrootbg - paint a solid colour onto the X root window.
 *
 * The desktop background. Nothing in Xorg or i3 will do this from a config
 * file, so like setrootcursor it has to be a client that init runs once before
 * the window manager comes up.
 *
 * A solid fill rather than an image, deliberately: an image needs libpng, a
 * multi-megabyte file in the initramfs, and a decode path that has to be right
 * for every bit depth and visual the server picked - all to end up looking like
 * the two hex digits below. The colour is compiled in and matches the i3bar
 * background so the panel and the desktop are one surface.
 *
 * The pixmap-and-ESETROOT dance rather than a plain XFillRectangle on the root
 * window, because painting root pixels directly does not survive: the server
 * repaints the root from its background pixmap on an expose, and anything that
 * touches the root (a window manager, a fullscreen window closing) will undo it.
 * Setting the background pixmap plus ESETROOT_PMAP makes it the state the
 * server itself restores from.
 *
 * Not static and not linked against libX11's extras beyond core: libX11 is
 * already in the closure for every other binary in the image.
 */

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>

/* The desktop colour: #1a1b26.
 *
 * Tokyo Night Moon, but one step darker than the terminal window (#24273b) and one
 * step lighter than the bar (#16161e). The ordering is the whole point: bar
 * darkest, desktop in the middle, window lightest, so a borderless terminal still
 * reads as a raised surface rather than as a hole punched in the desktop. See the
 * colour block in etc-rlos/i3.config, which sets the bar half of this.
 *
 * The previous value was #313244, which is LIGHTER than the #1b1e28 terminal it
 * sat behind. That inversion is why this file needed an argument at all: a window
 * darker than its own background needs a border to have an edge, and i3 strips
 * borders from every window. With the layering the right way round the problem
 * disappears instead of being worked around.
 */
#define ROOT_R 0x1a
#define ROOT_G 0x1b
#define ROOT_B 0x26

int main(void) {
  Display *dpy;
  int screen;
  Window root;
  Pixmap pixmap;
  GC gc;
  XColor color;

  dpy = XOpenDisplay(NULL);
  if (dpy == NULL) {
    fprintf(stderr, "setrootbg: cannot open display\n");
    return 1;
  }

  screen = DefaultScreen(dpy);
  root = RootWindow(dpy, screen);

  /* Resolve the colour through the server's colormap rather than hardcoding a
   * pixel value, so this is correct on a TrueColor visual and on a palette one
   * alike. A failure here means no colormap entry, not a reason to abort. */
  color.red = (unsigned short)(ROOT_R * 257);
  color.green = (unsigned short)(ROOT_G * 257);
  color.blue = (unsigned short)(ROOT_B * 257);
  color.flags = DoRed | DoGreen | DoBlue;
  if (XAllocColor(dpy, DefaultColormap(dpy, screen), &color) == 0)
    color.pixel = BlackPixel(dpy, screen);

  /* One screen-sized pixmap, filled edge to edge. Screen-sized rather than the
   * root window's current geometry because the root has no size of its own until
   * a window manager reparents things around; DisplayWidth is what is actually
   * being scanned out. */
  pixmap = XCreatePixmap(dpy, root, (unsigned) DisplayWidth(dpy, screen),
                         (unsigned) DisplayHeight(dpy, screen),
                         (unsigned) DefaultDepth(dpy, screen));
  gc = XCreateGC(dpy, pixmap, 0, NULL);
  XSetForeground(dpy, gc, color.pixel);
  XFillRectangle(dpy, pixmap, gc, 0, 0, DisplayWidth(dpy, screen),
                 DisplayHeight(dpy, screen));

  XSetWindowBackgroundPixmap(dpy, root, pixmap);
  XClearWindow(dpy, root);

  /* Tell the world which pixmap holds the root background. This is the EWMH
   * hint that i3 and other clients read before painting anything, and without
   * it a reparent can leave a stale pixmap in place. Two property names are in
   * use for it, and which one a given consumer reads is not something to guess
   * at, so both are set. */
  XChangeProperty(dpy, root, XInternAtom(dpy, "_XROOTPMAP_ID", False), XA_PIXMAP,
                  32, PropModeReplace, (unsigned char *)&pixmap, 1);
  XChangeProperty(dpy, root, XInternAtom(dpy, "ESETROOT_PMAP_ID", False),
                  XA_PIXMAP, 32, PropModeReplace, (unsigned char *)&pixmap, 1);

  XFlush(dpy);
  XCloseDisplay(dpy);
  /* pixmap and gc are deliberately not freed: the server holds a reference to
   * the pixmap as the root background, so destroying it here would put the
   * root back to whatever it was before. They are reclaimed when the server
   * exits, and this process exits immediately after anyway. */
  return 0;
}