# installer/lib/update.sh — in-place OS update (replace payload, keep config + home)
# Sourced by install.sh; not executable on its own.

# Replace the OS payload + bootloader on an existing LARCHOS partition, preserving
# the per-machine config files (hostname, hosts, passwd, shadow, username,
# machine-id, fstab) and the LARCHHOME partition. No partitioning, no formatting.
do_update() {
    _osdev="$1"
    if [ "$AUTO_YES" -ne 1 ]; then
        dialog --colors --yes-label "Update" --no-label "Cancel" \
            --backtitle "$DIALOG_BT" --title " Confirm Update " \
            --yesno "\
  Target disk  : $TARGET_DISK
  OS partition : $_osdev  (LARCHOS)

  The OS image and bootloader (kernel, initramfs, root
  filesystem, EFI binary, loader config) will be replaced
  with this version.

  Your user account, settings and home data are preserved.

  \Z1No partitions will be reformatted.\Zn" \
            16 66
        if [ $? -ne 0 ]; then
            return 1
        fi
        clear_screen
    fi

    INSTALL_STEPS=""
    show_step "Mounting LARCHOS partition ($_osdev)"
    mkdir -p "$MOUNT_OS"
    mount_or_die vfat "$_osdev" "$MOUNT_OS"
    [ -f "$MOUNT_OS/larch-os/rootfs.squashfs" ] \
        || die "No existing larch-os image on $_osdev (larch-os/rootfs.squashfs missing)"

    show_step "Updating EFI binary"
    mkdir -p "$MOUNT_OS/EFI/BOOT"
    cp "$ISO_MOUNT/EFI/BOOT/BOOTX64.EFI" "$MOUNT_OS/EFI/BOOT/BOOTX64.EFI"

    show_step "Updating bootloader config"
    rm -rf "$MOUNT_OS/loader"
    cp -r "$ISO_MOUNT/loader" "$MOUNT_OS/"

    show_step "Updating kernel and OS initramfs"
    mkdir -p "$MOUNT_OS/larch-os"
    cp "$ISO_MOUNT/larch-os/vmlinuz"       "$MOUNT_OS/larch-os/vmlinuz"
    cp "$ISO_MOUNT/larch-os/initramfs.img" "$MOUNT_OS/larch-os/initramfs.img"
    sync

    show_step "Updating OS squashfs (this may take a minute)"
    cp "$ISO_MOUNT/larch-os/rootfs.squashfs" "$MOUNT_OS/larch-os/rootfs.squashfs"
    sync

    umount "$MOUNT_OS"
    trap - EXIT

    dialog --backtitle "$DIALOG_BT" --title " Update Complete " \
        --msgbox "\
  larch-os has been updated successfully.

  Disk : $TARGET_DISK
  OS   : $_osdev  (LARCHOS)

  Your user account, settings and home data are unchanged.

  Remove the installation media, then choose OK to reboot." \
        15 64
    clear_screen
    umount /mnt/iso 2>/dev/null || true
    # install.sh is PID 1 (init exec's it). Plain `reboot` only signals init to
    # reboot — but we *are* init, and a bare shell doesn't act on that signal, so
    # the script would just exit and the kernel would panic ("Attempted to kill
    # init"). `-f` syncs and calls the reboot(2) syscall directly.
    do_reboot
}
