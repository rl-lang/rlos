/* klogd - colorizing kernel log daemon.
 *
 * The kernel prints no colors on console, so: boot with loglevel=3 (only
 * emerg/alert/crit reach the console plain - almost nothing on a healthy
 * boot) and let this daemon dump + stream everything else from /dev/kmsg
 * with per-priority colors. No duplicates: priorities 0-2 are skipped
 * here because the console already showed them.
 *
 * Colors (dmesg-style): 0-2 bright red (skipped, see above), 3 red,
 * 4 yellow, 5-7 default. Runs forever; init restarts it if it dies. */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *color_for(int pri) {
  switch (pri) {
  case 3:
    return "\x1b[31m"; /* err: red */
  case 4:
    return "\x1b[33m"; /* warning: yellow */
  default:
    return "";
  }
}

/*
 * LOG_FILE is the same message stream as the console, minus the colors, so it
 * can be read with cat/nano once the desktop has taken the screen. Console
 * output is unusable as a record: Xorg puts the physical display on its own
 * VT, so anything printed after X starts is scrolling on a console nobody is
 * looking at, and on a laptop there is no serial port to fall back to.
 *
 * Opened O_APPEND so restarts append rather than truncate - init respawns this
 * daemon, and losing the log of the run that just failed would defeat the
 * point. Never fatal: a failure to open or write the log must not take down the
 * console output, which is the only diagnostic visible during early boot.
 */
#define LOG_FILE "/log/kmsg"

static int logfd = -1;

static void log_open(void) {
  logfd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
  /* No message if this fails: the failure is announced by the absence of the
   * log, and init creates /log. Not worth a console line of its own. */
}

static void log_write(const char *text, size_t len) {
  size_t off = 0;
  if (logfd < 0)
    return;
  while (off < len) {
    ssize_t w = write(logfd, text + off, len - off);
    if (w <= 0) {
      if (w < 0 && errno == EINTR)
        continue;
      close(logfd);
      logfd = -1; /* stop trying; a full or vanished log is not fatal */
      return;
    }
    off += (size_t)w;
  }
}

int main(void) {
  int fd;

  /*
   * Open the log before /dev/kmsg, not after. devtmpfs creates /dev/kmsg when
   * the kernel registers it, and init's first spawn of this daemon can beat
   * that: the open fails, the function returns 1, and because the log was
   * never opened there is no /log/kmsg at all - which reads as "logging is
   * broken" rather than "the daemon started too early and will be restarted".
   * init does respawn it, but only after the retry delay, so most of the
   * session had no log for no good reason.
   */
  log_open();
  if (logfd < 0) {
    /* The log is the one thing this daemon exists to feed. If it cannot be
     * opened, say so on the console loudly: the alternative is a silent
     * absence that looks identical to "the kernel logged nothing". */
    const char *m = "klogd: cannot open " LOG_FILE "\n";
    write(STDOUT_FILENO, m, strlen(m));
  }

  /*
   * /proc/kmsg, not /dev/kmsg.
   *
   * This is the difference between a log with content and an empty file, and
   * it was the reason /log/kmsg never appeared. /dev/kmsg is a *stream*: it
   * only yields messages logged after the open, and by the time init gets
   * round to spawning this daemon the kernel has finished booting and gone
   * quiet, so there was nothing left to stream - the daemon ran perfectly and
   * wrote nothing. /proc/kmsg is the same data presented as a snapshot of the
   * whole ring buffer, so everything from the earliest boot message is there.
   *
   * Reading it costs nothing extra: opening it consumes the backlog and marks
   * it read, so no duplicates appear when the stream continues.
   */
  fd = open("/proc/kmsg", O_RDONLY);
  if (fd < 0) {
    char msg[128];
    int n = snprintf(msg, sizeof(msg), "klogd: cannot open /proc/kmsg: %s\n",
                     strerror(errno));
    if (n > 0) {
      size_t w = (size_t)n < sizeof(msg) ? (size_t)n : sizeof(msg) - 1;
      log_write(msg, w);
      write(STDOUT_FILENO, msg, w);
    }
    return 1;
  }

  char buf[4096];
  size_t len = 0;
  for (;;) {
    ssize_t n = read(fd, buf + len, sizeof(buf) - 1 - len);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return 1;
    }
    if (n == 0)
      return 1;
    len += (size_t)n;
    buf[len] = '\0';

    /* Emit complete lines, keep the tail fragment buffered. */
    char *line = buf;
    for (;;) {
      char *nl = strchr(line, '\n');
      if (nl == NULL)
        break;
      *nl = '\0';
      /* Record: "PRI,SEQ,TS[,FLAGS];MESSAGE" */
      int pri = 6;
      unsigned long long ts = 0;
      char *semi = strchr(line, ';');
      if (semi != NULL) {
        *semi = '\0';
        char *c1 = strchr(line, ',');
        if (c1 != NULL) {
          pri = atoi(line);
          char *c2 = strchr(c1 + 1, ',');
          if (c2 != NULL)
            ts = strtoull(c2 + 1, NULL, 10);
        }
        if (pri < 0 || pri > 7)
          pri = 6;
        if (pri >= 3) {
          const char *color = color_for(pri);
          const char *reset = color[0] != '\0' ? "\x1b[0m" : "";

          /* Log first and uncolored: a record with terminal escapes in it is
           * painful to read and useless to grep. */
          char plain[4352];
          int p = snprintf(plain, sizeof(plain), "[%5llu.%06llu] %s\n",
                           ts / 1000000ULL, ts % 1000000ULL, semi + 1);
          if (p > 0)
            log_write(plain, (size_t)p < sizeof(plain) ? (size_t)p
                                                       : sizeof(plain) - 1);

          /* Then the console, which is where the colors are worth having. */
          char out[4352];
          int m = snprintf(out, sizeof(out), "\x1b[2m[%5llu.%06llu]\x1b[0m %s%s%s\n",
                           ts / 1000000ULL, ts % 1000000ULL, color, semi + 1, reset);
          if (m > 0) {
            size_t wlen = (size_t)m < sizeof(out) ? (size_t)m : sizeof(out) - 1;
            if (write(STDOUT_FILENO, out, wlen) < 0)
              return 1;
          }
        }
      }
      line = nl + 1;
    }
    len -= (size_t)(line - buf);
    memmove(buf, line, len);
    if (len == sizeof(buf) - 1) /* pathological: drop an overlong line */
      len = 0;
  }
  return 0;
}
