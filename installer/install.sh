#!/bin/sh
# installer/install.sh — larch-os disk installer
#
# Bundled into installer.initramfs as /usr/sbin/larch-install and run by its
# init (installer/initramfs/init). The installer ISO carries no system files:
# this downloads the Larch OS release and desktop the user picks
# (shared/lib/release.sh) and installs it. Flow:
#
#   1. Load the bundled storage/network/input drivers (shared/lib/hw.sh).
#   2. Ask the full name and password (the username is derived from the full
#      name, the hostname as <username>-<brand>-<device type>).
#   3. Get online (wired DHCP, else Wi-Fi) and list the releases, one entry per
#      desktop (larch-gnome-v0.1.5, larch-cosmic-v0.1.5, …), to pick from —
#      before any disk is touched, so no network means nothing is erased.
#   4. Ask the target disk and confirm, then wipe it and create four GPT
#      partitions:
#
#        1. LARCHEFI  (FAT32) — systemd-boot and its entries, larch-os/vmlinuz,
#                               larch-os/sys.initramfs, larch-os/updater.initramfs
#        2. LARCHSYS  (ext4)  — sys.squashfs (the chosen desktop's OS root,
#                               loop-mounted by sys.initramfs), version, desktop
#        3. LARCHCONF (ext4)  — /conf: etc/ + etc-work/, the upper layer of the
#                               /etc overlay, starting with this machine's
#                               hostname, hosts, machine-id and account files;
#                               var/ + var-work/, the upper layer of /var
#        4. LARCHHOME (ext4)  — /home/<username>, seeded from the image's /etc/skel
#
#   5. Download the release onto LARCHSYS, verify it, install it, write the
#      machine config, reboot.
#
# Every run is a clean install. Updates are done by the "Update LARCH" boot
# entry (system/updater/update.sh), which replaces the same files.

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

DIALOG_BT="Larch OS installer"
DIE_TITLE="Installation failed"
. /usr/lib/larch/ui.sh
. /usr/lib/larch/hw.sh
. /usr/lib/larch/net.sh
. /usr/lib/larch/release.sh
. /usr/lib/larch/conf.sh
. /usr/lib/larch/helpers.sh
. /usr/lib/larch/disk.sh
. /usr/lib/larch/config-form.sh

# ── Argument parsing ──────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET_DISK="$2"; shift 2 ;;
        --yes)    AUTO_YES=1;       shift   ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Must be run as root"

# ── Drivers ──────────────────────────────────────────────────────────────────

echo "[larch-install] Loading drivers..." > /dev/console
load_drivers
wait_for_keyboard

# ── Questions, network, release ──────────────────────────────────────────────

form_config
net_up
lookup_releases
choose_release "" "$(default_release)" Reboot

while true; do

[ -n "$TARGET_DISK" ] || pick_disk_dialog
[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

case "$TARGET_DISK" in
    *nvme*|*mmcblk*) _sep=p ;;
    *)               _sep=  ;;
esac
PART1="${TARGET_DISK}${_sep}1"; PART2="${TARGET_DISK}${_sep}2"
PART3="${TARGET_DISK}${_sep}3"; PART4="${TARGET_DISK}${_sep}4"
unset _sep

if [ "$AUTO_YES" -ne 1 ]; then
    _dl=""
    [ "$REL_SIZE" -gt 0 ] && _dl="  ($(( REL_SIZE / 1048576 )) MB download)"
    dialog --colors --yes-label "Install" --no-label "Back" \
        --backtitle "$DIALOG_BT" --title " Confirm Installation " \
        --yesno "\
  Larch OS         : $REL_NAME$_dl
  Full name        : $LARCH_FULLNAME
  Username         : $LARCH_USERNAME
  Hostname         : $LARCH_HOSTNAME
  Target disk      : $TARGET_DISK
  EFI partition    : $PART1  (FAT32, $EFI_PART_SIZE, LARCHEFI)
  System partition : $PART2  (ext4, $SYS_PART_SIZE, LARCHSYS)
  Config partition : $PART3  (ext4, $CONF_PART_SIZE, LARCHCONF)
  Home partition   : $PART4  (ext4, remainder, LARCHHOME)

  \Z1WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED.\Zn" \
        19 72 \
        || { TARGET_DISK=""; continue; }
    clear_screen
fi

break
done

# ── Partition and format ─────────────────────────────────────────────────────

show_step "Unmounting any existing partitions on $TARGET_DISK"
for _p in "${TARGET_DISK}"[0-9]* "${TARGET_DISK}"p[0-9]*; do
    [ -b "$_p" ] && umount "$_p" 2>/dev/null || true
done
unset _p

show_step "Creating GPT partition table on $TARGET_DISK"
wipefs -a "$TARGET_DISK" >/dev/null 2>&1
# The GPT partition names are how sys.initramfs and the updater find them.
printf 'label: gpt\nsize=%s, type=uefi, name=LARCHEFI\nsize=%s, type=linux, name=LARCHSYS\nsize=%s, type=linux, name=LARCHCONF\ntype=linux, name=LARCHHOME\n' \
    "$EFI_PART_SIZE" "$SYS_PART_SIZE" "$CONF_PART_SIZE" | sfdisk -q "$TARGET_DISK" >/dev/null 2>&1 \
    || die "Could not partition $TARGET_DISK."
blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true

i=0
while [ $i -lt 15 ]; do
    [ -b "$PART1" ] && [ -b "$PART2" ] && [ -b "$PART3" ] && [ -b "$PART4" ] && break
    sleep 1; i=$((i+1))
done
for _p in "$PART1" "$PART2" "$PART3" "$PART4"; do
    [ -b "$_p" ] || die "Partition $_p not found after partitioning"
done
unset _p

show_step "Formatting partitions"
mkfs.fat -F 32 -n LARCHEFI "$PART1" >/dev/null 2>&1      || die "Could not format $PART1."
mkfs.ext4 -F -L LARCHSYS  -m 0 "$PART2" >/dev/null 2>&1  || die "Could not format $PART2."
mkfs.ext4 -F -L LARCHCONF -m 0 "$PART3" >/dev/null 2>&1  || die "Could not format $PART3."
mkfs.ext4 -F -L LARCHHOME -m 0 "$PART4" >/dev/null 2>&1  || die "Could not format $PART4."

mount_or_die ext4 "$PART2" "$MOUNT_SYS"
mount_or_die vfat "$PART1" "$MOUNT_EFI"

# ── Download and install the system ──────────────────────────────────────────
# The disk is already wiped, so a failed download offers a retry.

while true; do
    rm -rf "$STAGE"
    download_release "$STAGE" && check_release "$STAGE" && break
    umount "$NEW_MNT" 2>/dev/null || true
    dialog --backtitle "$DIALOG_BT" --title " Download failed " \
        --yes-label "Retry" --no-label "Reboot" \
        --yesno "\n$REL_NAME could not be downloaded and verified.\n\n$TARGET_DISK has already been erased. Retry the download?" 11 70 \
        || do_reboot
done

show_step "Installing $REL_NAME"
mv -f "$STAGE/$SYS_IMG" "$MOUNT_SYS/sys.squashfs" || die "Could not install sys.squashfs."
install_boot_files "$STAGE" "$MOUNT_EFI" || die "Could not install the kernel and bootloader on $PART1."
printf '%s\n' "$NEW_VERSION" > "$MOUNT_SYS/version"
printf '%s\n' "$REL_DESKTOP" > "$MOUNT_SYS/desktop"
rm -rf "$STAGE"
sync
umount "$MOUNT_EFI"

# The image (still mounted at $NEW_MNT by check_release) is where the
# identity files and the account names in use come from, and its /etc/skel
# seeds the home directory.
MOUNT_IMG="$NEW_MNT"

# The release may have system accounts the installer wasn't built with.
cut -d: -f1 "$MOUNT_IMG/etc/passwd" "$MOUNT_IMG/etc/group" | grep -vx larch | sort -u \
    > "$RUN/reserved-names"
RESERVED_NAMES="$RUN/reserved-names"
derive_username
derive_hostname

# ── Machine config ───────────────────────────────────────────────────────────

CONFIG_TMP="$RUN/config"
rm -rf "$CONFIG_TMP"
mkdir -p "$CONFIG_TMP"

show_step "Generating config files"
printf '%s\n' "$LARCH_HOSTNAME" > "$CONFIG_TMP/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
    "$LARCH_HOSTNAME" > "$CONFIG_TMP/hosts"

# GECOS = the full name as typed (GNOME shows it as the display name).
printf '%s:x:1000:1000:%s:/home/%s:/bin/bash\n' \
    "$LARCH_USERNAME" "$LARCH_FULLNAME" "$LARCH_USERNAME" > "$CONFIG_TMP/passwd"

# busybox mkpasswd is statically linked and always available in the initramfs.
# openssl passwd -6 is a fallback (dynamically linked; requires libraries).
pw_hash=$(busybox mkpasswd -m sha512 "$LARCH_PASSWORD" 2>/dev/null) || true
[ -n "$pw_hash" ] || \
    pw_hash=$(printf '%s' "$LARCH_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null) || true
[ -n "$pw_hash" ] || die "Password hashing failed (tried busybox mkpasswd and openssl passwd -6)"
today_days=$(( $(date +%s) / 86400 ))
printf '%s:%s:%d:0:99999:7:::\n' "$LARCH_USERNAME" "$pw_hash" "$today_days" \
    > "$CONFIG_TMP/shadow"
chmod 600 "$CONFIG_TMP/shadow"

# machine-id — generated once at install so the machine keeps a stable identity
# (DHCP lease/IP, DHCPv6 DUID, systemd journal). sys.initramfs mounts the /etc
# overlay before systemd starts, so PID 1 reads it from the upper layer.
# Format: 32 lowercase hex digits (sourced from the kernel UUID pool).
tr -d '-' < /proc/sys/kernel/random/uuid > "$CONFIG_TMP/machine-id"

# ── LARCHCONF: /etc's and /var's upper layers ────────────────────────────────

mount_or_die ext4 "$PART3" "$MOUNT_CONF"

show_step "Writing machine config into the config partition"
# The upper layers of /etc (this machine's identity) and /var (empty).
seed_layers "$MOUNT_IMG" "$CONFIG_TMP" "$LARCH_USERNAME" "$MOUNT_CONF/etc" "$MOUNT_CONF/var"
# overlayfs's workdirs: empty, on the same filesystem as the upper layers.
mkdir -m 0700 "$MOUNT_CONF/etc-work" "$MOUNT_CONF/var-work"
rm -rf "$CONFIG_TMP"

sync
umount "$MOUNT_CONF"

# ── LARCHHOME: the user's home ───────────────────────────────────────────────

mount_or_die ext4 "$PART4" "$MOUNT_HOME"

show_step "Seeding home partition for $LARCH_USERNAME"
# The partition is mounted at /home; seed the user's home into /home/<username>.
mkdir -p "$MOUNT_HOME/$LARCH_USERNAME"
cp -a "$MOUNT_IMG/etc/skel/." "$MOUNT_HOME/$LARCH_USERNAME/" 2>/dev/null || true
chmod -R u+w "$MOUNT_HOME/$LARCH_USERNAME"
chown -R 1000:1000 "$MOUNT_HOME/$LARCH_USERNAME"
chmod 0750 "$MOUNT_HOME/$LARCH_USERNAME"
chown 0:0 "$MOUNT_HOME"
chmod 0755 "$MOUNT_HOME"
chown 0:0 "$MOUNT_HOME/lost+found" 2>/dev/null || true

sync
umount "$MOUNT_HOME"
umount "$MOUNT_IMG"
umount "$MOUNT_SYS"

trap - EXIT
cleanup

# ── Done ─────────────────────────────────────────────────────────────────────

dialog --backtitle "$DIALOG_BT" --title " Installation Complete " \
    --msgbox "\
  $REL_NAME has been installed.

  Name     : $LARCH_FULLNAME
  User     : $LARCH_USERNAME
  Hostname : $LARCH_HOSTNAME
  EFI      : $PART1  (LARCHEFI)
  System   : $PART2  (LARCHSYS)
  Config   : $PART3  (LARCHCONF)
  Home     : $PART4  (LARCHHOME)

  Remove the installation media, then choose OK to reboot." \
    19 60
clear_screen
do_reboot
