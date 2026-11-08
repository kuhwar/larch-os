# shared/lib/ui.sh — dialog setup, messages, progress, error/reboot helpers
# Sourced by the installer (installer/install.sh) and the updater
# (system/updater/update.sh); not executable on its own. The caller sets
# DIALOG_BT (the backtitle) and DIE_TITLE before sourcing.

RUN="/run/larch"
mkdir -p "$RUN"

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export TERM="${TERM:-linux}"
export TERMINFO="${TERMINFO:-/usr/share/terminfo}"
DIALOG_BT="${DIALOG_BT:-Larch OS}"
DIE_TITLE="${DIE_TITLE:-Error}"
DIALOG_TMP="$RUN/dialog.out"
TAB=$(printf '\t')

do_reboot() {
    sync
    clear_screen
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger    2>/dev/null || true
    reboot -f 2>/dev/null || true
    while true; do sleep 60; done
}

clear_screen() { printf '\033[2J\033[3J\033[H'; }

# A status line that stays on screen while the next step runs.
msg() {
    dialog --backtitle "$DIALOG_BT" --title " $1 " --infobox "\n  $2" 7 70 || true
}

# A message the user has to acknowledge.
note() {
    dialog --backtitle "$DIALOG_BT" --title " $1 " --msgbox "\n$2" 12 70 || true
}

# Fatal error: offer a reboot or a shell.
die() {
    _msg="$*"
    echo "ERROR: $_msg" > /dev/console
    if dialog --backtitle "$DIALOG_BT" --title " $DIE_TITLE " \
            --yes-label "Reboot" --no-label "Shell" \
            --yesno "\n$_msg" 14 70; then
        do_reboot
    fi
    clear_screen
    echo "ERROR: $_msg"
    echo "Type 'reboot -f' when done."
    exec sh < /dev/console > /dev/console 2>&1
}

command -v dialog >/dev/null 2>&1 \
    || { echo "dialog not found in this initramfs" > /dev/console; exit 1; }
dialog --print-maxsize >/dev/null 2>&1 \
    || { echo "dialog cannot initialise the terminal (TERM=$TERM)" > /dev/console; exit 1; }

# Show a dialog gauge while <pid> runs. <meter> is a command printing the bytes
# done so far; <total> is the expected byte count (0 = unknown).
# Usage: progress <pid> <total> <title> <text> <meter...>
progress() {
    _pid="$1"; _total="$2"; _title="$3"; _text="$4"; shift 4
    [ "${_total:-0}" -gt 0 ] || _total=1
    (
        while kill -0 "$_pid" 2>/dev/null; do
            _done=$("$@" 2>/dev/null || echo 0)
            [ -n "$_done" ] || _done=0
            _pct=$(( _done * 100 / _total ))
            [ "$_pct" -le 99 ] || _pct=99
            printf 'XXX\n%d\n\n  %s\n\n  %d / %d MB\nXXX\n' "$_pct" "$_text" \
                $(( _done / 1048576 )) $(( _total / 1048576 ))
            sleep 1
        done
        echo 100
    ) | dialog --backtitle "$DIALOG_BT" --title " $_title " --gauge "" 10 70 0
}
