# updater/lib/hw.sh — find the larch partitions, load the bundled drivers
# Sourced by update.sh; not executable on its own.
#
# The updater initramfs carries its own network drivers (Ethernet, USB
# Ethernet, Wi-Fi, Thunderbolt), their firmware, HID/input, SDIO/MMC, crypto,
# loop and FAT (build stage 7, bundle_update_modules). It never reads
# LARCHSYS for them, so it still works when an interrupted update has left
# LARCHSYS half-written: boot "Update LARCH" again and retry.

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

# Storage drivers are built into the larch kernel, but USB/NVMe enumerate
# asynchronously. Only the GPT name is looked at, so a LARCHSYS with a broken
# image is still found.
wait_for_larchsys() {
    _w=0
    while [ -z "$(parts_named LARCHSYS)" ]; do
        _w=$((_w + 1))
        [ "$_w" -le 20 ] || return 1
        sleep 1
    done
}

# Load a module for every device modalias, like udev's coldplug. Display
# controllers (PCI class 0x03) are skipped: a GPU driver taking over the
# console is a risk with nothing to gain here (none are bundled anyway). A few
# passes, since loading a bus driver (USB, SDIO, HID) makes new devices appear.
coldplug() {
    for _pass in 1 2 3; do
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
    done
}

load_drivers() {
    [ -d "/lib/modules/$(uname -r)" ] \
        || die "This updater was built for another kernel than the one running ($(uname -r)). Reinstall from the ISO."
    # The kernel's own request_module() (crypto for WPA, nls for vfat, …)
    # must use kmod too.
    echo "$KMOD" > /proc/sys/kernel/modprobe 2>/dev/null || true
    coldplug
    # Not tied to a device: packet sockets (DHCP), loop (checking the
    # download), FAT (LARCHEFI), HID (keyboards), and the ciphers WPA2/3 use.
    for _m in af_packet loop vfat nls_cp437 nls_ascii nls_utf8 nls_iso8859-1 \
              usbhid hid_generic ccm gcm ctr cmac aes_generic aesni_intel; do
        "$KMOD" -q -b "$_m" 2>/dev/null || true
    done
    # Wi-Fi may come up soft-blocked; there is nothing persisted to honour.
    for _r in /sys/class/rfkill/*/soft; do
        [ -f "$_r" ] && echo 0 > "$_r" 2>/dev/null || true
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

# Choose the LARCHSYS to update; result in TARGET_SYS / TARGET_DISK /
# TARGET_EFI. With a single install there is nothing to ask.
pick_target() {
    set -- $(parts_named LARCHSYS)
    if [ "$#" -eq 1 ]; then
        TARGET_SYS="$1"
    else
        set --
        for _p in $(parts_named LARCHSYS); do
            _d=$(parent_disk "$_p")
            _desc=$(cat "/sys/block/$_d/device/vendor" "/sys/block/$_d/device/model" 2>/dev/null \
                    | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
            set -- "$@" "$_p" "/dev/$_d  ${_desc:-(unknown device)}"
        done
        while true; do
            dialog --backtitle "$DIALOG_BT" --title " Larch OS installs " \
                --cancel-label "Reboot" \
                --menu "\nMore than one disk has Larch OS. Which one should be updated?" \
                16 70 6 "$@" 2>"$DIALOG_TMP" && break
            do_reboot
        done
        TARGET_SYS=$(cat "$DIALOG_TMP")
    fi
    TARGET_DISK=$(parent_disk "$TARGET_SYS")
    TARGET_EFI=$(part_on_disk "$TARGET_DISK" LARCHEFI) \
        || die "No LARCHEFI partition next to /dev/$TARGET_SYS on /dev/$TARGET_DISK."
}
