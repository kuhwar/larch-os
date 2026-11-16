# installer/lib/config-form.sh — the installer's configuration prompts and the
# derived hostname (the prompts and derive_username are shared/lib/account.sh)
# Sourced by install.sh; not executable on its own.

# Three sequential prompts — one per field (shared/lib/account.sh).
form_config() {
    ask_full_name "System Configuration (1/3)"
    ask_password "System Configuration (2/3)" "System Configuration (3/3)"
    derive_username
    derive_hostname
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
