# larchconf-seed/

Initial contents of the LARCHCONF partition (`/etc/larch-conf`). Stage 9 copies
this tree to `/larchconf-seed/` on the ISO (minus the `.gitkeep` placeholders),
and the installer's `seed_larchconf` copies each top-level directory onto
LARCHCONF **only if it does not already exist there** — on a clean install and
on every update, so a new image can add a store without touching live state.

Each directory is the source of a bind mount in `rootfs-overlay/etc/fstab`.
To persist another service's state, add `<name>/` here, the bind line to the
fstab, and a `RequiresMountsFor` drop-in for the service.

Modes: ISO9660 doesn't keep them, so the installer sets them. Everything is
root-owned; directories get mode `0700`, or the mode in a sibling `<name>.mode`
file (e.g. `accountsservice.mode` → `0755`, since GDM's greeter reads avatars
from it). Files get the same mode without execute bits.
