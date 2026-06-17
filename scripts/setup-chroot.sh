#!/bin/bash
# scripts/setup-chroot.sh — runs INSIDE the Alpine chroot after bootstrap
# Called by build.sh as: chroot work/rootfs /setup-chroot.sh

set -euo pipefail

log() { echo "  [chroot] $*"; }

# ── Alpine repositories ───────────────────────────────────────────────────────
log "Configuring Alpine repositories"
cat > /etc/apk/repositories <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/edge/main
https://dl-cdn.alpinelinux.org/alpine/edge/community
EOF

apk update -q

# ── Timezone ──────────────────────────────────────────────────────────────────
log "Configuring timezone"
# musl handles UTF-8 natively — no locale generation needed
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# ── Hostname & hosts ─────────────────────────────────────────────────────────
log "Setting hostname"
echo "larchos" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   larchos
::1         localhost ip6-localhost ip6-loopback
EOF

# ── Install packages ──────────────────────────────────────────────────────────
log "Installing packages (this takes a while)"
PKGS=$(grep -v '^#' /packages.list | grep -v '^[[:space:]]*$' | tr '\n' ' ')
# shellcheck disable=SC2086
apk add --no-cache $PKGS

# ── User setup ────────────────────────────────────────────────────────────────
log "Creating default user 'larch'"
adduser -D -s /bin/bash -g "Larch User" larch
echo "larch:larch" | chpasswd

# Ensure hardware access groups exist (some are created by packages, add missing ones)
for grp in audio video input netdev plugdev seat; do
    addgroup -S "$grp" 2>/dev/null || true
done

# Add to relevant groups; wheel = sudo on Alpine
for grp in audio video input netdev plugdev wheel; do
    adduser larch "$grp" 2>/dev/null || true
done

# Allow wheel group passwordless sudo
echo "%wheel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# ── OpenRC services ────────────────────────────────────────────────────────────
log "Enabling OpenRC services"
# Boot-level services
rc-update add dbus boot
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit

# Default runlevel (graphical desktop)
rc-update add gdm default
rc-update add networkmanager default

# Disable services that conflict with immutability
rc-update del apk-audit 2>/dev/null || true

# Enable PipeWire globally — started per-user by GNOME session manager
# (no system service needed; wireplumber handles session routing)

# ── GDM: Wayland-only ─────────────────────────────────────────────────────────
log "Configuring GDM for Wayland"
mkdir -p /etc/gdm
# custom.conf is shipped via rootfs-overlay/etc/gdm/custom.conf

# ── Flatpak: add Flathub ──────────────────────────────────────────────────────
log "Configuring Flatpak"
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo || \
    log "WARNING: Could not reach Flathub (network may be unavailable in build environment)"

# ── NetworkManager ────────────────────────────────────────────────────────────
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

# ── Kernel check ──────────────────────────────────────────────────────────────
log "Checking kernel installation"
ls /boot/vmlinuz* 2>/dev/null || ls /boot/vmlinuz 2>/dev/null || \
    log "WARNING: no kernel found in /boot"

# ── Security hardening ────────────────────────────────────────────────────────
log "Hardening: locking root account"
passwd -l root

# ── Clean up ──────────────────────────────────────────────────────────────────
log "Cleaning apk cache"
rm -rf /var/cache/apk/*

log "chroot configuration complete"
