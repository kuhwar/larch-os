# installer/lib/disk.sh — disk detection, sizing, and picker dialog
# Sourced by install.sh; not executable on its own.

# Render a byte count as a human-readable capacity (GB/TB, base-10 like disks).
human_size() {
    _b="$1"
    if [ "$_b" -ge 1000000000000 ]; then
        printf '%d.%01d TB\n' "$(( _b / 1000000000000 ))" "$(( (_b % 1000000000000) / 100000000000 ))"
    elif [ "$_b" -ge 1000000000 ]; then
        printf '%d.%01d GB\n' "$(( _b / 1000000000 ))" "$(( (_b % 1000000000) / 100000000 ))"
    elif [ "$_b" -ge 1000000 ]; then
        printf '%d MB\n' "$(( _b / 1000000 ))"
    else
        printf '%d B\n' "$_b"
    fi
}

# Is this partition a larch-os EFI partition? The installer formats LARCHEFI as
# FAT32 with `mkfs.fat -n LARCHEFI`, which writes the 11-byte volume label into the
# boot sector at offset 71 (FAT BS_VolLab). busybox has no `blkid`, so read it raw
# with dd — this needs no mount and works per-partition (findfs only resolves a
# label to a single device, so it can't tell which disk owns it).
part_is_larchefi() {
    [ -b "$1" ] || return 1
    _lbl=$(dd if="$1" bs=1 skip=71 count=11 2>/dev/null | tr -d ' \000')
    [ "$_lbl" = "LARCHEFI" ]
}

# Does a disk (by sysfs name, e.g. sda) hold a larch-os install? Partition sysfs
# dirs are prefixed with the disk name (sda1, nvme0n1p1).
disk_has_larch() {
    for _pp in /sys/block/"$1"/"$1"*/partition; do
        [ -f "$_pp" ] || continue
        _pn=$(basename "$(dirname "$_pp")")
        part_is_larchefi "/dev/$_pn" && return 0
    done
    return 1
}

# dialog --menu of installable disks; selection (a /dev path) lands in TARGET_DISK.
# Disks that already carry a larch-os install are marked and listed first, with the
# first such disk pre-selected. Installing always erases the chosen disk;
# in-place updates are the "Update LARCH" boot entry (updater/update.sh).
# ESC re-shows the dialog. Restart button calls do_reboot.
pick_disk_dialog() {
    while true; do
        _default=""
        set --
        # Two passes so larch-os disks come first; within a pass, sysfs order.
        for _want_larch in 1 0; do
            for _sys in /sys/block/*; do
                _name=$(basename "$_sys")
                case "$_name" in
                    loop*|sr*|ram*|fd*|dm-*|md*) continue ;;
                esac
                [ -b "/dev/$_name" ] || continue
                if disk_has_larch "$_name"; then _is_larch=1; else _is_larch=0; fi
                [ "$_is_larch" -eq "$_want_larch" ] || continue
                _sectors=$(cat "$_sys/size" 2>/dev/null || echo 0)
                _size=$(human_size $(( _sectors * 512 )))
                _vendor=$(cat "$_sys/device/vendor" 2>/dev/null || echo "")
                _model=$(cat "$_sys/device/model" 2>/dev/null || echo "")
                _desc=$(echo "$_vendor $_model" | sed 's/^ *//;s/ *$//;s/  */ /g')
                [ -n "$_desc" ] || _desc="(unknown device)"
                if [ "$_is_larch" -eq 1 ]; then
                    _desc="$_desc  [Larch OS]"
                    [ -n "$_default" ] || _default="/dev/$_name"
                fi
                set -- "$@" "/dev/$_name" "$_size  $_desc"
            done
        done
        [ "$#" -gt 0 ] || die "No installable disks found"
        : > "$DIALOG_TMP"
        dialog --no-cancel --extra-button --extra-label "Restart" \
            --default-item "$_default" \
            --backtitle "$DIALOG_BT" --title " Target Disk " \
            --menu "Select the target disk. Disks marked [Larch OS] already have larch-os installed.\nThe selected disk will be ERASED." \
            18 72 8 "$@" 2>"$DIALOG_TMP"
        _rc=$?
        if [ "$_rc" -eq 0 ]; then
            TARGET_DISK=$(cat "$DIALOG_TMP")
            return 0
        fi
        if [ "$_rc" -eq 3 ]; then
            do_reboot
        fi
        # ESC (255) or any other code: re-show the dialog silently
    done
}
