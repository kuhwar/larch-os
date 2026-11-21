# shared/lib/conf.sh — what LARCHCONF holds for /etc and /var
# Sourced by sys.initramfs, the installer, the updater and system/build.sh
# (stage 6); not executable on its own.
#
# LARCHCONF (mounted at /conf on the running system) holds:
#   etc-overlay/ + etc-overlay-work/
#                 the upper layer of the /etc overlay — the accounts only
#                 (ACCOUNT_FILES), plus /etc/.updated and the account tools'
#                 lock and backup files
#   etc/          the files the image's /etc links to (ETC_LINKS) and the
#                 directories bind-mounted on /etc's (ETC_DIRS)
#   var/          /var's writable directories (VAR_DIRS): var/lib, var/log,
#                 var/cache and var/spool, bind-mounted over the image's
#                 (mount_var). The rest of /var is the read-only image.
# The installer creates them (seed_layers). Updates leave them alone, desktop
# switches included. "Reset LARCH OS" (Manage LARCH) replaces them with
# layers holding nothing but the machine's identity and accounts
# (rebuild_layers + swap_layers).

# /etc is the image's, with an overlay whose upper layer only the account
# tools write to: passwd, useradd, usermod, chpasswd, accounts-daemon and
# pam_unix replace those files by rename, which needs a writable /etc. Same
# options everywhere (sys/init, manage.sh, fstab): the lower layer is replaced
# by every update, so nothing in the upper layer may point into a particular
# squashfs — index (records the lower root's file handle and refuses to mount
# once it changes: "Stale file handle"), metacopy (metadata-only copy-ups
# whose data stays in the old lower layer) and redirect_dir (renamed
# directories referring to lower paths) are all off, whatever the kernel's
# defaults.
OVL_OPTS="index=off,metacopy=off,redirect_dir=off"
ACCOUNT_FILES="passwd shadow group gshadow subuid subgid"

# Everything else in /etc that changes per machine or at runtime lives in
# LARCHCONF:/etc instead, so nothing else lands in the overlay:
#   ETC_LINKS  files directly under /etc, each a symlink in the image to
#              /conf/etc/<file> (system/build.sh stage 6). The image's own
#              version is kept in ETC_DEFAULTS and copied to /conf/etc when it
#              lacks it (mount_etc). Writers that replace a file by rename
#              would put a file in the overlay instead; the ones that do
#              (timedated, localed) are pointed at /conf/etc directly
#              (SYSTEMD_ETC_* drop-ins). localtime's default is stored with an
#              absolute target (/usr/share/zoneinfo/<zone>), as timedated
#              writes it there.
#   ETC_DIRS   directories bind-mounted from /conf/etc/<dir>, seeded with a
#              copy of the image's on first use (later updates don't change
#              that copy).
ETC_LINKS="hostname hosts machine-id localtime adjtime locale.conf vconsole.conf printcap"
ETC_DIRS="cups bluetooth X11/xorg.conf.d"
ETC_DEFAULTS=usr/lib/larch/etc

# mount_etc <root> <conf-mount>: the /etc overlay (LARCHCONF's etc-overlay
# on the image's /etc), then LARCHCONF:/etc completed with the image's
# defaults of ETC_LINKS and ETC_DIRS it lacks, and ETC_DIRS bound on
# <root>/etc/<dir>.
mount_etc() {
    mkdir -p "$2/etc-overlay" "$2/etc-overlay-work" "$2/etc" || return 1
    mount -t overlay overlay \
        -o "lowerdir=$1/etc,upperdir=$2/etc-overlay,workdir=$2/etc-overlay-work,$OVL_OPTS" \
        "$1/etc" || return 1
    for _f in $ETC_LINKS; do
        [ -e "$2/etc/$_f" ] || [ -L "$2/etc/$_f" ] && continue
        [ -e "$1/$ETC_DEFAULTS/$_f" ] || [ -L "$1/$ETC_DEFAULTS/$_f" ] || continue
        cp -Pp "$1/$ETC_DEFAULTS/$_f" "$2/etc/$_f" || return 1
    done
    for _d in $ETC_DIRS; do
        [ -d "$1/etc/$_d" ] || continue
        if [ ! -d "$2/etc/$_d" ]; then
            mkdir -p "$(dirname "$2/etc/$_d")" || return 1
            cp -a "$1/etc/$_d" "$2/etc/$_d" || return 1
        fi
        mount --bind "$2/etc/$_d" "$1/etc/$_d" || return 1
    done
    unset _f _d
}

# umount_etc <root>: undo mount_etc.
umount_etc() {
    for _d in $ETC_DIRS; do
        umount "$1/etc/$_d" 2>/dev/null || umount -l "$1/etc/$_d" 2>/dev/null || true
    done
    umount "$1/etc" 2>/dev/null || umount -l "$1/etc" 2>/dev/null || true
    unset _d
}

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

# apply_machine_config <image-root> <config-dir> <username> <conf-mount>
# This machine's identity, from <config-dir> (hostname, hosts, machine-id,
# and passwd/shadow with the user's single line each):
#   <conf-mount>/etc/         hostname, hosts, machine-id — each a cp -p of
#                             the image's default (ETC_DEFAULTS), rewritten
#   <conf-mount>/etc-overlay/ the account files (ACCOUNT_FILES), with the user
#                             in place of the image's UID-1000 placeholder
#                             "larch". Each starts as a cp -p of the image's
#                             file and is rewritten with `cat >`, so it keeps
#                             the image's owner and mode (e.g. shadow:
#                             root:shadow 0640) — the same result as an
#                             overlay copy-up.
apply_machine_config() {
    _root="$1"; _cfg="$2"; _user="$3"; _etc="$4/etc"; _ovl="$4/etc-overlay"

    for _d in "$_etc" "$_ovl"; do
        mkdir -p "$_d"
        chown 0:0 "$_d"
        chmod 0755 "$_d"
    done
    for _f in hostname hosts machine-id; do
        cp -p "$_root/$ETC_DEFAULTS/$_f" "$_etc/$_f"
        cat "$_cfg/$_f" > "$_etc/$_f"
    done
    for _f in $ACCOUNT_FILES; do
        cp -p "$_root/etc/$_f" "$_ovl/$_f"
    done

    # passwd: drop any UID-1000 line, append the user.
    grep -v '^[^:]*:[^:]*:1000:' "$_root/etc/passwd" > "$_cfg/passwd.new" || true
    cat "$_cfg/passwd" >> "$_cfg/passwd.new"
    cat "$_cfg/passwd.new" > "$_ovl/passwd"
    # shadow: drop the placeholder's entry, append the user's.
    grep -v "^larch:\|^${_user}:" "$_root/etc/shadow" > "$_cfg/shadow.new" || true
    cat "$_cfg/shadow" >> "$_cfg/shadow.new"
    cat "$_cfg/shadow.new" > "$_ovl/shadow"
    rm -f "$_cfg/passwd.new" "$_cfg/shadow.new"

    if [ "$_user" != "larch" ]; then
        # Group memberships (word-boundary-safe) and the subordinate ID range
        # for rootless containers move to the username.
        for _f in group gshadow; do
            sed "s/\blarch\b/$_user/g" "$_root/etc/$_f" > "$_cfg/$_f.new"
            cat "$_cfg/$_f.new" > "$_ovl/$_f"
            rm -f "$_cfg/$_f.new"
        done
        for _f in subuid subgid; do
            sed "s/^larch:/$_user:/" "$_root/etc/$_f" > "$_cfg/$_f.new"
            cat "$_cfg/$_f.new" > "$_ovl/$_f"
            rm -f "$_cfg/$_f.new"
        done
    fi
    unset _root _cfg _user _etc _ovl _f _d
}

# seed_layers <image-root> <config-dir> <username> <conf-mount>
# A fresh LARCHCONF for <image-root>: the identity and account files
# (apply_machine_config), the image's /etc "up to date" stamp in the overlay
# — so ConditionNeedsUpdate=/etc (systemd-sysusers) doesn't run on the first
# boot but does once after each update, whose image has a newer /usr, adding
# the new release's system accounts — an empty overlay workdir and an empty
# var/ (mount_etc and mount_var add the image's defaults and directory
# skeleton at boot).
seed_layers() {
    apply_machine_config "$1" "$2" "$3" "$4"
    cp -p "$1/etc/.updated" "$4/etc-overlay/.updated" 2>/dev/null || true
    mkdir -p -m 0700 "$4/etc-overlay-work"
    mkdir -p "$4/var"
    chown 0:0 "$4/var"
    chmod 0755 "$4/var"
}

# Reset's layers, swapped in this order. The first one is the marker: while
# its .new exists, the swap hasn't started (finish_swap leaves the others
# alone); once it is gone, any other .new still there is part of a swap that
# was cut off. So rebuild_layers deletes the others' .new before the
# marker's and creates the marker's first.
LAYERS="etc-overlay etc var"

# rebuild_layers <conf-mount>: fresh layers built beside the current ones as
# <layer>.new/ (swap_layers puts them in place): etc-overlay.new/ gets the
# current ACCOUNT_FILES verbatim (cp -p: owner, mode), etc.new/ the hostname,
# hosts and machine-id, var.new/ is empty (mount_etc and mount_var recreate
# the rest at boot). So every account — with its password, groups and ID
# range — and the machine's identity stay exactly as they are; everything
# else goes. No .updated stamp: systemd-sysusers runs once on the next boot.
# The current layers are left as they are.
rebuild_layers() {
    rm -rf "$1/var.new" "$1/etc.new" "$1/etc-overlay.new"
    [ -s "$1/etc-overlay/passwd" ] || return 1
    for _l in $LAYERS; do
        mkdir -m 0755 "$1/$_l.new" || return 1
        chown 0:0 "$1/$_l.new"
    done
    for _f in $ACCOUNT_FILES; do
        [ -e "$1/etc-overlay/$_f" ] || continue
        cp -p "$1/etc-overlay/$_f" "$1/etc-overlay.new/$_f" || return 1
    done
    for _f in hostname hosts machine-id; do
        [ -e "$1/etc/$_f" ] || continue
        cp -p "$1/etc/$_f" "$1/etc.new/$_f" || return 1
    done
    unset _l _f
    sync
}

# swap_layers <conf-mount>: put the .new layers in place (renames, the
# marker first), with a fresh overlay workdir. If this is cut off,
# finish_swap completes it at boot.
swap_layers() {
    for _l in $LAYERS; do
        [ -d "$1/$_l.new" ] || return 1
    done
    for _l in $LAYERS; do
        rm -rf "${1:?}/$_l.old"
        mv "$1/$_l" "$1/$_l.old" && mv "$1/$_l.new" "$1/$_l" || return 1
    done
    rm -rf "${1:?}/etc-overlay-work"
    mkdir -m 0700 "$1/etc-overlay-work"
    sync
    for _l in $LAYERS; do
        rm -rf "${1:?}/$_l.old"
    done
    unset _l
    sync
}

# finish_swap <conf-mount>: complete a swap_layers that was cut off (sys/init,
# before mounting anything): a layer renamed away but its .new not yet in
# place, and — once the marker is swapped — the remaining layers.
finish_swap() {
    for _l in $LAYERS; do
        if [ ! -d "$1/$_l" ] && [ -d "$1/$_l.new" ]; then
            mv "$1/$_l.new" "$1/$_l" || return 1
        fi
    done
    _m=${LAYERS%% *}
    if [ ! -d "$1/$_m.new" ]; then
        for _l in $LAYERS; do
            [ -d "$1/$_l.new" ] || continue
            rm -rf "${1:?}/$_l.old"
            mv "$1/$_l" "$1/$_l.old" && mv "$1/$_l.new" "$1/$_l" || return 1
        done
    fi
    for _l in $LAYERS; do
        rm -rf "${1:?}/$_l.old"
    done
    unset _l _m
}
