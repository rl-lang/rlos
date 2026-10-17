#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <grp.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
/* For sockaddr_in and inet_ntop, used to read the address back off the
 * interface after DHCP. net/if.h above supplies ifreq and SIOCGIFADDR but not
 * the AF_INET types. */
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <termios.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

/* Minimal text-only PID 1 for the initramfs RAM root.
 * Mounts the basics, attaches the kernel console, then runs /bin/rlsh
 * in a respawn loop so exiting the shell gives a fresh one instead
 * of a kernel panic. */

/* Log directory: one place for the kernel log, the Xorg log and init's own.
 * It exists because the console stops being usable the moment the desktop
 * starts - Xorg puts the physical display on its own VT - and a laptop has no
 * serial port to fall back to. After that point a file is the only record. */
#define LOG_DIR   "/log"
#define KMSG_LOG  LOG_DIR "/kmsg"
#define X_LOG     LOG_DIR "/Xorg.log"
#define INIT_LOG  LOG_DIR "/init.log"

/* The single-file atom image: one gzipped tar of the whole container root
 * filesystem, unpacked once into a directory that bwrap then bind-mounts. It
 * lives at the root rather than under /atom because it is a file to unpack, not
 * a root to run in. Defined here rather than spelled at each use because both
 * secure_atom_image() and the boot log have to agree on the name. */
#define ATOM_IMAGE_PATH "/atom-rootfs.tar.gz"

/*
 * init's own message log, opened on first use and append-only.
 *
 * klogd handles the kernel stream and Xorg writes its own log, but init's
 * messages - "X display is up", the generated config, the udev wait - are the
 * ones that explain why one of those two went wrong, and they were previously
 * only ever on the console. Written without the ANSI color that warn() puts on
 * the console, for the same reason klogd's file copy is uncolored: a log full
 * of escape sequences is miserable to read and useless to grep.
 *
 * Failure is silent and non-fatal by design. init is PID 1; it must not exit
 * because a log file could not be opened.
 */
static int init_log_fd = -2; /* -2 = not yet tried, -1 = unavailable */

static void init_log(const char *msg) {
  size_t off = 0, len = strlen(msg);

  if (init_log_fd == -2) {
    init_log_fd = open(INIT_LOG, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (init_log_fd < 0) {
      /*
       * Do NOT latch -1 here. The first thing init prints is its console size,
       * which happens before /log is created, so an early open fails and a
       * latched failure would silently drop every message for the rest of the
       * boot - producing an init.log that exists and is empty, which looks
       * exactly like "init said nothing". Leave it as -2 and retry on the
       * next message; it costs one failed open per call until /log appears,
       * which is a handful of calls, and it cannot wedge.
       */
      return;
    }
  }
  if (init_log_fd < 0)
    return;

  while (off < len) {
    ssize_t w = write(init_log_fd, msg + off, len - off);
    if (w <= 0) {
      if (w < 0 && errno == EINTR)
        continue;
      close(init_log_fd);
      init_log_fd = -1;
      return;
    }
    off += (size_t)w;
  }
}

static void warn(const char *msg) {
  init_log(msg);
  write(2, "\x1b[33m", 5);
  write(2, msg, strlen(msg));
  write(2, "\x1b[0m", 4);
}

/* Append the decimal form of v to buf, returning the new end. Deliberately
 * hand-rolled: the only two formatted messages in init used snprintf, and
 * snprintf is what drags glibc's stdio into this binary. See the note in
 * compile_init.sh - the host's libc.a is built for x86-64-v3 and carries AVX
 * code, and on a CPU without AVX that turns into a SIGILL panic before init
 * can print a single character. Staying clear of stdio keeps PID 1 dependent
 * only on write(2). */
static char *put_dec(char *p, int v) {
  char tmp[12];
  int i = 0;
  unsigned u = (v < 0) ? (unsigned)-v : (unsigned)v;
  do {
    tmp[i++] = (char)('0' + (u % 10u));
    u /= 10u;
  } while (u);
  if (v < 0)
    *p++ = '-';
  while (i)
    *p++ = tmp[--i];
  return p;
}

/* The kernel command line, once, into a static buffer. GRUB entries select
 * optional init behaviour this way (see the rlos.diag branch in main) because
 * a kernel command line is the one boot parameter channel that needs no
 * bootloader cooperation and survives into a live image with nothing to
 * reconfigure. Read with read(2) like everything else here. */
static const char *read_cmdline(void) {
  static char buf[1024];
  ssize_t n;
  int fd = open("/proc/cmdline", O_RDONLY);
  if (fd < 0) {
    buf[0] = '\0';
    return buf;
  }
  n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n < 0)
    n = 0;
  buf[n] = '\0';
  return buf;
}

  /* Milliseconds since boot. Monotonic and only ever used for differences, never
   * formatted as a time of day - restart backoff wants "how long since", and
   * CLOCK_MONOTONIC answers that without the wall-clock jumps that make a
   * difference computed from realtime() go negative. */
  static unsigned long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
      return 0;
    return (unsigned long)ts.tv_sec * 1000UL +
           (unsigned long)(ts.tv_nsec / 1000000L);
  }

  /* Append a NUL-terminated string, returning the new end. Stops at the bound
   * rather than running off the buffer: the caller checks the result. */

static char *put_str(char *p, char *end, const char *s) {
  while (*s && p < end - 1)
    *p++ = *s++;
  *p = '\0';
  return p;
}

/*
 * Which of the two staged templates to copy, chosen by what the kernel bound
 * at boot. Both are complete, valid Xorg configs; neither is edited at runtime.
 */
#define X_TMPL_MSET  "/etc/X11/xorg.conf.ms.base"
#define X_TMPL_FBDEV "/etc/X11/xorg.conf.fbdev.base"
#define X_CONF      "/etc/X11/xorg.conf"
/* Same generated config, under /log so `log xorgconf` can show it after Xorg
 * has failed and there is no display to read /etc from. */
#define X_CONF_COPY "/log/xorg.conf"

/* Highest evdev node to look for. A desktop or laptop does not come close;
 * 64 is the same ceiling the input driver used to scan. */
#define EVDEV_MAX 64

/*
 * Build the Xorg config: the staged base (server flags, fbdev device, screen)
 * plus one InputDevice section per /dev/input/event* node, plus the
 * ServerLayout that ties them together.
 *
 * WHY THIS IS NEEDED. xf86-input-libinput does not enumerate anything itself.
 * Its PreInit reads the device node from the config:
 *
 *     path = xf86SetStrOption(pInfo->options, "Device", NULL);
 *     if (!path)
 *             goto fail;                    -> returns BadValue
 *
 * so every device needs its own section with an explicit Option "Device", or
 * PreInit fails and the server logs
 *     (EE) PreInit returned 2 for "<default keyboard>"
 * xorg-server cannot fill that option in: hw/input/ was removed from the
 * server in 21.x, so there is no server-side input enumerator, and a "Device"
 * section is the only place the option comes from. On a normal system udev
 * writes those sections (60-libinput.conf); we run no udevd, so we do it here.
 *
 * Enumeration is by probing for the node rather than parsing
 * /proc/bus/input/devices: the set of nodes is the only thing needed, and
 * asking the filesystem avoids re-parsing a file whose format is not
 * guaranteed. Devices that are not input devices are left in - libinput
 * classifies what it can use and ignores the rest, which is better than
 * guessing a filter here and being wrong on some machine.
 *
 * Written before Xorg starts, so the config is in place by the time the server
 * reads it. If this fails, Xorg gets no config and its own error path takes
 * over (the supervisor retries it), rather than leaving a desktop that silently
 * has no input.
 */
/*
 * Emit the Device/Screen pair for whichever driver this machine can actually
 * drive, into the DEVICE_PLACEHOLDER line of the staged base.
 *
 * The choice cannot be made at build time because it depends on what the
 * kernel bound at boot:
 *
 *   /dev/dri/card0 exists  -> a KMS driver (i915 on Intel) owns the GPU.
 *                             Use modesetting. It programs the hardware and
 *                             gets damage-tracked updates. The fbdev DDX has
 *                             no damage tracking at all, so every update -
 *                             every cursor move, every keystroke - is a
 *                             full-screen memcpy, which is slow enough to be
 *                             felt as lag.
 *   no /dev/dri            -> nothing drives the display hardware (a VM, or
 *                             firmware that only handed over a memory
 *                             framebuffer). Fall back to fbdev, which works
 *                             there because it just writes to /dev/fb0.
 *
 * The presence of /dev/dri/card0 is NOT the test, and this is the trap that
 * made the first attempt pick modesetting on a machine with no GPU at all:
 * DRM_EFIDRM is itself a DRM driver, so the kernel registers
 *   [drm] Initialized efidrm 1.0.0 for efi-framebuffer.0 on minor 0
 * and creates /dev/dri/card0 with nothing but the firmware's framebuffer
 * behind it. Checking for the node therefore says "accelerated" when nothing
 * accelerated anything, and modesetting then fails with "no screens found"
 * where fbdev would have worked.
 *
 * So check which driver is actually bound. /sys/class/drm/card0/device/driver
 * is a symlink to ../../../bus/pci/drivers/<name>, and the name is the answer.
 * A firmware framebuffer is not a GPU, so it does not count, and its driver
 * name is not what the config option calls it:
 *   efi-framebuffer   DRM_EFIDRM, drivers/gpu/drm/sysfb/efidrm.c, .name
 *                     "efi-framebuffer". This is the one that actually bit: it
 *                     is the driver name in sysfs, not "efidrm", so excluding
 *                     "efidrm" matches nothing and modesetting gets chosen on
 *                     a GPU-less machine, failing with "no screens found".
 *   simple-framebuffer  the old sysfb name, still built for some configs
 * Anything else is a real driver with real hardware behind it.
 *
 * The depth/visual settings are only emitted on the fbdev path. fbdev needs
 * DefaultDepth 24 on a 32bpp framebuffer because DRM_FBDEV_EMULATION does not
 * report FB_VISUAL_TRUECOLOR, so fbdevHWGetDepth() hands the server depth 32
 * and xf86SetWeight() - which has no case 32 - leaves the weight at 000 and
 * aborts startup with "Weight given (000) is inconsistent with the depth (32)"
 * followed by "no screens found". modesetting must NOT be given one: it takes
 * its depth from the real DRM mode, and xf86SetDepthBpp skips the config's
 * DefaultDepth entirely when -depth or -fbbpp is present, so a hardcoded depth
 * would override the mode the hardware actually reported.
 *
 * Returns 1 when a real GPU driver was found, so the caller can report which
 * path it took.
 */
/* Report what sound hardware, if any, the kernel bound.
 *
 * Worth logging for the same reason have_gpu_driver() exists: "the kernel has
 * sound support compiled in" and "sound works" are different claims, and only
 * one of them is visible from here.
 *
 * /sys/class/sound/ lists a cardN per HDA codec the controller found. The
 * common failure is a card that IS present but has no usable PCM, because
 * SND_HDA_INTEL matched the controller while no codec driver matched the chip
 * - every open then fails with -112 "Host is down". Naming the codec makes
 * that distinguishable from "no card at all".
 */
static void
report_sound(void)
{
  DIR *d = opendir("/sys/class/sound");
  if (!d) {
    warn("init: sound: no /sys/class/sound - this kernel has no sound support "
         "compiled in\n");
    return;
  }
  int cards = 0;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (strncmp(e->d_name, "card", 4) != 0)
      continue;

    /* Only the top-level entries are cards. card0/pcm0p and friends are
     * directories nested inside one, so require a bare digit after "card". */
    const char *tail = e->d_name + 4;
    if (!((*tail >= '0' && *tail <= '9') && tail[1] == '\0'))
      continue;

    char path[320];
    snprintf(path, sizeof path, "/sys/class/sound/%s/id", e->d_name);
    char id[64] = "unknown";
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
      ssize_t n = read(fd, id, sizeof id - 1);
      close(fd);
      if (n > 0) {
        id[n] = '\0';
        /* sysfs appends a newline. */
        for (char *q = id; *q; q++)
          if (*q == '\n')
            *q = '\0';
      }
    }
    warn("init: sound: ");
    warn(e->d_name);
    warn(" id=");
    warn(id);
    warn("\n");
    cards++;
  }
  closedir(d);
  if (cards == 0)
    warn("init: sound: no cards bound - the HDA codec driver may not match "
         "this machine\n");
}

static int
have_gpu_driver(char *driver_out, size_t driver_cap)
{
  char link[128];
  char target[256];
  char *p, *end;
  ssize_t n;
  size_t len, i;
  const char *base;
  static const char *firmware_only[] = {"efi-framebuffer", "simple-framebuffer",
                                        NULL};

  p = link;
  end = link + sizeof(link) - 1;
  p = put_str(p, end, "/sys/class/drm/card0/device/driver");
  *p = '\0';

  /* Only card0 is considered. On hybrid graphics there can be more than one
   * DRM card, and taking whichever answers first is how you end up driving the
   * wrong GPU - the integrated one is the one we want, and it is card0 in
   * practice, but if that ever stops being true this needs a real selection
   * rule rather than a coin flip. */
  if (access(link, F_OK) != 0)
    return 0;

  n = readlink(link, target, sizeof(target) - 1);
  if (n <= 0)
    return 0;
  target[n] = '\0';

  /* The link ends in .../bus/pci/drivers/<name>; keep just <name>. */
  base = target;
  len = (size_t) n;
  for (i = 0; i < len; i++)
    if (target[i] == '/')
      base = target + i + 1;

  /* Hand the name back for the boot report, e.g. "i915". */
  if (driver_out && driver_cap) {
    size_t blen = strlen(base);
    if (blen >= driver_cap)
      blen = driver_cap - 1;
    for (i = 0; i < blen; i++)
      driver_out[i] = base[i];
    driver_out[blen] = '\0';
  }

  /* A firmware framebuffer is not a GPU driver. */
  for (i = 0; firmware_only[i]; i++)
    if (strcmp(base, firmware_only[i]) == 0)
      return 0;

  return 1;
}

/*
 * write_all: write the whole buffer or say how far it got.
 *
 * A plain `if (write(fd, buf, len) < 0)` is not enough. write() returning a
 * POSITIVE value smaller than len means it wrote part of the buffer and
 * stopped, and that check passes it as success. For this config the result is a
 * file cut off mid-line, which Xorg's parser rejects with
 *   (EE) Error parsing the config file
 * and no indication that the file is short. So check the count, and treat a
 * short write as the failure it is.
 */
static int
write_all(int fd, const char *buf, size_t len)
{
  while (len > 0) {
    ssize_t n = write(fd, buf, len);
    if (n <= 0)
      return -1;
    buf += n;
    len -= (size_t) n;
  }
  return 0;
}

/*
 * Read one property out of an input device's udev database entry.
 *
 * udevd has already run and settled by the time this is called (start_udevd is
 * earlier in main), so /run/udev/data/c<major>:<minor> exists and carries the
 * properties 60-input-id.rules set from the kernel's own reporting: ID_INPUT,
 * ID_INPUT_TOUCHPAD, ID_INPUT_MOUSE, ID_INPUT_KEYBOARD and so on. That is
 * strictly better than matching strings like "touchpad" against /proc/bus/input
 * names, which gets model-specific names wrong ("ELAN Touch" is a touchscreen,
 * not a touchpad) and so configures the wrong device.
 *
 * Returns 1 if the key was present, and copies its value into out. Any failure -
 * missing entry, unreadable, key absent - returns 0, which is the safe answer:
 * it just means the caller falls back to libinput's defaults.
 */
static int
udev_prop(dev_t rdev, const char *key, char *out, size_t outsz)
{
  char path[80];
  char line[1024];
  char *q = path;
  size_t keylen = strlen(key);
  int fd, found = 0;

  q = put_str(q, path + sizeof(path) - 1, "/run/udev/data/c");
  q = put_dec(q, (int) major(rdev));
  *q++ = ':';
  q = put_dec(q, (int) minor(rdev));
  *q = '\0';

    if (out != NULL && outsz > 0)
      out[0] = '\0';
    fd = open(path, O_RDONLY);

  if (fd < 0)
    return 0;
  while (read(fd, line, sizeof(line) - 1) > 0) {
    line[sizeof(line) - 1] = '\0';
    /* Property lines are "KEY=value\n" but the last line has no newline, so a
     * strncmp on the prefix is what has to be used rather than strchr for '\n'.
     */
    if (strncmp(line, key, keylen) != 0 || line[keylen] != '=')
      continue;
    found = 1;
    if (out != NULL && outsz > 0) {
      char *v = line + keylen + 1;
      char *nl = strchr(v, '\n');
      size_t n = nl != NULL ? (size_t)(nl - v) : strlen(v);
      if (n >= outsz)
        n = outsz - 1;
      memcpy(out, v, n);
      out[n] = '\0';
    }
  }
  close(fd);
  return found;
}

/*
 * True only when the udev key exists *and* is set to 1.
 *
 * The key alone is not enough to reason about. input_id writes ID_INPUT_POINTER
 * and friends as 1 for real pointers, but a rule that explicitly writes 0 - to
 * suppress a device - also leaves the key present, and counting that as a
 * pointer inverts the answer. Comparing the value costs one strcmp and makes the
 * classification mean what it says.
 */
static int
udev_flag(dev_t rdev, const char *key)
{
  char val[32];

  if (!udev_prop(rdev, key, val, sizeof(val)))
    return 0;
  return strcmp(val, "1") == 0;
}

/*
 * Log what udev says about every input node, so the reason a device is not
 * working can be read off a screen instead of guessed at.
 *
 * This is not decoration. libinput's device open depends on the udev entry
 * being initialized - libinput/src/path-seat.c:340 polls
 * udev_device_get_is_initialized() 200 times at 10ms and then gives up with
 * "udev device never initialized", and libinput_device_has_capability() is what
 * decides a device becomes a pointer at all. If udev never classified a node
 * as a pointer, the cursor does not move and nothing on screen says why. So the
 * classification is recorded here, once, at the one moment it can be read.
 */
static void
report_input_device(int i, dev_t rdev, int touchpad)
{
  char name[128], cls[96];
  char num[12];
  char *q;

  num[0] = '\0';
  *put_dec(num, i) = '\0';
  warn("init:   event");
  warn(num);
  warn(": ");

  if (!udev_prop(rdev, "NAME", name, sizeof(name)))
    strcpy(name, "(no NAME in udev database)");
  warn(name);

  /* Show the ID_INPUT_* flags, because that is the classification libinput goes
   * on and it is the thing most likely to be missing. */
  q = put_str(cls, cls + sizeof(cls) - 1, "");
  {
    static const char *const flags[] = {
      "POINTER", "TOUCHPAD", "MOUSE", "KEYBOARD", "TABLET", "TOUCHSCREEN", NULL
    };
    for (int k = 0; flags[k] != NULL; k++) {
      char key[32];
      char *r = put_str(key, key + sizeof(key) - 1, "ID_INPUT_");
      r = put_str(r, key + sizeof(key) - 1, flags[k]);
      *r = '\0';
      if (!udev_prop(rdev, key, NULL, 0))
        continue;
      if (q != cls)
        q = put_str(q, cls + sizeof(cls) - 1, ",");
      q = put_str(q, cls + sizeof(cls) - 1, flags[k]);
    }
  }
  if (q == cls)
    q = put_str(q, cls + sizeof(cls) - 1, "UNCLASSIFIED");
  *q = '\0';

  warn(" [");
  warn(cls);
  warn("]");
  if (touchpad)
    warn(" -> tapping enabled");
  warn("\n");
}

/*
 * Emit one InputDevice section per device that actually exists.
 *
 * A section is written for every node that is present rather than a fixed block
 * for EVDEV_MAX, because the touchpad needs options the others must not get:
 * libinput ships tapping DISABLED (Tapping=0), and on a laptop with no physical
 * click buttons that presents as a touchpad that does not work at all - it
 * tracks fine under a finger but a tap, which is the only way to click on such a
 * machine, does nothing. Enabling it here is what makes the pad respond to what
 * the user actually does with it.
 *
 * The options are only added for nodes udev classified as a touchpad, so a
 * keyboard or a mouse never gets tap handling it has no use for.
 */
static void
emit_input_devices(char **pp, char *end, int *pn_dev)
{
  char path[64];
  char *p = *pp;
  int i, n_dev = 0, n_touch = 0, n_pointer = 0;

  warn("init: input devices as classified by udev:\n");

  for (i = 0; i < EVDEV_MAX; i++) {
    struct stat sb;
    char *q = path;
    int touchpad;

    q = put_str(q, path + sizeof(path) - 1, "/dev/input/event");
    *put_dec(q, i) = '\0';
    if (stat(path, &sb) != 0)
      continue;

    touchpad = udev_flag(sb.st_rdev, "ID_INPUT_TOUCHPAD");
    if (touchpad)
      n_touch++;
    if (udev_flag(sb.st_rdev, "ID_INPUT_POINTER") ||
        udev_flag(sb.st_rdev, "ID_INPUT_MOUSE") ||
        touchpad)
      n_pointer++;
    report_input_device(i, sb.st_rdev, touchpad);

    p = put_str(p, end, "\nSection \"InputDevice\"\n  Identifier  \"ev");
    p = put_dec(p, i);
    p = put_str(p, end, "\"\n  Driver      \"libinput\"\n  Option      \"Device\" \"/dev/input/event");
    p = put_dec(p, i);
    p = put_str(p, end, "\"");
    if (touchpad) {
      p = put_str(p, end,
                  "\n  Option      \"Tapping\"     \"1\""
                  "\n  Option      \"TapButton1\"  \"1\""
                  "\n  Option      \"TapButton2\"  \"3\""
                  "\n  Option      \"TapButton3\"  \"2\"");
    }
    p = put_str(p, end, "\nEndSection\n");
    if (p >= end - 1) {
      warn("init: config buffer full while listing input devices\n");
      break;
    }
    n_dev++;
  }
  /* Say so plainly when nothing came out as a pointer. A cursor that will not
   * move is the symptom; "no node was classified as a pointer" is the cause, and
   * printing it turns the next round from a guess into a fix. */
  if (n_dev == 0)
    warn("init: NO /dev/input/event* nodes exist at all\n");
  if (n_pointer == 0)
    warn("init: no input node was classified as a pointer - the cursor will"
         " not move\n");
  if (n_touch > 0) {
    char num[12];
    num[0] = '\0';
    *put_dec(num, n_touch) = '\0';
    warn("init: ");
    warn(num);
    warn(" touchpad(s) configured with tapping\n");
  }
  *pn_dev = n_dev;
  *pp = p;
}

/*
 * Wait until the set of input devices has stopped changing, and every node has a
 * udev database entry, before the X config is generated.
 *
 * WHY THIS IS NECESSARY, AND WHY IT IS THE ACTUAL BUG
 * ---------------------------------------------------
 * Input devices do not all appear at the same moment. The keyboard registers
 * with the kernel in the first instants of boot. The touchpad does not: i2c_hid
 * is an i2c client and probes when the ACPI controller and its adapters are
 * registered, and psmouse is a pnp/asyncio driver that probes after that. A USB
 * mouse appears whenever it is plugged in. gen_input_config() can therefore run
 * at a moment when the keyboard node exists and the touchpad node does not, and
 * it will write a config listing only what it happened to see.
 *
 * That is not survivable, because libinput is unforgiving about a device whose
 * udev entry is missing. src/evdev.c:2354 rejects it outright:
 *
 *     if ((udev_tags & EVDEV_UDEV_TAG_INPUT) == 0 ||
 *         (udev_tags & ~EVDEV_UDEV_TAG_INPUT) == 0) {
 *         evdev_log_info(device, "not tagged as supported input device\n");
 *         goto err;
 *
 * and src/path-seat.c:340 gives the udev entry only 200 x 10ms to become
 * initialized before giving up. So a device that exists but is not yet
 * classified is not "not working yet", it is excluded, permanently, and the
 * keyboard - which was ready in time - keeps working. That asymmetry is the
 * whole signature of this bug: keys fine, pointer dead.
 *
 * It also explains why this looked like a regression. Nothing about the cursor
 * work changes device enumeration; what changed is boot timing, and a race is
 * exactly the kind of thing that flips on an unrelated edit. The stable
 * signature is "keyboard works, pointing devices do not", and that is what this
 * removes.
 *
 * The loop waits for two things to be true and stay true across consecutive
 * scans: the total node count has stopped rising, and every node that exists has
 * a udev entry. `udevadm trigger --subsystem-match=input` is re-run while that
 * is not yet true, because a node that appeared after the first settle has a
 * uevent nobody is listening for - the same reason start_udevd replays them.
 *
 * Bounded at INPUT_SETTLE_ROUNDS so a machine with a genuinely churning input
 * stack costs a fixed few seconds at boot rather than hanging the desktop.
 */
#define INPUT_SETTLE_ROUNDS  12
#define INPUT_SETTLE_MS     250
#define INPUT_SETTLE_BUDGET 8000

static void msleep(long ms);
static char *child_envp[];
/* report_sound() and have_gpu_driver() are defined above main() but called from
 * inside it; declared here so both see the prototypes. */
static void report_sound(void);
static void secure_atom_image(void);
static int have_gpu_driver(char *driver_out, size_t driver_cap);

/* Run udevadm to completion. Both the initial replay in start_udevd and the
 * input re-trigger below want the same thing - run a udevadm command and wait
 * for it, since a trigger that is still in flight when the next thing reads the
 * database is not a trigger that happened. */
static void
run_udevadm(char *argv[])
{
  pid_t t = fork();

  if (t == 0) {
    execve("/usr/bin/udevadm", argv, child_envp);
    _exit(127);
  }
  if (t > 0)
    waitpid(t, NULL, 0);
}

/* Make the device nodes the compositor needs readable by uid 1000.
 *
 * WHY THIS IS NEEDED AT ALL. The X11 backend runs Xorg as root, so root-only
 * device nodes are fine there and nothing in init ever had to open them up. The
 * Wayland backend is the opposite: sway runs as uid 1000 and has to open the DRM
 * and evdev nodes itself. devtmpfs creates them 0600 root:root, and there is no
 * udev here applying the 0660 root:input rule plus the ACL that a distribution
 * would. On hardware that meant:
 *
 *   crw------- 1 root root 226,   0 card0
 *   crw------- 1 root root  13,  64 event0
 *
 * so libinput could not open a single input device and wlroots refused the
 * backend:
 *
 *   [wlr] [backend/libinput/backend.c:111] libinput initialization failed,
 *                                        no input devices
 *
 * and init reported only "sway did not create /run/user/1000/wayland-0".
 *
 * MODES. The /dev/dri nodes get 0666 because wlroots' DRM backend needs read AND write -
 * a DRM master takes an exclusive lock. /dev/input/event* gets 0644: libinput
 * opens evdev read-only, and there is no reason to widen it further.
 *
 * This is deliberately a blunt instrument. The tidy answer is a udev rule plus an
 * input group, which is what a distribution does; here it would mean shipping a
 * rules file, creating the group, and adding the user to it, to protect a machine
 * that has exactly one unprivileged account and is the person at the keyboard. */
static void
open_nodes_for_user(const char *dirpath, mode_t mode)
{
  DIR *d = opendir(dirpath);
  struct dirent *e;
  char path[96];
  int n = 0;

  if (d == NULL)
    return;
  while ((e = readdir(d)) != NULL) {
    struct stat sb;
    char *q;

    if (e->d_name[0] == '.')
      continue;
    q = put_str(path, path + sizeof(path) - 1, dirpath);
    q = put_str(q, path + sizeof(path) - 1, "/");
    put_str(q, path + sizeof(path) - 1, e->d_name);

    /* stat, not lstat, and only act on what is really there: chmod on a
     * symlink follows it, and /dev/input has entries that are not evdev nodes
     * we care about. */
    if (stat(path, &sb) != 0 || !S_ISCHR(sb.st_mode))
      continue;
    if (chmod(path, mode) == 0)
      n++;
  }
  closedir(d);
  if (n > 0) {
    char num[12];
    num[0] = '\0';
    *put_dec(num, n) = '\0';
    /* warn(), not info(): this helper is defined above build-lib.sh's output
     * helpers are all in scope, and warn is the one available this early. It is
     * also the right one - the line is here because something was WRONG, and
     * finding out afterwards that init silently opened the nodes is worse than
     * one noisy line on every boot. */
    warn("init: opened ");
    warn(num);
    warn(" device node(s) in ");
    warn(dirpath);
    warn(" for uid 1000\n");
  }
}

/* Count the /dev/input/event* nodes that exist, and how many of them udev has
 * actually classified.
 *
 * "Exists" and "classified" are separate questions and both matter. A node can
 * exist with no udev entry at all, or with an entry that predates input_id and
 * therefore lacks the ID_INPUT* tags - and both of those are rejected by
 * libinput. Counting them separately is what lets the log say which of the two
 * went wrong instead of just "no pointer".
 */
static void
count_input_nodes(int *pn_total, int *pn_ready)
{
  int i, total = 0, ready = 0;

  for (i = 0; i < EVDEV_MAX; i++) {
    char path[64];
    struct stat sb;
    char *q = put_str(path, path + sizeof(path) - 1, "/dev/input/event");

    *put_dec(q, i) = '\0';
    if (stat(path, &sb) != 0)
      continue;
    total++;
    if (udev_prop(sb.st_rdev, "ID_INPUT", NULL, 0))
      ready++;
  }
  *pn_total = total;
  *pn_ready = ready;
}

/* Replay the input uevents and wait for udevd to work through them. A node that
 * appeared after start_udevd already finished its initial replay has a uevent
 * nobody was listening for, which is exactly the same situation - and the same
 * remedy - as the one start_udevd exists to handle. */
static void
retrigger_input_udev(void)
{
  static char *trigger_argv[] = {
    "/usr/bin/udevadm", "trigger", "--action=add",
    "--subsystem-match=input", NULL
  };
  static char *settle_argv[] = {
    "/usr/bin/udevadm", "settle", "--timeout=3", NULL
  };

  run_udevadm(trigger_argv);
  run_udevadm(settle_argv);
}

static void
settle_input_devices(void)
{
  int round, prev_total = -1, prev_ready = -1, stable = 0;
  int total = 0, ready = 0;
  long spent = 0;

  for (round = 0; round < INPUT_SETTLE_ROUNDS && stable < 3; round++) {
    count_input_nodes(&total, &ready);
    if (total == prev_total && ready == prev_ready) {
      stable++;
    } else {
      stable = 0;
      prev_total = total;
      prev_ready = ready;
    }
    /* A node that exists but has no ID_INPUT classification is the failure this
     * whole function exists to prevent: its uevent came before udevd was
     * listening, or input_id has not run yet. Replay the input events and let
     * udevd catch up. Note this is conditional - a machine whose input stack has
     * simply finished arriving never pays for a settle, so the usual cost is the
     * polling sleeps and nothing else. */
    if (total > ready)
      retrigger_input_udev();
    if (stable < 3) {
      msleep(INPUT_SETTLE_MS);
      spent += INPUT_SETTLE_MS;
      if (spent > INPUT_SETTLE_BUDGET)
        break;
    }
  }

  warn("init: input settle: ");
  {
    char num[12];

    num[0] = '\0';
    *put_dec(num, total) = '\0';
    warn(num);
    warn(" node(s) present, ");
    num[0] = '\0';
    *put_dec(num, ready) = '\0';
    warn(num);
    warn(" classified by udev");
  }
  if (stable < 3)
    warn(" (still changing when the wait expired)");
  warn("\n");
  if (total > ready)
    warn("init: WARNING - input nodes present but unclassified; the cursor will"
         " not move\n");
}

static void
gen_input_config(void)
{
  char buf[16384];
  char *p = buf, *end = buf + sizeof(buf) - 1;
  char path[64];
  int src, i, n_dev = 0;
  const char *tmpl = have_gpu_driver(NULL, 0) ? X_TMPL_MSET : X_TMPL_FBDEV;

  src = open(tmpl, O_RDONLY);
  if (src < 0) {
    warn("init: no ");
    warn(tmpl);
    warn(": ");
    warn(strerror(errno));
    warn("\n");
    warn("init: X will start without input config or an explicit Device\n");
    return;
  }
  /*
   * Copy the chosen template across verbatim. There is no substitution and no
   * rewriting of any kind on this path: the template is a complete, valid Xorg
   * config as written, so if Xorg rejects the result the file is at fault and
   * the file is readable via `log xorgconf`.
   */
  {
    char *rp = buf, *rend = end;

    for (;;) {
      ssize_t n = read(src, rp, (size_t) (rend - rp));
      if (n <= 0)
        break;
      rp += n;
      if (rp >= rend - 1)
        break;
    }
    close(src);
    *rp = '\0';
    if (rp >= rend - 1) {
      warn("init: config template did not fit in the config buffer\n");
      return;
    }
    p = rp;
  }

  /*
   * One section per device that is present, with touchpad options where they
   * apply. See emit_input_devices.
   */
  emit_input_devices(&p, end, &n_dev);

  /* Only list the sections that exist, or Xorg errors on a missing device. */
  p = put_str(p, end, "\nSection \"ServerLayout\"\n  Identifier  \"layout0\"\n  Screen      \"screen0\"\n");
  for (i = 0; i < EVDEV_MAX; i++) {
    struct stat sb;
    char *q = path;
    /* Built by hand, not with snprintf: this binary avoids stdio entirely,
     * and the reason is in compile_init.sh. */
    q = put_str(q, path + sizeof(path) - 1, "/dev/input/event");
    *put_dec(q, i) = '\0';
    if (stat(path, &sb) != 0)
      continue;
    p = put_str(p, end, "  InputDevice \"ev");
    p = put_dec(p, i);
    p = put_str(p, end, "\"\n");
  }
  p = put_str(p, end, "EndSection\n");

  {
    int out = open(X_CONF, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
      warn("init: cannot write " X_CONF ": ");
      warn(strerror(errno));
      warn("\n");
      return;
    }
    if (write_all(out, buf, strlen(buf)) < 0)
      warn("init: could not write all of " X_CONF " - Xorg will read a"
           " truncated config\n");
    close(out);
  }

  /*
   * Keep a copy under /log as well. The generated config lives only on the
   * RAM disk at /etc/X11/xorg.conf, and once Xorg is failing there is no
   * display to open a file browser on and no coreutils in the shell to cat it
   * with - there is no way to read the one file whose contents decide whether
   * the session comes up. /log exists precisely so that something can be read
   * after the failure, so write it there too and expose it as `log xorgconf`.
   */
  {
    int out = open(X_CONF_COPY, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out >= 0) {
      if (write_all(out, buf, strlen(buf)) < 0)
        warn("init: short write to " X_CONF_COPY "\n");
      close(out);
    } else {
      warn("init: cannot write " X_CONF_COPY ": ");
      warn(strerror(errno));
      warn("\n");
    }
  }
  warn("init: xorg.conf generated with ");
  {
    char num[12];
    num[0] = '\0';
    *put_dec(num, n_dev) = '\0';
    warn(num);
  }
  warn(" input device(s)\n");

  /* "rlos.dumpcfg" on the kernel command line echoes the generated config to
   * the console. Xorg's own report of a bad config is one line - "Parse error
   * on line 19 of section Screen" - which names a line number but not the text,
   * and the file is only on the guest's RAM disk. When the config is generated
   * here rather than shipped as a file, being able to see what was actually
   * written is the difference between fixing it and guessing at it. */
  if (strstr(read_cmdline(), "rlos.dumpcfg")) {
    char line[512];
    char *c = buf, *lp = line;
    warn("\ninit: ==== generated " X_CONF " ====\n");
    for (;;) {
      if (*c == '\0' || *c == '\n' || lp >= line + sizeof(line) - 1) {
        *lp = '\0';
        warn(line);
        warn("\n");
        lp = line;
        if (*c == '\0')
          break;
      } else {
        *lp++ = *c;
      }
      c++;
    }
    warn("init: ==== end of config ====\n");
  }
}


static void warnf(const char *prefix, const char *path) {
  char buf[256];
  char *p = buf;
  const char *s;
  int e = errno;
  for (s = "init: "; *s; s++)
    *p++ = *s;
  for (s = prefix; *s; s++)
    *p++ = *s;
  *p++ = ' ';
  for (s = path; *s; s++)
    *p++ = *s;
  for (s = " failed: "; *s; s++)
    *p++ = *s;
  for (s = strerror(e); *s; s++)
    *p++ = *s;
  for (s = " (errno="; *s; s++)
    *p++ = *s;
  p = put_dec(p, e);
  *p++ = ')';
  *p++ = '\n';
  warn(buf);
}

/* Report a failure the process cannot sensibly continue past, then exit.
 *
 * Only ever called from a forked child on the way to execve(), never from PID 1:
 * _exit() rather than exit() because there are no atexit handlers to run in a
 * process whose only remaining job was to become somebody else. */
static void fatal(const char *prefix) {
  warnf(prefix, "privilege drop");
  _exit(126);
}

/* mkdir that tolerates EEXIST but loudly reports any other failure
 * (e.g. EROFS when root is mounted read-only) instead of silently
 * continuing into a boot that can't actually create /run or /tmp. */
static int xmkdir(const char *path, mode_t mode) {
  if (mkdir(path, mode) == 0 || errno == EEXIST)
    return 0;
  warnf("mkdir", path);
  return -1;
}

/* Write a NUL-terminated string to a path, for sysfs control files.
 *
 * sysfs attributes are written with a single write() of the whole value and no
 * trailing newline - unlike /proc, which usually wants one. Returns 1 on success.
 *
 * Needed because the kernel's sysfs ABI has no "write this value" function in
 * libc: every caller otherwise ends up hand-rolling the same open/write/close
 * dance, and getting the error path wrong here means silently ignoring a
 * firmware request that just failed. */
static int write_str_file(const char *path, const char *val) {
  int fd = open(path, O_WRONLY);
  if (fd < 0)
    return 0;
  size_t len = strlen(val);
  /* write_all returns 0 on success and -1 on failure - it is NOT a byte count,
   * and comparing it against len was a bug that reported every successful write
   * as a failure.
   *
   * Two real symptoms came out of that, which is how it was finally caught:
   *   - init printed "sysrq trigger failed - the machine will not change state"
   *     immediately after the kernel had logged "sysrq: Power Off" and powered
   *     the machine off, so init announced a shutdown it had just completed.
   *   - retry_wireless_firmware() never printed "rebound" even when the rebind
   *     had worked, because the success message sat behind the same inverted test.
   *     That is the entire reason the wireless fix appeared not to work.
   */
  int ok = (write_all(fd, val, len) == 0);
  /* The result of close() is deliberately ignored: the write is what runs the
   * kernel handler, and the handler starts tearing the machine down immediately,
   * so a close() error afterwards is a consequence of the success rather than a
   * failure of it. */
  close(fd);
  return ok;
}

/* Recursively set ownership under `root` (inclusive).
 *
 * fts(3) rather than a hand-rolled opendir/readdir loop: it handles the awkward
 * parts correctly (with FTS_PHYSICAL a symlink is reported as a symlink and not
 * followed, so one pointing outside the tree does not drag its target in; "."
 * and ".." never recurse). A loop that missed either would either fail silently
 * or chown something it shouldn't.
 *
 * FTS_PHYSICAL only. There is no FTS_NOFOLLOW in glibc's fts.h - it is a BSD
 * extension - and it is not needed: FTS_PHYSICAL is already the non-following
 * walk, FTS_LOGICAL is the one that follows.
 *
 * Best effort by design. This runs after /home/user has been mounted into a
 * tree that may legitimately have been produced by an unprivileged builder, in
 * which case almost nothing needs changing and fts will report errors on
 * entries it cannot reach. Failing the boot over that would be worse than the
 * problem being fixed, so errors are counted and reported, not fatal. The one
 * case that must not be silent is a completely unreadable tree, which shows up
 * as a count far above zero.
 *
 * Returns the number of entries it could not chown.
 */
static int chown_tree(const char *root, uid_t uid, gid_t gid) {
  /* NULL-terminated: fts_open() walks this array until it finds the NULL, so a
   * 1-element array with no terminator makes it read past the end into stack
   * garbage and segfault. Observed exactly that while testing this on the
   * build host - fts_open crashed on every path until the terminator was added.
   */
  char *paths[2] = {(char *)root, NULL};
  int n_failed = 0;
  /* FTS_NOCHDIR: without it fts_open chdir()s around the tree, and PID 1 must
   * not have its working directory moved out from under it mid-boot. It also
   * keeps fts_path absolute, which is what lchown() below is handed. */
  FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
  if (fts == NULL) {
    warnf("fts_open", root);
    return 1;
  }
  FTSENT *e;
  while ((e = fts_read(fts)) != NULL) {
    /* Chown DIRECTORIES as well as files. Skipping them is the bug this whole
     * function was written to fix: /home/user itself is reported by fts as
     * FTS_D (a directory), not FTS_F, so an FTS_F-only filter never touches it
     * - and it is the one directory that has to be writable, because that is
     * where mlterm's mkdir of ~/.mlterm, and every other dotfile, happens.
     *
     * The old code got this right by accident: it chowned /home/user directly
     * and never looked at anything below. Replacing that with a walk that
     * skipped directories made things strictly worse.
     *
     * FTS_D is the pre-order visit, so a parent is chowned before its children.
     * That ordering matters for correctness here: a directory that is still
     * root-owned would refuse to be traversed by anything that wanted to write
     * into it mid-walk.
     *
     * FTS_DP is the post-order visit of the same directory and is deliberately
     * not matched - the entry has already been handled on the way down. FTS_SL
     * (symlink) is skipped too: lchown would change the link's own ownership,
     * which buys nothing, and its target is either inside the tree (already
     * reached directly) or deliberately outside. */
    if (e->fts_info != FTS_F && e->fts_info != FTS_D)
      continue;
    if (lchown(e->fts_path, uid, gid) != 0) {
      n_failed++;
      /* One line is enough; a root-owned tree of any size would otherwise
       * bury the boot log under thousands of identical warnings. */
      if (n_failed == 1)
        warnf("chown", e->fts_path);
    }
  }
  fts_close(fts);
  return n_failed;
}

static char *child_envp[] = {
    /* root's home. The rescue shell on tty0 runs as root, so its history and
     * any scratch files land in /root rather than in the user's home - which
     * the user owns, and where root-created files would be root-owned. */
    "HOME=/root",
    "PATH=/bin:/usr/bin:/sbin:/usr/sbin",
    /*
     * The login shell is busybox's ash, not rlsh.
     *
     * rlsh reads a line with read(prompt), which is
     * std::io::stdin().read_line() (rl-std/src/io.rs:102) plus a trim. That
     * has no line editing at all, so the terminal's arrow keys, PageUp,
     * PageDown, Home and End arrive as raw escape sequences and are never
     * interpreted - they either do nothing or land in the command text. There
     * is no history, and no Ctrl+A/E/U/K/W. rlsh remains installed and
     * reachable as `rlsh`; it is simply not the shell a user is dropped into.
     */
    "SHELL=/bin/ash",
    "TERM=linux",
    "LANG=C.UTF-8",
    "LC_ALL=C.UTF-8",
    NULL,
};

/* Environment for the Ctrl-Alt-F3..F6 login shells.
 *
 * NOT child_envp. That one sets HOME=/root, deliberately, because the rescue
 * shell on tty0 runs as root. These run as uid 1000, so HOME=/root would send
 * every history write and every scratch file into a directory that user cannot
 * write - each one failing, silently, as a permission error on the console the
 * user is looking at.
 *
 * TERM=linux is the correct value for a VGA text console, and x_envp's
 * mlterm-256color would be wrong here: it advertises 256 colours and a
 * different key layout than a text VT has. That is also why the "linux" entry
 * has to exist in the image - see the terminfo loop in build_x11.sh, which
 * stages it alongside the mlterm entries. Without it TERM=linux resolves to
 * nothing and every curses program in these shells (nano, rldocs --tui, rlrepl)
 * fails with "can't open terminal" or falls back to line mode.
 *
 * USER and LOGNAME are set because child_envp does not set them either and a
 * login shell should not have to guess. */
static char *vt_shell_envp[] = {
    "HOME=/home/user",
    "PATH=/bin:/usr/bin:/sbin:/usr/sbin",
    "SHELL=/bin/ash",
    "TERM=linux",
    "LANG=C.UTF-8",
    "LC_ALL=C.UTF-8",
    "USER=user",
    "LOGNAME=user",
    /* init creates this 0700 and owned by uid 1000 before either desktop
     * starts. Without it, running sway by hand from a VT shell dies on
     * "XDG_RUNTIME_DIR is not set" - which reads as sway being broken when in
     * fact the shell is incomplete, and that is exactly the moment someone
     * would go looking in order to reproduce a compositor fault. */
    "XDG_RUNTIME_DIR=/run/user/1000",
    /* So swaymsg and friends reach a running compositor instead of failing to
     * connect. Harmless when no desktop is up: nothing is listening. */
    "WAYLAND_DISPLAY=wayland-0",
    NULL,
};

/* ------------------------------------------------------------------ *
 * X session
 *
 * The X clients deliberately do NOT get child_envp. TERM=linux is a dumb
 * 80x25 terminal type, so inside the terminal it would break the winsize probe
 * and every curses TUI - nano, rldocs --tui, rlrepl. They need a real
 * 256-colour type.
 *
 * The value here is what the X clients other than the terminal read, and i3 and
 * i3bar ignore TERM entirely. The terminal itself overwrites TERM in its own
 * child: mlterm takes it from its "termtype" setting, which the staged
 * /usr/etc/mlterm/main pins to mlterm-256color, so the shell it execs gets the
 * entry that matches what mlterm emits. Keep this in step with that file - both
 * are shipped by build_x11.sh, and both entries are compiled into the image.
 *
 * TERMINFO is set explicitly because the guest has no terminfo cache and
 * nothing sets TERMINFO_DIRS for it; without this, the entry does not resolve
 * and terminfo-based lookups fail.
 *
 * mlterm execs $SHELL (with no shell argument it runs the login shell named by
 * SHELL), and /bin/sh is already a symlink to ash, so SHELL here is
 * belt-and-braces rather than the only path.
 * ------------------------------------------------------------------ */
static char *x_envp[] = {
    "HOME=/home/user",
    "PATH=/bin:/usr/bin:/sbin:/usr/sbin",
    /* ash, not rlsh - see the note on child_envp above for why. */
    "SHELL=/bin/ash",
    /* mlterm-256color, not xterm-256color: the image ships a real mlterm
     * terminfo, and the staged usr/etc/mlterm/main tells mlterm to use this
     * name for its own shell, so this is the entry that matches what the
     * terminal emits. This line is for the other X clients that read TERM;
     * i3 and i3bar ignore it. */
    "TERM=mlterm-256color",
    "TERMINFO=/usr/share/terminfo",
    "TERMINFO_DIRS=/usr/share/terminfo",
    "DISPLAY=:0",
    /* mlterm writes diagnostics to $HOME/.mlterm/msg.log by default
     * (uitoolkit/ui_main_config.c calls bl_set_msg_log_file_name unless
     * logging_msg=false), so a terminal that dies at startup is still
     * readable after the fact. `log mlterm` reads that file. */
    /* libXcursor reads these and they override the Xcursor.theme/size
     * resources. We have no xrdb, and Xorg 21.1.24 rejects -xrm outright
     * ("Fatal server error: Unrecognized option: -xrm"), so the environment
     * is the only channel available.
     *
     * XCURSOR_THEME is set for clients that theme themselves (GTK, Qt). It has
     * no effect on the ROOT cursor: Xorg's CreateRootCursor (dix/cursor.c)
     * opens a font named "cursor" and builds a glyph cursor from it, and
     * xorg-server has no reference to libXcursor or XCURSOR_THEME anywhere. The
     * root cursor is themed by /usr/bin/setrootcursor instead - see
     * x11-drv/setrootcursor.c, which init runs once before the WM - which is
     * why this variable alone was not enough and the cursor came out as a black
     * block.
     *
     * XDG_DATA_DIRS is what actually locates the theme for that code:
     * XcursorThemeLoadTheme() searches $XDG_DATA_HOME/icons and every
     * $XDG_DATA_DIRS/icons entry. The theme is staged at /usr/share/icons.
     * libXcursor does fall back to /usr/share, but saying so explicitly means
     * the search path is not a library implementation detail we are guessing at.
     */
    "XCURSOR_THEME=Bibata-Modern-Ice",
    "XCURSOR_SIZE=24",
    /* The desktop runs as uid 1000, so the per-user XDG roots are the user's
     * home and not root's. i3's socket lives in XDG_RUNTIME_DIR (below);
     * XDG_CONFIG_HOME matters because i3 looks for a per-user config there
     * before the -c path we hand it, and mlterm reads XDG_CONFIG_DIRS. */
    "XDG_DATA_HOME=/home/user/.local/share",
    "XDG_CONFIG_HOME=/home/user/.config",
    "XDG_DATA_DIRS=/usr/local/share:/usr/share",
    "XDG_CONFIG_DIRS=/etc/xdg",
    /* i3 puts its IPC socket at $XDG_RUNTIME_DIR/i3 and mkdirp's it 0700.
     * Without this it falls back to a mkdtemp under /tmp, which works, but the
     * path is random per boot and so is any i3-msg invocation aimed at it.
     * Set explicitly, and created below, so the socket path is predictable.
     * It is the *user's* runtime dir now: the desktop runs as uid 1000, and
     * i3 (running as the user) has to be able to create the socket under it. */
    "XDG_RUNTIME_DIR=/run/user/1000",
    /* The other half of the cookie. Xorg is told -auth X_AUTHFILE above; the
     * clients are told where to find the same file here. Without this, and
     * with -ac gone, every client fails to open the display and the desktop
     * comes up empty. Must be a full path: it is not resolved against $HOME,
     * and the clients drop to uid 1000 whose home they do not share with
     * init. */
"XAUTHORITY=/run/Xauthority",
    "USER=user",
    "LOGNAME=user",
    "LANG=C.UTF-8",
    "LC_ALL=C.UTF-8",
    NULL,
  };

  /* ------------------------------------------------------------------
   * The Wayland session environment, for sway and its clients.
   *
   * Separate from x_envp rather than shared with it, because the two disagree on
   * the things that matter. A single shared array would have to pick one DISPLAY
   * value and whichever it picked would be wrong for the other backend: X clients
   * need DISPLAY=:0 pointing at Xorg, while Wayland clients must NOT see a
   * DISPLAY at all. A program that finds DISPLAY set prefers X11 over Wayland,
   * so a stale DISPLAY would send every GTK/Qt client hunting for an X server
   * that is not running. (XWayland changes this again - once it exists, DISPLAY
   * has to point at the XWayland server. See the XWayland note at the branch.)
   *
   * WAYLAND_DISPLAY is the display NAME, never a path. The client joins it with
   * XDG_RUNTIME_DIR to get the socket, which is why this and WL_SOCKET_PATH
   * below have to agree.
   *
   * XDG_RUNTIME_DIR is the user's, and init creates it: it must exist, be mode
   * 0700 and be owned by uid 1000, or the compositor cannot bind its socket at
   * all. It is the same directory the X11 branch uses for the i3 IPC socket, so
   * creating it once serves both backends.
   * ------------------------------------------------------------------ */
  static char *wl_envp[] = {
    "HOME=/home/user",
    "PATH=/bin:/usr/bin:/sbin:/usr/sbin",
    "SHELL=/bin/ash",
    /* Identical to the X11 value: nothing in the Wayland stack reads TERM yet,
     * but keeping them equal means a terminal added later behaves the same
     * whichever backend started. */
    "TERM=mlterm-256color",
    "TERMINFO=/usr/share/terminfo",
    "TERMINFO_DIRS=/usr/share/terminfo",
    "WAYLAND_DISPLAY=wayland-0",
    "XDG_RUNTIME_DIR=/run/user/1000",
    "XDG_DATA_HOME=/home/user/.local/share",
    "XDG_CONFIG_HOME=/home/user/.config",
    "XDG_DATA_DIRS=/usr/local/share:/usr/share",
    "XDG_CONFIG_DIRS=/etc/xdg",
    /* sway uses this to decide how much session/logind machinery to expect.
     * "tty" is the honest answer - this session comes from a virtual terminal -
     * and claiming "wayland" would send it down a code path looking for a
     * session manager that this image does not have. */
    "XDG_SESSION_TYPE=tty",
    "USER=user",
    "LOGNAME=user",
    "LANG=C.UTF-8",
    "LC_ALL=C.UTF-8",
    NULL,
  };

  /* sway's OWN environment. Identical to wl_envp except for two entries, and
   * both differences are load-bearing.
   *
   * 1. NO WAYLAND_DISPLAY. This is the bug that stopped the compositor starting
   *    at all. wlroots inspects its own environment and, finding
   *    WAYLAND_DISPLAY set, concludes it is a NESTED compositor and tries to
   *    attach to the "parent" - which does not exist, because this sway is what
   *    is supposed to create it. It never even attempts the DRM backend:
   *
   *      [wlr] [backend/wayland/backend.c:612] Could not connect to remote
   *             display: No such file or directory
   *      [sway/server.c:270] Unable to create backend
   *
   *    which names neither the device nor the cause. The compositor sets its
   *    own WAYLAND_DISPLAY for its children; it must not be told one by its
   *    parent.
   *
   * 2. WLR_BACKENDS=drm,libinput, spelled out. wlroots autodetects, and its
   *    autodetection is what walked into the problem above. Naming the backends
   *    means the behaviour no longer depends on the environment, which is the
   *    property that just cost a boot cycle. The X11 branch does the
   *    equivalent by passing an explicit xorg.conf.
   *
   * wl_envp - WITH WAYLAND_DISPLAY - stays correct for clients (swaybar, and
   * whatever exec's out of sway's own config), which genuinely do need to be
   * told which display to connect to. One environment cannot be right for both
   * ends of the same socket. */
  static char *sway_envp[] = {
    "HOME=/home/user",
    "PATH=/bin:/usr/bin:/sbin:/usr/sbin",
    "SHELL=/bin/ash",
    "TERM=mlterm-256color",
    "TERMINFO=/usr/share/terminfo",
    "TERMINFO_DIRS=/usr/share/terminfo",
    /* The two differences. Deliberately no WAYLAND_DISPLAY - see above. */
    "WLR_BACKENDS=drm,libinput",
    "WLR_LIBINPUT_NO_DEVICES=0",
    "WLR_RENDERER=pixman",
    "XDG_RUNTIME_DIR=/run/user/1000",
    "XDG_DATA_HOME=/home/user/.local/share",
    "XDG_CONFIG_HOME=/home/user/.config",
    "XDG_DATA_DIRS=/usr/local/share:/usr/share",
    "XDG_CONFIG_DIRS=/etc/xdg",
    "XDG_SESSION_TYPE=tty",
    "USER=user",
    "LOGNAME=user",
    "LANG=C.UTF-8",
    "LC_ALL=C.UTF-8",
    NULL,
  };

#define X_DISPLAY ":0"
  #define X_SOCKET  "/tmp/.X11-unix/X0"

  /* The Wayland display name and socket path.
   *
   * Not "wayland-0" by accident: that IS the name wlroots picks, in
   * backend/session/direct.c -
   *   wl_display_add_socket_auto() with no explicit name - and the socket lands
   * at $XDG_RUNTIME_DIR/<name>. Since sway runs as uid 1000 and init is root,
   * XDG_RUNTIME_DIR has to be the user's, not root's, and init has to create it
   * with the right owner or the compositor cannot make its socket at all.
   *
   * :0 is deliberately NOT reused even before XWayland exists. XWayland
   * allocates the next free display number and would come up as :1, and having
   * the Wayland display be :0 while X clients talk to :1 is a confusing thing to
   * debug for no benefit. */
  #define WL_DISPLAY_NAME "wayland-0"
  #define WL_SOCKET_PATH  "/run/user/1000/wayland-0"

/* The unprivileged account the desktop runs as, and the one `sudo` escalates
 * from. It is uid/gid 1000 to match a conventional first user. */
#define USER_NAME "user"
#define USER_UID  1000
#define USER_GID  1000

/* Drop the calling (forked, still-privileged) child to the user account.
 *
 * Called in the child between fork() and execve(), so it runs exactly once per
 * process, with the full privilege set still intact - which is the only moment
 * it can be done at all. Order matters and is not negotiable: supplementary
 * groups first (they are dropped only with CAP_SETGID), then the group (needs
 * CAP_SETGID), then the user id (needs CAP_SETUID). After setuid() succeeds the
 * process can never regain root, which is the point.
 *
 * A failure here IS fatal to the child, and deliberately so. If setuid() fails
 * the process would otherwise go on to exec as root and the desktop would come
 * up as an unprivileged-looking root session - exactly the thing the drop is
 * supposed to prevent, and something nothing downstream would notice or report.
 * Better a respawn loop with the reason in the log than a session that is
 * quietly still root. */
static void drop_to_user(void) {
  if (setgroups(0, NULL) != 0)
    fatal("setgroups");
  if (setgid(USER_GID) != 0)
    fatal("setgid");
  if (setuid(USER_UID) != 0)
    fatal("setuid");
}

/* Take ownership of, and lock down, the files that govern privilege
 * escalation: sudo itself and its policy file.
 *
 * sudo refuses to run unless it is setuid root AND owned by uid 0, and it
 * refuses to read a sudoers file that is not root-owned 0440. The initramfs is
 * packed by an unprivileged build user, so every staged file arrives owned by
 * that uid, not by root - there is no chown available at package time. init IS
 * root, so it sets the ownership and mode itself, once, at boot. Doing it here
 * rather than trusting the archive is also self-healing: if a rebuild ever
 * stages sudo with the wrong bits, the running system still comes up correct.
 *
 * /etc/shadow is locked down for the same reason and because it holds password
 * hashes that no non-root process has any business reading. */
static void secure_sudo_files(void) {
  struct { const char *path; uid_t uid; gid_t gid; mode_t mode; } f[] = {
    { "/usr/bin/sudo",         0, 0, 04755 },
    { "/usr/bin/sudoedit",     0, 0, 04755 },
    { "/etc/sudoers",          0, 0, 00440 },
    { "/etc/sudoers.d",        0, 0, 00750 },
    { "/etc/passwd",           0, 0, 0644 },
    { "/etc/group",            0, 0, 0644 },
    { "/etc/shadow",           0, 0, 0600 },
  };

  for (size_t i = 0; i < sizeof(f) / sizeof(f[0]); i++) {
    if (chown(f[i].path, f[i].uid, f[i].gid) != 0 && errno == ENOENT)
      continue; /* not shipped - nothing to harden */
    if (chmod(f[i].path, f[i].mode) != 0 && errno != ENOENT)
      warnf("chmod", f[i].path);
  }
  /* sudo keeps its per-session timestamp cache here; it creates the files
   * itself but not the directory. */
  xmkdir("/run/sudo", 0700);
}

/* Run a one-shot X client (setrootbg, setrootcursor) to completion: fork, exec
 * it with the X environment, wait for it, move on. These must happen exactly
 * once and in order before the window manager draws, so they are waited on
 * rather than supervised - a supervised helper that exits 0 would be restarted
 * forever, and one that exits non-zero on a missing display would spin.
 *
 * execve with x_envp, not execv: the helpers open the display with
 * XOpenDisplay(NULL), which reads DISPLAY out of the environment. PID 1's own
 * environment is whatever the kernel handed us with init=, and it has no
 * DISPLAY in it - DISPLAY=:0 exists only in x_envp, which is why they are given
 * it explicitly. */
static void run_x_helper(const char *path) {
  if (access(path, X_OK) != 0) {
    warn("init: ");
    warn(path);
    warn(" is missing - skipped\n");
    return;
  }
  pid_t p = fork();
  if (p == 0) {
    execve(path, (char *[]){ (char *)path, NULL }, x_envp);
    warn("init: exec ");
    warn(path);
    warn(" failed: ");
    warn(strerror(errno));
    warn("\n");
    _exit(127);
  } else if (p > 0) {
    int st = 0;
    while (waitpid(p, &st, 0) < 0 && errno == EINTR)
      ;
    /* Report the outcome. These helpers touch the root window, so a non-zero
     * exit is the difference between a coloured desktop and a black one, and
     * "nothing appeared" does not say which of the two went wrong. */
    warn("init: ");
    warn(path);
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
      warn(" ok\n");
    } else if (WIFEXITED(st)) {
      char num[12];
      num[0] = '\0';
      *put_dec(num, WEXITSTATUS(st)) = '\0';
      warn(" exited ");
      warn(num);
      warn("\n");
    } else if (WIFSIGNALED(st)) {
      warn(" killed by signal ");
      {
        char num[12];
        num[0] = '\0';
        *put_dec(num, WTERMSIG(st)) = '\0';
        warn(num);
      }
      warn("\n");
    } else {
      warn(" failed\n");
    }
  } else {
    warn("init: fork for ");
    warn(path);
    warn(" failed\n");
  }
}
/* X_CONF is defined next to gen_input_config() above, together with
 * X_BASE_CONF, because that function is what writes it. */
/* THE VIRTUAL TERMINAL LAYOUT. Fixed here and relied on by start_vt_shells()
   * below, which puts login shells on tty3-tty6, so the two must agree.
   *
   *   Ctrl-Alt-F1   tty1   boot log + the root rescue shell
   *   Ctrl-Alt-F2   tty2   the X11 desktop, or a login shell when the image
   *                          was built without -x and has no Xorg to run
   *   Ctrl-Alt-F3   tty3   login shell as uid 1000
   *   Ctrl-Alt-F4   tty4   login shell as uid 1000
   *   Ctrl-Alt-F5   tty5   login shell as uid 1000
   *   Ctrl-Alt-F6   tty6   login shell as uid 1000
   *
   * This used to be vt7 for X, with 2-6 left empty. The number is not arbitrary
   * either way: what matters is that X does not share a VT with anything that has
   * to survive it (see the note where Xorg is exec'd), and that F1 lands on the
   * console that fbcon is actually bound to. F1 does, because console=tty0 makes
   * fbcon attach to whichever VT is foreground at boot, which is tty1 - /dev/tty0
   * is not a device, it is the current foreground VT, which is why the comments
   * here say tty0 while the screen the user sees is tty1.
   *
   * X is on vt2 rather than vt7 so the extra shells fit on consecutive keys
   * F3-F6 with no gap, which is the whole point of them being there. */
  #define X_VT      "vt2"
  /* First and last extra login-shell VT. Inclusive. The first is VT_SHELL_FIRST
   * when X has vt2, and VT_SHELL_MIN when the image has no X and vt2 is free. */
  #define VT_SHELL_MIN   2
  #define VT_SHELL_FIRST 3
  #define VT_SHELL_LAST  6

/* How many times to try Xorg before dropping to the text console. This is
 * the important safety net: with X as the default boot, a broken xorg.conf
 * would otherwise be a black screen with no shell and no visible error,
 * which is exactly the failure we already spent a session fixing. */
#define X_MAX_TRIES 3

/* The MIT-MAGIC-COOKIE-1 file. Under /run rather than a home directory
 * because it is regenerated every boot, and /run is tmpfs - it must not
 * survive into a persistent install, where a stale cookie would be both
 * useless (Xorg is handed the current one) and a small liability. */
#define X_AUTHFILE "/run/Xauthority"
#define XAUTH_BIN  "/usr/bin/xauth"
#define XAUTH_COOKIE_LEN 32  /* 16 random bytes, hex-encoded */
#define X_WAIT_S    5   /* seconds to wait for the display per attempt */
  /* The Wayland compositor's equivalent. Longer than X_WAIT_S on purpose: sway
   * does strictly more before it binds the socket than Xorg does before it
   * creates its one - it enumerates KMS connectors, reads EDID over each output,
   * opens the input devices through libinput, and only then creates the display.
   * On a slow disk or a slow KMS device 5 seconds is a coin flip, and the
   * failure mode is not "slow boot", it is init killing a compositor that was
   * about to succeed and reporting "sway did not create ..." for a machine that
   * works. */
  #define SOCK_WAIT_MS 10  /* seconds to wait for the Wayland socket */

static void msleep(long ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
}

/* Published by net_up() when DHCP produced a lease, and the only thing the
 * supervision loop uses to decide whether a network-dependent service may
 * start. A listener on 0.0.0.0 with no address behind it is a remote shell you
 * cannot reach, and in the failure case (no lease) it would just hold port 22
 * and refuse connections while the log implied the machine was reachable.
 *
 * WHY A FILE AND NOT A VARIABLE. net_up() runs in a forked child, so a plain
 * `static int` it sets would land in the CHILD's copy of the address space and
 * the parent would never observe it - the one piece of state the parent most
 * needs is the one thing that cannot cross the fork() boundary. The options were
 * a shared mapping, a pipe, or a file. The file wins because it needs no cleanup
 * on the failure path, costs one open() on a path that already exists, and can
 * be read from the text console while diagnosing the very boot where it went
 * wrong - which the other two cannot. It is the same mechanism needs_x already
 * uses with the X socket.
 *
 * Content is informational only; the supervisor tests existence, nothing else. */
#define NET_READY "/run/net-ready"

/* Seconds to wait for the link to come up before sending the first DISCOVER.
 * Autonegotiation and wireless association both routinely outlast the instant
 * after SIOCSIFFLAGS, and a DISCOVER sent into a link that is not up yet is
 * dropped rather than answered - which turns "nothing is plugged in" into the
 * far less useful "no DHCP lease". Bounded: init is PID 1. */
#define CARRIER_WAIT_S 5
#define CARRIER_WAIT_S_STR "5"

/* ARPHRD_LOOPBACK, from <linux/if_arp.h>. That header cannot be included here:
 * it and <net/if.h> both declare struct ifconf and they disagree, so including
 * both is a hard compile error. One constant is not worth that. */
#ifndef ARPHRD_LOOPBACK
#define ARPHRD_LOOPBACK 772
#endif

/* ---- networking -----------------------------------------------------------
 *
 * Bring up the first wired interface and get an address with DHCP.
 *
 * Here rather than in the shell: by the time a user has a prompt, git, curl and
 * rl's std::http all need an IP, and a guest with no address looks exactly like
 * a guest with no NIC.
 *
 * Non-fatal throughout. No NIC, a dead cable, or an absent DHCP server must
 * still reach a prompt: init is PID 1, and if it blocks, nothing runs at all.
 *
 * Wired only. CONFIG_WIRELESS is not set in kernel.config, and the QCA6174 in
 * this machine's laptop needs ath10k plus firmware under /lib/firmware, which
 * is not staged either. iwd without either would be a daemon with nothing to
 * talk to.
 */

/* Name the first non-loopback, non-wireless interface.
 *
 * From /sys/class/net rather than assuming "eth0": the name varies by machine
 * (enp3s0, ens5, eth0), and a USB adapter only appears once the port is
 * probed. */
static int first_wired_iface(char *out, size_t outsz) {
  DIR *d = opendir("/sys/class/net");
  if (!d)
    return -1;
  struct dirent *e;
  int rc = -1;
  while ((e = readdir(d)) != NULL) {
    if (e->d_name[0] == '.' || strcmp(e->d_name, "lo") == 0)
      continue;

    /* Copy into an IFNAMSIZ buffer first. The kernel caps interface names at
     * 15 chars plus NUL, and an ioctl on ifr_name would be truncated by the
     * kernel anyway - so anything longer is not a name we can act on. Doing the
     * copy here also gives the compiler a bounded string to format. */
    char ifname[IFNAMSIZ];
    if (strlen(e->d_name) >= sizeof ifname)
      continue;
    strncpy(ifname, e->d_name, sizeof ifname - 1);
    ifname[sizeof ifname - 1] = '\0';

    char path[256];
    snprintf(path, sizeof path, "/sys/class/net/%s", ifname);

    /* A real NIC has an "address" file. Loopback does not, and neither do
     * anything that is not a device. */
    /* Sized off path[] itself, so the compiler can see it fits. */
    char sub[sizeof path + 16];
    snprintf(sub, sizeof sub, "%s/address", path);
    if (access(sub, F_OK) != 0)
      continue;

    /* Skip loopback by ARPHRD type, not by name. "lo" happens to be the only
     * loopback on Linux today, but sysfs DOES give it an address/ file, so a
     * name-only check is the only thing excluding it and any other loopback
     * interface would slip through. Type 772 is ARPHRD_LOOPBACK. */
    snprintf(sub, sizeof sub, "%s/type", path);
    char type[8] = {0};
    int tfd = open(sub, O_RDONLY);
    if (tfd >= 0) {
      ssize_t tn = read(tfd, type, sizeof type - 1);
      close(tfd);
      if (tn > 0 && atoi(type) == ARPHRD_LOOPBACK)
        continue;
    }

    /* /wireless marks a radio. CONFIG_WIRELESS is off today, but if it is ever
     * enabled, DHCP on a wireless interface is a pointless wait. */
    snprintf(sub, sizeof sub, "%s/wireless", path);
    if (access(sub, F_OK) == 0)
      continue;

    strncpy(out, ifname, outsz - 1);
    out[outsz - 1] = '\0';
    rc = 0;
    break;
  }
  closedir(d);
  return rc;
}

/* Set IFF_UP so DHCP can transmit. */
static int iface_up(const char *name) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0)
    return -1;
  struct ifreq ifr;
  memset(&ifr, 0, sizeof ifr);
  strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
  if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) {
    close(fd);
    return -1;
  }
  ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
  int rc = ioctl(fd, SIOCSIFFLAGS, &ifr);
  close(fd);
  return rc;
}

  /* Read the interface's link state: 1 if the link is genuinely up.
   *
   * IFF_RUNNING, not IFF_UP. iface_up() sets both, so asking about IFF_UP would
   * always answer yes and say nothing. IFF_RUNNING is maintained by the driver
   * from real link state - carrier detect on copper, association for wireless -
   * so it is the only flag that distinguishes "we asked for this interface" from
   * "something is plugged into it". */
  static int iface_carrier(const char *name) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
      return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) {
      close(fd);
      return -1;
    }
    close(fd);
    return (ifr.ifr_flags & IFF_RUNNING) ? 1 : 0;
  }

  /* Wait for the link to come up, bounded. Returns 1 if carrier appeared.
   *
   * WHY THIS EXISTS, and it is not a speculative wait. Without it, udhcpc's first
   * DISCOVER goes out microseconds after SIOCSIFFLAGS, while the PHY is still
   * negotiating. Those packets are dropped by the driver, not answered, so
   * udhcpc sees silence, spends its whole budget, and exits non-zero - and the
   * log says "no DHCP lease", which points at DHCP when the actual fault was
   * that nothing was plugged in yet. Autonegotiation on copper and association on
   * wireless both routinely take longer than the first few hundred milliseconds
   * of boot, and a USB Ethernet adapter enumerating after the interface is
   * already "up" is the same story.
   *
   * Bounded because init is PID 1: this must delay a bad link by seconds, not
   * hang the machine. */
  static int wait_for_carrier(const char *name, int seconds) {
    int tries = seconds * 10;
    for (int i = 0; i < tries; i++) {
      int c = iface_carrier(name);
      if (c < 0)
        return -1;
      if (c == 1)
        return 1;
      msleep(100);
    }
    return 0;
  }

  /* Read the interface's current IPv4 address.

 *
 * Via SIOCGIFADDR rather than by parsing a udhcpc lease file: busybox only
 * writes one when built with CONFIG_UDHCPC_LEASEFILE, and this build is not -
 * udhcpc accepts no -L and has no lease-file option at all. Asking the kernel
 * what address the interface actually ended up with is also the more honest
 * question: it reflects what `ip addr` will show, so a lease that was obtained
 * but not applied stays visible instead of being papered over.
 *
 * Returns 1 if an address was read.
 */
static int iface_ipv4(const char *name, char *out, size_t outsz) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0)
    return 0;
  struct ifreq ifr;
  memset(&ifr, 0, sizeof ifr);
  strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
  int rc = 0;
  if (ioctl(fd, SIOCGIFADDR, &ifr) == 0) {
    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
    if (inet_ntop(AF_INET, &sin->sin_addr, out, outsz))
      rc = 1;
  }
  close(fd);
  return rc;
}

/* Bring networking up. Runs after X, so it cannot delay the desktop. */
/* Rebind the built-in wireless drivers so they retry their firmware request.
 *
 * THE ROOT CAUSE. In init/main.c, kernel_init() runs:
 *
 *     do_basic_setup();        <- driver_init(): built-in drivers bind to their
 *                                  devices and request firmware HERE
 *     wait_for_initramfs();    <- only NOW is the initramfs unpacked
 *     prepare_namespace();     <- and only NOW is the real root mounted
 *
 * A driver built into the kernel therefore probes BEFORE any root filesystem
 * exists. It asks for /lib/firmware/ath10k/QCA6174/hw3.0/firmware-4.bin, gets
 * -ENOENT because there is nothing at / yet, and gives up for the rest of the
 * session. The adapter never appears, so iwd exits (it has no interface), so iwctl
 * waits forever.
 *
 * This is not ath10k-specific and not a staging bug - the firmware files were
 * staged correctly and the whole set is byte-identical to upstream. It hits the
 * live ISO exactly as much as the USB stick, and it is why the log shows the same
 * -ENOENT for regulatory.db, which is loaded by cfg80211 at the same instant.
 *
 * WHY REBINDING IS THE FIX. The driver has already failed its one probe, so
 * nothing will retry it on its own. Unbinding and re-binding re-runs the whole
 * probe - including the firmware request - and by the time init is executing, /
 * is mounted and /lib/firmware is present. This is the standard remedy and it
 * needs no kernel change, which matters because the alternative (moving these
 * drivers to modules) would undo the no-modules design.
 *
 * Cost: a second probe of a device that already failed, which is nothing next to
 * a wireless card that never works. On a machine whose firmware DID load - an
 * ISO with a wired-only adapter, or a box with no Wi-Fi at all - this finds no
 * device to rebind and does nothing.
 *
 * Best effort. A failure here leaves Wi-Fi broken but must not stop the boot, so
 * every step returns quietly and the caller says nothing on success. */
static void retry_wireless_firmware(void) {
  /* The drivers this kernel builds in that request firmware at probe time.
   * ath9k_htc is deliberately absent: it is a USB transport, and its rebind path
   * is /sys/bus/usb rather than /sys/bus/pci. */
  static const char *const drv[] = {
      "ath10k_pci", "ath9k_pci", "ath5k_pci", "ath6kl", NULL };

  for (int k = 0; drv[k]; k++) {
    char drvpath[256];
    snprintf(drvpath, sizeof drvpath, "/sys/bus/pci/drivers/%s", drv[k]);

    /* Collect the device addresses first. The unbind and bind passes must not
     * share one directory scan: writing to "unbind" destroys the very symlink
     * readdir would hand back next, so a single interleaved pass skips devices
     * depending on the order the kernel happened to list them. */
    char bfds[8][32];
    int n = 0;
    DIR *d = opendir(drvpath);
    /* A driver that is not present at all is ordinary - this kernel builds in
     * four wireless drivers and most machines have one or none of them, so a
     * missing directory is not a fault and is not reported. What IS worth
     * reporting is a directory that exists with no device under it, because that
     * means the driver registered but never bound: either the hardware is not
     * there, or the probe failed, and those are very different problems that
     * used to look identical from the log. */
    if (!d)
      continue;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && n < (int)(sizeof bfds / sizeof bfds[0])) {
      /* A device appears as a symlink named for its BDF (0000:02:00.0). The
       * other entries in this directory are the driver's own control files, which
       * is what the ':' test rejects.
       *
       * Length is checked rather than truncated: the longest BDF PCI can produce
       * is 12 characters, so anything near the buffer size is not a BDF and must
       * not be written to sysfs as one. */
      if (e->d_name[0] == '.' || !strchr(e->d_name, ':'))
        continue;
      size_t len = strlen(e->d_name);
      if (len == 0 || len >= sizeof bfds[n])
        continue;
      memcpy(bfds[n], e->d_name, len + 1);
      n++;
    }
    closedir(d);
    if (n == 0) {
      /* Driver present, nothing bound to it. That is the state ath10k is left in
       * when its firmware request fails, so it is worth a line: it separates
       * "this machine has no Wi-Fi" from "the driver tried and gave up", which
       * are indistinguishable from the log otherwise. */
      warn("init: wifi: ");
      warn(drv[k]);
      warn(" is registered but has no device bound - nothing to rebind\n");
      continue;
    }

    for (int i = 0; i < n; i++) {
      char p[320];
      snprintf(p, sizeof p, "%s/unbind", drvpath);
      if (!write_str_file(p, bfds[i])) {
        char eb[64];
        snprintf(eb, sizeof eb, " [errno %d]", errno);
        warn("init: wifi: FAILED to unbind ");
        warn(bfds[i]);
        warn(" on ");
        warn(drv[k]);
        warn(" (write to ");
        warn(p);
        warn(eb);
        warn(")\n");
break;
      }
    }
    /* A probe of a card with ~700KB of firmware is not instantaneous, and the
     * bind must not race the unbind's teardown. */
    msleep(300);
      for (int i = 0; i < n; i++) {
        char p[320];
        snprintf(p, sizeof p, "%s/bind", drvpath);
        if (!write_str_file(p, bfds[i])) {
          /* Report this. The failure used to be a bare `continue`, which made a
           * rebind that never happened indistinguishable from a machine with no
           * wireless hardware: the log simply had no "rebound" line, and the
           * only other evidence was a driver that had quietly given up. Every
           * other path in this file reports its failure; this one did not, and
           * that is the entire reason a real bug went unexamined for a boot. */
          char eb[64];
          snprintf(eb, sizeof eb, " [errno %d]", errno);
          warn("init: wifi: FAILED to rebind ");
          warn(bfds[i]);
          warn(" on ");
          warn(drv[k]);
          warn(" (write to ");
          warn(p);
          warn(eb);
          warn(")\n");
          continue;
        }
        warn("init: wifi: rebound ");
        warn(bfds[i]);
        warn(" on ");
        warn(drv[k]);
        warn(" so it can load firmware\n");
      }
    }
  }

static void net_up(void) {
  char ifname[64];
  if (first_wired_iface(ifname, sizeof ifname) != 0) {
    warn("init: net: no wired interface found - skipping DHCP\n");
    return;
  }
  if (iface_up(ifname) != 0) {
    warn("init: net: cannot bring ");
    warn(ifname);
    warn(" up - skipping DHCP\n");
    return;
  }
    warn("init: net: ");
    warn(ifname);
    warn(" up, requesting DHCP...\n");

    /* Wait for the link before asking for an address, so that "no lease" means
     * the network did not answer rather than "we spoke too early". */
    {
      int carrier = wait_for_carrier(ifname, CARRIER_WAIT_S);
      if (carrier == 0)
        warn("init: net: no link on this interface after "
             CARRIER_WAIT_S_STR "s - is a cable plugged in?\n");
      else if (carrier < 0)
        warn("init: net: cannot read link state - trying DHCP anyway\n");
    }


  /* Options, restricted to what this busybox actually accepts:
   *   -i IFACE  bind to the interface we found
   *   -n         exit if no lease is obtained (otherwise it waits forever)
   *   -q         exit once bound, so the child does not linger
   *   -t 6 -T 2  six discovers, two seconds apart: ~12s worst case. Bounded on
   *              purpose, because a dead cable must cost seconds, not hang -
   *              init is PID 1 and a hang here is a machine that never boots.
   *
   * There is deliberately NO -L. busybox writes a lease file only when built
   * with CONFIG_UDHCPC_LEASEFILE; this build has no such option, and passing an
   * unknown flag makes udhcpc exit with a usage error (12) BEFORE it sends a
   * single packet - which is indistinguishable from "no DHCP server". The
   * address is read back with SIOCGIFADDR instead.
   */
  pid_t p = fork();
  if (p == 0) {
    char *const argv[] = {(char *)"/bin/udhcpc", (char *)"-i", ifname,
                          (char *)"-n", (char *)"-q",
                          (char *)"-t", (char *)"6", (char *)"-T", (char *)"2",
                          NULL};
    char *const envp[] = {(char *)"PATH=/bin:/usr/bin:/sbin:/usr/sbin", NULL};
    execve("/bin/udhcpc", argv, envp);
    _exit(127);
  }
  if (p < 0) {
    warn("init: net: fork for udhcpc failed\n");
    return;
  }
  int st = 0;
  while (waitpid(p, &st, 0) < 0 && errno == EINTR)
    ;

  if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
    warn("init: net: no DHCP lease on ");
    warn(ifname);
    warn(" - continuing without a network\n");
    if (WIFEXITED(st)) {
      char eb[64];
      snprintf(eb, sizeof eb, "init: net: udhcpc exit status %d\n", WEXITSTATUS(st));
      warn(eb);
    } else if (WIFSIGNALED(st)) {
      char eb[64];
      snprintf(eb, sizeof eb, "init: net: udhcpc killed by signal %d\n", WTERMSIG(st));
      warn(eb);
    }
    return;
  }

  char ipaddr[64];
  if (!iface_ipv4(ifname, ipaddr, sizeof ipaddr))
    strncpy(ipaddr, "(no address on interface)", sizeof ipaddr);

  warn("init: net: ");
  warn(ifname);
  warn(" = ");
  warn(ipaddr);
  warn("\n");

  /* Publish the answer to the parent, which is in a different address space
   * and cannot see anything this function does to memory. */
  {
    int fd = open(NET_READY, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
      warn("init: net: could not create " NET_READY " - sshd will not start\n");
    } else {
      write_all(fd, ifname, strlen(ifname));
      write_all(fd, " ", 1);
      write_all(fd, ipaddr, strlen(ipaddr));
      write_all(fd, "\n", 1);
      close(fd);
    }
  }
}

/* Make /var/empty satisfy sshd's privilege-separation check.
 *
 * sshd refuses to start unless this directory is owned by root and is not
 * group- or world-writable, and the error it prints ("must be owned by root and
 * not group or world-writable") is easy to miss because it appears once per
 * restart attempt and scrolls away under the desktop's own noise.
 *
 * This has to happen here rather than in the build: assemble-rootfs.sh runs
 * unprivileged, so everything it creates lands owned by the build user (uid
 * 1000). mkusb.sh runs it as root, where the ownership would already be
 * correct - which is exactly why this only ever shows up on the live ISO.
 * Same reasoning as chown_tree("/home/user", ...) above: init is root and
 * cannot assume how the tree was produced.
 */
/* The D-Bus system bus identity, created on first boot.
 *
 * NOT baked into the image, and that is the whole point of this function. The
 * machine-id is what makes a D-Bus bus identifiable to its peers, so an image
 * that ships one gives every machine booted from that image the SAME identity.
 * Two of them on one network are then indistinguishable to any client that
 * caches a bus name by machine-id, and the usual advice - "rm /etc/machine-id
 * from the image and let the first boot generate it" - is exactly this.
 *
 * 32 hex characters, which is what dbus-uuidgen emits and what dbus-daemon
 * requires. Read from /dev/urandom rather than derived from the MAC address or
 * the hostname: this is a live system whose root filesystem is a tmpfs that is
 * wiped on reboot, so there is no stable hardware identity to derive from, and a
 * derived ID would repeat across two machines cloned from the same stick.
 *
 * The canonical empty form, a file containing exactly "uninitialized\n", is NOT
 * written. That value means "I have no ID yet, please assign one" to systemd,
 * and dbus-daemon treats an unparseable or short ID as fatal - so writing it
 * would trade one failure for a more confusing one. Generate a real one.
 *
 * Returns 1 if the file exists and is usable afterwards. */
#define MACHINE_ID "/etc/machine-id"

static int machine_id_ensure(void) {
  char buf[33];
  unsigned char raw[16];
  ssize_t n;
  int fd;

  /* Already there: a real ID, or deliberately absent. Either way leave it alone. */
  fd = open(MACHINE_ID, O_RDONLY);
  if (fd >= 0) {
    n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n == 32)
      return 1;
    /* Present but not a usable ID - too short, or the "uninitialized"
     * placeholder. Replace it rather than letting dbus-daemon abort on it. */
    warn("init: dbus: " MACHINE_ID " exists but is not a valid ID - replacing\n");
  }

  fd = open("/dev/urandom", O_RDONLY);
  if (fd < 0) {
    warn("init: dbus: cannot read /dev/urandom for a machine-id\n");
    return 0;
  }
  n = read(fd, raw, sizeof raw);
  close(fd);
  if (n != (ssize_t)sizeof raw) {
    warn("init: dbus: short read from /dev/urandom\n");
    return 0;
  }
  for (size_t i = 0; i < sizeof raw; i++)
    snprintf(buf + i * 2, 3, "%02x", raw[i]);
  buf[32] = '\0';

  fd = open(MACHINE_ID, O_WRONLY | O_CREAT | O_TRUNC, 0444);
  if (fd < 0) {
    warn("init: dbus: cannot write " MACHINE_ID "\n");
    return 0;
  }
  if (write_all(fd, buf, 32) < 0 || write_all(fd, "\n", 1) < 0) {
    warn("init: dbus: short write to " MACHINE_ID "\n");
    close(fd);
    return 0;
  }
  close(fd);
  /* 0444, deliberately. It is an identity, not state: nothing should ever write
   * it again, and read-only makes that a hard error rather than a silent
   * mutation that changes this machine's bus identity under a running bus. */
  return 1;
}

/* Start the D-Bus system bus and wait for it to be reachable.
 *
 * Started before iwd and bluetoothd, and waited for, because both connect to the
 * bus during startup and BOTH EXIT IF IT IS NOT THERE. Registering them in the
 * supervised table and letting them race would work most boots and fail
 * intermittently on a slow one - the shape of bug that gets blamed on the
 * daemons.
 *
 * Like sshd, this daemonises itself, so it is started once rather than
 * supervised, and init does not track or restart it. Returns 1 if the socket
 * appeared. */
#define DBUS_SOCK "/run/dbus/system_bus_socket"

static int start_dbus_once(void) {
  if (access("/usr/bin/dbus-daemon", X_OK) != 0) {
    warn("init: dbus: no dbus-daemon - not started\n");
    return 0;
  }
  if (!machine_id_ensure()) {
    warn("init: dbus: no usable machine-id - not started\n");
    return 0;
  }
  xmkdir("/run/dbus", 0755);

  pid_t p = fork();
  if (p < 0) {
    warn("init: dbus: fork failed - not started\n");
    return 0;
  }
  if (p == 0) {
    /* No --nofork: dbus-daemon backgrounds itself, exactly as sshd does. argv[0]
     * does not have to be absolute (unlike sshd), but the config path does. */
    char *const argv[] = {
        (char *)"/usr/bin/dbus-daemon",
        (char *)"--config-file=/etc/dbus-1/system.conf",
        (char *)"--fork",
        NULL };
    char *const envp[] = {
        (char *)"PATH=/bin:/usr/bin:/sbin:/usr/sbin",
        (char *)"HOME=/root",
        NULL };
    execve("/usr/bin/dbus-daemon", argv, envp);
    warn("init: dbus: exec /usr/bin/dbus-daemon failed\n");
    _exit(127);
  }
  /* Reap the short-lived parent so it does not linger as a zombie. The daemon
   * itself reparents to init. */
  waitpid(p, NULL, 0);

  /* Bounded wait for the socket. dbus-daemon binds before it is fully
   * ready to serve, so the socket appearing is the earliest possible signal and
   * the clients below do their own handshake anyway - this only has to be long
   * enough that we are not starting them into a socket that is not there yet. */
  for (int i = 0; i < 100; i++) {
    if (access(DBUS_SOCK, F_OK) == 0) {
      warn("init: dbus: system bus up on " DBUS_SOCK "\n");
      return 1;
    }
    msleep(100);
  }
  warn("init: dbus: system bus did not come up after 10s\n");
  return 0;
}

static void fix_privsep_dir(void) {
  if (mkdir("/var/empty", 0755) != 0 && errno != EEXIST)
    warnf("mkdir", "/var/empty");
  if (chown("/var/empty", 0, 0) != 0)
    warnf("chown", "/var/empty");
  /* 0755, explicitly. Do not just OR in bits: the build may have left a
   * permissive mode that has to be taken away, not added to. */
  if (chmod("/var/empty", 0755) != 0)
    warnf("chmod", "/var/empty");
}

/* Mint the sshd host keys if they are not already there.
 *
 * Not shipped in the image: a host key baked into a downloadable ISO is the same
 * host key for everyone who ever boots it, which is exactly what the key
 * exchange is meant to prevent.
 *
 * Generated into /etc/ssh rather than /run, so on a persistent USB install they
 * survive reboots and a client's known_hosts stays valid. On a live ISO /etc is
 * the initramfs, so they are fresh per boot and known_hosts will complain - that
 * is the correct, expected behaviour for a disposable image.
 *
 * ed25519 and RSA: ed25519 is what every current client prefers and it is
 * instant, but an older or unusual client may not offer it, and a host with only
 * an ed25519 key cannot be logged into at all by such a client. RSA 3072 costs a
 * second or two of keygen, paid once because the keys persist.
 *
 * Returns 1 if at least ed25519 exists afterwards.
 */
static int ssh_hosts_ensure(void) {
  static const struct { const char *type; const char *file; } keys[] = {
    { "ed25519", "/etc/ssh/ssh_host_ed25519_key" },
    { "rsa",     "/etc/ssh/ssh_host_rsa_key"     },
  };

  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
    if (access(keys[i].file, R_OK) == 0)
      continue;
    warn("init: ssh: generating ");
    warn(keys[i].type);
    warn(" host key (first boot only)...\n");

    pid_t p = fork();
    if (p < 0) {
      warn("init: ssh: fork for ssh-keygen failed\n");
      continue;
    }
    if (p == 0) {
      /* -q quiet, -N "" no passphrase: an unattended boot cannot answer a
       * prompt, and a passphrase here would be read from /dev/tty by a process
       * with no controlling terminal anyway.
       * -b 3072 bits, which is the current floor for RSA. */
      char *const av[] = { (char *)"/usr/bin/ssh-keygen", (char *)"-q",
                           (char *)"-t", (char *)keys[i].type,
                           (char *)"-b", (char *)"3072",
                           (char *)"-N", (char *)"",
                           (char *)"-f", (char *)keys[i].file, NULL };
      execve("/usr/bin/ssh-keygen", av, child_envp);
      _exit(127);
    }
    int st = 0;
    while (waitpid(p, &st, 0) < 0 && errno == EINTR)
      ;
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
      warn("init: ssh: ssh-keygen failed for ");
    /* The .pub is world-readable and harmless; the private half must not be. */
    if (access(keys[i].file, R_OK) == 0) {
      char pub[80];
      snprintf(pub, sizeof pub, "%s.pub", keys[i].file);
      chmod(keys[i].file, 0600);
      chmod(pub, 0644);
    }
  }
  return access("/etc/ssh/ssh_host_ed25519_key", R_OK) == 0;
}

static int start_sshd_once(void) {
  if (access("/bin/sshd", X_OK) != 0) {
    warn("init: ssh: no sshd binary - not started\n");
    return 0;
  }
  fix_privsep_dir();
  if (!ssh_hosts_ensure()) {
    warn("init: ssh: no usable host key - sshd not started\n");
    return 0;
  }

  /* argv[0] MUST be the absolute path. sshd's main() opens with:
   *
   *     if (*av[0] != '/') { "sshd requires execution with an absolute path"; exit(1); }
   *
   * so a bare "sshd" as argv[0] exits immediately.
   *
   * NO -D. That is the whole point of this function. -D means "do not daemonise",
   * and it was only ever passed because procs[] supervises by keeping a child in
   * the foreground: the supervisor wants a pid it can wait() on, so the child
   * must not fork away. Given that, sshd belongs in the table like everything
   * else - and that turned out badly:
   *
   *   - A child that cannot start is respawned. The loop's backoff was a flat
   *     300ms, so a broken sshd produced 181 identical lines in a minute, and the
   *     single line saying WHY scrolled off the end of the log first. The rate
   *     limit is now escalating, but respawning sshd at all is the wrong shape:
   *     it flaps port 22 rather than leaving it down and visible.
   *   - The supervised table was observed holding a corrupt entry - i3's name
   *     and path carrying sshd's argv - with every initialiser correct in the
   *     source. Whatever the cause, sshd is the one service here that a user
   *     actively needs to reason about, so it should not be sharing mutable
   *     state with the display stack.
   *
   * Without -D, sshd forks into the background, its parent exits, and it is
   * reparented to init. init does not track it and does not restart it, which is
   * the correct behaviour for a daemon that is not expected to crash: if it does
   * die, port 22 is simply closed, which is a true and obvious symptom rather
   * than a restart loop generating noise.
   *
   * -e sends its own diagnostics to stderr, which init has already pointed at
   * both the console and the log, so a failure still lands somewhere readable.
   *
   * Returns 1 if the fork succeeded. */
  pid_t p = fork();
  if (p < 0) {
    warn("init: ssh: fork for sshd failed - not started\n");
    return 0;
  }
  if (p == 0) {
    /* Its own environment, like the udhcpc child above: child_envp is a local of
     * main() and is not in scope here, and sshd needs nothing from ours. */
    char *const argv[] = { (char *)"/bin/sshd", (char *)"-e", NULL };
    char *const envp[] = {
        (char *)"PATH=/bin:/usr/bin:/sbin:/usr/sbin", NULL };
    execve("/bin/sshd", argv, envp);
    warn("init: ssh: exec /bin/sshd failed\n");
    _exit(127);
  }
  /* Reap the intermediate process sshd forked on its way to the background, so
   * it does not sit as a zombie for the life of the session. The daemon itself
   * reparents to init and is not waited on. */
  waitpid(p, NULL, 0);
  warn("init: ssh: sshd started on port 22 (log in as 'user')\n");
  if (access(NET_READY, F_OK) != 0)
    warn("init: ssh: no address yet - sshd is reachable on 127.0.0.1 only\n");
  return 1;
}


/* Create the X11 authentication cookie by running the real xauth.
 *
 * xauth rather than writing the file format here: the format is undocumented,
 * has changed over time, and a subtly wrong cookie fails silently as "no
 * desktop" on the framebuffer. xauth is also self-contained (104K, zero shared
 * libraries), so shipping it costs nothing.
 *
 * Returns 1 on success. The cookie is regenerated every boot and never written to
 * a persistent filesystem, so what this buys is "a program running on this
 * machine between boot and logout cannot attach to the display
 * unauthenticated" - which is the point of doing it at all.
 */
static int make_x_cookie(void) {
  if (access(XAUTH_BIN, X_OK) != 0) {
    warn("init: xauth missing - cannot authenticate the display\n");
    return 0;
  }
  /* xauth appends, so a leftover entry would otherwise accumulate and the
   * server would accept the old cookie too. */
  unlink(X_AUTHFILE);

  /* 16 bytes of urandom, hex-encoded. urandom not random: this is not a
   * long-term key, and blocking on a full pool would stall the boot. */
  char cookie[XAUTH_COOKIE_LEN + 1];
  unsigned char raw[XAUTH_COOKIE_LEN / 2];
  int fd = open("/dev/urandom", O_RDONLY);
  if (fd < 0 || read(fd, raw, sizeof raw) != (ssize_t)sizeof raw) {
    if (fd >= 0) close(fd);
    warn("init: cannot read /dev/urandom for the X cookie\n");
    return 0;
  }
  close(fd);
  for (int i = 0; i < (int)sizeof raw; i++)
    snprintf(cookie + i * 2, 3, "%02x", raw[i]);
  cookie[XAUTH_COOKIE_LEN] = '\0';

  pid_t p = fork();
  if (p < 0) {
    warn("init: fork for xauth failed\n");
    return 0;
  }
    if (p == 0) {
      /* ":0" matches DISPLAY in x_envp.
       *
       * XAUTHORITY is REQUIRED here, not a nicety. xauth decides where to write
       * from $HOME/.Xauthority, and this child is given neither HOME nor
       * XAUTHORITY - init passes PATH and nothing else, deliberately, so that
       * xauth cannot inherit a stale display from anywhere. With nothing to go
       * on xauth refuses outright:
       *
       *     xauth: unable to generate an authority file name
       *
       * and exits non-zero, which this function reports as "xauth failed to
       * create the cookie". The consequences cascade: no cookie means Xorg is
       * started without one, i3 and mlterm cannot authenticate to the display,
       * and both exit immediately - so init restart-loops them for the rest of
       * the session while the real cause scrolls past once. Verified against
       * the staged binary, which does contain the X libs xauth needs, so this
       * is purely the missing environment.
       *
       * The path must match X_AUTHFILE, because that is the file this function
       * then chmod 0600s and chowns to the user, and the one Xorg is told to
       * read via x_envp. Three places name this path; they have to agree. */
      char *const xauth_env[] = {(char *)"PATH=/bin:/usr/bin",
                                 (char *)"XAUTHORITY=" X_AUTHFILE, NULL};
      char *const xauth_argv[] = {
          (char *)XAUTH_BIN, (char *)"add", (char *)":0",
          (char *)"MIT-MAGIC-COOKIE-1", cookie, NULL,
      };
      execve(XAUTH_BIN, xauth_argv, xauth_env);
      _exit(127);
    }


  int status = 0;
  if (waitpid(p, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    warn("init: xauth failed to create the cookie\n");
    return 0;
  }
  /* xauth can exit 0 without producing the file, so confirm it exists before
   * telling Xorg to require it. */
  if (access(X_AUTHFILE, R_OK) != 0) {
    warn("init: xauth reported success but " X_AUTHFILE " is missing\n");
    return 0;
  }
  if (chmod(X_AUTHFILE, 0600) != 0)
    warn("init: chmod " X_AUTHFILE " failed\n");
  /* The clients drop to uid 1000 and must be able to read it, but init creates
   * the file as root. */
  if (chown(X_AUTHFILE, USER_UID, USER_GID) != 0)
    warn("init: chown " X_AUTHFILE " failed\n");
  return 1;
}

/* Poll for the X server's unix socket. i3 and mlterm exit immediately when the
 * display is not up, so nothing may be launched before this returns 1. */
static int wait_for_x(int seconds) {
    int tries = seconds * 20;
    for (int i = 0; i < tries; i++) {
      if (access(X_SOCKET, F_OK) == 0)
        return 1;
      msleep(50);
    }
    return 0;
  }

  /* wait_for_path: the same poll, for an arbitrary path.
   *
   * X_WAIT_S is hardcoded into wait_for_x because a Wayland socket was not
   * something this image had when it was written. The compositor branch needs
   * the identical behaviour - "has the thing that means clients can connect
   * appeared yet" - and duplicating the loop inline would guarantee the two
   * drift apart the first time the polling interval is tuned. */
  static int wait_for_path(const char *path, int seconds) {
    int tries = seconds * 20;
    for (int i = 0; i < tries; i++) {
      if (access(path, F_OK) == 0)
        return 1;
      msleep(50);
    }
    return 0;
  }


/*
 * Start udevd and wait until it has populated /run/udev/data.
 *
 * libinput will not open an input device without a udev database entry for it.
 * src/path-seat.c open_restricted() calls udev_device_new_from_devnum() and
 * then polls udev_device_get_is_initialized() 200 times at 10ms before giving
 * up with "udev device never initialized". So this is not a nicety: without a
 * udevd, libinput attaches nothing at all, no matter how correct the Xorg
 * config is.
 *
 * udevd is told to daemonise and then we poll for the database directory
 * rather than sleeping a fixed time. A fixed sleep would be either too short on
 * a machine with many devices or wasteful on one with two.
 */
static void
start_udevd(void)
{
  char *argv[] = { "/usr/sbin/udevd", "--daemon", NULL };
  pid_t p;
  int waited = 0;

  if (access("/usr/sbin/udevd", X_OK) != 0) {
    warn("init: no udevd - libinput cannot attach any input device\n");
    return;
  }
  xmkdir("/run/udev", 0755);
  xmkdir("/etc/udev", 0755);
  /* Deliberately NOT creating /run/udev/data: udevd creates it, so its
   * appearance is the signal that the daemon is really up. Pre-creating it
   * would make the wait below report success on a daemon that never ran. */

  p = fork();
  if (p == 0) {
    execve("/usr/sbin/udevd", argv, child_envp);
    _exit(127);
  }
  if (p < 0) {
    warn("init: fork for udevd failed\n");
    return;
  }

  /*
   * Replay the device events the kernel emitted before we started.
   *
   * The input devices register in the first couple of seconds of boot; udevd
   * starts several seconds later. Those "add" uevents were delivered to nobody,
   * so udevd has an empty queue and /run/udev/data stays empty - which is why
   * simply starting udevd is not enough. `udevadm trigger` walks /sys and
   * synthesises the events again, and `udevadm settle` blocks until the daemon
   * has finished processing them. That is the documented way to bring a udev
   * database up on a system that was already running before udev existed,
   * which is exactly what an initramfs is.
   */
  {
    static char *trigger_argv[] = {
      "/usr/bin/udevadm", "trigger", "--action=add", NULL
    };
    static char *settle_argv[] = {
      "/usr/bin/udevadm", "settle", "--timeout=10", NULL
    };

    run_udevadm(trigger_argv);
    run_udevadm(settle_argv);
  }

  /*
   * Belt and braces on top of `udevadm settle`, the documented way to know the
   * replay is done. What is checked here is that udevd created its database
   * root at all - not any particular device's entry, because the per-device
   * layout under it is libudev's business and asserting a path we have not
   * verified is how a log line ends up confidently wrong.
   *
   * If udevd never came up, say so plainly: that is the one condition that
   * means no device will ever be usable, and it is worth surfacing loudly. A
   * specific device being unusable is left for the libinput driver to report,
   * with the device name, which is a better place for that news.
   */
  for (;;) {
    struct stat sb;
    if (stat("/run/udev/data", &sb) == 0)
      break;
    if (waited >= 4000)
      break;
    usleep(50 * 1000);
    waited += 50;
  }
  warn("init: udev database");
  if (waited >= 4000)
    warn(" MISSING after 4000 ms - no input device will be usable\n");
  else
    warn(" ready\n");
}

/*
 * Print what we know about this machine's performance, once, right after X is
 * up. Present because "everything feels laggy" has two very different causes
 * and they are told apart by these numbers, not by guessing:
 *
 *   - load average well above 1.0 means something is spinning and starving X,
 *     so the lag is contention and the fix is to find the spinner;
 *   - a load average near zero with a low CPU MHz means the clock is pinned
 *     low - no cpufreq governor took over - so the lag is the CPU running at
 *     its slowest state and the fix is in the kernel config.
 *
 * Neither is guessable from the outside, and a desktop that renders correctly
 * while ignoring input looks identical in every log.
 */
static void
report_perf(void)
{
  char buf[512];
  char *line, *nl;
  int fd;
  ssize_t n;

  fd = open("/proc/loadavg", O_RDONLY);
  if (fd >= 0) {
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n > 0) {
      buf[n] = '\0';
      warn("init: loadavg: ");
      warn(buf);
    }
  }

  /*
   * The clock, from the first "cpu MHz" line in /proc/cpuinfo.
   *
   * /proc/cpuinfo is read as a whole and scanned, rather than printed as it
   * arrives: klogd and Xorg are writing to the same console, so a line
   * printed one write(2) at a time can be spliced into the middle of someone
   * else's output - which is exactly what happened the first time this was
   * tried. The buffer is read once, then the interesting line is emitted in a
   * single write.
   */
  fd = open("/proc/cpuinfo", O_RDONLY);
  if (fd >= 0) {
    ssize_t got = 0;
    for (;;) {
      n = read(fd, buf + got, sizeof(buf) - 1 - got);
      if (n <= 0)
        break;
      got += n;
      if ((size_t) got >= sizeof(buf) - 1)
        break;
    }
    close(fd);
    buf[got > 0 ? got : 0] = '\0';
    for (line = buf; line && *line; line = nl ? nl + 1 : 0) {
      nl = strchr(line, '\n');
      if (nl)
        *nl = '\0';
      if (strstr(line, "cpu MHz") && strchr(line, ':')) {
        char *v = strchr(line, ':');
        warn("init: cpu MHz: ");
        warn(v + 1);
        warn("\n");
        break;
      }
    }
  }

  /* Whether a scaling driver actually took over, which is the other half of
   * the question. Absent, the CPU stays wherever firmware left it. */
  {
    static const char *scaling[] = {
      "/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver",
      "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor",
      "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq",
    };
    static const char *cpufreq_names =
      "scaling_driver\0scaling_governor\0scaling_max_freq";
unsigned k;
    /* Not static: a static would be re-initialised on every call and never
     * advance, so all three entries printed the first name. */
    const char *name = cpufreq_names;
    for (k = 0; k < sizeof(scaling) / sizeof(scaling[0]); k++) {
      fd = open(scaling[k], O_RDONLY);
      if (fd < 0) {
        warn("init: cpufreq: absent - ");
        warn(name);
        warn("\n");
        name += strlen(name) + 1;
        continue;
      }
      n = read(fd, buf, sizeof(buf) - 1);
      close(fd);
      if (n > 0) {
        buf[n] = '\0';
        warn("init: cpufreq: ");
        warn(name);
        warn(" = ");
        warn(buf);
      }
      name += strlen(name) + 1;
    }
  }
}

/*
 * Report what has landed in /log so far.
 *
 * This exists because "is logging working" is otherwise unanswerable: init
 * cannot see the console output it just produced once X has taken the display,
 * and a log directory that exists but is empty is indistinguishable from one
 * that was never created. Printing the size of each file at boot turns that
 * into a single glance, and it doubles as a check that the writer which should
 * have filled it actually did.
 *
 * A size of zero right after startup is expected for Xorg.log, which the
 * server only writes to once it has something to say.
 */
/* Make the atom image safe to unpack a container root from.
 *
 * root-owned and not writable by anyone else. If it is group/world writable
 * then a process inside the container - which maps to an unprivileged host uid
 * via bwrap's --unshare-user - could rewrite the image, and every container
 * unpacked from it afterwards would be the attacker's code instead of atom's.
 *
 * This is a single regular file now, not a directory tree, which is part of why
 * the archive replaced the staged tree: securing one file needs one chown,
 * where securing a 95M tree needed a recursive walk over every file at every
 * boot. Same guarantee, a fraction of the work.
 *
 * Done here rather than in the build, for the same reason as chown_tree() above:
 * assemble-rootfs.sh runs unprivileged, so everything it creates arrives owned
 * by the build user (uid 1000). init is root and cannot assume how the image was
 * produced.
 *
 * Not an error if absent: an image built without rlos-atom has no atom image,
 * and the desktop image only grows one when pack_atom_image.sh has been run.
 */
static void
secure_atom_image(void)
{
  if (access(ATOM_IMAGE_PATH, F_OK) != 0)
    return;

  if (chown(ATOM_IMAGE_PATH, 0, 0) != 0)
    warnf("chown", ATOM_IMAGE_PATH);
  /* 0644: readable by everyone, because unpacking it is a user-facing thing to
   * do, and unwritable by anyone who is not root. */
  if (chmod(ATOM_IMAGE_PATH, 0644) != 0)
    warnf("chmod", ATOM_IMAGE_PATH);
  warn("init: atom: " ATOM_IMAGE_PATH " secured (root-owned, not writable by others)\n");
}

static void
report_logs(void)
{
  static const char *names[] = { "init.log", "kmsg", "Xorg.log" };
  unsigned k;

  warn("init: logs in " LOG_DIR ":");
  for (k = 0; k < sizeof(names) / sizeof(names[0]); k++) {
    char path[64];
    char num[24];
    struct stat sb;
    char *q = path;

    q = put_str(q, path + sizeof(path) - 1, LOG_DIR "/");
    q = put_str(q, path + sizeof(path) - 1, names[k]);

    if (stat(path, &sb) != 0) {
      warn("init:   ");
      warn(names[k]);
      warn(" missing");
      warn("\n");
      continue;
    }
    /*
     * Bytes, not KB. Divided by 1024 and truncated, a file with a few hundred
     * bytes reports as "0 KB", which is indistinguishable from a file that was
     * created and never written to - the exact ambiguity this function exists
     * to remove. Bytes cannot round down to a misleading zero.
     */
    num[0] = '\0';
    *put_dec(num, (int) sb.st_size) = '\0';
    warn("init:   ");
    warn(names[k]);
    warn(" ");
    warn(num);
    warn(" bytes");
    warn("\n");
  }
}

/* Defined below, next to the rest of the network code. Called from main() at
 * the very top of boot, which is before its definition. */
static void retry_wireless_firmware(void);

/* The supervised-children table, at file scope.
 *
 * It was a block-scope local of main() until do_shutdown() needed it: an orderly
 * shutdown has to know which children to stop, and that is a file-scope function
 * so it can be called from the signal path. Hoisting the table is the smaller
 * change of the two options - the alternative was passing pids in, which means
 * either a second copy that can disagree with the first or a pointer to a local. */
struct supervised {
  const char *name;
  const char *path;   /* what execve() is given */
  char *const *argv;  /* argv[0] is the name the program reports, not the path */
  char *const *envp;
  int needs_x;
  int as_user;        /* drop to uid 1000 in the child before execve */
  pid_t pid;
  /* Consecutive failed starts, and when the next one is allowed. Trailing
   * fields, so the positional initialisers below do not have to name them. */
  unsigned restarts;
  unsigned long retry_at_ms;
  /* Controlling terminal to claim in the child, e.g. "/dev/tty3", or NULL to
   * leave it alone. Added as a trailing field rather than avoided: the log
   * redirect a few lines below in the fork path was deliberately NOT made a
   * field, to keep every existing positional initialiser untouched after the
   * argv-aliasing bug. That caution does not apply here, because every call
   * site has to be updated anyway to start the new shells, and
   * -Wmissing-field-initializers turns a missed ", NULL" into a build failure
   * rather than a silent NULL. The compiler is the guard. */
  const char *ctty;
};
static struct supervised procs[18];
  static size_t nprocs = 0;
  
  /* Bounded insert. procs[] is a fixed array and several sites push to it, so the
   * only thing standing between a future nineteenth entry and a stack smash is
   * somebody counting correctly.
   *
   * The X11 backend used 11 of 12: klogd, ash, Xorg, i3, mlterm, iwd, bluetoothd
   * and the four VT shells. The Wayland backend replaces Xorg/i3/mlterm (3) with
   * sway/swaybar/swaybg (3) and adds seatd, so the peak is the same today - but
   * that is a coincidence of arithmetic, not a property worth relying on. It was
   * 12 while the comment above claimed "no plausible thirteenth child", and the
   * Wayland branch made that false. 18 leaves real headroom, and the bound is
   * what actually protects the array: exceeding it drops a child loudly rather
   * than letting entries alias each other. */
  #define SUPERVISE_MAX 18
/* Variadic because a struct initialiser contains commas, which a three-arg macro
 * would split into separate arguments. No braces around __VA_ARGS__: the call
 * sites supply the compound literal's own braces, and adding another pair here
 * silently produces (struct supervised){{ ... }}, which initialises only the
 * first member and leaves the rest zero.
 *
 * The trailing restarts/retry_at_ms fields ARE named at each call site rather
 * than defaulted here, because assigning them afterwards does not stop the
 * -Wmissing-field-initializers warning: that fires on the initialiser itself,
 * before anything this macro does. */
#define supervise(tbl, cnt, ...)                                      \
    ((*(cnt) < SUPERVISE_MAX)                                          \
       ? ((tbl)[(*(cnt))++] = (struct supervised)__VA_ARGS__, 1)      \
       : (warn("init: supervised table full, dropping a child\n"), 0))


/* ---------------------------------------------------------------------------
 * Orderly shutdown and reboot, driven by signals.
 *
 * WHY THIS EXISTS RATHER THAN A PROGRAM. shutdown.rl and reboot.rl already do the
 * sysrq half correctly, and the obvious question is why init should care. Because
 * a shutdown that skips init leaves every supervised child running: Xorg, i3,
 * mlterm, iwd, bluetoothd, sshd all still hold the machine open while the power
 * is being cut, which on a live system means whatever they had buffered is lost
 * and the user gets no warning. init is the only process that knows what those
 * children are, so it is the only place a shutdown can be orderly. The rl programs
 * therefore signal init and let init do the work, which also means one shutdown
 * path rather than two that can drift apart.
 *
 * WHY A FLAG AND NOT A SELF-PIPE. A signal handler must be async-signal-safe, and
 * the set of things it may touch is tiny. Assigning a sig_atomic_t is the only
 * thing here that qualifies. The work is done by the supervision loop when it
 * notices, which is also what makes it orderly: the loop already owns the child
 * table, so the shutdown path runs where the pids are known.
 *
 * The loop gets its chance because the handlers are installed WITHOUT SA_RESTART,
 * so a signal interrupts waitpid() and it returns EINTR. The loop's existing
 * `if (errno == EINTR) continue;` would otherwise discard that, so the flag is
 * checked on the next pass instead. Without SA_RESTART this does not work: the
 * syscall would be transparently restarted and the flag never noticed.
 *
 * SIGTERM and SIGINT power off, SIGQUIT reboots. That is the long-standing
 * convention, and it matches what "shutdown", "poweroff" and "reboot" from a shell
 * are expected to do.
 *
 * sig_atomic_t, not int: the compiler is entitled to assume a plain int accessed
 * from a handler is only touched in the handler, and the variable here is read by
 * ordinary code. */
static volatile sig_atomic_t shutdown_mode = 0;  /* 0 none, 1 poweroff, 2 reboot */

static void on_shutdown_signal(int sig) {
  /* The only assignment. No write(2), no malloc, no snprintf - see the note. */
  shutdown_mode = (sig == SIGQUIT) ? 2 : 1;
}

/* Install the handlers. Best effort: if sigaction fails the system still boots and
 * still works, it just cannot be told to shut down politely. */
static void install_signal_handlers(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_shutdown_signal;
  sigemptyset(&sa.sa_mask);
  /* Deliberately no SA_RESTART - see the note above. */
  sa.sa_flags = 0;

  const int sigs[] = { SIGTERM, SIGINT, SIGQUIT };
  for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) {
    if (sigaction(sigs[i], &sa, NULL) != 0)
      warnf("sigaction", "shutdown signal");
  }
}

/* Fire one sysrq key through the kernel's own trigger. Returns 1 on success.
 *
 * Same mechanism, and for the same reasons, as shutdown.rl: no syscall numbers to
 * get wrong. A mistyped sysrq key does nothing at all, whereas a wrong reboot(2)
 * number reboots instead of powering off with nothing to report. */
static int sysrq(const char *key) {
  return write_str_file("/proc/sysrq-trigger", key);
}

/* Stop every supervised child, then power off or reboot.
 *
 * Order matters and is not negotiable:
 *   1. SIGTERM first, so anything that can close its files does.
 *   2. A short grace period, then SIGKILL for whatever ignored it.
 *   3. Reap, so nothing is left as a zombie.
 *   4. sync ('s') - 'o' and 'b' do NOT sync themselves; they stop the CPUs and
 *      cut power, and anything still in the page cache is lost.
 *   5. 'o' to power off, or 'b' to reboot.
 *
 * Once step 5 is reached the machine is going away. Anything printed after it is
 * a sign the handler was not built in, so it is said here rather than left to be
 * discovered as a machine that ignored "poweroff". */
static void do_shutdown(int mode) {
  warn("init: shutting down (");
  warn(mode == 2 ? "reboot" : "poweroff");
  warn(")\n");

  const size_t np = nprocs;
  for (size_t i = 0; i < np; i++)
    if (procs[i].pid > 0)
      kill(procs[i].pid, SIGTERM);

  /* Give them a moment to finish, escalating rather than waiting forever: a
   * daemon blocked on a dead D-Bus socket can sit in an uninterruptible state
   * indefinitely, and refusing to power off because of it would be worse. */
  for (int waited = 0; waited < 20; waited++) {
    int left = 0;
    for (size_t i = 0; i < np; i++) {
      if (procs[i].pid > 0) {
        int st = 0;
        pid_t r = waitpid(procs[i].pid, &st, WNOHANG);
        if (r == procs[i].pid || (r < 0 && errno == ECHILD)) {
          procs[i].pid = -1;
        } else {
          left++;
        }
      }
    }
    if (left == 0)
      break;
    msleep(100);
  }

  for (size_t i = 0; i < np; i++) {
    if (procs[i].pid > 0) {
      kill(procs[i].pid, SIGKILL);
      waitpid(procs[i].pid, NULL, 0);
      warn("init:   killed ");
      warn(procs[i].name);
      warn(" (ignored SIGTERM)\n");
      procs[i].pid = -1;
    }
  }

  if (!sysrq("s"))
    warn("init: could not sync before powering off\n");
  if (!sysrq(mode == 2 ? "b" : "o")) {
    warn("init: sysrq trigger failed - the machine will not change state\n");
    /* Clear the flag so the loop does not call straight back in here.
     *
     * Without this the shutdown runs again on the very next pass, and again after
     * that: a tight loop writing a message to the console several times a second
     * on a machine the user has just been told is not going to shut down. That is
     * worse than doing nothing, because it hides the one fact that matters - that
     * the trigger failed - behind a blur.
     *
     * Staying up is the deliberate choice. Exiting would leave the machine
     * running with no init and no way to shut it down at all, turning a failed
     * shutdown into an unrecoverable one. */
    shutdown_mode = 0;
    warn("init: staying up. Use hardware power control, or fix ");
    warn("/proc/sysrq-trigger.\n");
  }
}


  int main(void) {

    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    /* Signals before anything else forks. Installed here rather than later so
     * a signal arriving during the seconds of X startup is still noticed - the
     * supervision loop that acts on it does not exist yet, but the handler sets
     * the flag regardless and the loop sees it the moment it starts. */
    install_signal_handlers();

    /* Rebind the wireless drivers NOW, immediately after sysfs is available.
   *
   * ORDER IS THE WHOLE POINT, and this call was originally placed much later -
   * after the D-Bus bus was up, next to where iwd is registered. That was wrong,
   * and the kernel log from a real machine showed exactly how wrong:
   *
   *     0.879  ath10k: could not probe fw (-2)      <- built-in probe, no rootfs
   *     ...    3.6s of Xorg starting                <- where the old call was
   *     4.545  ath10k: pci irq ... reset_mode 0     <- rebind, finally
   *     4.757  firmware ver WLAN.RM.4.4.1-00309- api 6
   *     4.960  wlp2s0: renamed from wlan0
   *
   * The rebind works, but landing at 4.5s means iwd was already registered and
   * had already exited twice against a machine with no wireless interface. It
   * exits non-zero when cfg80211 has nothing for it, so a fix that completes
   * after iwd starts is a fix the user still cannot use.
   *
   * Moving it here costs nothing and moves it ahead of Xorg, udev and D-Bus.
   * sysfs is mounted two lines up, which is the only thing it needs; /lib/firmware
   * is already present because init itself is executing from that rootfs. */
  retry_wireless_firmware();


  /* devtmpfs gives us /dev/ptmx, but without devpts mounted at
   * /dev/pts, opening a pty master never gets a matching slave node. */
  xmkdir("/dev/pts", 0755);
  if (mount("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666") != 0)
    warnf("mount", "/dev/pts (devpts)");

  /* /dev/shm, and this one is not optional for a Wayland session.
   *
   * wlroots allocates the keyboard keymap through a shared memory file - not
   * memfd, shm_open() - and it does so before the first client can connect:
   *
   *   [wlr] [types/wlr_keyboard.c:222] Failed to allocate shm file for keymap
   *   (repeated, once per attempt)
   *
   * With no tmpfs at /dev/shm there is nothing to open, the keymap never
   * arrives, and the compositor does not survive it. The X11 backend never
   * needed this: Xorg uses its own extension transport, not shm.
   *
   * Sized explicitly rather than left at the tmpfs default. The kernel defaults
   * a tmpfs to half of RAM, but wlroots divides this space between the keymap
   * and every client buffer, and the default on a machine with lots of RAM is
   * also the one that lets a compositor exhaust it. 256M is comfortably more
   * than a keymap plus a full-screen buffer, and does not grow with host RAM. */
  xmkdir("/dev/shm", 01777);
  if (mount("shm", "/dev/shm", "tmpfs", 0, "mode=1777,size=256m") != 0)
    warnf("mount", "/dev/shm (tmpfs)");

  /* Do NOT mknod /dev/console here. devtmpfs already creates it, pointing
   * at whichever console the kernel chose as primary - the last console=
   * on the cmdline. Forcing (5,1) pinned stdin/stdout/stderr to ttyS0
   * regardless of what the bootloader asked for, so the shell and klogd
   * stayed invisible on the framebuffer even once one existed. */
  int fd = open("/dev/console", O_RDWR);
  if (fd < 0) {
    warn("init: no /dev/console, keeping inherited fds\n");
  } else {
    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2)
      close(fd);
  }

  setsid();
  ioctl(0, TIOCSCTTY, 1);

  /* Before the first warn(), which is the console-geometry line below. That
   * call already tries to write init.log, so /log has to exist by now or the
   * open fails on the earliest message of the boot. */
  xmkdir(LOG_DIR, 0755);

  /* Serial consoles report a 0x0 window (no winsize concept, and QEMU
   * forwards nothing), which makes TUI apps render into a zero-area
   * viewport: a blank page. So ask the terminal emulator itself: move
   * the cursor far away, send a cursor-position request (CPR), and read
   * back the clamped position - that IS the real size. Any failure
   * (redirected output, dumb terminal, timeout) falls back to 80x24. */
  {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = 24;
    ws.ws_col = 80;
    if (isatty(0) && isatty(1)) {
      struct termios saved, raw;
      if (tcgetattr(0, &saved) == 0) {
        raw = saved;
        raw.c_lflag &= (tcflag_t) ~(ICANON | ECHO);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 20; /* 2s reply timeout */
        if (tcsetattr(0, TCSANOW, &raw) == 0) {
          tcflush(0, TCIFLUSH);
          const char query[] = "\x1b[s\x1b[999;999H\x1b[6n";
          if (write(1, query, sizeof(query) - 1) == (ssize_t)(sizeof(query) - 1)) {
            char buf[64];
            size_t len = 0;
            ssize_t n;
            while (len < sizeof(buf) - 1 &&
                   (n = read(0, buf + len, sizeof(buf) - 1 - len)) != 0) {
              if (n < 0) {
                if (errno == EINTR)
                  continue;
                break;
              }
              len += (size_t)n;
              if (len > 0 && buf[len - 1] == 'R')
                break;
            }
            buf[len] = '\0';
            int rows = 0, cols = 0;
            char *esc = strchr(buf, '\x1b');
            if (esc != NULL && sscanf(esc, "\x1b[%d;%dR", &rows, &cols) == 2 &&
                rows > 0 && rows <= 1000 && cols > 0 && cols <= 1000) {
              ws.ws_row = (unsigned short)rows;
              ws.ws_col = (unsigned short)cols;
            }
          }
          /* Best effort: restore cursor and console mode. */
          write(1, "\x1b[u", 3);
          tcsetattr(0, TCSANOW, &saved);
        }
      }
    }
    ioctl(0, TIOCSWINSZ, &ws);
    {
      char msg[64];
      char *p = msg;
      const char *s = "init: console ";
      while (*s)
        *p++ = *s++;
      p = put_dec(p, ws.ws_col);
      *p++ = 'x';
      p = put_dec(p, ws.ws_row);
      *p++ = '\n';
      /*
       * Through warn(), not a bare write(2), so this reaches /log/init.log too.
       * This is the first message init emits, which is why /log has to exist by
       * now: an earlier version wrote it straight to fd 2, and init.log ended
       * up created but empty because nothing else had called the logger yet.
       */
      warn(msg);
    }
  }

  xmkdir("/run", 0755);
  xmkdir("/tmp", 01777);
  chmod("/tmp", 01777);
  /* /var/run -> /run.
   *
   * /var/run has been a symlink to /run on essentially every Linux system for
   * twenty years, and daemons hardcode that spelling. iwd is the concrete case
   * here: iwd/src/main.c asks ell for the system bus with
   * l_dbus_new_default(L_DBUS_SYSTEM_BUS), and ell/dbus.c falls back to a
   * compile-time default that reads
   *
   *     unix:path=/var/run/dbus/system_bus_socket
   *
   * - /var/run, not /run. A live initramfs has no /var/run, so iwd looked for
   * the bus at a path that does not exist and died with
   *
   *     Failed to initialize D-Bus
   *
   * while dbus-daemon was running perfectly well on /run/dbus. That is a
   * confusing pair of facts to debug: init logs the system bus coming up, and
   * iwd immediately reports it cannot initialise D-Bus.
   *
   * Creating the symlink is the right fix rather than setting
   * DBUS_SYSTEM_BUS_ADDRESS for iwd alone, because the same hardcoded spelling
   * appears in other daemons, and the symlink is what every other system does.
   * EEXIST is success: it means the link (or a real /var/run) is already there. */
  if (symlink("/run", "/var/run") != 0 && errno != EEXIST)
    warnf("cannot symlink", "/var/run");

  /* fontconfig caches into /tmp/fccache (see etc/fonts/fonts.conf). It does
   * not create the directory itself, and with no writable cache dir it refuses
   * to serve any font at all - which shows up much later and very confusingly,
   * as st looping with "can't open font JetBrainsMono Nerd Font Mono". */
#ifndef RLOS_ATOM
    /* Desktop-only. rlos-atom ships no fonts and no fontconfig, so this cache
     * directory would be an empty dir nothing ever reads. The rest of the
     * reason it exists is above: fontconfig will not serve any font at all
     * without a writable cache dir, which shows up much later as st looping
     * with "can't open font ...". */
    xmkdir("/tmp/fccache", 01777);
#endif

  /* Accounts and privilege. secure_sudo_files() first: sudo checks its own
   * ownership and setuid bit at startup, so it has to be correct before the
   * first user process can try to run it. */
  secure_sudo_files();

    /* The atom image next, for the same reason: it must be root-owned before any
     * user process can reach it, because unpacking it is a user-facing thing to
     * do and it is what every container's root filesystem comes from. */
    secure_atom_image();

  /* root's home for the rescue shell; the user's home below. */
  xmkdir("/root", 0700);
  xmkdir("/home", 0755);
  xmkdir("/home/user", 0755);
  /* Everything under /home/user, not just the directory itself.
   *
   * Chowning only the directory leaves a real bug on an installed stick. The
   * initramfs is packed by an unprivileged build user, so there everything
   * arrives uid 1000 and a single chown on the top dir is enough. But
   * rlos-disk/mkusb.sh runs assemble-rootfs.sh as ROOT and then `cp -a`s the
   * tree onto the stick, which preserves that root ownership. init is root, so
   * it can and must fix it - otherwise the user lands in a directory it owns
   * whose immediate children are root-owned, and the first thing that tries to
   * write there (rlt --compile writing hostname.c next to hostname.rl, say)
   * fails with EACCES. That is exactly the symptom: `sudo chown -R user
   * ~/programs` made it go away.
   *
   * Done here rather than in the build because init cannot assume how the tree
   * was produced - same reasoning as secure_sudo_files() above.
   */
  chown_tree("/home/user", USER_UID, USER_GID);
  /* fontconfig's cache is written by the desktop, which now runs as the user;
   * a root-owned 1777 dir makes fontconfig warn about the cache and fall back
   * to scanning /usr/share/fonts on every start. Owning it is both quieter and
   * faster. */
#ifndef RLOS_ATOM
  if (chown("/tmp/fccache", USER_UID, USER_GID) != 0)
    warnf("chown", "/tmp/fccache");
#endif

  /* Start the shell in the user's home, not /. If /home/user is missing
   * from the image we stay at / rather than failing the boot. */
  if (chdir("/home/user") != 0)
    warn("init: chdir /home/user failed, staying at /\n");

  if (sethostname("system", 6) != 0)
    warn("init: sethostname failed\n");

  /* Kernel log colorizer: boot with loglevel=3 so only emerg/alert/crit
   * reach the console plain, and klogd reprints everything else from
   * /dev/kmsg with per-priority colors. It is the first child in the table
   * below so the backlog is dumped before anything else draws. */
   /* Supervised children. In X mode this is klogd, Xorg, i3 and mlterm; if X
    * will not start we fall back to the text session and run klogd + the
    * shell instead. needs_x gates i3 and mlterm on the display actually being
    * up, so a dead X server cannot put them into a crash loop.
    *
    * needs_net is the same trick one level down, and it exists because DHCP was
    * blocking boot: sshd used to be registered only when an address had already
    * been found, which meant the decision had to be made synchronously before
    * this loop ran, which meant net_up() had to block too. needs_net moves the
    * decision INTO the loop, where it is re-evaluated as conditions change, so
    * network setup is free to finish whenever it finishes.
    *
    * Both flags are checked here rather than by omitting the entry, because an
    * omitted entry is gone permanently: a machine that booted before its NIC
    * finished negotiating would never get sshd at all. */

  /* The bounded-insert bound and the supervise() macro are defined once, at file
   * scope, above the struct. They were ALSO duplicated here, and that was not
   * merely untidy: the copy in this scope said SUPERVISE_MAX 8 while the
   * file-scope one said 12, so the inner definition - the one actually in effect
   * for every supervise() call in main() - silently capped the table at 8 and
   * dropped the four VT shells with "supervised table full". The compiler said
   * "SUPERVISE_MAX redefined" and that warning was the only thing standing
   * between a source edit and a boot with two missing shells. */
    /* Every argv that procs[] holds must have STATIC storage duration.
     *
     * This is not a style preference; it is the whole explanation for a defect
   * that spent a long time looking like something else. A compound literal -
   * (char *[]){ "i3", "-c", ..., NULL } - inside a function has AUTOMATIC storage
   * duration associated with the ENCLOSING BLOCK (C11 6.5.2.5p5). The i3 and
   * mlterm entries are registered inside the `if (use_x) { ... }` block, so their
   * literals die when that block closes, while procs[].argv still points at them.
   *
   * The compiler then reuses that freed stack for the literals registered later
   * at main()'s top level, and the stale pointers start reading the new contents.
   * Observed, after adding the boot-time table dump:
   *
   *     [i3]       path=/bin/i3           argv=/usr/libexec/bluetooth/bluetoothd --experimental
   *     [iwd]      path=/usr/libexec/iwd  argv=/usr/libexec/bluetooth/bluetoothd --experimental
   *     [bluetoothd] path=/usr/.../bluetoothd argv=/usr/.../bluetoothd --experimental
   *
   * name and path were always correct because string literals have static
   * storage; only argv - the one field that is an ARRAY rather than a literal -
   * was wrong. i3 was then exec'd with bluetoothd's arguments and died on a
   * "wrong argument", which is what finally made it visible.
   *
   * That it took this long is the point: the source was correct, every
   * initializer was in the right order, and the compiled binary matched the
   * source. A wrong answer computed from correct source is the hardest kind to
   * find, and the table dump is what turned it into an obvious one.
   */
    static char *klogd_argv[]       = { "klogd", NULL };
    static char *ash_argv[]         = { "ash", "-i", NULL };
  static char *i3_argv[]          = { "i3", "-c", "/etc/i3.config", NULL };
  static char *mlterm_argv[]      = { "mlterm", NULL };
  static char *iwd_argv[]         = { "/usr/libexec/iwd", NULL };
  static char *bluetoothd_argv[]  = { "/usr/libexec/bluetooth/bluetoothd",
                                      "--experimental", NULL };
  supervise(procs, &nprocs, { "klogd", "/sbin/klogd",
      klogd_argv, child_envp, 0, 0, -1, 0, 0, NULL });

  /*
   * A shell on the text console, always, so a broken terminal is never a dead
   * end.
   *
   * WHY THIS IS NEEDED. The obvious way to look at a log is to run `log` in a
   * terminal. That works right up until the thing being diagnosed IS the
   * terminal: mlterm failing to start means no window to type `log` into,
   * so the instruction to run it is unusable. Without this, the only way to
   * read the file explaining why mlterm died would be to fix mlterm
   * first. That is the same trap rlos.diag exists further down to escape, one
   * level out: diag needs a kernel command line edit, this needs only
   * Ctrl+Alt+F1.
   *
   * It runs on tty0, which X does not touch - X is on vt2 (X_VT) precisely so
   * this console stays usable, so the two never compete for the screen and the
   * kernel messages init and klogd print are still there to read.
   *
   * needs_x is 0: this must work precisely when X did not come up, which is
   * when it is most needed. ash reads no DISPLAY and needs no graphics.
   */
supervise(procs, &nprocs, { "ash", "/bin/ash",
        ash_argv, child_envp, 0, 0, -1, 0, 0, NULL });

  /* Login shells on the remaining VTs: Ctrl-Alt-F3 through F6.
   *
   * They exist because there is no getty in this image, and without something
   * attached a VT is simply blank - switching to F3 on a machine with only the
   * tty1 shell and X on vt2 gives a black screen and no way back to a prompt,
   * which looks exactly like a hang. Without X there is no vt2 to skip past, so
   * the range starts one key earlier (see VT_SHELL_MIN).
   *
   * Registered here rather than after the X block, and deliberately outside the
   * use_x branch, for the same reason the rescue shell above is: these must work
   * precisely when X did not come up, which is when a text console is most
   * wanted. needs_x is 0 throughout.
   *
   * They run as uid 1000, not root. The rescue shell on tty1 stays root - it is
   * the last thing standing if the desktop fails - but that many always-resident
   * root shells on keys a user can reach by muscle memory is more than the
   * situation needs. sudo is present and working (secure_sudo_files() above), so
   * admin work is one prefix away.
   *
   * vt_shell_envp rather than child_envp, because child_envp sets HOME=/root: a
   * uid-1000 shell would try to keep its history and create scratch files in a
   * directory it does not own, and every one of those would fail. TERM=linux is
   * right here - these are VGA text consoles, and the x_envp value
   * (mlterm-256color) would describe capabilities the console does not have.
   *
   * ash_argv is shared by all of them deliberately: it has static storage
   * duration, which is the property that fixed the argv corruption bug, and
   * sharing one array for several children that take no arguments cannot make
   * it stale. Only name and ctty differ per entry. */
  /* F2 is the desktop only when the image has one. Built without -x there is
   * no Xorg, so vt2 is free and becomes just another login shell rather than a
   * dead key next to four that work. */
int have_xorg = (access("/bin/Xorg", X_OK) == 0);
    /* sway claims a VT the same way Xorg does, so the F2 desktop slot belongs to
     * whichever compositor is in the image. Keying this on Xorg alone was fine
     * only because there was no other option; with -w there are two, and an
     * image carrying both (which the -x -w rejection in assemble-rootfs.sh
     * forbids, but init cannot assume the image was built by that script) would
     * put sway and the VT shells on the same terminal. */
    int have_sway = (access("/bin/sway", X_OK) == 0);
    int have_desktop = have_xorg || have_sway;
    int vt_shell_first = have_desktop ? VT_SHELL_FIRST : VT_SHELL_MIN;
    int n_vt_shells = VT_SHELL_LAST - vt_shell_first + 1;

  /* Per-VT storage for the table below. It has to outlive this scope: procs[]
   * keeps a pointer to both strings for the lifetime of the run, and a loop-local
   * array would be reused by the next iteration. Sized for the larger of the two
   * ranges (VT_SHELL_MIN..VT_SHELL_LAST); with X present the first entries are
   * simply never filled. */
  static struct {
    char name[8];   /* "tty3" - strcmp()'d in the loop and in the table dump, so
                     * deliberately NOT "/dev/tty3" */
    char ctty[16];  /* "/dev/tty3" */
  } vt_shells[VT_SHELL_LAST - VT_SHELL_MIN + 1];

  for (int k = 0; k < n_vt_shells; k++) {
    int vt = vt_shell_first + k;
    char *q = put_str(vt_shells[k].name, vt_shells[k].name + sizeof(vt_shells[k].name), "tty");
    *put_dec(q, vt) = '\0';
    q = put_str(vt_shells[k].ctty, vt_shells[k].ctty + sizeof(vt_shells[k].ctty), "/dev/tty");
    *put_dec(q, vt) = '\0';
    supervise(procs, &nprocs, { vt_shells[k].name, "/bin/ash",
        ash_argv, vt_shell_envp, 0, 1, -1, 0, 0, vt_shells[k].ctty });
  }
if (have_xorg)
      warn("init: vt layout: F1 log, F2 desktop, F3-F6 shells\n");
    else if (have_sway)
      warn("init: vt layout: F1 log, F2 sway, F3-F6 shells (Wayland backend)\n");
    else
      warn("init: vt layout: F1 log, F2-F6 shells (no desktop: built without -x or -w)\n");

  int use_x = 0;
  /* Declared next to use_x rather than at the point of use, because the client
   * branch below tests it and the compositor block in between is what sets it. */
  int use_sway = 0;

  /*
   * Diagnostic boot: "rlos.diag" on the kernel command line. Report what the
   * input layer exposes and then stop, deliberately leaving the text console
   * on screen instead of starting a desktop.
   *
   * This exists because of a specific trap. When input does not work on real
   * hardware, the report that would explain why is written by the X input
   * driver - and X covers the text console, on its own VT, with a desktop
   * that cannot be typed into. The user is then asked for a log they have no
   * way to read, and the only way to see it is a keyboard that does not work.
   * Starting no X at all puts the answer where it can be seen, and can be
   * photographed, with nothing depending on the thing being diagnosed.
   */
  if (strstr(read_cmdline(), "rlos.diag")) {
    warn("\ninit: ==== DIAGNOSTIC MODE (rlos.diag) ====\n");
    warn("init: not starting X, so this report stays on screen.\n");
    {
      pid_t d = fork();
      if (d == 0) {
        char *argv[] = { "/usr/bin/rlin", NULL };
        execve("/usr/bin/rlin", argv, child_envp);
        _exit(127);
      }
      if (d > 0) {
        int st = 0;
        if (waitpid(d, &st, 0) == d && WIFEXITED(st)) {
          char num[12];
          num[0] = '\0';
          warn("init: rlin finished, status ");
          *put_dec(num, WEXITSTATUS(st)) = '\0';
          warn(num);
          warn("\n");
        }
      }
    }
    warn("init: ==== end report; desktop NOT started ====\n");
    warn("init: photograph or transcribe the lines above.\n");
    /* Stay alive on the text console so the report is not scrolled away by a
     * shell prompt, and so the machine is not left looking hung. */
    for (;;)
      pause();
  }

  /* udevd BEFORE either compositor, not inside the X11 branch.
   *
   * libinput will not open a single input device without a udev database entry
   * for it: src/path-seat.c open_restricted() calls udev_device_new_from_devnum()
   * and then polls udev_device_get_is_initialized() 200 times at 10ms before
   * giving up with "udev device never initialized". It needs the ID_INPUT,
   * ID_INPUT_KEYBOARD and friends tags to decide what a device even is, and
   * those only exist once udevd has classified them.
   *
   * With this call inside `if (access("/bin/Xorg", X_OK) == 0)`, a -w image never
   * ran udevd at all, so libinput opened zero devices and wlroots aborted the
   * backend - with no message naming udev anywhere:
   *
   *   [wlr] [backend/libinput/backend.c:111] libinput initialization failed,
   *                                            no input devices
   *
   * The node permissions were correct, the quirks parsed, the data was in
   * /usr/share/libinput. All of that was still irrelevant: no database, no
   * devices. Same underlying requirement as the X11 branch, which is exactly why
   * it was worth lifting out rather than duplicating. */
  start_udevd();

  if (access("/bin/Xorg", X_OK) == 0) {
    /* Wait for the input stack to stop changing before generating anything from
     * it. The keyboard is ready almost immediately, the touchpad and psmouse
     * probe much later, and libinput permanently excludes any device whose udev
     * entry is not yet classified - so generating the config without this wait
     * produces a desktop where the keys work and the cursor never moves. */
    settle_input_devices();
    /* XDG_RUNTIME_DIR must exist and be 0700 before i3 starts, or its mkdirp
     * fails and i3 exits with EXIT_FAILURE (get_process_filename.c:34). */
    xmkdir("/run/user", 0755);
    xmkdir("/run/user/1000", 0700);
    /* Owned by the user: i3 runs as uid 1000 and creates its IPC socket under
     * this directory, so a root-owned 0700 dir would make i3 fall back to a
     * random mkdtemp - or exit. */
    if (chown("/run/user/1000", USER_UID, USER_GID) != 0)
      warnf("chown", "/run/user/1000");
    /* Write the config before the server reads it. xf86-input-libinput takes
     * each device node from an explicit Option "Device", one section per node,
     * and the set of nodes is only knowable on this machine right now. */
    gen_input_config();
    /* Xorg needs the socket directory to exist; it is staged by
     * assemble-rootfs.sh, but create it here too so a stripped-down image
     * still gets a working display rather than a silent Xorg failure. */
    xmkdir("/tmp/.X11-unix", 01777);

    /* Authenticate the display. This has to happen BEFORE the server starts,
     * because Xorg is given -auth X_AUTHFILE and will refuse every client if
     * that file does not exist. Creating it here - not earlier - keeps it in
     * one place with the rest of the X setup, and after /run exists.
     *
     * On failure the desktop cannot come up at all, so say so plainly and
     * continue rather than pretending: the text console on tty0 is still
     * there, and the log line is on it. */
    if (make_x_cookie()) {
      warn("init: X display authenticated (MIT-MAGIC-COOKIE-1, -ac not needed)\n");
    } else {
      warn("init: WARNING - no X cookie; the desktop will not start.\n");
      warn("init:   i3 and mlterm will fail to open the display.\n");
      warn("init:   Use the text console on tty0. (rlin for input diagnostics)\n");
    }
    /* Report which driver gen_input_config() settled on. Worth saying plainly
     * because it is the thing under test: on hardware with i915 bound this
     * should read "i915", and if it says efidrm or "no GPU driver" then the GPU
     * driver did not attach and the lag is not fixed, whatever X's own log
     * says. Naming the driver rather than just "is there a /dev/dri node"
     * matters because DRM_EFIDRM creates /dev/dri/card0 on its own. */
    report_sound();

    {
      char drv[64];
      if (have_gpu_driver(drv, sizeof(drv))) {
        warn("init: graphics: modesetting on /dev/dri/card0, GPU driver ");
        warn(drv);
        warn("\n");
      } else {
        warn("init: graphics: fbdev on /dev/fb0 (no GPU driver bound)\n");
      }
    }
    /* The fbdev DDX reads /dev/fb0 directly, and it is the fallback path, so
     * this check only matters when modesetting was NOT chosen. If devtmpfs
     * did not register it there is no display to come up, and Xorg's only
     * complaint is the very indirect "open /dev/fb0: No such file or
     * directory" followed by "no screens found" - so name the cause here,
     * in plain terms. */
    if (access("/dev/dri/card0", F_OK) != 0 &&
        access("/dev/fb0", R_OK | W_OK) != 0) {
      warn("init: no usable /dev/fb0 (");
      warn(strerror(errno));
      warn(")\n");
      warn("init: no UEFI graphics device? boot with OVMF and -vga std, not\n");
      warn("init: SeaBIOS. Without an EFI framebuffer the kernel has no\n");
      warn("init: framebuffer, so there is nothing for X to draw on.\n");
    }
    /* No -xrm here: Xorg 21.1.24 rejects it with
     * "Fatal server error: Unrecognized option: -xrm". The cursor theme
     * travels in x_envp as XCURSOR_THEME, and st's font and colours are
     * compiled into its config.h by build_x11.sh. */
    /* Run X on its own VT. When Xorg shares tty0 with fbcon it puts the
     * terminal into its own mode, and a killed or crashed Xorg never gets to
     * restore it - the leftover state makes the next rlsh read EOF and exit
     * immediately, so a failed X start takes the text shell down with it.
     * On a separate VT the text console on tty0 is never touched, and
     * Ctrl-Alt-F1 gets you back to it. F2 is the desktop; F3-F6 are the extra
     * login shells (see the VT layout at X_VT). Only F1 works as the escape
     * hatch - there is no getty in this image, so a VT with nothing attached
     * to it is simply blank, which is why an earlier version of this comment
     * offering "F1/F2" was wrong about the second key. */
    /* static, not an automatic array: procs[] keeps a pointer to this and the
     * supervision loop reads it long after this block has exited. As a stack
     * array its storage was reused by the i3/mlterm entries further down, so a
     * restarted Xorg was exec'd with the wrong arguments. */
    static char *xorg_argv[] = {
        "/bin/Xorg", X_DISPLAY,
        X_VT,
        "-config", X_CONF,
        /* The guest has no /var/log, and Xorg treats that as fatal rather
         * than just warning: "Cannot open log file" is a fatal server error.
         * /log exists (init creates it) and is where the user looks once the
         * desktop has covered the console. */
        "-logfile", X_LOG,
        /*
         * -verbose 1, deliberately: libinput reports a successful attach at
         * LogV only, so without some verbosity the driver either works or does
         * not and the console is silent either way - which is what made the
         * previous input driver so hard to diagnose.
         *
         * Level 1 rather than 2 or 3 on purpose. Every Xorg message goes to the
         * log AND to /dev/console, and /dev/console is the framebuffer here, so
         * anything a driver logs per frame becomes a full console redraw per
         * frame. That is the difference between a responsive desktop and a
         * laggy one, and the video driver is the one that logs per frame. Raise
         * this only to chase something specific, and take the lag with it.
         */
        "-verbose", "1",
        /*
         * -auth /run/Xauthority: the real thing, replacing -ac.
         *
         * Xorg has to stay root (DRM, render nodes) but the clients run as
         * uid 1000, and with no shared credentials a root server refuses every
         * connection. -ac solved that by disabling host-based access control
         * altogether, which means ANY local process can connect: read the
         * screen, inject synthetic key events, snoop keystrokes. The old
         * comment argued that was acceptable because "the only local user is
         * the person at the keyboard, who can sudo to root anyway" - which
         * concedes the point. Anything that runs as the user is then also
         * trusted with the display, and that includes every program they run.
         *
         * The cookie is generated by xauth before the server starts (see
         * make_x_cookie), so Xorg accepts the clients that present it and
         * rejects everything else. Nothing else about the setup changes:
         * XAUTHORITY for the clients is set in x_envp below.
         */
        "-auth", X_AUTHFILE,
        NULL,
    };
    for (int attempt = 1; attempt <= X_MAX_TRIES && !use_x; attempt++) {
      pid_t x = fork();
      if (x < 0) {
        warn("init: fork for Xorg failed\n");
        break;
      }
      if (x == 0) {
        /* Only stdin is thrown away. stdout/stderr stay on the console on
         * purpose: if xorg.conf or the fbdev driver is wrong, Xorg says so
         * there, and swallowing it would leave a black screen with no
         * explanation - the failure mode this whole fallback exists to
         * avoid. */
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
          dup2(devnull, 0);
          if (devnull > 2)
            close(devnull);
        }
        execve("/bin/Xorg", xorg_argv, x_envp);
        warn("init: exec /bin/Xorg failed\n");
        _exit(1);
      }
      if (wait_for_x(X_WAIT_S)) {
        supervise(procs, &nprocs, { "Xorg", "/bin/Xorg",
            xorg_argv, x_envp, 0, 0, x, 0, 0, NULL });
        use_x = 1;
        warn("init: X display is up\n");
        report_perf();
        /* After the perf report so Xorg.log has had a moment to be created,
         * and last so its own output of this moment cannot alter the count. */
        usleep(300 * 1000);
        report_logs();

      } else {
        warn("init: Xorg did not create ");
        warn(X_SOCKET);
        warn("\n");
        kill(x, SIGKILL);
        waitpid(x, NULL, 0);
      }
    }
  }

    /* ---- the Wayland backend ------------------------------------------------
     *
     * Deliberately NOT an "if (use_x) ... else ..." fork of the X11 path. The
     * two stacks share almost nothing: different display server, different
     * protocol, different client model, and no shared configuration file.
     * What they share is the shape - start a compositor, then start clients that
     * connect to it - and that is all this borrows.
     *
     * XWayland is NOT started yet. It is a large extra dependency (needs meson,
     * pixman, and pulls in xkbcomp and a chunk of the X protocol implementation)
     * and nothing in the compositor stack needs it. When it is added it starts
     * as a child of sway - `sway --unsupported-gpu` execs it - or as a
     * supervised child of init, and at that point wl_envp needs a DISPLAY
     * pointing at it, which is why DISPLAY is absent above rather than set to
     * a placeholder.
     */
    if (have_sway) {
      /* What the compositor actually has to work with, printed before it is
       * started. Without this the only symptom of a missing DRM node is
       *
       *   [sway/server.c:270] Unable to create backend
       *
       * which names neither the device nor the reason. The X11 branch has an
       * equivalent report for the same reason.
       *
       * The /dev listing is the important half: it distinguishes "the driver
       * never bound" from "the driver bound and devtmpfs did not create a node",
       * and those two need completely different fixes. Only the driver's own
       * presence can be concluded from /sys, which is why have_gpu_driver()
       * checks the bound driver rather than the existence of /dev/dri/card0 -
       * DRM_EFIDRM creates that node on its own even when no GPU driver is
       * bound, so the node's existence proves nothing. */
      {
        char drv[64];
        if (have_gpu_driver(drv, sizeof(drv))) {
          warn("init: graphics: KMS driver bound is ");
          warn(drv);
          warn("\n");
        } else {
          warn("init: graphics: no GPU driver bound\n");
        }
        if (access("/dev/dri/card0", F_OK) == 0)
          warn("init: graphics: /dev/dri/card0 present\n");
        else
          warn("init: graphics: /dev/dri/card0 ABSENT\n");
        /* List what devtmpfs actually made. Short and unsorted on purpose: this
         * is a one-shot diagnostic on a failure path, and pulling in a directory
         * walk for it would be more machinery than the thing it diagnoses. */
        {
          DIR *d = opendir("/dev");
          struct dirent *e;
          int shown = 0;
          if (d) {
            while ((e = readdir(d)) != NULL) {
              if (e->d_name[0] == '.')
                continue;
              warn("  /dev/");
              warn(e->d_name);
              warn("\n");
              if (++shown >= 24)
                break;
            }
            closedir(d);
          }
        }
      }

      /* Wait for udev to finish classifying devices before sway starts.
       *
       * Same reason as the X11 branch calls settle_input_devices(): libinput
       * PERMANENTLY excludes a device whose udev entry is not yet classified -
       * the ID_INPUT* tags it needs to decide what a device is are written
       * asynchronously, and a device missing them at enumeration time is not
       * reconsidered later. The keyboard is ready almost immediately; the
       * touchpad and psmouse probe several seconds later.
       *
       * On the Wayland side this matters more, not less: there is no later
       * re-read. Xorg gets input through its own driver which re-probes, whereas
       * wlroots opens libinput exactly once during backend startup - if the
       * database is incomplete at that instant, the session simply has no input
       * for its whole life. */
      settle_input_devices();

      /* Open the DRM and evdev nodes up to uid 1000 BEFORE sway starts.
       *
       * sway runs as the user (as_user=1 below), and devtmpfs creates device
       * nodes 0600 root:root. Without this, libinput opens no input devices,
       * wlroots drops the backend, and the only symptom is the generic
       * "sway did not create ..." message further down. Nothing here is
       * Wayland-specific in principle - the same 0600 nodes are why a
       * non-root compositor cannot work - but the X11 path never hit it because
       * Xorg runs as root. */
      open_nodes_for_user("/dev/dri", 0666);
      open_nodes_for_user("/dev/input", 0644);
      open_nodes_for_user("/dev/hidraw", 0644);

      /* XDG_RUNTIME_DIR must exist, be mode 0700, and be owned by uid 1000.
       *
       * The compositor binds its socket inside it and refuses to start if the
       * directory is missing or not owned by it. init runs as root, so without
       * the chown sway would fail with an opaque "failed to create socket".
       * 0700 and not 0755 because the protocol specification requires it:
       * it is a per-user directory, and a world-readable one lets other users
       * connect to the compositor. There is only one non-root user here, but
       * the mode is free and the alternative is a habit.
       *
       * mkdir ignoring EEXIST is the point, not an oversight: the X11 branch
       * has already created this same directory for the i3 IPC socket, and a
       * plain mkdir would fail on a perfectly good directory. */
      mkdir("/run/user", 0755);
      mkdir("/run/user/1000", 0700);
      /* Clear sockets left behind by a previous failed start.
       *
       * wl_display_add_socket_auto() takes the FIRST FREE name, not a fixed
       * one. A stale wayland-0 therefore makes the next compositor bind
       * wayland-1 instead - and init waits for wayland-0 specifically, so the
       * session then fails for a reason that has nothing to do with the failure
       * that left the socket. Observed on hardware:
       *
       *   srwxr-xr-x root root wayland-1
       *   -rw-r----- root root wayland-1.lock
       *
       * and init reporting "sway did not create /run/user/1000/wayland-0" while
       * the compositor was in fact perfectly healthy under a different name.
       *
       * Unlinking only what a compositor creates, and never a directory: a
       * mistaken pattern here could remove /run/user/1000 itself. */
      for (int k = 0; k < 2; k++) {
        const char *pats[2] = { "/run/user/1000/wayland-", "/run/user/1000/sway-ipc." };
        for (int i = 0; i < 2; i++) {
          DIR *rd = opendir("/run/user/1000");
          struct dirent *re;
          if (!rd) break;
          while ((re = readdir(rd)) != NULL) {
            if (re->d_name[0] == '.') continue;
            if (strncmp(re->d_name, pats[i], strlen(pats[i])) != 0) continue;
            char sp[128];
            char *q = put_str(sp, sp + sizeof(sp) - 1, "/run/user/1000/");
            put_str(q, sp + sizeof(sp) - 1, re->d_name);
            unlink(sp);
          }
          closedir(rd);
        }
        break;
      }
      /* And the .lock files, which have a different name again. */
      {
        DIR *rd = opendir("/run/user/1000");
        struct dirent *re;
        if (rd) {
          while ((re = readdir(rd)) != NULL) {
            size_t ln = strlen(re->d_name);
            if (re->d_name[0] == '.') continue;
            if (ln < 5 || strcmp(re->d_name + ln - 5, ".lock") != 0) continue;
            char sp[128];
            char *q = put_str(sp, sp + sizeof(sp) - 1, "/run/user/1000/");
            put_str(q, sp + sizeof(sp) - 1, re->d_name);
            unlink(sp);
          }
          closedir(rd);
        }
      }
      if (chown("/run/user/1000", 1000, 1000) < 0)
        warn("init: could not chown /run/user/1000 - sway will not be able to bind its socket\n");

      /* No seatd. libseat can open a DRM node directly given the right
       * permissions, and running seatd as root while sway runs as uid 1000
       * would mean the compositor talking to a privileged helper it does not
       * need in this image. wlroots' direct backend logs that it is using the
       * direct session, which is the correct behaviour here. */

      /* -c /etc/sway/config given explicitly, for the same reason i3 is given
       * -c in the X11 branch: sway looks in a list of paths relative to $HOME
       * before the system config, and $HOME belongs to the user, so an
       * explicit absolute path is what actually makes the staged config load. */
      static char *sway_argv[] = {
          "/bin/sway", "-c", "/etc/sway/config", NULL,
      };

      pid_t sw = fork();
      if (sw < 0) {
        warn("init: fork for sway failed\n");
      } else if (sw == 0) {
        /* stdin is thrown away; stdout/stderr stay on the console on purpose.
         * sway reports the failures that matter here - no outputs, no seat,
         * permission denied on a DRM node - and swallowing them would leave a
         * black VT with no explanation, which is the exact failure mode the X
         * branch's equivalent comment describes. */
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
          dup2(devnull, 0);
          if (devnull > 2)
            close(devnull);
        }
        /* stderr ALSO goes to a file, not only to the console.
         *
         * Everything sway and wlroots say goes to stderr. On a VT that is also
         * the text-mode fallback, so by the time anyone reads it the real error
         * has scrolled away, and init's own message - "sway did not create
         * /run/user/1000/wayland-0" - names neither the cause nor the device.
         * init does not write to /proc/kmsg, so the kernel ring never sees it
         * either.
         *
         * That blind spot cost several rounds: every fix so far (WAYLAND_DISPLAY,
         * libseat, libinput's compiled-in data path, the 0600 device nodes) was
         * found by running sway BY HAND, not by reading any log. Console output
         * is unchanged; the file is what makes the next failure legible. /var is
         * a tmpfs here, so it costs nothing and lives until reboot. */
        xmkdir("/var/log", 0755);
        int slog = open("/var/log/sway.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (slog >= 0) {
          dup2(slog, 2);
          if (slog > 2)
            close(slog);
        }
        /* seatd-launch starts the daemon and execs sway with SEATD_SOCK set.
         * See build_wl.sh for why this changes the teardown behaviour. */
        /* Both of sway's arguments have to come through. Passing only
         * sway_argv[1] hands sway a bare "-c" with nothing after it, and sway
         * exits printing getopt's usage text - which is exactly what the
         * first hardware test showed. */
        char *seatd_argv[] = {
            "seatd-launch", "--", "/bin/sway",
            sway_argv[1], sway_argv[2], NULL
        };
        execve("/bin/seatd-launch", seatd_argv, sway_envp);
        warn("init: seatd-launch exec failed - falling back to bare sway\n");
        execve("/bin/sway", sway_argv, sway_envp);
        warn("init: exec /bin/sway failed\n");
        _exit(1);
      }

      /* Wait for the socket rather than assuming success. sway binds it once
       * the backend is up, which is after it has opened the DRM device and
       * enumerated outputs; a compositor that exits immediately - no KMS
       * device, no permissions - would otherwise leave init claiming a desktop
       * that is not there, with nothing on the console to explain why.
       *
       * The check is the socket's existence because that is the only observable
       * that means "a client can connect", which is what "did the desktop
       * start" actually has to mean. */
      if (wait_for_path(WL_SOCKET_PATH, SOCK_WAIT_MS)) {
        supervise(procs, &nprocs, { "sway", "/bin/sway",
            sway_argv, sway_envp, 1, 1, sw, 0, 0, NULL });
        use_sway = 1;
        warn("init: Wayland display is up (");
        warn(WL_DISPLAY_NAME);
        warn(")\n");
      } else {
        warn("init: sway did not create ");
        warn(WL_SOCKET_PATH);
        warn("\n");
        /* Before blaming sway, check the thing it cannot work around: wlroots'
         * DRM backend needs a modesetting device. An EFI framebuffer is not one
         * - it exposes no connectors over KMS - so with only -vga std and no
         * virtio-gpu, sway starts and exits with "No outputs detected". That is
         * the single most likely cause of this failure in QEMU and it is worth
         * naming, because the symptom on screen is identical to a compositor
         * that is simply broken. */
        if (access("/dev/dri/card0", F_OK) != 0) {
          warn("init:   no /dev/dri/card0. The compositor needs a KMS device, and\n");
          warn("init:   an EFI framebuffer is not one - run run_qemu.sh --video,\n");
          warn("init:   which adds virtio-gpu alongside the framebuffer.\n");
        }
        kill(sw, SIGKILL);
        waitpid(sw, NULL, 0);
      }
    }

  if (use_x) {
/* Wallpaper first, so there is something behind the desktop. It runs as
     * root (like setrootcursor) because it writes the root window's background
     * pixmap, and root is the server's own uid. */
    run_x_helper("/usr/bin/setrootbg");

    /* Theme the root cursor before any window manager runs.
     *
     * Xorg will not do it: CreateRootCursor (dix/cursor.c) opens a font named
     * "cursor" and builds a glyph cursor from it, and the server has no
     * libXcursor or XCURSOR_THEME support anywhere - so XCURSOR_THEME in the
     * environment does nothing here, and with no "cursor" font shipped the
     * pointer is a black block.
     *
     * i3 overwrites whatever we set. At startup it calls
     * xcursor_set_root_cursor(XCURSOR_CURSOR_POINTER), which goes through
     * libxcb-cursor. That library does NOT read XCURSOR_THEME; it reads the
     * Xcursor.theme X resource, which there is no way to set here (no xrdb),
     * and otherwise looks for an icon theme literally named "default",
     * falling back to a solid "core" cursor when there is none. So TWO
     * independent things have to be true for the arrow to look right:
     *   1. build_x11.sh stages /usr/share/icons/default as the cursor theme, so
     *      i3's own call finds the staged Bibata cursors.
     *   2. i3.config also runs setrootcursor through exec, which re-applies the
     *      theme after i3 has overwritten it.
     * Either alone fixes it; both are cheap, so both are done. */
    run_x_helper("/usr/bin/setrootcursor");

    /* i3, not dwm. -c is given explicitly with an absolute path because i3
     * refuses to start without a config (src/config.c:235) and otherwise looks
     * only at paths relative to $HOME, which is not worth depending on here. */
    supervise(procs, &nprocs, { "i3", "/bin/i3",
        i3_argv, x_envp, 1, 1, -1, 0, 0, NULL });
    /* mlterm. No -e / shell argument on purpose: with none, mlterm execs the
     * login shell named by $SHELL, and init sets SHELL=/bin/ash in x_envp; the
     * terminal does not need to be told what init already told the session.
     * Font, type engine and termtype come from the staged /usr/etc/mlterm/
     * config, which build_x11.sh writes - see the note there for why the
     * upstream defaults do not work in this guest. */
supervise(procs, &nprocs, { "mlterm", "/bin/mlterm",
          mlterm_argv, x_envp, 1, 1, -1, 0, 0, NULL });
    } else if (use_sway) {
      /* swaybar. Started as the user, like every other client, because it
       * connects to the compositor over $XDG_RUNTIME_DIR - a uid-1000 socket -
       * and a root client is refused by the same logic that refuses any other
       * uid. No -c config: swaybar's defaults are usable, and a config here
       * would be a second thing to keep in sync with the X11 equivalents. */
      static char *swaybar_argv[] = { "/bin/swaybar", NULL };
      supervise(procs, &nprocs, { "swaybar", "/bin/swaybar",
          swaybar_argv, wl_envp, 1, 1, -1, 0, 0, NULL });

      /* No wallpaper and no terminal yet. swaybg is not built (it is a
       * separate project, not part of the sway tree) and no terminal emulator
       * is staged for the Wayland backend; sway's own background is whatever
       * swaybg would have painted, which is the default solid colour. Adding
       * either later is one supervise() call each - the table has room, which
       * is the reason it was raised to 18 above rather than left at 12. */
    } else {
      if (access("/bin/Xorg", X_OK) == 0) {
        warn("init: X display did not come up - falling back to the text console\n");
      } else if (access("/bin/sway", X_OK) == 0) {
        warn("init: sway did not come up - falling back to the text console\n");
        warn("init:   a KMS device is required. Under QEMU, run run_qemu.sh --video\n");
        warn("init:   (it adds virtio-gpu), not the default headless mode.\n");
      } else {
        /* No compositor in the image at all, as opposed to one that failed to
         * start. The two need different advice: the first is a hardware/driver
         * problem the rlin/rlperf diagnostics exist for, the second is simply
         * that the image was assembled without -x or -w. Say which, or the
         * user is left hunting a graphics fault that was never in the picture. */
        warn("init: no desktop in this image - text console only.\n");
        warn("init:   built without -x or -w (see assemble-rootfs.sh); rebuild with\n");
        warn("init:   -x for the i3 + mlterm desktop, or -w for sway.\n");
      }
    /* No shell is added here: the rescue ash registered earlier runs on tty0
     * unconditionally, so this branch already has a prompt waiting. Adding a
     * second one would put two interactive ashes on the same console, racing
     * for the keyboard, and neither would be reliably usable. */
  }

  /* Network, after X has been given its chance but regardless of whether it
   * worked. It used to sit inside the use_x branch, which meant a machine that
   * fell back to the text console got no address at all - and the headless case
   * (no X, ssh in over the network) is precisely when a network is wanted
   * most.
   *
   * Forked, not called. This used to be a synchronous net_up() between here and
   * the supervision loop, and it was the single largest cause of a bad first
   * impression on boot: udhcpc is bounded at six discovers two seconds apart, so
   * a machine with an unplugged cable sat here for up to ~12s. Worse, it was
   * visibly wrong rather than merely slow - Xorg had already been given a slot
   * in procs[] but nothing forks until the loop below, so the display was up and
   * drawing nothing while DHCP logged to the console behind it. That reads as a
   * hung desktop, and the obvious diagnosis ("X is broken") is the wrong one.
   *
   * The old comment here worried that backgrounding DHCP would race the first
   * curl a user types. It does not, and the reason is structural: nothing that
   * needs the network is started until the loop sees NET_READY, so there is no
   * consumer to race. The order that used to be implicit - "address, then sshd" -
   * is now enforced by the gate instead of by the order two statements execute.
   *
   * net_up() itself stays exactly as it was, synchronous inside its own child.
   * Its own udhcpc wait is bounded, which is what makes this safe: init as PID 1
   * forks instead of blocking, so no DHCP hang can stop the machine booting.
   *
   * _exit, not exit: this is a fork of init, and the parent's stdio buffers and
   * atexit handlers are not ours to flush. */
  /* Loopback, first, before anything can want it.
   *
   * The kernel gives lo the address 127.0.0.1/8 but leaves the interface DOWN,
   * and nothing here was ever bringing it up: iface_up() is only called on the
   * interface first_wired_iface() returns, and that function skips loopback by
   * name and by ARPHRD type. So the machine booted with no working loopback.
   *
   * That is invisible until something depends on it, and then it looks like a
   * networking bug rather than a missing line. sshd binds 0.0.0.0:22 either way,
   * so the listener exists and the port is open, but 127.0.0.1 is unreachable
   * because there is no interface behind it - the symptom is a refused or timed
   * out connection to an address that is definitionally always local. On a
   * machine with no cable plugged in it is the ONLY way in.
   *
   * Nothing above can be reordered to fix it later: /etc/hosts maps localhost to
   * 127.0.0.1, and every local service that resolves its own name needs this up
   * first. */
  if (iface_up("lo") != 0)
    warn("init: net: cannot bring loopback up - 127.0.0.1 will not work\n");
  else
    warn("init: net: loopback up\n");

  /* Declared out here rather than inside the block below because the supervision
   * loop needs it: the network child is not a supervised process, so the loop
   * has no other way to tell "DHCP is still trying" from "DHCP gave up". */
  pid_t net_setup_pid = -1;
  {
    pid_t netpid = fork();
    if (netpid < 0) {
      warn("init: net: fork for network setup failed - continuing without a network\n");
    } else if (netpid == 0) {
      net_up();
      _exit(0);
    } else {
      net_setup_pid = netpid;
    }
  }

  /* The D-Bus system bus, before iwd and bluetoothd are registered below.
   *
   * Started and WAITED FOR rather than added to the supervised table, because
   * both of those daemons connect to the bus during startup and exit if it is
   * absent - so ordering cannot be left to a table that forks everything at once.
   */
  start_dbus_once();

    /* The wireless rebind is NOT done here. It happens at the very top of main(),
     * right after sysfs is mounted - see the call there. It used to live here, and
     * a real boot log proved that position is too late: the rebind completed at
     * 4.5s, by which point iwd had already started and exited twice against a
     * machine that had no wireless interface yet. Calling it twice would only
     * re-probe a driver that had already succeeded.
     *
     * iwd is registered below and starts against a wireless interface that is
     * already present. */
    /* iwd. Registered only when there is something to drive: it opens a netlink

   * socket to cfg80211 at startup, and with no wireless driver bound it exits
   * non-zero. Suppressing it here turns "no Wi-Fi hardware" from a restart loop
   * into a single absent line.
   *
   * as_user 0: iwd configures the interface directly and needs CAP_NET_ADMIN. The
   * point of the D-Bus bus above is that iwctl does NOT need the same privilege -
   * it is a pure client and talks to iwd. That is what lets this image offer
   * wireless with no setuid helper and no working sudo on a TTY. */
  if (access("/usr/libexec/iwd", X_OK) != 0) {
    warn("init: wifi: no iwd - wireless unavailable\n");
  } else {
    /* iwd writes profiles here. Created explicitly because /var is on the
     * read-mostly root of the live image and iwd's own mkdir(0700) is the kind
     * of thing that fails quietly and then reports "no networks" forever. */
    xmkdir("/var/lib/iwd", 0700);
    supervise(procs, &nprocs, { "iwd", "/usr/libexec/iwd",
        iwd_argv, child_envp, 0, 0, -1, 0, 0, NULL });
    warn("init: wifi: iwd starting - connect with iwctl\n");
  }

  /* bluetoothd. Same shape as iwd, and the same reasoning about privilege:
   * the daemon owns the adapter, bluetoothctl does not.
   *
   * it runs with --experimental here because without it bluetoothd rejects the
   * deprecated-but-still-used org.bluez.AdapterAgent1 interface that a great many
   * pairing flows still rely on. The alternative on a system with no desktop
   * pairing agent is that pairing silently never completes. */
  if (access("/usr/libexec/bluetooth/bluetoothd", X_OK) != 0) {
    warn("init: bluetooth: no bluetoothd - bluetooth unavailable\n");
  } else {
    supervise(procs, &nprocs, { "bluetoothd", "/usr/libexec/bluetooth/bluetoothd",
        bluetoothd_argv, child_envp, 0, 0, -1, 0, 0, NULL });
    warn("init: bluetooth: bluetoothd starting - scan with bluetoothctl\n");
  }

  /* sshd, started ONCE and NOT supervised. See start_sshd_once() for why it is
   * deliberately not in procs[]; the short version is that OpenSSH daemonises on
   * its own, so -D existed only to satisfy the supervisor, and paying for that
   * with a respawn loop cost a 181-line log flood that buried the one error
   * worth reading.
   *
   * It is also no longer conditional on having an address. sshd binds
   * 0.0.0.0:22 regardless of whether the interface has one, so with no lease it
   * is still reachable on loopback - which is the only way in on a machine whose
   * cable is not plugged in, and that is exactly the machine you most want to be
   * able to log into. Gating it on an address used to mean "no network" also
   * meant "no shell", on a system whose whole purpose is being rescuable.
   * Reachability is reported honestly instead, in the log line below and in the
   * network child's own no-lease message. */
  if (strstr(read_cmdline(), "rlos.nosshd")) {
    warn("init: ssh: rlos.nosshd on the cmdline - not starting sshd.\n");
    warn("init: ssh: run /bin/sshd by hand to start it or to see why it would fail.\n");
  } else {
    start_sshd_once();
  }

  /* Set once the network child has exited, so the "no lease" case is reported
   * exactly once rather than on every pass of the loop. It no longer gates
   * anything - sshd is started unconditionally - so all that is left is to say
   * what the outcome means for reaching this machine. */
  int net_reported = 0;

  /* One-time dump of the table, immediately before the loop.
   *
   * This exists because of a specific defect that was invisible from source and
   * nearly impossible to reason about: a supervised child was observed logging
   *
   *     init: i3 (/bin/i3) exited, restarting as: /bin/sshd -D -e [exit 1]
   *
   * naming i3, pathing /bin/i3, and restarting with sshd's argv. Every
   * initialiser in the source was correct and in the right order, and the
   * compiled binary was verified byte-for-byte against that source - so the
   * table's contents could not be established by reading the code, only by
   * looking at what the process actually holds.
   *
   * Six lines, once, at boot, is a trivial price for making any future
   * name/path/argv disagreement visible instead of inferrable. */
  warn("init: supervised table:");
  for (size_t i = 0; i < nprocs; i++) {
    warn("init:   [");
    warn(procs[i].name);
    warn("] path=");
    warn(procs[i].path);
    warn(" argv=");
    for (char *const *a = procs[i].argv; *a != NULL; a++) {
      warn(a == procs[i].argv ? "" : " ");
      warn(*a);
    }
    warn(" needs_x=");
    warn(procs[i].needs_x ? "1" : "0");
    warn(" as_user=");
    warn(procs[i].as_user ? "1" : "0");
    /* The ctty is in the dump for the same reason the rest of the line is: a
     * shell that came up on the wrong VT, or with no controlling terminal at all,
     * looks from the outside like a blank screen and nothing else. */
    warn(" ctty=");
    warn(procs[i].ctty ? procs[i].ctty : "-");
    warn("\n");
  }

  /* Reap and restart. Anything that dies comes back, and the backoff after
   * every reap keeps a crash loop from spinning. */
  for (;;) {
    /* Act on a shutdown request before doing anything else. Checked at the top
     * of the loop because this is the only code that runs between a signal
     * arriving and the machine going away - and because the loop owns procs[],
     * so the shutdown path can stop the children from right here. */
    if (shutdown_mode)
      do_shutdown(shutdown_mode);

    pid_t xorg_pid = -1;
    for (size_t i = 0; i < nprocs; i++)
      if (strcmp(procs[i].name, "Xorg") == 0)
        xorg_pid = procs[i].pid;

    for (size_t i = 0; i < nprocs; i++) {
      if (procs[i].pid > 0)
        continue;
      if (procs[i].needs_x &&
          (xorg_pid <= 0 || access(X_SOCKET, F_OK) != 0))
        continue;
      /* Restart backoff, as a gate rather than a sleep. Sleeping here would
       * stall every OTHER supervised child too, so a service that cannot start
       * would delay the ones that can - the tail wagging the desktop. The gate
       * lets the loop keep making progress and simply skips this entry until it
       * is allowed to try again.
       *
       * The reason this exists at all: the loop previously retried a failed
       * child every 300ms flat, which is not a backoff but a spin. A child that
       * cannot start - a config error, a missing file - produced hundreds of
       * identical notices in a minute, and the single line explaining WHY was
       * the first thing pushed off the end of the log. */
      if (procs[i].retry_at_ms && monotonic_ms() < procs[i].retry_at_ms)
        continue;
      pid_t p = fork();
      if (p < 0) {
        warn("init: fork failed for ");
        warn(procs[i].name);
        warn("\n");
        msleep(500);
        procs[i].pid = -1;
        continue;
      }
if (p == 0) {
          /* Claim a controlling terminal, when this child wants one.
           *
           * Only the extra login shells on tty3-tty6 set ctty; everything else
           * leaves it NULL and is unaffected.
           *
           * THE ORDER IS LOAD-BEARING, and it is the reverse of what reads
           * naturally. fork() leaves the child in init's process group, so it is
           * NOT a process-group leader and setsid() succeeds - calling it in the
           * other order relative to the session is what would fail. After
           * setsid() the child is a session leader with no controlling terminal,
           * and that is precisely the state TIOCSCTTY requires: claiming one is
           * only permitted for a session leader without a terminal. Doing it in
           * this order also needs no privilege, so nothing here depends on
           * whether this child drops to uid 1000.
           *
           * dup2 has to come last because until 0/1/2 are the VT, warn() from
           * this child would write to init's console rather than the shell the
           * user is looking at. */
          if (procs[i].ctty) {
            int ctty_fd = open(procs[i].ctty, O_RDWR);
            if (ctty_fd < 0) {
              warn("init: ");
              warn(procs[i].ctty);
              warn(": cannot open for the ");
              warn(procs[i].name);
              warn(" shell - that VT will be blank\n");
            } else if (setsid() < 0) {
              warn("init: setsid failed for ");
              warn(procs[i].name);
              warn(" - ");
              warn(procs[i].ctty);
              warn(" will be blank\n");
              close(ctty_fd);
            } else if (ioctl(ctty_fd, TIOCSCTTY, 0) != 0) {
              warn("init: TIOCSCTTY failed for ");
              warn(procs[i].name);
              warn(" - ");
              warn(procs[i].ctty);
              warn(" will be blank\n");
              close(ctty_fd);
            } else {
              /* dup2 duplicates the description, so closing ctty_fd afterwards
               * leaves 0/1/2 holding the VT. The != guards matter because
               * dup2(n, n) is a no-op that would otherwise close the fd we are
               * about to use. */
              if (ctty_fd != STDIN_FILENO)
                dup2(ctty_fd, STDIN_FILENO);
              if (ctty_fd != STDOUT_FILENO)
                dup2(ctty_fd, STDOUT_FILENO);
              if (ctty_fd != STDERR_FILENO)
                dup2(ctty_fd, STDERR_FILENO);
              if (ctty_fd > STDERR_FILENO)
                close(ctty_fd);
            }
          }
          if (procs[i].as_user)
            drop_to_user();
          /* Give daemons a log file of their own before exec, so their own
           * diagnostic survives.
           *
           * Xorg needs none of this because it takes -logfile and init passes
           * one. The daemons do not: iwd writes its reasons to stderr and
           * nowhere else, and stderr is inherited from init, which is the console
           * that X subsequently covers. So the single most useful line a daemon
           * can print - why it just exited - was being written to a screen nobody
           * was looking at, under a run of restart notices that pushed it off.
           *
           * Only the two that log in prose need this; the rest keep stderr and
           * stay no noisier than before. Not made a struct field on purpose: it
           * would mean editing every positional initialiser again, which is
           * exactly the class of change that caused the argv bug.
           */
          {
            const char *logpath = NULL;
            if (strcmp(procs[i].name, "iwd") == 0)
              logpath = LOG_DIR "/iwd.log";
            else if (strcmp(procs[i].name, "bluetoothd") == 0)
              logpath = LOG_DIR "/bluetoothd.log";
            if (logpath) {
              int lf = open(logpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
              if (lf >= 0) {
                dup2(lf, STDERR_FILENO);
                dup2(lf, STDOUT_FILENO);
                if (lf != STDERR_FILENO && lf != STDOUT_FILENO)
                  close(lf);
              }
              /* If it could not be opened, carry on with stderr. A missing log
               * file must not be the reason a daemon fails to start. */
            }
          }
          execve(procs[i].path, procs[i].argv, procs[i].envp);
          warn("init: exec ");
          warn(procs[i].name);
          warn(" failed\n");
          _exit(1);
        }
        procs[i].pid = p;
      }

      /* Written once, at supervise() entry, so that "procs.log is empty" is a
       * result rather than an absence of evidence. Every death below appends to
       * this file, so a file that does not exist means the logging never ran -
       * which is indistinguishable from "nothing died" unless something says
       * the file works. This line is that something. */
      {
        int lfd = open(LOG_DIR "/procs.log",
                       O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (lfd >= 0) {
          char line[256];
          int n = snprintf(line, sizeof line,
                           "%ld supervise start, %d children\n",
                           (long)time(NULL), (int)nprocs);
          if (n > 0) {
            ssize_t w = write(lfd, line, (size_t)n);
            (void)w;
          }
          close(lfd);
        } else {
          warn("init: cannot open ");
          warn(LOG_DIR "/procs.log");
          warn(" - child deaths will not be recorded\n");
        }
      }

    int status;
    pid_t died = waitpid(-1, &status, 0);
    if (died < 0) {
      if (errno == EINTR)
        continue;
      warn("init: waitpid failed\n");
      msleep(1000);
      continue;
    }

    /* The network child exiting is the only moment at which "DHCP is over and
     * there is no address" becomes a fact rather than a maybe, so this is where
     * that gets said. Without it the user sees a working desktop, no sshd, and
     * no indication that the two are related. The NET_READY test is what makes
     * this correct in both directions: net_up() creates the file before it
     * exits on the success path, so a child that exits with the file present
     * succeeded and needs no comment. */
    if (died == net_setup_pid && !net_reported) {
      net_reported = 1;
      net_setup_pid = -1;
      if (access(NET_READY, F_OK) != 0)
        warn("init: ssh: still no address - sshd is up, but reachable on "
             "127.0.0.1 only\n");
    }

    for (size_t i = 0; i < nprocs; i++) {
      if (procs[i].pid == died) {
        warn("init: ");
        warn(procs[i].name);
        /* path AND argv, deliberately redundant. A log line that names one
         * program while printing another's argv is impossible to diagnose from
         * source, because the source is correct - so the log has to carry enough
         * to show the table itself is wrong. Printing all three (name, path,
         * argv) makes an aliasing entry visible in the one line that reports it
         * instead of requiring a rebuild with extra instrumentation. */
        warn(" (");
        /* A daemon that logs to a file of its own has, by definition, just told
         * us why it died - in a file nothing is going to read. Echo its last few
         * lines here, at the moment of death, where they cannot be scrolled away.
         *
         * This is what makes "iwd exited [exit 1]" actionable rather than merely
         * true. The exit status says nothing; iwd's own message names the reason,
         * and the whole point of capturing it was so the reason could be seen
         * without going and reading a separate file.
         */
        if (strcmp(procs[i].name, "iwd") == 0 ||
            strcmp(procs[i].name, "bluetoothd") == 0) {
          char lp[64];
          snprintf(lp, sizeof lp, LOG_DIR "/%s.log", procs[i].name);
          int lf = open(lp, O_RDONLY);
          if (lf >= 0) {
            /* Seek to the END first. A daemon that has been failing for a minute
             * has already printed its reason many times, and reading the start
             * of the file would report what it said the FIRST time, which is
             * exactly the line that has already scrolled away everywhere else.
             * What matters is what it said the last time. */
            off_t end = lseek(lf, 0, SEEK_END);
            char buf[512];
            ssize_t n = 0;
            if (end > 0) {
              off_t from = end - (off_t)(sizeof buf - 1);
              if (from < 0)
                from = 0;
              if (lseek(lf, from, SEEK_SET) == from)
                n = read(lf, buf, sizeof buf - 1);
            }
            close(lf);
            if (n > 0) {
              buf[n] = '\0';
              /* Last complete line only - a partial one is a line still being
               * written when we read it, and would be misleading. */
              char *last = buf;
              for (char *q = buf; *q; q++)
                if (*q == '\n' && q[1] != '\0')
                  last = q + 1;
              /* Trim the trailing newline BEFORE printing: warn() does not add
               * one, and the caller's warn("\n") terminates the whole line. */
              size_t ll = strlen(last);
              while (ll > 0 && (last[ll - 1] == '\n' || last[ll - 1] == '\r'))
                last[--ll] = '\0';
              if (ll > 0) {
                warn("last line: ");
                warn(last);
}
      }
    }

        }
        warn(procs[i].path);
        warn(") exited, restarting as:");
        for (char *const *a = procs[i].argv; *a != NULL; a++) {
          warn(" ");
          warn(*a);
        }
        /* How it died matters. "exited, restarting" with a bare status is
         * useless when the program logs nothing at all on the way out - which
         * is the case for sshd failing before log_init(). A child that
         * segfaults and one that exits 1 on a config error look identical
         * without this. */
        {
          char wb[64];
          if (WIFSIGNALED(status))
            snprintf(wb, sizeof wb, " [signal %d]", WTERMSIG(status));
          else if (WIFEXITED(status))
            snprintf(wb, sizeof wb, " [exit %d]", WEXITSTATUS(status));
          else
            wb[0] = '\0';
          warn(wb);
        }
        warn("\n");
        /* The same report, in a file.
         *
         * The console line above is the ONLY record of how a child died, and the
         * console is where you are not looking when a desktop session drops you
         * to a text terminal - you are looking at the dead session. Getting the
         * reason then means rebooting and holding F1 through the whole wait to
         * reproduce it.
         *
         * One appended line per death makes "who died, how, and how often"
         * answerable after the fact, and the COUNT is the useful part: a single
         * exit is a config error, a tight loop is a crash or a resource limit,
         * and the console looks identical for both if you catch only the last
         * line before it scrolls away. */
        {
          int lfd = open(LOG_DIR "/procs.log",
                         O_WRONLY | O_CREAT | O_APPEND, 0644);
          if (lfd >= 0) {
            char line[512];
            int n = snprintf(line, sizeof line, "%ld %s",
                             (long)time(NULL), procs[i].name);
            if (n > 0 && (size_t)n < sizeof line) {
              if (WIFSIGNALED(status))
                n += snprintf(line + n, sizeof line - n, " signal %d",
                              WTERMSIG(status));
              else if (WIFEXITED(status))
                n += snprintf(line + n, sizeof line - n, " exit %d",
                              WEXITSTATUS(status));
              if (n > 0 && (size_t)n < sizeof line)
                n += snprintf(line + n, sizeof line - n, "\n");
              if (n > 0) {
                ssize_t w = write(lfd, line, (size_t)n);
                (void)w;
              }
            }
            close(lfd);
          }
        }
        procs[i].pid = -1;
        /* Escalate: 2s, 4s, 8s, then 16s for good. A service that is genuinely
         * broken should be quiet about it, while the transient failures that do
         * recover - a NIC that has not finished negotiating, a display that is
         * still coming up - still get retried promptly. */
        procs[i].restarts++;
        {
          unsigned long delay = 1000UL << (procs[i].restarts > 4 ? 4
                                                  : procs[i].restarts);
          procs[i].retry_at_ms = monotonic_ms() + delay;
        }
      }
    }
    msleep(300);
  }
  return 0;
}
