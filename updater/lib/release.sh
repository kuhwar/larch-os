# updater/lib/release.sh — list releases, download and check the image
# Sourced by update.sh; not executable on its own.

fetch() { curl -fsSL --cacert "$CA_BUNDLE" --connect-timeout 15 -A larch-update "$@"; }

# Print "<tag>\t<date>\t<size>\t<prerelease>\t<updater size or 0>" for the
# newest $RELEASES_SHOWN published releases that carry $ASSET and its
# checksum. No jq in the initramfs: the API's JSON is split at each release's
# own "url":".../releases/<id>" (assets' urls are .../releases/assets/<id>, and
# quotes inside release notes are escaped, so neither matches).
list_releases() {
    fetch -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$REPO/releases?per_page=30" -o "$RUN/releases.json" \
        || return 1
    awk -v max="$RELEASES_SHOWN" -v img="$ASSET" -v upd="$UPD_ASSET" '
        function field(s, k,   m) {
            if (!match(s, "\"" k "\" *: *\"[^\"]*\"")) return ""
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
                if (!has(r, img) || !has(r, img ".sha256")) continue
                size = asize(r, img); if (!size) continue
                tag = field(r, "tag_name"); if (tag == "") continue
                usize = has(r, upd ".sha256") ? asize(r, upd) : 0
                pre = (r ~ /"prerelease":true/) ? 1 : 0
                print tag "\t" substr(field(r, "published_at"), 1, 10) "\t" size "\t" pre "\t" usize
                c++
            }
        }' "$RUN/releases.json"
}

# Ask which release to install; sets REL_TAG, REL_SIZE and REL_UPD_SIZE.
choose_release() {
    while true; do
        msg "Releases" "Looking up Larch OS releases..."
        if ! list_releases > "$RUN/releases"; then
            dialog --backtitle "$DIALOG_BT" --title " Releases " \
                --yes-label "Retry" --no-label "Reboot" \
                --yesno "\nCould not reach GitHub to list the releases.\n\nIf the network is fine, check that the computer's clock is right (secure connections fail when it is far off)." 12 70 \
                || do_reboot
            continue
        fi
        [ -s "$RUN/releases" ] || die "No release of $REPO carries $ASSET."
        set --
        while IFS="$TAB" read -r _tag _date _size _pre _usize; do
            _d="$_date   $(( (_size + _usize) / 1048576 )) MB"
            [ "$_pre" = 1 ] && _d="$_d   pre-release"
            set -- "$@" "$_tag" "$_d"
        done < "$RUN/releases"
        dialog --backtitle "$DIALOG_BT" --title " Releases " \
            --ok-label "Select" --cancel-label "Reboot" \
            --menu "\nOnline via $NET_DESC.\n\nChoose the Larch OS release to install:" \
            17 70 "$RELEASES_SHOWN" "$@" 2>"$DIALOG_TMP" || do_reboot
        REL_TAG=$(cat "$DIALOG_TMP")
        REL_SIZE=$(awk -F'\t' -v t="$REL_TAG" '$1 == t { print $3 }' "$RUN/releases")
        REL_UPD_SIZE=$(awk -F'\t' -v t="$REL_TAG" '$1 == t { print $5 }' "$RUN/releases")
        return 0
    done
}

# Download <asset> of the chosen release to $DL_DIR and check it against its
# published .sha256, which is left in ASSET_SHA. Returns 1 (with a message
# shown) on failure. (Not via stdout: the dialogs draw there.)
# Usage: get_asset <asset> <size> <label>
get_asset() {
    _url="https://github.com/$REPO/releases/download/$REL_TAG/$1"
    if ! fetch -o "$DL_DIR/$1.sha256" "$_url.sha256"; then
        note "Download" "  Could not download $1.sha256 for $REL_TAG."; return 1
    fi
    _want=$(cut -d' ' -f1 < "$DL_DIR/$1.sha256" | tr 'A-F' 'a-f')
    if [ "${#_want}" -ne 64 ] || printf '%s' "$_want" | grep -q '[^0-9a-f]'; then
        note "Download" "  The published checksum of $1 is malformed."; return 1
    fi
    fetch --retry 3 -o "$DL_DIR/$1" "$_url" 2>"$RUN/curl.err" &
    _pid=$!
    progress "$_pid" "$2" "Download" "Downloading $3 ($REL_TAG)..." stat -c %s "$DL_DIR/$1"
    if ! wait "$_pid"; then
        note "Download" "  The download of $1 failed:\n  $(tail -1 "$RUN/curl.err" 2>/dev/null)"
        return 1
    fi
    msg "Download" "Checking $1..."
    if [ "$(sha256sum "$DL_DIR/$1" | cut -d' ' -f1)" != "$_want" ]; then
        note "Download" "  $1 is corrupt (checksum mismatch).\n  Nothing was written."
        return 1
    fi
    ASSET_SHA="$_want"
}

# Download the release into RAM ($DL_DIR, a tmpfs — never a partition).
# Sets IMG, WANT_SHA and NEW_UPDATER (empty if the release has none).
download_release() {
    IMG="$DL_DIR/$ASSET"
    NEW_UPDATER=""

    # Room for the image, the updater, and the kernel copied out of the image.
    _need=$(( REL_SIZE + REL_UPD_SIZE + 64 * 1048576 ))
    _avail=$(( $(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo) * 1024 ))
    if [ "$_avail" -lt $(( _need + 256 * 1048576 )) ]; then
        note "Not enough memory" "  The update is downloaded into memory first: it needs\n  $(( (_need + 256 * 1048576) / 1048576 )) MB free, this computer has $(( _avail / 1048576 )) MB."
        return 1
    fi
    umount "$DL_DIR" 2>/dev/null || true
    mount -t tmpfs -o "size=$_need,mode=0700" tmpfs "$DL_DIR" \
        || { note "Download" "  Could not set up the download area in memory."; return 1; }

    get_asset "$ASSET" "$REL_SIZE" "Larch OS" || return 1
    WANT_SHA="$ASSET_SHA"
    if [ "$REL_UPD_SIZE" -gt 0 ]; then
        get_asset "$UPD_ASSET" "$REL_UPD_SIZE" "the updater" || return 1
        NEW_UPDATER="$DL_DIR/$UPD_ASSET"
    fi
}

# Check the downloaded image is a Larch OS root that fits the system
# partition, take its kernel out (NEW_KERNEL; empty = keep the installed one),
# and check the release's updater has the drivers for that kernel — otherwise
# "Update LARCH" couldn't get online after this update.
check_image() {
    NEW_KERNEL=""
    if [ "$(head -c 4 "$IMG")" != hsqs ]; then
        note "Check" "  $ASSET is not a squashfs image."; return 1
    fi
    _img=$(stat -c %s "$IMG")
    _part=$(part_bytes "$TARGET_SYS")
    if [ "$_img" -gt "$_part" ]; then
        note "Check" "  This release ($(( _img / 1048576 )) MB) doesn't fit the system\n  partition ($(( _part / 1048576 )) MB). Reinstall from its ISO instead."
        return 1
    fi
    mount -t squashfs -o ro,loop "$IMG" "$NEW_MNT" \
        || { note "Check" "  Could not mount the downloaded image."; return 1; }
    if ! grep -qx 'ID=larchos' "$NEW_MNT/etc/os-release" 2>/dev/null; then
        umount "$NEW_MNT"; note "Check" "  The downloaded image is not Larch OS."; return 1
    fi
    # The image carries its kernel next to its modules (build stage 6); the
    # two must stay together, or the new root's modules won't load.
    _k=$(ls "$NEW_MNT"/usr/lib/modules/*/vmlinuz 2>/dev/null | tail -1)
    if [ -n "$_k" ]; then
        _kver="${_k%/vmlinuz}"; _kver="${_kver##*/}"
        NEW_KERNEL="$DL_DIR/vmlinuz"
        cp "$_k" "$NEW_KERNEL" || { umount "$NEW_MNT"; note "Check" "  Could not copy the new kernel."; return 1; }
    elif [ -d "$NEW_MNT/usr/lib/modules/$(uname -r)" ]; then
        _kver=$(uname -r)
    else
        umount "$NEW_MNT"
        note "Check" "  This release has a different kernel but doesn't carry it.\n  Reinstall from its ISO instead."
        return 1
    fi
    umount "$NEW_MNT"

    if [ -n "$NEW_UPDATER" ]; then
        if ! zcat "$NEW_UPDATER" 2>/dev/null | cpio -t 2>/dev/null | grep -q "usr/lib/modules/$_kver/"; then
            note "Check" "  The release's updater has no drivers for its kernel ($_kver)."
            return 1
        fi
    elif [ "$_kver" != "$(uname -r)" ]; then
        note "Check" "  This release has a new kernel ($_kver) but no updater built\n  for it. Reinstall from its ISO instead."
        return 1
    fi
}
