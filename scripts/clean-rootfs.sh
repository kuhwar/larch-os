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
log "Removing package manager related files"
rm -rf \
    /usr/share/doc \
    /usr/share/man \
    /usr/share/info \
    /usr/share/locale \
    /usr/share/i18n \
    /usr/lib/python3/dist-packages/apt* \
    /usr/lib/python3/dist-packages/debian* \
    /usr/bin/python3* \
    2>/dev/null || true

# Keep en_US locale only
mkdir -p /usr/share/locale
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en_US' -exec rm -rf {} + 2>/dev/null || true

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
