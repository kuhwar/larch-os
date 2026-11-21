#!/bin/bash
# scripts/setup-chroot.sh — runs INSIDE the base rootfs (system stage 4)
# Called by system/build.sh as: chroot work/rootfs /setup-chroot.sh, after the
# builder's dnf installed config/packages.list and the kmods into it.
# Configures the BASE every desktop image is copied from: locale, identity
# placeholders, the default user, shared services. Desktop-specific setup lives
# in system/desktops/<desktop>/ (scripts/setup-desktop.sh, stage 5).

set -euo pipefail

log() { echo "  [chroot] $*"; }

# ── Locale & timezone ────────────────────────────────────────────────────────
# glibc-all-langpacks ships every locale precompiled (locale-archive), so any
# language and region format is selectable in GNOME Settings.
log "Configuring locale and timezone"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf ../usr/share/zoneinfo/UTC /etc/localtime
LC_ALL=en_US.UTF-8 locale >/dev/null 2>&1 \
    || { echo "ERROR: en_US.UTF-8 is not available (glibc-all-langpacks)" >&2; exit 1; }

# ── Hostname & hosts ─────────────────────────────────────────────────────────
echo "larchos" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   larchos
::1         localhost ip6-localhost ip6-loopback
EOF

# ── No SELinux ───────────────────────────────────────────────────────────────
# No policy is installed (the squashfs carries no labels). Without a config
# file SELinux simply stays off; SELINUX=disabled would instead make systemd
# write to the kernel's removed runtime-disable switch (a kernel error at boot).
rm -f /etc/selinux/config

# ── PAM and NSS ──────────────────────────────────────────────────────────────
# Fedora generates /etc/pam.d/system-auth & co. and nsswitch.conf with
# authselect. "local" (plain files) is the base; then authselect lets go of
# them (opt-out) and the local LDAP directory is added by hand (ldap-poc):
# people's accounts come from nslcd (ldap) after the image's files, their
# passwords are checked and changed by pam_ldap. Shadow stays files-only, so
# hashes never leave the directory through NSS.
log "PAM/NSS: authselect 'local' + the local LDAP directory"
authselect select local --force >/dev/null
authselect opt-out >/dev/null
[ -e /etc/pam.d/system-auth ] || { echo "ERROR: no /etc/pam.d/system-auth" >&2; exit 1; }
for _f in system-auth password-auth; do
    _p=$(readlink -f "/etc/pam.d/$_f")
    sed -i \
        -e '/^auth .*pam_unix\.so/a auth        sufficient                                   pam_ldap.so minimum_uid=1000 use_first_pass' \
        -e '/^account .*pam_unix\.so/a account     [default=bad success=ok user_unknown=ignore authinfo_unavail=ignore] pam_ldap.so minimum_uid=1000' \
        -e '/^password .*pam_unix\.so/a password    sufficient                                   pam_ldap.so minimum_uid=1000 try_first_pass use_authtok' \
        "$_p"
    grep -q pam_ldap "$_p" || { echo "ERROR: pam_ldap not added to $_p" >&2; exit 1; }
done
_n=$(readlink -f /etc/nsswitch.conf)
sed -i -E 's/^(passwd|group):([[:space:]]+)files /\1:\2files ldap /' "$_n"
[ "$(grep -cE '^(passwd|group):.*files ldap' "$_n")" = 2 ] \
    || { echo "ERROR: ldap not added to $_n" >&2; exit 1; }
# authselect-apply-changes would regenerate (and, with opt-out, fail on) the
# files at every boot; the image's are final.
systemctl mask authselect-apply-changes.service

# ── Accounts ─────────────────────────────────────────────────────────────────
# No people in /etc/passwd: the installer creates the first one in the LDAP
# directory (/conf/ldap). /etc/passwd, group and shadow are the image's system
# accounts only, so every release brings its own.
userdel -r larch >/dev/null 2>&1 || true

# ── Systemd services ─────────────────────────────────────────────────────────
# The packages' scriptlets applied Fedora's presets; set exactly what larch runs.
log "Enabling systemd services"
systemctl enable NetworkManager bluetooth cups.socket avahi-daemon chronyd \
    switcheroo-control nvidia-suspend nvidia-resume nvidia-hibernate \
    larch-slapd nslcd
systemctl set-default graphical.target
# systemd-oomd: Fedora's userspace OOM killer — masked, the kernel's OOM
# killer is enough (swap is only zram, rootfs-overlay/etc/systemd/zram-generator.conf).
systemctl disable systemd-oomd.service systemd-oomd.socket 2>/dev/null || true
systemctl mask systemd-oomd.service systemd-oomd.socket
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber 2>/dev/null || true

# ── Boot splash (Plymouth + firmware BGRT logo) ──────────────────────────────
log "Configuring Plymouth boot splash (bgrt theme)"
plymouth-set-default-theme bgrt
if [ -d /usr/share/plymouth/themes ]; then
    for _theme in /usr/share/plymouth/themes/*; do
        case "$(basename "$_theme")" in
            bgrt|spinner|text|details|default.plymouth) : ;;
            *) rm -rf "$_theme" ;;
        esac
    done
fi

# ── NetworkManager ───────────────────────────────────────────────────────────
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/00-larch.conf <<'EOF'
[main]
plugins=keyfile
dhcp=internal

[keyfile]
# /etc is read-only: saved connections (Wi-Fi passwords) persist on
# LARCHCONF's /var/lib instead.
path=/var/lib/NetworkManager/system-connections

[device]
wifi.scan-rand-mac-address=yes
EOF

# ── Avahi: don't publish resolv.conf's DNS servers ───────────────────────────
# On by default, it makes avahi read /etc/resolv.conf at start, which on larch
# is a symlink into /run/NetworkManager that doesn't exist yet then: two errors
# at every boot. larch has no reason to announce its DNS servers over mDNS.
sed -i -e '/^enable-chroot=/d' \
       -e 's/^#\?publish-resolv-conf-dns-servers=.*/publish-resolv-conf-dns-servers=no/' \
       /etc/avahi/avahi-daemon.conf
grep -q '^publish-resolv-conf-dns-servers=no' /etc/avahi/avahi-daemon.conf

# ── Read-only root: mount points must ship in the image ──────────────────────
mkdir -p /conf /media /var/tmp

# ── Lock root ────────────────────────────────────────────────────────────────
passwd -l root >/dev/null

# ── iwlwifi firmware the kernel can't load ───────────────────────────────────
# Done here in the base (not in clean-rootfs.sh) so the installer and updater
# initramfs, which take firmware from the base, get the trimmed set too.
# linux-firmware ships several API versions per Intel Wi-Fi chip; iwlwifi
# loads the highest one <= its own maximum, so only that one stays per chip.
# The maxima come from this kernel's modules (modinfo). Fedora compresses
# firmware (.ucode.xz): names are compared without the compression suffix.
FW=/usr/lib/firmware
IWL=$FW/intel/iwlwifi
[ -d "$IWL" ] || IWL=$FW
IWL_REQ=$(find /usr/lib/modules -path '*/iwlwifi/*' -name '*.ko*' \
    -exec modinfo -F firmware {} \; 2>/dev/null | grep '^iwlwifi-' | sort -u || true)
if [ -n "$IWL_REQ" ] && ls "$IWL"/iwlwifi-* >/dev/null 2>&1; then
    log "Trimming iwlwifi firmware to what the kernel loads"
    printf '%s\n' "$IWL_REQ" > /tmp/iwl-req
    # shellcheck disable=SC2016
    IWL_DROP=$(ls "$IWL" | grep '^iwlwifi-' | sed -E 's/\.(zst|xz)$//' | awk '
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
    for f in $IWL_DROP; do rm -f "$IWL/$f" "$IWL/$f.xz" "$IWL/$f.zst"; done
    rm -f /tmp/iwl-req
fi
find "$FW" -xtype l -delete

log "chroot configuration complete"
