# larch-os builder image
# Provides all host-side build dependencies.
# The container must be run with --privileged because the build uses:
#   - debootstrap (needs mknod to create /dev nodes in the chroot)
#   - mount --bind (proc/sys/dev into the chroot)
#   - chroot itself
#
# Usage (see docker-build.sh for a one-liner wrapper):
#   docker build -t larch-os-builder .
#   docker run --privileged --rm \
#       -v "$(pwd)/output:/output" \
#       larch-os-builder

FROM debian:trixie-slim

# Install all build-time tools in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    # rootfs bootstrap
    debootstrap \
    # squashfs compression
    squashfs-tools \
    # ISO creation
    xorriso \
    # FAT image manipulation (for EFI boot image)
    mtools \
    dosfstools \
    # GPT partitioning (needed by installer, not build)
    gdisk \
    # systemd-boot EFI binary (for installed-to-disk systems)
    systemd-boot \
    # GRUB2 (UEFI only) — used for ISO/live boot (has ISO9660 driver; systemd-boot does not)
    grub-common \
    grub-efi-amd64-bin \
    # initramfs packing
    cpio \
    gzip \
    # misc utilities used by the build pipeline (docker-entrypoint.sh)
    ca-certificates \
    curl \
    rsync \
    # busybox-static for initramfs
    busybox-static \
    # xz-utils / zstd to decompress .ko.xz / .ko.zst modules for busybox modprobe
    xz-utils \
    zstd \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy the full larch-os source into the image.
# During development you'll likely use a bind-mount instead
# (see docker-build.sh --dev mode) so this layer is mainly for
# standalone / CI builds.
COPY . .

# Output directory — mount a host volume here to retrieve the outputs
# e.g.  -v "$(pwd)/output:/output"
RUN mkdir -p /output

# Outputs (system release files, installer ISO) land in the mounted volume
ENV LARCH_OUTPUT_DIR=/output

# Entrypoint: dispatches to system/build.sh and installer/build.sh.
# With no arguments it runs a full build; forward stage flags as CMD args, e.g.
#   docker run --privileged ... larch-os-builder system --stage 6
# (the ./docker-build.sh wrapper does this for you).
ENTRYPOINT ["./docker-entrypoint.sh"]
