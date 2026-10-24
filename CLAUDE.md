# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**larch-os** is a build system that produces a single `larch-os.iso` — a minimal, immutable ("atomic") Linux distribution running GNOME Wayland on Debian Trixie. The OS root is a read-only SquashFS image; writes at runtime go to a tmpfs OverlayFS layer and are discarded on reboot. Applications are delivered exclusively via Flatpak. There is no running package manager.

## Project goal & design principles

The end product is an **atomic, image-based distro** where the entire OS is one immutable unit and upgrades happen by swapping that unit — never by mutating files in place.

**Boot-to-install flow.** `./docker-build.sh` produces `larch-os.iso`. Booting the ISO drops the user straight into the installer script (no live desktop). The installer collects exactly three things:

1. full name
2. password
3. target disk

The **username** is not asked for: it is derived from the full name (`installer/lib/config-form.sh` `derive_username`) — common accented Latin letters folded to ASCII, lowercased, everything but `a-z0-9` dropped, leading digits stripped, capped at 30 chars (`Jane Doe` → `janedoe`; non-Latin-only names → `user`). If it collides with a name the image's system accounts/groups already use (`root`, `man`, `gdm`, … — listed at build time into the installer's `/usr/lib/larch/reserved-names`), a numeric suffix is appended (`root1`). The full name as typed becomes the passwd GECOS field, i.e. GNOME's display name.

The **hostname** is not asked for either: it is derived as `<username>-<brand>-<device type>` (e.g. `janedoe-lenovo-laptop`; brand from the SMBIOS `sys_vendor`, falling back to `board_vendor`, shortened — `ASUSTeK COMPUTER INC.` → `asus` — and omitted if it is a placeholder like `To be filled by O.E.M.`; `laptop`/`desktop`/`tablet`/`pc` from the SMBIOS chassis type in `/sys/class/dmi/id/chassis_type`). It is fixed after install — `rootfs-overlay/etc/polkit-1/rules.d/99-larch-hostname.rules` denies all `org.freedesktop.hostname1.set-*` actions, since a rename would only land in the tmpfs `/etc` and revert on reboot.

It then **wipes the target disk** and creates **three partitions**:

- **Partition 1 — boot/system.** Holds the bootloader, a tiny OS initramfs, `rootfs.squashfs` (the entire OS), and the per-machine configuration files (`fstab`, `hostname`, `hosts`, `username`, `machine-id`).
- **Partition 2 — config.** Mutable, root-owned system config (`/etc/larch-conf`): the user account files (`passwd`/`shadow`, root-only), NetworkManager connections, Bluetooth pairings, CUPS queues. Never touched by upgrades.
- **Partition 3 — home.** Mounted at `/home`; the user's home directory is `/home/<username>`, persistent across upgrades.

**Atomic upgrade model.** A future OS version is shipped as a **new ISO**. Upgrading means replacing `initramfs.img` and `rootfs.squashfs` on partition 1 and **re-linking the existing configuration files** — `fstab`, password, hostname, user, etc. are preserved, not regenerated. The user partition is never touched. This makes upgrades atomic and trivially rollback-able, and keeps all machine state on partition 1's config files rather than baked into the OS image.

**Deliberately minimal, locked-down configuration.** The system favors zero-decision defaults over flexibility:

- **Networking is always DHCP** with DNS provided by DHCP. No network configuration UI/flow.
- **Single fixed user.** The account created at install time is the only user. There is **no facility to add or remove users** afterward — user management is intentionally absent. `rootfs-overlay/etc/polkit-1/rules.d/99-larch-users.rules` denies `org.freedesktop.accounts.user-administration` and `org.gnome.controlcenter.user-accounts.administration` (add/delete users, account type, autologin in GNOME Settings → Users); the user can still change their own password, name and avatar (`change-own-*` actions).
- **No remote shell.** No SSH server ships in the image, and `rootfs-overlay/etc/polkit-1/rules.d/99-larch-ssh.rules` denies `org.gnome.controlcenter.remote-login-helper`, so GNOME Settings → System → Secure Shell can never enable `ssh.service`. The row itself stays visible (it is compiled into gnome-control-center with no visibility hook).
- **Graphical login only.** No text consoles: `rootfs-overlay/etc/systemd/logind.conf.d/10-larch-no-vt.conf` sets `NAutoVTs=0`/`ReserveVT=0`, and `getty@tty1`/`autovt@` are masked via `/dev/null` symlinks in `rootfs-overlay/etc/systemd/system/`. No cron either (`cron` is in `config/remove.list`; systemd timers cover scheduling), and `clean-rootfs.sh` deletes dpkg's `dpkg-db-backup` timer along with dpkg.
- **Core desktop only:** base GNOME (Wayland), **Nautilus** as the file manager, and **GNOME Terminal**. Nothing beyond the minimal desktop ships in the core image.
- **No package manager.** Software is installed solely via the **`flatpak` CLI** against Flathub. The base OS cannot be modified by the user; only Flatpak apps and `/home` change.

When implementing features, default to the most minimal, opinionated, immutable option consistent with these principles. Anything that would let the user mutate the base OS, add a second user, or hand-configure networking runs against the project's intent.

## Build commands

**The OS is built only inside the privileged Docker builder.** There is no host-side
build script — the 10-stage pipeline lives in `docker-entrypoint.sh` (the container
ENTRYPOINT) and needs `chroot`, `mount --bind`, and `mknod`, none of which are
available to an unprivileged `docker build`. So the pipeline runs at `docker run
--privileged` time via `./docker-build.sh`, never as Dockerfile `RUN` steps. The
Makefile build targets are thin wrappers around `./docker-build.sh`.

```bash
# Full build (all 10 stages) — takes 20–40 min on first run
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
./docker-build.sh --stage 7    # resume from stage 7 (work/ is bind-mounted, so resume works)
./docker-build.sh --only 9     # run exactly one stage
./docker-build.sh --shell      # interactive shell inside builder container
./docker-build.sh --clean      # delete output/ and work/ (uses Docker for root-owned files)
```

`docker-build.sh` runs the builder container with `--privileged` (needed for `chroot`,
`mount --bind`, and `mknod`) and forwards any `--stage`/`--only` flags straight through.

### Incremental rebuild shortcuts

| Changed | Command |
|---|---|
| `rootfs-overlay/` files | `./docker-build.sh --stage 3` |
| `config/packages.list` or `scripts/setup-chroot.sh` | `./docker-build.sh --stage 4` |
| `scripts/clean-rootfs.sh` or `config/remove.list` | `./docker-build.sh --stage 5` |
| `rootfs-overlay/` or any rootfs content | `./docker-build.sh --stage 6` (squashfs rebuild) |
| `initramfs/os/` (init or modules.list) | `./docker-build.sh --stage 7` |
| `installer/install.sh` or `initramfs/installer/` | `./docker-build.sh --stage 8` |
| Bootloader configs only | `./docker-build.sh --stage 9` (assemble-iso only) |

### Test in QEMU

```bash
make test-qemu               # boot ISO with UEFI (requires ovmf + qemu-system-x86)
make test-qemu-install       # boot ISO + blank 20G qcow2 disk for install testing
```

## Architecture

### Build pipeline (`docker-entrypoint.sh`)

Ten stages executed in order; `--stage N` skips stages before N, `--only N` runs just N:

1. **check-deps** — verifies `debootstrap`, `mksquashfs`, `xorriso`, `cpio`, systemd-boot EFI binary
2. **debootstrap** — creates `work/rootfs/` from Debian Trixie; skipped if `work/rootfs/usr/` already exists
3. **copy-overlay** — `cp -a rootfs-overlay/. work/rootfs/` (overlay wins over debootstrap defaults)
4. **chroot-configure** — bind-mounts proc/sys/dev, then runs `scripts/setup-chroot.sh` inside chroot
5. **clean-rootfs** — runs `scripts/clean-rootfs.sh` inside chroot to physically remove apt/dpkg and dev headers; last, it runs `systemd-update-done` so the image ships `/etc/.updated`/`/var/.updated` (otherwise `ConditionNeedsUpdate=` services — ldconfig, systemd-sysusers — rerun every boot, since `/etc` resets each boot)
6. **make-squashfs** — `mksquashfs work/rootfs work/rootfs.squashfs -comp zstd -Xcompression-level 19`
7. **build-os-initramfs** — builds the tiny OS initramfs (`work/os-initramfs.img`): busybox + modules + init, **no squashfs**. Squashfs lives separately on the LARCHOS partition and is loop-mounted at boot.
8. **build-installer** — builds the installer initramfs (`work/installer-initramfs.img`): busybox + modules + `install.sh` + `reserved-names` (user/group names from the rootfs, minus `larch`) + tool binaries (sfdisk, wipefs, mkfs.fat, mkfs.ext4, openssl, blockdev, plus `dialog` + terminfo for the installer UI — required, the build fails if they are absent from the rootfs). GRUB boots this to run the installer.
9. **assemble-iso** — builds `work/iso/` directory tree (see ISO layout below)
10. **make-iso** — `grub-mkrescue -d /usr/lib/grub/x86_64-efi -o larch-os.iso work/iso/ -- -volid LARCHISO` (`-d` pins a single GRUB platform so the ISO is **UEFI-only**)

### Two initramfs files

There are **two separate initramfs files** with distinct roles:

**`work/installer-initramfs.img`** (~10 MB) — what GRUB boots on the ISO:
- Source: `initramfs/installer/`
- Contains busybox, kernel modules, `install.sh` (as `/usr/sbin/larch-install`), and tool binaries
- Its init finds the ISO by `LABEL=LARCHISO`, mounts it at `/mnt/iso`, then `exec`s `larch-install`
- Never switch_roots — the installer runs to completion and reboots

**`work/os-initramfs.img`** (~4 MB) — what systemd-boot loads on the installed disk:
- Source: `initramfs/os/`
- Contains busybox, kernel modules, and the OS init script. **No squashfs.**
- Its init finds the LARCHOS partition, loop-mounts `rootfs.squashfs` from it, builds an overlayfs, applies per-machine config, then `switch_root`s to systemd
- Placed on the ISO at `/larch-os/initramfs.img` so the installer can copy it to the target disk

### ISO layout (`work/iso/`)

```
/vmlinuz                          ← kernel        (GRUB: linux /vmlinuz)
/installer-initramfs.img          ← installer initramfs (GRUB: initrd /installer-initramfs.img)
/boot/grub/grub.cfg               ← GRUB2 menu (path fixed by grub-mkrescue)
/EFI/BOOT/BOOTX64.EFI            ← systemd-boot EFI binary (installer copies to LARCHOS)
/loader/                          ← systemd-boot config (installer copies to LARCHOS)
/skel/                            ← /etc/skel contents (installer seeds LARCHHOME)
/larch-os/vmlinuz                 ← kernel copy (installer copies to LARCHOS)
/larch-os/initramfs.img           ← OS initramfs — tiny, no squashfs (installer copies)
/larch-os/rootfs.squashfs         ← OS squashfs (installer copies to LARCHOS)
```

GRUB boots `vmlinuz` + `installer-initramfs.img`. Everything under `/larch-os/` is data for the installer to copy to the target disk — it is not loaded by GRUB.

### Boot flow

**ISO/live:** GRUB2 → `/vmlinuz` + `/installer-initramfs.img` → installer init mounts ISO at `/mnt/iso` → runs `/usr/sbin/larch-install`

**Installed disk:** systemd-boot → `/larch-os/vmlinuz` + `/larch-os/initramfs.img` → OS init finds LARCHOS → loop-mounts `rootfs.squashfs` → overlayfs → applies config → `switch_root` to systemd → graphical login

**Installer (`installer/install.sh`, bundled into the installer initramfs as `/usr/sbin/larch-install`)**:
1. Verifies the ISO payload at `/mnt/iso/larch-os/`
2. Prompts for full name/password/target disk (username is derived from the full name, hostname from username + chassis type)
3. Partitions + formats (3 partitions), copies `initramfs.img` + `rootfs.squashfs` + `vmlinuz` + bootloader to LARCHOS, writes per-machine config, seeds LARCHCONF (NM connections dir) and LARCHHOME, then reboots

**OS initramfs (`initramfs/os/init`)** — busybox sh PID 1:
1. Loads modules (squashfs/loop/overlay first, then storage/FAT drivers)
2. Settles devices, scans for LARCHOS partition (FAT32 containing `rootfs.squashfs`)
3. Mounts LARCHOS at `/mnt/config`
4. Loop-mounts `/mnt/config/larch-os/rootfs.squashfs` read-only at `/mnt/squashfs`
5. Stacks OverlayFS: `lowerdir=squashfs, upperdir=tmpfs/upper, workdir=tmpfs/work` → `/mnt/root`
6. Reads config files from `/mnt/config/larch-os/` and writes them into the overlayfs upper (tmpfs) layer — applied on **every** boot without touching the squashfs
7. Moves proc/sys/dev and calls `switch_root /mnt/root /lib/systemd/systemd`

LARCHOS is **not unmounted** before `switch_root`: the squashfs loop device holds an open file reference to `rootfs.squashfs` on that filesystem. It becomes a detached mount after `switch_root` — invisible from the new root's filesystem tree but alive in the kernel's mount table.

### User config persistence

The installer writes these files to `LARCHOS:/larch-os/`:

| File | Content |
|---|---|
| `hostname` | plain hostname string (`<username>-<brand>-<device type>`, derived by the installer) |
| `hosts` | `/etc/hosts` content |
| `username` | plain username string (used by init to rename groups) |
| `machine-id` | 32 hex digits — stable `/etc/machine-id`, generated once at install |
| `fstab` | full `/etc/fstab` with `LABEL=LARCHCONF → /etc/larch-conf`, `LABEL=LARCHHOME → /home`, and NM bind mount |

The account files go to `LARCHCONF:/accounts/` instead (dir `0700`, root-owned) — FAT32 has no permissions, so a `shadow` on LARCHOS would be readable by anyone who mounts the disk:

| File | Content |
|---|---|
| `accounts/passwd` | single `/etc/passwd` line for UID 1000, GECOS = full name (mode 0644) |
| `accounts/shadow` | single `/etc/shadow` line with SHA-512 hash (mode 0600) |

The OS init mounts LARCHCONF **read-only** (`findfs LABEL=LARCHCONF`, ext4 modules loaded) just to read these, then unmounts it before `switch_root` so `systemd-fsck` can check it. If LARCHCONF or `accounts/` is missing, it falls back to `LARCHOS:/larch-os/{passwd,shadow}` (pre-move installs, `make-dev-disk.sh` disks). The installer's **update** path migrates those LARCHOS copies into `LARCHCONF:/accounts/` and deletes them from LARCHOS.

**Password changes persist via write-back**, not via links: `larch-persist-accounts.path` watches `/etc/passwd` and `/etc/shadow` (tmpfs) and runs `/usr/libexec/larch-persist-accounts`, which copies the UID-1000 lines to `/etc/larch-conf/accounts/` (atomic temp+rename, skipped if unchanged). This covers `passwd`, GNOME Settings (AccountsService → `usermod`) and full-name changes. Symlinking or bind-mounting `/etc/shadow` onto LARCHCONF does **not** work — tested on Trixie: `passwd`/`chpasswd` replace the symlink via rename, and `usermod` refuses a symlinked `/etc/passwd` (`cannot open /etc/passwd`).

The OS init re-applies these on every boot into the tmpfs upper layer:
- **passwd**: strips any UID-1000 line from the squashfs default, appends the installer entry
- **shadow**: strips the default `larch:` entry, appends the hashed installer entry
- **group**: `sed 's/\blarch\b/$USERNAME/g'` — renames group memberships to the installed username (word-boundary-safe)
- **machine-id**: copies the installer value to `/etc/machine-id` (mode 0444). Without it, `/etc` being tmpfs means systemd would synthesise a *new* id every boot, so the machine would get a different DHCP lease/IP (the DHCP client-id / DHCPv6 DUID derive from machine-id) and a fresh journal identity on each boot. Generated once at install from the kernel UUID pool.
- **timezone**: if `LARCHCONF:/timezone` exists, re-links `/etc/localtime` to `../usr/share/zoneinfo/<zone>` (only plain zone names that exist in the image; otherwise the image default, UTC). Time and timezone are automatic by default: `systemd-timesyncd` syncs the clock, and `rootfs-overlay/usr/share/glib-2.0/schemas/90_larch.gschema.override` turns on `automatic-timezone` and Location Services, so gsd-datetime sets the zone via `geoclue-2.0`. `rootfs-overlay/etc/polkit-1/rules.d/99-larch-datetime.rules` lets the active local session call timedated for this (`timedate1.set-timezone`/`set-ntp`/`set-time`, plus GNOME's `datetime.configure` to unlock the Date & Time page); `larch-persist-timezone.path` writes changes back. It watches `/etc` itself, not `/etc/localtime` — inotify follows the symlink to the read-only zoneinfo file, so a watch on the link never fires when timedated replaces it.
- **fstab**: replaces `/etc/fstab`; `systemd-fstab-generator` turns the `LABEL=LARCHHOME → /home` entry into `home.mount`. The init also creates the `/etc/larch-conf` mount point and a fallback `/home/<username>` dir in the tmpfs upper layer (owned 1000:1000, mode 0750) — visible only if LARCHHOME is absent, since the mounted partition hides it otherwise

### `/home` and `/etc/larch-conf` persistence

LARCHHOME is not mounted in initramfs, and LARCHCONF only briefly read-only (for the account files, see above). On an installed system, systemd mounts them via the generated fstab after `switch_root`.

### Persistent system config on LARCHCONF (WiFi, Bluetooth, printing)

Several daemons keep their state under `/etc` or `/var`, both of which live in the tmpfs OverlayFS upper layer — anything they write there would be **discarded on every reboot**. The LARCHCONF partition (`/etc/larch-conf`, ext4, root-owned) is the persistent store for this kind of system config; each service is backed by it via a bind mount, following the same three-part pattern:

1. **Installer seeds the store** (`installer/install.sh`, config-seeding block): creates a root-owned, `0700` directory at the root of LARCHCONF for the service.
2. **Installer-generated fstab adds a bind line** from that LARCHCONF directory onto the service's live state path (`bind,nofail`, plus `x-systemd.mkdir` where the target isn't guaranteed to already exist). `systemd-fstab-generator` auto-orders the bind mount after the `/etc/larch-conf` mount.
3. **A static `RequiresMountsFor` drop-in in `rootfs-overlay/etc/systemd/system/<service>.service.d/`** holds the service until its bind mount is ready — otherwise it could write state into the tmpfs upper before persistence is wired up and lose it on reboot.

Three services currently use this pattern:

| Service | LARCHCONF dir | Bind target | Drop-in |
|---|---|---|---|
| NetworkManager | `nm-system-connections/` | `/etc/NetworkManager/system-connections` | `NetworkManager.service.d/10-persist-connections.conf` |
| bluetoothd | `bluetooth/` | `/var/lib/bluetooth` | `bluetooth.service.d/10-persist-devices.conf` |
| cupsd | `cups/` | `/etc/cups/larch-state` | `cups.service.d/10-persist-printers.conf` |

Notes:
- **NetworkManager**: only the **connection profiles** persist (enough to auto-reconnect). NM's volatile state in `/var/lib/NetworkManager/` (DHCP leases, seen-BSSID timestamps) still resets each boot — harmless for an immutable system. **VPN configurations persist for free** — GNOME/NetworkManager VPN connections are stored as keyfiles in the same `system-connections/` directory, so the bind mount covers them too (VPNs needing an out-of-tree plugin still require that plugin in the squashfs).
- **Bluetooth**: `/var/lib/bluetooth` holds per-adapter pairing keys and device info; bluez doesn't ship this directory by default, hence `x-systemd.mkdir` on the fstab line.
- **Printing (CUPS)**: only queue *state* persists — `printers.conf`, `classes.conf`, `subscriptions.conf`, and `ppd/` — not the daemon's static config (`cupsd.conf`, `cups-files.conf`, `mime.types`, `snmp.conf`, `client.conf`), which should always come fresh from the image on upgrade. `scripts/setup-chroot.sh` symlinks those four state paths to `larch-state/...` inside `/etc/cups/`, and LARCHCONF's `cups/` directory is bind-mounted onto `/etc/cups/larch-state` (not directly onto `/etc/cups`) so the daemon config stays image-owned. GNOME Settings' Printers panel talks to cupsd via `cups-pk-helper`'s polkit actions (`org.opensuse.cupspkhelper.mechanism.*`); since root is locked and there's no admin/sudo group, `rootfs-overlay/etc/polkit-1/rules.d/99-larch-cups.rules` grants those to the active local session, mirroring `99-larch-flatpak.rules`.
- **Adding future persistent config**: follow the same three-part pattern above. If the service's state files aren't isolated to one directory (like CUPS), symlink them into a dedicated subdirectory in `scripts/setup-chroot.sh` (after the package installs, so it isn't clobbered by dpkg) rather than persisting the whole config tree.
- Rebuild after changing this: stage 3 (overlay drop-ins) + stage 4 (setup-chroot.sh changes, e.g. CUPS symlinks) + stage 8 (installer). Note the cached rootfs has apt stripped, so a drop-in-only change should use `--only 3` then `--stage 6` instead of `--stage 3`, to avoid the failing chroot-configure stage.

### Bootloader configs

| File | Purpose |
|---|---|
| `bootloader/grub.cfg` | Live ISO boot menu (GRUB2, ISO9660); boots `vmlinuz` + `installer-initramfs.img` |
| `bootloader/loader.conf` + `bootloader/entries/larch.conf` | systemd-boot for installed disk (FAT32 EFI partition); references `/larch-os/vmlinuz` and `/larch-os/initramfs.img` |

GRUB is only for booting the ISO, and only in **UEFI mode**. The ISO carries no BIOS/legacy boot path; stage 10 pins `grub-mkrescue -d /usr/lib/grub/x86_64-efi`. `grub-mkrescue` requires `grub.cfg` at `/boot/grub/grub.cfg` — this path cannot be changed.

### Disk layout (installed)

```
Partition 1 — FAT32, 3 GiB, label LARCHOS
  EFI/BOOT/BOOTX64.EFI      (systemd-boot EFI binary)
  loader/loader.conf
  loader/entries/larch.conf
  larch-os/vmlinuz
  larch-os/initramfs.img    (tiny OS initramfs — busybox + modules + init, no squashfs)
  larch-os/rootfs.squashfs  (OS root filesystem, loop-mounted at boot)
  larch-os/hostname
  larch-os/hosts
  larch-os/username
  larch-os/machine-id
  larch-os/fstab

Partition 2 — ext4, 512 MiB, label LARCHCONF   (mounted at /etc/larch-conf)
  accounts/passwd, shadow   (user account; read by OS init, written back by larch-persist-accounts)
  timezone                  (zone name, e.g. Europe/Berlin; read by OS init, written back by larch-persist-timezone)
  nm-system-connections/    (bind-mounted over /etc/NetworkManager/system-connections)
  bluetooth/                (bind-mounted over /var/lib/bluetooth)
  cups/                     (bind-mounted over /etc/cups/larch-state)

Partition 3 — ext4, remainder, label LARCHHOME   (mounted at /home)
  <username>/               (the user's home, seeded from /etc/skel at install time; persistent)
```

## Key files and their roles

| File | Role |
|---|---|
| `docker-entrypoint.sh` | The build: orchestrates all 10 stages inside the privileged builder container. Runs at `docker run` time (the container ENTRYPOINT), not during `docker build` |
| `docker-build.sh` | Host wrapper: builds the `larch-os-builder` image, then runs it `--privileged` with `work/` and `output/` bind-mounted; forwards `--stage`/`--only`/`--clean`/`--dev`/`--shell` |
| `Dockerfile` | Builder image (`debian:trixie-slim`) with all build tools; `ENTRYPOINT` is `docker-entrypoint.sh` |
| `scripts/setup-chroot.sh` | Installs packages, creates default user `larch` (password `larch`), enables GDM/NetworkManager/PipeWire, adds Flathub remote, configures polkit for Flatpak |
| `scripts/clean-rootfs.sh` | Purges apt/dpkg and dev artifacts from rootfs before squashfs |
| `config/packages.list` | Packages installed by `setup-chroot.sh` (comments and blank lines stripped) |
| `config/remove.list` | Packages purged by `clean-rootfs.sh` after configuration |
| `initramfs/os/init` | OS initramfs init — busybox sh PID 1 on the **installed disk**; finds LARCHOS, loop-mounts `rootfs.squashfs`, builds overlayfs, applies config, `switch_root`s to systemd |
| `initramfs/os/modules.list` | Modules for the OS initramfs (squashfs/overlay + storage/FAT drivers to find LARCHOS and mount the squashfs) |
| `initramfs/installer/init` | Installer initramfs init — busybox sh PID 1 on the **ISO**; finds `LABEL=LARCHISO`, mounts the ISO at `/mnt/iso`, then `exec`s `larch-install` |
| `initramfs/modules.list` | Shared kernel module list used by both initramfs builds |
| `installer/install.sh` | The installer, bundled into the installer initramfs as `/usr/sbin/larch-install`. Prompts, partitions, copies OS files to LARCHOS, seeds home, reboots |
| `rootfs-overlay/` | Files copied verbatim into rootfs at stage 3; mirror the target path |

## Common customisation patterns

- **Add a package:** edit `config/packages.list`, re-run from stage 4
- **Add a system config file:** drop it in `rootfs-overlay/` mirroring its final path, re-run from stage 3
- **Add/remove a kernel module in the OS initramfs:** edit `initramfs/modules.list` and the `load_mod` calls in `initramfs/os/init`, re-run from **stage 7**
- **Change the installer behaviour:** edit `installer/install.sh`, re-run from **stage 8**
- **Change the default live user or password:** edit `scripts/setup-chroot.sh`, re-run from stage 4
- **Enable autologin:** edit `rootfs-overlay/etc/gdm3/custom.conf`, re-run from stage 3

## Important constraints

- **`set -euo pipefail`** is used throughout `docker-entrypoint.sh` — any unhandled command failure aborts the build
- **Both init scripts use `set -e`** and run as PID 1; unhandled errors call `emergency_shell` (busybox sh on `/dev/console`); any command that may legitimately produce no output (e.g. `grep`, `ls`) must have `|| true`
- **`.ko.xz` modules** (Trixie default): busybox `modprobe` cannot load XZ-compressed modules; `populate_initramfs_tree()` always decompresses them and patches `modules.dep` — do not skip this when adding modules
- **`rootfs.squashfs` is a separate file on the LARCHOS partition** (`larch-os/rootfs.squashfs`), not embedded in `initramfs.img`. The OS init loop-mounts it from LARCHOS; LARCHOS therefore cannot be unmounted after boot (the loop device holds it open as a detached mount).
- **`work/` contents are root-owned** (created inside the privileged container); use `./docker-build.sh --clean` rather than `rm -rf work/` to avoid permission errors
- **Output ISO path** is controlled by `$LARCH_OUTPUT_ISO` env var (defaults to `$SCRIPT_DIR/larch-os.iso`; Docker sets it to `/output/larch-os.iso`)
- **ISO volume label is `LARCHISO`** (the installer initramfs finds the USB medium by this label); the installed FAT32 partition label is `LARCHOS` — keep these distinct
