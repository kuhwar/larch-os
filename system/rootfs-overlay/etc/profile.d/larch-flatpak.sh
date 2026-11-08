# larch-os — make Flatpak persistent and user-scoped.
#
# The OS root is an immutable squashfs and /var is a tmpfs overlay discarded on
# every reboot, so system-wide Flatpak installs (/var/lib/flatpak) do NOT survive.
# Only /home is persistent (the LARCHHOME partition). Therefore all Flatpak app
# installs must go to the per-user installation (~/.local/share/flatpak), which
# lives on /home and persists.
#
# This snippet runs at login and:
#   1. registers the Flathub remote at --user scope (idempotent, persistent), and
#   2. defaults the interactive `flatpak` command to --user.
#
# It requires network the first time; it is a no-op once the remote exists.

# Only for real interactive users (skip root and system accounts).
if [ -n "${HOME:-}" ] && [ "$(id -u)" -ge 1000 ] && command -v flatpak >/dev/null 2>&1; then
    if ! flatpak remote-list --user 2>/dev/null | grep -q '^flathub'; then
        flatpak remote-add --user --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
    fi

    # Default the interactive `flatpak` command to the persistent --user scope so
    # `flatpak install flathub <app>` just works. Pass explicit --system to target
    # the (non-persistent) system installation when you really want it.
    alias flatpak='flatpak --user'
fi
