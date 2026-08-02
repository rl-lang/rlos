#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>

static void warn(const char *msg) { write(2, msg, strlen(msg)); }

static void warnf(const char *prefix, const char *path) {
  char buf[256];
  int n = snprintf(buf, sizeof(buf), "init: %s %s failed: %s (errno=%d)\n",
                   prefix, path, strerror(errno), errno);
  if (n > 0)
    write(2, buf, (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1);
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

static int xchmod(const char *path, mode_t mode) {
  if (chmod(path, mode) == 0)
    return 0;
  warnf("chmod", path);
  return -1;
}

int main(void) {
  mount("proc", "/proc", "proc", 0, NULL);
  mount("sysfs", "/sys", "sysfs", 0, NULL);
  mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
  mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));

  /* devtmpfs gives us /dev/ptmx, but without devpts mounted at
   * /dev/pts, opening a pty master never gets a matching slave node -
   * any terminal (foot, etc.) trying to open a PTY fails with ENOENT. */
  xmkdir("/dev/pts", 0755);
  if (mount("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666") != 0)
    warnf("mount", "/dev/pts (devpts)");

  int fd = open("/dev/console", O_RDWR);
  if (fd < 0) {
    warn("init: no console\n");
  } else {
    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2)
      close(fd);
  }

  setsid();
  ioctl(0, TIOCSCTTY, 1);

  /* cage/wlroots require XDG_RUNTIME_DIR to exist with 0700 perms.
   * seatd also needs /run to exist so it can bind /run/seatd.sock.
   * If root is mounted read-only these will fail with EROFS; catch
   * that here instead of limping into a seatd bind failure later. */
  int run_ok = xmkdir("/run", 0755) == 0;
  run_ok &= xmkdir("/run/user", 0755) == 0;
  run_ok &= xmkdir("/run/user/0", 0700) == 0;
  run_ok &= xchmod("/run/user/0", 0700) == 0;

  /* seatd-launch needs /tmp to create its private socket dir */
  int tmp_ok = xmkdir("/tmp", 01777) == 0;
  tmp_ok &= xchmod("/tmp", 01777) == 0;

  if (!run_ok || !tmp_ok)
    warn("init: /run or /tmp setup failed - is root mounted read-only? "
         "(check for 'rw' on the kernel command line)\n");

  pid_t pid = fork();
  if (pid == 0) {
    char *envp[] = {
        "HOME=/root",
        "PATH=/bin:/usr/bin:/sbin:/usr/sbin",
        "XDG_RUNTIME_DIR=/run/user/0",
        "TERM=linux",
        /* foot refuses to honor the command it was given ("/bin/rlsh")
         * and silently substitutes a hardcoded "/bin/sh -c ''" fallback
         * whenever it can't resolve a UTF-8 locale (see foot's
         * main.c bad_locale path). With no locale data in this rootfs
         * and no LANG/LC_ALL set, that always triggered - and since
         * this rootfs has no /bin/sh either, the fallback itself then
         * failed to exec, taking the whole boot down with it. Setting
         * a UTF-8 locale here keeps foot on the real command. */
        "LANG=C.UTF-8",
        "LC_ALL=C.UTF-8",
        /* No udevd runs in this initramfs, so /dev/input/eventN nodes
         * exist (created directly by devtmpfs) but were never tagged
         * in a udev database for libinput's enumeration to find. That
         * makes libinput's backend init fail outright with zero
         * devices found. Tell wlroots not to treat that as fatal so
         * boot completes; keyboard/mouse won't work until a real
         * udev daemon + coldplug trigger is added. */
        "WLR_LIBINPUT_NO_DEVICES=1",
        NULL,
    };
    execve("/usr/bin/seatd-launch",
           (char *[]){"/usr/bin/seatd-launch", "--", "/usr/bin/cage", "--",
                      "/usr/bin/foot", "/bin/rlsh", NULL},
           envp);
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "init: seatd-launch execve failed: %s (errno=%d)\n",
                     strerror(errno), errno);
    write(2, buf, n);
    _exit(1);
  }

  for (;;) {
    int status;
    pid_t died = wait(&status);
    if (died < 0 && errno == ECHILD) {
      warn("init: all children exited, halting\n");
      pause();
    }
  }
}
