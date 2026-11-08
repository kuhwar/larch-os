#!/bin/bash
# scripts/setup-chroot.sh — runs INSIDE the chroot after debootstrap
# Called by system/build.sh (stage 4) as: chroot work/rootfs /setup-chroot.sh
# Configures the BASE every desktop image is copied from: kernel, drivers,
# shared services, the default user. Desktop-specific setup lives in
# system/desktops/<desktop>/ (scripts/setup-desktop.sh, stage 5).
# The script is bind-mounted into the chroot at /setup-chroot.sh before execution.

set -euo pipefail

log() { echo "  [chroot] $*"; }

# ── Locale & timezone ────────────────────────────────────────────────────────
# Only WRITE the locale config here. Locales are compiled later, after the
# `locales` package is installed — running locale-gen now (before `locales`
# ships /usr/share/i18n) silently produces nothing, leaving only glibc's
# built-in C.utf8 and breaking UTF-8 apps like gnome-terminal (VTE).
log "Configuring locale and timezone"
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf      # systemd system locale
echo "LANG=en_US.UTF-8" > /etc/default/locale   # Debian/PAM session locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# ── Hostname & hosts ─────────────────────────────────────────────────────────
log "Setting hostname"
echo "larchos" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   larchos
::1         localhost ip6-localhost ip6-loopback
EOF

# ── Install packages from packages.list ──────────────────────────────────────
log "Updating apt sources"
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

log "Installing packages (this takes a while)"
# Read packages.list, strip comments and blank lines
PKGS=$(grep -v '^#' /packages.list | grep -v '^[[:space:]]*$' | tr '\n' ' ')
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS

# ── NVIDIA proprietary driver (from trixie-backports) ─────────────────────────
# Pulled separately with `-t trixie-backports` so that whenever backports carries
# a newer driver than main it is preferred. Today backports has 550.163.01 (same
# upstream version as main, rebuilt for bpo13), so this currently installs 550 —
# which already supports Pascal (e.g. GTX 1070 Ti). The pin is forward-looking:
# if Debian backports a newer branch (e.g. 580.x, the last to support Pascal) a
# rebuild upgrades to it with no change here. nvidia-kernel-dkms compiles the
# module against linux-headers-amd64 (installed in the bulk step above);
# clean-rootfs.sh strips the source tree afterward. See config/packages.list for
# the modeset/Wayland notes.
# Beyond nvidia-driver itself, list the Recommends that --no-install-recommends
# would skip but that this image actually needs:
#   libnvidia-allocator1 — the actual GBM backend: ships nvidia-drm_gbm.so
#     (→ libnvidia-allocator.so), wired into /usr/lib/<triplet>/gbm/ via the
#     alternatives system. Mesa's libgbm dlopens <gbm-dir>/nvidia-drm_gbm.so
#     (named after the DRM driver); without it mutter cannot allocate buffers
#     on the nvidia KMS device and the whole session silently renders on
#     llvmpipe.
#   libnvidia-egl-gbm1 — EGL external platform for GBM surfaces
#     (15_nvidia_gbm.json); the other half of accelerated Wayland.
#   nvidia-vulkan-icd  — Vulkan ICD for the card (games/apps via Flatpak).
#   nvidia-smi         — driver diagnostics CLI.
#   switcheroo-control — D-Bus GPU inventory; GNOME Settings' "Graphics" row
#     reads it (shows "Unknown" without it). From main, not backports.
#   nvidia-suspend-common — nvidia-sleep.sh + nvidia-suspend/resume/hibernate
#     units. Without these, VRAM is lost across sleep and gnome-shell SIGABRTs
#     on resume (broken fonts / missing top bar, then session restart). Needs
#     NVreg_PreserveVideoMemoryAllocations=1 (rootfs-overlay/etc/modprobe.d/
#     larch-nvidia.conf) and the services enabled below.
#   kbd — fgconsole/chvt, called by nvidia-sleep.sh; not in the base image.
log "Installing NVIDIA driver from trixie-backports"
apt-get install -y --no-install-recommends -t trixie-backports \
    nvidia-driver libnvidia-allocator1 libnvidia-egl-gbm1 nvidia-vulkan-icd \
    nvidia-smi switcheroo-control nvidia-suspend-common kbd

# Save/restore VRAM around sleep (units are WantedBy=systemd-suspend.service /
# systemd-hibernate.service; enablement creates those .wants links).
systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service

# ── Generate locales (now that `locales` + /usr/share/i18n are installed) ──────
# Must run AFTER package install. Every supported locale is compiled, so any
# language and region format is selectable in GNOME Settings (~33 MB in the
# squashfs); en_US.UTF-8 stays the default. The compiled archive lands in
# /usr/lib/locale and survives clean-rootfs (which only strips /usr/share/i18n
# source data).
log "Generating all supported locales"
cp /usr/share/i18n/SUPPORTED /etc/locale.gen
locale-gen
# Fail the build loudly if the archive didn't materialise — a missing en_US
# locale silently breaks gnome-terminal (status=9, "Locale not supported").
LC_ALL=en_US.UTF-8 locale >/dev/null 2>&1 \
    || { echo "ERROR: en_US.UTF-8 was not generated" >&2; exit 1; }

# ── User setup ───────────────────────────────────────────────────────────────
log "Creating default user 'larch'"
# Create user with home directory; password is 'larch' (change before shipping)
useradd -m -s /bin/bash -c "Larch User" larch
echo "larch:larch" | chpasswd
# No sudo on larch-os. The base OS is immutable and updated only from
# install/upgrade media, so the user has no admin escalation path; root is
# locked below and the sudo package is purged via remove.list. Deliberately
# NOT added to the `sudo` group — that group is polkit's admin identity, so
# leaving the user in it would let privileged polkit actions be authorized
# with the user's own password, re-opening an escalation path.
usermod -aG audio,video,input,netdev,plugdev larch

# ── Systemd services ─────────────────────────────────────────────────────────
log "Enabling systemd services"
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable cups
systemctl enable avahi-daemon
systemctl set-default graphical.target

# Disable services that conflict with immutability
systemctl disable apt-daily.timer          2>/dev/null || true
systemctl disable apt-daily-upgrade.timer  2>/dev/null || true
systemctl disable unattended-upgrades      2>/dev/null || true
systemctl disable packagekit               2>/dev/null || true

# No dpkg on the immutable OS — the dpkg database backup timer has nothing to
# back up and its helper is purged with apt/dpkg. Mask so it can't be pulled in.
systemctl mask dpkg-db-backup.timer        2>/dev/null || true

# NetworkManager is the sole network manager (always-DHCP design). Disable the
# ifupdown service and the standalone wpa_supplicant unit so they don't race NM
# for interface control. (NM drives wpa_supplicant over D-Bus, not via this unit.)
systemctl disable networking.service       2>/dev/null || true
systemctl disable wpa_supplicant.service   2>/dev/null || true

# ── Boot splash (Plymouth + firmware BGRT logo) ──────────────────────────────
# plymouth-start.service is pulled into sysinit.target by a vendor .wants
# symlink, so no explicit enable is needed; it shows the splash once systemd
# is up (kernel cmdline carries `splash`). Set the bgrt theme as the default.
log "Configuring Plymouth boot splash (bgrt theme)"
# -R would trigger update-initramfs, which this image does not use — omit it.
plymouth-set-default-theme bgrt 2>/dev/null || true
# Remove every theme except bgrt and what it needs: spinner (bgrt's ImageDir
# for the throbber assets) and the text/details fallbacks plymouth requires.
# Iterate over whatever is actually installed (Debian's default set is bgrt,
# ceratopsian, emerald, homeworld, joy, lines, moonlight, softwaves, ...).
if [ -d /usr/share/plymouth/themes ]; then
    # Glob without a trailing slash so symlink themes (e.g. desktop-base's
    # `debian-theme`) are removed as the symlink itself, not followed.
    for _theme in /usr/share/plymouth/themes/*; do
        case "$(basename "$_theme")" in
            bgrt|spinner|text|details|default.plymouth) : ;;   # keep
            *) rm -rf "$_theme" ;;
        esac
    done
fi

# Enable PipeWire audio
systemctl --global enable pipewire.socket     2>/dev/null || true
systemctl --global enable pipewire-pulse.socket 2>/dev/null || true
systemctl --global enable wireplumber          2>/dev/null || true

# ── Flatpak: add Flathub system-wide ─────────────────────────────────────────
log "Configuring Flatpak"
# Add Flathub as a system remote for discoverability (baked into the squashfs).
# NOTE: this is best-effort — it needs network at build time, and system-scope
# *app* installs land in /var/lib/flatpak, which is on the tmpfs overlay and is
# discarded on reboot. Persistent installs must use --user (→ ~/.local/share/
# flatpak on the LARCHHOME partition). The Flathub remote is also registered at
# --user scope at first login by /etc/profile.d/larch-flatpak.sh.
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo || \
    log "WARNING: Could not reach Flathub (network may be unavailable in build environment)"

# polkit rule for Flatpak and the skel ~/.bashrc Flatpak snippet are shipped as
# static files via rootfs-overlay/ (etc/polkit-1/rules.d/99-larch-flatpak.rules
# and etc/skel/.bashrc), per the project convention for system config files.

# ── NetworkManager: manage all interfaces ────────────────────────────────────
log "Configuring NetworkManager"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/00-larch.conf <<'EOF'
[main]
plugins=keyfile
dhcp=internal

[keyfile]

[device]
wifi.scan-rand-mac-address=yes
EOF

# ── Kernel ───────────────────────────────────────────────────────────────────
# Debian's kernel (linux-image-amd64). It ships separately from the image as
# the release's vmlinuz (system/build.sh stage 9), with sys.initramfs and
# updater.initramfs built from its modules; /boot is left out of the squashfs.
log "Checking kernel installation"
ls /boot/vmlinuz* >/dev/null 2>&1 || { echo "ERROR: no kernel in /boot" >&2; exit 1; }

# ── Read-only root: mount points must ship in the image ──────────────────────
# / is mounted read-only, so systemd can't create mount points at boot
# (x-systemd.mkdir fails). Create every fstab target that packages don't.
mkdir -p /conf /media /var/tmp

# ── Console / TTY hardening (immutable system) ───────────────────────────────
log "Hardening console access"
# Disable root login on all ttys
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config 2>/dev/null || true
# Lock root account
passwd -l root

# ── iwlwifi firmware the kernel can't load (~120 MB raw) ─────────────────────
# Done here in the base (not in clean-rootfs.sh) so the installer and updater
# initramfs, which take firmware from the base, get the trimmed set too.
# linux-firmware ships several API versions per Intel Wi-Fi chip. iwlwifi
# requests from its newest supported API downwards and loads the first that
# exists, so for each chip only the highest version <= the kernel's maximum is
# ever used: newer ones (and the -c<N> naming of newer kernels) can't load,
# older ones are shadowed. The maxima come from this kernel's own modules
# (modinfo), so the trim follows kernel upgrades. Chips the kernel doesn't list
# (iwlegacy's 3945/4965, …) are capped at the highest API it lists. .pnvm files
# stay. Skipped if iwlwifi is built in (no module to read).
FW=/usr/lib/firmware
IWL=$FW/intel/iwlwifi
IWL_REQ=$(find /usr/lib/modules -path '*/iwlwifi/*' -name '*.ko*' \
    -exec modinfo -F firmware {} \; 2>/dev/null | grep '^iwlwifi-' | sort -u || true)
if [ -d "$IWL" ] && [ -n "$IWL_REQ" ]; then
    log "Trimming iwlwifi firmware to what the kernel loads"
    printf '%s\n' "$IWL_REQ" > /tmp/iwl-req
    # shellcheck disable=SC2016
    IWL_DROP=$(ls "$IWL" | awk '
        NR == FNR {
            if (match($0, /-[0-9]+\.ucode$/)) {
                fam = substr($0, 1, RSTART - 1); v = substr($0, RSTART + 1) + 0
                if (v > max[fam]) max[fam] = v
                if (v > gmax) gmax = v
            }
            if ($0 ~ /-c[0-9]+\.ucode$/) creq = 1
            next
        }
        /-[0-9]+\.ucode$/ {
            match($0, /-[0-9]+\.ucode$/)
            fam = substr($0, 1, RSTART - 1); v = substr($0, RSTART + 1) + 0
            lim = (fam in max) ? max[fam] : gmax
            if (v <= lim && v > best[fam]) { best[fam] = v; bestf[fam] = $0 }
            all[$0] = 1; next
        }
        /-c[0-9]+\.ucode$/ { if (!creq) print }
        END {
            for (f in all) {
                match(f, /-[0-9]+\.ucode$/); fam = substr(f, 1, RSTART - 1)
                if (bestf[fam] != f) print f
            }
        }' /tmp/iwl-req - || true)
    for f in $IWL_DROP; do rm -f "$IWL/$f"; done
    rm -f /tmp/iwl-req
fi
# linux-firmware's compatibility symlinks (e.g. /usr/lib/firmware/iwlwifi-*.ucode
# → intel/iwlwifi/) dangle for everything removed from the firmware tree.
find "$FW" -xtype l -delete

# ── Clean apt caches ─────────────────────────────────────────────────────────
log "Cleaning apt caches"
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

log "chroot configuration complete"
