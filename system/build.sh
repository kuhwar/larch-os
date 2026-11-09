#!/bin/bash
# system/build.sh — build the Larch OS system release (runs inside the builder)
#
# One release serves every desktop environment. It is built from one base
# rootfs (kernel, drivers, shared services) and one copy of it per desktop
# (system/desktops/<desktop>/), and published as these files in
# $LARCH_OUTPUT_DIR/system/ (default output/system/):
#
#   sys-<desktop>.squashfs  one OS root per desktop (installed as LARCHSYS:/sys.squashfs)
#   vmlinuz                 Fedora's kernel — the same for every desktop
#   sys.initramfs           boots the system: mounts the root and /etc, /var
#   updater.initramfs       the "Update LARCH" boot entry
#   BOOTX64.EFI, loader.tar systemd-boot and its configuration
#   SHA256SUMS
#
# Every package is installed by the BUILDER's dnf (--installroot, the builder's
# Fedora + RPM Fusion repositories, weak dependencies off, no docs), so the
# rootfs never contains a package manager to remove. Out-of-tree kernel modules
# (NVIDIA, Broadcom wl) are compiled by akmods in the builder too, against the
# rootfs's kernel, and installed as kmod RPMs: no compiler enters the image.
#
# Stages:
#   1. check-deps        — verify build tools
#   2. bootstrap         — Fedora's filesystem + generic-release into work/rootfs
#   3. base-overlay      — merge rootfs-overlay/
#   4. base-configure    — packages.list, the kmods (akmods), scripts/setup-chroot.sh
#   5. desktops          — per desktop: copy the base to work/desktops/<desktop>,
#                          install its packages, run its setup, apply its
#                          rootfs-overlay/, strip it (remove.list, orphans,
#                          remove-files.list, scripts/clean-rootfs.sh), and check
#                          that no library anything still links was removed
#   6. make-squashfs     — per desktop: sys-<desktop>.squashfs
#   7. sys-initramfs     — sys.initramfs (from the base)
#   8. updater-initramfs — updater.initramfs (from the base)
#   9. release-files     — vmlinuz, BOOTX64.EFI, loader.tar, SHA256SUMS
#
# The base is never stripped (stage 5 strips the copies), so stage 5 can be
# re-run at will. The installer build needs only the base: stages 1-4.
#
# Run via the container (see docker-build.sh):
#   ./docker-build.sh system                      # all stages, every desktop
#   ./docker-build.sh system --desktop gnome      # only some desktops
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

FEDORA_RELEASE="$(list_entries "$SYSTEM_DIR/config/fedora-release" | head -1)"
[[ "$FEDORA_RELEASE" =~ ^[0-9]+$ ]] || die "config/fedora-release must be a Fedora release number"
KMOD_DIR="$WORK_DIR/kmods"               # kmod RPMs akmods built for the base's kernel
DNF_CACHE="$WORK_DIR/dnf-cache"

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

[ "$(id -u)" -eq 0 ] || die "Must run as root inside the privileged builder (chroot, mounts, …) — use ./docker-build.sh"
mkdir -p "$WORK_DIR" "$OUT_DIR"
info "Fedora $FEDORA_RELEASE; desktops: $DESKTOPS"

# dnf_root <root> <dnf args…>: the builder's dnf acting on <root>. Weak
# dependencies (Recommends) are never installed and docs never extracted; the
# image gets exactly the listed packages and what they require.
dnf_root() {
    local root="$1"; shift
    dnf -y -q --installroot="$root" --releasever="$FEDORA_RELEASE" --use-host-config \
        --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        --setopt=keepcache=True --setopt=cachedir="$DNF_CACHE" "$@"
}

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
    mkdir -p "$root"/{proc,sys,dev}
    mount --bind /proc "$root/proc"
    mount --bind /sys  "$root/sys"
    # /dev must be bound recursively: under rootless Podman the container's
    # /dev is a tmpfs of placeholder files with each device node bind-mounted
    # over its placeholder, which a plain --bind would skip. rslave keeps the
    # recursive unmount below from propagating back.
    mount --rbind /dev "$root/dev"
    mount --make-rslave "$root/dev"
    CHROOT_MOUNTED="$root"
}

umount_chroot_pseudofs() {
    local root="${1:-${CHROOT_MOUNTED:-}}" m
    [ -n "$root" ] || return 0
    # Lazy and recursive, never -f: MNT_FORCE needs CAP_SYS_ADMIN in the
    # initial user namespace, so under rootless Podman `umount -f` fails and
    # leaves the mount behind (the next rsync then walks a live /sys). A mount
    # that survives is fatal rather than silently copied.
    for m in dev sys proc; do
        umount -Rl "$root/$m" 2>/dev/null || true
    done
    for m in dev sys proc; do
        if mountpoint -q "$root/$m"; then
            echo "ERROR: could not unmount $root/$m" >&2; exit 1
        fi
    done
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
    echo "$out"
}

# copy_resolv <root>: the builder's resolv.conf for scriptlets that need the
# network (flatpak remote-add), without following the image's symlink.
copy_resolv() {
    rm -f "$1/etc/resolv.conf"
    cp /etc/resolv.conf "$1/etc/resolv.conf"
}

# ── Shared-library guard ─────────────────────────────────────────────────────
# What stage 5 strips must not be a library anything left in the image links.
# guard_record <root> before stripping; guard_check <root> after: every
# DT_NEEDED soname that resolved before must still resolve for each file still
# in the image (sonames already unresolved are optional plugins whose library
# Fedora leaves to another package; they don't count). Runs the builder's
# readelf over the rootfs, so the image needs no binutils.
guard_sonames_present() {
    (cd "$1" && find usr/lib usr/lib64 \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' \) \
        -printf '%f\n' 2>/dev/null) | sort -u
}
guard_record() {
    local root="$1" g="$WORK_DIR/libguard"
    rm -rf "$g"; mkdir -p "$g"
    info "Recording shared-library dependencies"
    (cd "$root" && find usr/bin usr/sbin usr/lib usr/lib64 usr/libexec -type f \
        \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null \
        | xargs -0 -r readelf -d 2>/dev/null \
        | awk '/^File: /{f=$2} /\(NEEDED\)/{gsub(/[][]/,"",$5); print $5 "\t" f}') \
        | sort -u > "$g/needed" || true
    cut -f1 "$g/needed" | sort -u > "$g/needed.sonames"
    guard_sonames_present "$root" > "$g/present.before"
    comm -23 "$g/needed.sonames" "$g/present.before" > "$g/missing.before"
}
guard_check() {
    local root="$1" g="$WORK_DIR/libguard" so users broken=0
    guard_sonames_present "$root" > "$g/present.after"
    comm -23 "$g/needed.sonames" "$g/present.after" | comm -23 - "$g/missing.before" > "$g/broken"
    while IFS= read -r so; do
        [ -n "$so" ] || continue
        users=$(awk -F'\t' -v so="$so" '$1 == so {print $2}' "$g/needed" \
                | while read -r f; do if [ -e "$root/$f" ]; then echo "/$f"; fi; done \
                | head -3 | tr '\n' ' ' || true)
        [ -n "$users" ] || continue    # only files that were removed too needed it
        echo "ERROR: $so was removed but is needed by: $users" >&2
        broken=1
    done < "$g/broken"
    [ "$broken" -eq 0 ] || die "Stage 5 removed libraries the image needs (remove.list / orphans / remove-files.list)"
    info "Library guard: no needed shared library was removed"
}

# ── Stage 1: check-deps ──────────────────────────────────────────────────────
run_stage 1 "check-deps" && {
    MISSING=()
    for cmd in dnf rpm readelf akmodsbuild mksquashfs rsync cpio find xz gzip sha256sum; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done
    if [ "${#MISSING[@]}" -gt 0 ]; then
        printf 'Missing build tools in the builder image: %s\n' "${MISSING[*]}" >&2
        echo "They come from the Dockerfile; ./docker-build.sh rebuilds the image." >&2
        exit 1
    fi
    builder_rel=$(. /etc/os-release && echo "$VERSION_ID")
    [ "$builder_rel" = "$FEDORA_RELEASE" ] \
        || die "The builder is Fedora $builder_rel but config/fedora-release says $FEDORA_RELEASE (Dockerfile FROM)"
    info "All dependencies found"
}

# ── Stage 2: bootstrap ───────────────────────────────────────────────────────
# The filesystem layout and the release identity. generic-release (not
# fedora-release): Fedora's trademark guidelines want derivatives unbranded.
# kernel-install's plugins are disabled before any kernel arrives: every larch
# initramfs is built by hand (no dracut), there is no GRUB/BLS entry to write
# (systemd-boot's entries are release files), and the kernel ships as the
# release's vmlinuz from /usr/lib/modules/<ver>/vmlinuz. 50-depmod stays.
run_stage 2 "bootstrap — Fedora $FEDORA_RELEASE filesystem into work/rootfs" && {
    if [ -d "$ROOTFS_DIR/usr" ]; then
        info "Base rootfs already exists, skipping the bootstrap. Use --clean to restart."
    else
        mkdir -p "$ROOTFS_DIR/etc/kernel/install.d"
        for p in 20-grub 50-dracut 51-dracut-rescue 60-kdump 90-loaderentry 90-uki-copy \
                 92-crashkernel 92-tuned 99-grub-mkconfig; do
            ln -sf /dev/null "$ROOTFS_DIR/etc/kernel/install.d/$p.install"
        done
        mount_chroot_pseudofs "$ROOTFS_DIR"
        dnf_root "$ROOTFS_DIR" install filesystem generic-release
        umount_chroot_pseudofs
    fi
}

# ── Stage 3: base-overlay ────────────────────────────────────────────────────
run_stage 3 "base-overlay — merge rootfs-overlay" && {
    require_rootfs
    copy_overlay "$SYSTEM_DIR/rootfs-overlay" "$ROOTFS_DIR"
}

# ── Stage 4: base-configure ──────────────────────────────────────────────────
run_stage 4 "base-configure — install the base packages and configure" && {
    require_rootfs
    mount_chroot_pseudofs "$ROOTFS_DIR"
    copy_resolv "$ROOTFS_DIR"
    info "Installing config/packages.list"
    # shellcheck disable=SC2046
    dnf_root "$ROOTFS_DIR" install $(list_entries "$SYSTEM_DIR/config/packages.list")
    kver=$(rootfs_kver)
    [ -f "$ROOTFS_DIR/usr/lib/modules/$kver/vmlinuz" ] || die "No vmlinuz for kernel $kver in the rootfs"

    # Out-of-tree modules (config/akmods.list): akmods builds a kmod RPM per
    # akmod for the rootfs's kernel in the builder (kernel-devel of exactly that
    # version; akmodsbuild refuses root, so it runs as akmods' user), and the
    # RPMs go into the rootfs in one transaction with the userspace packages
    # that require them. Rebuilt only when the kernel or the akmod changed.
    info "Building kmods for kernel $kver (akmods, in the builder)"
    AKMODS=(); KMOD_PKGS=()
    while read -r ak rest; do
        [ -n "$ak" ] || continue
        AKMODS+=("$ak"); read -r -a more <<< "$rest"; KMOD_PKGS+=("${more[@]}")
    done < <(list_entries "$SYSTEM_DIR/config/akmods.list")
    dnf -y -q --setopt=install_weak_deps=False install "kernel-devel-$kver" "${AKMODS[@]}"
    id akmods >/dev/null 2>&1 || useradd -r -M -d /var/cache/akmods akmods
    mkdir -p "$KMOD_DIR"
    rpms=()
    for ak in "${AKMODS[@]}"; do
        name=${ak#akmod-}
        srpm=$(readlink -f "/usr/src/akmods/$name-kmod.latest" 2>/dev/null || true)
        [ -f "$srpm" ] || die "No akmods source RPM for $ak (/usr/src/akmods/$name-kmod.latest)"
        stamp="$(basename "$srpm") $kver"
        out="$KMOD_DIR/$name"
        if [ "$(cat "$out/.built" 2>/dev/null)" != "$stamp" ]; then
            info "  akmodsbuild $(basename "$srpm") for $kver"
            rm -rf "$out" "$WORK_DIR/akmods-build"; mkdir -p "$out" "$WORK_DIR/akmods-build"
            chown akmods: "$out" "$WORK_DIR/akmods-build"
            (cd "$WORK_DIR/akmods-build" && runuser -u akmods -- env HOME="$WORK_DIR/akmods-build" \
                akmodsbuild --kernels "$kver" --outputdir "$out" "$srpm") \
                > "$WORK_DIR/akmods-$name.log" 2>&1 \
                || { tail -40 "$WORK_DIR/akmods-$name.log" >&2; die "akmodsbuild failed for $name"; }
            echo "$stamp" > "$out/.built"
        else
            info "  kmod-$name for $kver already built ($(basename "$srpm"))"
        fi
        for r in "$out"/kmod-"$name"-"$kver"-*.x86_64.rpm; do
            [ -f "$r" ] || die "akmodsbuild left no kmod-$name-$kver RPM in $out"
            rpms+=("$r")
        done
    done
    dnf_root "$ROOTFS_DIR" install "${rpms[@]}" "${KMOD_PKGS[@]}"
    chroot "$ROOTFS_DIR" depmod -a "$kver"
    for m in nvidia nvidia-drm nvidia-modeset wl; do
        find "$ROOTFS_DIR/usr/lib/modules/$kver" -name "$m.ko*" | grep -q . \
            || die "The kmods left no $m.ko for $kver"
    done

    chroot_run "$ROOTFS_DIR" "$SYSTEM_DIR/scripts/setup-chroot.sh"
    rm -f "$ROOTFS_DIR/setup-chroot.sh"
    umount_chroot_pseudofs
    # The packages may have replaced an overlay file (dnf has no conffile
    # prompts); put ours back.
    copy_overlay "$SYSTEM_DIR/rootfs-overlay" "$ROOTFS_DIR"
}

# ── Stage 5: desktops ────────────────────────────────────────────────────────
run_stage 5 "desktops — install each desktop on a copy of the base" && {
    require_rootfs
    kver=$(rootfs_kver)
    for de in $DESKTOPS; do
        root=$(desktop_root "$de")
        dsrc="$SYSTEM_DIR/desktops/$de"
        info "[$de] Copying the base → $root"
        mkdir -p "$root"
        # The pseudo-filesystems' mount points only; their contents (and any
        # left in the copy by an earlier run) never belong in an image.
        rsync -aHAX --numeric-ids --delete --delete-excluded \
            --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
            "$ROOTFS_DIR/" "$root/"

        mount_chroot_pseudofs "$root"
        copy_resolv "$root"
        info "[$de] Installing the desktop's packages"
        # The kernel is the base's: every image of a release carries modules
        # for the one vmlinuz the release ships.
        # shellcheck disable=SC2046
        dnf_root "$root" install --exclude='kernel*' $(list_entries "$dsrc/packages.list")
        deps=()
        [ -f "$dsrc/setup.sh" ] && deps+=("$dsrc/setup.sh:desktop-setup.sh")
        chroot_run "$root" "$SYSTEM_DIR/scripts/setup-desktop.sh" ${deps[@]+"${deps[@]}"}
        # After the packages, so the base's and the desktop's files win.
        copy_overlay "$SYSTEM_DIR/rootfs-overlay" "$root"
        [ -d "$dsrc/rootfs-overlay" ] && copy_overlay "$dsrc/rootfs-overlay" "$root"

        info "[$de] Stripping"
        guard_record "$root"
        # remove.list: rpm globs, `!` lines keep. rpm -e --nodeps, no
        # scriptlets: what depends on a removed build-time package keeps working
        # without it (the guard below checks that).
        mapfile -t PATTERNS < <(list_entries "$(merged_list remove.list "$de")" | grep -v '^!' || true)
        mapfile -t KEEPS < <(list_entries "$(merged_list remove.list "$de")" | sed -n 's/^!//p')
        PURGE=()
        while read -r pkg; do
            # shellcheck disable=SC2053  # unquoted on purpose: glob match
            for k in ${KEEPS[@]+"${KEEPS[@]}"}; do [[ $pkg == $k ]] && continue 2; done
            # shellcheck disable=SC2053
            for p in ${PATTERNS[@]+"${PATTERNS[@]}"}; do
                if [[ $pkg == $p ]]; then PURGE+=("$pkg"); break; fi
            done
        done < <(rpm --root "$root" -qa --qf '%{NAME}\n' | sort -u)
        if [ "${#PURGE[@]}" -gt 0 ]; then
            info "[$de] remove.list: ${PURGE[*]}"
            rpm --root "$root" -e --nodeps --noscripts --notriggers "${PURGE[@]}"
        fi
        # Orphans: what only the removed packages (or nothing) needed.
        info "[$de] Removing orphaned dependencies"
        dnf_root "$root" autoremove --setopt=tsflags=noscripts,nodocs || true
        deps=("$(merged_list remove-files.list "$de"):remove-files.list")
        [ -f "$dsrc/launcher.list" ] && deps+=("$dsrc/launcher.list:launcher.list")
        chroot_run "$root" "$SYSTEM_DIR/scripts/clean-rootfs.sh" "${deps[@]}"
        guard_check "$root"
        # Root is mounted read-only, so NetworkManager can't rewrite
        # /etc/resolv.conf; point it at the file NM keeps in /run.
        rm -f "$root/etc/resolv.conf"
        ln -s ../run/NetworkManager/resolv.conf "$root/etc/resolv.conf"
        umount_chroot_pseudofs
        [ -d "$root/usr/lib/modules/$kver" ] || die "[$de] lost the modules of kernel $kver"
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
        mkdir -p "$root/var/lib/dbus"
        ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
        # What the image is: shown by the updater, checked by release.sh.
        mkdir -p "$root/usr/lib/larch"
        printf '%s\n' "$LARCH_VERSION" > "$root/usr/lib/larch/version"
        printf '%s\n' "$de" > "$root/usr/lib/larch/desktop"
        # systemd-tmpfiles' root.conf (`z / 555`) would try to chmod the
        # read-only root at every boot; ship it with that mode already.
        chmod 555 "$root"
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
    [ -f "$VMLINUZ" ] || die "Kernel vmlinuz not found in the rootfs (/usr/lib/modules/<ver>/vmlinuz)"
    kver=$(rootfs_kver)
    install -m 644 "$VMLINUZ" "$OUT_DIR/vmlinuz"
    # systemd-boot from the base (systemd-boot-unsigned; the images don't
    # carry it) and its config from bootloader/, as release files shared by
    # every desktop: the installer and updater put them on LARCHEFI.
    efi="$ROOTFS_DIR/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
    [ -f "$efi" ] || die "No systemd-bootx64.efi in the base rootfs (systemd-boot-unsigned in packages.list) — run stage 4"
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
