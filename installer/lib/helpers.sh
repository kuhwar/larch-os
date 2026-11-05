# installer/lib/helpers.sh — global variables, utility functions, dialog init
# Sourced by install.sh; not executable on its own.

ISO_MOUNT="/mnt/iso"
EFI_PART_SIZE="512MiB"
SYS_PART_SIZE="1GiB"
# LARCHCONF holds the upper layers of /etc and /var, i.e. all runtime state
# (journal capped at 64M, Flatpak system installs excluded — those go to --user
# in /home), so it is larger than on master.
CONF_PART_SIZE="1GiB"
TARGET_DISK=""
AUTO_YES=0
MOUNT_EFI="/run/larch-target-efi"
MOUNT_SYS="/run/larch-target-sys"
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

# Write this machine's identity files into <out-dir> (LARCHCONF's etc/, the
# upper layer of the /etc overlay): hostname, hosts, machine-id, and the account
# databases with the user in place of the image's UID-1000 placeholder "larch".
# Each starts as a cp -p of the image's file (read from the mounted LARCHSYS) and
# is rewritten with `cat >`, so it keeps the image's owner and mode (e.g. shadow:
# root:shadow 0640) — the same result as an overlay copy-up.
# Usage: apply_machine_config <image-root> <config-dir> <username> <out-dir>
apply_machine_config() {
    _root="$1"; _cfg="$2"; _user="$3"; _out="$4"

    mkdir -p "$_out"
    chown 0:0 "$_out"
    chmod 0755 "$_out"
    for _f in hostname hosts machine-id passwd shadow group gshadow subuid subgid; do
        cp -p "$_root/etc/$_f" "$_out/$_f"
    done

    cat "$_cfg/hostname"   > "$_out/hostname"
    cat "$_cfg/hosts"      > "$_out/hosts"
    cat "$_cfg/machine-id" > "$_out/machine-id"

    # passwd: drop any UID-1000 line, append the installed user.
    grep -v '^[^:]*:[^:]*:1000:' "$_root/etc/passwd" > "$_cfg/passwd.new" || true
    cat "$_cfg/passwd" >> "$_cfg/passwd.new"
    cat "$_cfg/passwd.new" > "$_out/passwd"
    # shadow: drop the placeholder's entry, append the hashed installer entry.
    grep -v "^larch:\|^${_user}:" "$_root/etc/shadow" > "$_cfg/shadow.new" || true
    cat "$_cfg/shadow" >> "$_cfg/shadow.new"
    cat "$_cfg/shadow.new" > "$_out/shadow"
    rm -f "$_cfg/passwd.new" "$_cfg/shadow.new"

    if [ "$_user" != "larch" ]; then
        # Group memberships (word-boundary-safe) and the subordinate ID range
        # for rootless containers move to the installed username.
        for _f in group gshadow; do
            sed "s/\blarch\b/$_user/g" "$_root/etc/$_f" > "$_cfg/$_f.new"
            cat "$_cfg/$_f.new" > "$_out/$_f"
            rm -f "$_cfg/$_f.new"
        done
        for _f in subuid subgid; do
            sed "s/^larch:/$_user:/" "$_root/etc/$_f" > "$_cfg/$_f.new"
            cat "$_cfg/$_f.new" > "$_out/$_f"
            rm -f "$_cfg/$_f.new"
        done
    fi
    unset _root _cfg _user _out _f
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
    mount -t "$_fstype" "$_dev" "$_mnt" && return 0
    die "Failed to mount $_dev at $_mnt as $_fstype"
}
