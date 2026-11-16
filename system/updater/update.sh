#!/bin/sh
# system/updater/update.sh — the Manage LARCH menu and the in-place updater
#
# Bundled into updater.initramfs as /usr/sbin/larch-update and run by its init
# (system/initramfs/updater/init) when "Manage LARCH" is picked in the
# systemd-boot menu. It loads the storage/network/input drivers and firmware
# bundled in this initramfs (shared/lib/hw.sh) — LARCHSYS is never read for
# them, so a failed update can be retried by booting "Manage LARCH" again —,
# finds the install, and shows the welcome menu:
#
#   Update LARCH         the update below
#   Manage users         add a user, or delete one (with its password; its
#                        home kept or deleted) — manage.sh
#   Reset LARCH OS       LARCHCONF's /etc and /var layers emptied but for the
#                        accounts, computer name and machine-id
#   Boot into EFI setup  reboot into the firmware's setup (OsIndications)
#
# The update:
#
#   1. Get online: DHCP on a cable if one is plugged in, else list Wi-Fi
#      networks and ask for the password (never stored).
#   2. List the last $RELEASES_SHOWN releases on GitHub, one entry per desktop
#      (larch-gnome-v0.1.5, larch-cosmic-v0.1.5, larch-gnome-v0.1.4, …), and
#      ask which one. Any desktop can be picked: that is how the desktop is
#      switched.
#   3. Download its files (shared/lib/release.sh) into LARCHSYS:/.staging and
#      verify them against SHA256SUMS; check that the image is Larch OS with
#      that desktop and that kernel, both initramfs and the image's modules
#      belong together.
#   4. Swap everything in: sys.squashfs by an ext4 rename on LARCHSYS, the
#      kernel, sys.initramfs, updater.initramfs, systemd-boot (BOOTX64.EFI) and
#      its entries (loader.tar) on LARCHEFI (each copied beside the old file,
#      then renamed). Until step 4 the installed system is untouched.
#
# No partitioning, and the update mounts neither LARCHHOME nor LARCHCONF —
# not even on a desktop switch: /etc and /var's upper layers (accounts,
# networks, printers, every setting) carry over as they are. The new image's
# system users are added on its first boot by systemd-sysusers (its /usr is
# newer than the layers' .updated stamps). Reset LARCH OS is the clean slate.

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

DIALOG_BT="Manage Larch OS"
DIE_TITLE="Error"
. /usr/lib/larch/ui.sh
. /usr/lib/larch/hw.sh
. /usr/lib/larch/net.sh
. /usr/lib/larch/release.sh
. /usr/lib/larch/conf.sh
. /usr/lib/larch/account.sh
. /usr/lib/larch/manage.sh

SYS_MNT="$RUN/sys"
EFI_MNT="$RUN/efi"
CONF_MNT="$RUN/conf"
STAGE="$SYS_MNT/.staging"
mkdir -p "$SYS_MNT" "$EFI_MNT" "$CONF_MNT"

free_bytes() { df -Pk "$1" | awk 'NR == 2 { print $4 * 1024 }'; }

# Choose the install to update; result in TARGET_SYS / TARGET_DISK /
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
                --menu "\nMore than one disk has Larch OS. Which one should be managed?" \
                16 70 6 "$@" 2>"$DIALOG_TMP" && break
            do_reboot
        done
        TARGET_SYS=$(cat "$DIALOG_TMP")
    fi
    TARGET_DISK=$(parent_disk "$TARGET_SYS")
    TARGET_EFI=$(part_on_disk "$TARGET_DISK" LARCHEFI) \
        || die "No LARCHEFI partition next to /dev/$TARGET_SYS on /dev/$TARGET_DISK."
    TARGET_CONF=$(part_on_disk "$TARGET_DISK" LARCHCONF) \
        || die "No LARCHCONF partition next to /dev/$TARGET_SYS on /dev/$TARGET_DISK."
}

# Abandon the chosen release: nothing installed has changed.
discard() {
    umount "$NEW_MNT" 2>/dev/null || true
    rm -rf "$STAGE"
}

# ── Drivers, partitions ──────────────────────────────────────────────────────

echo "[larch-update] Loading drivers..." > /dev/console
load_drivers
wait_for_keyboard
echo "[larch-update] Looking for the installed system..." > /dev/console
wait_for_part LARCHSYS || die "No Larch OS system partition (LARCHSYS) found."
pick_target

fsck_ext4 "$TARGET_SYS" \
    || die "The system partition /dev/$TARGET_SYS has file system errors that need a manual fsck."
mount -t ext4 "/dev/$TARGET_SYS" "$SYS_MNT" || die "Could not mount the system partition /dev/$TARGET_SYS."
mount -t vfat "/dev/$TARGET_EFI" "$EFI_MNT" || die "Could not mount the EFI partition /dev/$TARGET_EFI."
CURRENT_VERSION=$(cat "$SYS_MNT/version" 2>/dev/null || true)
# Installs from before desktops were selectable are GNOME.
CURRENT_DESKTOP=$(cat "$SYS_MNT/desktop" 2>/dev/null || echo gnome)
CURRENT="larch-$CURRENT_DESKTOP-${CURRENT_VERSION:-unknown}"
# Left over from an interrupted update.
rm -rf "$STAGE"

# ── Network, release, download ───────────────────────────────────────────────

update_system() {
    [ "$NET_UP" = 1 ] || { net_up; NET_UP=1; }

    while true; do
        lookup_releases
        choose_release "$CURRENT" "$(default_release "$CURRENT_DESKTOP")" Back || return 0
        SWITCH=0
        _switch_note=""
        if [ "$REL_DESKTOP" != "$CURRENT_DESKTOP" ]; then
            SWITCH=1
            _switch_note="

      \Z1This switches the desktop from $CURRENT_DESKTOP to $REL_DESKTOP.\Zn
      Accounts and system settings are kept as they are. If the new
      desktop misbehaves, Reset LARCH OS returns the system settings
      to how they were right after installation."
        fi
        dialog --colors --backtitle "$DIALOG_BT" --title " Update " \
            --yes-label "Install" --no-label "Back" \
            --yesno "\
      Installed        : $CURRENT
      New              : $REL_NAME
      Download         : $(( REL_SIZE / 1048576 )) MB
      System partition : /dev/$TARGET_SYS

      The system files are replaced once the download is verified.
      Your files and apps are kept.$_switch_note" $(( SWITCH ? 19 : 14 )) 74 \
            || continue
        if [ "$(free_bytes "$SYS_MNT")" -lt $(( REL_SIZE + 64 * 1048576 )) ]; then
            note "Not enough space" "  The system partition has $(( $(free_bytes "$SYS_MNT") / 1048576 )) MB free; this release needs\n  $(( REL_SIZE / 1048576 + 64 )) MB to download next to the installed system."
            continue
        fi
        download_release "$STAGE" || { discard; continue; }
        check_release "$STAGE"    || { discard; continue; }
        _need=$(du -sk "$STAGE/$KERNEL" "$STAGE/$SYS_INITRD" "$STAGE/$UPD_INITRD" "$STAGE/boot" \
                | awk '{ s += $1 } END { print (s + 1024) * 1024 }')
        if [ "$(free_bytes "$EFI_MNT")" -lt "$_need" ]; then
            discard
            die "The EFI partition /dev/$TARGET_EFI is too small for this release ($(( _need / 1048576 )) MB needed next to the installed files). Nothing was changed."
        fi
        umount "$NEW_MNT"
        break
    done
    install_release
}

# ── Install ──────────────────────────────────────────────────────────────────
install_release() {
    # From here on the old system is being replaced. Between the steps the image
    # and the kernel don't match and the system may not start, but the old
    # kernel + updater pair still does: boot "Manage LARCH" again and pick the
    # same entry.

    msg "Installing" "Installing $REL_NAME..."
    mv -f "$STAGE/$SYS_IMG" "$SYS_MNT/sys.squashfs" \
        || die "Could not replace sys.squashfs on /dev/$TARGET_SYS. The installed system is unchanged."
    sync
    install_boot_files "$STAGE" "$EFI_MNT" \
        || die "Could not install the new kernel and bootloader on LARCHEFI (/dev/$TARGET_EFI). Reboot and pick \"Manage LARCH\" → \"Update LARCH\" to retry."
    printf '%s\n' "$NEW_VERSION" > "$SYS_MNT/version"
    printf '%s\n' "$REL_DESKTOP" > "$SYS_MNT/desktop"
    rm -rf "$STAGE"
    sync
    umount "$EFI_MNT" 2>/dev/null || true
    umount "$SYS_MNT" 2>/dev/null || true

    dialog --backtitle "$DIALOG_BT" --title " Update complete " \
        --msgbox "\n  $REL_NAME has been installed.\n\n  Choose OK to reboot." 10 60
    do_reboot
}

# ── Welcome menu ─────────────────────────────────────────────────────────────

NET_UP=0
while true; do
    dialog --backtitle "$DIALOG_BT" --title " Manage LARCH " \
        --ok-label "Select" --cancel-label "Reboot" \
        --menu "\nWelcome to Larch OS.\n\nInstalled: $CURRENT on /dev/$TARGET_DISK\n\nWhat would you like to do?" \
        16 70 4 \
        1 "Update LARCH" \
        2 "Manage users" \
        3 "Reset LARCH OS" \
        4 "Boot into EFI setup" \
        2>"$DIALOG_TMP" || do_reboot
    case "$(cat "$DIALOG_TMP")" in
        1) update_system ;;
        2) manage_users ;;
        3) reset_system ;;
        4) efi_setup ;;
    esac
done
