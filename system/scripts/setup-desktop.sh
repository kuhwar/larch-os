#!/bin/bash
# scripts/setup-desktop.sh — runs INSIDE a desktop's copy of the base rootfs
# Called by system/build.sh (stage 5) as:
#   chroot work/desktops/<desktop> /setup-desktop.sh
# with system/desktops/<desktop>/packages.list as /desktop-packages.list and,
# if the desktop has one, its setup.sh as /desktop-setup.sh.
#
# The kernel stays the base's: every desktop image of a release must carry
# modules for the one vmlinuz the release ships, so it is held here.

set -euo pipefail

log() { echo "  [desktop] $*"; }
export DEBIAN_FRONTEND=noninteractive

apt-mark hold 'linux-image-*' 'linux-headers-*' >/dev/null 2>&1 || true
apt-get update -qq

log "Installing desktop packages"
PKGS=$(grep -v '^#' /desktop-packages.list | grep -v '^[[:space:]]*$' | tr '\n' ' ')
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS

if [ -f /desktop-setup.sh ]; then
    log "Running the desktop's setup.sh"
    bash /desktop-setup.sh
fi

# The display manager the desktop enabled must be the only one.
[ -L /etc/systemd/system/display-manager.service ] \
    || { echo "ERROR: the desktop enabled no display manager (display-manager.service)" >&2; exit 1; }

apt-get clean
rm -rf /var/lib/apt/lists/*
log "Desktop setup complete"
