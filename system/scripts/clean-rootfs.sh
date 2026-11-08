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

# ── Shared-library guard, part 1 ─────────────────────────────────────────────
# What remove.list/remove-files.list take away must not be a library anything
# left in the image links (Arch's libtool, for one, also ships libltdl, which
# gnome-shell needs). Record every DT_NEEDED soname now, while binutils'
# readelf is still here, and which of them are already unresolved (optional
# plugins whose libraries Arch leaves to optdepends); part 2 fails the build if
# the removals add to that set.
GUARD=/.larch-libguard    # not /var/tmp: remove-files.list empties it
mkdir -p "$GUARD"
sonames_present() {
    find /usr/lib \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' \) -printf '%f\n' | sort -u
}
log "Recording shared-library dependencies"
find /usr/bin /usr/lib /usr/libexec -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null \
    | xargs -0 -r readelf -d 2>/dev/null \
    | awk '/^File: /{f=$2} /\(NEEDED\)/{gsub(/[][]/,"",$5); print $5 "\t" f}' \
    | sort -u > "$GUARD/needed" || true    # readelf fails on non-ELF files: fine
cut -f1 "$GUARD/needed" | sort -u > "$GUARD/needed.sonames"
sonames_present > "$GUARD/present.before"
comm -23 "$GUARD/needed.sonames" "$GUARD/present.before" > "$GUARD/missing.before"

# ── Remove packages (remove.list) ────────────────────────────────────────────
# Entries are shell globs over package names; lines starting with ! keep what
# they match. One `pacman -Rddn`: no dependency checks (what depends on a
# removed build tool keeps working without it), no .pacsave files.
#
# No pacman hook may run: removing linux-headers would fire DKMS's remove hook
# and delete the nvidia/wl modules built against them, and the rest (sysusers,
# tmpfiles, schemas, …) have nothing left to do. A same-named hook in
# /etc/pacman.d/hooks linked to /dev/null disables a system one; scriptlets
# are skipped with --noscriptlet. /etc/pacman.d goes with the package manager.
log "Removing packages from remove.list"
mkdir -p /etc/pacman.d/hooks
for _h in /usr/share/libalpm/hooks/*.hook; do
    [ -e "$_h" ] && ln -sf /dev/null "/etc/pacman.d/hooks/$(basename "$_h")"
done

PATTERNS=(); EXCLUDES=()
while IFS= read -r _e; do
    [ -n "$_e" ] || continue
    case "$_e" in
        '!'*) EXCLUDES+=("${_e#!}") ;;
        *)    PATTERNS+=("$_e") ;;
    esac
done <<< "$(list_entries /remove.list)"

PURGE=()
while read -r _pkg; do
    [ -n "$_pkg" ] || continue
    for _x in "${EXCLUDES[@]}"; do
        # shellcheck disable=SC2053  # unquoted on purpose: glob match
        [[ $_pkg == $_x ]] && continue 2
    done
    for _p in "${PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ $_pkg == $_p ]]; then PURGE+=("$_pkg"); break; fi
    done
done <<< "$(pacman -Qq)"

if [ "${#PURGE[@]}" -gt 0 ]; then
    log "  ${#PURGE[@]} packages: ${PURGE[*]}"
    pacman -Rddn --noconfirm --noprogressbar --noscriptlet "${PURGE[@]}"
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

# ── Shared-library guard, part 2 ─────────────────────────────────────────────
# A soname needed by a file that is still in the image, resolvable before the
# removals and not now, is a removal that broke something: fail here, at build
# time, instead of with a black screen at boot.
sonames_present > "$GUARD/present.after"
comm -23 "$GUARD/needed.sonames" "$GUARD/present.after" \
    | comm -23 - "$GUARD/missing.before" > "$GUARD/broken"
BROKEN=0
while IFS= read -r _so; do
    [ -n "$_so" ] || continue
    _users=$(awk -F'\t' -v so="$_so" '$1 == so {print $2}' "$GUARD/needed" \
             | while read -r _f; do if [ -e "$_f" ]; then echo "$_f"; fi; done \
             | head -3 | tr '\n' ' ' || true)
    [ -n "$_users" ] || continue    # only files that were removed too need it
    echo "  [clean] ERROR: $_so was removed but is needed by: $_users" >&2
    BROKEN=1
done < "$GUARD/broken"
rm -rf "$GUARD"
[ "$BROKEN" -eq 0 ] || { echo "  [clean] remove.list/remove-files.list removed libraries the image needs" >&2; exit 1; }
log "No needed shared library was removed"

# Static and libtool archives, wherever they are.
find /usr/lib \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true

# ── Drop setuid from mount/umount ────────────────────────────────────────────
# They stay for root, but user mounts need fstab `user` entries (there are
# none), and udisks / fusermount3 cover removable drives and FUSE.
chmod u-s /usr/bin/mount /usr/bin/umount
# mount.cifs (cifs-utils, via Samba's client libs): gvfs-smb uses libsmbclient,
# not kernel CIFS mounts. libgtop_server2: only needed where /proc is not
# world-readable. wall/write (setgid tty): messages to other users' terminals;
# there are no text logins.
for _f in /usr/bin/mount.cifs /usr/lib/libgtop/libgtop_server2 /usr/bin/wall /usr/bin/write; do
    [ -e "$_f" ] && chmod ug-s "$_f"
done

# What still runs with privileges, for the build log (compare with the list in
# CLAUDE.md / remove-files.list).
log "setuid/setgid files left:"
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | sort | sed 's/^/      /'

# ── Wallpapers: keep only larch-os's own ─────────────────────────────────────
log "Trimming wallpapers"
find /usr/share/backgrounds -mindepth 1 -maxdepth 1 ! -name larch -exec rm -rf {} + 2>/dev/null || true
find /usr/share/gnome-background-properties -mindepth 1 ! -name 'larch.xml' -delete 2>/dev/null || true
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
