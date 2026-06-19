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
#   1. check-deps       — verify build tools
#   2. debootstrap      — create Debian Trixie minimal rootfs
#   3. copy-overlay     — merge rootfs-overlay/ into rootfs
#   4. chroot-configure — run scripts/setup-chroot.sh inside chroot
#   5. clean-rootfs     — strip package manager (scripts/clean-rootfs.sh)
#   6. make-squashfs    — compress rootfs into rootfs.squashfs
#   7. build-initramfs  — assemble custom cpio initramfs
#   8. assemble-iso     — copy all pieces into work/iso/
#   9. make-iso         — run grub-mkrescue to produce larch-os.iso (UEFI only)
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
INITRAMFS_FILE="$WORK_DIR/initramfs.img"           # installed-OS initramfs
INSTALLER_INITRAMFS_FILE="$WORK_DIR/installer.img" # live/installer initramfs
ISO_ROOT="$WORK_DIR/iso"
OUTPUT_ISO="${LARCH_OUTPUT_ISO:-$SCRIPT_DIR/larch-os.iso}"

DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_SUITE="trixie"
DEBIAN_ARCH="amd64"

# Initial debootstrap packages (bare minimum to get into chroot)
DEBOOTSTRAP_INCLUDE="bash,ca-certificates,locales,systemd"

# ── Argument parsing ──────────────────────────────────────────────────────────
START_STAGE=1
END_STAGE=9
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
    # Return 1 (skip) if stage is outside the requested range.
    # The caller pattern is: run_stage N "label" && { ... work ... }
    # Returning 1 causes && to short-circuit and skip the block.
    [ "$n" -ge "$START_STAGE" ] && [ "$n" -le "$END_STAGE" ] || return 1
    log "Stage $n: $*"
}

chroot_run() {
    # Bind-mount a script into the chroot and execute it
    local script="$1"
    local basename
    basename="$(basename "$script")"
    cp "$script" "$ROOTFS_DIR/$basename"
    chmod +x "$ROOTFS_DIR/$basename"
    chroot "$ROOTFS_DIR" "/$basename"
}

chroot_run_with_deps() {
    # Like chroot_run but also copies extra files needed by the script
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

build_initramfs() {
    # Build a gzipped cpio initramfs from a source directory.
    # Usage: build_initramfs <src_dir> <out_file> <label> [extras_dir]
    #   src_dir   — directory containing init and modules.list
    #   out_file  — output .img path
    #   label     — short label used in log messages
    #   extras_dir — optional directory whose contents are merged into the
    #                initramfs root before packing (e.g. install.sh + mke2fs)
    local src_dir="$1" out_file="$2" label="$3" extras_dir="${4:-}"
    local build_dir="$WORK_DIR/initramfs-build-$label"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"/{bin,sbin,lib,lib64,dev,proc,sys,mnt/probe,mnt/squashfs,mnt/ospart,mnt/overlay,mnt/root,mnt/config,mnt/iso,run}

    info "[$label] Copying busybox"
    local busybox_bin="$ROOTFS_DIR/bin/busybox"
    [ -f "$busybox_bin" ] || busybox_bin="$(command -v busybox-static 2>/dev/null)" || \
        die "busybox-static not found"
    cp "$busybox_bin" "$build_dir/bin/busybox"
    chmod +x "$build_dir/bin/busybox"
    for applet in sh ash bash cat cp echo grep ls mkdir mount modprobe \
                  mknod sleep switch_root umount uname blkid findfs find udevadm \
                  sed awk cut tr head tail \
                  chmod chown id stty sync lsblk reboot; do
        ln -sf busybox "$build_dir/bin/$applet" 2>/dev/null || true
    done
    ln -sf ../bin/busybox "$build_dir/sbin/switch_root"
    ln -sf ../bin/busybox "$build_dir/sbin/modprobe"
    ln -sf ../bin/busybox "$build_dir/sbin/blkid"
    ln -sf ../bin/busybox "$build_dir/sbin/reboot"

    info "[$label] Copying kernel modules"
    local kver
    kver=$(ls "$ROOTFS_DIR/lib/modules/" 2>/dev/null | sort -V | tail -1)
    if [ -n "$kver" ]; then
        mkdir -p "$build_dir/lib/modules/$kver"
        while IFS= read -r mod; do
            [[ "$mod" =~ ^#|^$ ]] && continue
            find "$ROOTFS_DIR/lib/modules/$kver" -name "${mod}.ko*" | \
            while IFS= read -r kofile; do
                install -D "$kofile" "$build_dir${kofile#$ROOTFS_DIR}"
            done
        done < "$src_dir/modules.list"

        for f in modules.dep modules.alias modules.softdep modules.builtin; do
            [ -f "$ROOTFS_DIR/lib/modules/$kver/$f" ] && \
                cp "$ROOTFS_DIR/lib/modules/$kver/$f" \
                   "$build_dir/lib/modules/$kver/" 2>/dev/null || true
        done

        # Debian Trixie ships .ko.xz; busybox modprobe cannot decompress them.
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

    # Merge optional extras (e.g. install.sh + mke2fs for the installer initramfs)
    if [ -n "$extras_dir" ] && [ -d "$extras_dir" ]; then
        info "[$label] Merging extras from $(basename "$extras_dir")"
        cp -a "$extras_dir/." "$build_dir/"
    fi

    info "[$label] Packing cpio → $out_file"
    rm -f "$out_file"
    if [ -f "$build_dir/rootfs.squashfs" ]; then
        # Two-pass pack: squashfs is already zstd-compressed, re-gzipping wastes CPU.
        # ORDER MATTERS: the raw (uncompressed) cpio MUST come first, the gzip cpio
        # second. This is the kernel's documented early-cpio concatenation pattern
        # (same as early microcode): it unpacks the leading raw cpio, skips its zero
        # padding, then detects and decompresses the trailing gzip archive.
        # The reverse order (gzip first, raw second) fails with
        # "Initramfs unpacking failed: invalid magic at start of compressed archive"
        # because after a compressed segment the kernel's input pointer does not land
        # cleanly on the next archive.
        info "[$label] Pass 1: appending rootfs.squashfs raw (pre-compressed)"
        # Flush the squashfs (often just written by stage 6) before cpio reads it:
        # on a bind-mounted volume a freshly written 500M+ file has intermittently
        # been read short here, silently producing an initramfs with no embedded
        # squashfs (82M instead of ~560M) and an unbootable installed OS.
        sync
        (cd "$build_dir" && echo "./rootfs.squashfs" | \
            cpio --create --format=newc --quiet) > "$out_file"
        # Hard guard: the raw cpio MUST be at least as large as the squashfs it
        # wraps. If it is short, Pass 1 read the file before it was fully visible —
        # fail loudly rather than ship a broken (squashfs-less) initramfs.
        local sqsz p1sz
        sqsz=$(stat -c %s "$build_dir/rootfs.squashfs")
        p1sz=$(stat -c %s "$out_file")
        [ "$p1sz" -ge "$sqsz" ] || \
            die "[$label] Pass 1 truncated: cpio is $p1sz bytes but rootfs.squashfs is $sqsz — squashfs not embedded"
        info "[$label] Pass 2: compressing base files"
        (cd "$build_dir" && find . ! -name "rootfs.squashfs" | \
            cpio --create --format=newc --quiet) | gzip -9 >> "$out_file"
    else
        (cd "$build_dir" && find . | cpio --create --format=newc --quiet) | \
            gzip -9 > "$out_file"
    fi
    local sz
    sz=$(du -sh "$out_file" | cut -f1)
    info "[$label] Done: $(basename "$out_file") ($sz)"
}

# ── Root check ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Must run as root inside the privileged builder (needed for chroot, mknod, etc.) — use ./docker-build.sh"

# ── Clean ────────────────────────────────────────────────────────────────────
if [ "$CLEAN" -eq 1 ]; then
    log "Cleaning work directory"
    # Unmount anything leftover inside rootfs
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
    # grub-mkrescue (stage 9), busybox (stage 7 initramfs), xz (stage 7 module
    # decompression) and gzip (stage 7 cpio packing) are needed just as much as
    # the rootfs tools below — check them all here so the build fails fast.
    for cmd in debootstrap mksquashfs xorriso cpio find grub-mkrescue xz gzip; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done
    # busybox ships as either `busybox` or `busybox-static`
    command -v busybox &>/dev/null || command -v busybox-static &>/dev/null || \
        MISSING+=("busybox-static")
    # GRUB x86_64-efi platform — required for the UEFI-only ISO in stage 9
    [ -f /usr/lib/grub/x86_64-efi/modinfo.sh ] || \
        MISSING+=("grub-efi-amd64-bin (GRUB x86_64-efi platform)")
    # Check for systemd-boot EFI binary
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
    else
        info "No rootfs-overlay directory found, skipping"
    fi
}

# ── Stage 4: chroot-configure ────────────────────────────────────────────────
run_stage 4 "chroot-configure — install packages and configure system" && {
    # Mount pseudo-filesystems
    info "Mounting proc/sys/dev inside chroot"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys  "$ROOTFS_DIR/sys"
    mount --bind /dev  "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"

    # Network DNS for package downloads
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    # Run the setup script
    chroot_run_with_deps \
        "$SCRIPT_DIR/scripts/setup-chroot.sh" \
        "$SCRIPT_DIR/config/packages.list" \
        "$SCRIPT_DIR/config/remove.list"

    # Unmount pseudo-filesystems
    info "Unmounting pseudo-filesystems"
    umount -lf "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount -lf "$ROOTFS_DIR/dev"     2>/dev/null || true
    umount -lf "$ROOTFS_DIR/sys"     2>/dev/null || true
    umount -lf "$ROOTFS_DIR/proc"    2>/dev/null || true
}

# ── Stage 5: clean-rootfs ─────────────────────────────────────────────────────
run_stage 5 "clean-rootfs — strip package manager and build artifacts" && {
    info "Running rootfs cleanup (removing apt/dpkg)"
    chroot_run "$SCRIPT_DIR/scripts/clean-rootfs.sh"
    info "Rootfs is now package-manager-free"
}

# ── Stage 6: make-squashfs ────────────────────────────────────────────────────
run_stage 6 "make-squashfs — compress rootfs into squashfs image" && {
    info "Creating squashfs (zstd compression)"
    rm -f "$SQUASHFS_FILE"
    mksquashfs "$ROOTFS_DIR" "$SQUASHFS_FILE" \
        -comp zstd \
        -Xcompression-level 19 \
        -no-progress \
        -noappend \
        -e "$ROOTFS_DIR/proc/*" \
        -e "$ROOTFS_DIR/sys/*"  \
        -e "$ROOTFS_DIR/dev/*"
    sz=$(du -sh "$SQUASHFS_FILE" | cut -f1)
    info "Squashfs created: $SQUASHFS_FILE ($sz)"
}

# ── Stage 7: build-initramfs ──────────────────────────────────────────────────
run_stage 7 "build-initramfs — build installer and OS initramfs cpio archives" && {
    # ── Installer extras: install.sh + mke2fs (with shared libs) ─────────────
    # The installer initramfs is "fat" — self-contained, no squashfs needed.
    # install.sh is baked in so the initramfs init can exec it directly.
    # mke2fs (from e2fsprogs in the rootfs) is included for ext4 home partition.
    INSTALLER_EXTRAS="$WORK_DIR/installer-extras"
    rm -rf "$INSTALLER_EXTRAS"
    mkdir -p "$INSTALLER_EXTRAS"

    info "[installer] Baking install.sh into initramfs"
    install -m 755 "$SCRIPT_DIR/installer/install.sh" "$INSTALLER_EXTRAS/install.sh"

    info "[installer] Copying mke2fs + shared libraries from rootfs"
    MKE2FS_BIN="$(find "$ROOTFS_DIR/sbin" "$ROOTFS_DIR/usr/sbin" \
                       "$ROOTFS_DIR/bin"  "$ROOTFS_DIR/usr/bin" \
                       -name "mke2fs" 2>/dev/null | head -1)"
    [ -n "$MKE2FS_BIN" ] || die "mke2fs not found in rootfs — add e2fsprogs to packages.list"

    install -D "$MKE2FS_BIN" "$INSTALLER_EXTRAS${MKE2FS_BIN#$ROOTFS_DIR}"
    # mkfs.ext4 is normally a symlink to mke2fs
    ln -sf "$(basename "$MKE2FS_BIN")" \
        "$INSTALLER_EXTRAS$(dirname "${MKE2FS_BIN#$ROOTFS_DIR}")/mkfs.ext4"

    # Copy the shared libraries mke2fs needs (hardcoded for Debian amd64).
    # Search by exact soname (no wildcard, no -type f) so that soname symlinks are
    # found and install dereferences them — avoids copying versioned filenames that
    # the dynamic linker won't resolve.
    for libname in libext2fs.so.2 libe2p.so.2 libcom_err.so.2 libblkid.so.1 libuuid.so.1 libc.so.6; do
        libpath="$(find "$ROOTFS_DIR/usr/lib" \
                        -name "$libname" 2>/dev/null | head -1)"
        if [ -n "$libpath" ]; then
            install -D "$libpath" "$INSTALLER_EXTRAS${libpath#$ROOTFS_DIR}"
            info "  lib: $libname"
        else
            info "  WARNING: $libname not found in rootfs"
        fi
    done
    # Dynamic linker — on Debian Trixie /lib and /lib64 are symlinks to usr/lib[64],
    # so search usr/ directly. The ELF interpreter path baked into binaries is
    # /lib64/ld-linux-x86-64.so.2, so install it there regardless of source path.
    LD_PATH="$(find "$ROOTFS_DIR/usr/lib" "$ROOTFS_DIR/usr/lib64" \
                    -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | head -1)"
    if [ -n "$LD_PATH" ]; then
        install -D "$LD_PATH" "$INSTALLER_EXTRAS/lib64/ld-linux-x86-64.so.2"
        info "  ld: ld-linux-x86-64.so.2"
    else
        info "  WARNING: dynamic linker not found in rootfs"
    fi

    info "[installer] Copying openssl + libcrypto from rootfs (for password hashing)"
    OPENSSL_BIN="$(find "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/bin" \
                        -name "openssl" -type f 2>/dev/null | head -1)"
    [ -n "$OPENSSL_BIN" ] || die "openssl not found in rootfs — add openssl to packages.list"
    install -D "$OPENSSL_BIN" "$INSTALLER_EXTRAS${OPENSSL_BIN#$ROOTFS_DIR}"
    # libssl, libcrypto, libz, libzstd — full openssl passwd dependency set.
    # Same soname-exact search as above.
    for libname in libssl.so.3 libcrypto.so.3 libz.so.1 libzstd.so.1; do
        libpath="$(find "$ROOTFS_DIR/usr/lib" \
                        -name "$libname" 2>/dev/null | head -1)"
        if [ -n "$libpath" ]; then
            install -D "$libpath" "$INSTALLER_EXTRAS${libpath#$ROOTFS_DIR}"
            info "  lib: $libname"
        else
            info "  WARNING: $libname not found in rootfs"
        fi
    done

    info "[installer] Copying sfdisk + libraries from rootfs (for GPT partitioning)"
    SFDISK_BIN="$(find "$ROOTFS_DIR/usr/sbin" "$ROOTFS_DIR/sbin" \
                       -name "sfdisk" 2>/dev/null | head -1)"
    [ -n "$SFDISK_BIN" ] || die "sfdisk not found in rootfs — add util-linux to packages.list"
    install -D "$SFDISK_BIN" "$INSTALLER_EXTRAS${SFDISK_BIN#$ROOTFS_DIR}"
    for libname in libfdisk.so.1 libsmartcols.so.1 libtinfo.so.6 libreadline.so.8; do
        libpath="$(find "$ROOTFS_DIR/usr/lib" -name "$libname" 2>/dev/null | head -1)"
        if [ -n "$libpath" ]; then
            install -D "$libpath" "$INSTALLER_EXTRAS${libpath#$ROOTFS_DIR}"
            info "  lib: $libname"
        else
            info "  WARNING: $libname not found in rootfs"
        fi
    done

    info "[installer] Copying mkdosfs from rootfs (for FAT32 formatting)"
    MKDOSFS_BIN="$(find "$ROOTFS_DIR/usr/sbin" "$ROOTFS_DIR/sbin" \
                        -name "mkdosfs" 2>/dev/null | head -1)"
    [ -n "$MKDOSFS_BIN" ] || die "mkdosfs not found in rootfs — add dosfstools to packages.list"
    install -D "$MKDOSFS_BIN" "$INSTALLER_EXTRAS${MKDOSFS_BIN#$ROOTFS_DIR}"

    # Build the fat installer initramfs
    build_initramfs "$SCRIPT_DIR/initramfs/installer" "$INSTALLER_INITRAMFS_FILE" \
                    "installer" "$INSTALLER_EXTRAS"

    # ── OS initramfs: fat — rootfs.squashfs is embedded directly ─────────────
    # Requires squashfs from stage 6. Check it exists before proceeding.
    [ -f "$SQUASHFS_FILE" ] || \
        die "rootfs.squashfs not found ($SQUASHFS_FILE) — run stage 6 first"

    OS_EXTRAS="$WORK_DIR/os-extras"
    rm -rf "$OS_EXTRAS"
    mkdir -p "$OS_EXTRAS"
    info "[os] Copying rootfs.squashfs into initramfs extras"
    cp "$SQUASHFS_FILE" "$OS_EXTRAS/rootfs.squashfs"

    build_initramfs "$SCRIPT_DIR/initramfs/os" "$INITRAMFS_FILE" "os" "$OS_EXTRAS"
}

# ── Stage 8: assemble-iso ────────────────────────────────────────────────────
run_stage 8 "assemble-iso — copy all files into ISO tree" && {
    info "Assembling ISO directory tree"
    rm -rf "$ISO_ROOT"
    # ISO layout:
    #   /               — installer runtime (GRUB boots /vmlinuz + /initramfs.img)
    #   /boot/grub/     — GRUB internal config (path fixed by grub-mkrescue)
    #   /larch-os/      — installed-OS payload (install.sh copies these to target)
    mkdir -p \
        "$ISO_ROOT/boot/grub" \
        "$ISO_ROOT/larch-os/loader/entries"

    # GRUB config (path fixed — grub-mkrescue reads /boot/grub/grub.cfg)
    cp "$SCRIPT_DIR/bootloader/grub.cfg" "$ISO_ROOT/boot/grub/grub.cfg"

    # Kernel — find vmlinuz in rootfs
    VMLINUZ=""
    for p in \
        "$ROOTFS_DIR/boot/vmlinuz" \
        "$ROOTFS_DIR/boot/vmlinuz-$(ls "$ROOTFS_DIR/lib/modules/" 2>/dev/null | sort -V | tail -1)"; do
        [ -f "$p" ] && { VMLINUZ="$p"; break; }
    done
    [ -f "$VMLINUZ" ] || VMLINUZ=$(ls "$ROOTFS_DIR/boot/vmlinuz"* 2>/dev/null | sort -V | tail -1)
    [ -f "$VMLINUZ" ] || die "Kernel vmlinuz not found in rootfs/boot"
    info "Kernel: $VMLINUZ"

    # ── ISO root: installer runtime ───────────────────────────────────────────
    cp "$VMLINUZ"                  "$ISO_ROOT/vmlinuz"       # GRUB: linux /vmlinuz
    cp "$INSTALLER_INITRAMFS_FILE" "$ISO_ROOT/initramfs.img" # GRUB: initrd /initramfs.img
    # rootfs.squashfs is embedded inside /larch-os/initramfs.img — no separate copy needed

    # ── /larch-os/: installed-OS payload ─────────────────────────────────────
    # install.sh copies these to the target EFI partition under /larch-os/
    cp "$INITRAMFS_FILE" "$ISO_ROOT/larch-os/initramfs.img"

    # systemd-boot EFI binary — install.sh places at EFI/BOOT/BOOTX64.EFI on target
    EFI_BIN="$(find "$ROOTFS_DIR/usr/lib/systemd/boot/efi" \
                    \( -name "systemd-bootx64.efi" -o -name "systemd-bootx64.efi.signed" \) \
                    2>/dev/null | head -1)"
    [ -f "$EFI_BIN" ] || die "systemd-boot EFI binary not found in rootfs"
    cp "$EFI_BIN" "$ISO_ROOT/larch-os/bootx64.efi"

    # systemd-boot loader config — install.sh copies to /loader/ on target
    cp "$SCRIPT_DIR/bootloader/loader.conf"        "$ISO_ROOT/larch-os/loader/"
    cp "$SCRIPT_DIR/bootloader/entries/larch.conf" "$ISO_ROOT/larch-os/loader/entries/"

    info "ISO tree assembled at $ISO_ROOT"
    du -sh "$ISO_ROOT"
}

# ── Stage 9: make-iso ─────────────────────────────────────────────────────────
run_stage 9 "make-iso — produce larch-os.iso via grub-mkrescue" && {
    # grub-mkrescue wraps xorriso and injects GRUB2 with full ISO9660 support.
    # GRUB reads /boot/grub/grub.cfg straight from the disc, so the kernel
    # and squashfs on the ISO9660 filesystem are directly accessible at boot —
    # unlike systemd-boot which has no ISO9660 driver.
    info "Building UEFI-only ISO with grub-mkrescue"
    rm -f "$OUTPUT_ISO"

    # UEFI only: point grub-mkrescue at a single GRUB platform directory.
    # By default grub-mkrescue scans /usr/lib/grub for every installed platform
    # and embeds a BIOS El Torito image whenever i386-pc is present (grub-pc-bin),
    # producing a BIOS+UEFI hybrid ISO. Passing -d <platform-dir> restricts it to
    # exactly that platform, so the disc carries only a UEFI El Torito entry —
    # deterministically UEFI-only regardless of what GRUB platforms the host has.
    GRUB_EFI_DIR="/usr/lib/grub/x86_64-efi"
    [ -f "$GRUB_EFI_DIR/modinfo.sh" ] || \
        die "GRUB x86_64-efi platform not found at $GRUB_EFI_DIR (install grub-efi-amd64-bin)"

    # -volid sets the ISO9660 volume label so blkid -L LARCHOS finds the disc.
    # No-space value avoids quoting issues with grub-mkrescue's xorriso passthrough.
    grub-mkrescue -d "$GRUB_EFI_DIR" -o "$OUTPUT_ISO" "$ISO_ROOT" -- -volid LARCHOS 2>/dev/null || \
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
