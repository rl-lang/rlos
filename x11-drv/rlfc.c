/*
 * rlfc - report what fontconfig and Xft actually resolve inside the guest.
 *
 * WHY THIS EXISTS
 * ---------------
 * st exits with
 *     can't open font JetBrainsMono Nerd Font Mono:pixelsize=14:...
 * st has four separate die() sites that print that identical string, and the
 * message does not say which one fired. st.c:1021 is the one that matters, and
 * it is reached only if all of these succeed in order:
 *
 *     1. FcNameParse(fontstr)                     (x.c:992  -> die at 995)
 *     2. FcPatternDuplicate + FcConfigSubstitute
 *        + XftDefaultSubstitute                   (x.c:924-931)
 *     3. FcFontMatch                              (x.c:933  -> return 1)
 *     4. XftFontOpenPattern(dpy, match)           (x.c:937  -> return 1)
 *
 * Host-side reproduction is useless here: it loads the *host's* fontconfig
 * config and the *host's* X server, so it cannot answer what the guest does.
 * This runs in the guest, against the same libs the session uses, and reports
 * each of the four steps separately.
 *
 * A previous version of this probe reported a single pass/fail from
 * XftFontOpen() and printed "XftFontOpen returned NULL". That call was wrong:
 * XftFontOpen's third parameter is a `const char *` pattern *string* (it is
 * variadic, printf-style, and feeds FcPatternVaBuild), but the probe was
 * passing an `FcPattern *`. fontconfig therefore parsed the bytes of a
 * pointer as a pattern string, and the resulting failure was an artifact of
 * the probe rather than a fact about the guest. st itself never calls
 * XftFontOpen - x.c:937 uses XftFontOpenPattern, which does take an
 * FcPattern. So the probe now mirrors x.c exactly.
 *
 * It is a diagnostic, not part of the session, and can be dropped once the
 * font question is settled.
 *
 * With XFT_DEBUG=3 in the environment, libXft narrates alongside this
 * (xftdbg.c:36, bits from xftint.h:279-289: OPEN=1, OPENV=2):
 *   - "XftFontInfoFill: <file>: <id> (<n> pixels)" proves the match produced a
 *     usable FC_FILE and a pixel size, and that execution reached
 *     xftfreetype.c:435. A failure after this line is inside FreeType.
 *   - "No Match" means FcFontMatch failed; "No Font" means it succeeded but
 *     XftFontOpenPattern failed.
 */

#include <fontconfig/fontconfig.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xrender.h>
#include <Xft.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The pattern st is built with, from build_x11.sh's config.h patch. Kept as a
 * literal so this reports on the real request rather than a guess at it. */
#define ST_PATTERN "JetBrainsMono Nerd Font Mono:pixelsize=14:antialias=true:autohint=true"

/* A control with no property list, to separate "this family is unreachable"
 * from "this property list is the problem". */
#define ST_PATTERN_MIN "JetBrainsMono Nerd Font Mono"

static const char *
str_or_null(FcChar8 *s)
{
    return s ? (const char *)s : "(none)";
}

static void
list_dirs(const char *label, FcStrList *list)
{
    FcChar8 *e;
    int n = 0;

    printf("  %s:", label);
    while (list && (e = FcStrListNext(list))) {
        struct stat st;
        int writable = (stat((const char *)e, &st) == 0) && (access((const char *)e, W_OK) == 0);
        printf(" [%s%s]", (const char *)e, writable ? "" : " (not writable)");
        n++;
    }
    if (n == 0)
        printf(" (none)");
    printf("\n");
}

/*
 * The body of st's xloadfont(), in the same order, reporting each step.
 * Returns 0 if the font opened, 1 if it did not - the same meaning st gives
 * the return value, so "0" here and "no die" there agree.
 */
static int
xloadfont_like_st(Display *dpy, int screen, const char *fontstr, const char *label)
{
    FcPattern *pattern, *configured, *match;
    FcResult result;
    XftFont *font;
    FcChar8 *file = 0, *family = 0;

    printf("--- %s: %s\n", label, fontstr);
    fflush(stdout);

    /* step 1: parse (x.c:992). A parse failure dies at x.c:995. */
    pattern = FcNameParse((const FcChar8 *)fontstr);
    if (!pattern) {
        printf("    step 1 FcNameParse: FAILED  <-- st would die at x.c:995\n");
        return 1;
    }
    printf("    step 1 FcNameParse: ok\n");

    /* step 2: substitute (x.c:924-931). NULL config means "current", which is
     * what st passes. XftDefaultSubstitute is Xft's, not fontconfig's: it
     * folds in X resources and sets Xft-specific properties. */
    configured = FcPatternDuplicate(pattern);
    if (!configured) {
        printf("    step 2 FcPatternDuplicate: FAILED\n");
        FcPatternDestroy(pattern);
        return 1;
    }
    FcConfigSubstitute(NULL, configured, FcMatchPattern);
    XftDefaultSubstitute(dpy, screen, configured);
    printf("    step 2 substitute: ok\n");

    /* step 3: match (x.c:933). */
    match = FcFontMatch(NULL, configured, &result);
    if (!match) {
        printf("    step 3 FcFontMatch: FAILED (result=%d)  <-- st would return 1\n", result);
        FcPatternDestroy(configured);
        FcPatternDestroy(pattern);
        return 1;
    }
    FcPatternGetString(match, FC_FAMILY, 0, &family);
    FcPatternGetString(match, FC_FILE, 0, &file);
    printf("    step 3 FcFontMatch: ok (result=%d) family=%s file=%s\n",
           result, str_or_null(family), str_or_null(file));
    if (!file) {
        printf("    step 3 matched a pattern with no FC_FILE - nothing to render with\n");
        FcPatternDestroy(match);
        FcPatternDestroy(configured);
        FcPatternDestroy(pattern);
        return 1;
    }

    /* Confirm the guest can actually read the file fontconfig picked. FcFontMatch
     * resolves by name; if this fopen fails, FT_New_Face inside Xft is the next
     * thing to fail, several steps away and with no message of its own. */
    {
        FILE *fp = fopen((const char *)file, "rb");
        if (!fp) {
            printf("    step 3b fopen(%s): FAILED (errno=%d)  <-- not readable in guest\n",
                   (const char *)file, errno);
        } else {
            struct stat st;
            unsigned char magic[4] = {0, 0, 0, 0};
            size_t nread = fread(magic, 1, sizeof magic, fp);
            fclose(fp);
            if (stat((const char *)file, &st) == 0)
                printf("    step 3b fopen(%s): ok (%ld bytes, magic %02x%02x%02x%02x)\n",
                       (const char *)file, (long)st.st_size,
                       magic[0], magic[1], magic[2], magic[3]);
            else
                printf("    step 3b fopen(%s): ok (magic %02x%02x%02x%02x, %lu read)\n",
                       (const char *)file,
                       magic[0], magic[1], magic[2], magic[3], (unsigned long)nread);
        }
    }

    /* step 4: open through Xft (x.c:937). */
    font = XftFontOpenPattern(dpy, match);
    if (!font) {
        printf("    step 4 XftFontOpenPattern: FAILED (NULL)  <-- st would return 1 -> die at x.c:1021\n");
        FcPatternDestroy(match);
        FcPatternDestroy(configured);
        FcPatternDestroy(pattern);
        return 1;
    }
    printf("    step 4 XftFontOpenPattern: ok (ascent=%d descent=%d max_adv=%d)\n",
           font->ascent, font->descent, font->max_advance_width);
    XftFontClose(dpy, font);
    FcPatternDestroy(match);
    FcPatternDestroy(configured);
    FcPatternDestroy(pattern);
    return 0;
}

int
main(void)
{
    FcConfig *config;
    const char *env;

    env = getenv("FONTCONFIG_FILE");
    printf("FONTCONFIG_FILE=%s\n", env ? env : "(unset)");
    env = getenv("FONTCONFIG_PATH");
    printf("FONTCONFIG_PATH=%s\n", env ? env : "(unset)");
    env = getenv("XFT_DEBUG");
    printf("XFT_DEBUG=%s\n", env ? env : "(unset)");
    printf("fontconfig runtime version=%d.%d.%d\n",
           FcGetVersion() / 10000, (FcGetVersion() / 100) % 100, FcGetVersion() % 100);

    if (!FcInit()) {
        printf("FAIL: FcInit\n");
        return 1;
    }
    if (!FcInitLoadConfigAndFonts()) {
        printf("FAIL: FcInitLoadConfigAndFonts - the config did not load\n");
        return 1;
    }
    config = FcConfigGetCurrent();
    printf("config loaded\n");

    {
        /* FcConfigGetConfigFile does not exist; FcConfigGetConfigFiles is the
         * plural form and returns the list actually in use. */
        FcStrList *cf = FcConfigGetConfigFiles(config);
        FcChar8 *e;
        int n = 0;
        printf("  config files:");
        while (cf && (e = FcStrListNext(cf))) {
            printf(" [%s]", (const char *)e);
            n++;
        }
        if (!n)
            printf(" (none - fontconfig is using built-in defaults)");
        printf("\n");
    }
    list_dirs("cache dirs", FcConfigGetCacheDirs(config));
    list_dirs("font dirs", FcConfigGetFontDirs(config));

    {
        const char *dpy_name = getenv("DISPLAY");
        Display *dpy;
        int screen, event_base, error_base, rc;

        if (!dpy_name || !*dpy_name) {
            printf("XFT: skipped, no DISPLAY\n");
            return 0;
        }
        printf("XFT: opening display %s\n", dpy_name);
        fflush(stdout);

        dpy = XOpenDisplay(NULL);
        if (!dpy) {
            printf("XFT: cannot open display %s\n", dpy_name);
            return 1;
        }
        screen = DefaultScreen(dpy);
        printf("XFT: display opened, screen %d depth %d\n", screen, DefaultDepth(dpy, screen));

        /* Informational: Xft tolerates a missing RENDER extension at open
         * time (xftdpy.c:103 just clears info->hasRender), so this is not
         * expected to be the cause, but it is worth having on the record. */
        if (XRenderQueryExtension(dpy, &event_base, &error_base)) {
            int major = 0, minor = 0;
            XRenderQueryVersion(dpy, &major, &minor);
            printf("XFT: RENDER extension present, version %d.%d\n", major, minor);
        } else {
            printf("XFT: RENDER extension ABSENT (not fatal for opening fonts)\n");
        }

        /* The real request, then a property-list-free control. */
        rc  = xloadfont_like_st(dpy, screen, ST_PATTERN,      "st's exact pattern");
        rc |= xloadfont_like_st(dpy, screen, ST_PATTERN_MIN,  "control, family only");

        XCloseDisplay(dpy);
        printf("RESULT: %s\n", rc ? "font did NOT open" : "font opened");
        return rc;
    }
}
