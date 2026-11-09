# shared/lib/conf.sh — LARCHCONF's /etc and /var layers
# Sourced by the installer and the updater; not executable on its own.
#
# LARCHCONF (mounted at /conf on the running system) holds the upper layers of
# the /etc and /var overlays that sys.initramfs mounts: etc/ + etc-work/,
# var/ + var-work/. The installer creates them (seed_layers). A normal update
# leaves them alone. Switching desktop rebuilds them on the new image
# (rebuild_layers): the user's state below is carried over, everything else is
# dropped so the new desktop starts from its image's own files.

# User state that survives a desktop switch, relative to /etc and /var. The
# identity files (hostname, hosts, machine-id) and the account databases are
# not listed: they are rewritten on the new image (apply_machine_config).
KEEP_ETC="NetworkManager/system-connections cups/printers.conf cups/classes.conf
cups/subscriptions.conf cups/ppd localtime timezone adjtime locale.conf
vconsole.conf X11/xorg.conf.d/00-keyboard.conf"
KEEP_VAR="lib/NetworkManager lib/bluetooth lib/AccountsService lib/cups lib/flatpak
lib/systemd/backlight lib/systemd/rfkill lib/systemd/timers lib/chrony
log/journal"

# Write this machine's identity files into <out-dir> (an /etc upper layer):
# hostname, hosts, machine-id, and the account databases with the user in place
# of the image's UID-1000 placeholder "larch". Each starts as a cp -p of the
# image's file and is rewritten with `cat >`, so it keeps the image's owner and
# mode (e.g. shadow: root:shadow 0640) — the same result as an overlay copy-up.
# <config-dir> holds hostname, hosts, machine-id, and passwd/shadow with the
# user's single line each.
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

    # passwd: drop any UID-1000 line, append the user.
    grep -v '^[^:]*:[^:]*:1000:' "$_root/etc/passwd" > "$_cfg/passwd.new" || true
    cat "$_cfg/passwd" >> "$_cfg/passwd.new"
    cat "$_cfg/passwd.new" > "$_out/passwd"
    # shadow: drop the placeholder's entry, append the user's.
    grep -v "^larch:\|^${_user}:" "$_root/etc/shadow" > "$_cfg/shadow.new" || true
    cat "$_cfg/shadow" >> "$_cfg/shadow.new"
    cat "$_cfg/shadow.new" > "$_out/shadow"
    rm -f "$_cfg/passwd.new" "$_cfg/shadow.new"

    if [ "$_user" != "larch" ]; then
        # Group memberships (word-boundary-safe) and the subordinate ID range
        # for rootless containers move to the username.
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

# seed_layers <image-root> <config-dir> <username> <etc-out> <var-out>
# Fresh upper layers for <image-root>: the identity files in <etc-out>, an
# empty <var-out> (its root's mode/owner become /var's), and the image's "up to
# date" stamps, so ConditionNeedsUpdate= services (systemd-sysusers, ldconfig,
# …) don't run on the first boot but do run once after each update — whose
# image has a newer /usr — and bring the layers up to date.
seed_layers() {
    apply_machine_config "$1" "$2" "$3" "$4"
    mkdir -p "$5"
    chown 0:0 "$5"
    chmod 0755 "$5"
    cp -p "$1/etc/.updated" "$4/.updated" 2>/dev/null || true
    cp -p "$1/var/.updated" "$5/.updated" 2>/dev/null || true
}

# read_machine_config <etc-upper> <config-dir>: the identity of an installed
# machine (as written by the installer and changed since — password, full
# name) into <config-dir>, in apply_machine_config's format. Sets CONF_USER.
read_machine_config() {
    mkdir -p "$2"
    for _f in hostname hosts machine-id; do
        [ -s "$1/$_f" ] || return 1
        cp "$1/$_f" "$2/$_f"
    done
    grep '^[^:]*:[^:]*:1000:' "$1/passwd" 2>/dev/null | head -1 > "$2/passwd"
    CONF_USER=$(cut -d: -f1 "$2/passwd")
    [ -n "$CONF_USER" ] || return 1
    grep "^$CONF_USER:" "$1/shadow" 2>/dev/null | head -1 > "$2/shadow"
    [ -s "$2/shadow" ] || return 1
    chmod 600 "$2/shadow"
}

# mkparents <old-root> <new-root> <rel>: the parent directories of <rel> in
# <new-root>, with the owner and mode they have in <old-root>.
mkparents() {
    _d="${3%/*}"
    [ "$_d" != "$3" ] || return 0
    _acc=""
    for _c in $(echo "$_d" | tr '/' ' '); do
        _acc="${_acc:+$_acc/}$_c"
        [ -d "$2/$_acc" ] && continue
        mkdir "$2/$_acc" || return 1
        if [ -d "$1/$_acc" ]; then
            chown "$(stat -c %u:%g "$1/$_acc")" "$2/$_acc"
            chmod "$(stat -c %a "$1/$_acc")" "$2/$_acc"
        fi
    done
}

# keep_state <old-upper> <new-upper> <paths>: copy what exists of <paths>.
keep_state() {
    for _p in $3; do
        [ -e "$1/$_p" ] || [ -L "$1/$_p" ] || continue
        mkparents "$1" "$2" "$_p" || return 1
        rm -rf "${2:?}/$_p"
        cp -a "$1/$_p" "$2/$_p" || return 1
    done
}

# rebuild_layers <conf-mount> <new-image-root>: LARCHCONF's layers for a
# different desktop, built beside the current ones as etc.new/ and var.new/
# (swap_layers puts them in place). The current layers are left as they are.
rebuild_layers() {
    _conf="$1"; _img="$2"; _cfg="$RUN/machine-config"
    # var.new first: sys.initramfs reads var.new without etc.new as a swap
    # in progress.
    rm -rf "$_conf/var.new" "$_conf/etc.new" "$_cfg"
    read_machine_config "$_conf/etc" "$_cfg" || return 1
    seed_layers "$_img" "$_cfg" "$CONF_USER" "$_conf/etc.new" "$_conf/var.new" || return 1
    rm -rf "$_cfg"
    keep_state "$_conf/etc" "$_conf/etc.new" "$KEEP_ETC" || return 1
    keep_state "$_conf/var" "$_conf/var.new" "$KEEP_VAR" || return 1
    # The session the user last picked belonged to the old desktop.
    for _u in "$_conf"/var.new/lib/AccountsService/users/*; do
        [ -f "$_u" ] && sed -i '/^Session=/d; /^XSession=/d' "$_u"
    done
    return 0
}

# swap_layers <conf-mount>: put etc.new/ and var.new/ in place (renames), with
# fresh workdirs. If this is cut off, sys.initramfs finishes it at boot.
swap_layers() {
    for _d in etc var; do
        [ -d "$1/$_d.new" ] || return 1
    done
    for _d in etc var; do
        rm -rf "${1:?}/$_d.old"
        mv "$1/$_d" "$1/$_d.old" && mv "$1/$_d.new" "$1/$_d" || return 1
        rm -rf "${1:?}/$_d-work"
        mkdir -m 0700 "$1/$_d-work"
    done
    sync
    rm -rf "${1:?}/etc.old" "${1:?}/var.old"
    sync
}
