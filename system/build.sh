#!/bin/bash
# system/build.sh — build the Larch OS system release (runs inside the builder)
#
# One release serves every desktop environment. It is built from one base
# rootfs (kernel, drivers, shared services) and one copy of it per desktop
# (system/desktops/<desktop>/), and published as these files in
# $LARCH_OUTPUT_DIR/system/ (default output/system/):
#
#   sys-<desktop>.squashfs  one OS root per desktop (installed as LARCHSYS:/sys.squashfs)
#   vmlinuz                 Debian's kernel — the same for every desktop
#   sys.initramfs           boots the system: mounts the root and /etc, /var
#   updater.initramfs       the "Update LARCH" boot entry
#   SHA256SUMS
#
# Stages:
#   1. check-deps        — verify build tools
#   2. debootstrap       — create the Debian Trixie base (work/rootfs)
#   3. base-overlay      — merge rootfs-overlay/ and the bootloader configs into it
#   4. base-configure    — scripts/setup-chroot.sh in the base (kernel, drivers, services)
#   5. desktops          — per desktop: copy the base to work/desktops/<desktop>,
#                          install the desktop (scripts/setup-desktop.sh), apply its
#                          rootfs-overlay/, strip the package manager (clean-rootfs.sh)
#   6. make-squashfs     — per desktop: sys-<desktop>.squashfs
#   7. sys-initramfs     — sys.initramfs (from the base)
#   8. updater-initramfs — updater.initramfs (from the base)
#   9. release-files     — vmlinuz + SHA256SUMS
#
# The base is never cleaned (stage 5 cleans the copies), so stage 5 can be
# re-run at will. The installer build needs only the base: stages 1-4.
#
# Run via the container (see docker-build.sh):
#   ./docker-build.sh system                      # all stages, every desktop
#   ./docker-build.sh system --desktop gnome      # only some desktops (repeatable;
#                                                 #  or LARCH_DESKTOPS="gnome kde")
#   ./docker-build.sh system --stage 5            # from stage 5 on
#   ./docker-build.sh system --only 7             # exactly one stage
#   ./docker-build.sh system --to 4               # just the base (for the installer)

set -euo pipefail

SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SYSTEM_DIR")"
WORK_DIR="$ROOT_DIR/work"
ROOTFS_DIR="$WORK_DIR/rootfs"            # the base; build-lib.sh takes tools/modules from it
DESKTOPS_WORK="$WORK_DIR/desktops"
OUT_DIR="${LARCH_OUTPUT_DIR:-$ROOT_DIR/output}/system"
LARCH_VERSION="${LARCH_VERSION:-dev-$(date -u +%Y%m%d%H%M)}"

# shellcheck source=../shared/build-lib.sh
. "$ROOT_DIR/shared/build-lib.sh"

DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_SUITE="trixie"
DEBIAN_ARCH="amd64"
DEBOOTSTRAP_INCLUDE="bash,ca-certificates,locales,systemd"

# ── Arguments ────────────────────────────────────────────────────────────────
DESKTOPS="${LARCH_DESKTOPS:-}"
STAGE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop) DESKTOPS="$DESKTOPS $2"; shift 2 ;;
        *) STAGE_ARGS+=("$1"); shift ;;
    esac
done
if [ -z "${DESKTOPS// /}" ]; then
    DESKTOPS=$(cd "$SYSTEM_DIR/desktops" && ls -d -- */ | tr -d / | tr '\n' ' ')
fi
for de in $DESKTOPS; do
    [[ "$de" =~ ^[a-z0-9]+$ ]] || die "Desktop names are lowercase letters/digits: '$de'"
    [ -f "$SYSTEM_DIR/desktops/$de/packages.list" ] || die "No system/desktops/$de/packages.list"
done

BUILD_NAME="system"
END_STAGE=9
parse_stage_args "${STAGE_ARGS[@]}"

[ "$(id -u)" -eq 0 ] || die "Must run as root inside the privileged builder (chroot, mknod, …) — use ./docker-build.sh"
mkdir -p "$WORK_DIR" "$OUT_DIR"
info "Desktops: $DESKTOPS"

# chroot_run <root> <script> [file…]: copy <script> and the files into <root>
# (each as /<its basename>, or /<name> for "path:name") and run it there.
chroot_run() {
    local root="$1" script="$2" dep; shift 2
    install -m 755 "$script" "$root/$(basename "$script")"
    for dep in "$@"; do
        if [[ "$dep" == *:* ]]; then cp "${dep%%:*}" "$root/${dep#*:}"
        else cp "$dep" "$root/$(basename "$dep")"; fi
    done
    chroot "$root" "/$(basename "$script")"
}

mount_chroot_pseudofs() {
    local root="$1"
    info "Mounting proc/sys/dev inside $root"
    mount --bind /proc "$root/proc"
    mount --bind /sys  "$root/sys"
    # /dev must be bound recursively. Rootless Podman can't mknod, so the
    # container's /dev is a tmpfs of empty placeholder files with each device
    # node (null, zero, urandom, pts, …) bind-mounted over its placeholder. A
    # plain --bind skips those submounts: the chroot then sees /dev/null as a
    # regular, writable file, every `>/dev/null` appends to it, and every
    # `cat … /dev/null` replays the junk (this broke the NVIDIA DKMS conftest).
    # rslave keeps the recursive unmount below from propagating back.
    mount --rbind /dev "$root/dev"
    mount --make-rslave "$root/dev"
    CHROOT_MOUNTED="$root"
}

umount_chroot_pseudofs() {
    local root="${1:-${CHROOT_MOUNTED:-}}"
    [ -n "$root" ] || return 0
    umount -Rl "$root/dev"  2>/dev/null || true
    umount -lf "$root/sys"  2>/dev/null || true
    umount -lf "$root/proc" 2>/dev/null || true
    # Under rootless Podman, debootstrap leaves the rootfs's own /dev/null as a
    # regular file (no mknod). Empty it so nothing written there by an earlier
    # build ships in the squashfs (devtmpfs hides it at runtime anyway).
    if [ -f "$root/dev/null" ] && [ ! -L "$root/dev/null" ]; then
        : > "$root/dev/null"
    fi
    CHROOT_MOUNTED=""
}
trap umount_chroot_pseudofs EXIT

require_rootfs() {
    [ -d "$ROOTFS_DIR/usr" ] || die "Larch OS base rootfs not found — run system stages 2-4 first"
}

desktop_root() { echo "$DESKTOPS_WORK/$1"; }

# A list file for clean-rootfs.sh: the base list plus the desktop's own.
merged_list() {
    local name="$1" de="$2"
    local out="$WORK_DIR/$de.$name"
    cat "$SYSTEM_DIR/config/$name" > "$out"
    [ -f "$SYSTEM_DIR/desktops/$de/$name" ] && cat "$SYSTEM_DIR/desktops/$de/$name" >> "$out"
    echo "$out:$name"
}

# ── Stage 1: check-deps ──────────────────────────────────────────────────────
run_stage 1 "check-deps" && {
    MISSING=()
    for cmd in debootstrap mksquashfs rsync cpio find xz gzip sha256sum; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done
    if [ "${#MISSING[@]}" -gt 0 ]; then
        printf 'Missing build tools in the builder image: %s\n' "${MISSING[*]}" >&2
        echo "They come from the Dockerfile; ./docker-build.sh rebuilds the image." >&2
        exit 1
    fi
    info "All dependencies found"
}

# ── Stage 2: debootstrap ─────────────────────────────────────────────────────
run_stage 2 "debootstrap — create the Debian base rootfs" && {
    if [ -d "$ROOTFS_DIR/usr" ]; then
        info "Base rootfs already exists, skipping debootstrap. Use --clean to restart."
    else
        mkdir -p "$ROOTFS_DIR"
        debootstrap --arch="$DEBIAN_ARCH" --include="$DEBOOTSTRAP_INCLUDE" \
            "$DEBIAN_SUITE" "$ROOTFS_DIR" "$DEBIAN_MIRROR"
    fi
}

# ── Stage 3: base-overlay ────────────────────────────────────────────────────
run_stage 3 "base-overlay — merge rootfs-overlay" && {
    require_rootfs
    copy_overlay "$SYSTEM_DIR/rootfs-overlay" "$ROOTFS_DIR"
    # Bases from before the bootloader became release files (stage 9).
    rm -rf "$ROOTFS_DIR/usr/lib/larch/boot"
}

# ── Stage 4: base-configure ──────────────────────────────────────────────────
run_stage 4 "base-configure — install the base packages and configure" && {
    require_rootfs
    mount_chroot_pseudofs "$ROOTFS_DIR"
    # The image's resolv.conf is a symlink into /run (set below); replace it
    # with the builder's for apt, without following the link.
    rm -f "$ROOTFS_DIR/etc/resolv.conf"
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
    chroot_run "$ROOTFS_DIR" "$SYSTEM_DIR/scripts/setup-chroot.sh" \
        "$SYSTEM_DIR/config/packages.list" "$SYSTEM_DIR/config/remove.list"
    rm -f "$ROOTFS_DIR/setup-chroot.sh" "$ROOTFS_DIR/packages.list" "$ROOTFS_DIR/remove.list"
    umount_chroot_pseudofs
}

# ── Stage 5: desktops ────────────────────────────────────────────────────────
run_stage 5 "desktops — install each desktop on a copy of the base" && {
    require_rootfs
    for de in $DESKTOPS; do
        root=$(desktop_root "$de")
        dsrc="$SYSTEM_DIR/desktops/$de"
        info "[$de] Copying the base → $root"
        mkdir -p "$root"
        rsync -aHAX --numeric-ids --delete "$ROOTFS_DIR/" "$root/"

        mount_chroot_pseudofs "$root"
        rm -f "$root/etc/resolv.conf"
        cp /etc/resolv.conf "$root/etc/resolv.conf"
        deps=("$dsrc/packages.list:desktop-packages.list")
        [ -f "$dsrc/setup.sh" ] && deps+=("$dsrc/setup.sh:desktop-setup.sh")
        chroot_run "$root" "$SYSTEM_DIR/scripts/setup-desktop.sh" "${deps[@]}"
        # After the packages, so the desktop's files win over package defaults
        # without dpkg conffile prompts.
        [ -d "$dsrc/rootfs-overlay" ] && copy_overlay "$dsrc/rootfs-overlay" "$root"
        info "[$de] Stripping the package manager"
        chroot_run "$root" "$SYSTEM_DIR/scripts/clean-rootfs.sh" \
            "$(merged_list remove.list "$de")" "$(merged_list remove-files.list "$de")"
        # Root is mounted read-only, so NetworkManager can't rewrite
        # /etc/resolv.conf; point it at the file NM keeps in /run.
        rm -f "$root/etc/resolv.conf"
        ln -s ../run/NetworkManager/resolv.conf "$root/etc/resolv.conf"
        umount_chroot_pseudofs
    done
}

# ── Stage 6: make-squashfs ───────────────────────────────────────────────────
run_stage 6 "make-squashfs — one sys-<desktop>.squashfs per desktop" && {
    for de in $DESKTOPS; do
        root=$(desktop_root "$de")
        [ -d "$root/usr" ] || die "No rootfs for desktop $de — run stage 5 first"
        # The image is the root of every install as-is, so it carries no
        # machine identity: the installer writes machine-id into /etc's upper
        # layer, and an empty file here keeps systemd from treating a missing
        # one as a first boot. D-Bus's copy follows it.
        : > "$root/etc/machine-id"
        ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
        # What the image is: shown by the updater, checked by release.sh.
        printf '%s\n' "$LARCH_VERSION" > "$root/usr/lib/larch/version"
        printf '%s\n' "$de" > "$root/usr/lib/larch/desktop"
        out="$OUT_DIR/sys-$de.squashfs"
        rm -f "$out"
        info "[$de] mksquashfs (version $LARCH_VERSION)"
        # config/squashfs.exclude: build leftovers and /boot (see the file).
        mksquashfs "$root" "$out" \
            -comp zstd -Xcompression-level 19 -no-progress -noappend \
            -wildcards -ef "$SYSTEM_DIR/config/squashfs.exclude"
        info "[$de] $(basename "$out"): $(du -sh "$out" | cut -f1)"
    done
}

# ── Stage 7: sys-initramfs ───────────────────────────────────────────────────
run_stage 7 "sys-initramfs — build sys.initramfs" && {
    require_rootfs
    build_dir="$WORK_DIR/sys-initramfs"
    init_initramfs_tree "$build_dir" "$SYSTEM_DIR/initramfs/sys/init"
    # The same disk drivers (and their firmware) as the installer and the
    # updater, filesystems and a keyboard (for the rescue shell). No network:
    # systemd's udev loads everything else from the image.
    bundle_modules "$build_dir" 1 "$MODS_BASE" "$MODS_DISK" "$MODS_INPUT"
    copy_bin_with_libs e2fsck "$build_dir"
    pack_initramfs "$build_dir" "$OUT_DIR/sys.initramfs"
}

# ── Stage 8: updater-initramfs ───────────────────────────────────────────────
run_stage 8 "updater-initramfs — build updater.initramfs" && {
    require_rootfs
    build_dir="$WORK_DIR/updater-initramfs"
    init_initramfs_tree "$build_dir" "$SYSTEM_DIR/initramfs/updater/init"
    # Exactly the installer's drivers: every disk and network driver of the
    # image's kernel, with their firmware.
    bundle_modules "$build_dir" 1 "$MODS_BASE" "$MODS_DISK" "$MODS_INPUT" "$MODS_NET"
    bundle_network "$build_dir"
    bundle_dialog "$build_dir" updater
    copy_bin_with_libs e2fsck "$build_dir"
    install -m 755 "$SYSTEM_DIR/updater/update.sh" "$build_dir/usr/sbin/larch-update"
    pack_initramfs "$build_dir" "$OUT_DIR/updater.initramfs"
}

# ── Stage 9: release-files ───────────────────────────────────────────────────
run_stage 9 "release-files — vmlinuz, bootloader, entries and SHA256SUMS" && {
    require_rootfs
    VMLINUZ="$(find_vmlinuz)"
    [ -f "$VMLINUZ" ] || die "Kernel vmlinuz not found in rootfs/boot"
    kver=$(rootfs_kver)
    install -m 644 "$VMLINUZ" "$OUT_DIR/vmlinuz"
    # systemd-boot from the base (systemd-boot-efi; the images don't carry it)
    # and its config from bootloader/, as release files shared by every
    # desktop: the installer and updater put them on LARCHEFI.
    efi="$ROOTFS_DIR/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
    [ -f "$efi" ] || die "No systemd-bootx64.efi in the base rootfs (systemd-boot-efi in packages.list) — run stage 4"
    install -m 644 "$efi" "$OUT_DIR/BOOTX64.EFI"
    loader_dir="$WORK_DIR/loader"
    rm -rf "$loader_dir"
    install -D -m 644 "$SYSTEM_DIR/bootloader/loader.conf" "$loader_dir/loader/loader.conf"
    install -d "$loader_dir/loader/entries"
    install -m 644 "$SYSTEM_DIR/bootloader/entries/"*.conf "$loader_dir/loader/entries/"
    tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -cf "$OUT_DIR/loader.tar" -C "$loader_dir" loader
    files=(vmlinuz sys.initramfs updater.initramfs BOOTX64.EFI loader.tar)
    for f in sys.initramfs updater.initramfs; do
        [ -f "$OUT_DIR/$f" ] || die "$OUT_DIR/$f is missing — run stages 7-8 first"
    done
    for de in $DESKTOPS; do
        [ -f "$OUT_DIR/sys-$de.squashfs" ] || die "$OUT_DIR/sys-$de.squashfs is missing — run stages 5-6 first"
        [ -d "$(desktop_root "$de")/usr/lib/modules/$kver" ] \
            || die "The $de image has no modules for the release's kernel $kver — rebuild it from stage 5"
        files+=("sys-$de.squashfs")
    done
    # An image of a desktop not built this time may belong to another kernel.
    for f in "$OUT_DIR"/sys-*.squashfs; do
        [ -e "$f" ] || continue
        case " ${files[*]} " in *" $(basename "$f") "*) ;; *)
            info "Removing $(basename "$f") (not part of this build)"; rm -f "$f" ;;
        esac
    done
    (cd "$OUT_DIR" && sha256sum "${files[@]}" > SHA256SUMS)
    info "Release files in $OUT_DIR (kernel $kver):"
    (cd "$OUT_DIR" && ls -lh "${files[@]}" SHA256SUMS)
}

log "System build: stages $START_STAGE-$END_STAGE complete"
