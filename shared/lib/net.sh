# shared/lib/net.sh — get online: wired DHCP first, else pick a Wi-Fi network
# Sourced by the installer and the updater (after ui.sh and hw.sh); not
# executable on its own.
#
# Nothing is remembered: the Wi-Fi password is asked every time and lives only
# in wpa_supplicant's memory until reboot. Nothing is written to disk.

UDHCPC_SCRIPT=/usr/share/udhcpc/default.script
WPA_CTRL=/run/wpa_supplicant
WIFI_IF=""

# Physical interfaces only (virtual ones have no device link).
list_ifaces() {
    for _i in /sys/class/net/*; do
        _n="${_i##*/}"
        [ "$_n" = lo ] && continue
        [ -e "$_i/device" ] || continue
        echo "$_n"
    done
}

is_wireless() { [ -d "/sys/class/net/$1/wireless" ] || [ -e "/sys/class/net/$1/phy80211" ]; }

# One-shot DHCP: configure the address, route and DNS, then exit. The lease
# isn't renewed, which is fine for a download that takes minutes.
dhcp() {
    ip addr flush dev "$1" 2>/dev/null || true
    udhcpc -i "$1" -f -n -q -t 5 -T 3 -A 2 -s "$UDHCPC_SCRIPT" >/dev/null 2>&1 \
        && ip route | grep -q '^default'
}

try_wired() {
    _eths=""
    for _n in $(list_ifaces); do
        is_wireless "$_n" && continue
        ip link set "$_n" up 2>/dev/null || true
        _eths="$_eths $_n"
    done
    [ -n "$_eths" ] || return 1
    msg "Network" "Looking for a wired connection..."
    # Link negotiation takes a few seconds after the interface comes up.
    _t=0; _up=""
    while [ "$_t" -lt 8 ]; do
        _up=""
        for _n in $_eths; do
            [ "$(cat "/sys/class/net/$_n/carrier" 2>/dev/null)" = 1 ] && _up="$_up $_n"
        done
        [ -n "$_up" ] && break
        sleep 1; _t=$((_t + 1))
    done
    for _n in $_up; do
        msg "Network" "Cable connected on $_n, requesting an address..."
        dhcp "$_n" && { NET_DESC="wired ($_n)"; return 0; }
    done
    return 1
}

wpa() { wpa_cli -p "$WPA_CTRL" -i "$WIFI_IF" "$@" 2>/dev/null; }

start_wpa() {
    [ -S "$WPA_CTRL/$WIFI_IF" ] && return 0
    printf 'ctrl_interface=%s\nupdate_config=0\n' "$WPA_CTRL" > "$RUN/wpa.conf"
    ip link set "$WIFI_IF" up 2>/dev/null || true
    wpa_supplicant -B -i "$WIFI_IF" -D nl80211,wext -c "$RUN/wpa.conf" \
        -P "$RUN/wpa.pid" >/dev/null 2>&1 || return 1
    _w=0
    while [ ! -S "$WPA_CTRL/$WIFI_IF" ]; do
        _w=$((_w + 1)); [ "$_w" -le 10 ] || return 1
        sleep 1
    done
}

# Scan and write "<signal>\t<security>\t<ssid>" lines, strongest first, one per
# SSID, to $RUN/networks. The SSID is as wpa_cli prints it (non-printable
# bytes escaped), which is what connect_wifi feeds back via ssid P"...".
scan_wifi() {
    msg "Wi-Fi" "Scanning for wireless networks on $WIFI_IF..."
    wpa scan >/dev/null
    _w=0
    while [ "$_w" -lt 8 ]; do
        sleep 1; _w=$((_w + 1))
        [ "$_w" -ge 3 ] && [ "$(wpa scan_results | wc -l)" -gt 1 ] && break
    done
    wpa scan_results | awk -F'\t' 'NR > 1 && $5 != "" && $5 !~ /^(\\x00)+$/ {
            sec = "open"
            if ($4 ~ /EAP/)                sec = "eap"
            else if ($4 ~ /WEP/)           sec = "wep"
            else if ($4 ~ /WPA|RSN|SAE/)   sec = "psk"
            print $3 "\t" sec "\t" $5
        }' | sort -t "$TAB" -k1,1nr | awk -F'\t' '!seen[$3]++' > "$RUN/networks"
}

bars() {
    if   [ "$1" -ge -55 ]; then echo "[####]"
    elif [ "$1" -ge -65 ]; then echo "[### ]"
    elif [ "$1" -ge -75 ]; then echo "[##  ]"
    else                        echo "[#   ]"
    fi
}

# 0 connected · 1 failed · 2 probably a wrong password
connect_wifi() {
    _ssid="$1"; _sec="$2"; _pass="$3"
    wpa remove_network all >/dev/null
    _id=$(wpa add_network | tail -1)
    case "$_id" in ''|*[!0-9]*) return 1 ;; esac
    wpa set_network "$_id" ssid "P\"$_ssid\"" | grep -qx OK || return 1
    wpa set_network "$_id" scan_ssid 1 >/dev/null
    if [ "$_sec" = open ]; then
        wpa set_network "$_id" key_mgmt NONE >/dev/null
    else
        if [ "${#_pass}" -eq 64 ] && ! printf '%s' "$_pass" | grep -q '[^0-9A-Fa-f]'; then
            wpa set_network "$_id" psk "$_pass" | grep -qx OK || return 1
        else
            wpa set_network "$_id" psk "\"$_pass\"" | grep -qx OK || return 1
        fi
        # WPA2 and WPA3 (SAE takes the same passphrase); plain WPA-PSK if this
        # wpa_supplicant lacks SAE.
        wpa set_network "$_id" key_mgmt "WPA-PSK WPA-PSK-SHA256 SAE" | grep -qx OK \
            || wpa set_network "$_id" key_mgmt WPA-PSK >/dev/null
        wpa set_network "$_id" ieee80211w 1 >/dev/null
    fi
    wpa select_network "$_id" >/dev/null
    _w=0
    while [ "$_w" -lt 30 ]; do
        sleep 1; _w=$((_w + 1))
        wpa status | grep -qx 'wpa_state=COMPLETED' && break
        # wpa_supplicant disables a network temporarily after a failed
        # handshake — almost always a wrong password.
        [ "$_w" -ge 5 ] && [ "$_sec" != open ] \
            && wpa list_networks | grep -q 'TEMP-DISABLED' && return 2
    done
    [ "$_w" -lt 30 ] || return 1
    msg "Wi-Fi" "Connected, requesting an address..."
    dhcp "$WIFI_IF"
}

# 0 online · 1 go back to looking for a cable
wifi_menu() {
    start_wpa || die "Could not start wpa_supplicant on $WIFI_IF."
    scan_wifi
    while true; do
        set --
        _i=0
        while IFS="$TAB" read -r _sig _sec _ssid; do
            _i=$((_i + 1))
            case "$_sec" in
                psk)  _l="WPA" ;;
                open) _l="open" ;;
                eap)  _l="802.1X (not supported)" ;;
                wep)  _l="WEP (not supported)" ;;
            esac
            set -- "$@" "$_i" "$(bars "$_sig") $_ssid  ($_l)"
        done < "$RUN/networks"
        if [ "$#" -eq 0 ]; then
            dialog --backtitle "$DIALOG_BT" --title " Wi-Fi " \
                --extra-button --extra-label "Use cable" \
                --yes-label "Rescan" --no-label "Reboot" \
                --yesno "\nNo wireless networks found on $WIFI_IF." 9 70
            case $? in
                0) scan_wifi; continue ;;
                3) return 1 ;;
                *) do_reboot ;;
            esac
        fi
        dialog --backtitle "$DIALOG_BT" --title " Wi-Fi " \
            --ok-label "Connect" --extra-button --extra-label "Rescan" \
            --help-button --help-label "Use cable" --cancel-label "Reboot" \
            --menu "\nNo wired connection. Choose a wireless network:" \
            20 70 12 "$@" 2>"$DIALOG_TMP"
        case $? in
            0) ;;
            3) scan_wifi; continue ;;
            2) return 1 ;;
            *) do_reboot ;;
        esac
        _n=$(cat "$DIALOG_TMP")
        _line=$(sed -n "${_n}p" "$RUN/networks")
        _sec=$(echo "$_line" | cut -f2)
        _ssid=$(echo "$_line" | cut -f3-)
        case "$_sec" in
            eap|wep) note "Wi-Fi" "  $_ssid uses a kind of security that isn't supported here.\n  Choose another network or use a cable."; continue ;;
        esac
        _pass=""
        if [ "$_sec" = psk ]; then
            dialog --backtitle "$DIALOG_BT" --title " Wi-Fi password " --insecure \
                --passwordbox "\nPassword for $_ssid:" 10 70 2>"$DIALOG_TMP" || continue
            _pass=$(cat "$DIALOG_TMP"); : > "$DIALOG_TMP"
            if [ "${#_pass}" -lt 8 ] || [ "${#_pass}" -gt 64 ]; then
                note "Wi-Fi" "  A Wi-Fi password is 8 to 63 characters."; continue
            fi
        fi
        msg "Wi-Fi" "Connecting to $_ssid..."
        connect_wifi "$_ssid" "$_sec" "$_pass"
        case $? in
            0) _pass=""; NET_DESC="Wi-Fi ($_ssid)"; return 0 ;;
            2) note "Wi-Fi" "  Could not connect to $_ssid.\n  The password is probably wrong." ;;
            *) note "Wi-Fi" "  Could not connect to $_ssid." ;;
        esac
        _pass=""
        wpa remove_network all >/dev/null
    done
}

net_up() {
    # Wi-Fi may come up soft-blocked; there is nothing persisted to honour.
    for _r in /sys/class/rfkill/*/soft; do
        [ -f "$_r" ] && echo 0 > "$_r" 2>/dev/null || true
    done
    while true; do
        try_wired && return 0
        WIFI_IF=""
        for _n in $(list_ifaces); do
            is_wireless "$_n" && { WIFI_IF="$_n"; break; }
        done
        if [ -z "$WIFI_IF" ]; then
            dialog --backtitle "$DIALOG_BT" --title " Network " \
                --yes-label "Retry" --no-label "Reboot" \
                --yesno "\nNo network connection, and no wireless adapter was found.\n\nPlug in a network cable, then choose Retry." 11 70 \
                || do_reboot
            continue
        fi
        wifi_menu && return 0
    done
}
