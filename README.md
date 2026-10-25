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
> - **For now, every new release requires a full install.** The installer offers an
>   **Update** option for disks that already have larch-os, but it is not maintained
>   yet: the disk layout and config format still change between releases, and an
>   update may leave the system broken. A full install **wipes the disk again —
>   including your `/home`.** Back up your data before reinstalling. Reliable atomic
>   upgrades (that keep `/home`) are planned — see the [Roadmap](#roadmap).
>
> - **UEFI only.** The machine must boot in UEFI mode. Legacy BIOS is not supported.

---

## What you get

- A read-only OS image (SquashFS) — system files can't be modified and reset on reboot.
- GNOME Shell on Wayland, with Files (Nautilus) and Terminal.
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
| Disk | 8 GB | 20 GB+ |
| GPU | Anything with a basic framebuffer | Intel / AMD / virtio (Mesa) |

**Secure Boot:** the boot images are not signed, so if your machine has Secure Boot
enabled you'll need to **disable it in firmware settings** before installing and booting.

## 1. Download

Grab the latest ISO from the [**Releases**](https://github.com/kuhwar/larch-os/releases) page:

- Always-latest ISO: <https://github.com/kuhwar/larch-os/releases/latest/download/larch-os.iso>
- Checksum: `larch-os.iso.sha256` (attached to each release)

Verify the download before writing it:

```bash
sha256sum -c larch-os.iso.sha256
# larch-os.iso: OK
```

## 2. Write it to a USB stick

This **erases the USB stick.** Replace `/dev/sdX` with your stick's device
(check carefully with `lsblk` — picking the wrong device destroys data):

```bash
sudo dd if=larch-os.iso of=/dev/sdX bs=4M status=progress oflag=sync
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
3. The installer asks for exactly three things:

   | Prompt | What it's for |
   |---|---|
   | **Full name** | Your display name; the username is derived from it (`Jane Doe` → `janedoe`) |
   | **Password** | Password for your single user account |
   | **Target disk** | The disk to install onto — **this disk is wiped** |

   The computer's name is derived too: `<username>-<brand>-<device type>`, e.g.
   `janedoe-lenovo-laptop`. If the disk already has larch-os, choose **Clean install**,
   not Update (see [Updating](#updating)).

4. Review the summary and confirm. The installer then **erases the target disk**,
   creates its layout, and copies the system over.
5. When it finishes, remove the USB stick and reboot. You'll land at the GNOME login
   screen.

> The disk is split into three partitions: a boot/system partition that holds the OS
> image, a small config partition for system settings (Wi-Fi, Bluetooth, printers,
> your account, logs), and a large partition for your `/home`. Keeping them separate
> is what will make future upgrades possible without touching your files.

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

## How it works (and what persists)

- **The OS is read-only.** System files come from a compressed image and cannot be
  changed. Anything written outside `/home` lives in memory and is **discarded on every
  reboot** — so the base system always returns to a clean state.
- **`/home` is persistent.** Your files, settings, and Flatpak apps live on a separate
  partition and survive reboots.
- **There is no package manager** in the running system, and no root login. You shape
  your environment entirely through Flatpak apps and your home directory.

This is by design: it makes the system predictable and very hard to break.

## Updating

**For now, use a full install for every new release.** The installer has an **Update**
option that replaces the OS image in place and keeps your settings and `/home`, but it
is not maintained across releases yet — the disk layout and config format are still
changing, so an update may leave the system broken. A full install **erases the whole
disk, including your `/home`** — so **back up your data first**.

Atomic, in-place upgrades that swap the OS image while preserving your `/home` are the
top item on the [Roadmap](#roadmap).

## Limitations (by design)

- **One user.** The account created during install is the only one; there's no way to add
  or remove users afterward.
- **Networking is automatic (DHCP) only.** There's no network configuration UI.
- **Apps via Flatpak only.** No `apt`, no system package manager.
- **No reliable in-place upgrades yet** — full install required (see above).

## Roadmap

- **Atomic, in-place upgrades** — replace the OS image and keep `/home`, with easy
  rollback. *(Top priority.)*
- Signed boot images for Secure Boot support.
- A graphical app store experience on top of Flathub.

## Build it yourself

larch-os is built reproducibly inside a privileged Docker container — no host build
tools required beyond Docker:

```bash
./docker-build.sh            # → output/larch-os.iso
```

Releases are produced automatically by GitHub Actions on each version tag. For the build
internals and contributor notes, see [`CLAUDE.md`](CLAUDE.md).
