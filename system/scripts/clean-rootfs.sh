#!/bin/bash
# scripts/clean-rootfs.sh — runs INSIDE the chroot as the final step before squashfs
# Strips the package manager and anything else that must not be in the final image.
# Called by system/build.sh (stage 5) in each desktop's copy of the base:
#   chroot work/desktops/<desktop> /clean-rootfs.sh
# remove.list / remove-files.list are the base lists plus the desktop's own.
#
# What goes is listed in config/remove.list (packages) and
# config/remove-files.list (paths); this script applies them and does the few
# steps a list can't express.

set -euo pipefail

log() { echo "  [clean] $*"; }

# Non-comment, non-blank lines of a list file, whitespace-trimmed.
list_entries() { sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true; }

export DEBIAN_FRONTEND=noninteractive

# ── Purge packages (remove.list) ─────────────────────────────────────────────
# Entries are dpkg-query patterns; lines starting with ! exclude what they match.
log "Purging packages from remove.list"
# Here-strings, not < <(…): /dev isn't mounted in the chroot at stage 5, so
# process substitution (/dev/fd/N) fails.
PATTERNS=(); EXCLUDES=()
while IFS= read -r _e; do
    [ -n "$_e" ] || continue
    case "$_e" in
        '!'*) EXCLUDES+=("${_e#!}") ;;
        *)    PATTERNS+=("$_e") ;;
    esac
done <<< "$(list_entries /remove.list)"

PURGE=()
while read -r _status _pkg; do
    [ "${_status:-}" = installed ] || continue
    for _x in "${EXCLUDES[@]}"; do
        # shellcheck disable=SC2053  # unquoted on purpose: glob match
        [[ $_pkg == $_x ]] && continue 2
    done
    PURGE+=("$_pkg")
done <<< "$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' "${PATTERNS[@]}" 2>/dev/null || true)"

if [ "${#PURGE[@]}" -gt 0 ]; then
    log "  ${#PURGE[@]} packages"
    dpkg --purge --force-depends "${PURGE[@]}" 2>/dev/null || true
fi

# ── Delete files (remove-files.list) ─────────────────────────────────────────
# Globs are expanded here, inside the chroot; unmatched ones expand to nothing.
log "Deleting paths from remove-files.list"
shopt -s nullglob dotglob
while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    case "$_p" in
        /?*/?*) ;;   # at least two levels deep, e.g. /usr/bin/su or /tmp/*
        *) echo "  [clean] refusing to delete '$_p' (not a path below a top-level dir)" >&2; exit 1 ;;
    esac
    # shellcheck disable=SC2086  # unquoted on purpose: glob expansion
    for _m in $_p; do rm -rf -- "$_m"; done
done <<< "$(list_entries /remove-files.list)"
shopt -u nullglob dotglob

# Static and libtool archives left by *-dev packages, wherever they are.
find /usr/lib \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true

# ── Drop setuid from mount/umount ────────────────────────────────────────────
# They stay for root, but user mounts need fstab `user` entries (there are
# none), and udisks / fusermount3 cover removable drives and FUSE.
chmod u-s /usr/bin/mount /usr/bin/umount

# ── Wallpapers: keep only larch-os's own ─────────────────────────────────────
# rootfs-overlay/usr/share/backgrounds/larch, set by each desktop's own
# config (GNOME: desktops/gnome's 90_larch.gschema.override). Drop any other a
# dependency pulled in, so the desktop's wallpaper picker offers just that one. desktop-base (purged above) may leave its schema override.
log "Trimming wallpapers"
find /usr/share/backgrounds -mindepth 1 -maxdepth 1 ! -name larch -exec rm -rf {} + 2>/dev/null || true
find /usr/share/gnome-background-properties -mindepth 1 ! -name 'larch.xml' -delete 2>/dev/null || true
rm -f /usr/share/glib-2.0/schemas/10_desktop-base.gschema.override
if command -v glib-compile-schemas >/dev/null && [ -d /usr/share/glib-2.0/schemas ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas
fi

# ── Mark /etc and /var as up to date with /usr ───────────────────────────────
# ConditionNeedsUpdate= (ldconfig, systemd-sysusers, systemd-update-done)
# compares /usr's mtime against /etc/.updated and /var/.updated. Without them in
# the image, those services would run on the first boot after every install.
# Written last, so /usr's mtime is final.
log "Stamping /etc/.updated and /var/.updated"
/usr/lib/systemd/systemd-update-done

# ── Remove build scripts from rootfs ─────────────────────────────────────────
log "Removing build scripts from rootfs"
rm -f /setup-chroot.sh /setup-desktop.sh /desktop-setup.sh /desktop-packages.list \
      /clean-rootfs.sh /packages.list /remove.list /remove-files.list

log "Rootfs clean complete"
