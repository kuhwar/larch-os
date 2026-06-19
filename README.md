# larch-os

A minimal, immutable Linux distribution with a GNOME Wayland desktop and Flatpak-only application delivery.

## Design Principles

| Property | Implementation |
|---|---|
| Immutable OS root | SquashFS (read-only) + OverlayFS (tmpfs upper layer) |
| App delivery | Flatpak only — no package manager in the running system |
| Desktop | GNOME Shell (Wayland), Nautilus, GNOME Terminal |
| Boot | UEFI only — systemd-boot, no GRUB, no legacy BIOS |
| Output | Single `larch-os.iso` file |
| User data | Persists in a dedicated `/home` partition |

## Disk Layout (installed)

```
┌─────────────────────────────────────────────────────┐
│  GPT disk                                           │
├────────────────────────────┬────────────────────────┤
│  Partition 1               │  Partition 2           │
│  FAT32 · ~3 GiB            │  ext4 · rest of disk   │
│  label: LARCHOS            │  label: LARCHHOME      │
│                            │                        │
│  EFI/BOOT/BOOTX64.EFI      │  /home                 │
│  loader/                   │  (persistent)          │
│  boot/vmlinuz              │                        │
│  boot/initramfs.img        │                        │
│  live/rootfs.squashfs      │                        │
└────────────────────────────┴────────────────────────┘
```

The OS lives entirely in a compressed SquashFS image on the EFI partition. The root filesystem is physically read-only. An OverlayFS with a tmpfs upper layer makes `/etc`, `/var`, and `/tmp` writable at runtime — changes are discarded on reboot. Only `/home` is persistent.

## Boot Flow

```
UEFI firmware
  └─> EFI/BOOT/BOOTX64.EFI  (systemd-boot)
        └─> kernel + initramfs.img
              └─> initramfs/init:
                    1. Load kernel modules (squashfs, overlay, loop, vfat, ext4)
                    2. Find LARCHOS partition → mount FAT32
                    3. Loop-mount live/rootfs.squashfs (read-only)
                    4. Set up OverlayFS (tmpfs upper)
                    5. Find LARCHHOME partition → mount as /home
                    6. switch_root → systemd → GDM → GNOME Wayland
```

## Quick Start

### 1. Install build dependencies

```bash
make install-deps
# or manually:
sudo apt-get install debootstrap squashfs-tools xorriso mtools dosfstools \
                     gdisk systemd-boot ovmf qemu-system-x86 cpio
```

### 2. Build the ISO

```bash
make iso          # wrapper around ./docker-build.sh
# Output: output/larch-os.iso
```

The OS is built **only inside the privileged Docker builder** — there is no host-side
build script. The pipeline needs `chroot`/`mount --bind`/`mknod`, which are unavailable
to an unprivileged `docker build`, so it runs at `docker run --privileged` time.

The full build takes 20–40 minutes depending on network speed and CPU (the debootstrap and package installation stages are the slow parts).

### 3. Test in QEMU

```bash
make test-qemu
```

### 4. Install to disk (from live environment)

Boot the ISO, then open GNOME Terminal and run:

```bash
sudo larch-install
```

The installer will ask for the target disk, then create the two-partition layout and copy everything.

## Build Stages

The build runs in 9 stages (`docker-entrypoint.sh`). You can restart from any stage:

| Stage | Name | Description |
|---|---|---|
| 1 | check-deps | Verify host build tools |
| 2 | debootstrap | Create minimal Debian Bookworm rootfs |
| 3 | copy-overlay | Merge `rootfs-overlay/` into rootfs |
| 4 | chroot-configure | Install packages, configure system |
| 5 | clean-rootfs | Strip apt/dpkg from final image |
| 6 | make-squashfs | Compress rootfs → `rootfs.squashfs` |
| 7 | build-initramfs | Assemble custom cpio initramfs |
| 8 | assemble-iso | Copy all files into ISO tree |
| 9 | make-iso | Run grub-mkrescue → `larch-os.iso` (UEFI only) |

```bash
# Resume from stage 6 (e.g. after editing rootfs-overlay):
./docker-build.sh --stage 6

# Re-run only stage 7:
./docker-build.sh --only 7
```

## Repository Structure

```
larch-os/
├── docker-entrypoint.sh      Build pipeline (stages 1–9; runs in the builder container)
├── docker-build.sh           Host wrapper: builds + runs the privileged builder
├── Dockerfile                Builder image (all build tools)
├── Makefile                  Convenience targets (wrap ./docker-build.sh)
├── config/
│   ├── packages.list         Packages installed during build
│   └── remove.list           Packages stripped before squashfs
├── rootfs-overlay/           Files merged into rootfs
│   └── etc/
│       ├── os-release        Distro branding
│       ├── hostname
│       ├── fstab
│       ├── gdm3/custom.conf  GDM Wayland config
│       └── flatpak/          Flathub remote config
├── initramfs/
│   ├── init                  Custom PID-1 init script
│   └── modules.list          Kernel modules bundled into initramfs
├── bootloader/
│   ├── loader.conf           systemd-boot global config
│   └── entries/larch.conf    Boot entry (kernel cmdline)
├── scripts/
│   ├── setup-chroot.sh       Runs inside chroot: packages, users, services
│   └── clean-rootfs.sh       Strips package manager from final image
└── installer/
    └── install.sh            Disk installer (run from live environment)
```

## Customisation

### Adding packages to the base image

Edit `config/packages.list` and re-run from stage 4:
```bash
./docker-build.sh --stage 4
```

### Changing the default user

Edit `scripts/setup-chroot.sh` — search for `useradd larch`. Re-run from stage 4.

### Adding system configuration files

Drop files into `rootfs-overlay/` mirroring their destination path, e.g.:
```
rootfs-overlay/etc/environment   → /etc/environment in the image
rootfs-overlay/usr/share/wallpapers/my-bg.png → ...
```
Then re-run from stage 3.

### Enabling autologin

Edit `rootfs-overlay/etc/gdm3/custom.conf`:
```ini
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=larch
```

## Security Notes

- Root account is locked (`passwd -l root`)
- No SSH server installed by default
- Package manager is physically absent from the running system
- OS root resets to factory state on every reboot

## Requirements

| | Minimum | Recommended |
|---|---|---|
| RAM | 2 GB | 4 GB |
| Disk (installed) | 8 GB | 20 GB+ |
| CPU | x86-64 with SSE4.2 | x86-64 with KVM |
| Firmware | UEFI | UEFI |
| GPU | Any with VESA/VBIOS | Mesa-supported (Intel/AMD/virtio) |
