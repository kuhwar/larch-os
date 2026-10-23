#!/bin/bash
# scripts/clean-rootfs.sh — runs INSIDE the chroot as the final step before squashfs
# Strips the package manager and anything else that must not be in the final image.
# Called by docker-entrypoint.sh (stage 5) as: chroot work/rootfs /clean-rootfs.sh

set -euo pipefail

log() { echo "  [clean] $*"; }

export DEBIAN_FRONTEND=noninteractive

# ── Remove packages listed in remove.list ────────────────────────────────────
log "Removing package manager and build-time packages"
REMOVE_PKGS=$(grep -v '^#' /remove.list | grep -v '^[[:space:]]*$' | tr '\n' ' ')
# shellcheck disable=SC2086
dpkg --purge --force-depends $REMOVE_PKGS 2>/dev/null || true

# Kernel headers / kbuild carry the kernel version in their names, so they're
# matched by glob here instead of being listed in remove.list.
HEADER_PKGS=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' \
    'linux-headers-*' 'linux-kbuild-*' 2>/dev/null | awk '$1 == "installed" { print $2 }' || true)
if [ -n "$HEADER_PKGS" ]; then
    # shellcheck disable=SC2086
    dpkg --purge --force-depends $HEADER_PKGS 2>/dev/null || true
fi

# Fallback for anything the toolchain purge left behind (cc1 alone is ~60 MB).
rm -rf /usr/libexec/gcc /usr/lib/gcc 2>/dev/null || true

# ── Remove apt and dpkg binaries and databases ───────────────────────────────
log "Wiping apt/dpkg binaries and databases"
rm -rf \
    /usr/bin/apt* \
    /usr/bin/dpkg* \
    /usr/lib/apt \
    /usr/lib/dpkg \
    /var/lib/apt \
    /var/lib/dpkg \
    /var/cache/apt \
    /var/cache/debconf \
    /etc/apt \
    /etc/dpkg

# ── Remove package manager leftovers ─────────────────────────────────────────
# NOTE: the python3 interpreter itself (/usr/bin/python3*) is NOT removed here
# — system-config-printer's scp-dbus-service.py (org.fedoraproject.Config.Printing,
# used by GNOME Settings' printer panel) needs a real python3 at runtime. Only
# the apt/dpkg python bindings are stripped, same as python3-apt/python3-debian
# above.
log "Removing package manager related files"
rm -rf \
    /usr/share/doc \
    /usr/share/man \
    /usr/share/info \
    /usr/share/locale \
    /usr/share/i18n \
    /usr/lib/python3/dist-packages/apt* \
    /usr/lib/python3/dist-packages/debian* \
    2>/dev/null || true

# Keep en_US locale only
mkdir -p /usr/share/locale
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en_US' -exec rm -rf {} + 2>/dev/null || true

# GNOME help ships every translation (~30 MB); keep only the untranslated C pages.
find /usr/share/help -mindepth 1 -maxdepth 1 ! -name 'C' -exec rm -rf {} + 2>/dev/null || true

# ── Trim wallpapers ──────────────────────────────────────────────────────────
# Keep only the GNOME default (adwaita light/dark), which is what
# org.gnome.desktop.background points at once desktop-base's override is gone.
log "Trimming wallpapers"
find /usr/share/backgrounds/gnome -mindepth 1 ! -name 'adwaita-*' -delete 2>/dev/null || true
find /usr/share/gnome-background-properties -mindepth 1 ! -name 'adwaita.xml' -delete 2>/dev/null || true
rm -f /usr/share/glib-2.0/schemas/10_desktop-base.gschema.override
glib-compile-schemas /usr/share/glib-2.0/schemas

# ── Hide system-config-printer's GUI ─────────────────────────────────────────
# Only its D-Bus service (org.fedoraproject.Config.Printing, D-Bus-activated)
# is needed, by GNOME Settings' Printers panel. Drop the duplicate "Print
# Settings" launcher and the tray applet autostart (GNOME has no tray;
# gsd-print-notifications already covers printer notifications).
log "Removing system-config-printer launcher and applet"
rm -f /usr/share/applications/system-config-printer.desktop \
      /etc/xdg/autostart/print-applet.desktop

# ── Prune Vulkan drivers that never apply ────────────────────────────────────
# lvp = software (llvmpipe) Vulkan; gfxstream/virtio = VM-guest-only drivers.
# GTK4 falls back to its GL renderer without a hardware Vulkan ICD, and Flatpak
# apps bring their own Mesa from the runtime.
log "Pruning software/VM Vulkan drivers"
for _vk in lvp gfxstream virtio; do
    rm -f "/usr/lib/x86_64-linux-gnu/libvulkan_${_vk}.so" \
          "/usr/share/vulkan/icd.d/${_vk}_icd.json" \
          /usr/share/vulkan/icd.d/"${_vk}"_vk_icd.json
done

# ── Remove *-dev packages leftovers ──────────────────────────────────────────
log "Removing dev headers and static libraries"
find /usr/include -mindepth 1 -delete 2>/dev/null || true
find /usr/lib     -name '*.a'  -delete 2>/dev/null || true
find /usr/lib     -name '*.la' -delete 2>/dev/null || true

# ── Remove DKMS build artifacts ──────────────────────────────────────────────
# broadcom-sta-dkms and nvidia-kernel-dkms build their .ko into /lib/modules
# during stage 4; the source trees and headers are not needed at runtime.
log "Removing DKMS sources and kernel headers"
rm -rf /usr/src/linux-headers-* /usr/src/broadcom-sta-* /usr/src/nvidia-* /var/lib/dkms 2>/dev/null || true
find /usr/lib/modules -maxdepth 2 -name 'build' -type l -delete 2>/dev/null || true
find /usr/lib/modules -maxdepth 2 -name 'source' -type l -delete 2>/dev/null || true

# ── Clear temporary files ─────────────────────────────────────────────────────
log "Clearing caches and temporary files"
rm -rf \
    /tmp/* \
    /var/tmp/* \
    /var/log/*.log \
    /var/log/*.gz \
    /root/.bash_history \
    /home/*/.bash_history \
    2>/dev/null || true

# ── Remove build scripts from rootfs ─────────────────────────────────────────
log "Removing build scripts from rootfs"
rm -f /setup-chroot.sh /clean-rootfs.sh /packages.list /remove.list

log "Rootfs clean complete"
