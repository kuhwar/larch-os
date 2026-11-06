#!/bin/bash
# scripts/fetch-kernel.sh — runs in the BUILDER container (not the chroot)
# Called by docker-entrypoint.sh (stage 4) as: fetch-kernel.sh <cache-dir>
#
# Puts the larch kernel packages (linux-image-*.deb + linux-headers-*.deb) into
# <cache-dir>. They are built by the larch-kernel repo's manual "Build kernel"
# workflow and published as GitHub releases: Debian's kernel with the
# root-mount drivers built in, so the installed system needs no initramfs.
#
#   LARCH_KERNEL_REPO  GitHub repo to fetch from (default kuhwar/larch-kernel)
#   LARCH_KERNEL_TAG   release tag to pin (default: the latest release)
#
# The cache dir survives --clean; a release already in it is not downloaded
# again. To use a locally built kernel instead, put its .debs in the cache dir
# and write "local" into <cache-dir>/.tag — it is then used as is. Without a
# linux-headers .deb, DKMS (nvidia, broadcom-sta) skips building its modules.

set -euo pipefail

log() { echo "  [kernel] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

CACHE="${1:?usage: fetch-kernel.sh <cache-dir>}"
REPO="${LARCH_KERNEL_REPO:-kuhwar/larch-kernel}"
mkdir -p "$CACHE"

# A local kernel may come without headers (then DKMS modules are skipped).
have_debs() {
    ls "$CACHE"/linux-image-*.deb >/dev/null 2>&1
}
cached_tag=$(cat "$CACHE/.tag" 2>/dev/null || true)

if [ "$cached_tag" = "local" ] && have_debs; then
    log "Using the locally built kernel in $CACHE"
    exit 0
fi

if [ -n "${LARCH_KERNEL_TAG:-}" ]; then
    api="https://api.github.com/repos/$REPO/releases/tags/$LARCH_KERNEL_TAG"
else
    api="https://api.github.com/repos/$REPO/releases/latest"
fi
if ! json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api"); then
    have_debs || die "Can't reach $api and no kernel is cached in $CACHE (run larch-kernel's Build kernel workflow first)"
    log "Can't reach GitHub — using the cached kernel ($cached_tag)"
    exit 0
fi

tag=$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$tag" ] || die "No release tag in $api"
if [ "$tag" = "$cached_tag" ] && have_debs; then
    log "Kernel $tag already cached"
    exit 0
fi

urls=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.deb"' | sed 's/.*"\([^"]*\)"$/\1/')
printf '%s\n' "$urls" | grep -q '/linux-image-'   || die "Release $tag has no linux-image .deb"
printf '%s\n' "$urls" | grep -q '/linux-headers-' || die "Release $tag has no linux-headers .deb"

log "Downloading kernel $tag from $REPO"
tmp="$CACHE/.download"
rm -rf "$tmp"
mkdir -p "$tmp"
for u in $urls; do
    curl -fsSL -o "$tmp/$(basename "$u")" "$u"
done
rm -f "$CACHE"/*.deb
mv "$tmp"/*.deb "$CACHE/"
rmdir "$tmp"
echo "$tag" > "$CACHE/.tag"
log "Kernel packages: $(cd "$CACHE" && ls ./*.deb | tr '\n' ' ')"
