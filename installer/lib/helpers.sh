# installer/lib/helpers.sh — installer constants and helpers
# Sourced by install.sh after the shared libraries (ui.sh, hw.sh, net.sh,
# release.sh, conf.sh); not executable on its own.

# LARCHEFI holds the kernel, sys.initramfs, updater.initramfs (with every
# network driver and its firmware) and systemd-boot — and room for a second
# copy of each, since an update copies the new files beside the old ones.
EFI_PART_SIZE="1GiB"
# LARCHSYS (ext4) holds sys.squashfs — and the next release's files while an
# update downloads them.
SYS_PART_SIZE="4GiB"
# LARCHCONF holds the upper layers of /etc and /var, i.e. all runtime state
# (journal capped at 64M, Flatpak system installs excluded — those go to
# --user in /home).
CONF_PART_SIZE="1GiB"
TARGET_DISK=""
AUTO_YES=0
MOUNT_EFI="$RUN/target-efi"
MOUNT_SYS="$RUN/target-sys"
MOUNT_CONF="$RUN/target-conf"
MOUNT_HOME="$RUN/target-home"
MOUNT_IMG="$RUN/target-img"
STAGE="$MOUNT_SYS/.staging"

LARCH_HOSTNAME=""
LARCH_FULLNAME=""
LARCH_USERNAME=""
LARCH_PASSWORD=""

# Accumulate step messages and show them inside a dialog infobox so installation
# progress stays on screen rather than bleeding to the raw terminal.
INSTALL_STEPS=""
show_step() {
    INSTALL_STEPS="${INSTALL_STEPS}  >> $*
"
    dialog --backtitle "$DIALOG_BT" --title " Installing... " \
        --infobox "$INSTALL_STEPS" 20 70 || true
}

cleanup() {
    umount "$MOUNT_IMG"  2>/dev/null || true
    umount "$NEW_MNT"    2>/dev/null || true
    umount "$MOUNT_EFI"  2>/dev/null || true
    umount "$MOUNT_SYS"  2>/dev/null || true
    umount "$MOUNT_CONF" 2>/dev/null || true
    umount "$MOUNT_HOME" 2>/dev/null || true
    # The dialog scratch file briefly holds the typed password — remove it.
    rm -f "$DIALOG_TMP" 2>/dev/null || true
}
trap cleanup EXIT

mount_or_die() {
    _fstype="$1"; _dev="$2"; _mnt="$3"
    mkdir -p "$_mnt"
    mount -t "$_fstype" "$_dev" "$_mnt" && return 0
    die "Failed to mount $_dev at $_mnt as $_fstype"
}
