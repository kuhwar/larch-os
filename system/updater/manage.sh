# system/updater/manage.sh — the Manage LARCH menu's actions other than the
# update: user accounts, Reset LARCH OS, boot into the firmware (EFI) setup.
# Sourced by update.sh (installed as /usr/lib/larch/manage.sh); not executable
# on its own. Expects ui.sh, hw.sh, conf.sh and account.sh, and update.sh's
# SYS_MNT (LARCHSYS, mounted rw), CONF_MNT, TARGET_DISK, TARGET_CONF.
#
# Accounts are changed with the installed image's own tools (useradd, userdel,
# chpasswd, unix_chkpwd), chrooted into the image as the running system sees
# it: sys.squashfs loop-mounted, /etc and /var overlaid with LARCHCONF's upper
# layers exactly as sys.initramfs does, LARCHHOME at /home. So the hashes,
# groups, subordinate ID ranges and /etc/skel are the system's own, and a
# password changed in GNOME (yescrypt) is checked like the lock screen does.

IMG_MNT="$RUN/img"
mkdir -p "$IMG_MNT"
# Same options as system/initramfs/sys/init (see there).
OVL_OPTS="index=off,metacopy=off,redirect_dir=off"
IMG_OPEN=0

conf_mount() {
    mountpoint -q "$CONF_MNT" 2>/dev/null && return 0
    fsck_ext4 "$TARGET_CONF" && mount -t ext4 "/dev/$TARGET_CONF" "$CONF_MNT" && return 0
    note "Config partition" "  Could not mount the config partition /dev/$TARGET_CONF."
    return 1
}

conf_umount() {
    sync
    umount "$CONF_MNT" 2>/dev/null || true
}

# img_open: the installed system at $IMG_MNT, writable where the running
# system is (/etc, /var, /home), with /dev, /proc, /sys, /run and /tmp.
img_open() {
    [ "$IMG_OPEN" = 0 ] || return 0
    TARGET_HOME=$(part_on_disk "$TARGET_DISK" LARCHHOME) \
        || { note "Users" "  No LARCHHOME partition on /dev/$TARGET_DISK."; return 1; }
    conf_mount || return 1
    if ! mount -t squashfs -o ro,loop "$SYS_MNT/sys.squashfs" "$IMG_MNT"; then
        note "Users" "  Could not mount the installed system (sys.squashfs)."
        conf_umount; return 1
    fi
    IMG_OPEN=1
    for _d in etc var; do
        mkdir -p "$CONF_MNT/$_d" "$CONF_MNT/$_d-work"
        mount -t overlay overlay \
            -o "lowerdir=$IMG_MNT/$_d,upperdir=$CONF_MNT/$_d,workdir=$CONF_MNT/$_d-work,$OVL_OPTS" \
            "$IMG_MNT/$_d" \
            || { note "Users" "  Could not mount the /$_d overlay."; img_close; return 1; }
    done
    mount -o bind /dev "$IMG_MNT/dev" \
        && mount -t proc proc "$IMG_MNT/proc" \
        && mount -t sysfs sysfs "$IMG_MNT/sys" \
        && mount -t tmpfs -o mode=0755 tmpfs "$IMG_MNT/run" \
        && mount -t tmpfs -o mode=1777 tmpfs "$IMG_MNT/tmp" \
        || { note "Users" "  Could not prepare the installed system."; img_close; return 1; }
    if ! fsck_ext4 "$TARGET_HOME" || ! mount -t ext4 "/dev/$TARGET_HOME" "$IMG_MNT/home"; then
        note "Users" "  Could not mount the home partition /dev/$TARGET_HOME."
        img_close; return 1
    fi
}

img_close() {
    sync
    for _m in home tmp run sys proc dev var etc; do
        umount "$IMG_MNT/$_m" 2>/dev/null || umount -l "$IMG_MNT/$_m" 2>/dev/null || true
    done
    umount "$IMG_MNT" 2>/dev/null || umount -l "$IMG_MNT" 2>/dev/null || true
    IMG_OPEN=0
    conf_umount
}

in_img() { chroot "$IMG_MNT" "$@"; }

# The regular users: "name:uid:full name" lines.
list_users() {
    awk -F: '$3 >= 1000 && $3 < 60000 { split($5, g, ","); print $1 ":" $3 ":" g[1] }' \
        "$IMG_MNT/etc/passwd"
}

# check_password <user> <password>: the image's PAM helper, as root (which may
# check any user; it reads the password NUL-terminated from a pipe).
check_password() {
    printf '%s\000' "$2" | in_img /usr/sbin/unix_chkpwd "$1" nonull >/dev/null 2>&1
}

add_user() {
    LARCH_FULLNAME=""
    ask_full_name "Add a user (1/3)" "Back" || return 0
    ask_password "Add a user (2/3)" "Add a user (3/3)"

    # Names the system, the other users or a home directory left behind by a
    # deleted user already have get a numeric suffix.
    { cut -d: -f1 "$IMG_MNT/etc/passwd" "$IMG_MNT/etc/group"; ls -A "$IMG_MNT/home"; } \
        | sort -u > "$RUN/reserved-names"
    RESERVED_NAMES="$RUN/reserved-names"
    derive_username

    if ! dialog --backtitle "$DIALOG_BT" --title " Add a user " \
            --yes-label "Add" --no-label "Back" --yesno "
  Full name : $LARCH_FULLNAME
  Username  : $LARCH_USERNAME
  Home      : /home/$LARCH_USERNAME" 10 60; then
        LARCH_PASSWORD=""; return 0
    fi

    msg "Add a user" "Adding $LARCH_USERNAME..."
    # The groups the image gives its placeholder user (setup-chroot.sh), those
    # that exist. No wheel: it is polkit's admin identity.
    _groups=$(awk -F: '$1 == "audio" || $1 == "video" || $1 == "input" { printf "%s%s", s, $1; s = "," }' \
        "$IMG_MNT/etc/group")
    # A UID no account and no file in /home has had: a deleted user's kept home
    # (still owned by its old UID) must not pass to the next user. useradd -U
    # gives the private group the same number when it is free.
    _uid=$( { cut -d: -f3 "$IMG_MNT/etc/passwd"; cut -d: -f3 "$IMG_MNT/etc/group"
              for _h in "$IMG_MNT"/home/*; do [ -e "$_h" ] && stat -c %u "$_h"; done; } \
            | awk 'BEGIN { m = 1000 } $1 >= 1000 && $1 < 60000 && $1 > m { m = $1 } END { print m + 1 }')
    if ! in_img useradd -m -U -u "$_uid" -s /bin/bash -c "$LARCH_FULLNAME" ${_groups:+-G "$_groups"} \
            "$LARCH_USERNAME" >"$RUN/user.err" 2>&1; then
        LARCH_PASSWORD=""
        note "Add a user" "  Could not add $LARCH_USERNAME:\n  $(tail -1 "$RUN/user.err")"
        return 0
    fi
    if ! printf '%s:%s\n' "$LARCH_USERNAME" "$LARCH_PASSWORD" | in_img chpasswd >"$RUN/user.err" 2>&1; then
        LARCH_PASSWORD=""
        in_img userdel -r "$LARCH_USERNAME" >/dev/null 2>&1 || true
        note "Add a user" "  Could not set the password of $LARCH_USERNAME:\n  $(tail -1 "$RUN/user.err")"
        return 0
    fi
    LARCH_PASSWORD=""
    # Like the installer's home.
    chmod 0750 "$IMG_MNT/home/$LARCH_USERNAME"
    sync
    note "Add a user" "  $LARCH_FULLNAME ($LARCH_USERNAME) can now log in."
}

# delete_user <name>
delete_user() {
    _u="$1"
    # Without any user nobody could log in (there is no root login).
    if [ "$(list_users | wc -l)" -le 1 ]; then
        note "Delete a user" "  $_u is the only user; add another user before deleting it."
        return 0
    fi

    : > "$DIALOG_TMP"
    dialog --insecure --backtitle "$DIALOG_BT" --title " Delete $_u " \
        --ok-label "Next" --cancel-label "Back" \
        --passwordbox "To delete $_u, enter $_u's password:" 8 60 \
        2>"$DIALOG_TMP" || { : > "$DIALOG_TMP"; return 0; }
    _pw=$(cat "$DIALOG_TMP"); : > "$DIALOG_TMP"
    msg "Delete $_u" "Checking the password..."
    if ! check_password "$_u" "$_pw"; then
        _pw=""
        note "Delete $_u" "  Wrong password. $_u was not deleted."
        return 0
    fi
    _pw=""

    _home=$(awk -F: -v u="$_u" '$1 == u { print $6 }' "$IMG_MNT/etc/passwd")
    _rm=""
    _what="  Its files in $_home are kept."
    if [ -n "$_home" ] && [ -d "$IMG_MNT$_home" ]; then
        dialog --colors --backtitle "$DIALOG_BT" --title " Delete $_u " \
            --defaultno --yes-label "Delete files" --no-label "Keep files" --yesno "
  Also delete $_u's home folder $_home
  and everything in it?

  \Z1Deleted files can't be recovered.\Zn" 11 64 && {
            _rm="-r"; _what="  $_home and its contents are deleted as well."
        }
    fi
    dialog --colors --backtitle "$DIALOG_BT" --title " Delete $_u " \
        --defaultno --yes-label "Delete" --no-label "Back" --yesno "
  Delete the user $_u?

$_what" 10 64 || return 0

    msg "Delete $_u" "Deleting $_u..."
    # userdel -r also removes the mail spool; exit 12 = the home could not be
    # removed (the account is gone all the same).
    in_img userdel $_rm "$_u" >"$RUN/user.err" 2>&1 || true
    if grep -q "^$_u:" "$IMG_MNT/etc/passwd"; then
        note "Delete $_u" "  Could not delete $_u:\n  $(tail -1 "$RUN/user.err")"
        return 0
    fi
    if [ -n "$_rm" ] && [ -n "$_home" ] && [ "$_home" = "/home/$_u" ] && [ -e "$IMG_MNT$_home" ]; then
        rm -rf "${IMG_MNT:?}/home/${_u:?}"
    fi
    # GNOME's per-user settings (language, avatar, session).
    rm -f "$IMG_MNT/var/lib/AccountsService/users/$_u" "$IMG_MNT/var/lib/AccountsService/icons/$_u"
    sync
    note "Delete $_u" "  $_u has been deleted.\n$_what"
}

manage_users() {
    msg "Users" "Opening the installed system..."
    img_open || return 0
    while true; do
        # "+" can't be a username.
        set -- + "Add a user"
        _users=$(list_users)
        _n=0
        _old_ifs=$IFS; IFS='
'
        for _l in $_users; do
            IFS=$_old_ifs
            _name=${_l%%:*}; _rest=${_l#*:}; _uid=${_rest%%:*}; _full=${_rest#*:}
            _d="Delete  ${_full:-$_name}"
            set -- "$@" "$_name" "$_d"
            _n=$((_n + 1))
        done
        IFS=$_old_ifs
        _h=$((_n + 1)); [ "$_h" -le 10 ] || _h=10
        dialog --backtitle "$DIALOG_BT" --title " Manage users " \
            --ok-label "Select" --cancel-label "Back" \
            --menu "\nAdd a user, or pick a user to delete:" $((_h + 8)) 70 "$_h" "$@" \
            2>"$DIALOG_TMP" || break
        _sel=$(cat "$DIALOG_TMP")
        case "$_sel" in
            +) add_user ;;
            *)   delete_user "$_sel" ;;
        esac
    done
    img_close
}

# Reset LARCH OS: LARCHCONF's layers replaced by ones holding only the account
# files, computer name and machine-id, copied as they are (conf.sh
# rebuild_layers). Built as etc.new/var.new and swapped in (cut-off safe).
reset_system() {
    dialog --colors --backtitle "$DIALOG_BT" --title " Reset LARCH OS " \
        --defaultno --yes-label "Reset" --no-label "Back" --yesno "
  Reset the system settings to how they were right after installation.

  \Z1Removed:\Zn Wi-Fi networks and other connections, Bluetooth devices,
  printers, time zone, language and avatar settings, logs, and every
  other change to the system's configuration.

  Kept: the user accounts and their passwords, the computer's name,
  and everything in /home (your files, your settings, your apps)." 17 76 \
        || return 0

    msg "Reset LARCH OS" "Resetting the system settings..."
    conf_mount || return 0
    if ! rebuild_layers "$CONF_MNT"; then
        rm -rf "$CONF_MNT/var.new" "$CONF_MNT/etc.new"   # var.new first (see sys/init)
        conf_umount
        note "Reset LARCH OS" "  Could not rebuild the settings (config partition full,\n  or no account files found). Nothing was changed."
        return 0
    fi
    swap_layers "$CONF_MNT" \
        || die "Could not put the reset settings in place on /dev/$TARGET_CONF. Reboot and pick \"Manage LARCH\" → \"Reset LARCH OS\" to retry."
    conf_umount
    dialog --backtitle "$DIALOG_BT" --title " Reset LARCH OS " \
        --msgbox "\n  The system settings have been reset.\n\n  Choose OK to reboot." 10 60
    do_reboot
}

# Boot into the firmware setup: set EFI_OS_INDICATIONS_BOOT_TO_FW_UI (bit 0 of
# the global variable OsIndications) and reboot — what systemd-boot's and
# `systemctl reboot --firmware-setup`'s "reboot into firmware" do.
efi_setup() {
    _efivars=/sys/firmware/efi/efivars
    _guid=8be4df61-93ca-11d2-aa0d-00e098032b8c
    if [ ! -d /sys/firmware/efi ]; then
        note "EFI setup" "  This computer was not started in UEFI mode."
        return 0
    fi
    /usr/sbin/modprobe efivarfs 2>/dev/null || true
    mountpoint -q "$_efivars" 2>/dev/null || mount -t efivarfs efivarfs "$_efivars" 2>/dev/null \
        || { note "EFI setup" "  Could not access the EFI variables."; return 0; }
    # 4 attribute bytes, then the 64-bit value (little-endian). Read whole:
    # busybox od's -j doesn't skip on efivarfs files.
    set -- $(od -An -tu1 "$_efivars/OsIndicationsSupported-$_guid" 2>/dev/null)
    _sup=0
    [ "$#" -lt 5 ] || _sup=$5
    if [ $(( _sup & 1 )) -ne 1 ]; then
        note "EFI setup" "  This computer's firmware can't be asked to open its setup.\n  Reboot and press its setup key (often F2, F10, F12, Del or Esc)\n  while it starts."
        return 0
    fi
    _var="$_efivars/OsIndications-$_guid"
    set -- $(od -An -tu1 "$_var" 2>/dev/null)
    if [ "$#" -eq 12 ]; then shift 4; else set -- 0 0 0 0 0 0 0 0; fi
    _b0=$(( $1 | 1 )); shift
    # NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS
    _fmt='\007\000\000\000'"$(printf '\\%03o' "$_b0" "$@")"
    printf "$_fmt" > "$RUN/osindications"
    chattr -i "$_var" 2>/dev/null || true
    # One write(): efivarfs takes the attributes and data in a single call.
    if ! cat "$RUN/osindications" > "$_var" 2>/dev/null; then
        note "EFI setup" "  Could not set the EFI variable OsIndications.\n  Reboot and press the firmware's setup key while it starts."
        return 0
    fi
    sync
    msg "EFI setup" "Restarting into the firmware setup..."
    sleep 1
    do_reboot
}
