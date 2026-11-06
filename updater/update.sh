#!/bin/sh
# updater/update.sh — larch-os in-place updater
#
# Bundled into the updater initramfs as /usr/sbin/larch-update and run by its
# init (initramfs/update/init) when "Update LARCH" is picked in the
# systemd-boot menu. Flow:
#
#   1. Load the network/input drivers and firmware bundled in this initramfs
#      (lib/hw.sh). LARCHSYS is never read, so a failed update can be retried
#      by booting "Update LARCH" again.
#   2. Get online: DHCP on a cable if one is plugged in, else list Wi-Fi
#      networks and ask for the password (never stored).
#   3. List the last $RELEASES_SHOWN releases on GitHub and ask which one.
#   4. Download its larch-os-rootfs.squashfs and larch-os-update-initramfs.img
#      into RAM and verify their sha256s.
#   5. Write the image raw over LARCHSYS (no A/B: the one system partition is
#      replaced) and read it back to verify. Only then touch LARCHEFI: install
#      the image's kernel as larch-os/vmlinuz and the release's updater (built
#      for that kernel) as larch-os/update-initramfs.img. Until that step the
#      old kernel + updater pair on LARCHEFI is intact, so any failure before
#      it can be retried from the boot menu.
#
# LARCHCONF and LARCHHOME are never mounted: /etc and /var's upper layers,
# the user, and their files carry over as they are. The loader entries (with
# this machine's systemd.machine_id=/systemd.hostname=) are left alone.

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

. /usr/lib/larch-update/common.sh
. /usr/lib/larch-update/hw.sh
. /usr/lib/larch-update/net.sh
. /usr/lib/larch-update/release.sh

# ── Drivers ───────────────────────────────────────────────────────────────────

echo "[larch-update] Loading drivers..." > /dev/console
load_drivers
wait_for_keyboard
echo "[larch-update] Looking for the installed system..." > /dev/console
wait_for_larchsys || die "No Larch OS system partition (LARCHSYS) found."

pick_target

# ── Network, release, download ────────────────────────────────────────────────

net_up

while true; do
    choose_release
    dialog --backtitle "$DIALOG_BT" --title " Update " \
        --yes-label "Update" --no-label "Back" \
        --yesno "\
  Release          : $REL_TAG
  Download         : $(( REL_SIZE / 1048576 )) MB
  System partition : /dev/$TARGET_SYS

  The system partition is replaced by this release once the
  download is verified. Your files, settings and apps are kept.

  Don't turn the computer off while it is being written." 15 70 \
        || continue
    download_release || continue
    check_image      || continue
    break
done

# ── Write ─────────────────────────────────────────────────────────────────────
# From here on the old system is being replaced.

IMG_BYTES=$(stat -c %s "$IMG")
while true; do
    dd if="$IMG" of="/dev/$TARGET_SYS" bs=4M conv=fsync 2>"$RUN/dd.err" &
    _pid=$!
    progress "$_pid" "$IMG_BYTES" "Writing" "Writing Larch OS $REL_TAG to /dev/$TARGET_SYS..." \
        awk '/^wchar:/ { print $2 }' "/proc/$_pid/io"
    _ok=1
    wait "$_pid" || _ok=0
    if [ "$_ok" -eq 1 ]; then
        msg "Writing" "Verifying the system partition..."
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        _got=$(head -c "$IMG_BYTES" "/dev/$TARGET_SYS" | sha256sum | cut -d' ' -f1)
        [ "$_got" = "$WANT_SHA" ] && break
    fi
    # The partition is now neither the old system nor the new one, so don't
    # let the user walk away from it. The image is still in RAM.
    dialog --backtitle "$DIALOG_BT" --title " Write failed " \
        --yes-label "Retry" --no-label "Shell" \
        --yesno "\nWriting /dev/$TARGET_SYS failed or did not verify.\n$(tail -1 "$RUN/dd.err" 2>/dev/null)\n\nThe system will not boot until this succeeds. Retry now? (You can also reboot and pick \"Update LARCH\" again.)" 14 70 \
        || die "The system partition /dev/$TARGET_SYS is incomplete. Reboot and pick \"Update LARCH\" to retry. The image is still at $IMG."
done

# Kernel and updater go together (the updater's modules are built for that
# kernel): copy both beside the old ones, then rename them into place —
# FAT renames are as close to atomic as it gets.
if [ -n "$NEW_KERNEL" ] || [ -n "$NEW_UPDATER" ]; then
    msg "Writing" "Installing the new kernel and updater..."
    mount -t vfat "/dev/$TARGET_EFI" "$EFI_MNT" \
        || die "Could not mount LARCHEFI (/dev/$TARGET_EFI). The new system is written but its kernel is not installed."
    _d="$EFI_MNT/larch-os"
    _ok=1
    [ -z "$NEW_UPDATER" ] || cp "$NEW_UPDATER" "$_d/update-initramfs.img.new" || _ok=0
    [ -z "$NEW_KERNEL" ]  || cp "$NEW_KERNEL"  "$_d/vmlinuz.new"              || _ok=0
    sync
    if [ "$_ok" -eq 1 ]; then
        [ -z "$NEW_UPDATER" ] || mv -f "$_d/update-initramfs.img.new" "$_d/update-initramfs.img" || _ok=0
        [ -z "$NEW_KERNEL" ]  || mv -f "$_d/vmlinuz.new" "$_d/vmlinuz" || _ok=0
        sync
    fi
    rm -f "$_d/update-initramfs.img.new" "$_d/vmlinuz.new"
    umount "$EFI_MNT" 2>/dev/null || true
    [ "$_ok" -eq 1 ] \
        || die "Could not install the new kernel/updater on LARCHEFI (full?). The new system is written; reboot and pick \"Update LARCH\" to retry."
fi

dialog --backtitle "$DIALOG_BT" --title " Update complete " \
    --msgbox "\n  Larch OS $REL_TAG has been installed.\n\n  Choose OK to reboot." 10 60
do_reboot
