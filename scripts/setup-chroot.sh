#!/bin/bash
# scripts/setup-chroot.sh — runs INSIDE the chroot after debootstrap
# Called by build.sh as: chroot work/rootfs /setup-chroot.sh
# The script is bind-mounted into the chroot at /setup-chroot.sh before execution.

set -euo pipefail

log() { echo "  [chroot] $*"; }

# ── Locale & timezone ────────────────────────────────────────────────────────
log "Configuring locale and timezone"
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
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
log "Updating apt sources"
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

log "Installing packages (this takes a while)"
# Read packages.list, strip comments and blank lines
PKGS=$(grep -v '^#' /packages.list | grep -v '^[[:space:]]*$' | tr '\n' ' ')
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS

# ── User setup ───────────────────────────────────────────────────────────────
log "Creating default user 'larch'"
# Create user with home directory; password is 'larch' (change before shipping)
useradd -m -s /bin/bash -c "Larch User" larch
echo "larch:larch" | chpasswd
# Allow sudo for larch user
echo "larch ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/larch
chmod 0440 /etc/sudoers.d/larch
# Add to relevant groups
usermod -aG audio,video,input,netdev,plugdev,sudo larch

# ── Systemd services ─────────────────────────────────────────────────────────
log "Enabling systemd services"
systemctl enable gdm3
systemctl enable NetworkManager
systemctl set-default graphical.target

# Disable services that conflict with immutability
systemctl disable apt-daily.timer          2>/dev/null || true
systemctl disable apt-daily-upgrade.timer  2>/dev/null || true
systemctl disable unattended-upgrades      2>/dev/null || true
systemctl disable packagekit               2>/dev/null || true

# No dpkg on the immutable OS — the dpkg database backup timer has nothing to
# back up and its helper is purged with apt/dpkg. Mask so it can't be pulled in.
systemctl mask dpkg-db-backup.timer        2>/dev/null || true

# NetworkManager is the sole network manager (always-DHCP design). Disable the
# ifupdown service and the standalone wpa_supplicant unit so they don't race NM
# for interface control. (NM drives wpa_supplicant over D-Bus, not via this unit.)
systemctl disable networking.service       2>/dev/null || true
systemctl disable wpa_supplicant.service   2>/dev/null || true

# ── Boot splash (Plymouth + firmware BGRT logo) ──────────────────────────────
# plymouth-start.service is pulled into sysinit.target by a vendor .wants
# symlink, so no explicit enable is needed; it shows the splash once systemd
# is up (kernel cmdline carries `splash`). Set the bgrt theme as the default.
log "Configuring Plymouth boot splash (bgrt theme)"
# -R would trigger update-initramfs, which this image does not use — omit it.
plymouth-set-default-theme bgrt 2>/dev/null || true
# Remove every theme except bgrt and what it needs: spinner (bgrt's ImageDir
# for the throbber assets) and the text/details fallbacks plymouth requires.
# Iterate over whatever is actually installed (Debian's default set is bgrt,
# ceratopsian, emerald, homeworld, joy, lines, moonlight, softwaves, ...).
if [ -d /usr/share/plymouth/themes ]; then
    # Glob without a trailing slash so symlink themes (e.g. desktop-base's
    # `debian-theme`) are removed as the symlink itself, not followed.
    for _theme in /usr/share/plymouth/themes/*; do
        case "$(basename "$_theme")" in
            bgrt|spinner|text|details|default.plymouth) : ;;   # keep
            *) rm -rf "$_theme" ;;
        esac
    done
fi

# Enable PipeWire audio
systemctl --global enable pipewire.socket     2>/dev/null || true
systemctl --global enable pipewire-pulse.socket 2>/dev/null || true
systemctl --global enable wireplumber          2>/dev/null || true

# ── GDM: Wayland-only ───────────/───────────────────────────────────────────
log "Configuring GDM for Wayland"
# Ensure the Wayland session is used and X11 is not started
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf <<'EOF'
[daemon]
WaylandEnable=true
DefaultSession=gnome-wayland.desktop

[security]

[xdmcp]

[chooser]
EOF

# ── Flatpak: add Flathub system-wide ─────────────────────────────────────────
log "Configuring Flatpak"
# Add Flathub as a system remote for discoverability (baked into the squashfs).
# NOTE: this is best-effort — it needs network at build time, and system-scope
# *app* installs land in /var/lib/flatpak, which is on the tmpfs overlay and is
# discarded on reboot. Persistent installs must use --user (→ ~/.local/share/
# flatpak on the LARCHHOME partition). The Flathub remote is also registered at
# --user scope at first login by /etc/profile.d/larch-flatpak.sh.
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo || \
    log "WARNING: Could not reach Flathub (network may be unavailable in build environment)"

# polkit rule for Flatpak and the skel ~/.bashrc Flatpak snippet are shipped as
# static files via rootfs-overlay/ (etc/polkit-1/rules.d/99-larch-flatpak.rules
# and etc/skel/.bashrc), per the project convention for system config files.

# ── NetworkManager: manage all interfaces ────────────────────────────────────
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

# ── Kernel / initramfs: stub (real initramfs is built externally) ─────────────
# Just make sure the vmlinuz symlink is resolvable
log "Checking kernel installation"
ls /boot/vmlinuz* 2>/dev/null || log "WARNING: no kernel found in /boot"

# ── Console / TTY hardening (immutable system) ───────────────────────────────
log "Hardening console access"
# Disable root login on all ttys
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config 2>/dev/null || true
# Lock root account
passwd -l root

# ── Clean apt caches ─────────────────────────────────────────────────────────
log "Cleaning apt caches"
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

log "chroot configuration complete"
