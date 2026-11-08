# larch-os builder image
# Provides all host-side build dependencies.
# The container must be run with --privileged because the build uses:
#   - mount --bind (proc/sys/dev into the rootfs) while pacman installs into it
#   - chroot itself
#
# Usage (see docker-build.sh for a one-liner wrapper):
#   docker build -t larch-os-builder .
#   docker run --privileged --rm \
#       -v "$(pwd)/output:/output" \
#       larch-os-builder

FROM docker.io/library/archlinux:base

# The builder's pacman bootstraps the rootfs (system stage 2) and checks its
# package signatures against this keyring. The image's own pacman.conf
# (NoExtract of docs, locales, …) applies only to the builder's packages; the
# rootfs is installed with system/config/pacman.conf.
RUN pacman-key --init && pacman-key --populate archlinux \
 && pacman -Syu --noconfirm --needed \
    # squashfs compression
    squashfs-tools \
    # ISO creation (xorriso) and the GRUB EFI image's FAT filesystem
    libisoburn \
    mtools \
    dosfstools \
    # GRUB2 (UEFI only) — used for ISO/live boot (has ISO9660 driver; systemd-boot does not)
    grub \
    # initramfs packing
    cpio \
    gzip \
    # misc utilities used by the build pipeline
    ca-certificates \
    curl \
    rsync \
    xz \
    zstd \
 && pacman -Scc --noconfirm

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
