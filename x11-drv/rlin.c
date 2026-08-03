/*
 * rlin - report what the guest's input layer actually exposes.
 *
 * WHY THIS EXISTS
 * ---------------
 * Input devices go missing in ways the boot log does not explain. The kernel
 * boots at loglevel=3, which suppresses input core's own evdev registration
 * messages, so from the log alone there is no way to tell "the kernel never
 * created a node" (a kernel config problem) from "the node is there and the
 * driver will not use it" (a driver problem). Reading linux/.config on the
 * build host is not evidence either: it is not the config the running bzImage
 * was built from. This runs in the guest and checks each link in the chain
 * directly.
 *
 * It is also the only way to read a report off a machine whose input is
 * broken: the report that explains a dead keyboard is written while X starts,
 * and X covers the text console with a desktop nobody can type into. The
 * "rlOS (live, diagnose input)" GRUB entry runs this and deliberately does not
 * start X, so the answer stays on the framebuffer where it can be read - or
 * photographed - without needing the thing being diagnosed.
 *
 * The classification lines below are a model of what a consumer of
 * /dev/input/event* has to work out, not a report on any one driver. libinput
 * does its own classification, with far more of it, including touchpads and
 * trackpoints. Use these lines to see what hardware is present and what it
 * reports, and let the X log say whether the driver then attaches.
 *
 * A diagnostic, not part of the session. Drop it once input works.
 *
 * What each section establishes:
 *   - /dev/input         does the directory exist, and is it empty?
 *   - open()             can we open each node at all, as root?
 *   - EVIOCGBIT(0)       does the node answer the evdev bitset query? A node
 *                        that opens but fails this is not usable by Xft-free
 *                        evdev drivers either, which is a different bug from
 *                        the node not existing.
 *   - /sys/class/input   the driver's own view, independent of /dev. A
 *                        populated sysfs with an empty /dev/input pins the
 *                        fault to node creation specifically.
 *   - bitsets            which event types and keys each node claims, so a
 *                        keyboard/mouse mix-up is visible rather than guessed.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#include <linux/input.h>

#define MAX_NODES 32

/*
 * Bitset shape and bit test. A bitset for evdev code range n is
 * ((n / 64) + 1) unsigned longs, and a bit is set when
 * (bits[n / 64] >> (n % 64)) & 1.
 */
#define BIT_WORDS(max) (((max) / 64) + 1)

static int
bit_is_set(const unsigned long *bits, int b)
{
    return (bits[b >> 6] >> (b & 63)) & 1;
}

static void
print_set_bits(const unsigned long *bits, int max, const char *label)
{
    int i, printed = 0;
    for (i = 0; i <= max; i++) {
        if (bit_is_set(bits, i)) {
            printf("%s%s%d", printed ? "," : "", label, i);
            printed++;
        }
    }
    if (!printed)
        printf("(none)");
    printf("\n");
}

/*
 * Ask the node what it advertises. An EVIOCGBIT failure is reported as a
 * distinct outcome rather than folded into "nothing usable", because the two
 * mean different things: a node that will not answer the query is a different
 * problem from a node that answers and has nothing we want.
 *
 * Note EVIOCGBIT returns the number of bytes copied, not 0, on success. A
 * "== 0" test here reads as "this device has no capabilities" against
 * hardware that is present and working.
 */
static int
probe_node(const char *path)
{
    unsigned long evbits[BIT_WORDS(EV_MAX)];
    unsigned long relbits[BIT_WORDS(REL_MAX)];
    unsigned long absbits[BIT_WORDS(ABS_MAX)];
    unsigned long keybits[BIT_WORDS(KEY_MAX)];
    struct stat st;
    int fd, i;
    static const char *ev_names[] = {
        "SYN", "KEY", "REL", "ABS", "MSC", "SW", "LED", "SND",
        "REP", "FF", "PWR", "FF_STATUS"
    };

    printf("  %s\n", path);

    if (stat(path, &st) != 0) {
        printf("    stat: FAILED (%s)\n", strerror(errno));
        return 0;
    }
    printf("    stat: ok, char device %u:%u\n",
           (unsigned) major(st.st_rdev), (unsigned) minor(st.st_rdev));

    fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        printf("    open: FAILED (%s)  <-- node exists but is not openable\n",
               strerror(errno));
        return 0;
    }
    printf("    open: ok (fd %d)\n", fd);

    memset(evbits, 0, sizeof evbits);
    if (ioctl(fd, EVIOCGBIT(0, sizeof evbits), &evbits) < 0) {
        printf("    EVIOCGBIT(0): FAILED (%s)  <-- not a usable evdev node\n",
               strerror(errno));
        close(fd);
        return 0;
    }
    printf("    EVIOCGBIT(0): ok\n");

    printf("    event types:");
    for (i = 0; i <= EV_MAX; i++) {
        if (bit_is_set(evbits, i))
            printf(" %s", (size_t) i < sizeof ev_names / sizeof ev_names[0]
                           ? ev_names[i] : "?");
    }
    printf("\n");

    memset(relbits, 0, sizeof relbits);
    if (ioctl(fd, EVIOCGBIT(EV_REL, sizeof relbits), &relbits) >= 0) {
        printf("    relative axes: ");
        print_set_bits(relbits, REL_MAX, "");
    }

    memset(absbits, 0, sizeof absbits);
    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof absbits), &absbits) >= 0) {
        printf("    absolute axes: ");
        print_set_bits(absbits, ABS_MAX, "");
    }

    memset(keybits, 0, sizeof keybits);
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keybits), &keybits) >= 0) {
        /* Only a short prefix of the key range. This report may have to be
         * read off a screen by someone whose keyboard does not work, and a
         * full key dump wraps into unreadable slivers. */
        int n = 0;
        for (i = KEY_ESC; i <= KEY_MICMUTE && n < 12; i++) {
            if (bit_is_set(keybits, i)) {
                if (n == 0)
                    printf("    keys:");
                printf(" %d", i);
                n++;
            }
        }
        if (n == 12)
            printf(" ...");
        if (n)
            printf("\n");

        /* A plain capability summary. The return value decides this program's
         * exit status, which is what init uses to decide whether a desktop is
         * worth starting, so it must track the verdict printed here. */
        if (bit_is_set(keybits, KEY_A) || bit_is_set(keybits, KEY_ESC))
            printf("    would classify: KEYBOARD\n");
        else if (bit_is_set(evbits, EV_REL) && bit_is_set(relbits, REL_X)) {
            printf("    would classify: POINTER (relative)\n");
            return 1;
        } else if (bit_is_set(evbits, EV_ABS)) {
            printf("    would classify: POINTER (absolute)\n");
            return 1;
        } else {
            printf("    would classify: UNUSABLE <- nothing here handles it\n");
        }
        return 1;
    }

    close(fd);
    return 0;
}

static void
list_dir(const char *label, const char *dir)
{
    DIR *d = opendir(dir);
    struct dirent *e;
    int n = 0;

    printf("%s (%s):\n", label, dir);
    if (!d) {
        printf("  opendir: FAILED (%s)\n", strerror(errno));
        return;
    }
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        printf("  %s\n", e->d_name);
        n++;
    }
    closedir(d);
    if (n == 0)
        printf("  (empty)\n");
}

int
main(void)
{
    char path[64];
    int i, found = 0, usable = 0;

    printf("=== evdev probe (uid %d) ===\n", (int) getuid());

    /*
     * 1. sysfs first. This is the driver's own view of the input layer and
     * does not depend on /dev at all, so it separates "the kernel has no
     * input devices" from "the kernel has them but made no nodes".
     */
    list_dir("input devices", "/sys/class/input");
    printf("  /proc/bus/input/devices:\n");
    {
        FILE *f = fopen("/proc/bus/input/devices", "r");
        if (!f) {
            printf("    (cannot open: %s)\n", strerror(errno));
        } else {
            char line[512];
            while (fgets(line, sizeof line, f)) {
                char *nl = strchr(line, '\n');
                if (nl)
                    *nl = 0;
                if (strncmp(line, "I:", 2) == 0)
                    printf("    I: %s\n", line + 2);
                else if (strncmp(line, "H:", 2) == 0)
                    printf("    H: %s\n", line + 2);
            }
            fclose(f);
        }
    }

    /* 2. The nodes themselves. */
    list_dir("/dev/input", "/dev/input");

    for (i = 0; i < MAX_NODES; i++) {
        struct stat st;
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        if (stat(path, &st) == 0) {
            found++;
            usable += probe_node(path);
        }
    }
    if (found == 0)
        printf("no /dev/input/event* nodes exist at all (tried event0..%d)\n",
               MAX_NODES - 1);

    /*
     * 3. Verdict. The three outcomes need three different fixes, and they are
     * worth stating outright rather than leaving inferred from the sections
     * above.
     */
    printf("=== verdict ===\n");
    {
        DIR *d = opendir("/sys/class/input");
        int sysfs_devices = 0;
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)))
                if (e->d_name[0] != '.' &&
                    strncmp(e->d_name, "event", 5) == 0)
                    sysfs_devices++;
            closedir(d);
        }
        if (sysfs_devices == 0 && found == 0) {
            printf("no input devices and no evdev nodes: check the kernel\n"
                   "config for CONFIG_INPUT_EVDEV and CONFIG_INPUT\n");
        } else if (sysfs_devices > 0 && found == 0) {
            printf("input devices EXIST (%d in sysfs) but no /dev/input/event* nodes\n"
                   "were created: the running kernel lacks CONFIG_INPUT_EVDEV, or\n"
                   "devtmpfs is not mounting them. This is a kernel-side fix.\n",
                   sysfs_devices);
        } else if (usable == 0) {
            printf("%d evdev node(s) exist but NONE looks like a keyboard or a\n"
                   "pointer. The X session would come up with no input at all.\n", found);
        } else if (usable == 1) {
            printf("%d evdev node(s) exist, %d usable. A desktop needs one of each\n"
                   "role; with only %d, expect a keyboard-only or pointer-only\n"
                   "session.\n", found, usable, usable);
        } else {
            printf("%d evdev node(s) exist, %d usable: enough for a keyboard and\n"
                   "a pointer.\n", found, usable);
        }
    }

    /*
     * Exit status is the machine-readable answer, so init can decide whether
     * starting a desktop is worth doing at all:
     *   0 - a keyboard and a pointer are both present and usable
     *   2 - something is missing, and starting X would only hide the report
     *       behind an unusable desktop
     */
    if (usable >= 2)
        return 0;
    return 2;
}
