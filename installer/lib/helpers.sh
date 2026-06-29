# installer/lib/helpers.sh — global variables, utility functions, dialog init
# Sourced by install.sh; not executable on its own.

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
