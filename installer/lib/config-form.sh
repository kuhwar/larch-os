# installer/lib/config-form.sh — four-step interactive configuration prompts
# Sourced by install.sh; not executable on its own.

# Four sequential prompts — one per field — so Enter always advances to the
# next field rather than jumping to the OK button (a --mixedform limitation).
form_config() {
    local _pw2

    # ── Hostname ──────────────────────────────────────────────────────────────
    while true; do
        : > "$DIALOG_TMP"
        dialog --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (1/4) " \
            --inputbox "Hostname  (letters, numbers and hyphens):" 8 60 "$LARCH_HOSTNAME" \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        LARCH_HOSTNAME=$(cat "$DIALOG_TMP")
        case "$LARCH_HOSTNAME" in
            ""|-*|*-)
                dialog --backtitle "$DIALOG_BT" \
                    --msgbox "Hostname cannot be empty or start/end with a hyphen." 6 56
                continue ;;
            *[!a-zA-Z0-9-]*)
                dialog --backtitle "$DIALOG_BT" \
                    --msgbox "Hostname: only letters, numbers and hyphens allowed." 6 56
                continue ;;
        esac
        break
    done

    # ── Username ──────────────────────────────────────────────────────────────
    while true; do
        : > "$DIALOG_TMP"
        dialog --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (2/4) " \
            --inputbox "Username  (lowercase letters, numbers, _ and -):" 8 60 "$LARCH_USERNAME" \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        LARCH_USERNAME=$(cat "$DIALOG_TMP")
        case "$LARCH_USERNAME" in
            "")
                dialog --backtitle "$DIALOG_BT" --msgbox "Username cannot be empty." 5 40
                continue ;;
            *[!a-z0-9_-]*)
                dialog --backtitle "$DIALOG_BT" \
                    --msgbox "Username: only lowercase letters, numbers, _ and -." 5 56
                continue ;;
        esac
        break
    done

    # ── Password + confirm ────────────────────────────────────────────────────
    while true; do
        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Next" \
            --backtitle "$DIALOG_BT" --title " System Configuration (3/4) " \
            --passwordbox "Password:" 8 60 \
            2>"$DIALOG_TMP"
        if [ $? -ne 0 ]; then
            continue
        fi
        LARCH_PASSWORD=$(cat "$DIALOG_TMP")

        : > "$DIALOG_TMP"
        dialog --insecure --no-cancel --ok-label "Continue" \
            --backtitle "$DIALOG_BT" --title " System Configuration (4/4) " \
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
}
