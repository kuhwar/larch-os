# shared/lib/release.sh — list Larch OS releases, download, check, install
# Sourced by the installer and the updater (after ui.sh and hw.sh); not
# executable on its own.
#
# A system release (.github/workflows/build-system.yml, tag v*) is a GitHub
# release carrying these files, all built from the same base rootfs:
#
#   sys-<desktop>.squashfs  one OS root per desktop (gnome, kde, …) → LARCHSYS:/sys.squashfs
#   vmlinuz                 Debian's kernel          → LARCHEFI:/larch-os/vmlinuz
#   sys.initramfs           boots the system         → LARCHEFI:/larch-os/sys.initramfs
#   updater.initramfs       the "Update LARCH" entry → LARCHEFI:/larch-os/updater.initramfs
#   BOOTX64.EFI             systemd-boot             → LARCHEFI:/EFI/BOOT/BOOTX64.EFI
#   loader.tar              loader/loader.conf + loader/entries/*.conf → LARCHEFI:/loader/
#   SHA256SUMS              sha256sum of all of them
#
# Each (release, desktop) pair is offered as "larch-<desktop>-<tag>", e.g.
# larch-gnome-v0.1.5. The bootloader and its entries are release files of
# their own (not inside the images, which stay lean), shared by every desktop
# of the release, so they always match the kernel and initramfs they boot.
#
# For testing, a plain HTTP directory holding those files can stand in for
# GitHub: larch.source=<url> on the kernel command line, or the QEMU fw_cfg
# entry opt/larch/source (test-qemu.sh --local). Its images are offered as
# larch-<desktop>-local.

REPO="kuhwar/larch-os"
RELEASES_SHOWN=5
CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
DEFAULT_DESKTOP=gnome

SUMS=SHA256SUMS
KERNEL=vmlinuz
SYS_INITRD=sys.initramfs
UPD_INITRD=updater.initramfs
BOOT_EFI=BOOTX64.EFI
LOADER=loader.tar
SYS_IMG=""              # sys-<desktop>.squashfs of the chosen entry

NEW_MNT="$RUN/new"      # a downloaded image, loop-mounted for checks
mkdir -p "$NEW_MNT"

fetch() { curl -fsSL --cacert "$CA_BUNDLE" --connect-timeout 15 -A larch-os "$@"; }

local_source() {
    _s=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^larch\.source=//p' | tail -1)
    [ -n "$_s" ] || _s=$(cat /sys/firmware/qemu_fw_cfg/by_name/opt/larch/source/raw 2>/dev/null || true)
    echo "${_s%/}"
}

# Write one line per (release, desktop) to $RUN/releases:
#   <name> <tag> <desktop> <date> <prerelease> <img> <kernel> <sys-initrd>
#   <upd-initrd> <efi> <loader>
# (tab-separated, sizes in bytes; name = larch-<desktop>-<tag>) for the newest
# $RELEASES_SHOWN published releases that carry the kernel, both initramfs,
# the bootloader, its entries, SHA256SUMS and at least one
# sys-<desktop>.squashfs (so releases up to v0.5.1, which kept the bootloader
# inside the image, are not offered). No jq in the initramfs:
# the API's JSON is split at each release's own "url":".../releases/<id>"
# (assets' urls are .../releases/assets/<id>, and quotes inside release notes
# are escaped, so neither matches).
list_releases() {
    LOCAL_SOURCE=$(local_source)
    if [ -n "$LOCAL_SOURCE" ]; then
        fetch -o "$RUN/local.sums" "$LOCAL_SOURCE/$SUMS" || return 1
        sed -n 's/^[0-9a-f]*  *\*\{0,1\}sys-\([a-z0-9]*\)\.squashfs$/\1/p' "$RUN/local.sums" | sort \
            | while read -r _de; do
                printf 'larch-%s-local\tlocal\t%s\t%s\t0\t0\t0\t0\t0\t0\t0\n' "$_de" "$_de" "$LOCAL_SOURCE"
            done > "$RUN/releases"
        return 0
    fi
    fetch -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$REPO/releases?per_page=30" -o "$RUN/releases.json" \
        || return 1
    awk -v max="$RELEASES_SHOWN" -v sums="$SUMS" -v k="$KERNEL" \
        -v si="$SYS_INITRD" -v ui="$UPD_INITRD" -v be="$BOOT_EFI" -v bl="$LOADER" '
        function field(s, key,   m) {
            if (!match(s, "\"" key "\" *: *\"[^\"]*\"")) return ""
            m = substr(s, RSTART, RLENGTH)
            sub(/^"[^"]*" *: *"/, "", m); sub(/"$/, "", m)
            return m
        }
        function has(s, name) { return index(s, "\"name\":\"" name "\"") > 0 }
        # Size of asset <name> (0 if absent): the first "size" after its name.
        function asize(s, name,   p, a) {
            p = index(s, "\"name\":\"" name "\""); if (!p) return 0
            a = substr(s, p)
            if (!match(a, /"size":[0-9]+/)) return 0
            return substr(a, RSTART + 7, RLENGTH - 7)
        }
        { buf = buf $0 }
        END {
            gsub(/": +/, "\":", buf)   # tolerate pretty-printed JSON
            n = split(buf, rel, /"url":"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/[0-9]+"/)
            c = 0
            for (i = 2; i <= n && c < max; i++) {
                r = rel[i]
                if (r ~ /"draft":true/) continue
                if (!has(r, sums) || !asize(r, k) || !asize(r, si) || !asize(r, ui) \
                    || !asize(r, be) || !asize(r, bl)) continue
                tag = field(r, "tag_name"); if (tag == "") continue
                pre = (r ~ /"prerelease":true/) ? 1 : 0
                date = substr(field(r, "published_at"), 1, 10)
                # Every sys-<desktop>.squashfs asset, in name order.
                nd = 0; rest = r
                while (match(rest, /"name":"sys-[a-z0-9]+\.squashfs"/)) {
                    d = substr(rest, RSTART + 12, RLENGTH - 22)
                    rest = substr(rest, RSTART + RLENGTH)
                    if (!(d in seen)) { seen[d] = 1; des[++nd] = d }
                }
                for (x = 1; x <= nd; x++)
                    for (y = x + 1; y <= nd; y++)
                        if (des[y] < des[x]) { t = des[x]; des[x] = des[y]; des[y] = t }
                got = 0
                for (x = 1; x <= nd; x++) {
                    d = des[x]; img = asize(r, "sys-" d ".squashfs")
                    if (img) {
                        print "larch-" d "-" tag "\t" tag "\t" d "\t" date "\t" pre "\t" \
                              img "\t" asize(r, k) "\t" asize(r, si) "\t" asize(r, ui) "\t" \
                              asize(r, be) "\t" asize(r, bl)
                        got = 1
                    }
                }
                for (d in seen) delete seen[d]
                if (got) c++
            }
        }' "$RUN/releases.json" > "$RUN/releases"
}

# Fill $RUN/releases, asking to retry while GitHub can't be reached.
lookup_releases() {
    while true; do
        msg "Releases" "Looking up Larch OS releases..."
        if list_releases; then
            [ -s "$RUN/releases" ] || die "No release of $REPO carries the Larch OS system files."
            return 0
        fi
        dialog --backtitle "$DIALOG_BT" --title " Releases " \
            --yes-label "Retry" --no-label "Reboot" \
            --yesno "\nCould not reach GitHub to list the releases.\n\nIf the network is fine, check that the computer's clock is right (secure connections fail when it is far off)." 12 70 \
            || do_reboot
    done
}

# select_release <name>: REL_NAME, REL_TAG, REL_DESKTOP, REL_DATE, SYS_IMG,
# REL_IMG_SIZE, REL_BOOT_SIZE (kernel, both initramfs, bootloader, entries) and REL_SIZE
# (everything) from $RUN/releases.
select_release() {
    _line=$(awk -F'\t' -v n="$1" '$1 == n { print; exit }' "$RUN/releases")
    [ -n "$_line" ] || return 1
    REL_NAME="$1"
    REL_TAG=$(echo "$_line" | cut -f2)
    REL_DESKTOP=$(echo "$_line" | cut -f3)
    REL_DATE=$(echo "$_line" | cut -f4)
    REL_IMG_SIZE=$(echo "$_line" | cut -f6)
    REL_BOOT_SIZE=$(echo "$_line" | awk -F'\t' '{ print $7 + $8 + $9 + $10 + $11 }')
    REL_SIZE=$(( REL_IMG_SIZE + REL_BOOT_SIZE ))
    SYS_IMG="sys-$REL_DESKTOP.squashfs"
}

# default_release [desktop]: the entry a menu starts on — the newest
# non-pre-release of <desktop> (default $DEFAULT_DESKTOP), else of any desktop,
# else the newest entry.
default_release() {
    awk -F'\t' -v d="${1:-$DEFAULT_DESKTOP}" '
        NR == 1 { first = $1 }
        $5 == 0 && $3 == d && !m1 { m1 = $1 }
        $5 == 0 && !m2 { m2 = $1 }
        END { print (m1 ? m1 : (m2 ? m2 : first)) }' "$RUN/releases"
}

# choose_release <installed-name> <default-name> <cancel-label>: menu of every
# listed entry (larch-<desktop>-<tag>); the installed one is marked. Cancel
# reboots.
choose_release() {
    set -- "$1" "$2" "$3"
    _installed="$1"; _default="$2"; _cancel="$3"
    _n=$(wc -l < "$RUN/releases")
    _h=$_n; [ "$_h" -le 12 ] || _h=12
    set --
    while IFS="$TAB" read -r _name _tag _de _date _pre _img _k _si _ui _be _bl; do
        if [ "$_tag" = local ]; then
            _d="local build"
        else
            _d="$_date   $(( (_img + _k + _si + _ui + _be + _bl) / 1048576 )) MB"
        fi
        [ "$_pre" = 1 ] && _d="$_d   pre-release"
        [ "$_name" = "$_installed" ] && _d="$_d   (installed)"
        set -- "$@" "$_name" "$_d"
    done < "$RUN/releases"
    dialog --backtitle "$DIALOG_BT" --title " Larch OS " \
        --ok-label "Select" --cancel-label "$_cancel" --default-item "$_default" \
        --menu "\nOnline via $NET_DESC.\n\nChoose the Larch OS desktop and version to install:" \
        $(( _h + 9 )) 72 "$_h" "$@" 2>"$DIALOG_TMP" || do_reboot
    select_release "$(cat "$DIALOG_TMP")"
}

release_url() {
    if [ "$REL_TAG" = local ]; then
        echo "$LOCAL_SOURCE/$1"
    else
        echo "https://github.com/$REPO/releases/download/$REL_TAG/$1"
    fi
}

# get_asset <file> <dir> <size> <label>: download <file> of the chosen release
# into <dir> and check it, as read back from the disk, against SHA256SUMS.
# Returns 1 (with a message shown) on failure. (Not via stdout: the dialogs
# draw there.)
get_asset() {
    _want=$(awk -v f="$1" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1; exit }' "$2/$SUMS" | tr 'A-F' 'a-f')
    if [ "${#_want}" -ne 64 ] || printf '%s' "$_want" | grep -q '[^0-9a-f]'; then
        note "Download" "  $SUMS of $REL_TAG has no valid checksum for $1."; return 1
    fi
    rm -f "$2/$1"
    fetch --retry 3 -o "$2/$1" "$(release_url "$1")" 2>"$RUN/curl.err" &
    _pid=$!
    progress "$_pid" "$3" "Download" "Downloading $4 ($REL_NAME)..." stat -c %s "$2/$1"
    if ! wait "$_pid"; then
        note "Download" "  The download of $1 failed:\n  $(tail -1 "$RUN/curl.err" 2>/dev/null)"
        return 1
    fi
    msg "Download" "Checking $1..."
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    if [ "$(sha256sum "$2/$1" | cut -d' ' -f1)" != "$_want" ]; then
        note "Download" "  $1 is corrupt (checksum mismatch)."
        return 1
    fi
}

# download_release <dir>: all files of the chosen release into <dir>.
download_release() {
    mkdir -p "$1"
    if ! fetch -o "$1/$SUMS" "$(release_url "$SUMS")" 2>"$RUN/curl.err"; then
        note "Download" "  Could not download $SUMS for $REL_TAG:\n  $(tail -1 "$RUN/curl.err" 2>/dev/null)"
        return 1
    fi
    _sz() { awk -F'\t' -v n="$REL_NAME" -v c="$1" '$1 == n { print $c }' "$RUN/releases"; }
    get_asset "$SYS_IMG"    "$1" "$(_sz 6)" "$REL_DESKTOP"       || return 1
    get_asset "$KERNEL"     "$1" "$(_sz 7)" "the kernel"         || return 1
    get_asset "$SYS_INITRD" "$1" "$(_sz 8)" "the boot initramfs" || return 1
    get_asset "$UPD_INITRD" "$1" "$(_sz 9)" "the updater"        || return 1
    get_asset "$BOOT_EFI"   "$1" "$(_sz 10)" "the bootloader"    || return 1
    get_asset "$LOADER"     "$1" "$(_sz 11)" "the boot entries"  || return 1
}

# The kernel an initramfs carries modules for.
initrd_kver() {
    zcat "$1" 2>/dev/null | cpio -t 2>/dev/null \
        | sed -n 's|^usr/lib/modules/\([^/]*\)/.*|\1|p' | head -1
}

# check_release <dir>: the downloaded files form a working Larch OS — the
# image is a Larch OS root, and both initramfs and the image's modules are for
# the same kernel (the release's vmlinuz). Lays the bootloader and the loader
# entries out under <dir>/boot/ as they go on LARCHEFI (install_boot_files).
# Sets NEW_KVER and NEW_VERSION. Leaves the image mounted at $NEW_MNT for the
# caller (umount it when done).
check_release() {
    msg "Check" "Checking the downloaded release..."
    if [ "$(head -c 4 "$1/$SYS_IMG")" != hsqs ]; then
        note "Check" "  $SYS_IMG is not a squashfs image."; return 1
    fi
    if [ "$(head -c 2 "$1/$BOOT_EFI")" != MZ ]; then
        note "Check" "  $BOOT_EFI is not an EFI program."; return 1
    fi
    # Only loader/loader.conf and loader/entries/*.conf, nothing that could
    # land outside <dir>/boot.
    if tar -tf "$1/$LOADER" 2>/dev/null | grep -qvE '^loader/(loader[.]conf|entries/|entries/[A-Za-z0-9._-]+[.]conf)?$'; then
        note "Check" "  $LOADER holds files other than the boot entries."; return 1
    fi
    rm -rf "$1/boot"
    mkdir -p "$1/boot/EFI/BOOT"
    if ! tar -xf "$1/$LOADER" -C "$1/boot" 2>/dev/null \
        || [ ! -f "$1/boot/loader/loader.conf" ] \
        || ! ls "$1/boot/loader/entries/"*.conf >/dev/null 2>&1; then
        note "Check" "  $LOADER does not carry loader.conf and the boot entries."; return 1
    fi
    cp "$1/$BOOT_EFI" "$1/boot/EFI/BOOT/BOOTX64.EFI" \
        || { note "Check" "  Could not stage the bootloader."; return 1; }
    NEW_KVER=$(initrd_kver "$1/$SYS_INITRD")
    if [ -z "$NEW_KVER" ]; then
        note "Check" "  $SYS_INITRD carries no kernel modules."; return 1
    fi
    if [ "$(initrd_kver "$1/$UPD_INITRD")" != "$NEW_KVER" ]; then
        note "Check" "  $UPD_INITRD was not built for the release's kernel ($NEW_KVER)."; return 1
    fi
    mount -t squashfs -o ro,loop "$1/$SYS_IMG" "$NEW_MNT" \
        || { note "Check" "  Could not mount the downloaded image."; return 1; }
    _err=""
    grep -qx 'ID=larchos' "$NEW_MNT/etc/os-release" 2>/dev/null \
        || _err="The downloaded image is not Larch OS."
    [ -n "$_err" ] || [ "$(cat "$NEW_MNT/usr/lib/larch/desktop" 2>/dev/null)" = "$REL_DESKTOP" ] \
        || _err="$SYS_IMG is not a $REL_DESKTOP image."
    [ -n "$_err" ] || [ -d "$NEW_MNT/usr/lib/modules/$NEW_KVER" ] \
        || _err="The image has no modules for the release's kernel ($NEW_KVER)."
    NEW_VERSION=$(cat "$NEW_MNT/usr/lib/larch/version" 2>/dev/null || echo "$REL_TAG")
    [ -z "$_err" ] || { umount "$NEW_MNT"; note "Check" "  $_err"; return 1; }
}

# install_boot_files <dir> <efi-mount>: the kernel, both initramfs, the
# bootloader and its entries from <dir> onto LARCHEFI. Everything is copied
# beside the old files first, then renamed into place (FAT renames are as
# close to atomic as it gets), so a failure while copying leaves the old set
# working. Entries that the new release no longer has are removed.
install_boot_files() {
    _src="$1"; _efi="$2"
    mkdir -p "$_efi/larch-os" "$_efi/EFI/BOOT" "$_efi/loader/entries"
    _pairs="$_src/$KERNEL:larch-os/vmlinuz
$_src/$SYS_INITRD:larch-os/sys.initramfs
$_src/$UPD_INITRD:larch-os/updater.initramfs
$_src/boot/EFI/BOOT/BOOTX64.EFI:EFI/BOOT/BOOTX64.EFI
$_src/boot/loader/loader.conf:loader/loader.conf"
    for _e in "$_src"/boot/loader/entries/*.conf; do
        [ -f "$_e" ] && _pairs="$_pairs
$_e:loader/entries/${_e##*/}"
    done
    _ok=1
    for _p in $_pairs; do
        cp "${_p%%:*}" "$_efi/${_p#*:}.new" || { _ok=0; break; }
    done
    sync
    if [ "$_ok" -eq 1 ]; then
        for _p in $_pairs; do
            mv -f "$_efi/${_p#*:}.new" "$_efi/${_p#*:}" || _ok=0
        done
        for _e in "$_efi"/loader/entries/*.conf; do
            [ -f "$_e" ] && [ ! -f "$_src/boot/loader/entries/${_e##*/}" ] && rm -f "$_e"
        done
        sync
    fi
    for _p in $_pairs; do rm -f "$_efi/${_p#*:}.new"; done
    [ "$_ok" -eq 1 ]
}
