# shared/lib/conf.sh — LARCHCONF's /etc and /var layers
# Sourced by sys.initramfs, the installer and the updater; not executable on
# its own.
#
# LARCHCONF (mounted at /conf on the running system) holds:
#   etc/ + etc-work/  the upper layer of the /etc overlay
#   var/              /var's writable directories (VAR_DIRS): var/lib, var/log,
#                     var/cache and var/spool, bind-mounted over the image's
#                     (mount_var). The rest of /var is the read-only image.
# The installer creates them (seed_layers). Updates leave them alone, desktop
# switches included. "Reset LARCH OS" (Manage LARCH) replaces them with
# layers holding nothing but the machine's identity and accounts
# (rebuild_layers + swap_layers).

# Same options as the /etc overlay everywhere (sys/init, manage.sh, fstab):
# the lower layer is replaced by every update, so nothing in the upper layer
# may point into a particular squashfs — index (records the lower root's file
# handle and refuses to mount once it changes: "Stale file handle"), metacopy
# (metadata-only copy-ups whose data stays in the old lower layer) and
# redirect_dir (renamed directories referring to lower paths) are all off,
# whatever the kernel's defaults.
OVL_OPTS="index=off,metacopy=off,redirect_dir=off"

# /var's writable directories, each LARCHCONF:/var/<dir> bind-mounted on
# /var/<dir>. Everything else in /var is the image's: symlinks into /run
# (lock, run), mail → spool/mail, empty dirs nothing writes to (adm, db, opt,
# …), and /var/tmp, a tmpfs (fstab).
VAR_DIRS="lib log cache spool"

# var_skeleton <image-dir> <conf-dir>: every directory and symlink of the
# image's <image-dir> that <conf-dir> lacks, created there with the image's
# numeric owner and mode (no files). So services whose state directories only
# their package creates (colord, geoclue, samba, CUPS's spool, …) find them on
# an empty layer, and a newer image's new ones appear after an update.
# Existing entries are never changed.
var_skeleton() {
    [ -d "$1" ] || return 0
    (cd "$1" && find . \( -type d -o -type l \)) | while IFS= read -r _p; do
        _p=${_p#.}; _p=${_p#/}
        _t="$2${_p:+/$_p}"
        [ -e "$_t" ] || [ -L "$_t" ] && continue
        if [ -L "$1/$_p" ]; then
            ln -s "$(readlink "$1/$_p")" "$_t" 2>/dev/null || true
        else
            mkdir "$_t" 2>/dev/null || continue
            chown "$(stat -c %u:%g "$1/${_p:-.}")" "$_t" 2>/dev/null || true
            chmod "$(stat -c %a "$1/${_p:-.}")" "$_t" 2>/dev/null || true
        fi
    done
    unset _p _t
}

# mount_var <root> <conf-mount>: LARCHCONF:/var/<dir> (completed by
# var_skeleton) bind-mounted on <root>/var/<dir>, for each of VAR_DIRS.
mount_var() {
    mkdir -p "$2/var" || return 1
    for _d in $VAR_DIRS; do
        var_skeleton "$1/var/$_d" "$2/var/$_d"
        [ -d "$2/var/$_d" ] || mkdir -m 0755 "$2/var/$_d" || return 1
        mount --bind "$2/var/$_d" "$1/var/$_d" || return 1
    done
    unset _d
}

# umount_var <root>: undo mount_var.
umount_var() {
    for _d in $VAR_DIRS; do
        umount "$1/var/$_d" 2>/dev/null || umount -l "$1/var/$_d" 2>/dev/null || true
    done
    unset _d
}

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
# Fresh layers for <image-root>: the identity files in <etc-out>, an empty
# <var-out> (mount_var fills in the directory skeleton at boot), and the
# image's /etc "up to date" stamp, so ConditionNeedsUpdate= services
# (systemd-sysusers, ldconfig, …) don't run on the first boot but do run once
# after each update — whose image has a newer /usr — and bring the layer up to
# date. /var/.updated is the image's own, on the read-only /var.
seed_layers() {
    apply_machine_config "$1" "$2" "$3" "$4"
    mkdir -p "$5"
    chown 0:0 "$5"
    chmod 0755 "$5"
    cp -p "$1/etc/.updated" "$4/.updated" 2>/dev/null || true
}

# The files that make up the machine's identity and accounts, relative to /etc.
IDENTITY_FILES="hostname hosts machine-id passwd shadow group gshadow subuid subgid"

# rebuild_layers <conf-mount>: fresh layers built beside the current ones as
# etc.new/ and var.new/ (swap_layers puts them in place): etc.new/ gets the
# current layer's IDENTITY_FILES verbatim (cp -p: owner, mode), var.new/ is
# empty (mount_var recreates the directory skeleton at boot). So every account — with its password, groups and ID range — and the
# hostname and machine-id stay exactly as they are; everything else goes. No
# .updated stamps: the ConditionNeedsUpdate= services (systemd-sysusers,
# ldconfig, …) run once on the next boot and bring the new layers up to date.
# The current layers are left as they are.
rebuild_layers() {
    # var.new first: sys.initramfs reads var.new without etc.new as a swap
    # in progress.
    rm -rf "$1/var.new" "$1/etc.new"
    [ -s "$1/etc/passwd" ] || return 1
    mkdir -m 0755 "$1/etc.new" "$1/var.new" || return 1
    chown 0:0 "$1/etc.new" "$1/var.new"
    for _f in $IDENTITY_FILES; do
        [ -e "$1/etc/$_f" ] || continue
        cp -p "$1/etc/$_f" "$1/etc.new/$_f" || return 1
    done
    sync
}

# swap_layers <conf-mount>: put etc.new/ and var.new/ in place (renames), with
# a fresh /etc workdir. If this is cut off, sys.initramfs finishes it at boot.
swap_layers() {
    for _d in etc var; do
        [ -d "$1/$_d.new" ] || return 1
    done
    for _d in etc var; do
        rm -rf "${1:?}/$_d.old"
        mv "$1/$_d" "$1/$_d.old" && mv "$1/$_d.new" "$1/$_d" || return 1
    done
    rm -rf "${1:?}/etc-work"
    mkdir -m 0700 "$1/etc-work"
    sync
    rm -rf "${1:?}/etc.old" "${1:?}/var.old"
    sync
}
