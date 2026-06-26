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
# Asks for:  hostname · username · password · target disk
# Writes to LARCHOS:  vmlinuz · initramfs.img · bootloader · per-machine config
#                     (hostname, hosts, passwd, shadow, username, fstab)

set -e

export PATH=/usr/sbin:/sbin:/usr/bin:/bin

ISO_MOUNT="/mnt/iso"
OS_PART_SIZE="3GiB"
TARGET_DISK=""
AUTO_YES=0
MOUNT_OS="/run/larch-target-os"
MOUNT_HOME="/run/larch-target-home"

LARCH_HOSTNAME=""
LARCH_USERNAME=""
LARCH_PASSWORD=""

# ── Helpers ───────────────────────────────────────────────────────────────────

die() {
    echo "" >&2
    echo "ERROR: $*" >&2
    echo "Dropping to a debug shell. Type 'reboot' when done." >&2
    exec sh < /dev/console > /dev/console 2>&1
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

# ── Verify installer medium ───────────────────────────────────────────────────

[ -f "$ISO_MOUNT/larch-os/initramfs.img" ]   || die "OS initramfs not found on installer medium ($ISO_MOUNT/larch-os/initramfs.img)"
[ -f "$ISO_MOUNT/larch-os/rootfs.squashfs" ] || die "rootfs.squashfs not found on installer medium ($ISO_MOUNT/larch-os/rootfs.squashfs)"
[ -f "$ISO_MOUNT/larch-os/vmlinuz" ]         || die "Kernel not found on installer medium"
[ -f "$ISO_MOUNT/EFI/BOOT/BOOTX64.EFI" ]    || die "EFI binary not found on installer medium"
[ -d "$ISO_MOUNT/loader" ]                   || die "Bootloader config not found on installer medium"

# ── Prompt for system configuration ──────────────────────────────────────────

prompt_config() {
    nl
    echo "╔══════════════════════════════════════════════╗"
    echo "  larch-os — System Configuration"
    echo "╚══════════════════════════════════════════════╝"
    nl

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

list_disks() {
    # One device per line: full device path · total capacity · model/description.
    _found=0
    for _sys in /sys/block/*; do
        _name=$(basename "$_sys")
        case "$_name" in
            loop*|sr*|ram*|fd*|dm-*|md*) continue ;;
        esac
        [ -b "/dev/$_name" ] || continue

        # Total capacity in bytes (512-byte sectors), rendered human-readable.
        _sectors=$(cat "$_sys/size" 2>/dev/null || echo 0)
        _size=$(human_size $(( _sectors * 512 )))

        # Device name/definition: vendor + model, falling back to model alone.
        _vendor=$(cat "$_sys/device/vendor" 2>/dev/null || echo "")
        _model=$(cat "$_sys/device/model" 2>/dev/null || echo "")
        _desc=$(echo "$_vendor $_model" | sed 's/^ *//;s/ *$//;s/  */ /g')
        [ -n "$_desc" ] || _desc="(unknown device)"

        printf "  %-14s %10s   %s\n" "/dev/$_name" "$_size" "$_desc"
        _found=1
    done
    [ "$_found" -eq 1 ] || echo "  (could not list disks)"
}

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

nl
if [ -z "$TARGET_DISK" ]; then
    echo "Available disks:"
    list_disks
    nl
    printf "Target disk (e.g. /dev/sda): "
    read -r TARGET_DISK
fi

[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

case "$TARGET_DISK" in
    *nvme*|*mmcblk*) PART1="${TARGET_DISK}p1"; PART2="${TARGET_DISK}p2" ;;
    *)               PART1="${TARGET_DISK}1";  PART2="${TARGET_DISK}2"  ;;
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

printf '%s\n' "$LARCH_HOSTNAME" > "$CONFIG_TMP/hostname"

printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
    "$LARCH_HOSTNAME" > "$CONFIG_TMP/hosts"

printf '%s:x:1000:1000:%s:/home/%s:/bin/bash\n' \
    "$LARCH_USERNAME" "$LARCH_USERNAME" "$LARCH_USERNAME" > "$CONFIG_TMP/passwd"

# busybox mkpasswd is statically linked and always available in the initramfs.
# openssl passwd -6 is a fallback (dynamically linked; requires libraries).
pw_hash=$(busybox mkpasswd -m sha-512 "$LARCH_PASSWORD" 2>/dev/null) || true
[ -n "$pw_hash" ] || \
    pw_hash=$(printf '%s' "$LARCH_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null) || true
[ -n "$pw_hash" ] || die "Password hashing failed (tried busybox mkpasswd and openssl passwd -6)"
today_days=$(( $(date +%s) / 86400 ))
printf '%s:%s:%d:0:99999:7:::\n' "$LARCH_USERNAME" "$pw_hash" "$today_days" \
    > "$CONFIG_TMP/shadow"
chmod 600 "$CONFIG_TMP/shadow"

printf '%s\n' "$LARCH_USERNAME" > "$CONFIG_TMP/username"

printf '# /etc/fstab — larch-os (generated by installer)\n'                    > "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/tmp\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/run\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'LABEL=LARCHHOME\t\t/home/%s\text4\tdefaults,relatime,nofail\t0\t2\n' \
    "$LARCH_USERNAME"                                                          >> "$CONFIG_TMP/fstab"

# ── Partition ─────────────────────────────────────────────────────────────────

info "Unmounting any existing partitions on $TARGET_DISK"
for _p in "${TARGET_DISK}"[0-9]* "${TARGET_DISK}"p[0-9]*; do
    [ -b "$_p" ] && umount "$_p" 2>/dev/null || true
done
unset _p

info "Creating GPT partition table on $TARGET_DISK"
wipefs -a "$TARGET_DISK"
printf 'label: gpt\nsize=%s, type=uefi, name=LARCHOS\ntype=linux, name=LARCHHOME\n' \
    "$OS_PART_SIZE" | sfdisk -q "$TARGET_DISK"
blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true

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
cp "$ISO_MOUNT/EFI/BOOT/BOOTX64.EFI" "$MOUNT_OS/EFI/BOOT/BOOTX64.EFI"

info "Copying bootloader config"
cp -r "$ISO_MOUNT/loader" "$MOUNT_OS/"

info "Copying kernel and OS initramfs"
mkdir -p "$MOUNT_OS/larch-os"
cp "$ISO_MOUNT/larch-os/vmlinuz"       "$MOUNT_OS/larch-os/vmlinuz"
cp "$ISO_MOUNT/larch-os/initramfs.img" "$MOUNT_OS/larch-os/initramfs.img"
sync

info "Copying OS squashfs (this may take a minute)"
cp "$ISO_MOUNT/larch-os/rootfs.squashfs" "$MOUNT_OS/larch-os/rootfs.squashfs"
sync

info "Writing installation config to LARCHOS"
DEST="$MOUNT_OS/larch-os"
cp "$CONFIG_TMP/hostname" "$DEST/hostname"
cp "$CONFIG_TMP/hosts"    "$DEST/hosts"
cp "$CONFIG_TMP/passwd"   "$DEST/passwd"
cp "$CONFIG_TMP/shadow"   "$DEST/shadow"
cp "$CONFIG_TMP/username" "$DEST/username"
cp "$CONFIG_TMP/fstab"    "$DEST/fstab"
chmod 640 "$DEST/shadow"

sync
umount "$MOUNT_OS"

# ── Format and seed home partition ───────────────────────────────────────────

mkdir -p "$MOUNT_HOME"

info "Formatting home partition as ext4 ($PART2)"
mkfs.ext4 -F -L LARCHHOME -m 0 "$PART2"

mount_or_die ext4 "$PART2" "$MOUNT_HOME"

info "Seeding home partition for $LARCH_USERNAME"
cp -a /mnt/iso/skel/. "$MOUNT_HOME/" 2>/dev/null || true
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
umount /mnt/iso 2>/dev/null || true
reboot
