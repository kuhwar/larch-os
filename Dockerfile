# larch-os builder image — Alpine edge base
# Provides all host-side build dependencies.
# The container must be run with --privileged because the build uses:
#   - apk --root (needs mknod to create /dev nodes in the chroot)
#   - mount --bind (proc/sys/dev into the chroot)
#   - chroot itself
#
# Usage (see docker-build.sh for a one-liner wrapper):
#   docker build -t larch-os-builder .
#   docker run --privileged --rm \
#       -v "$(pwd)/output:/output" \
#       larch-os-builder

FROM alpine:edge

# Enable community repo (GNOME, systemd-boot, flatpak, etc.)
RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    apk update

RUN apk add --no-cache \
    # squashfs compression
    squashfs-tools \
    # ISO creation
    xorriso \
    # FAT image manipulation (for EFI boot image)
    mtools \
    dosfstools \
    # GPT partitioning
    gptfdisk \
    # systemd-boot EFI binary (for installed-to-disk systems)
    systemd-boot \
    # GRUB2 — used for ISO/live boot (has ISO9660 driver; systemd-boot does not)
    grub grub-efi grub-bios \
    # initramfs packing
    cpio \
    gzip \
    # misc utilities used by build.sh
    bash \
    ca-certificates \
    curl \
    rsync \
    # busybox-static for initramfs
    busybox-static \
    # xz / zstd to decompress .ko.xz / .ko.zst modules for busybox modprobe
    xz \
    zstd \
    # apk is natively available on Alpine — used in stage 2 to bootstrap the rootfs
    apk-tools

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
