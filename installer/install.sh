#!/bin/bash
# installer/install.sh — larch-os disk installer
#
# Shipped in the OS image as /usr/sbin/larch-install and launched by
# larch-installer.service on tty1 when the ISO is booted (kernel cmdline carries
# `larch.installer`). It therefore runs in the FULLY BOOTED live system: systemd
# is up and systemd-udevd has already auto-loaded every hardware driver. That is
# the whole point of the design — the installer relies on udev for hardware, so
# the keyboard and target disk work on any machine without a hand-maintained
# kernel-module list.
#
# Asks for:  hostname · username · password · target disk
# Writes to LARCHOS:  vmlinuz · initramfs.img · bootloader · per-machine config
#                     ({hostname,hosts,passwd,shadow,username,fstab})
#
# The OS initramfs that boots the installed disk is REASSEMBLED here, not copied:
# the squashfs (the live root's lower layer) is recovered from its loop device and
# wrapped as a raw cpio, then the prebuilt gzip base image is appended — exactly
# the two-pass early-cpio layout the OS initramfs expects:
#       initramfs.img = raw-cpio(rootfs.squashfs)  ++  initramfs-base.img
# This avoids storing the squashfs twice (once live, once as a payload).
#
# Tools all come from the live system (util-linux, dosfstools, e2fsprogs, openssl,
# cpio, gzip) — no binaries are baked into an initramfs anymore.

set -e

export PATH=/usr/sbin:/sbin:/usr/bin:/bin

# Installer payload baked into the squashfs (see docker-entrypoint.sh stage 6).
PAYLOAD="/usr/lib/larch/payload"
OS_PART_SIZE="3GiB"
TARGET_DISK=""
AUTO_YES=0
MOUNT_OS="/run/larch-target-os"
MOUNT_HOME="/run/larch-target-home"

# User-supplied config (filled by prompt_config)
LARCH_HOSTNAME=""
LARCH_USERNAME=""
LARCH_PASSWORD=""

# ── Helpers ───────────────────────────────────────────────────────────────────

die() {
    echo "" >&2
    echo "ERROR: $*" >&2
    echo "Dropping to a debug shell. Run 'systemctl reboot' when done." >&2
    exec /bin/bash
}
info() { echo "  >> $*"; }
nl()   { echo ""; }

confirm() {
    [ "$AUTO_YES" -eq 1 ] && return 0
    printf "%s [y/N] " "$*"
    read -r ans
    case "$ans" in [yY]) return 0 ;; *) return 1 ;; esac
}

cleanup() {
    umount "$MOUNT_OS"   2>/dev/null || true
    umount "$MOUNT_HOME" 2>/dev/null || true
}
trap cleanup EXIT

# mount_or_die <fstype> <device> <mountpoint>
mount_or_die() {
    _fstype="$1"; _dev="$2"; _mnt="$3"
    mount -t "$_fstype" "$_dev" "$_mnt" && return 0
    die "Failed to mount $_dev at $_mnt as $_fstype"
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET_DISK="$2"; shift 2 ;;
        --yes)    AUTO_YES=1;       shift   ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Must be run as root"

# ── Verify payload + recover the squashfs ─────────────────────────────────────

[ -f "$PAYLOAD/initramfs-base.img" ] || die "OS initramfs base not found in payload ($PAYLOAD/initramfs-base.img)"
[ -f "$PAYLOAD/bootx64.efi" ]        || die "EFI binary not found in payload"
[ -d "$PAYLOAD/loader" ]             || die "Bootloader config not found in payload"

# The live root's lower layer is the squashfs, loop-mounted by the OS initramfs.
# Find that loop device by filesystem type so we can read the raw image back.
SQUASHFS_DEV=""
for _l in /dev/loop*; do
    [ -b "$_l" ] || continue
    if [ "$(blkid -s TYPE -o value "$_l" 2>/dev/null)" = "squashfs" ]; then
        SQUASHFS_DEV="$_l"; break
    fi
done
[ -n "$SQUASHFS_DEV" ] || die "Could not locate the live squashfs loop device (is this the live ISO?)"

# Kernel image to install (the live system's own kernel, from the squashfs /boot).
VMLINUZ="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
[ -f "$VMLINUZ" ] || VMLINUZ="$(readlink -f /boot/vmlinuz 2>/dev/null || true)"
[ -f "$VMLINUZ" ] || die "Kernel image not found under /boot"

# ── Prompt for system configuration ──────────────────────────────────────────

prompt_config() {
    nl
    echo "╔══════════════════════════════════════════════╗"
    echo "  larch-os — System Configuration"
    echo "╚══════════════════════════════════════════════╝"
    nl

    # Hostname
    while true; do
        printf "Hostname: "
        read -r LARCH_HOSTNAME
        case "$LARCH_HOSTNAME" in
            ""|"-"*|*"-")
                echo "  Invalid: cannot be empty or start/end with a hyphen" ;;
            *[!a-zA-Z0-9-]*)
                echo "  Invalid: only letters, numbers, and hyphens allowed" ;;
            *) break ;;
        esac
    done

    # Username
    while true; do
        printf "Username: "
        read -r LARCH_USERNAME
        case "$LARCH_USERNAME" in
            "")
                echo "  Invalid: cannot be empty" ;;
            *[!a-z0-9_-]*)
                echo "  Invalid: only lowercase letters, numbers, underscores, hyphens" ;;
            *) break ;;
        esac
    done

    # Password (hidden, with confirmation)
    while true; do
        printf "Password for %s: " "$LARCH_USERNAME"
        stty -echo 2>/dev/null || true
        read -r LARCH_PASSWORD
        stty echo  2>/dev/null || true
        nl

        printf "Confirm password: "
        stty -echo 2>/dev/null || true
        read -r _pw2
        stty echo  2>/dev/null || true
        nl

        if [ -z "$LARCH_PASSWORD" ]; then
            echo "  Password cannot be empty"
        elif [ "$LARCH_PASSWORD" != "$_pw2" ]; then
            echo "  Passwords do not match — try again"
        else
            break
        fi
    done
}

prompt_config

# ── Pick target disk ──────────────────────────────────────────────────────────

nl
if [ -z "$TARGET_DISK" ]; then
    echo "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v "^loop" | grep -v "^sr" || \
        ls /dev/sd? /dev/vd? /dev/nvme?n? 2>/dev/null || echo "  (could not list disks)"
    nl
    printf "Target disk (e.g. /dev/sda): "
    read -r TARGET_DISK
fi

[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

case "$TARGET_DISK" in
    *nvme*|*mmcblk*) PART1="${TARGET_DISK}p1"; PART2="${TARGET_DISK}p2" ;;
    *)              PART1="${TARGET_DISK}1";  PART2="${TARGET_DISK}2"  ;;
esac

# ── Confirm ───────────────────────────────────────────────────────────────────

nl
echo "╔══════════════════════════════════════════════╗"
echo "  larch-os installer — summary"
echo "╠══════════════════════════════════════════════╣"
printf "  Hostname      : %s\n" "$LARCH_HOSTNAME"
printf "  Username      : %s\n" "$LARCH_USERNAME"
printf "  Target disk   : %s\n" "$TARGET_DISK"
printf "  OS partition  : %s  (FAT32, %s, label LARCHOS)\n" "$PART1" "$OS_PART_SIZE"
printf "  Home partition: %s  (ext4,  rest of disk)\n" "$PART2"
echo ""
echo "  WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED."
echo "╚══════════════════════════════════════════════╝"
nl
confirm "Proceed with installation?" || { echo "Aborted."; exit 0; }

# ── Generate config files ─────────────────────────────────────────────────────

CONFIG_TMP="/run/larch-config"
rm -rf "$CONFIG_TMP"
mkdir -p "$CONFIG_TMP"

info "Generating config files"

# /etc/hostname
printf '%s\n' "$LARCH_HOSTNAME" > "$CONFIG_TMP/hostname"

# /etc/hosts
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
    "$LARCH_HOSTNAME" > "$CONFIG_TMP/hosts"

# /etc/passwd entry (UID 1000)
printf '%s:x:1000:1000:%s:/home/%s:/bin/bash\n' \
    "$LARCH_USERNAME" "$LARCH_USERNAME" "$LARCH_USERNAME" > "$CONFIG_TMP/passwd"

# /etc/shadow entry — hash with SHA-512 via openssl passwd
pw_hash=$(printf '%s' "$LARCH_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null) \
    || die "Password hashing failed (openssl passwd -6 not available)"
today_days=$(( $(date +%s) / 86400 ))
printf '%s:%s:%d:0:99999:7:::\n' "$LARCH_USERNAME" "$pw_hash" "$today_days" \
    > "$CONFIG_TMP/shadow"
chmod 600 "$CONFIG_TMP/shadow"

# username record (read by OS init to rename the user's group)
printf '%s\n' "$LARCH_USERNAME" > "$CONFIG_TMP/username"

# /etc/fstab — mounts LARCHHOME at /home/<username>
printf '# /etc/fstab — larch-os (generated by installer)\n'                    > "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/tmp\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/run\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'LABEL=LARCHHOME\t\t/home/%s\text4\tdefaults,relatime,nofail\t0\t2\n' \
    "$LARCH_USERNAME"                                                          >> "$CONFIG_TMP/fstab"

# ── Partition ─────────────────────────────────────────────────────────────────

info "Creating GPT partition table on $TARGET_DISK"
wipefs -a "$TARGET_DISK" 2>/dev/null || true
printf 'label: gpt\nsize=%s, type=uefi, name=LARCHOS\ntype=linux, name=LARCHHOME\n' \
    "$OS_PART_SIZE" | sfdisk -q "$TARGET_DISK"
partprobe "$TARGET_DISK" 2>/dev/null || true

i=0
while [ $i -lt 15 ]; do [ -b "$PART1" ] && [ -b "$PART2" ] && break; sleep 1; i=$((i+1)); done
[ -b "$PART1" ] || die "Partition $PART1 not found after partitioning"
[ -b "$PART2" ] || die "Partition $PART2 not found after partitioning"

# ── Format PART1 and install OS files ────────────────────────────────────────

info "Formatting OS partition as FAT32 ($PART1)"
mkfs.fat -F 32 -n LARCHOS "$PART1"

mkdir -p "$MOUNT_OS"
mount_or_die vfat "$PART1" "$MOUNT_OS"

info "Installing EFI binary"
mkdir -p "$MOUNT_OS/EFI/BOOT"
cp "$PAYLOAD/bootx64.efi" "$MOUNT_OS/EFI/BOOT/BOOTX64.EFI"

info "Copying bootloader config"
cp -r "$PAYLOAD/loader" "$MOUNT_OS/"

info "Copying kernel"
mkdir -p "$MOUNT_OS/larch-os"
cp "$VMLINUZ" "$MOUNT_OS/larch-os/vmlinuz"

# ── Reassemble the OS initramfs (squashfs + base) directly on the target ──────
# Recover the squashfs from the live root's loop device, wrap it as a raw cpio,
# then append the prebuilt gzip base image. This reproduces the exact two-pass
# layout that docker-entrypoint.sh builds for the live ISO.
info "Recovering OS image and assembling initramfs (a few minutes — large image)"
DEST="$MOUNT_OS/larch-os"
dd if="$SQUASHFS_DEV" of="$DEST/rootfs.squashfs" bs=4M status=none
sync
sqsz=$(stat -c %s "$DEST/rootfs.squashfs")
( cd "$DEST" && echo "./rootfs.squashfs" | cpio --create --format=newc --quiet ) > "$DEST/initramfs.img"
p1sz=$(stat -c %s "$DEST/initramfs.img")
[ "$p1sz" -ge "$sqsz" ] || die "initramfs assembly truncated ($p1sz < $sqsz) — squashfs not embedded"
cat "$PAYLOAD/initramfs-base.img" >> "$DEST/initramfs.img"
rm -f "$DEST/rootfs.squashfs"
sync

info "Writing installation config to LARCHOS"
cp "$CONFIG_TMP/hostname" "$DEST/hostname"
cp "$CONFIG_TMP/hosts"    "$DEST/hosts"
cp "$CONFIG_TMP/passwd"   "$DEST/passwd"
cp "$CONFIG_TMP/shadow"   "$DEST/shadow"
cp "$CONFIG_TMP/username" "$DEST/username"
cp "$CONFIG_TMP/fstab"    "$DEST/fstab"
chmod 640 "$DEST/shadow"

sync
umount "$MOUNT_OS"

info "Formatting home partition as ext4 ($PART2)"
mkfs.ext4 -F -L LARCHHOME -m 1 "$PART2"
sync

# ── Seed home partition ───────────────────────────────────────────────────────

mkdir -p "$MOUNT_HOME"
info "Seeding home partition for $LARCH_USERNAME"
mount_or_die ext4 "$PART2" "$MOUNT_HOME"
# LARCHHOME is mounted directly at /home/<username> at runtime, so seed /etc/skel
# into the partition ROOT — NOT a /<username> subdir.
cp -a /etc/skel/. "$MOUNT_HOME/" 2>/dev/null || true
chown -R 1000:1000 "$MOUNT_HOME"
chown 0:0 "$MOUNT_HOME/lost+found" 2>/dev/null || true
chmod 0750 "$MOUNT_HOME"
sync
umount "$MOUNT_HOME"

trap - EXIT

# ── Done ─────────────────────────────────────────────────────────────────────

nl
echo "╔══════════════════════════════════════════════╗"
echo "  Installation complete!"
echo ""
printf "  Hostname : %s\n" "$LARCH_HOSTNAME"
printf "  User     : %s\n" "$LARCH_USERNAME"
printf "  OS       : %s  (LARCHOS)\n"   "$PART1"
printf "  Home     : %s  (LARCHHOME)\n" "$PART2"
echo ""
echo "  Remove the installation media, then press Enter to reboot."
echo "╚══════════════════════════════════════════════╝"
read -r _
systemctl reboot
