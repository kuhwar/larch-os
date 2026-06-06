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
    # GRUB2 — used for ISO/live boot (has ISO9660 driver; systemd-boot does not)
    grub-common \
    grub-efi-amd64-bin \
    grub-pc-bin \
    # initramfs packing
    cpio \
    gzip \
    # misc utilities used by build.sh
    ca-certificates \
    curl \
    rsync \
    # busybox-static for initramfs
    busybox-static \
    # xz-utils to decompress .ko.xz modules for busybox modprobe compatibility
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy the full larch-os source into the image.
# During development you'll likely use a bind-mount instead
# (see docker-build.sh --dev mode) so this layer is mainly for
# standalone / CI builds.
COPY . .

# Output directory — mount a host volume here to retrieve larch-os.iso
# e.g.  -v "$(pwd)/output:/output"
RUN mkdir -p /output

# Override OUTPUT_ISO so the ISO lands in the mounted output volume
ENV LARCH_OUTPUT_ISO=/output/larch-os.iso

# Entrypoint: run the full build by default.
# Override CMD to run a specific stage:
#   docker run ... larch-os-builder ./build.sh --stage 6
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["./build.sh"]
