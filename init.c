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

int main(void) {
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

  pid_t pid = fork();
  if (pid == 0) {
    execve("/usr/bin/cage",
           (char *[]){"/usr/bin/cage", "--", "/usr/bin/foot", "-e", "/bin/rlsh",
                      NULL},
           NULL);
    char buf[256];
    int n =
        snprintf(buf, sizeof(buf), "init: cage execve failed: %s (errno=%d)\n",
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
