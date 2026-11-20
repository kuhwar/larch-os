# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**larch-os** is a minimal, immutable ("atomic") Linux distribution built from Fedora packages (the release in `system/config/fedora-release`, plus RPM Fusion for the NVIDIA and Broadcom drivers), offered with several desktop environments (GNOME Wayland today; KDE, COSMIC, … as `system/desktops/<desktop>/` are added). The OS root is a read-only SquashFS image (`sys.squashfs`, one per desktop); `/etc` is an overlay and `/var/{lib,log,cache,spool}` are bind mounts, both persisting on a config partition, `/home` is its own partition. Applications are delivered exclusively as AppImages, through **Sawmill**, the default app store. There is no running package manager and no Flatpak.

The repo produces **two separate releases**, each built from its own directory:

1. **The installer** (`installer/`) → `larch-installer.iso`. It holds *only* the installer — GRUB, the system's (Fedora) kernel and `installer.initramfs` (every storage, input and network driver plus firmware, the tools, `install.sh`). **No system files.** The installer asks full name and password, gets online, lists the releases, one entry per desktop (`larch-gnome-v0.1.5`, `larch-cosmic-v0.1.5`, `larch-gnome-v0.1.4`, …), partitions the disk and **downloads the chosen one** onto it.
2. **The system** (`system/`) → a set of files published as a GitHub release (tags `v*`):
   - `sys-<desktop>.squashfs` — one OS root per desktop, all built from one base (installed as `LARCHSYS:/sys.squashfs`)
   - `vmlinuz` — Fedora's kernel (`kernel-core`)
   - `sys.initramfs` — boots the system: mounts `sys.squashfs` as `/`, LARCHCONF, the `/etc` overlay and the `/var` binds, then `switch_root`s to systemd
   - `updater.initramfs` — the "Manage LARCH" boot entry: same drivers as the installer; a welcome menu — **Update LARCH**, **Manage users**, **Reset LARCH OS**, **Boot into EFI setup** (see "Manage LARCH" below). Update LARCH shows the same menu (last 5 releases × desktops) and replaces the system files. Picking another desktop **switches desktop**. No partitioning; LARCHHOME and LARCHCONF untouched, even on a desktop switch (see "Desktop switch").
   - `BOOTX64.EFI` (systemd-boot) and `loader.tar` (`loader.conf` + the boot entries) — shared by every desktop; the images don't carry a bootloader
   - `SHA256SUMS`

`shared/` holds what both use: the initramfs build helpers (`shared/build-lib.sh`) and the busybox-sh runtime libraries (`shared/lib/`: `ui.sh` dialog helpers, `hw.sh` drivers/partitions, `net.sh` wired DHCP/Wi-Fi, `release.sh` release listing/download/check/install, `conf.sh` LARCHCONF's layers, `account.sh` the full-name/password prompts and `derive_username`).

## Project goal & design principles

The end product is an **atomic, image-based distro** where the entire OS is one immutable unit and upgrades happen by swapping that unit — never by mutating files in place.

**Boot-to-install flow.** Booting `larch-installer.iso` drops the user straight into the installer script (no live desktop). The installer collects exactly three things:

1. full name
2. password
3. target disk

(and, if there is no cable, a Wi-Fi network + password — never stored — and the desktop/version entry from the release menu, which starts on the newest GNOME release). Network and releases are looked up **before** the disk question, so no network means nothing is erased.

The **username** is not asked for: it is derived from the full name (`shared/lib/account.sh` `derive_username`) — common accented Latin letters folded to ASCII, lowercased, everything but `a-z0-9` dropped, leading digits stripped, capped at 30 chars (`Jane Doe` → `janedoe`; non-Latin-only names → `user`). If it collides with a name the image's system accounts/groups already use (`root`, `man`, `gdm`, … — listed at build time into the installer's `/usr/lib/larch/reserved-names`, and checked again against the downloaded image's `/etc/passwd`/`group`), a numeric suffix is appended (`root1`). The full name as typed becomes the passwd GECOS field, i.e. GNOME's display name.

The **hostname** is not asked for either: it is derived as `<username>-<brand>-<device type>` (e.g. `janedoe-lenovo-laptop`; brand from the SMBIOS `sys_vendor`, falling back to `board_vendor`, shortened — `ASUSTeK COMPUTER INC.` → `asus` — and omitted if it is a placeholder like `To be filled by O.E.M.`; `laptop`/`desktop`/`tablet`/`pc` from the SMBIOS chassis type in `/sys/class/dmi/id/chassis_type`). It is fixed after install — `system/rootfs-overlay/etc/polkit-1/rules.d/99-larch-hostname.rules` denies all `org.freedesktop.hostname1.set-*` actions.

**Atomic upgrade model.** An upgrade replaces `sys.squashfs` on LARCHSYS and the kernel + both initramfs + systemd-boot on LARCHEFI with a release's files, never touching LARCHHOME or LARCHCONF (desktop switches included). `/etc/fstab` is static in the image (partitions found by label), so an upgrade brings its new mounts along.

**Deliberately minimal, locked-down configuration.** The system favors zero-decision defaults over flexibility (paths below are under `system/`):

- **Networking is always DHCP** with DNS provided by DHCP. No network configuration UI/flow.
- **Users are managed only from the boot menu.** Users (including the one created at install) are added/deleted only through **Manage LARCH → Manage users** (`system/updater/manage.sh`), never from the running system. `rootfs-overlay/etc/polkit-1/rules.d/99-larch-users.rules` denies `org.freedesktop.accounts.user-administration` and `org.gnome.controlcenter.user-accounts.administration` (add/delete users, account type, autologin in GNOME Settings → Users); the user can still change their own password, name and avatar (`change-own-*` actions).
- **No remote shell.** No SSH server ships in the image (only the client, `openssh-clients`, which `git-core` requires), and `rootfs-overlay/etc/polkit-1/rules.d/99-larch-ssh.rules` denies `org.gnome.controlcenter.remote-login-helper`, so GNOME Settings → System → Secure Shell can never enable `ssh.service`. The row itself stays visible (it is compiled into gnome-control-center with no visibility hook).
- **Graphical login only.** No text consoles: `rootfs-overlay/etc/systemd/logind.conf.d/10-larch-no-vt.conf` sets `NAutoVTs=0`/`ReserveVT=0`, and `getty@tty1`/`autovt@` are masked via `/dev/null` symlinks in `rootfs-overlay/etc/systemd/system/`. No cron either (none is installed; systemd timers cover scheduling).
- **Minimal setuid set.** `config/remove-files.list` deletes `su`, `pkexec`, `chfn`, `chsh`, `gpasswd`, `newgrp`/`sg`, `chage`, `pam_timestamp_check`, `lockdev` (and their PAM files) and `gst-ptp-helper`; `remove.list` takes out GRUB (`grub2-set-bootflag`); `clean-rootfs.sh` strips setuid/setgid from `mount`/`umount`, `mount.cifs`, `wall`/`write` and prints what is left to the build log. What stays privileged: `passwd`, `unix_chkpwd`, `polkit-agent-helper-1`, `fusermount3`, `newuidmap`/`newgidmap` (file capabilities), `nvidia-modprobe`.
- **Core desktop only:** base GNOME (Wayland), **Nautilus** as the file manager, and **Sawmill** (github.com/projectlarch/sawmill) as the app manager — no terminal. Nothing beyond the minimal desktop ships in the core image. Sawmill is the latest release's `Sawmill-x86_64.AppImage`, fetched by system stage 3 (`install_sawmill` in `system/build.sh`: GitHub's API, checked against the asset's sha256 digest, cached in `work/sawmill/<tag>/`) into the base at `/opt/sawmill/Sawmill.AppImage` (+ `/opt/sawmill/version`, the icon `/usr/share/icons/hicolor/512x512/apps/io.sawmill.Store.png`); its launcher, for every user and desktop, is `rootfs-overlay/usr/share/applications/io.sawmill.Store.desktop`. A newer Sawmill reaches users with the next system release (it can't update itself in the read-only `/opt`).
- **No package manager, no Flatpak.** Software is installed only as AppImages, via **Sawmill** (the default app store; apps in `~/.local/share/sawmill/`) or downloaded by hand into `/home`. The base OS cannot be modified by the user; only `/home` changes. The image ships `fuse-libs` (the classic type-2 runtime's `libfuse.so.2`), fuse3's setuid `fusermount3` and `xdg-desktop-portal` (+ the desktop's backend) for AppImage apps' file choosers and screen sharing. Don't add Flatpak, Flathub or another app-delivery channel. **Rootless containers** (Podman) are user-installed too — a static build under `~/.local`; the image only ships `newuidmap`/`newgidmap` (from `shadow-utils`, with file capabilities — they can't live in `/home`) so the user's `/etc/subuid`/`/etc/subgid` range can be mapped. Container root is the user's own UID, never host root.

When implementing features, default to the most minimal, opinionated, immutable option consistent with these principles. Anything that would let the user mutate the base OS, manage users from the running system, or hand-configure networking runs against the project's intent.

## Repository layout

```
docker-build.sh, docker-entrypoint.sh, Dockerfile, Makefile, test-qemu.sh, test-auto.sh
tools/qmp.py            QMP client for test-auto.sh (keystrokes, screenshots)
shared/
  build-lib.sh          initramfs assembly: busybox tree, kmod, module sets, firmware, tools, packing
  lib/{ui,hw,net,release,conf,account}.sh   runtime libs in every initramfs, at /usr/lib/larch/
  udhcpc.script
system/
  build.sh              the system build (9 stages) → output/system/
  config/               packages.list, akmods.list, remove.list, remove-files.list, squashfs.exclude
                        (base lists — no desktop packages), fedora-release (the Fedora release number)
  rootfs-overlay/       base files copied verbatim into the base rootfs (stage 3)
  scripts/              setup-chroot.sh (base, stage 4), setup-desktop.sh + clean-rootfs.sh (per desktop, stage 5) — run
                        inside the chroot; they only configure: every package is installed/removed by the builder
  desktops/<desktop>/   packages.list (required), setup.sh (must enable a display manager),
                        rootfs-overlay/, remove.list, remove-files.list (optional, appended to the base's),
                        launcher.list (optional: the only .desktop entries shown in the app grid)
                        e.g. desktops/gnome/: GNOME + GDM, gdm/custom.conf, gschema override (dash: Files + Sawmill), launcher.list
  bootloader/           loader.conf + entries/ — published as the release file loader.tar (stage 9)
  initramfs/sys/init    sys.initramfs PID 1
  initramfs/updater/init  updater.initramfs PID 1
  updater/update.sh     the Manage LARCH menu + updater (/usr/sbin/larch-update)
  updater/manage.sh     its users / reset / EFI-setup actions (/usr/lib/larch/manage.sh)
installer/
  build.sh              the installer build (4 stages) → output/larch-installer.iso
  grub.cfg              ISO boot menu
  initramfs/init        installer.initramfs PID 1
  install.sh, lib/      the installer (/usr/sbin/larch-install) and its helpers
```

## Build commands

**Everything is built only inside the privileged Docker builder.** The builds need `chroot`, `mount --bind`, and `mknod`, none of which are available to an unprivileged `docker build`, so they run at `docker run --privileged` time via `./docker-build.sh` (the container ENTRYPOINT `docker-entrypoint.sh` dispatches to `system/build.sh` / `installer/build.sh`), never as Dockerfile `RUN` steps.

```bash
./docker-build.sh                      # both: output/system/* and output/larch-installer.iso
./docker-build.sh system               # system release files → output/system/
./docker-build.sh installer            # installer ISO (needs the base work/rootfs, system stages 2-4)
./docker-build.sh system --stage 6     # resume from a stage (work/ is bind-mounted)
./docker-build.sh installer --only 2   # exactly one stage
./docker-build.sh system --to 4        # stop after a stage (4 = the base; CI: what the installer needs)
./docker-build.sh system --desktop gnome   # only some desktops (repeatable; or LARCH_DESKTOPS="gnome kde")
./docker-build.sh --dev ...            # bind-mount the source
./docker-build.sh --shell              # shell in the builder
./docker-build.sh --clean              # delete output/ and work/ (root-owned, so via Docker)
make all | system | installer | clean | test-qemu | test-qemu-local
```

`LARCH_VERSION` (CI sets the tag) is stamped into the image as `/usr/lib/larch/version`, copied to `LARCHSYS:/version` on install/update and shown by the updater; local builds get `dev-<timestamp>`.

### Incremental rebuild shortcuts

| Changed | Command |
|---|---|
| `system/rootfs-overlay/`, a new Sawmill release | `./docker-build.sh system --stage 3` |
| `system/bootloader/` | `./docker-build.sh system --stage 9` |
| `system/desktops/<desktop>/*`, `setup-desktop.sh` | `./docker-build.sh system --stage 5 [--desktop <desktop>]` |
| `system/config/packages.list` or `system/scripts/setup-chroot.sh` | `./docker-build.sh system --stage 4` |
| `clean-rootfs.sh`, `remove.list`, `remove-files.list` | `./docker-build.sh system --stage 5` |
| rootfs content / `squashfs.exclude` | `./docker-build.sh system --stage 6` |
| `system/initramfs/sys/`, `shared/lib/hw.sh` | `./docker-build.sh system --stage 7` |
| `system/initramfs/updater/`, `system/updater/`, `shared/lib/` | `./docker-build.sh system --stage 8` |
| `installer/install.sh`, `installer/lib/`, `installer/initramfs/`, `shared/lib/` | `./docker-build.sh installer` |
| `installer/grub.cfg` | `./docker-build.sh installer --stage 3` |

Stage 9 (vmlinuz, `BOOTX64.EFI`, `loader.tar`, `SHA256SUMS`) must follow any of stages 6–8 for a consistent `output/system/`; it only includes the desktops of this run and deletes other `sys-*.squashfs` (they may be for another kernel). The base (`work/rootfs`) keeps apt — stage 5 cleans the per-desktop copies in `work/desktops/<desktop>/` — so any stage can be re-run.

### Test in QEMU

```bash
./test-qemu.sh          # ISO + 20G qcow2 disk, UEFI; installs if the disk is blank, else boots it
                        # (rm work/test-disk.img to reinstall). Installer/updater download from GitHub.
./test-qemu.sh --local  # same, but serves output/system/ on 127.0.0.1:8088 and passes
                        # http://10.0.2.2:8088 as QEMU fw_cfg opt/larch/source → offered as release "local"
```

**Unattended:** `./test-auto.sh` (`make test-auto`) does a fresh install of the local build on a blank disk and its first boot with no window: it serves `output/system/` like `--local`, answers the installer through QEMU's QMP socket (`tools/qmp.py`: keystrokes, screenshots), boots the installed system, logs in, powers off cleanly, reads the guest journal off LARCHCONF (`sfdisk`/`debugfs` from `work/rootfs`, so the host needs neither) and **exits 1 if anything logged an error before shutdown** other than `KNOWN_ERRORS` (the kernel's TDX line). Screenshots of every step (`i1-name` … `i5-complete`, `b1-login`, `b2-desktop`) and the journal go to `work/autotest/`; `./test-auto.sh boot` boots that disk again. ≈ 8 min, needs KVM. Run it after any change to the packages, the cleanup or the boot path. It needs a complete local build (`output/system/` and the ISO); with an empty `work/` the `--stage N` shortcuts can't run, so do a full `./docker-build.sh` first. Read the journal on the host with `journalctl -D work/autotest/journal/journal -p warning`. Warnings that are expected at login: units gsd tries to stop that aren't installed (`orca`, `rygel`, `gnome-user-share-webdav`), USBGuard/`bolt` not activatable, no BlueZ/backlight in the VM, `accounts-daemon` `/etc/tcb`, and `nvidia-powerd`'s `Allocate Root client failed` (info level, no NVIDIA GPU).

`test-qemu.sh` adds a USB keyboard: OVMF ignores QEMU's PS/2 keyboard, so only with it does holding Space reach systemd-boot's hidden menu (Manage LARCH). The same goes for QMP `send-key` (it reaches the newest keyboard). Busybox `od -j` doesn't skip on efivarfs files — read the whole variable.

QEMU comes from host packages (`sudo make install-deps`) or a QEMU AppImage (`$QEMU_APPIMAGE`, a `qemu-system-x86_64` symlinked to one, or `~/Applications/*QEMU*.AppImage`; edk2's UEFI code is copied to `work/` and mapped as pflash). Extra args go to qemu. On real hardware the same override is the kernel argument `larch.source=<url>` (press `e` in GRUB / systemd-boot).

## Architecture

### System build (`system/build.sh`)

1. **check-deps**
2. **bootstrap** — `filesystem` + `generic-release` into `work/rootfs/` (kernel-install's plugins are first linked to `/dev/null` in `/etc/kernel/install.d/`, except `50-depmod`: no dracut, no GRUB/BLS entries, the kernel stays at `/usr/lib/modules/<ver>/vmlinuz`); skipped if `work/rootfs/usr/` exists.
   **Every package is installed by the builder's dnf** (`dnf_root`: `--installroot`, the builder's Fedora + RPM Fusion repos via `--use-host-config`, `install_weak_deps=False`, `tsflags=nodocs`, cache in `work/dnf-cache`), so neither dnf nor rpm's database ever needs removing from a running image. The builder (`Dockerfile`) must be the same Fedora release as `config/fedora-release` (checked at stage 1).
3. **base-overlay** — `copy_overlay rootfs-overlay` (`cp -a` + `chmod go-w`), then `install_sawmill` (the latest Sawmill AppImage → `/opt/sawmill/`; needs network)
4. **base-configure** — bind-mounts proc/sys/dev (`/dev` with `--rbind` — under rootless Podman a plain `--bind` exposes placeholder files instead of device nodes; unmounted with `umount -Rl`, never `-f`, which rootless Podman refuses, and a surviving mount is fatal), installs `packages.list`, then the **kmods**: for each `akmods.list` line, `akmodsbuild` (as the `akmods` user) compiles the kmod RPM **in the builder** against `kernel-devel` of the rootfs's exact kernel (cached in `work/kmods/` until the kernel or akmod changes), and the RPMs go into the rootfs with the userspace packages on that line (NVIDIA **580xx** — the last branch for Pascal — and Broadcom `wl`); no compiler or headers ever enter the image. Then `scripts/setup-chroot.sh` (configuration only: authselect `local`, the default user, services, Plymouth, NetworkManager, avahi, no SELinux config, the iwlwifi firmware trim — here, so the initramfs firmware is trimmed too), and the overlay copied again. The base is never stripped.
5. **desktops** — per desktop: `rsync -aHAX --delete` the base → `work/desktops/<desktop>/` (excluding `/proc /sys /dev /run` contents); dnf installs the desktop's `packages.list` (`--exclude=kernel*`); `scripts/setup-desktop.sh` runs its `setup.sh` and requires a `display-manager.service`; then the base's and the desktop's `rootfs-overlay/`. Then stripping, from the builder: a **shared-library guard** records every `DT_NEEDED` soname (builder's `readelf`); `rpm -e --nodeps --noscripts` of the base + desktop `remove.list` matches; `dnf autoremove` (orphans); `clean-rootfs.sh` in the chroot (remove-files.list, setuid, the `launcher.list` allow-list — every other `.desktop` gets `NoDisplay=true` —, `dconf update`, schemas, the hicolor icon cache, `systemd-update-done` last); then the guard fails the build if a soname that resolved before no longer does for a file still in the image.
6. **make-squashfs** — per desktop: empty `/etc/machine-id`, `/usr/lib/larch/version` and `/usr/lib/larch/desktop`, the image root's mode 555 (systemd's `tmpfiles.d/root.conf` would otherwise try to chmod the read-only `/` at every boot), `mksquashfs … -comp zstd -Xcompression-level 19 -ef config/squashfs.exclude` → `output/system/sys-<desktop>.squashfs` (`/boot` and `usr/lib/modules/*/vmlinuz` excluded: the kernel ships separately)
7. **sys-initramfs** — `MODS_BASE` + `MODS_DISK` + `MODS_INPUT` (+ their firmware), `e2fsck` → `sys.initramfs`
8. **updater-initramfs** — also `MODS_NET` (same drivers as the installer) + firmware, curl/wpa_supplicant/udhcpc, dialog, `update.sh` + `manage.sh` → `updater.initramfs`
9. **release-files** — `vmlinuz` from the base's `/usr/lib/modules/<ver>/vmlinuz`, `BOOTX64.EFI` (the base's `systemd-bootx64.efi` from `systemd-boot-unsigned`; `remove.list` takes it out of the images), `loader.tar` from `bootloader/`, a check that every image has modules for that kernel, `SHA256SUMS`

### Installer build (`installer/build.sh`)

Needs the base `work/rootfs` (system stages 2–4). 1 **check-deps** · 2 **installer-initramfs** (same modules/firmware/network/dialog as the updater, plus `sfdisk wipefs mkfs.fat mkfs.ext4 e2fsck openssl` + OpenSSL provider modules, `install.sh`, `installer/lib/*`, `reserved-names`) · 3 **assemble-iso** (`/vmlinuz`, `/installer.initramfs`, `/boot/grub/grub.cfg`) · 4 **make-iso** (`grub-mkrescue -d /usr/lib/grub/x86_64-efi … -volid LARCHISO`: **UEFI-only**).

### How an initramfs is built (`shared/build-lib.sh`)

- `init_initramfs_tree`: busybox from the rootfs with **all** its applets linked in `/bin`, kmod's `modprobe` at `/usr/sbin/modprobe`, the init, `shared/lib/*.sh` → `/usr/lib/larch/`, `/etc/mtab` → `/proc/mounts`.
- `bundle_modules <dir> <firmware 0|1> <regex>…`: every module whose `modules.dep` path matches, with its dependencies, **kept compressed** (`.ko.xz`; kmod loads them, busybox's modprobe can't; the kmods live in `extra/`), all `modules.*` indexes, the image's `modprobe.d`; with firmware, everything the modules declare via `modinfo -F firmware` plus regulatory.db/brcm extras. Module sets: `MODS_BASE` (squashfs, overlay, ext4, fat/nls, isofs, efivarfs, crypto, lib, qemu_fw_cfg), `MODS_DISK` (**every** disk-driver directory of the larch OS kernel: ata, block, cdrom, md, memstick, message, mmc, nvdimm, nvme, scsi, ufs, virtio, hv, xen, firewire, thunderbolt, pci/controller, usb host/storage), `MODS_INPUT` (hid, input, i2c, mfd, pinctrl), `MODS_NET` (all of drivers/net, wireless stacks, rfkill, packet, wl). The installer and updater carry the identical set (`MODS_DISK` + `MODS_NET`, with firmware); sys.initramfs the same `MODS_DISK` (with firmware), no network. Don't hand-pick drivers out of these directories.
- `copy_bin_with_libs`: a rootfs binary + its libraries via `chroot ldd`. Busybox's shell runs applets before PATH, so call copied tools that shadow an applet by absolute path (`/usr/sbin/modprobe`, `/usr/sbin/e2fsck`).
- Every initramfs is built for the rootfs's kernel, so it only works with that release's `vmlinuz` — `hw.sh load_drivers` refuses to run otherwise.

### Disk layout (installed)

```
1. LARCHEFI  — FAT32, 1 GiB
     EFI/BOOT/BOOTX64.EFI          systemd-boot (the release file BOOTX64.EFI)
     loader/loader.conf, loader/entries/larch{,-debug,-update}.conf   (from the release file loader.tar)
     larch-os/vmlinuz, larch-os/sys.initramfs, larch-os/updater.initramfs
2. LARCHSYS  — ext4, 4 GiB, label LARCHSYS
     sys.squashfs                  the OS root of the installed desktop (loop-mounted read-only)
     version, desktop              release tag and desktop of the installed system
     .staging/                     only while an update downloads (next release's files)
3. LARCHCONF — ext4, 1 GiB, mounted at /conf
     etc/ + etc-work/              upper/work of the /etc overlay (identity files written by the installer)
     var/{lib,log,cache,spool}     bind-mounted on /var/… (empty at install; sys/init adds the image's directory skeleton)
4. LARCHHOME — ext4, remainder, /home   (/home/<username>, seeded from the image's /etc/skel)
```

Partitions are found by **GPT partition name** (`PARTNAME=` in `/sys/class/block/*/uevent` — no udev in the initramfs); LARCHCONF/LARCHEFI must be on the same disk as LARCHSYS. 1 GiB LARCHEFI and 4 GiB LARCHSYS leave room for a second copy of every file, since updates copy beside the old ones.

### Boot flow

**Installer ISO:** GRUB → `/vmlinuz` + `/installer.initramfs` → `installer/initramfs/init` → `install.sh`: `load_drivers` → full name/password → `net_up` → `lookup_releases`/`choose_release` (menu of `larch-<desktop>-<tag>`, starting on `default_release`: newest non-pre-release GNOME) → disk picker (disks carrying the `LARCHISO` medium are left out) → confirm → wipe + 4 partitions → download into `LARCHSYS:/.staging`, verify against `SHA256SUMS` (re-read from disk) → `check_release` → rename `sys-<desktop>.squashfs` to `sys.squashfs`, `install_boot_files`, write `version`/`desktop` → from the image (still mounted by `check_release`): `seed_layers` (identity files into `LARCHCONF:/etc`, empty `/var` directory, the image's `/etc/.updated` stamp), seed home → reboot. A failed download after the wipe offers a retry.

**Installed system:** systemd-boot (`timeout menu-hidden`: no menu, the default `larch.conf` boots at once; holding a key such as Space while it starts shows the menu with the debug and "Manage LARCH" entries) → `larch-os/vmlinuz` + `larch-os/sys.initramfs` → `system/initramfs/sys/init`: load drivers (one coldplug pass, more while waiting for LARCHSYS) → mount LARCHSYS ext4 **ro** at `/run/larch/sys` → loop-mount `sys.squashfs` at `/sysroot` (dies with a hint to boot "Manage LARCH" → "Update LARCH" if it has no modules for the running kernel) → `e2fsck -p` + mount LARCHCONF at `/sysroot/conf` → overlay on `/sysroot/etc`, `mount_var` binds on `/sysroot/var/{lib,log,cache,spool}` → `mount --move` dev/proc/sys/run → `switch_root /sysroot /lib/systemd/systemd`. PID 1 thus starts with the final `/etc`: machine-id, hostname and units enabled at runtime are all visible (no kernel-command-line identity args).

**Manage LARCH:** systemd-boot → `larch-os/vmlinuz` + `larch-os/updater.initramfs` → `update.sh`: drivers → pick install (if several) → fsck + mount LARCHSYS rw and LARCHEFI → the welcome menu:

- **Manage users** (`manage.sh`): the installed system is opened as it runs — `sys.squashfs` loop-mounted, `/etc` overlaid and `/var`'s directories bind-mounted from LARCHCONF (`conf.sh` `OVL_OPTS`/`mount_var`, as `sys/init`), LARCHHOME at `/home`, `/dev /proc /sys /run /tmp` — and the image's own `useradd`/`chpasswd`/`userdel` run chrooted in it (so hashes use the image's PAM/login.defs method, as GNOME's password changes do, and groups/subuid ranges/`/etc/skel` are the system's; new UIDs are above every account and every `/home/*` owner, so a kept home never passes to a new user). Add: full name + password (`account.sh`), username derived with the existing users, groups and home names reserved, groups `audio,video,input` (the image placeholder's, never `wheel`), home mode 0750. Delete: the user's password checked with the image's `unix_chkpwd` (as root, NUL-terminated on stdin), then keep or delete the home (`userdel [-r]`) and the AccountsService entry. Any user can be deleted, the install's account included, except the last one (there is no root login).
- **Reset LARCH OS**: `rebuild_layers` (identity + all accounts, nothing else) and `swap_layers` → reboot. Not a literal wipe of LARCHCONF: that would lose the accounts.
- **Boot into EFI setup**: mount efivarfs, check bit 0 of `OsIndicationsSupported`, OR it into `OsIndications` (attributes `07 00 00 00` + 8 value bytes, one write), reboot.
- **Update LARCH**: `net_up` (once) → `choose_release` (Back returns to the welcome menu; installed entry marked, starting on the newest of the installed desktop; a different desktop is a **switch**, with a warning in the confirm dialog) → space check → download into `LARCHSYS:/.staging` + verify → `check_release` (squashfs magic, `ID=larchos`, the image's `/usr/lib/larch/desktop`, both initramfs and the image's modules for the same kernel, `BOOTX64.EFI` is an EFI program, `loader.tar` holds only `loader/loader.conf` + `loader/entries/*.conf`; both staged under `.staging/boot/`) → LARCHEFI space check → **commit**: `mv` the image to `sys.squashfs` (ext4 rename), `install_boot_files` (each file copied as `.new`, then renamed; stale entries removed) → write `version` and `desktop` → reboot. It never reads LARCHSYS for drivers, so it still works when the system files are broken. Between the two commit steps the image and kernel don't match and the system won't boot, but the old kernel+updater pair does — rerun "Manage LARCH" → "Update LARCH".

### Release listing (`shared/lib/release.sh`)

The releases come from `REPO=projectlarch/os` (`shared/lib/release.sh`); installers and updaters built before the move still ask for `kuhwar/larch-os` and only reach it through GitHub's transfer redirect (`curl -L`), so that old name must never be reused. GitHub's releases API JSON (no jq) is split at each release's own `"url":".../releases/<id>"`; a release counts only if it carries `vmlinuz`, `sys.initramfs`, `updater.initramfs`, `BOOTX64.EFI`, `loader.tar`, `SHA256SUMS` and at least one `sys-<desktop>.squashfs` (so installer releases and old-format releases — up to v0.5.1, whose bootloader was inside the image — are ignored); each image becomes one line/menu entry `larch-<desktop>-<tag>` in `$RUN/releases`. `larch.source=<url>` on the kernel command line or fw_cfg `opt/larch/source` replaces GitHub with a plain HTTP directory (entries `larch-<desktop>-local` from its `SHA256SUMS`, sizes unknown).

### `/etc` overlay and `/var` binds

- `/etc`: `lowerdir` = the image's `/etc`, `upperdir` = `/conf/etc`, mounted with `OVL_OPTS` = `index=off,metacopy=off,redirect_dir=off` (`shared/lib/conf.sh`; also in `fstab`): every update replaces the lower layer, so nothing in the upper layer may refer to a particular squashfs (`index` would refuse the mount after an update: "Stale file handle"). Rename-based writers (`passwd`, `usermod`, timedated, CUPS, …) just work and persist.
- `/var` is the image's, **read-only**, except `VAR_DIRS` (`lib log cache spool`): `conf.sh` `mount_var` bind-mounts `/conf/var/<dir>` on each, after `var_skeleton` has created there every directory and symlink of the image's `/var/<dir>` that is missing (numeric owner + mode, no files — packages' state dirs such as colord's or CUPS's spool, and a new release's new ones). Every service's state (NM, Bluetooth, AccountsService, CUPS jobs, journal capped at 64M by `journald.conf.d/10-larch.conf`, timers) persists there; image files in those directories (e.g. the journal catalog) are hidden. Anything that writes elsewhere in `/var` gets `EROFS` — a new writable `/var` directory must go into `VAR_DIRS` and `fstab`. `/var/.updated` is the image's, so `ConditionNeedsUpdate=/var` never holds (systemd-update-done ignores the `EROFS`); `systemd-journal-catalog-update` gets a drop-in to run on `/etc`'s stamp or a missing catalog.
- `system/rootfs-overlay/etc/fstab` lists `/conf` (pass 0 — sys.initramfs fscks it), the `/etc` overlay and the four `/var` binds although they're already mounted, so systemd orders their unmounting at shutdown; plus `/var/tmp` and `/media` tmpfs and `/home`. Mount points must exist in the image (`setup-chroot.sh` creates `/conf /media /var/tmp`) since nothing can be created on `/` at boot. `/etc/resolv.conf` is a symlink to `/run/NetworkManager/resolv.conf`.
- **Stamps:** the installer copies the image's `/etc/.updated` into the upper layer, so `ConditionNeedsUpdate=` services (systemd-sysusers, ldconfig, …) don't run on first boot but run once after each update (the new image's `/usr` is newer) and bring the upper layer up to date (e.g. a new release's system users).
- **Desktop switch**: LARCHCONF is **not touched** — like a version update, only LARCHSYS/LARCHEFI change, so accounts and every system setting carry over. The new image's system users/groups (e.g. another display manager's) are added on its first boot by `systemd-sysusers` (`ConditionNeedsUpdate=`, see "Stamps"). Leftovers of the old desktop in the upper layers (its display manager's config/state) are inert or shadow the new image like any drift (the known gap below); **Reset LARCH OS** is the clean slate. **Reset** (`shared/lib/conf.sh` `rebuild_layers`): new layers `conf/etc.new`/`var.new` — `etc.new` gets the current layer's `IDENTITY_FILES` verbatim (`hostname hosts machine-id passwd shadow group gshadow subuid subgid`, `cp -p`), `var.new` is empty (the skeleton is recreated at boot). Every account stays exactly as it is (no UID special case; the image's `larch:larch` placeholder never returns, the installer replaced it). No `.updated` stamps, so the `ConditionNeedsUpdate=` services (sysusers, ldconfig, …) run once on the next boot. `swap_layers` renames them in place; `sys/init` finishes a swap cut off between renames (`etc` missing + `etc.new` → rename; `var.new` without `etc.new` → swap `var`), so **always delete `var.new` before `etc.new`**.
- **Known gap:** any `/etc` file changed at runtime hides a newer image's version of it (drift); only what `ConditionNeedsUpdate=` services reconcile is updated. Writes outside `/etc`, `/var/{lib,log,cache,spool}`, `/home` and the tmpfs mounts get `EROFS`.

### Image trimming

Weak dependencies are never installed, so the lists name everything. `system/config/remove.list` removes rpm, systemd-boot, GRUB/grubby and nvidia-settings (pulled in by NVIDIA's packages), dracut and sudo; `desktops/gnome/remove.list` removes evolution-data-server and both WebKitGTKs (~250M; Fedora's gnome-shell requires them only for its calendar-event server and captive-portal window, which `desktops/gnome/remove-files.list` deletes with their D-Bus activation). `remove-files.list` deletes the package databases, NVIDIA's X.Org bits (its CUDA/OpenCL/NVENC/NVDEC/OptiX userspace stays: AppImages use the host's), `/usr/share/gir-1.0`, docs/licenses, setuid tools, Vulkan drivers for non-PC GPUs and firmware for routers/ARM SoCs/server NICs (`ti/` and `nxp/` kept deliberately); `setup-chroot.sh` drops every iwlwifi `.ucode.xz` except the highest API ≤ the kernel's maximum per chip (read via `modinfo`).

### Time, language, misc

**Swap is zram only** — no swap partition or file, so no hibernation: `zram-generator` with `rootfs-overlay/etc/systemd/zram-generator.conf` (zstd, half of RAM up to 8 GiB) and `sysctl.d/99-larch-zram.conf` (swappiness 180, page-cluster 0). Time and timezone are automatic: `chrony` (timedated finds it via `ntp-units.d`), and (GNOME) `desktops/gnome/rootfs-overlay/usr/share/glib-2.0/schemas/90_larch.gschema.override` turns on `automatic-timezone` and Location Services (gsd-datetime via geoclue). `99-larch-datetime.rules` lets the active local session call timedated; `99-larch-cups.rules` grants cups-pk-helper's actions. `99-larch-udisks.rules` grants udisks2's `open-device` (removable drives only, not `open-device-system`), so image-writer apps can write a USB stick. The image ships every locale precompiled (`glibc-all-langpacks`); the user's language/avatar persist in `/var/lib/AccountsService` on LARCHCONF's `/var/lib`.

### Clean boot (what the Fedora port had to fix)

The first boot of a fresh install logs no userspace error up to the login screen. Things that otherwise break it, all handled: `systemd-pam` (else no logind session → no user bus → GDM black screen), no `/etc/selinux/config` (`SELINUX=disabled` makes systemd hit the kernel's removed runtime-disable switch), `dconf update` at stage 5 (GDM's `/etc/dconf/db/gdm`), `rootfs-overlay/etc/tmpfiles.d/larch-resolv.conf` (an empty `/run/NetworkManager/resolv.conf` before NetworkManager starts, for avahi), avahi's `publish-resolv-conf-dns-servers=no`, systemd-oomd masked, the image root at mode 555, no gnome-keyring (GNOME 51 uses oo7; gnome-keyring's PAM module only logged errors). The one remaining kernel error, `virt/tdx: TDX not supported by the host platform`, is printed by the built-in TDX host code on every non-TDX Intel CPU (no parameter disables it); `loglevel=3` keeps it off the screen. Shutdown still logs refused D-Bus activations (GDM/gsd asking for services while they stop).

## Common customisation patterns

- **Add a package:** `system/config/packages.list` (a Fedora/RPM Fusion name; weak dependencies are never installed, so list what a package only recommends but you need), then `system --stage 4`. If the boot then logs a missing service or library, add that too — e.g. `systemd-pam` (no `pam_systemd` → no user bus → GDM black screen)
- **Out-of-tree kernel modules:** `system/config/akmods.list` (akmod + the userspace packages that require its kmod)
- **Move to a new Fedora release:** `system/config/fedora-release` and the `Dockerfile`'s `FROM` + RPM Fusion URLs, then `./docker-build.sh --clean` and a full build
- **Add a system config file:** drop it in `system/rootfs-overlay/` (every desktop) or `system/desktops/<desktop>/rootfs-overlay/` mirroring its final path, then `system --stage 3` / `--stage 5`. The overlay is copied over the packages' files, so don't put a replacement for a file a Fedora package already ships there unless it is meant to win (the old Debian `/etc/skel/.bashrc` silently replaced Fedora's).
- **Add a desktop:** `system/desktops/<name>/` (lowercase `[a-z0-9]`) with `packages.list` and a `setup.sh` that enables its display manager; the next system build ships `sys-<name>.squashfs` and the menus offer `larch-<name>-<tag>`
- **Need a driver in an initramfs:** widen the module-set regexes in `shared/build-lib.sh` (and the explicit list in `hw.sh load_drivers` if nothing autoloads it by modalias)
- **Change the installer:** `installer/install.sh` / `installer/lib/`, then `./docker-build.sh installer`
- **Change boot entries:** `system/bootloader/entries/` (published as `loader.tar`, installed by the installer and every update), then `system --stage 9`
- **Change the Manage LARCH menu:** `system/updater/update.sh` (menu, update) / `manage.sh` (users, reset, EFI setup), then `system --stage 8` + `--stage 9`
- **Change the default user or password:** `system/scripts/setup-chroot.sh`, then `system --stage 4`

## Important constraints

- **No automatic migration code by default.** There are no installs in real use yet, so the scripts carry no logic that converts an older install's LARCHCONF, LARCHSYS or LARCHEFI layout — that code would only pile up. When a change would leave existing installs in a state the new code doesn't handle (e.g. a different LARCHCONF layout), **stop and explain to the user**: what breaks or is left behind on an existing install, how it can be handled (usually **Manage LARCH → Reset LARCH OS**, which rebuilds LARCHCONF from the accounts; otherwise a reinstall), and whether an automated migration is worth implementing — then let the user decide before writing any.
- **`set -euo pipefail`** in the bash build scripts — any unhandled command failure aborts the build.
- **The init scripts run as PID 1** (busybox sh); `sys/init` uses `set -e` and calls `die` (message + rescue shell) on failures; the installer and updater inits only `setsid` their script and reboot if it returns. Any command that may legitimately fail must have `|| true` or an explicit check.
- **Kernel, sys.initramfs, updater.initramfs and the sys-<desktop>.squashfs images of one release belong together** (modules are built for one kernel). The installer and updater check this (`check_release`); never mix files across releases.
- **`work/` and `output/` contents are root-owned** (created inside the privileged container); use `./docker-build.sh --clean` rather than `rm -rf`.
- **Outputs** go to `$LARCH_OUTPUT_DIR` (default `output/`; Docker sets `/output`): `system/` and `larch-installer.iso`.
- **Labels:** the ISO volume is `LARCHISO`; the installed partitions are found by GPT name `LARCHEFI`/`LARCHSYS`/`LARCHCONF`/`LARCHHOME` (ext4/FAT labels match). Keep them distinct.
- **Releases:** system releases are tags `v*` (`.github/workflows/build-system.yml`), installer releases are tags `installer-v*` (`build-installer.yml`, which builds the base, system stages 1–4, first). One system release carries every desktop. Feature changes bump the minor version (`v0.8.1` → `v0.9.0`), fixes the patch. A system release does **not** need an installer release: the installer downloads whichever release is picked and installs that release's own kernel, initramfs and image (`/etc/skel` comes from the downloaded image too). Cut an installer release only when `installer/`, `shared/lib/` or `installer/grub.cfg` change behaviour, or when its kernel needs newer drivers/firmware for new hardware.
- Systems installed before this layout (squashfs written raw to LARCHSYS, no sys.initramfs) can't be updated to it — their updater looks for different release assets. They need one reinstall.
