#!/bin/bash
# system/desktops/gnome/setup.sh — GNOME-specific configuration
# Runs inside the desktop's chroot after its packages.list is installed
# (scripts/setup-desktop.sh, system stage 5). The GNOME config files
# themselves are in ./rootfs-overlay (GDM Wayland-only gdm/custom.conf,
# gschema defaults, the wallpaper entry).

set -euo pipefail

# GDM is the display manager (display-manager.service).
systemctl enable gdm
