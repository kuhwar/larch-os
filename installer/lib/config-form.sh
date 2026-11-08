# installer/lib/config-form.sh — three-step interactive configuration prompts
# Sourced by install.sh; not executable on its own.

# Three sequential prompts — one per field — so Enter always advances to the
# next field rather than jumping to the OK button (a --mixedform limitation).
form_config() {
    local _pw2

    # ── Full name ─────────────────────────────────────────────────────────────
    # The username and hostname are derived from it (see derive_username).
    while true; do
        : > "$DIALOG_TMP"
        dialog --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (1/3) " \
            --inputbox "Full name  (e.g. Jane Doe):" 8 60 "$LARCH_FULLNAME" \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        # ':' and ',' are field/sub-field separators in /etc/passwd's GECOS
        # field; drop them and control characters, then trim surrounding blanks.
        LARCH_FULLNAME=$(tr -d ':,\000-\037\177' < "$DIALOG_TMP" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ -z "$LARCH_FULLNAME" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Full name cannot be empty." 5 40
            continue
        fi
        break
    done

    # ── Password + confirm ────────────────────────────────────────────────────
    while true; do
        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (2/3) " \
            --passwordbox "Password:" 8 60 \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        LARCH_PASSWORD=$(cat "$DIALOG_TMP")

        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Continue" \
            --backtitle "$DIALOG_BT" --title " System Configuration (3/3) " \
            --passwordbox "Confirm password:" 8 60 \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        _pw2=$(cat "$DIALOG_TMP")

        if [ -z "$LARCH_PASSWORD" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Password cannot be empty." 5 40
            continue
        fi
        if [ "$LARCH_PASSWORD" != "$_pw2" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Passwords do not match." 5 40
            continue
        fi
        break
    done

    derive_username
    derive_hostname
}

# Username = full name lowercased with everything but a-z/0-9 removed
# ("Jane Doe" -> janedoe). Common accented Latin letters are folded to
# ASCII first (sed works byte-wise on the UTF-8 sequences, so each is listed
# literally). The result matches Debian's ^[a-z][a-z0-9]*$, capped at 32 chars.
# Names already used by the image's system accounts/groups ($RESERVED_NAMES:
# generated at build time, and again from the downloaded image before the
# account is written) get a numeric suffix: "Root" -> root1.
derive_username() {
    local _base _n

    _base=$(printf '%s' "$LARCH_FULLNAME" | sed -E \
        -e 's/(À|Á|Â|Ã|Ä|Å|à|á|â|ã|ä|å|Ą|ą)/a/g' \
        -e 's/(Æ|æ)/ae/g' \
        -e 's/(Ç|ç|Ć|ć|Č|č)/c/g' \
        -e 's/(Đ|đ|Ď|ď)/d/g' \
        -e 's/(È|É|Ê|Ë|è|é|ê|ë|Ę|ę|Ě|ě)/e/g' \
        -e 's/(Ğ|ğ)/g/g' \
        -e 's/(Ì|Í|Î|Ï|ì|í|î|ï|İ|ı)/i/g' \
        -e 's/(Ł|ł)/l/g' \
        -e 's/(Ñ|ñ|Ń|ń|Ň|ň)/n/g' \
        -e 's/(Ò|Ó|Ô|Õ|Ö|Ø|ò|ó|ô|õ|ö|ø|Ő|ő)/o/g' \
        -e 's/(Ř|ř)/r/g' \
        -e 's/(Ś|ś|Ş|ş|Š|š)/s/g' \
        -e 's/ß/ss/g' \
        -e 's/(Ť|ť|Ţ|ţ)/t/g' \
        -e 's/(Ù|Ú|Û|Ü|ù|ú|û|ü|Ů|ů|Ű|ű)/u/g' \
        -e 's/(Ý|ý|ÿ)/y/g' \
        -e 's/(Ź|ź|Ż|ż|Ž|ž)/z/g' \
        | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | sed 's/^[0-9]*//' | cut -c1-30)
    [ -n "$_base" ] || _base=user   # e.g. a name written only in non-Latin script

    LARCH_USERNAME="$_base"
    _n=1
    while grep -qx "$LARCH_USERNAME" "${RESERVED_NAMES:-/usr/lib/larch/reserved-names}" 2>/dev/null; do
        LARCH_USERNAME="$_base$_n"
        _n=$((_n + 1))
    done
}

# Short brand name from the SMBIOS system vendor (falling back to the board
# vendor, for self-built desktops whose system vendor is a placeholder), e.g.
# "LENOVO" -> lenovo, "ASUSTeK COMPUTER INC." -> asus. Unknown vendors use their
# first word; placeholders ("To be filled by O.E.M.", ...) yield nothing.
derive_brand() {
    local _f _v

    for _f in sys_vendor board_vendor; do
        _v=$(tr 'A-Z' 'a-z' 2>/dev/null < "/sys/class/dmi/id/$_f" || true)
        case "$_v" in
            ""|*"to be filled"*|*"system manufacturer"*|*"default string"*|o.e.m.*|oem*|*"not specified"*|*"not applicable"*)
                continue ;;
            *hewlett*|hp|hp\ *) echo hp ;;
            *asustek*)          echo asus ;;
            *micro-star*)       echo msi ;;
            *gigabyte*)         echo gigabyte ;;
            innotek*)           echo virtualbox ;;
            *)  printf '%s' "$_v" | sed 's/[[:space:],].*//' | tr -cd 'a-z0-9' | cut -c1-16 ;;
        esac
        return 0
    done
}

# The hostname is not asked for; it is derived as <username>-<brand>-<device
# type> (e.g. janedoe-lenovo-laptop), or <username>-<device type> when the brand
# is unknown, with the device type read from the SMBIOS chassis type.
# derive_username already yields [a-z0-9]; the '_'/'-' cleanup below only guards
# against a username from elsewhere (labels <= 63 chars, no edge hyphens).
derive_hostname() {
    local _chassis _kind="" _user _brand

    _brand=$(derive_brand)
    [ -z "$_brand" ] || _kind="$_brand-"

    _chassis=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || true)
    case "$_chassis" in
        8|9|10|14|31|32)          _kind="${_kind}laptop"  ;;  # portable/laptop/notebook/sub-notebook/convertible/detachable
        3|4|5|6|7|13|15|16|35|36) _kind="${_kind}desktop" ;;  # desktop/tower/all-in-one/mini PC/...
        30)                       _kind="${_kind}tablet"  ;;
        *)                        _kind="${_kind}pc"      ;;  # unknown, VMs (QEMU reports 1 = Other)
    esac

    _user=$(printf '%s' "$LARCH_USERNAME" | tr '_' '-' | cut -c1-38 | sed 's/^-*//; s/-*$//')
    if [ -n "$_user" ]; then
        LARCH_HOSTNAME="$_user-$_kind"
    else
        LARCH_HOSTNAME="larch-$_kind"
    fi
}
