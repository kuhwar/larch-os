#!/bin/sh
# installer/install.sh — larch-os disk installer
#
# Runs as PID 1's child in the installer initramfs (see initramfs/installer/init).
# The init mounts the installer USB at /mnt/iso before calling this script, so all
# OS files to be installed are available there:
#   /mnt/iso/larch-os/initramfs.img    — larch OS initramfs (base, no squashfs)
#   /mnt/iso/larch-os/rootfs.squashfs  — OS root filesystem (separate from initramfs)
#   /mnt/iso/larch-os/vmlinuz          — kernel
#   /mnt/iso/EFI/BOOT/BOOTX64.EFI     — systemd-boot
#   /mnt/iso/loader/                   — bootloader config
#
# Picks the target disk first. A disk that already holds a larch-os install is
# marked [Larch OS], listed first and pre-selected; choosing it offers two modes:
#
#   Update (default) — replace the OS payload + bootloader (vmlinuz, initramfs.img,
#     rootfs.squashfs, EFI binary, loader config) in place. The per-machine config
#     files and the LARCHHOME partition are preserved; nothing is reformatted.
#
#   Clean install — the flow below: ask full name · password (the username is
#     derived from the full name, the hostname as <username>-<device type>),
#     then wipe and repartition the disk.
#
# Clean install writes to LARCHOS:
#   vmlinuz · initramfs.img · bootloader · per-machine config
#   (hostname, hosts, username, machine-id, fstab)
# and to LARCHCONF: accounts/passwd · accounts/shadow (root-only)

set -e

export PATH=/usr/sbin:/sbin:/usr/bin:/bin

. /usr/lib/larch/helpers.sh
. /usr/lib/larch/disk.sh
. /usr/lib/larch/config-form.sh
. /usr/lib/larch/update.sh

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

[ -f "$ISO_MOUNT/larch-os/initramfs.img" ]   || die "OS initramfs not found on installer medium ($ISO_MOUNT/larch-os/initramfs.img)"
[ -f "$ISO_MOUNT/larch-os/rootfs.squashfs" ] || die "rootfs.squashfs not found on installer medium ($ISO_MOUNT/larch-os/rootfs.squashfs)"
[ -f "$ISO_MOUNT/larch-os/vmlinuz" ]         || die "Kernel not found on installer medium"
[ -f "$ISO_MOUNT/EFI/BOOT/BOOTX64.EFI" ]    || die "EFI binary not found on installer medium"
[ -d "$ISO_MOUNT/loader" ]                   || die "Bootloader config not found on installer medium"

# ── Main install loop ─────────────────────────────────────────────────────────

while true; do

[ -n "$TARGET_DISK" ] || pick_disk_dialog

[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

case "$TARGET_DISK" in
    *nvme*|*mmcblk*) PART1="${TARGET_DISK}p1"; PART2="${TARGET_DISK}p2"; PART3="${TARGET_DISK}p3" ;;
    *)               PART1="${TARGET_DISK}1";  PART2="${TARGET_DISK}2";  PART3="${TARGET_DISK}3"  ;;
esac

# ── Update vs clean install ───────────────────────────────────────────────────
# If the chosen disk already holds a larch-os install, offer an in-place update
# (replace the OS payload + bootloader, keep config files and the home partition)
# as the default. Otherwise, fall through to a clean install.

LARCHOS_PART=""
_disk_name=$(basename "$TARGET_DISK")
LARCHOS_PART=$(find_larchos_part "$_disk_name" || true)

# --yes means a non-interactive clean install; don't pop the update menu there.
if [ -n "$LARCHOS_PART" ] && [ "$AUTO_YES" -ne 1 ]; then
    while true; do
        : > "$DIALOG_TMP"
        dialog --no-cancel --default-item update \
            --backtitle "$DIALOG_BT" --title " Existing larch-os Detected " \
            --menu "An existing larch-os installation was found on $TARGET_DISK ($LARCHOS_PART).\n\nChoose how to proceed:" \
            14 72 2 \
            update "Update — replace OS image, keep account, settings & home" \
            clean  "Clean install — ERASE the whole disk and set up anew" \
            2>"$DIALOG_TMP"
        if [ $? -eq 0 ]; then
            break
        fi
        # ESC: re-show
    done
    if [ "$(cat "$DIALOG_TMP")" = "update" ]; then
        if ! do_update "$LARCHOS_PART"; then
            TARGET_DISK=""
            continue
        fi
    fi
fi

# ── Clean install ─────────────────────────────────────────────────────────────
# From here on is the fresh-install path: collect config, then wipe + partition.

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
  OS partition     : $PART1  (FAT32, $OS_PART_SIZE, LARCHOS)
  Config partition : $PART2  (ext4, $CONF_PART_SIZE, LARCHCONF)
  Home partition   : $PART3  (ext4, remainder, LARCHHOME)

  \Z1WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED.\Zn" \
        17 70 \
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

printf '%s\n' "$LARCH_USERNAME" > "$CONFIG_TMP/username"

# machine-id — generated once at install so the machine keeps a stable identity
# (DHCP lease/IP, DHCPv6 DUID, systemd journal) across reboots. /etc is tmpfs on
# the installed system, so without a persisted value systemd would synthesise a
# fresh id every boot. The OS init re-applies this into /etc/machine-id.
# Format: 32 lowercase hex digits + newline (sourced from the kernel UUID pool).
tr -d '-' < /proc/sys/kernel/random/uuid > "$CONFIG_TMP/machine-id"

printf '# /etc/fstab — larch-os (generated by installer)\n'                    > "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/tmp\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/run\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
# LARCHCONF: persistent, root-owned system config (NM connections, Bluetooth
# device store, CUPS printer state)
printf 'LABEL=LARCHCONF\t\t/etc/larch-conf\text4\tdefaults,relatime,nofail\t0\t2\n' \
                                                                               >> "$CONFIG_TMP/fstab"
# LARCHHOME is mounted at /home; the user's home directory lives at
# /home/<username> inside that partition (seeded below from /etc/skel).
printf 'LABEL=LARCHHOME\t\t/home\t\text4\tdefaults,relatime,nofail\t0\t2\n' \
                                                                               >> "$CONFIG_TMP/fstab"
# Persist NetworkManager system connections on LARCHCONF.
# fstab-generator orders this bind after the /etc/larch-conf mount;
# NetworkManager.service waits for it via a RequiresMountsFor drop-in in the rootfs overlay.
printf '/etc/larch-conf/nm-system-connections\t/etc/NetworkManager/system-connections\tnone\tbind,nofail\t0\t0\n' \
                                                                               >> "$CONFIG_TMP/fstab"
# Persist Bluetooth paired-device data on LARCHCONF. x-systemd.mkdir creates
# /var/lib/bluetooth if bluez hasn't already; bluetooth.service waits for the
# mount via a RequiresMountsFor drop-in in the rootfs overlay.
printf '/etc/larch-conf/bluetooth\t\t/var/lib/bluetooth\tnone\tbind,nofail,x-systemd.mkdir\t0\t0\n' \
                                                                               >> "$CONFIG_TMP/fstab"
# Persist CUPS printer queue state on LARCHCONF. setup-chroot.sh symlinks
# printers.conf/classes.conf/subscriptions.conf/ppd into /etc/cups/larch-state
# so only queue state (not cupsd.conf etc.) is redirected here; x-systemd.mkdir
# creates the mount point, cups.service waits for it via a RequiresMountsFor
# drop-in in the rootfs overlay.
printf '/etc/larch-conf/cups\t\t\t/etc/cups/larch-state\tnone\tbind,nofail,x-systemd.mkdir\t0\t0\n' \
                                                                               >> "$CONFIG_TMP/fstab"

# ── Partition ─────────────────────────────────────────────────────────────────

show_step "Unmounting any existing partitions on $TARGET_DISK"
for _p in "${TARGET_DISK}"[0-9]* "${TARGET_DISK}"p[0-9]*; do
    [ -b "$_p" ] && umount "$_p" 2>/dev/null || true
done
unset _p

show_step "Creating GPT partition table on $TARGET_DISK"
wipefs -a "$TARGET_DISK" >/dev/null 2>&1
printf 'label: gpt\nsize=%s, type=uefi, name=LARCHOS\nsize=%s, type=linux, name=LARCHCONF\ntype=linux, name=LARCHHOME\n' \
    "$OS_PART_SIZE" "$CONF_PART_SIZE" | sfdisk -q "$TARGET_DISK" >/dev/null 2>&1
blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true

i=0
while [ $i -lt 15 ]; do [ -b "$PART1" ] && [ -b "$PART2" ] && [ -b "$PART3" ] && break; sleep 1; i=$((i+1)); done
[ -b "$PART1" ] || die "Partition $PART1 not found after partitioning"
[ -b "$PART2" ] || die "Partition $PART2 not found after partitioning"
[ -b "$PART3" ] || die "Partition $PART3 not found after partitioning"

# ── Format PART1 and install OS files ────────────────────────────────────────

show_step "Formatting OS partition as FAT32 ($PART1)"
mkfs.fat -F 32 -n LARCHOS "$PART1" >/dev/null 2>&1

mkdir -p "$MOUNT_OS"
mount_or_die vfat "$PART1" "$MOUNT_OS"

show_step "Installing EFI binary"
mkdir -p "$MOUNT_OS/EFI/BOOT"
cp "$ISO_MOUNT/EFI/BOOT/BOOTX64.EFI" "$MOUNT_OS/EFI/BOOT/BOOTX64.EFI"

show_step "Copying bootloader config"
cp -r "$ISO_MOUNT/loader" "$MOUNT_OS/"

show_step "Copying kernel and OS initramfs"
mkdir -p "$MOUNT_OS/larch-os"
cp "$ISO_MOUNT/larch-os/vmlinuz"       "$MOUNT_OS/larch-os/vmlinuz"
cp "$ISO_MOUNT/larch-os/initramfs.img" "$MOUNT_OS/larch-os/initramfs.img"
sync

show_step "Copying OS squashfs (this may take a minute)"
cp "$ISO_MOUNT/larch-os/rootfs.squashfs" "$MOUNT_OS/larch-os/rootfs.squashfs"
sync

show_step "Writing installation config to LARCHOS"
DEST="$MOUNT_OS/larch-os"
cp "$CONFIG_TMP/hostname"   "$DEST/hostname"
cp "$CONFIG_TMP/hosts"      "$DEST/hosts"
cp "$CONFIG_TMP/username"   "$DEST/username"
cp "$CONFIG_TMP/machine-id" "$DEST/machine-id"
cp "$CONFIG_TMP/fstab"      "$DEST/fstab"
# passwd/shadow go to LARCHCONF below — FAT32 can't make the hash root-only.

sync
umount "$MOUNT_OS"

# ── Format and seed config partition ─────────────────────────────────────────

mkdir -p "$MOUNT_CONF"

show_step "Formatting config partition as ext4 ($PART2)"
mkfs.ext4 -F -L LARCHCONF -m 0 "$PART2" >/dev/null 2>&1

mount_or_die ext4 "$PART2" "$MOUNT_CONF"

show_step "Seeding config partition"
# Account files: the OS init reads them at boot, larch-persist-accounts.path
# writes password changes back. shadow is root-only, unlike on FAT32 LARCHOS.
seed_accounts "$MOUNT_CONF" "$CONFIG_TMP/passwd" "$CONFIG_TMP/shadow"

# Root-owned 0700 so WiFi secrets are unreadable/undeletable by the user.
mkdir -p "$MOUNT_CONF/nm-system-connections"
chown 0:0 "$MOUNT_CONF/nm-system-connections"
chmod 0700 "$MOUNT_CONF/nm-system-connections"

# Same posture for Bluetooth pairing keys and CUPS printer queue state.
mkdir -p "$MOUNT_CONF/bluetooth"
chown 0:0 "$MOUNT_CONF/bluetooth"
chmod 0700 "$MOUNT_CONF/bluetooth"

mkdir -p "$MOUNT_CONF/cups"
chown 0:0 "$MOUNT_CONF/cups"
chmod 0700 "$MOUNT_CONF/cups"
# /etc/cups/ppd is a symlink into this directory (see setup-chroot.sh); the
# cups-daemon package normally ships that directory pre-created, so it must
# exist here too or cupsd fails to save new printers' PPDs (server-error-
# internal-error) on a fresh install.
mkdir -p "$MOUNT_CONF/cups/ppd"
chown 0:0 "$MOUNT_CONF/cups/ppd"
chmod 0700 "$MOUNT_CONF/cups/ppd"

sync
umount "$MOUNT_CONF"

# ── Format and seed home partition ───────────────────────────────────────────

mkdir -p "$MOUNT_HOME"

show_step "Formatting home partition as ext4 ($PART3)"
mkfs.ext4 -F -L LARCHHOME -m 0 "$PART3" >/dev/null 2>&1

mount_or_die ext4 "$PART3" "$MOUNT_HOME"

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
  OS       : $PART1  (LARCHOS)
  Config   : $PART2  (LARCHCONF)
  Home     : $PART3  (LARCHHOME)

  Remove the installation media, then choose OK to reboot." \
    17 60
clear_screen
umount /mnt/iso 2>/dev/null || true
do_reboot
