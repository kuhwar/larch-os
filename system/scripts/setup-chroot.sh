#!/bin/bash
# scripts/setup-chroot.sh — runs INSIDE the base rootfs (system stage 4)
# Called by system/build.sh as: chroot work/rootfs /setup-chroot.sh
# Configures the BASE every desktop image is copied from: kernel, drivers,
# shared services, the default user. Desktop-specific setup lives in
# system/desktops/<desktop>/ (scripts/setup-desktop.sh, stage 5).
#
# Stage 2 installed Arch's `base` and wrote /etc/pacman.conf pointing at the
# pinned snapshot (config/arch-snapshot), so every package here comes from it.

set -euo pipefail

log() { echo "  [chroot] $*"; }

# ── NVIDIA 550 from the AUR (pinned) ─────────────────────────────────────────
# Arch's nvidia packages are 590+, which dropped Pascal (GTX 10xx). The AUR's
# nvidia-550xx-dkms (split: -utils, -dkms, opencl-) is 550.163.01 with patches
# for current kernels. Pinned to a commit of its AUR repo; makepkg verifies
# NVIDIA's .run against the PKGBUILD's sha512sums.
NVIDIA_AUR_PKG="nvidia-550xx-dkms"
NVIDIA_AUR_COMMIT="cdcb0b31bde5cd0ec1f060866264718bc0493bb2"   # 550.163.01-7
AUR_USER="larch-aur"                                           # makepkg refuses root

PACMAN=(pacman --noconfirm --noprogressbar)

# ── pacman keyring ───────────────────────────────────────────────────────────
log "Initialising the pacman keyring"
pacman-key --init >/dev/null
pacman-key --populate archlinux >/dev/null

# ── No mkinitcpio runs ───────────────────────────────────────────────────────
# Every larch initramfs is assembled by hand (shared/build-lib.sh), and the
# kernel ships as the release file vmlinuz (stage 9, from
# /usr/lib/modules/<ver>/vmlinuz). A hook named like a system one in
# /etc/pacman.d/hooks overrides it; one linked to /dev/null disables it.
mkdir -p /etc/pacman.d/hooks
for h in 60-mkinitcpio-remove.hook 90-mkinitcpio-install.hook; do
    ln -sf /dev/null "/etc/pacman.d/hooks/$h"
done

# ── Locale & timezone ────────────────────────────────────────────────────────
log "Configuring locale and timezone"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# ── Hostname & hosts ─────────────────────────────────────────────────────────
log "Setting hostname"
echo "larchos" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   larchos
::1         localhost ip6-localhost ip6-loopback
EOF

# ── Install packages from packages.list ──────────────────────────────────────
log "Installing packages (this takes a while)"
PKGS=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' /packages.list | grep -v '^$' | tr '\n' ' ')
# --overwrite: the base rootfs-overlay (stage 3) may already hold a path a
# package ships; build.sh copies the overlay again after this script.
# shellcheck disable=SC2086
"${PACMAN[@]}" -S --needed --overwrite '/etc/*' $PKGS

KVER=$(ls /usr/lib/modules | sort -V | tail -1)
[ -f "/usr/lib/modules/$KVER/vmlinuz" ] || { echo "ERROR: no kernel in /usr/lib/modules" >&2; exit 1; }
log "Kernel $KVER"

# ── NVIDIA proprietary driver 550 (AUR build) ────────────────────────────────
# Built as an unprivileged throwaway user (removed below, so it is not in the
# image's passwd). --nodeps: nvidia-550xx-dkms depends on nvidia-utils=550,
# which is its own split package; the makedepends are installed here.
# Installing -dkms runs the DKMS pacman hook, which builds nvidia.ko for
# $KVER against linux-headers.
log "Building NVIDIA 550 ($NVIDIA_AUR_PKG @ ${NVIDIA_AUR_COMMIT:0:12}) from the AUR"
"${PACMAN[@]}" -S --needed base-devel git patchelf
useradd -r -m -d "/var/tmp/$AUR_USER" -s /usr/bin/nologin "$AUR_USER"
# runuser keeps root's environment; HOME must be the build user's own.
as_aur() { runuser -u "$AUR_USER" -- env HOME="/var/tmp/$AUR_USER" "$@"; }
AUR_DIR="/var/tmp/$AUR_USER/$NVIDIA_AUR_PKG"
as_aur git clone -q "https://aur.archlinux.org/$NVIDIA_AUR_PKG.git" "$AUR_DIR"
as_aur git -C "$AUR_DIR" -c advice.detachedHead=false checkout -q "$NVIDIA_AUR_COMMIT"
(cd "$AUR_DIR" && as_aur makepkg --nodeps --noconfirm --noprogressbar)
"${PACMAN[@]}" -U "$AUR_DIR"/nvidia-550xx-utils-[0-9]*.pkg.tar.zst \
                  "$AUR_DIR"/nvidia-550xx-dkms-[0-9]*.pkg.tar.zst
userdel -r "$AUR_USER" 2>/dev/null || true
groupdel "$AUR_USER" 2>/dev/null || true
rm -rf "/var/tmp/$AUR_USER"

# Both DKMS modules must have been built for the release's kernel.
for m in nvidia nvidia-drm nvidia-modeset wl; do
    find "/usr/lib/modules/$KVER" -name "$m.ko*" | grep -q . \
        || { echo "ERROR: DKMS did not build $m.ko for $KVER" >&2; exit 1; }
done

# Save/restore VRAM around sleep (nvidia-utils ships the units; enablement
# creates the .wants links under systemd-suspend/hibernate.service).
systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service

# ── Generate locales ─────────────────────────────────────────────────────────
# Every locale Arch's /etc/locale.gen lists (all of glibc's SUPPORTED) is
# compiled, so any language and region format is selectable in GNOME
# Settings; en_US.UTF-8 stays the default. The archive lands in
# /usr/lib/locale; remove-files.list drops the /usr/share/i18n sources.
log "Generating all supported locales"
sed -i -E 's/^#([A-Za-z0-9_.@-]+ [A-Za-z0-9-]+)[[:space:]]*$/\1/' /etc/locale.gen
locale-gen >/dev/null
# A missing en_US locale silently breaks gnome-terminal (status=9).
LC_ALL=en_US.UTF-8 locale >/dev/null 2>&1 \
    || { echo "ERROR: en_US.UTF-8 was not generated" >&2; exit 1; }

# ── User setup ───────────────────────────────────────────────────────────────
log "Creating default user 'larch'"
# The UID-1000 placeholder the installer turns into the real user.
useradd -m -s /bin/bash -c "Larch User" larch
echo "larch:larch" | chpasswd
# No sudo on larch-os, and the user is deliberately NOT in `wheel`: that group
# is polkit's admin identity on Arch, so membership would let privileged
# polkit actions be authorized with the user's own password.
usermod -aG audio,video,input larch

# ── Systemd services ─────────────────────────────────────────────────────────
# Arch enables nothing on install (Debian's postinsts did), so everything the
# image runs is listed.
log "Enabling systemd services"
systemctl enable NetworkManager bluetooth cups avahi-daemon systemd-timesyncd \
    switcheroo-control
systemctl set-default graphical.target

# ── Boot splash (Plymouth + firmware BGRT logo) ──────────────────────────────
log "Configuring Plymouth boot splash (bgrt theme)"
# -R would rebuild an initramfs, which this image does not use.
plymouth-set-default-theme bgrt 2>/dev/null || true
# Keep bgrt and what it needs: spinner (its ImageDir) and the text/details
# fallbacks.
if [ -d /usr/share/plymouth/themes ]; then
    for _theme in /usr/share/plymouth/themes/*; do
        case "$(basename "$_theme")" in
            bgrt|spinner|text|details|default.plymouth) : ;;
            *) rm -rf "$_theme" ;;
        esac
    done
fi

# PipeWire audio
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber 2>/dev/null || true

# ── Flatpak: add Flathub system-wide ─────────────────────────────────────────
log "Configuring Flatpak"
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo || \
    log "WARNING: Could not reach Flathub (network may be unavailable in build environment)"

# ── NetworkManager ───────────────────────────────────────────────────────────
log "Configuring NetworkManager"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/00-larch.conf <<'EOF'
[main]
plugins=keyfile
dhcp=internal

[keyfile]

[device]
wifi.scan-rand-mac-address=yes
EOF

# ── Read-only root: mount points must ship in the image ──────────────────────
mkdir -p /conf /media /var/tmp

# ── Lock root ────────────────────────────────────────────────────────────────
passwd -l root

# ── iwlwifi firmware the kernel can't load ───────────────────────────────────
# Done here in the base (not in clean-rootfs.sh) so the installer and updater
# initramfs, which take firmware from the base, get the trimmed set too.
# linux-firmware ships several API versions per Intel Wi-Fi chip; iwlwifi
# loads the highest one <= its own maximum, so only that one stays per chip.
# The maxima come from this kernel's modules (modinfo). Arch compresses
# firmware (.ucode.zst): names are compared without the compression suffix.
FW=/usr/lib/firmware
IWL=$FW/intel/iwlwifi
IWL_REQ=$(find /usr/lib/modules -path '*/iwlwifi/*' -name '*.ko*' \
    -exec modinfo -F firmware {} \; 2>/dev/null | grep '^iwlwifi-' | sort -u || true)
if [ -d "$IWL" ] && [ -n "$IWL_REQ" ]; then
    log "Trimming iwlwifi firmware to what the kernel loads"
    printf '%s\n' "$IWL_REQ" > /tmp/iwl-req
    # shellcheck disable=SC2016
    IWL_DROP=$(ls "$IWL" | sed -E 's/\.(zst|xz)$//' | awk '
        NR == FNR {
            if (match($0, /-[0-9]+\.ucode$/)) {
                fam = substr($0, 1, RSTART - 1); v = substr($0, RSTART + 1) + 0
                if (v > max[fam]) max[fam] = v
                if (v > gmax) gmax = v
            }
            if ($0 ~ /-c[0-9]+\.ucode$/) creq = 1
            next
        }
        /-[0-9]+\.ucode$/ {
            match($0, /-[0-9]+\.ucode$/)
            fam = substr($0, 1, RSTART - 1); v = substr($0, RSTART + 1) + 0
            lim = (fam in max) ? max[fam] : gmax
            if (v <= lim && v > best[fam]) { best[fam] = v; bestf[fam] = $0 }
            all[$0] = 1; next
        }
        /-c[0-9]+\.ucode$/ { if (!creq) print }
        END {
            for (f in all) {
                match(f, /-[0-9]+\.ucode$/); fam = substr(f, 1, RSTART - 1)
                if (bestf[fam] != f) print f
            }
        }' /tmp/iwl-req - || true)
    for f in $IWL_DROP; do rm -f "$IWL/$f" "$IWL/$f.zst" "$IWL/$f.xz"; done
    rm -f /tmp/iwl-req
fi
# linux-firmware's compatibility symlinks dangle for everything removed.
find "$FW" -xtype l -delete

# ── Clean up ─────────────────────────────────────────────────────────────────
# The sync databases stay: stage 5 installs each desktop from the same
# snapshot without refreshing them.
log "Cleaning the package cache"
rm -rf /var/cache/pacman/pkg/*
# gpg-agent/keyboxd started by pacman-key would keep the chroot busy.
gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true

log "chroot configuration complete"
