# shared/build-lib.sh — build helpers used by system/build.sh and installer/build.sh
#
# Sourced (bash), not executed. Every initramfs is assembled by hand from the
# larch OS rootfs ($ROOTFS_DIR, built by system/build.sh stages 2–5): busybox,
# kmod, the kernel modules for the hardware it must drive (picked by path from
# modules.dep, with their dependencies), optionally their firmware, a few tool
# binaries with their shared libraries, and the shell libraries in shared/lib/.
#
# Callers set ROOTFS_DIR and WORK_DIR before sourcing.

SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SHARED_DIR")"

log()  { echo; echo "════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════"; }
info() { echo "  ▸ $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── Module sets (extended regexes over modules.dep paths) ────────────────────
# Matched against "kernel/drivers/…/x.ko.xz"; each module's dependencies come
# along from modules.dep. Use [.] rather than \. (awk -v unescapes strings).
#
# Filesystems and the libraries/crypto they need, plus qemu_fw_cfg (lets
# test-qemu.sh point the installer/updater at a local build, see release.sh).
MODS_BASE='^kernel/(fs/(squashfs|overlayfs|ext4|jbd2|fat|nls|isofs)/|fs/mbcache[.]ko|lib/|crypto/|arch/x86/crypto/|drivers/firmware/qemu_fw_cfg[.]ko)'
# Disk drivers: every storage driver larch OS's kernel has, whole directories,
# nothing hand-picked — SATA/PATA, NVMe, all of SCSI (incl. SAS/RAID HBAs and
# the VM controllers), md/device-mapper, virtio/Xen/Hyper-V block, eMMC/SD,
# UFS, MemoryStick, NVDIMM, Fusion MPT, FireWire (SBP-2), CD-ROM, USB storage
# and the USB/Thunderbolt hosts and PCI controllers (Intel VMD) they sit behind.
MODS_DISK='^kernel/drivers/(ata|block|cdrom|md|memstick|message|mmc|nvdimm|nvme|scsi|ufs|virtio|hv|xen|firewire|thunderbolt|pci/controller|usb/(host|storage|common|core))/'
# Keyboards: USB/Bluetooth-less HID, and laptop keyboards/touchpads on I²C
# (i2c-hid needs the LPSS/DesignWare I²C controllers and Intel pinctrl).
MODS_INPUT='^kernel/drivers/(hid|input|i2c|mfd|pinctrl)/'
# Network drivers: every one larch OS's kernel has — all of drivers/net
# (Ethernet, USB Ethernet, Wi-Fi incl. the DKMS-built Broadcom wl), Thunderbolt
# networking — plus the 802.11 stack, rfkill and packet sockets (DHCP).
MODS_NET='^kernel/(drivers/(net|thunderbolt|bcma|ssb)/|net/(wireless|mac80211|rfkill|packet)/)|^updates/(.*/)?wl[.]ko'

# copy_overlay <src> <root>: files mirroring their target paths, copied over
# <root>. cp -a carries the checkout's modes, which a umask of 002 leaves
# group-writable — on /, /etc, /usr too. Nothing here wants g/o write.
copy_overlay() {
    cp -a "$1/." "$2/"
    (cd "$1" && find . ! -type l -print0) | (cd "$2" && xargs -0 chmod go-w)
}

rootfs_kver() {
    local k
    k=$(ls "$ROOTFS_DIR/usr/lib/modules/" 2>/dev/null | sort -V | tail -1)
    [ -n "$k" ] || die "No kernel modules in the rootfs — run system stages 2-5 first"
    echo "$k"
}

find_vmlinuz() {
    local kver; kver=$(rootfs_kver)
    if [ -f "$ROOTFS_DIR/boot/vmlinuz-$kver" ]; then echo "$ROOTFS_DIR/boot/vmlinuz-$kver"; return 0; fi
    ls "$ROOTFS_DIR/boot/vmlinuz"* 2>/dev/null | sort -V | tail -1
}

copy_bin_with_libs() {
    # Copy a binary from the larch OS rootfs into dst_root, together with all
    # its shared library dependencies resolved via the rootfs dynamic linker.
    local binary="$1" dst_root="$2"

    local src
    src=$(find "$ROOTFS_DIR/usr/sbin" "$ROOTFS_DIR/usr/bin" \
               -name "$binary" 2>/dev/null | head -1)
    [ -n "$src" ] || die "Binary '$binary' not found in larch OS rootfs"

    local rel="${src#$ROOTFS_DIR}"
    install -D "$src" "$dst_root$rel"
    info "  [bin] $binary → $rel"

    # The dynamic linker. All Debian amd64 binaries name
    # /lib64/ld-linux-x86-64.so.2 as their interpreter; in the initramfs /lib64
    # is a real directory, so put the symlink inside it explicitly.
    local ldso_src ldso_rel
    ldso_src=$(find "$ROOTFS_DIR/usr/lib" -name "ld-linux-x86-64.so.2" 2>/dev/null | head -1)
    if [ -n "$ldso_src" ]; then
        ldso_src=$(readlink -f "$ldso_src" 2>/dev/null || echo "$ldso_src")
        ldso_rel="${ldso_src#$ROOTFS_DIR}"
        install -D "$ldso_src" "$dst_root$ldso_rel" 2>/dev/null || true
        mkdir -p "$dst_root/lib64"
        ln -sf "$ldso_rel" "$dst_root/lib64/ld-linux-x86-64.so.2" 2>/dev/null || true
    fi

    # ldd inside the chroot: paths come out without the ROOTFS_DIR prefix and
    # use the rootfs's ld.so.cache.
    local lib_paths
    lib_paths=$(chroot "$ROOTFS_DIR" ldd "$rel" 2>/dev/null | \
                awk '/=>/ && $3 ~ /^\// { print $3 }' || true)
    [ -n "$lib_paths" ] || return 0

    local lib libsrc real real_rel
    while IFS= read -r lib; do
        [ -n "$lib" ] || continue
        libsrc="$ROOTFS_DIR$lib"
        [ -e "$libsrc" ] || continue
        real=$(readlink -f "$libsrc" 2>/dev/null || true)
        [ -f "$real" ] || continue
        real_rel="${real#$ROOTFS_DIR}"
        install -D "$real" "$dst_root$real_rel" 2>/dev/null || true
        # Soname symlink with an absolute target (the link and the file may be
        # in different prefix dirs, /lib vs /usr/lib, on merged-usr Debian).
        if [ "$libsrc" != "$real" ]; then
            mkdir -p "$(dirname "$dst_root$lib")"
            ln -sf "$real_rel" "$dst_root$lib" 2>/dev/null || true
        fi
    done <<< "$lib_paths"
}

# init_initramfs_tree <build_dir> <init_script>
# The skeleton every larch initramfs starts from: busybox with all its applets
# in /bin, kmod's modprobe (the rootfs's modules are .ko.xz, which busybox
# can't load), the init script and the shell libraries in /usr/lib/larch.
init_initramfs_tree() {
    local build_dir="$1" init_src="$2" applet
    rm -rf "$build_dir"
    mkdir -p "$build_dir"/{bin,sbin,lib,lib64,usr/bin,usr/sbin,usr/lib/larch,dev,proc,sys,run,tmp,etc,mnt,sysroot}

    local busybox_bin="$ROOTFS_DIR/usr/bin/busybox"
    [ -f "$busybox_bin" ] || die "busybox not found in the rootfs (busybox-static is in packages.list)"
    install -m 755 "$busybox_bin" "$build_dir/bin/busybox"
    for applet in $("$build_dir/bin/busybox" --list); do
        [ "$applet" = busybox ] || ln -sf busybox "$build_dir/bin/$applet"
    done
    for applet in udhcpc ip sha256sum stat xargs setsid cttyhack readlink zcat cpio \
                  switch_root mount blkid; do
        [ -e "$build_dir/bin/$applet" ] \
            || die "busybox in the rootfs lacks the '$applet' applet the initramfs scripts need"
    done

    install -m 755 "$init_src" "$build_dir/init"
    ln -sf /proc/mounts "$build_dir/etc/mtab"   # e2fsck checks it

    copy_bin_with_libs modprobe "$build_dir"
    install -m 644 "$SHARED_DIR"/lib/*.sh "$build_dir/usr/lib/larch/"
}

# bundle_modules <build_dir> <with_firmware 0|1> <regex>...
# The modules whose modules.dep path matches any <regex>, with their
# dependencies (modules.dep lists them transitively), kept compressed for
# kmod. With <with_firmware> 1, also the firmware those modules declare
# (MODULE_FIRMWARE) as present in the rootfs, plus what cfg80211/brcmfmac load
# without declaring it. Also the image's modprobe.d (e.g. broadcom-sta's
# blacklist of b43/bcma).
bundle_modules() {
    local build_dir="$1" with_fw="$2"; shift 2
    local re; re=$(IFS='|'; echo "$*")
    local kver; kver=$(rootfs_kver)
    local src="$ROOTFS_DIR/usr/lib/modules/$kver"
    local dst="$build_dir/usr/lib/modules/$kver"
    local label; label=$(basename "$build_dir")
    [ -f "$src/modules.dep" ] || die "modules.dep not found for kernel $kver"
    local list="$WORK_DIR/$label.modules" fwlist="$WORK_DIR/$label.firmware"

    awk -F': *' -v re="$re" '
        $1 ~ re {
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
    info "[$label] kernel $kver: $(wc -l < "$list") modules ($(du -sh "$dst" | cut -f1))"

    mkdir -p "$build_dir/etc/modprobe.d" "$build_dir/usr/lib/modprobe.d"
    cp -a "$ROOTFS_DIR/etc/modprobe.d/." "$build_dir/etc/modprobe.d/" 2>/dev/null || true
    cp -a "$ROOTFS_DIR/usr/lib/modprobe.d/." "$build_dir/usr/lib/modprobe.d/" 2>/dev/null || true
    ln -sfn ../usr/lib/modprobe.d "$build_dir/lib/modprobe.d"

    [ "$with_fw" = 1 ] || return 0
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
    info "[$label] firmware: $(find "$build_dir/usr/lib/firmware" -type f | wc -l) files ($(du -sh "$build_dir/usr/lib/firmware" | cut -f1))"
}

# bundle_network <build_dir>
# What shared/lib/net.sh and release.sh run: curl (GitHub API + downloads),
# wpa_supplicant/wpa_cli (Wi-Fi), busybox udhcpc with its script, the CA
# bundle, and the bare /etc that name resolution needs.
bundle_network() {
    local build_dir="$1" bin
    for bin in curl wpa_supplicant wpa_cli; do
        copy_bin_with_libs "$bin" "$build_dir"
    done
    install -D -m 755 "$SHARED_DIR/udhcpc.script" "$build_dir/usr/share/udhcpc/default.script"
    install -D -m 644 "$ROOTFS_DIR/etc/ssl/certs/ca-certificates.crt" \
        "$build_dir/etc/ssl/certs/ca-certificates.crt"
    printf 'hosts: files dns\n' > "$build_dir/etc/nsswitch.conf"
    printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > "$build_dir/etc/hosts"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$build_dir/etc/passwd"
    printf 'root:x:0:\n' > "$build_dir/etc/group"
}

bundle_dialog() {
    # dialog drives the installer's and the updater's entire UI (ncurses) and
    # is a REQUIRED component — neither has a text fallback.
    local build_dir="$1" label="$2"
    find "$ROOTFS_DIR/usr/bin" -name dialog 2>/dev/null | grep -q . \
        || die "dialog not found in rootfs — required by the $label (it ships via system/config/packages.list; rebuild from system stage 4)"
    copy_bin_with_libs dialog "$build_dir"
    # ncurses needs a terminfo entry for $TERM; the scripts use TERM=linux.
    local ti_src="$ROOTFS_DIR/usr/share/terminfo" ent
    [ -d "$ti_src" ] || die "terminfo not found in rootfs — required for the $label's dialog UI"
    for ent in l/linux v/vt100 v/vt220 a/ansi x/xterm x/xterm-256color d/dumb; do
        [ -f "$ti_src/$ent" ] && install -D "$ti_src/$ent" "$build_dir/usr/share/terminfo/$ent"
    done
    [ -f "$build_dir/usr/share/terminfo/l/linux" ] \
        || die "terminfo entry for TERM=linux not found in rootfs — required for the $label's dialog UI"
}

pack_initramfs() {
    # Pack <build_dir> as a single gzip cpio at <out> (release.sh lists it
    # with zcat | cpio -t to check which kernel it was built for).
    local build_dir="$1" out="$2"
    rm -f "$out"
    mkdir -p "$(dirname "$out")"
    (cd "$build_dir" && find . | cpio --create --format=newc --quiet) | gzip -9 > "$out"
    info "$(basename "$out"): $(du -sh "$out" | cut -f1)"
}

# Stage selection shared by both build scripts: --stage N (from N), --only N,
# --to N (up to N).
parse_stage_args() {
    START_STAGE=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) START_STAGE="$2"; shift 2 ;;
            --only)  START_STAGE="$2"; END_STAGE="$2"; shift 2 ;;
            --to)    END_STAGE="$2"; shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

run_stage() {
    local n="$1"; shift
    [ "$n" -ge "$START_STAGE" ] && [ "$n" -le "$END_STAGE" ] || return 1
    log "$BUILD_NAME stage $n: $*"
}
