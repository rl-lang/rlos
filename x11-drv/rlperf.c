/*
 * rlperf - report why the desktop feels slow.
 *
 * WHY IT EXISTS
 * -------------
 * Input works but everything is laggy, and "laggy" does not say why. Two very
 * different causes need opposite fixes, and nothing in the boot log separates
 * them:
 *
 *   1. Something is spinning, starving X of CPU. Fix: find the spinner.
 *   2. Nothing is spinning and X is still slow, because every screen update
 *      costs a full-screen copy. Fix: stop doing that.
 *
 * The measurement that tells them apart is per-process CPU time: if Xorg is
 * near 100% of one core it is being kept busy (case 1 or 2 with X the busy
 * part), and if every process is idle then the machine is waiting on something
 * other than computation (case 2, latency rather than throughput).
 *
 * This exists as a guest command rather than a log line for a specific
 * reason: the diagnostic output has to land somewhere the user can read it.
 * The boot log goes to the serial console, which a laptop has no port for, and
 * the text console is covered by Xorg's own VT. On-screen is the only place
 * that works, and the user already has a working keyboard and shell - just no
 * tools, since rlsh ships only ls, wc, rm, whoami and hostname.
 *
 * Reads /proc and /dev/fb0 only. No dependencies.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <linux/fb.h>

#define MAX_WATCH 8
#define MAX_NAME 32

struct proc {
    int pid;
    long ticks;
    char name[MAX_NAME];
};

/* procfs publishes CPU time in clock ticks, not seconds. */
static long clock_ticks(void)
{
    long v = sysconf(_SC_CLK_TCK);
    return v > 0 ? v : 100;
}

static void
read_file(const char *path, char *buf, size_t cap)
{
    int fd = open(path, O_RDONLY);
    ssize_t n;

    buf[0] = '\0';
    if (fd < 0)
        return;
    n = read(fd, buf, cap - 1);
    close(fd);
    if (n < 0)
        n = 0;
    buf[n] = '\0';
}

/* Strip the trailing newline so output lines up without printf gymnastics. */
static void
chomp(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r'))
        s[--n] = '\0';
}


/* Total jiffies any process has used: sum of fields 14+15 over all of /proc. */
static long
total_ticks(void)
{
    DIR *d = opendir("/proc");
    struct dirent *e;
    long sum = 0;

    if (!d)
        return 0;
    while ((e = readdir(d))) {
        char path[80], buf[1024];
        char *p;
        long utime, stime;

        if (e->d_name[0] < '0' || e->d_name[0] > '9')
            continue;
        snprintf(path, sizeof(path), "/proc/%.32s/stat", e->d_name);
        read_file(path, buf, sizeof(buf));
        if (!buf[0])
            continue;
        /* The comm field is in parentheses and may itself contain spaces or
         * parentheses, so fields are counted from after its closing ')'. */
        p = strrchr(buf, ')');
        if (!p)
            continue;
        /* after ") " the fields are state(3) ppid(4) ... utime(14) stime(15) */
        p++;
        {
            int field = 2;
            utime = stime = 0;
            while (*p == ' ')
                p++;
            while (*p) {
                char *end;
                long v = strtol(p, &end, 10);
                if (end == p)
                    break;
                field++;
                if (field == 14)
                    utime = v;
                else if (field == 15) {
                    stime = v;
                    break;
                }
                p = end;
                while (*p == ' ')
                    p++;
            }
            sum += utime + stime;
        }
    }
    closedir(d);
    return sum;
}

static long
proc_ticks(int pid)
{
    char path[80], buf[1024], *p;
    long utime = 0, stime = 0;
    int field = 2;

    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    read_file(path, buf, sizeof(buf));
    if (!buf[0])
        return -1;
    p = strrchr(buf, ')');
    if (!p)
        return -1;
    p++;
    while (*p == ' ')
        p++;
    while (*p) {
        char *end;
        long v = strtol(p, &end, 10);
        if (end == p)
            break;
        field++;
        if (field == 14)
            utime = v;
        else if (field == 15) {
            stime = v;
            break;
        }
        p = end;
        while (*p == ' ')
            p++;
    }
    return utime + stime;
}

static int
find_pid(const char *name)
{
    DIR *d = opendir("/proc");
    struct dirent *e;
    int found = 0;

    if (!d)
        return -1;
    while (!found && (e = readdir(d))) {
        char path[80], buf[1024];

        if (e->d_name[0] < '0' || e->d_name[0] > '9')
            continue;
        snprintf(path, sizeof(path), "/proc/%.32s/comm", e->d_name);
        read_file(path, buf, sizeof(buf));
        if (!buf[0])
            continue;
        chomp(buf);
        if (strcmp(buf, name) != 0)
            continue;
        found = atoi(e->d_name);
    }
    closedir(d);
    return found;
}

/*
 * Time a single full-screen write to /dev/fb0.
 *
 * This is the measurement that matters for the framebuffer path. Xorg's fbdev
 * DDX has no damage tracking, so it treats most updates as whole-screen, and
 * every one of those is a memcpy of the full buffer into the EFI framebuffer
 * the firmware handed us. If that copy is slow, no amount of CPU will fix the
 * lag and the answer is "do less of it", not "work faster".
 */
static void
time_framebuffer(void)
{
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    int fd = open("/dev/fb0", O_RDWR);
    size_t bytes, off;
    unsigned char *buf;
    struct timeval t0, t1;
    double ms;
    int i;

    if (fd < 0) {
        printf("framebuffer : cannot open /dev/fb0 (%s)\n", strerror(errno));
        return;
    }
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) == 0) {
        printf("fb geometry : %ux%u virtual %ux%u, %u bpp\n",
               vinfo.xres, vinfo.yres, vinfo.xres_virtual, vinfo.yres_virtual,
               vinfo.bits_per_pixel);
    }
    /* smem_len is the real mapped size and is what we can actually write;
     * fall back to the visible geometry only if the ioctl gave us nothing. */
    if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) == 0 && finfo.smem_len)
        bytes = finfo.smem_len;
    else
        bytes = (size_t) vinfo.xres * vinfo.yres *
                ((vinfo.bits_per_pixel + 7) / 8);
    if (bytes == 0)
        bytes = (size_t) vinfo.xres * vinfo.yres *
                ((vinfo.bits_per_pixel + 7) / 8);

    printf("fb size     : %zu bytes (%.1f MB) per full-screen write\n",
           bytes, bytes / 1048576.0);

    buf = malloc(bytes);
    if (!buf) {
        printf("framebuffer : cannot allocate %zu bytes\n", bytes);
        close(fd);
        return;
    }
    memset(buf, 0, bytes);

    /* First write warms the mapping; the second is the steady-state cost. */
    for (i = 0; i < 2; i++) {
        off = 0;
        gettimeofday(&t0, NULL);
        while (off < bytes) {
            ssize_t w = write(fd, buf + off, bytes - off);
            if (w <= 0)
                break;
            off += (size_t) w;
        }
        gettimeofday(&t1, NULL);
        ms = (t1.tv_sec - t0.tv_sec) * 1000.0 +
             (t1.tv_usec - t0.tv_usec) / 1000.0;
        printf("fb write    : %.1f ms for one full-screen write%s\n",
               ms, i == 0 ? " (cold)" : "");
    }

    /* Sequential read is the other half of the path and often the slower one
     * on firmware framebuffers, so it is worth knowing separately. */
    {
        ssize_t r;
        gettimeofday(&t0, NULL);
        while ((r = read(fd, buf, bytes)) > 0)
            ;
        gettimeofday(&t1, NULL);
        ms = (t1.tv_sec - t0.tv_sec) * 1000.0 +
             (t1.tv_usec - t0.tv_usec) / 1000.0;
        printf("fb read     : %.1f ms for one full-screen read\n", ms);
    }

    free(buf);
    close(fd);
}

int
main(void)
{
    static const char *watch[] = { "Xorg", "dwm", "st", "udevd", "klogd" };
    struct proc before[MAX_WATCH], after[MAX_WATCH];
    char buf[4096];
    long t0, t1;
    int i, n = (int) (sizeof(watch) / sizeof(watch[0]));

    printf("=== rlperf ===\n");

    read_file("/proc/loadavg", buf, sizeof(buf));
    chomp(buf);
    printf("loadavg     : %s\n", buf);

    read_file("/proc/meminfo", buf, sizeof(buf));
    {
        char *p = strstr(buf, "MemAvailable:");
        if (p) {
            unsigned long kb = strtoul(p + 13, NULL, 10);
            printf("mem available: %lu MB\n", kb / 1024);
        }
    }

    /* CPU clock and scaling, which is the "is the machine just slow" half.
     * Only the first core's lines: /proc/cpuinfo repeats them per core and on
     * a many-core machine that buries everything else printed here. */
    {
        FILE *f = fopen("/proc/cpuinfo", "r");
        char line[512];
        int shown_model = 0, shown_mhz = 0;
        while (f && fgets(line, sizeof(line), f)) {
            if (!shown_model && strncmp(line, "model name", 10) == 0) {
                char *c = strchr(line, ':');
                if (c) {
                    chomp(c + 1);
                    printf("cpu         : %s\n", c);
                    shown_model = 1;
                }
            } else if (!shown_mhz && strncmp(line, "cpu MHz", 7) == 0) {
                char *c = strchr(line, ':');
                if (c) {
                    chomp(c);
                    printf("cpu clock   :%s\n", c);
                    shown_mhz = 1;
                }
            }
            if (shown_model && shown_mhz)
                break;
        }
        if (f)
            fclose(f);
    }

    {
        static const char *freq[] = {
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver",
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor",
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq",
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq",
        };
        unsigned k;
        for (k = 0; k < sizeof(freq) / sizeof(freq[0]); k++) {
            read_file(freq[k], buf, sizeof(buf));
            chomp(buf);
            if (buf[0])
                printf("cpufreq     : %s\n", buf);
            else
                printf("cpufreq     : (absent) %s\n",
                       strrchr(freq[k], '/') + 1);
        }
    }

    time_framebuffer();

    /*
     * Sample per-process CPU over an interval. Two seconds is long enough for
     * the numbers to mean something and short enough that the user does not
     * think the program has hung.
     */
    printf("\n--- CPU over 2 seconds ---\n");
    for (i = 0; i < n; i++) {
        int pid = find_pid(watch[i]);
        before[i].pid = pid;
        before[i].ticks = pid > 0 ? proc_ticks(pid) : -1;
        snprintf(before[i].name, sizeof(before[i].name), "%s", watch[i]);
    }
    t0 = total_ticks();
    sleep(2);
    t1 = total_ticks();

    for (i = 0; i < n; i++) {
        after[i] = before[i];
        if (before[i].pid > 0)
            after[i].ticks = proc_ticks(before[i].pid);
        if (before[i].ticks < 0 || after[i].ticks < 0) {
            printf("%-10s : not running\n", before[i].name);
            continue;
        }
        {
            long used = after[i].ticks - before[i].ticks;
            long all = t1 - t0;
            double pct_of_machine = all > 0 ? 100.0 * used / all : 0.0;
            double pct_of_core = 100.0 * used / clock_ticks() / 2.0;
            printf("%-10s : %5.1f%% of one core (%5.1f%% of machine, pid %d)\n",
                   before[i].name, pct_of_core, pct_of_machine,
                   before[i].pid);
        }
    }

    printf("\nIf Xorg is near 100%% of a core, it is the busy one and the cost is\n"
           "in what it draws. If everything here is idle, the lag is not CPU\n"
           "and the fb write timing above is where to look.\n");
    return 0;
}