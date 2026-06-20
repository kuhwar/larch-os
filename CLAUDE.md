# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**larch-os** is a build system that produces a single `larch-os.iso` — a minimal, immutable ("atomic") Linux distribution running GNOME Wayland on Debian Trixie. The OS root is a read-only SquashFS image; writes at runtime go to a tmpfs OverlayFS layer and are discarded on reboot. Applications are delivered exclusively via Flatpak. There is no running package manager.

## Project goal & design principles

The end product is an **atomic, image-based distro** where the entire OS is one immutable unit and upgrades happen by swapping that unit — never by mutating files in place.

**Boot-to-install flow.** `./docker-build.sh` produces `larch-os.iso`. Booting the ISO drops the user straight into the installer script (no live desktop). The installer collects exactly four things:

1. hostname
2. username
3. password
4. target disk

It then **wipes the target disk** and creates **two partitions**:

- **Partition 1 — boot/system.** Holds the bootloader, the initramfs (which embeds the entire OS as a SquashFS), and all per-machine configuration files (`fstab`, `passwd`, `shadow`, `hostname`, `hosts`, `sudoers`, `username`, …).
- **Partition 2 — home.** The user's `/home/<username>`, persistent across upgrades.

**Atomic upgrade model.** A future OS version is shipped as a **new initramfs** (with its embedded SquashFS). Upgrading means replacing the initramfs on partition 1 and **re-linking the existing configuration files** — `fstab`, password, hostname, user, etc. are preserved, not regenerated. The user partition is never touched. This makes upgrades atomic and trivially rollback-able, and keeps all machine state on partition 1's config files rather than baked into the OS image.

**Deliberately minimal, locked-down configuration.** The system favors zero-decision defaults over flexibility:

- **Networking is always DHCP** with DNS provided by DHCP. No network configuration UI/flow.
- **Single fixed user.** The account created at install time is the only user. There is **no facility to add or remove users** afterward — user management is intentionally absent.
- **Core desktop only:** base GNOME (Wayland), **Nautilus** as the file manager, and **GNOME Terminal**. Nothing beyond the minimal desktop ships in the core image.
- **No package manager.** Software is installed solely via the **`flatpak` CLI** against Flathub. The base OS cannot be modified by the user; only Flatpak apps and `/home` change.

When implementing features, default to the most minimal, opinionated, immutable option consistent with these principles. Anything that would let the user mutate the base OS, add a second user, or hand-configure networking runs against the project's intent.

## Build commands

**The OS is built only inside the privileged Docker builder.** There is no host-side
build script — the 9-stage pipeline lives in `docker-entrypoint.sh` (the container
ENTRYPOINT) and needs `chroot`, `mount --bind`, and `mknod`, none of which are
available to an unprivileged `docker build`. So the pipeline runs at `docker run
--privileged` time via `./docker-build.sh`, never as Dockerfile `RUN` steps. The
Makefile build targets are thin wrappers around `./docker-build.sh`.

```bash
# Full build (all 9 stages) — takes 20–40 min on first run
make iso                       # → output/larch-os.iso   (alias for ./docker-build.sh)

# Delete work/ and output ISO
make clean                     # → ./docker-build.sh --clean

# Install host-side tools for QEMU testing / dev-disk (NOT for building)
sudo make install-deps
```

### Docker build / resume

```bash
./docker-build.sh              # full build → output/larch-os.iso
./docker-build.sh --dev        # bind-mount source for fast iteration
./docker-build.sh --stage 6    # resume from stage 6 (work/ is bind-mounted, so resume works)
./docker-build.sh --only 7     # run exactly one stage
./docker-build.sh --shell      # interactive shell inside builder container
./docker-build.sh --clean      # delete output/ and work/ (uses Docker for root-owned files)
```

`docker-build.sh` runs the builder container with `--privileged` (needed for `chroot`,
`mount --bind`, and `mknod`) and forwards any `--stage`/`--only` flags straight to the
entrypoint.

### Incremental rebuild shortcuts

| Changed | Command |
|---|---|
| `rootfs-overlay/` files | `./docker-build.sh --stage 3` |
| `config/packages.list` or `scripts/setup-chroot.sh` | `./docker-build.sh --stage 4` |
| `scripts/clean-rootfs.sh` or `config/remove.list` | `./docker-build.sh --stage 5` |
| `installer/install.sh`, `config/packages.list`, or `rootfs-overlay/` (incl. `larch-installer.service`) | `./docker-build.sh --stage 6` (the installer + its payload live in the squashfs now) |
| `initramfs/os/` (init or modules.list) | `./docker-build.sh --stage 6` (the base image is rebuilt into the squashfs at stage 6, the bootable initramfs at stage 7) |
| Bootloader configs only | `./docker-build.sh --stage 6` (loader configs are staged into the squashfs payload) |

### Test in QEMU

```bash
make test-qemu               # boot ISO with UEFI (requires ovmf + qemu-system-x86)
make test-qemu-install       # boot ISO + blank 20G qcow2 disk for install testing
```

### Test in QEMU

```bash
make test-qemu               # boot ISO with UEFI (requires ovmf + qemu-system-x86)
make test-qemu-install       # boot ISO + blank 20G qcow2 disk for install testing
```

## Architecture

### Build pipeline (`docker-entrypoint.sh`)

Nine stages executed in order; `--stage N` skips stages before N, `--only N` runs just N:

1. **check-deps** — verifies `debootstrap`, `mksquashfs`, `xorriso`, `cpio`, systemd-boot EFI binary
2. **debootstrap** — creates `work/rootfs/` from Debian Trixie; skipped if `work/rootfs/usr/` already exists
3. **copy-overlay** — `cp -a rootfs-overlay/. work/rootfs/` (overlay wins over debootstrap defaults)
4. **chroot-configure** — bind-mounts proc/sys/dev, then runs `scripts/setup-chroot.sh` inside chroot; copies `config/packages.list` and `config/remove.list` into the chroot before invoking it
5. **clean-rootfs** — runs `scripts/clean-rootfs.sh` inside chroot to physically remove apt/dpkg and dev headers
6. **make-squashfs** — first stages the **installer payload** into the rootfs (`install_os_payload_into_rootfs`: the OS `initramfs-base.img`, `bootx64.efi`, loader config under `/usr/lib/larch/payload/`, plus `installer/install.sh` → `/usr/sbin/larch-install`), then `mksquashfs work/rootfs work/rootfs.squashfs -comp zstd -Xcompression-level 19`. Decompresses `.ko.xz`/`.ko.zst` modules in the base image and patches `modules.dep` (busybox modprobe cannot load compressed modules).
7. **build-initramfs** — builds the single bootable OS initramfs (`work/initramfs.img`): `rootfs.squashfs` appended raw, then the gzip base. This same image boots the live ISO and the installed disk.
8. **assemble-iso** — builds `work/iso/` directory tree (kernel + OS initramfs + grub.cfg — a pure boot carrier)
9. **make-iso** — `grub-mkrescue -d /usr/lib/grub/x86_64-efi -o larch-os.iso work/iso/ -- -volid LARCHOS` (`-d` pins a single GRUB platform so the ISO is **UEFI-only** — no BIOS El Torito image even if `grub-pc-bin` is installed)

### One initramfs, two roles (no separate installer initramfs)

There is a **single** OS initramfs (`work/initramfs.img`, source `initramfs/os/`, built by `build_initramfs()`). It embeds `rootfs.squashfs` and boots the real OS. It is used unchanged for both the live ISO and the installed disk — what differs is only the kernel cmdline:

- **Installed disk** (systemd-boot): boots normally → graphical login.
- **Live ISO** (GRUB): cmdline adds `larch.installer systemd.unit=multi-user.target`, so the system boots to a **text console** and `larch-installer.service` runs `/usr/sbin/larch-install` on tty1. Because this is the fully-booted OS, **systemd-udevd has auto-loaded every hardware driver** (keyboard, storage, …) — the installer no longer depends on a hand-maintained kernel-module list, which is why the keyboard works on any machine.

**The installer reassembles the disk image; it does not carry a second copy.** Storing the squashfs once (in the booting initramfs) means `install.sh` must rebuild the target's OS initramfs at install time:

```
target initramfs.img  =  raw-cpio(rootfs.squashfs)  ++  initramfs-base.img
```

- `rootfs.squashfs` is **recovered from the live root's loop device** (`blkid` finds the loop whose `TYPE=squashfs`) with `dd` — no second copy is stored on the ISO or in RAM.
- `initramfs-base.img` is the **"pass 2" half** of the OS initramfs (busybox + modules + init, *no* squashfs), built once at stage 6 by `build_initramfs_base()` and baked into the squashfs at `/usr/lib/larch/payload/`.

This reproduces byte-for-byte the same two-pass early-cpio layout `build_initramfs()` produces for the ISO. **Two-pass ordering still matters**: the raw (uncompressed) squashfs cpio MUST come first, the gzip base second.

### ISO layout (`work/iso/`)

```
/vmlinuz                          ← kernel        (GRUB: linux /vmlinuz)
/initramfs.img                    ← OS initramfs (embeds rootfs.squashfs); GRUB cmdline routes it to installer mode
/boot/grub/grub.cfg               ← GRUB2 menu (path is fixed by grub-mkrescue)
```

The ISO is a pure boot carrier — GRUB boots these two files. The installer payload (`initramfs-base.img`, EFI, loader, `larch-install`) lives **inside the squashfs**, not loose on the ISO.

### Boot flow

**ISO/live:** GRUB2 → `/vmlinuz` + `/initramfs.img` → OS init mounts squashfs/overlay → `switch_root` to systemd → (cmdline `larch.installer`) `larch-installer.service` runs `/usr/sbin/larch-install` on tty1, with udev-loaded drivers

**Installed disk:** systemd-boot → `/larch-os/vmlinuz` + `/larch-os/initramfs.img` → OS init applies config → `switch_root` to systemd → graphical login

**Installer (`installer/install.sh`, shipped as `/usr/sbin/larch-install`)** — runs in the booted live system as root on tty1:
1. Verifies the payload (`/usr/lib/larch/payload/…`) and locates the squashfs loop device
2. Prompts for hostname/username/password/target disk
3. Partitions + formats, **reassembles** the target `initramfs.img` (squashfs from loop + base), writes the bootloader and per-machine config to LARCHOS, seeds LARCHHOME, then `systemctl reboot`

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

GRUB is only for booting the ISO, and only in **UEFI mode** — the whole system (live ISO and installed disk) is UEFI-only. The ISO carries no BIOS/legacy boot path; stage 9 pins `grub-mkrescue -d /usr/lib/grub/x86_64-efi` so only a UEFI El Torito image is emitted. `grub-mkrescue` requires grub.cfg at `/boot/grub/grub.cfg` — this path cannot be changed.

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
| `docker-entrypoint.sh` | The build: orchestrates all 9 stages inside the privileged builder container; defines `build_initramfs()`, `chroot_run()` / `chroot_run_with_deps()` helpers. Runs at `docker run` time (the container ENTRYPOINT), not during `docker build` |
| `docker-build.sh` | Host wrapper: builds the `larch-os-builder` image, then runs it `--privileged` with `work/` and `output/` bind-mounted; forwards `--stage`/`--only`/`--clean`/`--dev`/`--shell` |
| `Dockerfile` | Builder image (`debian:trixie-slim`) with all build tools; `ENTRYPOINT` is `docker-entrypoint.sh` |
| `scripts/setup-chroot.sh` | Installs packages, creates default user `larch` (password `larch`), enables GDM/NetworkManager/PipeWire, adds Flathub remote, configures polkit for Flatpak |
| `scripts/clean-rootfs.sh` | Purges apt/dpkg and dev artifacts from rootfs before squashfs |
| `config/packages.list` | Packages installed by `setup-chroot.sh` (comments and blank lines stripped) |
| `config/remove.list` | Packages purged by `clean-rootfs.sh` after configuration |
| `initramfs/os/init` | Busybox sh PID 1 (live ISO **and** installed disk); mounts squashfs, overlayfs, applies config from LARCHOS, `switch_root`s to systemd |
| `initramfs/os/modules.list` | Modules for the OS initramfs (squashfs/overlay + storage drivers to find LARCHOS). Note: this only needs to get to `switch_root`; **all** other hardware (incl. the installer's keyboard) is loaded by udev afterward |
| `installer/install.sh` | The installer, shipped as `/usr/sbin/larch-install`. Runs in the booted live system on tty1: prompts, partitions, **reassembles** the target `initramfs.img` (squashfs from loop + base), writes bootloader + config to LARCHOS, seeds home |
| `rootfs-overlay/etc/systemd/system/larch-installer.service` | Runs `larch-install` on tty1 when the cmdline has `larch.installer`; gated by `ConditionKernelCommandLine` so it is inert on installed disks |
| `rootfs-overlay/` | Files copied verbatim into rootfs at stage 3; mirror the target path |

## Common customisation patterns

- **Add a package:** edit `config/packages.list`, re-run from stage 4
- **Add a system config file:** drop it in `rootfs-overlay/` mirroring its final path, re-run from stage 3
- **Add/remove a kernel module in the OS initramfs:** edit `initramfs/os/modules.list` and the `load_mod` calls in `initramfs/os/init`, re-run from **stage 6** (the base image is rebuilt into the squashfs there). Only modules needed to reach `switch_root` belong here — everything else is loaded by udev in the live system.
- **Change the installer behaviour:** edit `installer/install.sh` (or `larch-installer.service`), re-run from **stage 6** (both ship inside the squashfs)
- **Change the default live user or password:** edit `scripts/setup-chroot.sh`, re-run from stage 4
- **Enable autologin:** edit `rootfs-overlay/etc/gdm3/custom.conf`, re-run from stage 3

## Important constraints

- **`set -euo pipefail`** is used throughout `docker-entrypoint.sh` — any unhandled command failure aborts the build
- **Both init scripts use `set -e`** and run as PID 1; unhandled errors call `emergency_shell` (busybox sh on `/dev/console`); any command that may legitimately produce no output (e.g. `grep`, `ls`) must have `|| true`
- **`.ko.xz` modules** (Trixie default): busybox `modprobe` cannot load XZ-compressed modules; `populate_initramfs_tree()` always decompresses them and patches `modules.dep` (runs for both the stage-6 base image and the stage-7 bootable initramfs) — do not skip this when adding modules
- **`rootfs.squashfs` is not a separate file on the installed disk** — it is embedded inside `initramfs.img` as a raw uncompressed cpio append; never double-compress it
- **`work/` contents are root-owned** (created inside the privileged container); use `./docker-build.sh --clean` rather than `rm -rf work/` to avoid permission errors
- **Output ISO path** is controlled by `$LARCH_OUTPUT_ISO` env var (defaults to `$SCRIPT_DIR/larch-os.iso`; Docker sets it to `/output/larch-os.iso`)
