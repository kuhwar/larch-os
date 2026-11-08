#!/bin/bash
# scripts/setup-desktop.sh — runs INSIDE a desktop's copy of the base rootfs
# Called by system/build.sh (stage 5) as:
#   chroot work/desktops/<desktop> /setup-desktop.sh
# with system/desktops/<desktop>/packages.list as /desktop-packages.list and,
# if the desktop has one, its setup.sh as /desktop-setup.sh.
#
# The sync databases are the base's (stage 4) and are not refreshed: the
# desktop comes from the same Arch snapshot as the base, so nothing the base
# has (the kernel above all — every desktop image must carry modules for the
# one vmlinuz the release ships) is upgraded and there is no partial upgrade.

set -euo pipefail

log() { echo "  [desktop] $*"; }

log "Installing desktop packages"
PKGS=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' /desktop-packages.list | grep -v '^$' | tr '\n' ' ')
# --overwrite: a base rootfs-overlay file may sit where a package ships one;
# build.sh copies both overlays again after this script.
# shellcheck disable=SC2086
pacman -S --needed --noconfirm --noprogressbar --ignore linux,linux-headers \
    --overwrite '/etc/*' $PKGS

if [ -f /desktop-setup.sh ]; then
    log "Running the desktop's setup.sh"
    bash /desktop-setup.sh
fi

# The display manager the desktop enabled must be the only one.
[ -L /etc/systemd/system/display-manager.service ] \
    || { echo "ERROR: the desktop enabled no display manager (display-manager.service)" >&2; exit 1; }

rm -rf /var/cache/pacman/pkg/*
log "Desktop setup complete"
