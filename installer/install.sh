#!/bin/sh
# installer/install.sh — larch-os disk installer
#
# Runs inside the installer initramfs (exec'd by /init). The entire OS payload
# (kernel, OS initramfs, EFI binary, loader config) is baked into the initramfs
# at /payload, so there is no ISO to mount — the source files are already in RAM.
#
# Asks for:  hostname · username · password · target disk
# Creates:   /larch-os/{hostname,hosts,passwd,shadow,username} on LARCHOS
# The OS initramfs reads these on every boot and merges them into the overlayfs.
#
# Tools used (all in the fat installer initramfs):
#   sfdisk       — GPT partitioning     (busybox)
#   mkdosfs      — FAT32 formatting     (busybox)
#   mke2fs       — ext4 formatting      (copied from rootfs with libs)
#   openssl passwd  — password hashing   (copied from rootfs with libs)
#   cp/mount/sync/reboot                (busybox)

set -e

# Busybox ash default PATH is /bin:/usr/bin only; our copied binaries live in
# /usr/sbin and /sbin.  Set explicitly so all tools are reachable.
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

# OS payload baked into this initramfs (see docker-entrypoint.sh stage 7).
SRC="/payload"
OS_PART_SIZE="3GiB"
TARGET_DISK=""
AUTO_YES=0
MOUNT_OS="/mnt/target-os"
MOUNT_HOME="/mnt/target-home"

# User-supplied config (filled by prompt_config)
LARCH_HOSTNAME=""
LARCH_USERNAME=""
LARCH_PASSWORD=""

# ── Helpers ───────────────────────────────────────────────────────────────────

die() {
    echo "" >&2
    echo "ERROR: $*" >&2
    echo "Dropping to debug shell. Run 'reboot -f' when done." >&2
    exec sh
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
# busybox `mount` without an explicit -t relies on probing /proc/filesystems,
# which is unreliable for freshly-formatted partitions — always pass the type.
mount_or_die() {
    _fstype="$1"; _dev="$2"; _mnt="$3"
    mount -t "$_fstype" "$_dev" "$_mnt" && return 0
    info "Kernel filesystems available: $(tr '\n' ' ' < /proc/filesystems)"
    die "Failed to mount $_dev at $_mnt as $_fstype — is the '$_fstype' kernel module loaded? (check the '[mod]' lines above for SKIP)"
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

# ── Verify baked-in payload ───────────────────────────────────────────────────

[ -f "$SRC/vmlinuz" ]                || die "vmlinuz not found in payload"
[ -f "$SRC/larch-os/initramfs.img" ] || die "OS initramfs not found in payload"
[ -f "$SRC/larch-os/bootx64.efi" ]   || die "EFI binary not found in payload"
[ -d "$SRC/larch-os/loader" ]        || die "Bootloader config not found in payload"

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
    *nvme*) PART1="${TARGET_DISK}p1"; PART2="${TARGET_DISK}p2" ;;
    *)      PART1="${TARGET_DISK}1";  PART2="${TARGET_DISK}2"  ;;
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

CONFIG_TMP="/tmp/larch-config"
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
today_days=$(( $(busybox date +%s) / 86400 ))
printf '%s:%s:%d:0:99999:7:::\n' "$LARCH_USERNAME" "$pw_hash" "$today_days" \
    > "$CONFIG_TMP/shadow"
chmod 600 "$CONFIG_TMP/shadow"

# username record (read by OS init to rename the user's group)
printf '%s\n' "$LARCH_USERNAME" > "$CONFIG_TMP/username"

# /etc/fstab — mounts LARCHHOME at /home/<username>
# tmpfs entries mirror the squashfs base fstab; LARCHHOME uses nofail so a
# missing partition (should never happen on installed systems) does not hang boot.
printf '# /etc/fstab — larch-os (generated by installer)\n'                    > "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/tmp\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/run\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'LABEL=LARCHHOME\t\t/home/%s\text4\tdefaults,relatime,nofail\t0\t2\n' \
    "$LARCH_USERNAME"                                                          >> "$CONFIG_TMP/fstab"

# ── Partition ─────────────────────────────────────────────────────────────────

info "Creating GPT partition table on $TARGET_DISK"
printf 'label: gpt\nsize=%s, type=uefi, name=LARCHOS\ntype=linux, name=LARCHHOME\n' \
    "$OS_PART_SIZE" | /usr/sbin/sfdisk -q "$TARGET_DISK"

i=0
while [ $i -lt 15 ]; do [ -b "$PART1" ] && [ -b "$PART2" ] && break; sleep 1; i=$((i+1)); done
[ -b "$PART1" ] || die "Partition $PART1 not found after partitioning"
[ -b "$PART2" ] || die "Partition $PART2 not found after partitioning"

# ── Format PART1 and install OS files ────────────────────────────────────────

info "Formatting OS partition as FAT32 ($PART1)"
/usr/sbin/mkdosfs -F 32 -n LARCHOS "$PART1"

mkdir -p "$MOUNT_OS"
mount_or_die vfat "$PART1" "$MOUNT_OS"

info "Installing EFI binary"
mkdir -p "$MOUNT_OS/EFI/BOOT"
cp "$SRC/larch-os/bootx64.efi" "$MOUNT_OS/EFI/BOOT/BOOTX64.EFI"

info "Copying bootloader config"
cp -r "$SRC/larch-os/loader" "$MOUNT_OS/"

info "Copying kernel"
mkdir -p "$MOUNT_OS/larch-os"
cp "$SRC/vmlinuz" "$MOUNT_OS/larch-os/vmlinuz"

info "Copying OS initramfs (this may take a few minutes — fat image)"
cp "$SRC/larch-os/initramfs.img" "$MOUNT_OS/larch-os/initramfs.img"

info "Writing installation config to LARCHOS"
cp "$CONFIG_TMP/hostname" "$MOUNT_OS/larch-os/hostname"
cp "$CONFIG_TMP/hosts"    "$MOUNT_OS/larch-os/hosts"
cp "$CONFIG_TMP/passwd"   "$MOUNT_OS/larch-os/passwd"
cp "$CONFIG_TMP/shadow"   "$MOUNT_OS/larch-os/shadow"
cp "$CONFIG_TMP/username" "$MOUNT_OS/larch-os/username"
cp "$CONFIG_TMP/fstab"    "$MOUNT_OS/larch-os/fstab"
chmod 640 "$MOUNT_OS/larch-os/shadow"

sync
umount "$MOUNT_OS"

info "Formatting home partition as ext4 ($PART2)"
/usr/sbin/mke2fs -t ext4 -L LARCHHOME -m 1 "$PART2"
sync

# ── Seed home partition ───────────────────────────────────────────────────────

mkdir -p "$MOUNT_HOME"
info "Seeding home partition for $LARCH_USERNAME"
mount_or_die ext4 "$PART2" "$MOUNT_HOME"
# LARCHHOME is mounted directly at /home/<username> at runtime, so seed /etc/skel
# into the partition ROOT — NOT a /<username> subdir, which would surface as the
# nested /home/<username>/<username>.
cp -a /etc/skel/. "$MOUNT_HOME/" 2>/dev/null || true
chown -R 1000:1000 "$MOUNT_HOME"
# Keep lost+found owned by root so fsck is happy; the home root itself is the user's.
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
reboot -f
