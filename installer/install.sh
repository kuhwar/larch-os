#!/bin/sh
# installer/install.sh — larch-os disk installer
#
# Runs as PID 1's child in the installer initramfs (see initramfs/installer/init).
# The init mounts the installer USB at /mnt/iso before calling this script, so all
# OS files to be installed are available there:
#   /mnt/iso/larch-os/rootfs.squashfs  — OS root filesystem (unpacked onto LARCHSYS)
#   /mnt/iso/larch-os/vmlinuz          — kernel (root-mount drivers built in)
#   /mnt/iso/EFI/BOOT/BOOTX64.EFI     — systemd-boot
#   /mnt/iso/loader/                   — bootloader config
#
# Asks full name · password (the username is derived from the full name, the
# hostname as <username>-<brand>-<device type>) and the target disk, then wipes
# it and creates four partitions:
#
#   1. LARCHEFI  (FAT32) — systemd-boot, loader config, vmlinuz. No initramfs:
#                          the kernel mounts LARCHSYS itself.
#   2. LARCHSYS  (ext4)  — the OS, unpacked from rootfs.squashfs, with this
#                          machine's config written straight into its /etc
#                          (hostname, hosts, machine-id, user account). Mounted
#                          read-only at boot.
#   3. LARCHCONF (ext4)  — /etc/larch-conf: a copy of the image's /var
#                          (bind-mounted over /var), the /etc stores from the
#                          ISO's larchconf-seed/, and accounts/passwd·shadow.
#   4. LARCHHOME (ext4)  — /home/<username>, seeded from /etc/skel.
#
# There is no in-place update on this layout yet: every run is a clean install.

set -e

export PATH=/usr/sbin:/sbin:/usr/bin:/bin

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

# ── Verify installer medium ───────────────────────────────────────────────────

[ -f "$ISO_MOUNT/larch-os/rootfs.squashfs" ] || die "rootfs.squashfs not found on installer medium ($ISO_MOUNT/larch-os/rootfs.squashfs)"
[ -f "$ISO_MOUNT/larch-os/vmlinuz" ]         || die "Kernel not found on installer medium"
[ -f "$ISO_MOUNT/EFI/BOOT/BOOTX64.EFI" ]    || die "EFI binary not found on installer medium"
[ -d "$ISO_MOUNT/loader" ]                   || die "Bootloader config not found on installer medium"
command -v unsquashfs >/dev/null 2>&1        || die "unsquashfs not found in installer initramfs"

# ── Main install loop ─────────────────────────────────────────────────────────

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

form_config

# ── Confirm ───────────────────────────────────────────────────────────────────

if [ "$AUTO_YES" -ne 1 ]; then
    dialog --colors --yes-label "Install" --no-label "Cancel" \
        --backtitle "$DIALOG_BT" --title " Confirm Installation " \
        --yesno "\
  Full name        : $LARCH_FULLNAME
  Username         : $LARCH_USERNAME
  Hostname         : $LARCH_HOSTNAME
  Target disk      : $TARGET_DISK
  EFI partition    : $PART1  (FAT32, $EFI_PART_SIZE, LARCHEFI)
  System partition : $PART2  (ext4, $SYS_PART_SIZE, LARCHSYS)
  Config partition : $PART3  (ext4, $CONF_PART_SIZE, LARCHCONF)
  Home partition   : $PART4  (ext4, remainder, LARCHHOME)

  \Z1WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED.\Zn" \
        18 70 \
        || { TARGET_DISK=""; continue; }
    clear_screen
fi

break
done

# ── Generate config files ─────────────────────────────────────────────────────

CONFIG_TMP="/run/larch-config"
rm -rf "$CONFIG_TMP"
mkdir -p "$CONFIG_TMP"

INSTALL_STEPS=""
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
# (DHCP lease/IP, DHCPv6 DUID, systemd journal). Written into LARCHSYS's /etc,
# which is read-only at runtime, so it never changes after install.
# Format: 32 lowercase hex digits + newline (sourced from the kernel UUID pool).
tr -d '-' < /proc/sys/kernel/random/uuid > "$CONFIG_TMP/machine-id"

# ── Partition ─────────────────────────────────────────────────────────────────

show_step "Unmounting any existing partitions on $TARGET_DISK"
for _p in "${TARGET_DISK}"[0-9]* "${TARGET_DISK}"p[0-9]*; do
    [ -b "$_p" ] && umount "$_p" 2>/dev/null || true
done
unset _p

show_step "Creating GPT partition table on $TARGET_DISK"
wipefs -a "$TARGET_DISK" >/dev/null 2>&1
# GPT partition names double as the kernel's root=PARTLABEL=LARCHSYS.
printf 'label: gpt\nsize=%s, type=uefi, name=LARCHEFI\nsize=%s, type=linux, name=LARCHSYS\nsize=%s, type=linux, name=LARCHCONF\ntype=linux, name=LARCHHOME\n' \
    "$EFI_PART_SIZE" "$SYS_PART_SIZE" "$CONF_PART_SIZE" | sfdisk -q "$TARGET_DISK" >/dev/null 2>&1
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

# ── LARCHSYS: unpack the OS and write this machine's config ──────────────────

show_step "Formatting system partition as ext4 ($PART2)"
mkfs.ext4 -F -L LARCHSYS "$PART2" >/dev/null 2>&1

mkdir -p "$MOUNT_SYS"
mount_or_die ext4 "$PART2" "$MOUNT_SYS"

show_step "Unpacking the OS (this takes a few minutes)"
# unsquashfs keeps owners, modes, setuid bits and xattrs (file capabilities).
unsquashfs -f -no-progress -d "$MOUNT_SYS" "$ISO_MOUNT/larch-os/rootfs.squashfs" >/dev/null \
    || die "Failed to unpack rootfs.squashfs onto $PART2"

show_step "Writing machine config into the system partition"
apply_machine_config "$MOUNT_SYS" "$CONFIG_TMP" "$LARCH_USERNAME"

# ── LARCHCONF: /var and the /etc stores ──────────────────────────────────────

mkdir -p "$MOUNT_CONF"

show_step "Formatting config partition as ext4 ($PART3)"
mkfs.ext4 -F -L LARCHCONF -m 0 "$PART3" >/dev/null 2>&1

mount_or_die ext4 "$PART3" "$MOUNT_CONF"

show_step "Seeding config partition"
# /var is bind-mounted from here over the read-only root's /var.
cp -a "$MOUNT_SYS/var" "$MOUNT_CONF/var"
# Account files: a copy for larch-persist-accounts; the system reads the ones
# written into LARCHSYS's /etc above.
seed_accounts "$MOUNT_CONF" "$CONFIG_TMP/passwd" "$CONFIG_TMP/shadow"
# Bind-mount sources for /etc paths in /etc/fstab (NM connections, CUPS).
seed_larchconf "$MOUNT_CONF"

sync
umount "$MOUNT_CONF"
umount "$MOUNT_SYS"

# ── LARCHEFI: bootloader + kernel ────────────────────────────────────────────

show_step "Formatting EFI partition as FAT32 ($PART1)"
mkfs.fat -F 32 -n LARCHEFI "$PART1" >/dev/null 2>&1

mkdir -p "$MOUNT_EFI"
mount_or_die vfat "$PART1" "$MOUNT_EFI"

show_step "Installing bootloader and kernel"
mkdir -p "$MOUNT_EFI/EFI/BOOT" "$MOUNT_EFI/larch-os"
cp "$ISO_MOUNT/EFI/BOOT/BOOTX64.EFI" "$MOUNT_EFI/EFI/BOOT/BOOTX64.EFI"
cp -r "$ISO_MOUNT/loader" "$MOUNT_EFI/"
cp "$ISO_MOUNT/larch-os/vmlinuz" "$MOUNT_EFI/larch-os/vmlinuz"

sync
umount "$MOUNT_EFI"

# ── LARCHHOME: the user's home ───────────────────────────────────────────────

mkdir -p "$MOUNT_HOME"

show_step "Formatting home partition as ext4 ($PART4)"
mkfs.ext4 -F -L LARCHHOME -m 0 "$PART4" >/dev/null 2>&1

mount_or_die ext4 "$PART4" "$MOUNT_HOME"

show_step "Seeding home partition for $LARCH_USERNAME"
# The partition is mounted at /home; seed the user's home into /home/<username>.
mkdir -p "$MOUNT_HOME/$LARCH_USERNAME"
cp -a /mnt/iso/skel/. "$MOUNT_HOME/$LARCH_USERNAME/" 2>/dev/null || true
# ISO9660 files are read-only (0444); cp -a carries that over, so restore
# owner-write on the seeded dotfiles.
chmod -R u+w "$MOUNT_HOME/$LARCH_USERNAME"
chown -R 1000:1000 "$MOUNT_HOME/$LARCH_USERNAME"
chmod 0750 "$MOUNT_HOME/$LARCH_USERNAME"
chown 0:0 "$MOUNT_HOME"
chmod 0755 "$MOUNT_HOME"
chown 0:0 "$MOUNT_HOME/lost+found" 2>/dev/null || true

sync
umount "$MOUNT_HOME"

trap - EXIT

# ── Done ─────────────────────────────────────────────────────────────────────

dialog --backtitle "$DIALOG_BT" --title " Installation Complete " \
    --msgbox "\
  larch-os has been installed successfully.

  Name     : $LARCH_FULLNAME
  User     : $LARCH_USERNAME
  Hostname : $LARCH_HOSTNAME
  EFI      : $PART1  (LARCHEFI)
  System   : $PART2  (LARCHSYS)
  Config   : $PART3  (LARCHCONF)
  Home     : $PART4  (LARCHHOME)

  Remove the installation media, then choose OK to reboot." \
    18 60
clear_screen
umount /mnt/iso 2>/dev/null || true
do_reboot
