# shared/lib/hw.sh — load the bundled drivers, find the larch partitions
# Sourced by every larch initramfs (system/initramfs/sys/init, the updater,
# the installer); not executable on its own. Needs $RUN and a die().
#
# Each initramfs carries its own drivers for the kernel it was built with
# (shared/build-lib.sh bundle_modules): sys.initramfs the storage and input
# drivers, the updater and the installer also every network driver and its
# firmware. Nothing is read from LARCHSYS for drivers, so the updater still
# works when LARCHSYS is broken.

KMOD=/usr/sbin/modprobe   # kmod's (handles .ko.xz); busybox's applet can't

# Kernel names (sda2, nvme0n1p2) of partitions whose GPT name is <name>.
# No udev here, so no /dev/disk/by-partlabel; the kernel's uevent has it.
parts_named() {
    for _u in /sys/class/block/*/uevent; do
        grep -qx "PARTNAME=$1" "$_u" 2>/dev/null || continue
        _n="${_u%/uevent}"
        echo "${_n##*/}"
    done
}

parent_disk() {
    _l=$(readlink -f "/sys/class/block/$1")
    _l="${_l%/*}"
    echo "${_l##*/}"
}

# The partition named <name> on disk <disk>, if any.
part_on_disk() {
    for _q in $(parts_named "$2"); do
        [ "$(parent_disk "$_q")" = "$1" ] && { echo "$_q"; return 0; }
    done
    return 1
}

part_bytes() { echo $(( $(cat "/sys/class/block/$1/size") * 512 )); }

# Load a module for every device modalias, like udev's coldplug. Display
# controllers (PCI class 0x03) are skipped: a GPU driver taking over the
# console is a risk with nothing to gain here (none are bundled anyway).
# <passes> rounds (default 3), since loading a bus driver (USB, SDIO, HID,
# Thunderbolt) makes new devices appear.
coldplug() {
    _passes="${1:-3}"
    while [ "$_passes" -gt 0 ]; do
        for _a in /sys/bus/*/devices/*/modalias; do
            [ -f "$_a" ] || continue
            case "$_a" in
                /sys/bus/pci/devices/*)
                    case "$(cat "${_a%/modalias}/class" 2>/dev/null)" in 0x03*) continue ;; esac ;;
            esac
            cat "$_a" 2>/dev/null
        done | sort -u > "$RUN/modaliases"
        xargs "$KMOD" -q -b -a < "$RUN/modaliases" 2>/dev/null || true
        sleep 1
        _passes=$((_passes - 1))
    done
}

# load_drivers [passes]
load_drivers() {
    [ -d "/lib/modules/$(uname -r)" ] \
        || die "This initramfs was built for another kernel than the one running ($(uname -r))."
    # The kernel's own request_module() (fs-ext4, crypto for WPA, nls for
    # vfat, …) must use kmod too.
    echo "$KMOD" > /proc/sys/kernel/modprobe 2>/dev/null || true
    coldplug "${1:-3}"
    # Not tied to a device: filesystems, loop (the squashfs file), packet
    # sockets (DHCP), HID (keyboards), the ciphers WPA2/3 use, and
    # qemu_fw_cfg (test-qemu.sh's local release source). Whatever this
    # initramfs doesn't carry is skipped.
    for _m in loop squashfs overlay ext4 vfat nls_cp437 nls_ascii nls_utf8 nls_iso8859-1 \
              isofs sr_mod sd_mod af_packet usbhid hid_generic \
              ccm gcm ctr cmac aes_generic aesni_intel qemu_fw_cfg; do
        "$KMOD" -q -b "$_m" 2>/dev/null || true
    done
}

# wait_for_part <name> [seconds]: until a partition with that GPT name shows
# up (USB/NVMe enumerate asynchronously), rescanning modaliases meanwhile.
wait_for_part() {
    _w=0
    while [ -z "$(parts_named "$1")" ]; do
        _w=$((_w + 1))
        [ "$_w" -le "${2:-20}" ] || return 1
        coldplug 1
    done
}

wait_for_keyboard() {
    _k=0
    while ! grep -q kbd /proc/bus/input/devices 2>/dev/null; do
        _k=$((_k + 1))
        [ "$_k" -le 10 ] || return 0
        sleep 1
    done
}

# Check (and repair what is safe to repair) an ext4 partition before mounting
# it read-write. 0/1 = clean or fixed; anything else is reported, not fatal.
fsck_ext4() {
    /usr/sbin/e2fsck -p "/dev/$1" >/dev/null 2>&1
    [ $? -le 1 ]
}
