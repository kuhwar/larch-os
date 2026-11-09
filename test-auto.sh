#!/bin/bash
# test-auto.sh — unattended install + first boot of the local build in QEMU
#
# Boots output/larch-installer.iso on a blank 20G disk with output/system/
# served as release "local" (like ./test-qemu.sh --local), answers the
# installer through QEMU's QMP socket (full name, password twice, release,
# disk, Install, OK), boots the installed system, logs in, shuts down cleanly
# and reads the guest's journal off its LARCHCONF partition. Screenshots of
# every step go to work/autotest/.
#
#   ./test-auto.sh          # fresh install, then first boot (≈ 8 min)
#   ./test-auto.sh boot     # boot the disk the last run installed again
#
# Exit status: 0 when the boot logged no error before shutdown other than the
# known ones in KNOWN_ERRORS below; 1 otherwise (the errors are printed).
# The login screen and the desktop are judged from the screenshots
# (b1-login.png, b2-desktop.png).
#
# Needs: a system build (output/system/, work/rootfs/ — sfdisk and debugfs
# are run from the base rootfs, so the host needs neither), the installer ISO,
# python3 and journalctl on the host, QEMU as for ./test-qemu.sh (host
# packages or a QEMU AppImage). KVM is required.

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
ROOT=$PWD

# Absolute paths: QEMU's -daemonize changes its working directory to /, and
# QMP's screendump writes where QEMU is.
ISO=$ROOT/output/larch-installer.iso
SYSTEM=$ROOT/output/system
V=$ROOT/work/autotest
PORT=8088
FULLNAME="Test User"
PASSWORD="${LARCH_TEST_PASSWORD:-larchtest}"   # letters and digits only (typed via QMP)
# Errors that are expected on every boot (regexes over the journal message).
# virt/tdx: printed by the kernel's built-in TDX host code on every CPU without
# TDX; no parameter disables it, and loglevel=3 keeps it off the screen.
KNOWN_ERRORS='virt/tdx: TDX not supported by the host platform'

PHASE=${1:-install}
case "$PHASE" in install|boot) ;; *) echo "usage: $0 [install|boot]" >&2; exit 2 ;; esac

[ -f "$ISO" ] || { echo "No $ISO — run ./docker-build.sh installer first" >&2; exit 1; }
[ -f "$SYSTEM/SHA256SUMS" ] || { echo "No $SYSTEM — run ./docker-build.sh system first" >&2; exit 1; }
[ -x work/rootfs/usr/bin/debugfs ] || { echo "No work/rootfs with e2fsprogs — run the system build first" >&2; exit 1; }
[ -w /dev/kvm ] || { echo "/dev/kvm is not usable: KVM is required" >&2; exit 1; }
mkdir -p "$V"

# ── QEMU (same detection as test-qemu.sh) ────────────────────────────────────
if [[ -z "${QEMU_APPIMAGE:-}" ]]; then
    qemu_path=$(command -v qemu-system-x86_64 || true)
    if [[ -n "$qemu_path" ]]; then
        qemu_path=$(readlink -f "$qemu_path")
        [[ "$qemu_path" != *.AppImage ]] || QEMU_APPIMAGE=$qemu_path
    else
        QEMU_APPIMAGE=$(compgen -G "$HOME/Applications/*QEMU*.AppImage" | head -n1 || true)
        [[ -n "$QEMU_APPIMAGE" ]] || { echo "No qemu-system-x86_64 on PATH and no ~/Applications/*QEMU*.AppImage" >&2; exit 1; }
    fi
fi
if [[ -n "${QEMU_APPIMAGE:-}" ]]; then
    qemu_system=("$QEMU_APPIMAGE" qemu-system-x86_64)
    qemu_img=("$QEMU_APPIMAGE" qemu-img)
    "$QEMU_APPIMAGE" sh -c 'cat "$APPDIR/share/qemu/edk2-x86_64-code.fd"' > "$V/code.fd"
    : > "$V/vars.fd"; truncate -s 540672 "$V/vars.fd"     # fresh, blank NVRAM each run
    firmware=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$V/code.fd"
              -drive "if=pflash,format=raw,unit=1,file=$V/vars.fd")
else
    qemu_system=(qemu-system-x86_64)
    qemu_img=(qemu-img)
    firmware=(-bios /usr/share/ovmf/OVMF.fd)
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
SOCK="$V/qmp.sock"
qmp()  { python3 tools/qmp.py "$SOCK" "$@" >/dev/null; }
shot() { python3 tools/qmp.py "$SOCK" screendump "$V/$1.png" >/dev/null; echo "  screenshot: $V/$1.png"; }
key()  { qmp sendkey "$@"; }
typ() {  # type letters, digits and spaces
    local s="$1" c i keys=()
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in
            [a-z0-9]) keys+=("$c") ;;
            [A-Z])    keys+=("shift-${c,,}") ;;
            ' ')      keys+=(spc) ;;
            *) echo "can't type '$c'" >&2; exit 2 ;;
        esac
    done
    qmp sendkey "${keys[@]}"
}
vm_pid() { pgrep -f -- "file=$V/disk.qcow2" || true; }
wait_still() {  # wait until the screen stops changing (max $1 × 10 s)
    local prev="" cur _
    for _ in $(seq "$1"); do
        sleep 10
        python3 tools/qmp.py "$SOCK" screendump "$V/poll.png" >/dev/null
        cur=$(md5sum < "$V/poll.png.ppm")
        [ "$cur" = "$prev" ] && return 0
        prev=$cur
    done
}
start_vm() {  # start_vm <with installer ISO 0|1>
    local iso=()
    [ "$1" = 1 ] && iso=(-drive "file=$ISO,media=cdrom,readonly=on,if=none,id=cd" -device ide-cd,drive=cd,bootindex=1)
    rm -f "$SOCK"
    "${qemu_system[@]}" -enable-kvm -m 4G -cpu host -smp 2 "${firmware[@]}" \
        -drive "file=$V/disk.qcow2,format=qcow2,if=none,id=disk" -device virtio-blk-pci,drive=disk,bootindex=0 \
        "${iso[@]}" -vga virtio -display none \
        -device virtio-net,netdev=net0 -netdev user,id=net0 \
        -fw_cfg "name=opt/larch/source,string=http://10.0.2.2:$PORT" \
        -qmp "unix:$SOCK,server,nowait" -daemonize
    until [ -S "$SOCK" ]; do sleep 0.5; done
}
stop_vm() {  # a clean shutdown, so journald flushes the boot to LARCHCONF
    qmp system_powerdown || true
    for _ in $(seq 90); do [ -n "$(vm_pid)" ] || return 0; sleep 1; done
    qmp quit || true; sleep 2
}
# A tool from the base rootfs, run with the rootfs's own dynamic linker.
rootfs_tool() {
    local r=work/rootfs
    "$r/usr/lib64/ld-linux-x86-64.so.2" --library-path "$r/usr/lib64" "$r/usr/bin/$1" "${@:2}"
}

# The local release server (what test-qemu.sh --local does)
python3 -m http.server --bind 127.0.0.1 --directory "$SYSTEM" "$PORT" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true; [ -z "$(vm_pid)" ] || qmp quit || true' EXIT

# ── Install ──────────────────────────────────────────────────────────────────
if [ "$PHASE" = install ]; then
    rm -f "$V"/*.png "$V"/*.ppm "$V/disk.qcow2"
    "${qemu_img[@]}" create -f qcow2 "$V/disk.qcow2" 20G >/dev/null
    echo "== Installer"
    start_vm 1
    sleep 45;            shot i1-name
    typ "$FULLNAME";     key ret; sleep 2
    typ "$PASSWORD";     key ret; sleep 2
    typ "$PASSWORD";     key ret; sleep 25; shot i2-release   # network + release list
    key ret; sleep 5;    shot i3-disk
    key ret; sleep 3;    shot i4-confirm
    key ret                                                   # Install
    wait_still 60;       shot i5-complete                     # download + install
    key ret                                                   # OK -> reboot
    echo "== First boot"
    sleep 5
else
    [ -f "$V/disk.qcow2" ] || { echo "No $V/disk.qcow2 — run $0 first" >&2; exit 1; }
    echo "== Boot"
    start_vm 0
fi

# ── Login screen, login, shutdown ────────────────────────────────────────────
sleep 75;                         shot b1-login
key ret; sleep 3; typ "$PASSWORD"; key ret; sleep 30; shot b2-desktop
stop_vm

# ── The guest's journal ──────────────────────────────────────────────────────
echo "== Journal"
rm -rf "$V/journal" "$V/disk.raw"; mkdir -p "$V/journal"
"${qemu_img[@]}" convert -O raw "$V/disk.qcow2" "$V/disk.raw"
off=$(rootfs_tool sfdisk -d "$V/disk.raw" | awk '/name="LARCHCONF"/ { gsub(/[^0-9]/, "", $4); print $4 * 512 }')
[ -n "$off" ] || { echo "No LARCHCONF partition on the test disk" >&2; exit 1; }
rootfs_tool debugfs -R "rdump /var/log/journal $V/journal" "$V/disk.raw?offset=$off" >/dev/null 2>&1 || true
rm -f "$V/disk.raw"
jdir=$(dirname "$(find "$V/journal" -name system.journal | head -1)")
[ -d "$jdir" ] || { echo "No journal on the test disk" >&2; exit 1; }

# Errors of the last boot, up to the shutdown this script requested.
jc() { journalctl --directory="$jdir" -b 0 --no-pager "$@"; }
until_shutdown=$(jc -o short-monotonic | awk -F'[][]' '/Power key pressed|System is powering down|Powering off/ { print $2; exit }')
errors=$(jc -p err -o short-monotonic | awk -F'[][]' -v t="${until_shutdown:-1e9}" '$2 + 0 < t + 0' \
         | grep -vE "$KNOWN_ERRORS" || true)
echo "  journal: $jdir"
if [ -n "$errors" ]; then
    echo "FAIL — errors logged before shutdown:"
    echo "$errors"
    exit 1
fi
echo "PASS — no unexpected error before shutdown (check b1-login.png and b2-desktop.png)"
