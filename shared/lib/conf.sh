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

# /etc is the image's, read-only: no overlay. What changes per machine or at
# runtime lives on LARCHCONF (/conf) instead:
#   ETC_LINKS  files directly under /etc, each a symlink in the image to
#              /conf/etc/<file> (system/build.sh stage 6). The image's own version
#              is kept in ETC_DEFAULTS and copied to /conf when /conf lacks it
#              (mount_etc). Writers that replace a file by rename can't work
#              through such a link; the ones that do (timedated, localed) are
#              pointed at /conf directly (SYSTEMD_ETC_* drop-ins).
#              localtime's default is stored with an absolute target
#              (/usr/share/zoneinfo/<zone>), as timedated writes it there.
#   ETC_DIRS   directories bind-mounted from /conf/etc/<dir>, seeded with a
#              copy of the image's on first use (later updates don't change
#              that copy).
# The accounts are in the LDAP directory (/conf/ldap), so passwd, group and
# shadow are the image's system accounts only.
ETC_LINKS="hostname hosts machine-id subuid subgid localtime adjtime locale.conf vconsole.conf printcap .pwd.lock"
ETC_DIRS="cups bluetooth X11/xorg.conf.d"
ETC_DEFAULTS=usr/lib/larch/etc

# mount_etc <root> <conf-mount>: complete /conf with the image's defaults of
# ETC_LINKS and ETC_DIRS it lacks, then bind ETC_DIRS on <root>/etc/<dir>.
mount_etc() {
    mkdir -p "$2/etc" || return 1
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

# Write this machine's identity files into <out-dir> (LARCHCONF's etc/, where
# the image's /etc links point): hostname, hosts, machine-id from
# <config-dir>, and the user's subordinate ID range (rootless containers)
# appended to the image's subuid/subgid. Each starts as a cp -p of the image's
# default (ETC_DEFAULTS), so it keeps its owner and mode.
# The accounts themselves are in the LDAP directory (ldap_create).
# Usage: apply_machine_config <image-root> <config-dir> <username> <out-dir>
apply_machine_config() {
    _root="$1"; _cfg="$2"; _user="$3"; _out="$4"

    mkdir -p "$_out"
    chown 0:0 "$_out"
    chmod 0755 "$_out"
    for _f in hostname hosts machine-id; do
        cp -p "$_root/$ETC_DEFAULTS/$_f" "$_out/$_f"
        cat "$_cfg/$_f" > "$_out/$_f"
    done
    for _f in subuid subgid; do
        cp -p "$_root/$ETC_DEFAULTS/$_f" "$_out/$_f"
        printf '%s:524288:65536\n' "$_user" >> "$_out/$_f"
    done
    unset _root _cfg _user _out _f
}

# ldap_create <image-root> <conf-mount> <ldif>: the account directory's
# database, /conf/ldap on LARCHCONF, created from <ldif> with the image's own
# slapadd and slapd.conf (chrooted into <image-root>, LARCHCONF bound on its
# /conf), owned by the image's ldap user.
ldap_create() {
    rm -rf "${2:?}/ldap"
    mkdir -m 0700 "$2/ldap" || return 1
    cp "$3" "$2/.seed.ldif" || return 1
    mount --bind "$2" "$1/conf" || return 1
    mount --bind /dev "$1/dev" || { umount "$1/conf"; return 1; }
    chroot "$1" /usr/sbin/slapadd -q -f /etc/openldap/slapd.conf -l /conf/.seed.ldif \
        && chroot "$1" chown -R ldap:ldap /conf/ldap
    _rc=$?
    umount "$1/dev" 2>/dev/null || true
    umount "$1/conf" 2>/dev/null || true
    rm -f "$2/.seed.ldif"
    [ -f "$2/ldap/data.mdb" ] && return $_rc
    return 1
}

# seed_layers <image-root> <config-dir> <username> <etc-out> <var-out>
# A fresh LARCHCONF for <image-root>: the identity files in <etc-out> and an
# empty <var-out> (mount_etc and mount_var add the image's defaults and
# directory skeleton at boot).
seed_layers() {
    apply_machine_config "$1" "$2" "$3" "$4"
    mkdir -p "$5"
    chown 0:0 "$5"
    chmod 0755 "$5"
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
