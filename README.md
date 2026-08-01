# rlos

An experimental minimal Linux boot chain - a step toward [rl-lang](https://github.com/rl-lang)'s
long-arc goal of building an OS userspace in rl-lang.

Currently: custom-built kernel + a minimal initramfs booting into a shell.
Init is C for now; userspace binaries include `rl` running inside the
environment. rl-lang's own coreutils/shell (`rlsh`, `core-utils`)
are the intended long-term replacement for busybox.

## Status

- [x] Kernel builds and boots in QEMU
- [x] Minimal initramfs (mount proc/sys/dev, console setup, exec into a shell)
- [x] busybox as interim shell
- [x] `rl` binary runs inside the environment
- [ ] rl-lang shell (`rlsh`) as PID 1's shell, replacing busybox
- [ ] Init rewritten in rl-lang

## Build order

### 1. Kernel

Clone and build the kernel, using the config in this repo:

```bash
./compile_kernel.sh
```

### 2. Init

```bash
./compile_init.sh
```

Compiles `init.c`.

### 3. Rootfs

```bash
./build_rootfs.sh
```

### 4. Pack initramfs

```bash
./compile_initramfs.sh
```

### 5. Boot

```bash
./run_qemu.sh
```

## License

MIT - see [LICENSE](LICENSE.md).
