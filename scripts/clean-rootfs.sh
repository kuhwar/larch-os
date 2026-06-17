#!/bin/bash
# scripts/clean-rootfs.sh — runs INSIDE the Alpine chroot before squashfs
# Strips the package manager and build artifacts from the final image.
# Called by build.sh as: chroot work/rootfs /clean-rootfs.sh

set -euo pipefail

log() { echo "  [clean] $*"; }

# ── Remove apk package manager ────────────────────────────────────────────────
log "Removing apk package manager (immutable OS)"
apk del apk-tools 2>/dev/null || true
rm -f /sbin/apk /usr/bin/apk
rm -rf /var/cache/apk /var/lib/apk /lib/apk

# ── Remove documentation ──────────────────────────────────────────────────────
log "Removing documentation and man pages"
rm -rf \
    /usr/share/man \
    /usr/share/doc \
    /usr/share/info

# Keep en_US locale only
mkdir -p /usr/share/locale
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en_US' \
    -exec rm -rf {} + 2>/dev/null || true

# ── Remove dev headers and static libs ───────────────────────────────────────
log "Removing dev headers and static libraries"
find /usr/include -mindepth 1 -delete 2>/dev/null || true
find /usr/lib /lib -name '*.a'  -delete 2>/dev/null || true
find /usr/lib /lib -name '*.la' -delete 2>/dev/null || true

# ── Clear temporary files ─────────────────────────────────────────────────────
log "Clearing caches and temporary files"
rm -rf \
    /tmp/* \
    /var/tmp/* \
    /var/log/*.log \
    /root/.ash_history \
    /root/.bash_history \
    /home/*/.bash_history \
    2>/dev/null || true

# ── Remove build scripts from rootfs ─────────────────────────────────────────
log "Removing build scripts from rootfs"
rm -f /setup-chroot.sh /clean-rootfs.sh /packages.list /remove.list

log "Rootfs clean complete"
