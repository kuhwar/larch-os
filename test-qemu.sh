#!/bin/bash
# test-qemu.sh — boot output/larch-installer.iso + a 20G test disk in QEMU (UEFI)
#
# One script for install and boot: the disk is first in the boot order, so a
# blank disk falls through to the ISO (installer) and an installed one boots
# the system. Delete work/test-disk.img to test a fresh install again.
#
# The installer and "Update LARCH" download the system from GitHub releases.
# With --local they use the local build in output/system/ instead: it is
# served on 127.0.0.1:8088 (python3 or busybox httpd) and handed to the guest
# as the QEMU fw_cfg entry opt/larch/source (shared/lib/release.sh), where it
# shows up as release "local".
#   ./test-qemu.sh --local
#
# QEMU comes from the host packages (`sudo make install-deps`: qemu-system-x86,
# qemu-utils, ovmf) or, where there is no package manager (e.g. on larch-os
# itself), from a QEMU AppImage. The AppImage is used when QEMU_APPIMAGE is set,
# or auto-detected as ~/Applications/*QEMU*.AppImage when qemu-system-x86_64
# isn't on PATH:
#   ./test-qemu.sh
#   QEMU_APPIMAGE=~/Applications/QEMU-git-x86_64.AppImage ./test-qemu.sh
#
# Extra arguments are passed through to qemu-system-x86_64.

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ISO=output/larch-installer.iso
DISK=work/test-disk.img
LOCAL_DIR=output/system
LOCAL_PORT=8088

LOCAL=0
if [[ "${1:-}" == --local ]]; then LOCAL=1; shift; fi

[[ -f "$ISO" ]] || { echo "Run './docker-build.sh installer' (make installer) first" >&2; exit 1; }
mkdir -p work

local_args=()
if [[ "$LOCAL" -eq 1 ]]; then
    [[ -f "$LOCAL_DIR/SHA256SUMS" ]] || { echo "Run './docker-build.sh system' (make system) first" >&2; exit 1; }
    if command -v python3 >/dev/null; then
        python3 -m http.server --bind 127.0.0.1 --directory "$LOCAL_DIR" "$LOCAL_PORT" >/dev/null 2>&1 &
    elif command -v busybox >/dev/null; then
        busybox httpd -f -p "127.0.0.1:$LOCAL_PORT" -h "$LOCAL_DIR" &
    else
        echo "--local needs python3 or busybox to serve $LOCAL_DIR" >&2; exit 1
    fi
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT
    # QEMU's user network reaches the host's loopback as 10.0.2.2.
    local_args=(-fw_cfg "name=opt/larch/source,string=http://10.0.2.2:$LOCAL_PORT")
    echo "Serving $LOCAL_DIR to the guest as http://10.0.2.2:$LOCAL_PORT"
fi

if [[ -z "${QEMU_APPIMAGE:-}" ]]; then
    qemu_path=$(command -v qemu-system-x86_64 || true)
    if [[ -n "$qemu_path" ]]; then
        # A qemu-system-x86_64 symlinked to the AppImage (e.g. in ~/.local/bin)
        # brings no qemu-img or OVMF.fd with it — treat it as the AppImage.
        qemu_path=$(readlink -f "$qemu_path")
        [[ "$qemu_path" != *.AppImage ]] || QEMU_APPIMAGE=$qemu_path
    else
        QEMU_APPIMAGE=$(compgen -G "$HOME/Applications/*QEMU*.AppImage" | head -n1 || true)
        [[ -n "$QEMU_APPIMAGE" ]] || {
            echo "No qemu-system-x86_64 on PATH and no ~/Applications/*QEMU*.AppImage" >&2
            exit 1
        }
    fi
fi

if [[ -n "${QEMU_APPIMAGE:-}" ]]; then
    # The AppImage's AppRun execs the bundled binary named as its first argument.
    qemu_system=("$QEMU_APPIMAGE" qemu-system-x86_64)
    qemu_img=("$QEMU_APPIMAGE" qemu-img)

    # The AppImage ships edk2's split UEFI image (code only, no OVMF.fd), which
    # -bios can't load (not a 64 KiB multiple) and QEMU can't find inside the
    # AppImage by name — so copy it out (re-copied when the AppImage is newer)
    # and map it as pflash. The NVRAM starts blank (no vars template is
    # bundled): OVMF falls back to volatile variables, as with -bios OVMF.fd,
    # and both GRUB (ISO) and systemd-boot (disk) sit at the removable-media
    # path EFI/BOOT/BOOTX64.EFI, so no boot entries are needed.
    fw_code=work/edk2-x86_64-code.fd
    fw_vars=work/edk2-x86_64-vars.fd
    if [[ ! -s "$fw_code" || "$QEMU_APPIMAGE" -nt "$fw_code" ]]; then
        "$QEMU_APPIMAGE" sh -c 'cat "$APPDIR/share/qemu/edk2-x86_64-code.fd"' > "$fw_code.tmp"
        mv "$fw_code.tmp" "$fw_code"
    fi
    # edk2's 4 MiB flash layout: 0x37C000 code + 0x84000 vars.
    [[ -f "$fw_vars" ]] || truncate -s 540672 "$fw_vars"
    firmware=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$fw_code"
              -drive "if=pflash,format=raw,unit=1,file=$fw_vars")
else
    qemu_system=(qemu-system-x86_64)
    qemu_img=(qemu-img)
    firmware=(-bios /usr/share/ovmf/OVMF.fd)
fi

[[ -f "$DISK" ]] || "${qemu_img[@]}" create -f qcow2 "$DISK" 20G

# Not exec'd: with --local the file server is stopped when QEMU exits.
"${qemu_system[@]}" \
    -enable-kvm \
    -m 4G \
    -cpu host \
    -smp 2 \
    "${firmware[@]}" \
    -drive file="$DISK",format=qcow2,if=none,id=disk \
    -device virtio-blk-pci,drive=disk,bootindex=0 \
    -drive file="$ISO",media=cdrom,readonly=on,if=none,id=cd \
    -device ide-cd,drive=cd,bootindex=1 \
    -vga virtio \
    -display gtk,gl=off \
    -full-screen \
    -device virtio-net,netdev=net0 \
    -netdev user,id=net0 \
    "${local_args[@]}" \
    "$@"
