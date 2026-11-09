# larch-os builder image
# Provides all host-side build dependencies.
# The container must be run with --privileged because the build uses:
#   - mount --bind (proc/sys/dev into the rootfs) while dnf installs into it
#   - chroot itself
#
# Usage (see docker-build.sh for a one-liner wrapper):
#   docker build -t larch-os-builder .
#   docker run --privileged --rm \
#       -v "$(pwd)/output:/output" \
#       larch-os-builder

# The same Fedora release as system/config/fedora-release: the builder's dnf
# installs the rootfs with its own repo configuration (--use-host-config), and
# akmods builds the out-of-tree kernel modules here, against the rootfs's
# kernel, so no compiler ever enters the image.
FROM docker.io/library/fedora:45

RUN dnf -y install \
        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-45.noarch.rpm \
        https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-45.noarch.rpm \
 && dnf -y install --setopt=install_weak_deps=False \
    # squashfs compression
    squashfs-tools \
    # ISO creation (xorriso) and the GRUB EFI image's FAT filesystem
    xorriso mtools dosfstools \
    # GRUB2 (UEFI only) for the installer ISO: grub2-mkrescue + x86_64-efi modules
    grub2-tools-extra grub2-efi-x64-modules \
    # initramfs packing, image work
    cpio gzip xz zstd rsync findutils util-linux file \
    # readelf for the shared-library guard (system stage 5)
    binutils \
    # akmods: builds kmod RPMs (NVIDIA, Broadcom wl) for the rootfs's kernel
    akmods rpm-build gcc make \
    ca-certificates curl \
 && dnf clean all

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
