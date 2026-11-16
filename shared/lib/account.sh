# shared/lib/account.sh — the full-name / password prompts and the username
# derived from the full name. Sourced by the installer (installer/lib/
# config-form.sh) and the Manage LARCH menu (system/updater/users.sh); not
# executable on its own.

# ask_full_name <title>: sets LARCH_FULLNAME (Enter always advances — one
# prompt per field rather than a --mixedform). Cancel (when <cancel> is given
# as $2) returns 1.
ask_full_name() {
    while true; do
        : > "$DIALOG_TMP"
        if [ -n "${2:-}" ]; then
            dialog --ok-label "Next" --cancel-label "$2" \
                --backtitle "$DIALOG_BT" --title " $1 " \
                --inputbox "Full name  (e.g. Jane Doe):" 8 60 "$LARCH_FULLNAME" \
                2>"$DIALOG_TMP" || return 1
        else
            dialog --no-cancel --ok-label "Next" \
                --backtitle "$DIALOG_BT" --title " $1 " \
                --inputbox "Full name  (e.g. Jane Doe):" 8 60 "$LARCH_FULLNAME" \
                2>"$DIALOG_TMP" || continue
        fi
        # ':' and ',' are field/sub-field separators in /etc/passwd's GECOS
        # field; drop them and control characters, then trim surrounding blanks.
        LARCH_FULLNAME=$(tr -d ':,\000-\037\177' < "$DIALOG_TMP" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ -z "$LARCH_FULLNAME" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Full name cannot be empty." 5 40
            continue
        fi
        return 0
    done
}

# ask_password <title> <confirm-title>: sets LARCH_PASSWORD (asked twice).
ask_password() {
    local _pw2
    while true; do
        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " $1 " \
            --passwordbox "Password:" 8 60 \
            2>"$DIALOG_TMP" || continue
        LARCH_PASSWORD=$(cat "$DIALOG_TMP")

        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Continue" \
            --backtitle "$DIALOG_BT" --title " $2 " \
            --passwordbox "Confirm password:" 8 60 \
            2>"$DIALOG_TMP" || continue
        _pw2=$(cat "$DIALOG_TMP")
        : > "$DIALOG_TMP"

        if [ -z "$LARCH_PASSWORD" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Password cannot be empty." 5 40
            continue
        fi
        if [ "$LARCH_PASSWORD" != "$_pw2" ]; then
            dialog --backtitle "$DIALOG_BT" --msgbox "Passwords do not match." 5 40
            continue
        fi
        return 0
    done
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
