# rlos

An experimental text-only Linux OS - a step toward [rl-lang](https://github.com/rl-lang)'s
long-arc goal of building an OS userspace in rl-lang.

A custom-stripped kernel boots into a RAM root filesystem whose entire userspace -
shell, coreutils, and editor - is written in rl-lang and packaged by the `rl` compiler
driver. A C `init` (PID 1) sets up the console and supervises; a `klogd` daemon reads
the kernel ring buffer and paints it, Gentoo-OpenRC style.

Three boot paths share one rootfs tree, so they can never drift apart:

| Path | What it is | Media |
|---|---|---|
| **initramfs** | RAM sandbox, fastest loop | `bzImage` + `initramfs.gz` |
| **live ISO** | hybrid BIOS+UEFI, `dd`-able to USB | `rlos.iso` (97M) |
| **disk** | persistent, GRUB + ext4 | `disk.img` (1G) |

## Status

- [x] Stripped kernel builds and boots in QEMU (~11.9M `bzImage`)
- [x] C `init` (PID 1): mounts `proc`/`sys`/`dev`/`devpts`, console winsize probe via
      CPR, `setsid`+`TIOCSCTTY`, `exec`s `rlsh` with respawn + child reaper
- [x] `klogd`: reads `/dev/kmsg`, skips pri 0-2, dim timestamps, yellow warnings, red errors
- [x] rl-lang shell `rlsh` as the interactive shell (with RL syntax highlighting)
- [x] rl-lang coreutils: `ls`, `wc`, `whoami`, `hostname`, `rm`
- [x] rl-lang editor: `nano` (multi-module: draw, syntax highlight, theme)
- [x] rl-lang toolchain in-guest: `rl` `rlc` `rlt` `rldocs` `rlrepl` `rlsp`, plus `rlt` ->
      C11 -> vendored **gcc 16.2.0** (C-only, LTO) via `cc`, so `rlt --compile` and
      `rlt --compile --lto` work inside the VM
- [x] **git 2.55.0** vendored into the guest (180 helpers)
- [x] RAM initramfs target boots to a colored prompt
- [x] Live ISO: hybrid BIOS+UEFI, both verified booting in QEMU (SeaBIOS + OVMF)
- [x] X11 desktop: Xorg (i915/modesetting or fbdev DDX), i3 4.25 + i3bar, mlterm,
      Bibata cursor theme, Xft fonts, `xf86-input-libinput` + `eudev` for input
- [ ] Tap-to-click / two-finger scroll (now unblocked: needs a `LIBINPUT_CONFIG_*` rule)
- [x] Disk image: GPT + GRUB (`bios_grub`) + ext4 root, boots via `root=PARTUUID=`
- [x] Real USB stick install: `rlos-disk/mkusb.sh` writes a persistent GPT stick
      (`bios_grub` + FAT32 ESP + ext4), booting on both BIOS and UEFI
- [x] `fastfetch` with the RLOS ASCII logo (`ff_logo.txt`, fastfetch `$1`..`$8` colour
      placeholders), configured system-wide at `etc/xdg/fastfetch/config.jsonc`
- [x] Persistent `/home/user` ownership: init chowns the whole tree recursively, not just
      the directory. The installed stick is built by a root-owned `cp -a`, so the one
      chown that used to be there left the first child root-owned and `mlterm` could not
      create `~/.mlterm`
- [x] `lsblk` in the guest: busybox has no `lsblk` applet, so `scripts/lsblk.sh` provides
      one over sysfs + mountinfo + udev, staged to `/usr/bin/lsblk`
- [x] Working C toolchain in-guest: vendored **binutils 2.46.1** supplies `as` + `ld`,
      which gcc needs and TinyCC did not. `libc.so`/`libm.so`/`libgcc_s.so` symlinks are
      staged so a link resolves; they point at the *shared* libc deliberately, since static
      `libc.a` drags in `__gcc_personality_v0` and the `_Unwind_*` set from libgcc which
      `rlt` never passes `-lgcc_s` for
- [x] Real X11 authentication: `xauth` staged, init generates an MIT-MAGIC-COOKIE-1,
      Xorg gets `-auth`, clients get `XAUTHORITY`. Xorg's `-ac` is gone
- [x] Kernel re-enabled for real hardware: USB (XHCI/EHCI/OHCI/UHCI/storage/HID),
      NICs (e1000e/igb/r8169), `OVERLAY_FS`, `ISO9660_FS`, `SQUASHFS`
- [ ] Init rewritten in rl-lang
- [ ] Persistent *live* session (overlayfs upper on a USB partition) - distinct from the
      real install above, which does not need overlayfs
- [ ] Real-stick `dd` validation on physical hardware (boots; input not yet confirmed)
- [ ] Networking in-guest (drivers present, no DHCP client yet)

## Requirements

Host: Gentoo (or any Linux) with `qemu-system-x86_64`, `gcc`, `make`, `grub-mkrescue`,
`curl`, and `zlib`/`readline` headers. `sys-fs/mtools` is needed only for the UEFI half of
the ISO. No KVM access is required - the runners fall back to `-accel tcg` and say so.

> Note: Gentoo ships **no** `xorriso` ebuild (verified against upstream master 2026-09),
> so `build_xorriso.sh` vendors it. This is the one place where a distro package can't be
> assumed, and the repo handles it rather than making you.

## Build

The order matters: each step consumes the previous one's output.

### 1. Kernel

```bash
./compile_kernel.sh
```

Clones `linux` (shallow, torvalds/master) if absent, resolves `kernel.config` via
`olddefconfig`, builds, and copies out `bzImage`. The config is deliberately minimal -
no DRM, no sound, no wireless, no USB *input* beyond HID - because every driver is
weight this text-only OS doesn't need. First build takes a while; later ones are fast.

### 2. rl-lang toolchain

```bash
./build_rl_bins.sh
```

Builds six `rl` binaries into `rl-bins/` using the **`no-media`** cargo feature, which
compiles out `std-audio`/`std-gui` (rodio, cpal, symphonia, eframe) and their bodies in
`rl-std`, `rl-vm`, `rl-cli`, `rl-repl`, and `rl-cc`. That keeps `rl` itself from dragging
in a windowing stack it never opens. The gating is module-aware: `native_module! media;`
means a `no-media` build drops the module's body but leaves every other `std` item alone,
so `rl-lang` defaults are unchanged and `vm-full` still gives you everything.

### 3. init + klogd

```bash
./rlos-initramfs/compile_init.sh
./rlos-initramfs/compile_klogd.sh
```

Two small static C binaries. `init` is PID 1; `klogd` is the `/dev/kmsg` reader that
colors the boot log.

### 4. Guest toolchains (vendored)

```bash
./build_binutils.sh  # binutils 2.46.1 -> binutils-dist/  (as + ld)
./build_gcc.sh       # gcc 16.2.0 (C-only + LTO) -> gcc-dist/ (compiler `cc`)
./build_git.sh       # git 2.55.0 -> git-dist/
```

All three are pinned and installed into local prefixes - no root, no host pollution.
Order matters: `build_binutils.sh` first, because gcc has no built-in assembler or
linker and cannot link anything without it. TinyCC had both, which is why the guest
never needed binutils before.

gcc is configured `--enable-languages=c --enable-lto`: no C++ front end, no
libstdcxx/libgomp/libquadmath. The reason for LTO is that `rl_runtime.c` is ~15.6k lines
of type-erased containers in one translation unit, so whole-program visibility across it
is worth real time and size - and `rlt --compile --lto` needs a genuine LTO implementation,
which tcc had none of. What is given up: tcc compiled ~70x faster at ~1/40th the size, and
`gcc-dist/` plus `binutils-dist/` add ~120MB to the image against tcc's 6.4MB.

`rlt` pins `-std=c11`, `-fno-strict-aliasing` and `-Wno-error=return-mismatch` on the
compile line. Measured: `rl_runtime.c` compiles clean under `gcc -std=c11 -pedantic-errors`
with zero diagnostics, and the one thing standing between it and C99 is `_Generic`, which
the `rl_ok` / `rl_box` / `rl_print` / `rl_println` / `rl_unwrap` dispatch macros depend on.
So C11 is the real floor, not C99.

`build_gcc.sh` collects the exact glibc header closure that `rl_runtime.c` includes rather
than guessing, plus the `ffi.h` / `yaml.h` / `argon2.h` closures behind the `RL_USE_*`
guards that the main probe cannot see. The probe uses the same flags as the real compile:
`-O2` matters, because glibc only defines `__USE_EXTERN_INLINES` when `__OPTIMIZE__` is
set, and only then does `stdio.h` pull in `bits/stdio.h`. The `assemble-rootfs.sh` step
symlinks `cc -> gcc`.

## Run

### initramfs (fastest loop)

```bash
./rlos-initramfs/build_initramfs.sh
./rlos-initramfs/run_qemu.sh
```

`initramfs.gz` (59M) is the whole system in RAM. Expect a colored boot log and a
`[root@system <user>]$` prompt in ~25s. Everything is lost on reboot - by design.

### Live ISO

```bash
./build_xorriso.sh        # once: vendored xorriso -> host-tools/
./rlos-iso/mkiso.sh
./rlos-iso/run_qemu.sh        # BIOS (SeaBIOS)
./rlos-iso/run_qemu_uefi.sh   # UEFI (OVMF)
```

`mkiso.sh` auto-prepends `host-tools/bin` to `PATH`, so no environment setup is needed.
The resulting `rlos.iso` is hybrid - it boots from optical media *and* from a raw
`dd` to a USB stick. Root still lives in RAM, so this is a stateless live session:
writable, but every change evaporates on reboot.

#### Writing to a USB stick

```bash
lsblk                                        # note existing devices FIRST
# plug the stick in, then:
lsblk -o NAME,SIZE,MODEL,TRAN                 # identify it - do not guess the letter
sudo dd if=rlos.iso of=/dev/sdX bs=4M oflag=sync status=progress
sync
```

Triple-check `/dev/sdX` before pressing enter. `dd` to the wrong device is instant and
total. UEFI machines need Secure Boot disabled (GRUB is unsigned).

This is still a *live* medium: whatever you write is lost on reboot. For something that
keeps its files, install rlOS onto the stick instead - see below.

### Installed USB stick (persistent, BIOS + UEFI)

The real answer to "I want to install this on the stick so my files survive a reboot".
`dd` writes a live medium that runs entirely out of RAM; this writes an actual filesystem,
so `/home/user` is still there after you power off.

```bash
cd rlos-disk
sudo ./mkusb.sh /dev/sdX                 # root partition = 16G (default)
sudo ./mkusb.sh /dev/sdX --size 32G      # or 8G / 512M / max for rest-of-stick
```

Unlike the `dd` route, this is not a hybrid image - it is a partitioned disk:

| partition | size | format | why |
|---|---|---|---|
| p1 | 1 MiB | none (`bios_grub`) | legacy BIOS cannot read GPT, so GRUB's core image needs a home |
| p2 | 512 MiB | FAT32 (ESP) | the only partition UEFI firmware is *allowed* to read |
| p3 | `--size` (default 16G) | ext4 (`rlos-root`) | the system |

The root partition defaults to 16G rather than filling the stick: an rlOS rootfs is
~144 MB, so 16G is generous, and a smaller p3 means `mkfs` and the rootfs copy touch
far less flash - which matters on the budget sticks that overstate their capacity and
fail partway through a large write. Whatever is left over stays unallocated, so you can
grow the partition later with `growpart` and `resize2fs`. Use `--size max` to fill the
stick from p3's start offset instead.

`bzImage` and a `grub.cfg` are written to both p2 and p3 - each bootloader reads the copy
on the partition it came from, so neither has to go hunting for the other filesystem. The
two configs are deliberately *not* the same file: the BIOS one uses
`terminal_output serial console` and the UEFI one adds `gfxterm`, because BIOS GRUB is in
the VGA text buffer while UEFI hands the kernel a framebuffer. Mixing those up is what
produces a blank screen after handover.

If the screen shows only a bare cursor after selecting an entry, boot
**`rlOS (text mode / nomodeset)`**. It forces legacy VGA text mode so `console=tty0`
has somewhere to write, which separates "the kernel ran but the video handover failed"
from "the kernel never reached root" - the latter prints VFS errors, the former prints
nothing. This is worth knowing about on real UEFI hardware: the kernel prefers
`DRM_I915` when it finds the GPU and falls back to `DRM_EFIDRM` otherwise, so the
framebuffer GRUB drew into is not always the one the console ends up on. The default
entry therefore does not request an `fbcon` font.

**`rootwait` is mandatory on the installed stick.** Every entry carries it, and it is
not a precaution. An installed stick has no initramfs, so the root filesystem is
mounted by the kernel's own early-boot path in `init/do_mounts.c`, which retries while
scanning for the root device - but `root_wait` is a zero-initialised `static int` that
is only ever set by the `rootwait` parameter itself. Without it the deadline is already
expired, that retry loop breaks after a single 5 ms sleep, and the kernel dies with:

```
VFS: unable to mount root fs on unknown-block(0,0)
```

USB enumeration takes much longer than 5 ms, so the kernel gives up before the disk
exists. LFS documents this identical failure and suggests `rootdelay` for it; `rootwait`
is the better tool because it retries until the device appears instead of guessing a
duration, and it can be bounded (`rootwait=30`). The live ISO does not need it because
its rootfs lives in the initramfs, so nothing has to be discovered at that stage - that
difference between having an initramfs and not is the entire explanation for why the ISO
booted while the stick panicked.

Guards, in order, before anything is written: refuses a non-block-device, refuses anything
with a mounted filesystem, refuses the disk the running system booted from, refuses
anything in `REFUSE_DISKS` (currently `/dev/sda`), and finally asks you to type the device
path back. The partitions are found via `/dev/disk/by-partlabel`, so `sdX1` vs `nvme0n1p1`
vs `mmcblk0p1` all work the same.

UEFI Secure Boot must be disabled (GRUB is unsigned), same as the ISO.

### Persistent disk (QEMU)

```bash
sudo ./rlos-disk/mkdisk.sh      # once: 1G GPT image
sudo ./rlos-disk/install.sh     # rootfs + bzImage + GRUB, root=PARTUUID=...
./rlos-disk/run_qemu.sh
```

Needs `sudo` for the loop mount. `install.sh` derives `root=PARTUUID=` from `blkid` at
install time, which is why the earlier `root=LABEL=` attempt panicked with
`VFS: Unable to mount root fs`. Changes to the root filesystem survive reboot, unlike
the other two targets. BIOS-only, and it targets an image file - use `mkusb.sh` for a
real stick that also boots under UEFI.

## Architecture notes

**One assembler, four targets.** `assemble-rootfs.sh <dir>` builds the userspace tree
once; `build_initramfs.sh` packs it with cpio+gzip, `rlos-disk/install.sh` copies it onto
ext4, `rlos-disk/mkusb.sh` copies it onto a real stick, and `rlos-iso/mkiso.sh` ships the
initramfs alongside the kernel. When you add a coreutil, you edit `rl_programs/` and the
packaging loop - all four targets pick it up.

**Scripts are staged by glob.** Anything in `scripts/*.sh` lands in the guest's `/usr/bin`
with the `.sh` suffix dropped, so `scripts/lsblk.sh` becomes `lsblk` and shadows nothing
(busybox genuinely has no `lsblk`). Adding a second script needs no edit to
`assemble-rootfs.sh`.

**`sbin/init` with an `/init` symlink.** The kernel looks for `/sbin/init` on disk boots
and follows `/init` on initramfs boots; one real file, two names, no divergence.

**Console ordering is load-bearing.** In the ISO's GRUB entry the cmdline is
`console=tty0 console=ttyS0,115200` - ttyS0 *last*, so it wins `/dev/console`. With the
order reversed, the kernel still prints to serial but `klogd` and `rlsh` write to tty0,
which doesn't exist under `-vga none`, and the session looks like it hung after
`Run /init as init process`. It isn't hung; it's writing into the void.

**Console geometry via CPR, not a hardcoded 80x24.** `init` queries the terminal with
`ESC[s ESC[999;999H ESC[6n`, parses the `ESC[row;colR` reply under a 2s timeout, then
restores the cursor. That's what lets full-screen TUIs (`rldocs --tui`, `rlrepl`) size
themselves correctly. Hardcoding a size is the thing that silently breaks under a
different terminal.

**Why `klogd` is named that.** It's the traditional Unix name - *k*ernel *log* *d*emon,
the job old `sysklogd` did. This one also colorizes. Rename it freely; it's four places:
`klogd.c`, `compile_klogd.sh`, the `sbin/klogd` install in `assemble-rootfs.sh`, and two
`execve` paths in `init.c`.

**No `ld.so.cache` in the guest.** The assembler flattens every runtime dependency into
`/usr/lib64` (the loader's default search path) as well as preserving its real absolute
path, so libraries from anywhere on the host resolve in-guest without a cache.

## X11 stack

`build_x11.sh` is optional and independent of the text-mode build; the guest boots into
i3 + mlterm when `x11-dist/` exists and into the text console when it does not. The
stack is Xorg 21.1.24, i3 4.25, mlterm 3.9.1, libXft 2.3.9 and
xkeyboard-config, plus the three libraries i3 needs and the host lacks: yajl 2.1.0,
xcb-util-xrm 1.3 and libstartup-notification 0.12.

**Two video drivers ship, because which one is right is a property of the machine.**
On a GPU-less machine (or firmware that only exports a framebuffer) the fbdev DDX takes
`DRM_EFIDRM`'s framebuffer directly; on the laptop's Intel GPU the real path is i915 +
modesetting. `init.c` picks between two complete `xorg.conf` templates at boot by
reading the driver symlink under `/sys/class/drm/card0/device/driver`.

**No multiplexer, on purpose.** mlterm has built-in scrollback, which is what dvtm was
vendored for; `st` and Alacritty came and went, but scrollback is still not a reason
to ship one. `help.rl` is checked against
`etc-rlos/i3.config` at build time so the cheat sheet cannot drift from the real
bindings.

**Input is `xf86-input-libinput` + `eudev`, and both were reversals.** This project
first shipped its own evdev reader (`x11-drv/rlos_evdev.c`, ~450 lines) specifically to
avoid a dependency tree. It passed under QEMU and failed twice on real laptop hardware
- once because it scanned `/dev/input` once at `PreInit` and never rescanned, so a USB
keyboard enumerating seconds later was missed permanently; once because it only
understood relative pointing devices, so an I2C-HID touchpad reporting only absolute axes
was not recognised as a pointer at all. Both failures presented identically: a desktop
that renders and accepts nothing.

libinput is the supported path and it is where the hard parts already are - touchpad
gestures, palm detection, scroll, and correct classification of the several
keyboard-shaped, mouse-shaped and neither-shaped devices a laptop actually has. It also
pulls in **udev**, for two reasons that are not optional:

- libinput will not open a device without a udev database entry. `open_restricted()` in
  `src/path-seat.c` resolves the node with `udev_device_new_from_devnum()` and then
  polls `udev_device_get_is_initialized()` 200 times at 10ms before giving up with
  `libinput bug: udev device never initialized`. "Initialized" means an entry under
  `/run/udev/data`, and only a running `udevd` writes those.
- `60-input-id.rules` is what sets `ID_INPUT_KEYBOARD`/`ID_INPUT_MOUSE`/
  `ID_INPUT_TOUCHPAD`/`ID_SEAT`, which is how libinput tells a touchpad from a mouse.
  That is also the hook that would later carry `LIBINPUT_CONFIG_TAP_TO_CLICK`.

So the guest runs `udevd`, which is a small deviation from "no daemons" and buys working
input plus a supported path to touchpad configuration later.

**Two more things the driver needs that nothing here provides by default.** Both are
handled by `init.c` at boot, and both were found by running the thing rather than reading
about it:

1. `xf86-input-libinput` enumerates nothing itself. Its `PreInit` takes the node from
   `Option "Device"` and returns `BadValue` without it. `hw/input/` was removed from
   xorg-server in 21.x, so there is no server-side enumerator, and a `Device` section is
   the only source of that option - normally written by udev's `60-libinput.conf`.
   `gen_input_config()` therefore builds `/etc/X11/xorg.conf` at boot from a staged
   `xorg.conf.base` plus one `InputDevice` section per `/dev/input/event*` node.
2. The input devices register seconds before `udevd` starts, so those `add` uevents were
   delivered to nobody. `udevd` needs `udevadm trigger` to replay them and
   `udevadm settle` to know when that is done.

**`eudev` is built with `--libdir=/usr/lib64`, which fixes its rules path.** `udevd` has
no `--rules-dir`; its search path is compiled in. libinput's meson build installs its own
rules under `/usr/lib`, so `build_x11.sh` merges both sets into
`/usr/lib64/udev/rules.d`, and gates that `60-input-id.rules` and libinput's rules are
actually present rather than assuming the install worked.

**Tap-to-click and two-finger scroll are still off.** libinput's touchpad defaults are
conservative and `xf86-input-libinput` configures devices only from udev properties. Now
that `udevd` runs, this is fixable the ordinary way: a
`LIBINPUT_CONFIG_TAP_TO_CLICK="1"` rule in `rules.d`.

**When input is broken, the log you need is hidden behind the thing that is broken.** The
report explaining a dead keyboard is written while X starts, and X covers the text
console with a desktop nobody can type into - so the user is asked for a log they have no
way to read. The `rlOS (live, diagnose input)` GRUB entry exists for this: `rlos.diag` on
the kernel command line makes init run `rlin` and then deliberately *not* start X, leaving
the report on the framebuffer where it can be read, or photographed, with nothing
depending on the thing being diagnosed.

## Layout

```
compile_kernel.sh          kernel build from kernel.config -> bzImage
build_rl_bins.sh           6 rl binaries (no-media) -> rl-bins/
assemble-rootfs.sh         shared userspace tree -> any target dir
build_binutils.sh          binutils -> binutils-dist/  (guest as + ld)
build_gcc.sh               gcc (C-only+LTO) -> gcc-dist/  (guest `cc`)
build_git.sh               git 2.55.0 -> git-dist/     (guest git)
build_xorriso.sh           xorriso -> host-tools/      (host ISO tool)

rlos-initramfs/            init.c, klogd.c, packers, run_qemu.sh
rlos-iso/                  mkiso.sh, run_qemu.sh, run_qemu_uefi.sh
rlos-disk/                 mkdisk.sh, install.sh, mkusb.sh, run_qemu.sh
scripts/                   *.sh -> staged into the guest's /usr/bin (suffix dropped)
rl_programs/               rl-lang userspace sources
kernel.config              stripped kernel config (source of truth)
```

## License

MIT - see [LICENSE](LICENSE.md).
