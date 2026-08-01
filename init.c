#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>

static void warn(const char *msg) { write(2, msg, strlen(msg)); }

int main(void) {
  mkdir("/newroot", 0755);
  if (mount("/dev/vda1", "/newroot", "ext4", 0, NULL) < 0) {
    warn("init: failed to mount root disk\n");
  } else {
    if (chdir("/newroot") < 0)
      warn("init: chdir failed\n");
    if (mount(".", "/", NULL, MS_MOVE, NULL) < 0)
      warn("init: move mount failed\n");
    if (chroot(".") < 0)
      warn("init: chroot failed\n");
    chdir("/");
  }

  mount("proc", "/proc", "proc", 0, NULL);
  mount("sysfs", "/sys", "sysfs", 0, NULL);
  mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
  mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));

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

  execve("/bin/rlsh", (char *[]){"/bin/rlsh", "-i", NULL}, NULL);
  warn("init: execve failed\n");

  for (;;) {
    if (wait(NULL) < 0 && errno == ECHILD)
      pause();
  }
}
