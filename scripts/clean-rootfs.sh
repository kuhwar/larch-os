#!/bin/bash
# scripts/clean-rootfs.sh — runs INSIDE the chroot as the final step before squashfs
# Strips the package manager and anything else that must not be in the final image.
# Called by docker-entrypoint.sh (stage 5) as: chroot work/rootfs /clean-rootfs.sh
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

# ── iwlwifi firmware the kernel can't load (~120 MB raw) ─────────────────────
# linux-firmware ships several API versions per Intel Wi-Fi chip. iwlwifi
# requests from its newest supported API downwards and loads the first that
# exists, so for each chip only the highest version <= the kernel's maximum is
# ever used: newer ones (and the -c<N> naming of newer kernels) can't load,
# older ones are shadowed. The maxima come from this kernel's own modules
# (modinfo), so the trim follows kernel upgrades. Chips the kernel doesn't list
# (iwlegacy's 3945/4965, …) are capped at the highest API it lists. .pnvm files
# stay. Skipped if iwlwifi is built in (no module to read).
FW=/usr/lib/firmware
IWL=$FW/intel/iwlwifi
IWL_REQ=$(find /usr/lib/modules -path '*/iwlwifi/*' -name '*.ko*' \
    -exec modinfo -F firmware {} \; 2>/dev/null | grep '^iwlwifi-' | sort -u || true)
if [ -d "$IWL" ] && [ -n "$IWL_REQ" ]; then
    log "Trimming iwlwifi firmware to what the kernel loads"
    printf '%s\n' "$IWL_REQ" > /tmp/iwl-req
    # shellcheck disable=SC2016
    IWL_DROP=$(ls "$IWL" | awk '
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
    for f in $IWL_DROP; do rm -f "$IWL/$f"; done
    rm -f /tmp/iwl-req
fi
# linux-firmware's compatibility symlinks (e.g. /usr/lib/firmware/iwlwifi-*.ucode
# → intel/iwlwifi/) dangle for everything removed from the firmware tree.
find "$FW" -xtype l -delete

# ── Wallpapers: keep only larch-os's own ─────────────────────────────────────
# rootfs-overlay/usr/share/backgrounds/larch, set by 90_larch.gschema.override.
# Drop any other a dependency pulled in, so GNOME Settings → Appearance offers
# just that one. desktop-base (purged above) may leave its schema override.
log "Trimming wallpapers"
find /usr/share/backgrounds -mindepth 1 -maxdepth 1 ! -name larch -exec rm -rf {} + 2>/dev/null || true
find /usr/share/gnome-background-properties -mindepth 1 ! -name 'larch.xml' -delete 2>/dev/null || true
rm -f /usr/share/glib-2.0/schemas/10_desktop-base.gschema.override
glib-compile-schemas /usr/share/glib-2.0/schemas

# ── Mark /etc and /var as up to date with /usr ───────────────────────────────
# ConditionNeedsUpdate= (ldconfig, systemd-sysusers, systemd-update-done)
# compares /usr's mtime against /etc/.updated and /var/.updated. Without them in
# the image, those services would run on the first boot after every install.
# Written last, so /usr's mtime is final.
log "Stamping /etc/.updated and /var/.updated"
/usr/lib/systemd/systemd-update-done

# ── Remove build scripts from rootfs ─────────────────────────────────────────
log "Removing build scripts from rootfs"
rm -f /setup-chroot.sh /clean-rootfs.sh /packages.list /remove.list /remove-files.list

log "Rootfs clean complete"
