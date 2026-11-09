#!/bin/bash
# scripts/clean-rootfs.sh — runs INSIDE a desktop's rootfs, the last step before squashfs
# Called by system/build.sh (stage 5), after the builder removed remove.list's
# packages and the orphans, with the base + desktop remove-files.list as
# /remove-files.list and the desktop's launcher.list (if any) as /launcher.list.
# build.sh's library guard checks the result afterwards.

set -euo pipefail

log() { echo "  [clean] $*"; }

# Non-comment, non-blank lines of a list file, whitespace-trimmed.
list_entries() { sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true; }

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

# Static and libtool archives, wherever they are.
find /usr/lib /usr/lib64 \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true

# ── setuid/setgid ────────────────────────────────────────────────────────────
# mount/umount stay for root; user mounts need fstab `user` entries (none),
# and udisks / fusermount3 cover removable drives and FUSE.
for _f in /usr/bin/mount /usr/bin/umount /usr/bin/mount.cifs /usr/bin/wall /usr/bin/write; do
    if [ -e "$_f" ]; then chmod ug-s "$_f"; fi
done
log "setuid/setgid files left:"
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | sort | sed 's/^/      /'

# ── Launcher allow-list (desktops/<desktop>/launcher.list) ───────────────────
# Every .desktop entry the list doesn't name gets NoDisplay=true: still there
# for file associations and D-Bus activation, just not in the app grid.
if [ -f /launcher.list ]; then
    log "Hiding launchers not in launcher.list"
    for _f in /usr/share/applications/*.desktop; do
        [ -e "$_f" ] || continue
        _id=$(basename "$_f")
        list_entries /launcher.list | grep -qxF "$_id" && continue
        grep -qE '^(NoDisplay|Hidden)=true' "$_f" && continue
        sed -i -e '/^NoDisplay=/d' -e '0,/^\[Desktop Entry\]$/s//[Desktop Entry]\nNoDisplay=true/' "$_f"
        log "  hidden: $_id"
    done
fi
if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q /usr/share/applications || true
fi

# ── Wallpapers: keep only larch-os's own ─────────────────────────────────────
find /usr/share/backgrounds -mindepth 1 -maxdepth 1 ! -name larch -exec rm -rf {} + 2>/dev/null || true
find /usr/share/gnome-background-properties -mindepth 1 ! -name 'larch.xml' -delete 2>/dev/null || true
if command -v glib-compile-schemas >/dev/null && [ -d /usr/share/glib-2.0/schemas ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas
fi

# ── Caches the removals left stale ───────────────────────────────────────────
ldconfig
# dconf's system databases (GDM's greeter profile reads /etc/dconf/db/gdm):
# package scriptlets compile them, but not in a build root.
if command -v dconf >/dev/null; then dconf update; fi
if command -v fc-cache >/dev/null; then fc-cache -s >/dev/null 2>&1 || true; fi

# ── Mark /etc and /var as up to date with /usr ───────────────────────────────
# ConditionNeedsUpdate= (ldconfig, systemd-sysusers, systemd-update-done)
# compares /usr's mtime against /etc/.updated and /var/.updated. Without them in
# the image, those services would run on the first boot after every install.
# Written last, so /usr's mtime is final.
log "Stamping /etc/.updated and /var/.updated"
/usr/lib/systemd/systemd-update-done

rm -f /clean-rootfs.sh /remove-files.list /launcher.list
log "Rootfs clean complete"
