#!/bin/bash
# docker-entrypoint.sh — the builder container's ENTRYPOINT
#
# Larch OS is built ONLY inside the privileged builder container: the builds
# need `mknod` (debootstrap), `mount --bind` of proc/sys/dev and `chroot`,
# none of which are available during an unprivileged `docker build`. Use
# ./docker-build.sh to launch it; its arguments are forwarded here.
#
# Two builds, each in its own directory:
#   system     system/build.sh    → output/system/ (sys-<desktop>.squashfs per
#                                   desktop, vmlinuz, sys.initramfs,
#                                   updater.initramfs, SHA256SUMS)
#   installer  installer/build.sh → output/larch-installer.iso
#                                   (needs the base rootfs from system stages 2-4)
#
# Usage:
#   docker-entrypoint.sh                           # both (system, then installer)
#   docker-entrypoint.sh system [--stage N | --only N | --to N]
#   docker-entrypoint.sh installer [--stage N | --only N | --to N]
#   docker-entrypoint.sh --clean                   # delete work/ and the outputs

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${LARCH_OUTPUT_DIR:-$ROOT_DIR/output}"

case "${1:-all}" in
    system)    shift; exec "$ROOT_DIR/system/build.sh" "$@" ;;
    installer) shift; exec "$ROOT_DIR/installer/build.sh" "$@" ;;
    all)
        [ $# -le 1 ] || { echo "Stage flags need a target: system or installer" >&2; exit 1; }
        "$ROOT_DIR/system/build.sh"
        exec "$ROOT_DIR/installer/build.sh"
        ;;
    --clean)
        for mnt in proc sys dev/pts dev; do
            umount -lf "$ROOT_DIR/work/rootfs/$mnt" 2>/dev/null || true
        done
        rm -rf "$ROOT_DIR/work" "$OUT/system" "$OUT/larch-installer.iso"
        echo "Clean complete."
        ;;
    *) echo "Unknown target: $1 (system, installer or none for both)" >&2; exit 1 ;;
esac
