# Running atom with bubblewrap

`atom` is a complete little Linux filesystem — busybox, `gcc` + binutils, git, ssh, sqlite,
curl — that runs inside bubblewrap as an isolated service. This guide is how you
unpack it and start something in it.

There is no `atom-run` wrapper. That is deliberate: a wrapper would hide the
namespace and mount setup, and that setup *is* the security boundary. You write
the `bwrap` command, so you can see exactly what is isolated and what is not.

Two reference documents ship alongside this one, both upstream and both pinned to
the version we ship:

- `/usr/share/doc/bwrap/bwrap.1` — the official man page. `man bwrap` if you have
  `man`; otherwise read the file.
- `/usr/share/doc/bwrap/README.md` — upstream's own explanation of what the
  namespaces do.

---

## 1. Unpack the image

The image is a single file at the root of the filesystem:

```
/atom-rootfs.tar.gz
```

Unpack it somewhere. Once.

```sh
mkdir -p ~/atom
tar -xzpf /atom-rootfs.tar.gz -C ~/atom
```

### The `-p` is not optional

`-p` means "preserve permissions". Without it, `tar` restores every directory as
`0755`, and `~/atom/tmp` comes out `0755` instead of `1777` — a `/tmp` that no
unprivileged process can write. You will not get an error; you will get a
confusing failure from whatever program you tried to run. `tar -xzpf`, every
time.

### Where to unpack it

Anywhere is fine. `$HOME` is the obvious choice. Unpacking costs about 95M.

If you want it in RAM instead, see the note at the end — as shipped there is no
pre-mounted tmpfs you can write to.

### Unpack once, run many

This is the part worth understanding, because it is why one 41M file can back
any number of containers.

`bwrap --ro-bind` does not copy anything. It points the container's mount
namespace at the same directory you already have. So if you start five
containers off one unpacked `~/atom`, they all read the same pages off the same
directory — five containers, one copy on disk. The tenth costs you nothing.

---

## 2. Start something in it

```sh
bwrap \
  --ro-bind ~/atom      / \
  --proc /proc --dev /dev --tmpfs /tmp \
  --unshare-user --unshare-pid --unshare-uts --unshare-ipc \
  --die-with-parent \
  --chdir / \
  --setenv HOME /root --setenv USER root \
  -- \
  /bin/sh
```

Read it line by line:

| Flag | What it does |
|---|---|
| `--ro-bind ~/atom /` | The container's `/` is your unpacked atom, **read-only**. |
| `--proc /proc` | Fresh `/proc` for this namespace. Processes inside see only themselves. |
| `--dev /dev` | Minimal `/dev` — null, zero, random, urandom. Not the host's devices. |
| `--tmpfs /tmp` | Empty writable `/tmp`, discarded when the container exits. |
| `--unshare-user` | Container root is your uid, not 0. This is what makes it safe to run as a normal user. |
| `--unshare-pid` | Its own PID namespace. It cannot see or signal host processes. |
| `--unshare-uts` | Its own hostname. Set it with `--hostname`. |
| `--unshare-ipc` | Its own SysV IPC / POSIX message queues. |
| `--die-with-parent` | If your shell exits, the container is torn down. No orphans. |
| `--setenv HOME /root` | Programs need a sane `$HOME` or they misbehave. |
| `--` | Everything after this is the program. Its flags stay its own. |

Note what is **not** here: `--unshare-net`. That is deliberate — see the next
section.

---

## 3. Networking, ssh, and ports

Because this command does not pass `--unshare-net`, the container **shares the
host's network**. Everything it does to the network, you do to the host's.

That has one useful consequence and one sharp edge.

**Useful:** a server inside the container binds a port that is *also* a port on
the host, because to the network stack they are the same thing. You do not need
port forwarding, and there is none available — `bwrap` cannot forward ports, and
this kernel has no `VETH`.

**Sharp edge:** two containers cannot both listen on the same port. Containers
share the host network, so a container's port *is* a host port. Pick one port per
container.

The convention the shipped scripts use is **2250 and up**, and `atom-ssh.sh`
enforces it for you: with no `ATOM_PORT` set it takes the first free port from
2250 through 2299 and prints the one it actually bound. Run it as many times as
you like and each instance reports its own port. Setting `ATOM_PORT` pins a
specific port and is honoured exactly — useful when you want a stable port for a
`known_hosts` entry or an ssh config `Host` block.

Every other manual example below just uses 2242 to keep the commands short and
readable. That is a literal port in a literal command, not a default you inherit.

### ssh into a container

```sh
bwrap ... -- /usr/sbin/sshd -D -e -p 2242
```

Then, from any machine on the network:

```sh
ssh -p 2242 user@<host>
```

Prefer `127.0.0.1` over `<host>`: it needs no name resolution, and the machine's
own hostname may not be resolvable from the machine you are typing on.

### Move files in, and run them

`sshd` inside the container serves the normal subsystems, so `scp` and `sftp`
work as usual:

```sh
scp -P 2242 server.c user@<host>:~/atom/data/
```

### Run a server

busybox ships `httpd` and `nc`, so you do not need to install anything:

```sh
bwrap ... -- /bin/httpd -f -p 8080 -h /var/lib/atom/www
```

Then from the host: `curl http://localhost:8080/`.

To compile something instead, `gcc` is in the image (as `cc`):

```sh
bwrap ... -- /bin/sh -c 'cc -o /var/lib/atom/srv /var/lib/atom/server.c && /var/lib/atom/srv'
```

---

## 4. The one thing that will confuse you

**The container's filesystem is read-only.** `/` is `--ro-bind`.

So this fails:

```sh
scp -P 2242 server.c user@<host>:/tmp/     # works, but /tmp is --tmpfs: gone on exit
scp -P 2242 server.c user@<host>:~/        # fails: read-only filesystem
```

The **only** persistent writable place is `/var/lib/atom`, and you have to give
it one. Add a bind for it:

```sh
mkdir -p ~/atom-data
# ...and add this line to the bwrap command above:
  --bind ~/atom-data /var/lib/atom \
```

Then everything persistent goes in `/var/lib/atom`, and it survives the
container exiting. This is not a limitation to work around — it is the point. A
service cannot rewrite its own `git`, so a compromised container cannot become a
persistent foothold by editing the thing that gets re-run.

For per-container state, bind a different host directory per container. Two
containers on different ports should also have different data directories:

```sh
--bind ~/atom-data-web /var/lib/atom   # container on 2242
--bind ~/atom-data-git /var/lib/atom   # container on 2243
```

---

## 5. Many containers at once

Because `--ro-bind` shares rather than copies, this is the whole trick:

```sh
# container "web" on port 2242
bwrap --ro-bind ~/atom / --bind ~/data-web /var/lib/atom \
      --proc /proc --dev /dev --tmpfs /tmp \
      --unshare-user --unshare-pid --unshare-uts --unshare-ipc \
      --die-with-parent --chdir / -- \
      /usr/sbin/sshd -D -e -p 2242 &

# container "git" on port 2243, same rootfs, different state
bwrap --ro-bind ~/atom / --bind ~/data-git /var/lib/atom \
      --proc /proc --dev /dev --tmpfs /tmp \
      --unshare-user --unshare-pid --unshare-uts --unshare-ipc \
      --die-with-parent --chdir / -- \
      /usr/sbin/sshd -D -e -p 2243 &
```

Both read `~/atom`. Neither can see the other's `/var/lib/atom`. Neither can see
host processes. Killing one leaves the other running.

---

## 6. Nested containers

`atom` has its own `bwrap` and libcap, so a container can start another
container: unpack the image inside the container and re-run the same command.

```sh
bwrap --ro-bind ~/atom / ... -- /bin/bwrap --ro-bind /atom / ... -- /bin/sh
```

This works because rlOS is built with `CONFIG_USER_NS=y`, and user namespaces
nest.

---

## What this does not do

Worth knowing before you rely on it:

- **No cgroup limits.** `bwrap` has no resource control. A container can use all
  the RAM and all the CPU. This is the main thing you give up by not using
  podman.
- **No network isolation between containers.** They share the host's network.
  Distinct ports are all that separate them.
- **No filesystem isolation from `/var/lib/atom`.** That bind is writable by
  design; keep it the only writable path.
- **No seccomp filter.** Upstream recommends one in some cases (see the README's
  Limitations section); we ship none.

For "run an untrusted program where it cannot hurt the desktop", `bwrap` plus a
read-only root is a real boundary. It is not a substitute for podman's cgroups,
network namespace, or seccomp defaults.

---

## Reference

```sh
bwrap --help          # every flag, one line each
man bwrap             # the real manual page, if man is installed
```

Files:

| Path | What |
|---|---|
| `/atom-rootfs.tar.gz` | The single-file image |
| `~/atom` | Where you unpacked it |
| `/usr/share/doc/bwrap/bwrap.1` | Official man page |
| `/usr/share/doc/bwrap/README.md` | Upstream README |