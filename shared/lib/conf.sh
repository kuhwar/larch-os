# shared/lib/conf.sh — LARCHCONF's /etc and /var layers
# Sourced by the installer and the updater; not executable on its own.
#
# LARCHCONF (mounted at /conf on the running system) holds the upper layers of
# the /etc and /var overlays that sys.initramfs mounts: etc/ + etc-work/,
# var/ + var-work/. The installer creates them (seed_layers). Updates leave
# them alone, desktop switches included. "Reset LARCH OS" (Manage LARCH)
# replaces them with layers holding nothing but the machine's identity and
# accounts (rebuild_layers + swap_layers).

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

# The files that make up the machine's identity and accounts, relative to /etc.
IDENTITY_FILES="hostname hosts machine-id passwd shadow group gshadow subuid subgid"

# rebuild_layers <conf-mount>: fresh layers built beside the current ones as
# etc.new/ and var.new/ (swap_layers puts them in place): etc.new/ gets the
# current layer's IDENTITY_FILES verbatim (cp -p: owner, mode), var.new/ is
# empty. So every account — with its password, groups and ID range — and the
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
