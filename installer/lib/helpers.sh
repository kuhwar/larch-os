# installer/lib/helpers.sh — global variables, utility functions, dialog init
# Sourced by install.sh; not executable on its own.

ISO_MOUNT="/mnt/iso"
OS_PART_SIZE="3GiB"
CONF_PART_SIZE="512MiB"
TARGET_DISK=""
AUTO_YES=0
MOUNT_OS="/run/larch-target-os"
MOUNT_CONF="/run/larch-target-conf"
MOUNT_HOME="/run/larch-target-home"

LARCH_HOSTNAME=""
LARCH_FULLNAME=""
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

# Install the account files into accounts/ on a mounted LARCHCONF.
# Usage: seed_accounts <larchconf-mount> <passwd-file> <shadow-file>
seed_accounts() {
    mkdir -p "$1/accounts"
    chown 0:0 "$1/accounts"
    chmod 0700 "$1/accounts"
    cp "$2" "$1/accounts/passwd"
    cp "$3" "$1/accounts/shadow"
    chown 0:0 "$1/accounts/passwd" "$1/accounts/shadow"
    chmod 0644 "$1/accounts/passwd"
    chmod 0600 "$1/accounts/shadow"
}

# Copy each top-level directory of the ISO's larchconf-seed/ onto a mounted
# LARCHCONF, skipping any that already exist there (never clobbers live state).
# ISO9660 drops modes, so they're set here: root-owned, directories get the mode
# in a sibling <name>.mode file (default 0700), files the same minus execute.
# Usage: seed_larchconf <larchconf-mount>
seed_larchconf() {
    for _src in "$ISO_MOUNT/larchconf-seed"/*/; do
        [ -d "$_src" ] || continue
        _name=$(basename "$_src")
        [ -e "$1/$_name" ] && continue
        _mode=0700
        if [ -f "$ISO_MOUNT/larchconf-seed/$_name.mode" ]; then
            _mode=$(cat "$ISO_MOUNT/larchconf-seed/$_name.mode")
        fi
        cp -R "${_src%/}" "$1/"
        chown -R 0:0 "$1/$_name"
        find "$1/$_name" -type d -exec chmod "$_mode" {} \;
        find "$1/$_name" -type f -exec chmod "$_mode" {} \; -exec chmod a-x {} \;
    done
    unset _src _name _mode
}

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
# dialog is a hard dependency — bundled into the installer initramfs at stage 8.
# We verify it can initialise the terminal before drawing anything so a terminal
# problem dies cleanly instead of mid-form.

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
    umount "$MOUNT_CONF" 2>/dev/null || true
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
