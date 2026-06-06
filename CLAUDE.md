# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**larch-os** is a build system that produces a single `larch-os.iso` — a minimal, immutable Linux distribution running GNOME Wayland on Debian Trixie. The OS root is a read-only SquashFS image; writes at runtime go to a tmpfs OverlayFS layer and are discarded on reboot. Applications are delivered exclusively via Flatpak. There is no running package manager.

## Build commands

All build targets require root. The Makefile is a thin wrapper around `build.sh`.

```bash
# Full build (all 9 stages) — takes 20–40 min on first run
sudo make iso

# Resume from a specific stage (e.g. after editing rootfs-overlay/)
sudo ./build.sh --stage 3

# Re-run exactly one stage
sudo ./build.sh --only 7

# Delete work/ and output ISO
sudo make clean

# Install host-side build tools
sudo make install-deps
```

### Incremental rebuild shortcuts

| Changed | Command |
|---|---|
| `rootfs-overlay/` files | `sudo ./build.sh --stage 3` |
| `config/packages.list` or `scripts/setup-chroot.sh` | `sudo ./build.sh --stage 4` |
| `scripts/clean-rootfs.sh` or `config/remove.list` | `sudo ./build.sh --stage 5` |
| `initramfs/installer/` or `initramfs/os/` or `installer/install.sh` | `sudo ./build.sh --only 7` |
| Bootloader configs only | `sudo ./build.sh --stage 8` |

### Docker build (no host-side deps required)

```bash
./docker-build.sh              # full build → output/larch-os.iso
./docker-build.sh --dev        # bind-mount source for fast iteration
./docker-build.sh --stage 6    # resume from stage 6
./docker-build.sh --shell      # interactive shell inside builder container
./docker-build.sh --clean      # delete output/ and work/ (uses Docker for root-owned files)
```

The container must run with `--privileged` (needed for `chroot`, `mount --bind`, and `mknod`).

### Test in QEMU

```bash
make test-qemu               # boot ISO with UEFI (requires ovmf + qemu-system-x86)
make test-qemu-install       # boot ISO + blank 20G qcow2 disk for install testing
```

## Architecture

### Build pipeline (`build.sh`)

Nine stages executed in order; `--stage N` skips stages before N, `--only N` runs just N:

1. **check-deps** — verifies `debootstrap`, `mksquashfs`, `xorriso`, `cpio`, systemd-boot EFI binary
2. **debootstrap** — creates `work/rootfs/` from Debian Trixie; skipped if `work/rootfs/usr/` already exists
3. **copy-overlay** — `cp -a rootfs-overlay/. work/rootfs/` (overlay wins over debootstrap defaults)
4. **chroot-configure** — bind-mounts proc/sys/dev, then runs `scripts/setup-chroot.sh` inside chroot; copies `config/packages.list` and `config/remove.list` into the chroot before invoking it
5. **clean-rootfs** — runs `scripts/clean-rootfs.sh` inside chroot to physically remove apt/dpkg and dev headers
6. **make-squashfs** — `mksquashfs work/rootfs work/rootfs.squashfs -comp zstd -Xcompression-level 19`
7. **build-initramfs** — builds **two** fat initramfs images (see below); decompresses `.ko.xz`/`.ko.zst` modules (busybox modprobe cannot load compressed modules), patches `modules.dep`
8. **assemble-iso** — builds `work/iso/` directory tree
9. **make-iso** — `grub-mkrescue -o larch-os.iso work/iso/ -- -volid LARCHOS`

### Two initramfs images

Stage 7 produces two self-contained ("fat") initramfs files via the shared `build_initramfs()` function:

| Output file | Source dir | Extras baked in | Purpose |
|---|---|---|---|
| `work/installer.img` | `initramfs/installer/` | `install.sh` + `mke2fs` + shared libs | Runs on ISO boot; drives the installer |
| `work/initramfs.img` | `initramfs/os/` | `rootfs.squashfs` (raw, uncompressed cpio append) | Copied to the installed disk; boots the OS |

**Two-pass cpio packing** for the OS initramfs: small files are gzip-9 compressed in one cpio pass; `rootfs.squashfs` (already zstd-compressed) is appended as a second raw uncompressed cpio block. The Linux kernel merges concatenated cpio archives transparently, so the squashfs is never double-compressed.

### ISO layout (`work/iso/`)

```
/vmlinuz                          ← kernel (ISO boot)
/initramfs.img                    ← installer initramfs (fat, contains install.sh)
/boot/grub/grub.cfg               ← GRUB2 menu (path is fixed by grub-mkrescue)
/larch-os/initramfs.img           ← OS initramfs (fat, contains rootfs.squashfs)
/larch-os/vmlinuz                 ← kernel (copied to installed disk)
/larch-os/bootx64.efi             ← systemd-boot EFI binary
/larch-os/loader/loader.conf
/larch-os/loader/entries/larch.conf
```

Everything at the ISO root is the installer runtime. Everything under `/larch-os/` is copied to the target disk by `install.sh`.

### Boot flow

**ISO/live:** GRUB2 → `/vmlinuz` + `/initramfs.img` (installer initramfs) → `install.sh` runs

**Installed disk:** systemd-boot → `/larch-os/vmlinuz` + `/larch-os/initramfs.img` (OS initramfs) → systemd

**Installer initramfs (`initramfs/installer/init`)** — busybox sh PID 1:
1. Loads all storage, USB, and filesystem modules
2. Scans optical drives for an ISO9660 volume containing the larch-os payload
3. Mounts the ISO at `/mnt/iso`
4. `exec /install.sh`

**OS initramfs (`initramfs/os/init`)** — busybox sh PID 1:
1. Loads modules (squashfs/loop/overlay first, then storage/FAT drivers)
2. Loop-mounts embedded `/rootfs.squashfs` read-only
3. Stacks OverlayFS: `lowerdir=squashfs, upperdir=tmpfs/upper, workdir=tmpfs/work` → `/mnt/root`
4. Settles devices (`udevadm settle || sleep 2`), then finds `LABEL=LARCHOS` via `blkid`
5. Mounts LARCHOS read-only, reads config files from `/larch-os/` and writes them into the overlayfs upper (tmpfs) layer — applied on **every** boot without touching the squashfs
6. Moves proc/sys/dev and calls `switch_root /mnt/root /lib/systemd/systemd`

If LARCHOS is not found (live ISO, or disk not yet formatted), the init logs a warning and boots with the squashfs defaults.

### User config persistence

The installer collects hostname, username, and password and writes these files to `LARCHOS:/larch-os/`:

| File | Content |
|---|---|
| `hostname` | plain hostname string |
| `hosts` | `/etc/hosts` content |
| `passwd` | single `/etc/passwd` line for UID 1000 |
| `shadow` | single `/etc/shadow` line with SHA-512 hash |
| `sudoers` | `<username> ALL=(ALL) NOPASSWD:ALL` |
| `username` | plain username string (used by init to rename groups) |
| `fstab` | full `/etc/fstab` with `LABEL=LARCHHOME → /home/<username>` |

The OS init re-applies these on every boot into the tmpfs upper layer:
- **passwd**: strips any UID-1000 line from the squashfs default, appends the installer entry
- **shadow**: strips the default `larch:` entry, appends the hashed installer entry
- **group**: `sed 's/\blarch\b/$USERNAME/g'` — renames group memberships to the installed username (word-boundary-safe)
- **sudoers**: written to `/etc/sudoers.d/larch-os-user` (mode 440)
- **fstab**: replaces `/etc/fstab`; the init also creates `/home/<username>` as a mount point (owned 1000:1000, mode 0750) and masks `home.mount` with a `/dev/null` symlink so `systemd-fstab-generator` takes over home mounting

### `/home` persistence

`/home` is not mounted in initramfs. On an installed system, systemd mounts `LABEL=LARCHHOME` via a `.mount` unit after `switch_root`. In live/ISO mode the fstab has `nofail` so systemd skips it and `/home` is served from the tmpfs upper layer.

### Two bootloader configs

| File | Purpose |
|---|---|
| `bootloader/grub.cfg` | Live ISO boot menu (GRUB2, ISO9660); references `/vmlinuz` and `/initramfs.img` at ISO root |
| `bootloader/loader.conf` + `bootloader/entries/larch.conf` | systemd-boot for installed disk (FAT32 EFI partition); references `/larch-os/vmlinuz` and `/larch-os/initramfs.img` |

GRUB is only for booting the ISO. `grub-mkrescue` requires grub.cfg at `/boot/grub/grub.cfg` — this path cannot be changed.

### Disk layout (installed)

```
Partition 1 — FAT32, 3 GiB, label LARCHOS
  EFI/BOOT/BOOTX64.EFI      (systemd-boot EFI binary)
  loader/loader.conf
  loader/entries/larch.conf
  larch-os/vmlinuz
  larch-os/initramfs.img    (fat — contains rootfs.squashfs)
  larch-os/hostname
  larch-os/hosts
  larch-os/passwd
  larch-os/shadow
  larch-os/sudoers
  larch-os/username
  larch-os/fstab

Partition 2 — ext4, remainder, label LARCHHOME
  <username>/               (seeded from /etc/skel at install time; persistent)
```

## Key files and their roles

| File | Role |
|---|---|
| `build.sh` | Orchestrates all 9 stages; defines `build_initramfs()`, `chroot_run()` / `chroot_run_with_deps()` helpers |
| `scripts/setup-chroot.sh` | Installs packages, creates default user `larch` (password `larch`), enables GDM/NetworkManager/PipeWire, adds Flathub remote, configures polkit for Flatpak |
| `scripts/clean-rootfs.sh` | Purges apt/dpkg and dev artifacts from rootfs before squashfs |
| `config/packages.list` | Packages installed by `setup-chroot.sh` (comments and blank lines stripped) |
| `config/remove.list` | Packages purged by `clean-rootfs.sh` after configuration |
| `initramfs/installer/init` | Busybox sh PID 1 for the installer; finds ISO, mounts it, execs install.sh |
| `initramfs/installer/modules.list` | Modules for the installer initramfs (includes full storage + USB stack) |
| `initramfs/os/init` | Busybox sh PID 1 for the installed OS; mounts squashfs, overlayfs, applies config from LARCHOS |
| `initramfs/os/modules.list` | Modules for the OS initramfs (squashfs/overlay + storage drivers for LARCHOS) |
| `installer/install.sh` | Prompts for hostname/username/password, partitions disk, formats, copies OS initramfs and config files to LARCHOS, seeds home partition |
| `rootfs-overlay/` | Files copied verbatim into rootfs at stage 3; mirror the target path |
| `Dockerfile` | Builder image based on `debian:trixie-slim`; needs `--privileged` at runtime |

## Common customisation patterns

- **Add a package:** edit `config/packages.list`, re-run from stage 4
- **Add a system config file:** drop it in `rootfs-overlay/` mirroring its final path, re-run from stage 3
- **Add/remove a kernel module in the OS initramfs:** edit `initramfs/os/modules.list` and the `load_mod` calls in `initramfs/os/init`, re-run `--only 7`
- **Add/remove a kernel module in the installer initramfs:** edit `initramfs/installer/modules.list` and `initramfs/installer/init`, re-run `--only 7`
- **Change the default live user or password:** edit `scripts/setup-chroot.sh`, re-run from stage 4
- **Enable autologin:** edit `rootfs-overlay/etc/gdm3/custom.conf`, re-run from stage 3

## Important constraints

- **`set -euo pipefail`** is used throughout build.sh — any unhandled command failure aborts the build
- **Both init scripts use `set -e`** and run as PID 1; unhandled errors call `emergency_shell` (busybox sh on `/dev/console`); any command that may legitimately produce no output (e.g. `grep`, `ls`) must have `|| true`
- **`.ko.xz` modules** (Trixie default): busybox `modprobe` cannot load XZ-compressed modules; stage 7 always decompresses them and patches `modules.dep` — do not skip this when adding modules
- **`rootfs.squashfs` is not a separate file on the installed disk** — it is embedded inside `initramfs.img` as a raw uncompressed cpio append; never double-compress it
- **`work/` contents are root-owned** after a native build; use `./docker-build.sh --clean` rather than `rm -rf work/` to avoid permission errors
- **Output ISO path** is controlled by `$LARCH_OUTPUT_ISO` env var (defaults to `$SCRIPT_DIR/larch-os.iso`; Docker sets it to `/output/larch-os.iso`)
