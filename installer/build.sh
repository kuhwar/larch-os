#!/bin/bash
# installer/build.sh — build the Larch OS installer ISO (runs inside the builder)
#
# The ISO holds only the installer: GRUB, the system's (Arch) kernel and
# installer.initramfs. No system files — the installer downloads the system
# release and desktop the user picks. The kernel, drivers, firmware and tools all come from the
# system's base rootfs, so this needs work/rootfs from system stages 2-4
# (./docker-build.sh system --to 4).
#
# Stages:
#   1. check-deps          — verify build tools and the system rootfs
#   2. installer-initramfs — build installer.initramfs
#   3. assemble-iso        — the ISO tree (work/installer-iso/)
#   4. make-iso            — grub-mkrescue → $LARCH_OUTPUT_DIR/larch-installer.iso (UEFI only)
#
#   ./docker-build.sh installer [--stage N | --only N | --to N]

set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$INSTALLER_DIR")"
WORK_DIR="$ROOT_DIR/work"
ROOTFS_DIR="$WORK_DIR/rootfs"
INITRAMFS="$WORK_DIR/installer.initramfs"
ISO_ROOT="$WORK_DIR/installer-iso"
OUTPUT_ISO="${LARCH_OUTPUT_DIR:-$ROOT_DIR/output}/larch-installer.iso"
GRUB_EFI_DIR="/usr/lib/grub/x86_64-efi"

# shellcheck source=../shared/build-lib.sh
. "$ROOT_DIR/shared/build-lib.sh"

BUILD_NAME="installer"
END_STAGE=4
parse_stage_args "$@"

[ "$(id -u)" -eq 0 ] || die "Must run as root inside the privileged builder (chroot for ldd) — use ./docker-build.sh"
mkdir -p "$WORK_DIR"

# ── Stage 1: check-deps ──────────────────────────────────────────────────────
run_stage 1 "check-deps" && {
    MISSING=()
    for cmd in xorriso grub-mkrescue cpio find gzip; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done
    [ -f "$GRUB_EFI_DIR/modinfo.sh" ] || MISSING+=("grub (GRUB x86_64-efi platform)")
    if [ "${#MISSING[@]}" -gt 0 ]; then
        printf 'Missing build tools in the builder image: %s\n' "${MISSING[*]}" >&2
        exit 1
    fi
    [ -d "$ROOTFS_DIR/usr/lib/modules" ] && [ -f "$(find_vmlinuz)" ] \
        || die "No system base rootfs in work/rootfs — build it first: ./docker-build.sh system --to 4"
    info "All dependencies found (kernel $(rootfs_kver))"
}

# ── Stage 2: installer-initramfs ─────────────────────────────────────────────
run_stage 2 "installer-initramfs — build installer.initramfs" && {
    build_dir="$WORK_DIR/installer-initramfs"
    init_initramfs_tree "$build_dir" "$INSTALLER_DIR/initramfs/init"
    # Exactly the updater's drivers: every disk and network driver of the
    # larch OS kernel, with their firmware — the installer has to find the
    # disk and get online on any hardware larch OS runs on.
    bundle_modules "$build_dir" 1 "$MODS_BASE" "$MODS_DISK" "$MODS_INPUT" "$MODS_NET"
    bundle_network "$build_dir"
    bundle_dialog "$build_dir" installer

    install -m 755 "$INSTALLER_DIR/install.sh" "$build_dir/usr/sbin/larch-install"
    install -m 644 "$INSTALLER_DIR/lib/"*.sh "$build_dir/usr/lib/larch/"

    # User/group names the image already uses (root, daemon, man, gdm, ...), so
    # the derived username never clashes with one. "larch" is left out: it is
    # the UID-1000 placeholder the installed user replaces. (The installer
    # checks again against the image it downloads.)
    cut -d: -f1 "$ROOTFS_DIR/etc/passwd" "$ROOTFS_DIR/etc/group" \
        | grep -vx larch | sort -u > "$build_dir/usr/lib/larch/reserved-names"

    # Partitioning and formatting (sfdisk, wipefs, mkfs.fat, mkfs.ext4), and
    # openssl as the password-hash fallback.
    for bin in sfdisk wipefs mkfs.fat mkfs.ext4 e2fsck openssl; do
        copy_bin_with_libs "$bin" "$build_dir"
    done
    # OpenSSL 3 dlopens its provider modules — invisible to ldd. Without the
    # default provider, `openssl passwd -6` fails.
    ossl_mods_src=$(find "$ROOTFS_DIR/usr/lib" -type d -name ossl-modules 2>/dev/null | head -1)
    if [ -n "$ossl_mods_src" ]; then
        mkdir -p "$build_dir${ossl_mods_src#$ROOTFS_DIR}"
        cp -a "$ossl_mods_src/." "$build_dir${ossl_mods_src#$ROOTFS_DIR}/"
    fi

    pack_initramfs "$build_dir" "$INITRAMFS"
}

# ── Stage 3: assemble-iso ────────────────────────────────────────────────────
run_stage 3 "assemble-iso — the ISO tree" && {
    [ -f "$INITRAMFS" ] || die "installer.initramfs not found — run installer stage 2 first"
    rm -rf "$ISO_ROOT"
    mkdir -p "$ISO_ROOT/boot/grub"
    install -m 644 "$INSTALLER_DIR/grub.cfg" "$ISO_ROOT/boot/grub/grub.cfg"
    install -m 644 "$(find_vmlinuz)" "$ISO_ROOT/vmlinuz"
    install -m 644 "$INITRAMFS" "$ISO_ROOT/installer.initramfs"
    du -sh "$ISO_ROOT"
}

# ── Stage 4: make-iso ────────────────────────────────────────────────────────
run_stage 4 "make-iso — grub-mkrescue (UEFI only)" && {
    [ -f "$ISO_ROOT/installer.initramfs" ] || die "ISO tree not assembled — run installer stage 3 first"
    mkdir -p "$(dirname "$OUTPUT_ISO")"
    rm -f "$OUTPUT_ISO"
    # UEFI only: pinning one GRUB platform directory leaves out the BIOS El
    # Torito entry. LARCHISO is the ISO9660 volume label; the installer leaves
    # disks carrying it out of the target list.
    grub-mkrescue -d "$GRUB_EFI_DIR" -o "$OUTPUT_ISO" "$ISO_ROOT" -- -volid LARCHISO 2>/dev/null || \
        grub-mkrescue -d "$GRUB_EFI_DIR" -o "$OUTPUT_ISO" "$ISO_ROOT"
    info "$OUTPUT_ISO ($(du -sh "$OUTPUT_ISO" | cut -f1))"
}

log "Installer build: stages $START_STAGE-$END_STAGE complete"
