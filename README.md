# larch-os

A minimal, **immutable** Linux desktop. The whole operating system ships as a single
read-only image: you can't break it, and every reboot returns the system files to a
known-good state. You get a clean GNOME (Wayland) desktop, and you install apps as
[Flatpaks](https://flatpak.org/) from [Flathub](https://flathub.org/). Your files and
settings live in `/home` and are kept separate from the OS.

It is based on Debian Trixie and is intentionally simple: one user, automatic (DHCP)
networking, no package manager to fiddle with, no options to get lost in.

---

> ## ⚠️ Read this before installing
>
> - **The installer ERASES the entire target disk.** Every existing partition, OS,
>   and file on the disk you pick is destroyed. There is no dual-boot and no "install
>   alongside." Back up anything you care about first, and double-check which disk you
>   select.
>
> - **The installer needs an internet connection.** The installer ISO carries no copy of
>   the system: it downloads the latest Larch OS release during installation (about
>   1–2 GB), over a network cable or Wi-Fi.
>
> - **Updates are still young.** The **Update LARCH** boot-menu entry replaces the
>   system and keeps your settings and `/home`, but the format still changes between
>   releases. Keep backups. Systems installed before the current disk layout need one
>   full reinstall, which **wipes the disk — including your `/home`.**
>
> - **UEFI only.** The machine must boot in UEFI mode. Legacy BIOS is not supported.

---

## What you get

- A read-only OS image (SquashFS) — system files can't be modified and reset on reboot.
- Your choice of desktop — GNOME Shell on Wayland (with Files and Terminal) today, more to
  come — switchable later from the updater.
- Flathub preconfigured; install any app with the `flatpak` command.
- A persistent home directory on its own partition.
- A locked-down, zero-decision setup: one user account, DHCP networking, no root login,
  no SSH, no package manager.

## Requirements

| | Minimum | Recommended |
|---|---|---|
| Firmware | **UEFI** (Secure Boot off — see below) | UEFI |
| CPU | 64-bit x86 (x86-64) | x86-64 with KVM |
| RAM | 2 GB | 4 GB+ |
| Disk | 12 GB | 30 GB+ |
| Network | Cable or Wi-Fi (WPA2/WPA3 or open) for installing and updating | |
| GPU | Anything with a basic framebuffer | Intel / AMD / virtio (Mesa) |

**Secure Boot:** the boot images are not signed, so if your machine has Secure Boot
enabled you'll need to **disable it in firmware settings** before installing and booting.

## 1. Download

Grab the installer ISO from the newest `installer-v*` release on the
[**Releases**](https://github.com/kuhwar/larch-os/releases) page:

- `larch-installer.iso` and its checksum `larch-installer.iso.sha256`

(The `v*` releases are the system itself — the installer and the updater download
those for you.) Verify the download before writing it:

```bash
sha256sum -c larch-installer.iso.sha256
# larch-installer.iso: OK
```

## 2. Write it to a USB stick

This **erases the USB stick.** Replace `/dev/sdX` with your stick's device
(check carefully with `lsblk` — picking the wrong device destroys data):

```bash
sudo dd if=larch-installer.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Prefer a graphical tool? **GNOME Disks** ("Restore Disk Image…") or
[**balenaEtcher**](https://etcher.balena.io/) work just as well. A USB stick of 1 GB or
larger is plenty.

## 3. Install

1. Plug in the USB stick and boot the machine from it (open the firmware boot menu —
   often <kbd>F12</kbd>, <kbd>F11</kbd>, <kbd>F9</kbd>, or <kbd>Esc</kbd> — and choose
   the USB entry, in **UEFI** mode).
2. A short boot menu appears for 3 seconds, then larch-os boots **straight into the
   installer** — there is no live desktop to explore.
3. The installer asks for:

   | Prompt | What it's for |
   |---|---|
   | **Full name** | Your display name; the username is derived from it (`Jane Doe` → `janedoe`) |
   | **Password** | Password for your single user account |
   | **Wi-Fi network** | Only if no network cable is plugged in; the Wi-Fi password is not stored |
   | **Desktop & version** | e.g. `larch-gnome-v0.1.5`, `larch-cosmic-v0.1.5`, `larch-gnome-v0.1.4` — the newest GNOME release is preselected |
   | **Target disk** | The disk to install onto — **this disk is wiped** |

   The computer's name is derived too: `<username>-<brand>-<device type>`, e.g.
   `janedoe-lenovo-laptop`. The installer goes online and lists the Larch OS releases
   *before* asking for the disk, so without a network nothing is erased.

4. Review the summary and confirm. The installer then **erases the target disk**,
   creates its layout, downloads the system, and verifies it.
5. When it finishes, remove the USB stick and reboot. You'll land at the GNOME login
   screen.

> The disk is split into four partitions: a boot partition (bootloader and kernel), a
> system partition holding the OS image, a small config partition for system settings
> (Wi-Fi, Bluetooth, printers, your account, logs), and a large partition for your
> `/home`. Keeping them separate is what lets updates replace the system without
> touching your files.

## 4. First boot & installing apps

Log in with the username and password you chose. To install software, use Flatpak from
a terminal. **[Flathub](https://flathub.org/) is preconfigured as the download source**
(the `flathub` remote below), and larch-os already defaults Flatpak to your **persistent
per-user space** (the only place installs survive a reboot) — so you don't need any extra
flags:

```bash
# Install Chromium from Flathub
flatpak install flathub org.chromium.Chromium

# More examples
flatpak install flathub org.mozilla.firefox
flatpak install flathub org.gnome.Calculator
```

Run them from the GNOME app grid like any other application. Browse what's available at
<https://flathub.org/>, or search from the terminal:

```bash
flatpak search chromium
```

> Under the hood, larch-os aliases `flatpak` to `flatpak --user` so installs land in
> `~/.local/share/flatpak` on your `/home`. (A system-wide install via `flatpak --system`
> would be wiped on the next reboot, so avoid it.)

### AppImages

[AppImages](https://appimage.org/) work too — keep them anywhere in your home (e.g.
`~/Applications`), make them executable, and run them:

```bash
chmod +x ~/Applications/Some-App.AppImage
~/Applications/Some-App.AppImage
```

To get AppImages into the app grid with icons, install
[Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) from Flathub
(`flatpak install flathub it.mijorus.gearlever`) and open them with it.

## How it works (and what persists)

- **The OS is read-only.** System files come from a compressed image and cannot be
  changed. System settings (Wi-Fi, Bluetooth, printers, your password, logs) are kept
  on a separate config partition, layered over the image's defaults.
- **`/home` is persistent.** Your files, settings, and Flatpak apps live on a separate
  partition and survive reboots.
- **There is no package manager** in the running system, and no root login. You shape
  your environment entirely through Flatpak apps and your home directory.

This is by design: it makes the system predictable and very hard to break.

## Updating

Pick **Update LARCH** in the boot menu (it shows for 3 seconds at startup). The
updater gets online (cable, or it asks for a Wi-Fi network) and lists the last five Larch OS
releases for every desktop — `larch-gnome-v0.1.5`, `larch-cosmic-v0.1.5`,
`larch-gnome-v0.1.4`, … — and installs the one you choose: the new system is downloaded
and verified first, then swapped in. Your settings, apps and `/home` are kept, and the disk
is not repartitioned.

**Switching desktop** works the same way: pick an entry with another desktop. The system
settings are reset for the new desktop, except your account and password, the computer's
name, network connections, Bluetooth devices, printers, time zone, language, system
Flatpak apps and logs. Your files in `/home` stay as they are.

If an update is interrupted, the system may not start until you pick **Update LARCH**
again and finish it. Keep backups anyway: the update format is still young.

## Limitations (by design)

- **One user.** The account created during install is the only one; there's no way to add
  or remove users afterward.
- **Networking is automatic (DHCP) only.** There's no network configuration UI.
- **Apps via Flatpak (or AppImage) only.** No `apt`, no system package manager.
- **Updates need a network** — there is no offline update.

## Roadmap

- **Rollback** — keep the previous system image and boot it if an update misbehaves.
- Signed boot images for Secure Boot support.
- A graphical app store experience on top of Flathub.

## Build it yourself

larch-os is built reproducibly inside a privileged Docker container — no host build
tools required beyond Docker. There are two builds, in their own directories:

```bash
./docker-build.sh system      # system/    → output/system/ (sys-<desktop>.squashfs per desktop, vmlinuz, sys.initramfs, updater.initramfs, SHA256SUMS)
./docker-build.sh installer   # installer/ → output/larch-installer.iso
./test-qemu.sh --local        # try the installer in QEMU, installing the local system build
```

Releases are produced by GitHub Actions: `v*` tags publish the system files,
`installer-v*` tags publish the installer ISO. For the build
internals and contributor notes, see [`CLAUDE.md`](CLAUDE.md).
