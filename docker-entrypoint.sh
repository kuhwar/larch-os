#!/bin/bash
# docker-entrypoint.sh — larch-os build pipeline (runs inside the builder container)
#
# This is the container ENTRYPOINT and the entire build. larch-os is built ONLY
# inside the privileged builder container: the pipeline needs `mknod` (debootstrap),
# `mount --bind` of proc/sys/dev, and `chroot`, none of which are available during
# an unprivileged `docker build`. So the stages live here and run at `docker run
# --privileged` time — never as Dockerfile RUN steps. Use ./docker-build.sh to
# launch it; arguments below are forwarded straight through as CMD.
#
# Stages:
#   1.  check-deps          — verify build tools
#   2.  debootstrap         — create Debian Trixie minimal rootfs (larch OS)
#   3.  copy-overlay        — merge rootfs-overlay/ into rootfs
#   4.  chroot-configure    — fetch the kernel (scripts/fetch-kernel.sh), then
#                             run scripts/setup-chroot.sh inside chroot
#   5.  clean-rootfs        — strip package manager (scripts/clean-rootfs.sh)
#   6.  make-squashfs       — compress rootfs into rootfs.squashfs (the installer writes it raw onto LARCHSYS)
#   7.  build-updater       — build the updater initramfs ("Update LARCH" boot entry;
#                             also published per release, see build-iso.yml)
#   8.  build-installer     — build the installer initramfs (mounts ISO, runs install.sh)
#   9.  assemble-iso        — copy all pieces into work/iso/
#   10. make-iso            — run grub-mkrescue to produce larch-os.iso (UEFI only)
#
# Usage (via the container — see docker-build.sh):
#   ./docker-build.sh              # full build
#   ./docker-build.sh --stage 6    # run from stage 6 onwards (skip earlier stages)
#   ./docker-build.sh --only 6     # run exactly one stage
#   ./docker-build.sh --clean      # delete work/ directory

set -euo pipefail

# ── Paths & constants ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/work"
ROOTFS_DIR="$WORK_DIR/rootfs"
SQUASHFS_FILE="$WORK_DIR/rootfs.squashfs"
KERNEL_CACHE="$SCRIPT_DIR/kernel-cache"
INSTALLER_INITRAMFS_FILE="$WORK_DIR/installer-initramfs.img"
UPDATE_INITRAMFS_FILE="$WORK_DIR/update-initramfs.img"
ISO_ROOT="$WORK_DIR/iso"
OUTPUT_ISO="${LARCH_OUTPUT_ISO:-$SCRIPT_DIR/larch-os.iso}"

DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_SUITE="trixie"
DEBIAN_ARCH="amd64"

DEBOOTSTRAP_INCLUDE="bash,ca-certificates,locales,systemd"

# ── Argument parsing ──────────────────────────────────────────────────────────
START_STAGE=1
END_STAGE=10
CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) START_STAGE="$2"; shift 2 ;;
        --only)  START_STAGE="$2"; END_STAGE="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo; echo "════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════"; }
info()    { echo "  ▸ $*"; }
die()     { echo "ERROR: $*" >&2; exit 1; }
run_stage() {
    local n="$1"; shift
    [ "$n" -ge "$START_STAGE" ] && [ "$n" -le "$END_STAGE" ] || return 1
    log "Stage $n: $*"
}

chroot_run() {
    local script="$1"
    local basename
    basename="$(basename "$script")"
    cp "$script" "$ROOTFS_DIR/$basename"
    chmod +x "$ROOTFS_DIR/$basename"
    chroot "$ROOTFS_DIR" "/$basename"
}

chroot_run_with_deps() {
    local script="$1"; shift
    local basename
    basename="$(basename "$script")"
    cp "$script" "$ROOTFS_DIR/$basename"
    chmod +x "$ROOTFS_DIR/$basename"
    for dep in "$@"; do
        cp "$dep" "$ROOTFS_DIR/$(basename "$dep")"
    done
    chroot "$ROOTFS_DIR" "/$basename"
}

copy_bin_with_libs() {
    # Copy a binary from the larch OS rootfs into dst_root, together with all
    # its shared library dependencies resolved via the rootfs dynamic linker.
    local binary="$1" dst_root="$2"

    local src
    src=$(find "$ROOTFS_DIR/usr/sbin" "$ROOTFS_DIR/usr/bin" \
               "$ROOTFS_DIR/sbin" "$ROOTFS_DIR/bin" \
               -name "$binary" 2>/dev/null | head -1)
    [ -n "$src" ] || die "Binary '$binary' not found in larch OS rootfs"

    local rel="${src#$ROOTFS_DIR}"
    install -D "$src" "$dst_root$rel"
    info "  [bin] $binary → $rel"

    # Copy the dynamic linker. GNU find does NOT descend into a symlinked
    # starting-point (without -L); on Debian Trixie merged-usr /lib → usr/lib,
    # so search usr/lib directly.
    local ldso_src ldso_rel
    ldso_src=$(find "$ROOTFS_DIR/usr/lib" \
                    -name "ld-linux-x86-64.so.2" 2>/dev/null | head -1)
    [ -n "$ldso_src" ] || \
        ldso_src=$(find -L "$ROOTFS_DIR/lib" "$ROOTFS_DIR/lib64" \
                        -name "ld-linux-x86-64.so.2" 2>/dev/null | head -1)
    if [ -n "$ldso_src" ]; then
        ldso_src=$(readlink -f "$ldso_src" 2>/dev/null || echo "$ldso_src")
        ldso_rel="${ldso_src#$ROOTFS_DIR}"
        install -D "$ldso_src" "$dst_root$ldso_rel" 2>/dev/null || true
        # All Debian amd64 binaries use /lib64/ld-linux-x86-64.so.2 as their ELF
        # interpreter. In the rootfs /lib64 → usr/lib64 → real linker via symlink
        # chain. In the initramfs /lib64 is a real empty directory, so put the
        # symlink inside it explicitly.
        mkdir -p "$dst_root/lib64"
        ln -sf "$ldso_rel" \
               "$dst_root/lib64/ld-linux-x86-64.so.2" 2>/dev/null || true
    fi

    # Use chroot ldd to list shared library dependencies. Running ldd inside
    # the rootfs chroot avoids the ROOTFS_DIR prefix appearing in the output
    # (which happens with ld-linux --list run from outside) and correctly uses
    # the rootfs ld.so.cache and library search paths.
    local lib_paths
    lib_paths=$(chroot "$ROOTFS_DIR" ldd "$rel" 2>/dev/null | \
                awk '/=>/ && $3 ~ /^\// { print $3 }' || true)
    [ -n "$lib_paths" ] || return 0

    # Use a here-string (not a pipe) so the while runs in the current shell
    # and set -e / pipefail cannot be triggered by the input-generation side.
    while IFS= read -r lib; do
        [ -n "$lib" ] || continue
        local libsrc="$ROOTFS_DIR$lib"
        [ -e "$libsrc" ] || continue
        local real; real=$(readlink -f "$libsrc" 2>/dev/null || true)
        [ -f "$real" ] || continue
        local real_rel="${real#$ROOTFS_DIR}"
        install -D "$real" "$dst_root$real_rel" 2>/dev/null || true
        # Recreate the soname symlink with an absolute target so it works even
        # when the symlink and real file are in different prefix dirs
        # (e.g. /lib/... → /usr/lib/... on merged-usr Debian).
        if [ "$libsrc" != "$real" ]; then
            mkdir -p "$(dirname "$dst_root$lib")"
            ln -sf "$real_rel" "$dst_root$lib" 2>/dev/null || true
        fi
    done <<< "$lib_paths"
}

populate_initramfs_tree() {
    # Fill <build_dir> with the busybox userland, the kernel modules named in
    # <modules_list> (default initramfs/modules.list; "none" for no modules),
    # <src_dir>/init and an empty /etc/modprobe.d.
    local src_dir="$1" build_dir="$2" label="${3:-initramfs}"
    local modules_list="${4:-$SCRIPT_DIR/initramfs/modules.list}"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"/{bin,sbin,lib,lib64,lib/x86_64-linux-gnu,usr/bin,usr/sbin,\
usr/lib/x86_64-linux-gnu,dev,proc,sys,mnt/squashfs,mnt/overlay,mnt/root,mnt/config,\
mnt/iso,run,tmp}

    info "[$label] Copying busybox"
    local busybox_bin="$ROOTFS_DIR/bin/busybox"
    [ -f "$busybox_bin" ] || busybox_bin="$(command -v busybox-static 2>/dev/null)" || \
        die "busybox-static not found"
    cp "$busybox_bin" "$build_dir/bin/busybox"
    chmod +x "$build_dir/bin/busybox"
    for applet in sh ash cat cp echo grep ls mkdir mount modprobe \
                  mknod sleep switch_root umount uname blkid findfs find udevadm \
                  sed awk cut tr head tail cttyhack \
                  chmod chown id stty sync lsblk reboot date stat; do
        ln -sf busybox "$build_dir/bin/$applet" 2>/dev/null || true
    done
    ln -sf ../bin/busybox "$build_dir/sbin/switch_root"
    ln -sf ../bin/busybox "$build_dir/sbin/modprobe"
    ln -sf ../bin/busybox "$build_dir/sbin/blkid"
    ln -sf ../bin/busybox "$build_dir/sbin/reboot"

    info "[$label] Copying kernel modules"
    local kver
    kver=$(ls "$ROOTFS_DIR/lib/modules/" 2>/dev/null | sort -V | tail -1)
    if [ "$modules_list" = none ]; then
        info "[$label] Kernel modules: added by the caller"
    elif [ -n "$kver" ]; then
        mkdir -p "$build_dir/lib/modules/$kver"
        while IFS= read -r mod; do
            [[ "$mod" =~ ^#|^$ ]] && continue
            find "$ROOTFS_DIR/lib/modules/$kver" -name "${mod}.ko*" | \
            while IFS= read -r kofile; do
                install -D "$kofile" "$build_dir${kofile#$ROOTFS_DIR}"
            done
        done < "$modules_list"

        for f in modules.dep modules.alias modules.softdep modules.builtin; do
            [ -f "$ROOTFS_DIR/lib/modules/$kver/$f" ] && \
                cp "$ROOTFS_DIR/lib/modules/$kver/$f" \
                   "$build_dir/lib/modules/$kver/" 2>/dev/null || true
        done

        info "[$label] Decompressing .ko.xz / .ko.zst modules"
        find "$build_dir/lib/modules" -name "*.ko.xz" | \
        while IFS= read -r f; do
            xz -d "$f"
        done
        find "$build_dir/lib/modules" -name "*.ko.zst" | \
        while IFS= read -r f; do
            zstd -d "$f" -o "${f%.zst}" -q && rm -f "$f"
        done
        for f in modules.dep modules.alias modules.softdep; do
            local mf="$build_dir/lib/modules/$kver/$f"
            [ -f "$mf" ] && sed -i 's/\.ko\.xz/.ko/g; s/\.ko\.zst/.ko/g' "$mf"
        done
    else
        info "WARNING: No kernel modules found in rootfs"
    fi

    info "[$label] Copying init script"
    cp "$src_dir/init" "$build_dir/init"
    chmod +x "$build_dir/init"

    mkdir -p "$build_dir/etc/modprobe.d"
}

bundle_dialog() {
    # dialog drives the installer's and the updater's entire UI (ncurses) and
    # is a REQUIRED component — neither has a text fallback. Fail the build here
    # rather than ship a broken initramfs. If this trips on a cached rootfs that
    # predates `dialog` in packages.list, rebuild from stage 4.
    local build_dir="$1" label="$2"
    if ! find "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/bin" -name dialog 2>/dev/null | grep -q .; then
        die "dialog not found in rootfs — it is required by the $label (it ships via config/packages.list; rebuild from stage 4)"
    fi
    copy_bin_with_libs dialog "$build_dir"
    # ncurses needs a terminfo entry for the active $TERM. Bundle the common
    # console/VM terminal types; the scripts set TERM=linux on the VT.
    local ti_src="$ROOTFS_DIR/usr/share/terminfo"
    [ -d "$ti_src" ] || die "terminfo not found in rootfs — required for the $label's dialog UI"
    local _ent
    for _ent in l/linux v/vt100 v/vt220 a/ansi x/xterm x/xterm-256color d/dumb; do
        [ -f "$ti_src/$_ent" ] && \
            install -D "$ti_src/$_ent" "$build_dir/usr/share/terminfo/$_ent"
    done
    [ -f "$build_dir/usr/share/terminfo/l/linux" ] \
        || die "terminfo entry for TERM=linux not found in rootfs — required for the $label's dialog UI"
    info "[$label] Bundled dialog + terminfo (full-screen UI)"
}

pack_initramfs() {
    # Pack <build_dir> as a single gzip cpio at <out>.
    local build_dir="$1" out="$2" label="$3"
    info "[$label] Packing → $out"
    rm -f "$out"
    (cd "$build_dir" && find . | cpio --create --format=newc --quiet) | \
        gzip -9 > "$out"
    info "[$label] Done: $(basename "$out") ($(du -sh "$out" | cut -f1))"
}

build_installer_initramfs() {
    local src_dir="$SCRIPT_DIR/initramfs/installer"
    local build_dir="$WORK_DIR/installer-initramfs-build"

    populate_initramfs_tree "$src_dir" "$build_dir" "installer"

    # Copy larch-install script and its library files
    install -m 755 "$SCRIPT_DIR/installer/install.sh" \
        "$build_dir/usr/sbin/larch-install"
    for _lib in "$SCRIPT_DIR/installer/lib/"*.sh; do
        [ -f "$_lib" ] || continue
        install -D -m 644 "$_lib" "$build_dir/usr/lib/larch/$(basename "$_lib")"
    done

    # User/group names the image already uses (root, daemon, man, gdm, ...), so
    # the installer never derives a username that clashes with one. "larch" is
    # left out: it is the UID-1000 placeholder the installed user replaces.
    cut -d: -f1 "$ROOTFS_DIR/etc/passwd" "$ROOTFS_DIR/etc/group" \
        | grep -vx larch | sort -u > "$build_dir/usr/lib/larch/reserved-names"

    # Copy /etc/skel from larch OS rootfs so the installer can seed the home partition
    if [ -d "$ROOTFS_DIR/etc/skel" ]; then
        mkdir -p "$build_dir/mnt/iso/skel"
        # skel is seeded via /mnt/iso/skel/ at install time (build stage 9 copies it there)
    fi

    # Copy tool binaries from larch OS rootfs with their shared libraries.
    # These tools are not in busybox: sfdisk (partitioning), wipefs (disk wipe),
    # mkfs.fat (FAT32 format), mkfs.ext4 (ext4 format), openssl (password hash),
    # blockdev (re-read partition table, partition size).
    info "[installer] Copying tool binaries from larch OS rootfs"
    for bin in sfdisk wipefs mkfs.fat mkfs.ext4 openssl blockdev; do
        copy_bin_with_libs "$bin" "$build_dir"
    done

    # mkfs.fat is also invoked as mkfs.vfat
    local fat_bin; fat_bin=$(find "$build_dir" -name "mkfs.fat" 2>/dev/null | head -1)
    [ -n "$fat_bin" ] && \
        ln -sf "$(basename "$fat_bin")" "$(dirname "$fat_bin")/mkfs.vfat" 2>/dev/null || true

    # OpenSSL 3 loads provider modules via dlopen at runtime — they are NOT
    # visible to ldd and so copy_bin_with_libs misses them. Without the default
    # provider, `openssl passwd -6` (SHA-512 crypt) fails immediately.
    # Copy the whole ossl-modules directory from the rootfs.
    local ossl_mods_src
    ossl_mods_src=$(find "$ROOTFS_DIR/usr/lib" -type d -name "ossl-modules" 2>/dev/null | head -1)
    if [ -n "$ossl_mods_src" ]; then
        local ossl_mods_dst="$build_dir${ossl_mods_src#$ROOTFS_DIR}"
        mkdir -p "$ossl_mods_dst"
        cp -a "$ossl_mods_src/." "$ossl_mods_dst/"
        info "[installer] Copied OpenSSL provider modules → ${ossl_mods_src#$ROOTFS_DIR}"
    else
        info "WARNING: ossl-modules directory not found in rootfs — openssl passwd may fail"
    fi

    bundle_dialog "$build_dir" installer

    pack_initramfs "$build_dir" "$INSTALLER_INITRAMFS_FILE" installer
}

bundle_update_modules() {
    # The updater's own drivers: every network driver (Ethernet, USB Ethernet,
    # Wi-Fi incl. the DKMS-built Broadcom wl, Thunderbolt networking), plus
    # what it takes to use them and the console — HID/input, SDIO/MMC hosts,
    # USB host controllers, cfg80211/mac80211/rfkill, crypto (WPA2/3), loop
    # and FAT/NLS — with all their dependencies (modules.dep lists them
    # transitively), and the firmware those modules declare. Modules stay
    # compressed: the bundled kmod loads .ko.xz itself. The updater never
    # reads LARCHSYS for drivers, so it works with a half-written LARCHSYS.
    local build_dir="$1"
    local kver; kver=$(ls "$ROOTFS_DIR/lib/modules/" | sort -V | tail -1)
    local src="$ROOTFS_DIR/usr/lib/modules/$kver"
    local dst="$build_dir/usr/lib/modules/$kver"
    [ -f "$src/modules.dep" ] || die "modules.dep not found for kernel $kver"
    local list="$WORK_DIR/update-modules.list" fwlist="$WORK_DIR/update-firmware.list"

    awk -F': *' '
        $1 ~ /^kernel\/(drivers\/(net|hid|input|mmc|usb\/host|thunderbolt|bcma|ssb)|net\/(wireless|mac80211|rfkill|packet)|crypto|arch\/x86\/crypto|lib|fs\/(fat|nls))\// \
            || $1 ~ /^kernel\/drivers\/block\/loop\.ko/ || $1 ~ /^updates\/(.*\/)?wl\.ko/ {
            print $1
            n = split($2, d, " "); for (i = 1; i <= n; i++) print d[i]
        }' "$src/modules.dep" | sort -u > "$list"

    local rel
    while IFS= read -r rel; do
        install -D -m 644 "$src/$rel" "$dst/$rel"
    done < "$list"
    # The indexes cover modules not bundled too; loading one of those just fails.
    cp "$src"/modules.* "$dst/"
    ln -sfn ../usr/lib/modules "$build_dir/lib/modules"
    info "[updater] $(wc -l < "$list") modules ($(du -sh "$dst" | cut -f1))"

    # Firmware the bundled modules declare (MODULE_FIRMWARE), as present in
    # the rootfs (some names are globs; compressed variants count), plus what
    # cfg80211/brcmfmac load without declaring it.
    sed "s|^|/usr/lib/modules/$kver/|" "$list" \
        | chroot "$ROOTFS_DIR" xargs -r modinfo -F firmware 2>/dev/null \
        | sort -u > "$fwlist" || true
    printf '%s\n' 'regulatory.db*' 'brcm/*.txt*' 'brcm/*.clm_blob*' 'brcm/*.txcap_blob*' >> "$fwlist"
    local fwsrc="$ROOTFS_DIR/usr/lib/firmware" fw f
    while IFS= read -r fw; do
        [ -n "$fw" ] || continue
        # Unquoted on purpose: expands the glob names.
        for f in "$fwsrc"/$fw "$fwsrc"/$fw.xz "$fwsrc"/$fw.zst; do
            [ -e "$f" ] || continue
            install -D -m 644 "$f" "$build_dir/usr/lib/firmware/${f#"$fwsrc"/}"
        done
    done < "$fwlist"
    mkdir -p "$build_dir/usr/lib/firmware"
    ln -sfn ../usr/lib/firmware "$build_dir/lib/firmware"
    info "[updater] firmware: $(find "$build_dir/usr/lib/firmware" -type f | wc -l) files ($(du -sh "$build_dir/usr/lib/firmware" | cut -f1))"

    # The image's module config (e.g. broadcom-sta's blacklist of b43/bcma).
    mkdir -p "$build_dir/etc/modprobe.d" "$build_dir/usr/lib/modprobe.d"
    cp -a "$ROOTFS_DIR/etc/modprobe.d/." "$build_dir/etc/modprobe.d/" 2>/dev/null || true
    cp -a "$ROOTFS_DIR/usr/lib/modprobe.d/." "$build_dir/usr/lib/modprobe.d/" 2>/dev/null || true
    ln -sfn ../usr/lib/modprobe.d "$build_dir/lib/modprobe.d"
}

build_update_initramfs() {
    # The "Update LARCH" boot entry's initramfs: busybox, the updater scripts,
    # the network/UI tools and its own drivers + firmware (bundle_update_modules).
    # Built for the kernel in this rootfs, so it is published per release
    # (larch-os-update-initramfs.img) and the updater installs it with the
    # release's kernel.
    local src_dir="$SCRIPT_DIR/initramfs/update"
    local build_dir="$WORK_DIR/update-initramfs-build"

    populate_initramfs_tree "$src_dir" "$build_dir" "updater" none
    # The scripts lean on busybox's standalone shell for these applets.
    local _applet _applets
    _applets=$("$build_dir/bin/busybox" --list)
    for _applet in udhcpc ip ifconfig sha256sum stat xargs setsid cttyhack readlink zcat cpio; do
        printf '%s\n' "$_applets" | grep -qx "$_applet" \
            || die "busybox in the rootfs lacks the '$_applet' applet the updater needs"
    done
    rm -rf "$build_dir/lib/modules" "$build_dir/etc/modprobe.d"
    bundle_update_modules "$build_dir"

    install -m 755 "$SCRIPT_DIR/updater/update.sh" "$build_dir/usr/sbin/larch-update"
    for _lib in "$SCRIPT_DIR/updater/lib/"*.sh; do
        install -D -m 644 "$_lib" "$build_dir/usr/lib/larch-update/$(basename "$_lib")"
    done
    install -D -m 755 "$src_dir/udhcpc.script" "$build_dir/usr/share/udhcpc/default.script"

    # curl (GitHub API + download), wpa_supplicant/wpa_cli (Wi-Fi), and kmod's
    # modprobe: the image's modules are .ko.xz, which busybox can't load.
    info "[updater] Copying tool binaries from larch OS rootfs"
    for bin in curl wpa_supplicant wpa_cli modprobe; do
        copy_bin_with_libs "$bin" "$build_dir"
    done
    install -D -m 644 "$ROOTFS_DIR/etc/ssl/certs/ca-certificates.crt" \
        "$build_dir/etc/ssl/certs/ca-certificates.crt"
    printf 'hosts: files dns\n' > "$build_dir/etc/nsswitch.conf"
    printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > "$build_dir/etc/hosts"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$build_dir/etc/passwd"
    printf 'root:x:0:\n' > "$build_dir/etc/group"

    bundle_dialog "$build_dir" updater
    pack_initramfs "$build_dir" "$UPDATE_INITRAMFS_FILE" updater
}

find_vmlinuz() {
    local kver p
    kver=$(ls "$ROOTFS_DIR/lib/modules/" 2>/dev/null | sort -V | tail -1)
    for p in "$ROOTFS_DIR/boot/vmlinuz" "$ROOTFS_DIR/boot/vmlinuz-$kver"; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    ls "$ROOTFS_DIR/boot/vmlinuz"* 2>/dev/null | sort -V | tail -1
}

find_efi_bin() {
    find "$ROOTFS_DIR/usr/lib/systemd/boot/efi" \
        \( -name "systemd-bootx64.efi" -o -name "systemd-bootx64.efi.signed" \) \
        2>/dev/null | head -1
}

# ── Root check ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Must run as root inside the privileged builder (needed for chroot, mknod, etc.) — use ./docker-build.sh"

# ── Clean ─────────────────────────────────────────────────────────────────────
if [ "$CLEAN" -eq 1 ]; then
    log "Cleaning work directory"
    for mnt in proc sys dev/pts dev; do
        umount -lf "$ROOTFS_DIR/$mnt" 2>/dev/null || true
    done
    rm -rf "$WORK_DIR" "$OUTPUT_ISO"
    echo "Clean complete."
    exit 0
fi

mkdir -p "$WORK_DIR"

# ── Stage 1: check-deps ───────────────────────────────────────────────────────
run_stage 1 "check-deps" && {
    info "Checking required build tools"
    MISSING=()
    for cmd in debootstrap mksquashfs xorriso cpio find grub-mkrescue xz gzip; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done
    command -v busybox &>/dev/null || command -v busybox-static &>/dev/null || \
        MISSING+=("busybox-static")
    [ -f /usr/lib/grub/x86_64-efi/modinfo.sh ] || \
        MISSING+=("grub-efi-amd64-bin (GRUB x86_64-efi platform)")
    find /usr/lib/systemd/boot/efi -name "*.efi" &>/dev/null 2>&1 || \
        MISSING+=("systemd-boot EFI (install systemd-boot package)")

    if [ "${#MISSING[@]}" -gt 0 ]; then
        echo ""
        echo "Missing build tools in the builder image:"
        for m in "${MISSING[@]}"; do echo "  - $m"; done
        echo ""
        echo "These are provided by the Dockerfile. Rebuild the image:"
        echo "  ./docker-build.sh   (rebuilds larch-os-builder, then builds)"
        exit 1
    fi
    info "All dependencies found"
}

# ── Stage 2: debootstrap ──────────────────────────────────────────────────────
run_stage 2 "debootstrap — create minimal Debian rootfs" && {
    if [ -d "$ROOTFS_DIR/usr" ]; then
        info "Rootfs already exists, skipping debootstrap. Use --clean to restart."
    else
        mkdir -p "$ROOTFS_DIR"
        info "Running debootstrap $DEBIAN_SUITE → $ROOTFS_DIR"
        debootstrap \
            --arch="$DEBIAN_ARCH" \
            --include="$DEBOOTSTRAP_INCLUDE" \
            "$DEBIAN_SUITE" \
            "$ROOTFS_DIR" \
            "$DEBIAN_MIRROR"
        info "Debootstrap complete"
    fi
}

# ── Stage 3: copy rootfs overlay ─────────────────────────────────────────────
run_stage 3 "copy-overlay — merge rootfs-overlay into rootfs" && {
    if [ -d "$SCRIPT_DIR/rootfs-overlay" ]; then
        info "Copying overlay files"
        cp -a "$SCRIPT_DIR/rootfs-overlay/." "$ROOTFS_DIR/"
        # cp -a carries the checkout's modes, which a umask of 002 leaves
        # group-writable — on /, /etc, /usr too. Nothing here wants g/o write.
        (cd "$SCRIPT_DIR/rootfs-overlay" && find . ! -type l -print0) \
            | (cd "$ROOTFS_DIR" && xargs -0 chmod go-w)
    else
        info "No rootfs-overlay directory found, skipping"
    fi
}

# ── Stage 4: chroot-configure ────────────────────────────────────────────────
run_stage 4 "chroot-configure — install packages and configure system" && {
    info "Mounting proc/sys/dev inside chroot"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys  "$ROOTFS_DIR/sys"
    mount --bind /dev  "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"

    # The image's resolv.conf is a symlink into /run (set below); replace it
    # with the builder's for apt, without following the link.
    rm -f "$ROOTFS_DIR/etc/resolv.conf"
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    # Custom kernel with the root-mount drivers built in (no initramfs on the
    # installed system), built and released by the larch-kernel repo. Cached in
    # kernel-cache/; setup-chroot.sh installs the .debs from /kernel-debs
    # before the package list.
    "$SCRIPT_DIR/scripts/fetch-kernel.sh" "$KERNEL_CACHE"
    rm -rf "$ROOTFS_DIR/kernel-debs"
    mkdir -p "$ROOTFS_DIR/kernel-debs"
    cp "$KERNEL_CACHE"/*.deb "$ROOTFS_DIR/kernel-debs/"

    chroot_run_with_deps \
        "$SCRIPT_DIR/scripts/setup-chroot.sh" \
        "$SCRIPT_DIR/config/packages.list" \
        "$SCRIPT_DIR/config/remove.list"
    rm -rf "$ROOTFS_DIR/kernel-debs"

    # Root is mounted read-only, so NetworkManager can't rewrite
    # /etc/resolv.conf; point it at the file NM keeps in /run.
    rm -f "$ROOTFS_DIR/etc/resolv.conf"
    ln -s ../run/NetworkManager/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    info "Unmounting pseudo-filesystems"
    umount -lf "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount -lf "$ROOTFS_DIR/dev"     2>/dev/null || true
    umount -lf "$ROOTFS_DIR/sys"     2>/dev/null || true
    umount -lf "$ROOTFS_DIR/proc"    2>/dev/null || true
}

# ── Stage 5: clean-rootfs ─────────────────────────────────────────────────────
run_stage 5 "clean-rootfs — strip package manager and build artifacts" && {
    info "Running rootfs cleanup (removing apt/dpkg)"
    chroot_run_with_deps \
        "$SCRIPT_DIR/scripts/clean-rootfs.sh" \
        "$SCRIPT_DIR/config/remove.list" \
        "$SCRIPT_DIR/config/remove-files.list"
    info "Rootfs is now package-manager-free"
}

# ── Stage 6: make-squashfs ────────────────────────────────────────────────────
run_stage 6 "make-squashfs — compress rootfs into squashfs image" && {
    # The image is the root filesystem of every install as-is, so it must carry
    # no machine identity: an empty /etc/machine-id makes systemd take the id
    # from systemd.machine_id= (the installer puts it in the loader entry) and
    # mount it over the read-only file; D-Bus's copy follows it.
    : > "$ROOTFS_DIR/etc/machine-id"
    ln -sfn /etc/machine-id "$ROOTFS_DIR/var/lib/dbus/machine-id"

    # The image carries its own kernel beside its modules (/boot is excluded),
    # so the updater can install the kernel that matches the new root's
    # modules onto LARCHEFI along with it.
    VMLINUZ="$(find_vmlinuz)"
    [ -f "$VMLINUZ" ] || die "Kernel vmlinuz not found in rootfs/boot"
    kver=$(ls "$ROOTFS_DIR/lib/modules/" | sort -V | tail -1)
    install -m 644 "$VMLINUZ" "$ROOTFS_DIR/usr/lib/modules/$kver/vmlinuz"
    info "Kernel $kver → /usr/lib/modules/$kver/vmlinuz"

    info "Creating squashfs (zstd compression)"
    rm -f "$SQUASHFS_FILE"
    # config/squashfs.exclude: build leftovers and /boot (see the file).
    mksquashfs "$ROOTFS_DIR" "$SQUASHFS_FILE" \
        -comp zstd \
        -Xcompression-level 19 \
        -no-progress \
        -noappend \
        -wildcards \
        -ef "$SCRIPT_DIR/config/squashfs.exclude"
    sz=$(du -sh "$SQUASHFS_FILE" | cut -f1)
    info "Squashfs created: $SQUASHFS_FILE ($sz)"
}

# ── Stage 7: build-updater ───────────────────────────────────────────────────
# (The installed system itself boots without an initramfs: the kernel mounts
# root=PARTLABEL=LARCHSYS read-only. This initramfs is only for the
# "Update LARCH" boot entry.)
run_stage 7 "build-updater — build the updater initramfs" && {
    [ -d "$ROOTFS_DIR/usr" ] || \
        die "Larch OS rootfs not found — run stages 2-5 first (stage 7 copies tools from it)"
    build_update_initramfs
}

# ── Stage 8: build-installer ─────────────────────────────────────────────────
run_stage 8 "build-installer — build the installer initramfs" && {
    [ -d "$ROOTFS_DIR/usr" ] || \
        die "Larch OS rootfs not found — run stages 2-5 first (stage 8 copies tools from it)"
    build_installer_initramfs
}

# ── Stage 9: assemble-iso ────────────────────────────────────────────────────
run_stage 9 "assemble-iso — copy all files into ISO tree" && {
    info "Assembling ISO directory tree"
    rm -rf "$ISO_ROOT"
    mkdir -p "$ISO_ROOT/boot/grub" \
             "$ISO_ROOT/larch-os" \
             "$ISO_ROOT/EFI/BOOT" \
             "$ISO_ROOT/loader/entries" \
             "$ISO_ROOT/skel"

    cp "$SCRIPT_DIR/bootloader/grub.cfg" "$ISO_ROOT/boot/grub/grub.cfg"

    VMLINUZ="$(find_vmlinuz)"
    [ -f "$VMLINUZ" ] || die "Kernel vmlinuz not found in rootfs/boot"
    info "Kernel: $VMLINUZ"

    # Kernel — boots the installer initramfs
    cp "$VMLINUZ" "$ISO_ROOT/vmlinuz"

    # Installer initramfs — GRUB loads this; mounts the ISO and runs install.sh
    [ -f "$INSTALLER_INITRAMFS_FILE" ] || \
        die "Installer initramfs not found — run stage 8 first"
    cp "$INSTALLER_INITRAMFS_FILE" "$ISO_ROOT/installer-initramfs.img"

    # Larch OS to be installed — the installer writes the squashfs raw onto the
    # LARCHSYS partition and copies the kernel to the EFI partition
    [ -f "$SQUASHFS_FILE" ] || \
        die "rootfs.squashfs not found — run stage 6 first"
    cp "$SQUASHFS_FILE"     "$ISO_ROOT/larch-os/rootfs.squashfs"
    cp "$VMLINUZ"           "$ISO_ROOT/larch-os/vmlinuz"
    # Updater initramfs — the installer copies it to LARCHEFI for the
    # "Update LARCH" boot entry
    [ -f "$UPDATE_INITRAMFS_FILE" ] || \
        die "Updater initramfs not found — run stage 7 first"
    cp "$UPDATE_INITRAMFS_FILE" "$ISO_ROOT/larch-os/update-initramfs.img"

    # Bootloader files for the installed disk — installer copies these to LARCHEFI
    EFI_BIN="$(find_efi_bin)"
    [ -f "$EFI_BIN" ] || die "systemd-boot EFI binary not found in rootfs"
    cp "$EFI_BIN" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
    cp "$SCRIPT_DIR/bootloader/loader.conf"              "$ISO_ROOT/loader/loader.conf"
    cp "$SCRIPT_DIR/bootloader/entries/larch.conf"       "$ISO_ROOT/loader/entries/larch.conf"
    # Second, non-default entry: verbose console logging for diagnosing boot
    # failures (quiet/splash and the systemd/udev status suppressors are dropped).
    # The menu shows for loader.conf's timeout; sort-key orders the entries.
    cp "$SCRIPT_DIR/bootloader/entries/larch-debug.conf" "$ISO_ROOT/loader/entries/larch-debug.conf"
    # Third entry: boot the updater (download a release, rewrite LARCHSYS).
    cp "$SCRIPT_DIR/bootloader/entries/larch-update.conf" "$ISO_ROOT/loader/entries/larch-update.conf"

    # /etc/skel — seeded into home partition at install time
    cp -a "$ROOTFS_DIR/etc/skel/." "$ISO_ROOT/skel/" 2>/dev/null || true

    info "ISO tree assembled at $ISO_ROOT"
    du -sh "$ISO_ROOT"
}

# ── Stage 10: make-iso ────────────────────────────────────────────────────────
run_stage 10 "make-iso — produce larch-os.iso via grub-mkrescue" && {
    # grub-mkrescue wraps xorriso and injects GRUB2 with full ISO9660 support.
    # GRUB reads /boot/grub/grub.cfg straight from the disc, so the kernel
    # and installer initramfs on the ISO9660 filesystem are directly accessible
    # at boot — unlike systemd-boot which has no ISO9660 driver.
    info "Building UEFI-only ISO with grub-mkrescue"
    rm -f "$OUTPUT_ISO"

    # UEFI only: pin a single GRUB platform directory to avoid a BIOS El Torito entry.
    GRUB_EFI_DIR="/usr/lib/grub/x86_64-efi"
    [ -f "$GRUB_EFI_DIR/modinfo.sh" ] || \
        die "GRUB x86_64-efi platform not found at $GRUB_EFI_DIR (install grub-efi-amd64-bin)"

    # LARCHISO is the ISO9660 volume label. The installer init finds the USB medium
    # by this label using findfs/blkid. Use a different label than the installed
    # FAT32 partition (LARCHEFI) to avoid any blkid ambiguity.
    grub-mkrescue -d "$GRUB_EFI_DIR" -o "$OUTPUT_ISO" "$ISO_ROOT" -- -volid LARCHISO 2>/dev/null || \
        grub-mkrescue -d "$GRUB_EFI_DIR" -o "$OUTPUT_ISO" "$ISO_ROOT"

    sz=$(du -sh "$OUTPUT_ISO" | cut -f1)
    log "Build complete"
    echo ""
    echo "  Output: $OUTPUT_ISO  ($sz)"
    echo ""
    echo "  Test with QEMU:"
    echo "    qemu-system-x86_64 \\"
    echo "      -enable-kvm \\"
    echo "      -m 4G \\"
    echo "      -bios /usr/share/ovmf/OVMF.fd \\"
    echo "      -cdrom $OUTPUT_ISO \\"
    echo "      -vga virtio \\"
    echo "      -display gtk,gl=on"
    echo ""
}

log "All stages complete"
