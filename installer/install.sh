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
#   Clean install — the flow below: ask hostname · username · password, then wipe
#     and repartition the disk.
#
# Clean install writes to LARCHOS:
#   vmlinuz · initramfs.img · bootloader · per-machine config
#   (hostname, hosts, passwd, shadow, username, machine-id, fstab)

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

# Wipe the screen (used to clear dialog's drawing before/after plain output).
clear_screen() { printf '\033[2J\033[3J\033[H'; }

# Accumulate step messages and show them inside a dialog infobox so installation
# progress stays on screen rather than bleeding to the raw terminal.
INSTALL_STEPS=""
show_step() {
    INSTALL_STEPS="${INSTALL_STEPS}  >> $*
"
    dialog --backtitle "$DIALOG_BT" --title " Installing... " \
        --infobox "$INSTALL_STEPS" 20 70 || true
}

# Reboot the system. Uses sysrq 'b' as the most direct kernel path; falls back
# to busybox reboot -f. Loops forever if all methods fail to prevent PID 1 exit.
do_reboot() {
    sync
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger    2>/dev/null || true
    reboot -f 2>/dev/null || true
    while true; do sleep 60; done
}

# ── Terminal UI (dialog) ──────────────────────────────────────────────────────
# The installer UI is built entirely on `dialog` (ncurses) — it is a hard
# dependency. The build bundles it into the installer initramfs (stage 8) and
# fails if it is missing, so the binary is always present here. We still verify
# it can initialise the terminal (terminfo for the active $TERM) before drawing
# anything, so a terminal problem dies cleanly instead of mid-form.

export TERM="${TERM:-linux}"
export TERMINFO="${TERMINFO:-/usr/share/terminfo}"
DIALOG_BT="larch-os installer"
DIALOG_TMP="/run/larch-dialog.out"

command -v dialog >/dev/null 2>&1 \
    || die "dialog not found in installer initramfs (it is a required component)"
dialog --print-maxsize >/dev/null 2>&1 \
    || die "dialog cannot initialise the terminal (TERM=$TERM, TERMINFO=$TERMINFO)"

cleanup() {
    umount "$MOUNT_OS"   2>/dev/null || true
    umount "$MOUNT_HOME" 2>/dev/null || true
    # The dialog scratch file briefly holds the typed password — remove it.
    rm -f "$DIALOG_TMP" 2>/dev/null || true
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

# Four sequential prompts — one per field — so Enter always advances to the
# next field rather than jumping to the OK button (a --mixedform limitation).
form_config() {
    local _pw2

    # ── Hostname ──────────────────────────────────────────────────────────────
    while true; do
        : > "$DIALOG_TMP"
        dialog --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (1/4) " \
            --inputbox "Hostname  (letters, numbers and hyphens):" 8 60 "$LARCH_HOSTNAME" \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        LARCH_HOSTNAME=$(cat "$DIALOG_TMP")
        case "$LARCH_HOSTNAME" in
            ""|-*|*-)
                dialog --backtitle "$DIALOG_BT" \
                    --msgbox "Hostname cannot be empty or start/end with a hyphen." 6 56
                continue ;;
            *[!a-zA-Z0-9-]*)
                dialog --backtitle "$DIALOG_BT" \
                    --msgbox "Hostname: only letters, numbers and hyphens allowed." 6 56
                continue ;;
        esac
        break
    done

    # ── Username ──────────────────────────────────────────────────────────────
    while true; do
        : > "$DIALOG_TMP"
        dialog --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (2/4) " \
            --inputbox "Username  (lowercase letters, numbers, _ and -):" 8 60 "$LARCH_USERNAME" \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        LARCH_USERNAME=$(cat "$DIALOG_TMP")
        case "$LARCH_USERNAME" in
            "")
                dialog --backtitle "$DIALOG_BT" --msgbox "Username cannot be empty." 5 40
                continue ;;
            *[!a-z0-9_-]*)
                dialog --backtitle "$DIALOG_BT" \
                    --msgbox "Username: only lowercase letters, numbers, _ and -." 5 56
                continue ;;
        esac
        break
    done

    # ── Password + confirm ────────────────────────────────────────────────────
    while true; do
        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (3/4) " \
            --passwordbox "Password:" 8 60 \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        LARCH_PASSWORD=$(cat "$DIALOG_TMP")

        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Continue" \
            --backtitle "$DIALOG_BT" --title " System Configuration (4/4) " \
            --passwordbox "Confirm password:" 8 60 \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        _pw2=$(cat "$DIALOG_TMP")

        if [ -z "$LARCH_PASSWORD" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Password cannot be empty." 5 40
            continue
        fi
        if [ "$LARCH_PASSWORD" != "$_pw2" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Passwords do not match." 5 40
            continue
        fi
        break
    done
}

# ── Pick target disk ──────────────────────────────────────────────────────────

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

# Is this partition a larch-os system partition? The installer formats LARCHOS as
# FAT32 with `mkfs.fat -n LARCHOS`, which writes the 11-byte volume label into the
# boot sector at offset 71 (FAT BS_VolLab). busybox has no `blkid`, so read it raw
# with dd — this needs no mount and works per-partition (findfs only resolves a
# label to a single device, so it can't tell which disk owns it).
part_is_larchos() {
    [ -b "$1" ] || return 1
    _lbl=$(dd if="$1" bs=1 skip=71 count=11 2>/dev/null | tr -d ' \000')
    [ "$_lbl" = "LARCHOS" ]
}

# Echo the /dev path of the LARCHOS partition on a disk (by sysfs name, e.g. sda),
# or nothing. Partition sysfs dirs are prefixed with the disk name (sda1, nvme0n1p1).
find_larchos_part() {
    for _pp in /sys/block/"$1"/"$1"*/partition; do
        [ -f "$_pp" ] || continue
        _pn=$(basename "$(dirname "$_pp")")
        if part_is_larchos "/dev/$_pn"; then echo "/dev/$_pn"; return 0; fi
    done
    return 1
}

# dialog --menu of installable disks; selection (a /dev path) lands in TARGET_DISK.
# Disks that already carry a larch-os install are marked and listed first, with the
# first such disk pre-selected so updating an existing install is the happy path.
# ESC re-shows the dialog. Restart button calls do_reboot.
pick_disk_dialog() {
    while true; do
        _default=""
        set --
        # Two passes so larch-os disks come first; within a pass, sysfs order.
        for _want_larch in 1 0; do
            for _sys in /sys/block/*; do
                _name=$(basename "$_sys")
                case "$_name" in
                    loop*|sr*|ram*|fd*|dm-*|md*) continue ;;
                esac
                [ -b "/dev/$_name" ] || continue
                if find_larchos_part "$_name" >/dev/null; then _is_larch=1; else _is_larch=0; fi
                [ "$_is_larch" -eq "$_want_larch" ] || continue
                _sectors=$(cat "$_sys/size" 2>/dev/null || echo 0)
                _size=$(human_size $(( _sectors * 512 )))
                _vendor=$(cat "$_sys/device/vendor" 2>/dev/null || echo "")
                _model=$(cat "$_sys/device/model" 2>/dev/null || echo "")
                _desc=$(echo "$_vendor $_model" | sed 's/^ *//;s/ *$//;s/  */ /g')
                [ -n "$_desc" ] || _desc="(unknown device)"
                if [ "$_is_larch" -eq 1 ]; then
                    _desc="$_desc  [Larch OS]"
                    [ -n "$_default" ] || _default="/dev/$_name"
                fi
                set -- "$@" "/dev/$_name" "$_size  $_desc"
            done
        done
        [ "$#" -gt 0 ] || die "No installable disks found"
        : > "$DIALOG_TMP"
        dialog --no-cancel --extra-button --extra-label "Restart" \
            --default-item "$_default" \
            --backtitle "$DIALOG_BT" --title " Target Disk " \
            --menu "Select the target disk. Disks marked [Larch OS] already have larch-os installed and can be updated in place.\nClean installs ERASE the selected disk." \
            18 72 8 "$@" 2>"$DIALOG_TMP"
        _rc=$?
        if [ "$_rc" -eq 0 ]; then
            TARGET_DISK=$(cat "$DIALOG_TMP")
            return 0
        fi
        if [ "$_rc" -eq 3 ]; then
            do_reboot
        fi
        # ESC (255) or any other code: re-show the dialog silently
    done
}

while true; do

[ -n "$TARGET_DISK" ] || pick_disk_dialog

[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

case "$TARGET_DISK" in
    *nvme*|*mmcblk*) PART1="${TARGET_DISK}p1"; PART2="${TARGET_DISK}p2" ;;
    *)               PART1="${TARGET_DISK}1";  PART2="${TARGET_DISK}2"  ;;
esac

# ── Update vs clean install ───────────────────────────────────────────────────
# If the chosen disk already holds a larch-os install, offer an in-place update
# (replace the OS payload + bootloader, keep config files and the home partition)
# as the default. Otherwise, fall through to a clean install.

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
    # init"). `-f` syncs and calls the reboot(2) syscall directly. exit 0 is a
    # belt-and-braces guard in case reboot ever returns.
    do_reboot
}

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
  Hostname       : $LARCH_HOSTNAME
  Username       : $LARCH_USERNAME
  Target disk    : $TARGET_DISK
  OS partition   : $PART1  (FAT32, $OS_PART_SIZE, LARCHOS)
  Home partition : $PART2  (ext4, remainder)

  \Z1WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED.\Zn" \
        15 66 \
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

# machine-id — generated once at install so the machine keeps a stable identity
# (DHCP lease/IP, DHCPv6 DUID, systemd journal) across reboots. /etc is tmpfs on
# the installed system, so without a persisted value systemd would synthesise a
# fresh id every boot. The OS init re-applies this into /etc/machine-id.
# Format: 32 lowercase hex digits + newline (sourced from the kernel UUID pool).
tr -d '-' < /proc/sys/kernel/random/uuid > "$CONFIG_TMP/machine-id"

printf '# /etc/fstab — larch-os (generated by installer)\n'                    > "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/tmp\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'tmpfs\t\t\t/run\t\ttmpfs\tdefaults,nosuid,nodev\t\t0\t0\n'           >> "$CONFIG_TMP/fstab"
printf 'LABEL=LARCHHOME\t\t/home/%s\text4\tdefaults,relatime,nofail\t0\t2\n' \
    "$LARCH_USERNAME"                                                          >> "$CONFIG_TMP/fstab"
# Persist NetworkManager system connections (WiFi etc.) on the home partition.
# Bind a root-owned dir under the user's home over NM's keyfile store. The
# fstab generator orders this after the /home mount; NetworkManager.service
# waits for it via a RequiresMountsFor drop-in shipped in the rootfs overlay.
printf '/home/%s/.larch/nm-system-connections\t/etc/NetworkManager/system-connections\tnone\tbind,nofail\t0\t0\n' \
    "$LARCH_USERNAME"                                                          >> "$CONFIG_TMP/fstab"

# ── Partition ─────────────────────────────────────────────────────────────────

show_step "Unmounting any existing partitions on $TARGET_DISK"
for _p in "${TARGET_DISK}"[0-9]* "${TARGET_DISK}"p[0-9]*; do
    [ -b "$_p" ] && umount "$_p" 2>/dev/null || true
done
unset _p

show_step "Creating GPT partition table on $TARGET_DISK"
wipefs -a "$TARGET_DISK" >/dev/null 2>&1
printf 'label: gpt\nsize=%s, type=uefi, name=LARCHOS\ntype=linux, name=LARCHHOME\n' \
    "$OS_PART_SIZE" | sfdisk -q "$TARGET_DISK" >/dev/null 2>&1
blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true

i=0
while [ $i -lt 15 ]; do [ -b "$PART1" ] && [ -b "$PART2" ] && break; sleep 1; i=$((i+1)); done
[ -b "$PART1" ] || die "Partition $PART1 not found after partitioning"
[ -b "$PART2" ] || die "Partition $PART2 not found after partitioning"

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
cp "$CONFIG_TMP/hostname" "$DEST/hostname"
cp "$CONFIG_TMP/hosts"    "$DEST/hosts"
cp "$CONFIG_TMP/passwd"   "$DEST/passwd"
cp "$CONFIG_TMP/shadow"   "$DEST/shadow"
cp "$CONFIG_TMP/username"   "$DEST/username"
cp "$CONFIG_TMP/machine-id" "$DEST/machine-id"
cp "$CONFIG_TMP/fstab"    "$DEST/fstab"
chmod 640 "$DEST/shadow"

sync
umount "$MOUNT_OS"

# ── Format and seed home partition ───────────────────────────────────────────

mkdir -p "$MOUNT_HOME"

show_step "Formatting home partition as ext4 ($PART2)"
mkfs.ext4 -F -L LARCHHOME -m 0 "$PART2" >/dev/null 2>&1

mount_or_die ext4 "$PART2" "$MOUNT_HOME"

show_step "Seeding home partition for $LARCH_USERNAME"
cp -a /mnt/iso/skel/. "$MOUNT_HOME/" 2>/dev/null || true
chown -R 1000:1000 "$MOUNT_HOME"
chown 0:0 "$MOUNT_HOME/lost+found" 2>/dev/null || true
chmod 0750 "$MOUNT_HOME"

# Persistent, root-owned store for NetworkManager system connections. This is
# the bind-mount source for /etc/NetworkManager/system-connections (see fstab).
# Root-owned 0700 so WiFi secrets stay unreadable/undeletable by the user even
# though they live under the user's home (the only persistent partition).
mkdir -p "$MOUNT_HOME/.larch/nm-system-connections"
chown 0:0 "$MOUNT_HOME/.larch" "$MOUNT_HOME/.larch/nm-system-connections"
chmod 0755 "$MOUNT_HOME/.larch"
chmod 0700 "$MOUNT_HOME/.larch/nm-system-connections"

sync
umount "$MOUNT_HOME"

trap - EXIT

# ── Done ─────────────────────────────────────────────────────────────────────

dialog --backtitle "$DIALOG_BT" --title " Installation Complete " \
    --msgbox "\
  larch-os has been installed successfully.

  Hostname : $LARCH_HOSTNAME
  User     : $LARCH_USERNAME
  OS       : $PART1  (LARCHOS)
  Home     : $PART2  (LARCHHOME)

  Remove the installation media, then choose OK to reboot." \
    15 60
clear_screen
umount /mnt/iso 2>/dev/null || true
do_reboot
