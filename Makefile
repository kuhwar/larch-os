# larch-os Makefile
# All targets that touch the rootfs or produce output require root.
# Convenience wrapper around build.sh.

SHELL     := /bin/bash
SUDO      := sudo
BUILD     := $(SUDO) ./build.sh
OUTPUT    := output/larch-os.iso

# Make build.sh write the ISO to $(OUTPUT) so native builds, `make clean`,
# and the test-qemu targets all agree on one path. Honour an externally set
# LARCH_OUTPUT_ISO if the caller already exported one.
export LARCH_OUTPUT_ISO ?= $(abspath $(OUTPUT))

# QEMU display/VGA settings — overridable per machine.
# Default is the most portable combo (no host GL). Intel/Mesa hosts can opt back
# into virgl acceleration with:  make test-qemu QEMU_VGA=virtio QEMU_DISPLAY=gtk,gl=on
# NVIDIA proprietary/nouveau hosts black-screen with gl=on, so it is OFF here.
QEMU_VGA     ?= std
QEMU_DISPLAY ?= gtk,gl=off

.DEFAULT_GOAL := iso

## ── Main targets ─────────────────────────────────────────────────────────────

.PHONY: iso
iso: ## Build the complete larch-os.iso (all 9 stages)
	$(BUILD)

.PHONY: clean
clean: ## Delete work directory and output ISO
	$(BUILD) --clean

.PHONY: install-deps
install-deps: ## Install required build tools on the host
	apt-get update
	apt-get install -y \
	    debootstrap \
	    squashfs-tools \
	    xorriso \
	    mtools \
	    dosfstools \
	    gdisk \
	    systemd-boot \
	    grub-common \
	    grub-efi-amd64-bin \
	    grub-pc-bin \
	    busybox-static \
	    xz-utils \
	    zstd \
	    gzip \
	    ovmf \
	    qemu-system-x86 \
	    qemu-utils \
	    cpio

## ── Incremental rebuild targets ──────────────────────────────────────────────

.PHONY: squashfs
squashfs: ## Re-run squashfs stage only (stage 6) — use after rootfs edits
	$(BUILD) --stage 6

.PHONY: initramfs
initramfs: ## Re-build initramfs only (stage 7)
	$(BUILD) --only 7

.PHONY: iso-only
iso-only: ## Re-assemble and re-pack ISO (stages 8+9) — skips rootfs build
	$(BUILD) --stage 8

## ── Docker build ─────────────────────────────────────────────────────────────

.PHONY: docker
docker: ## Full build inside Docker (ISO → output/larch-os.iso)
	./docker-build.sh

.PHONY: docker-dev
docker-dev: ## Docker build with source bind-mounted (fast iteration)
	./docker-build.sh --dev

.PHONY: docker-stage
docker-stage: ## Resume Docker build from a stage: make docker-stage STAGE=6
	./docker-build.sh --stage $(STAGE)

.PHONY: docker-shell
docker-shell: ## Open a shell inside the builder container
	./docker-build.sh --shell

.PHONY: docker-clean
docker-clean: ## Remove output/ and work/ directories
	./docker-build.sh --clean

## ── Testing ──────────────────────────────────────────────────────────────────

.PHONY: test-qemu
test-qemu: ## Boot installed disk in QEMU with UEFI (run test-qemu-install first)
	@[ -f work/test-disk.img ] || { echo "No work/test-disk.img — run 'make test-qemu-install' first to install"; exit 1; }
	qemu-system-x86_64 \
	    -enable-kvm \
	    -m 4G \
	    -cpu host \
	    -smp 2 \
	    -bios /usr/share/ovmf/OVMF.fd \
	    -drive file=work/test-disk.img,format=qcow2,if=virtio \
	    -vga $(QEMU_VGA) \
	    -display $(QEMU_DISPLAY) \
	    -device virtio-net,netdev=net0 \
	    -netdev user,id=net0

.PHONY: test-qemu-install
test-qemu-install: ## Test installation: boot ISO + attach a blank 20G disk
	@[ -f "$(OUTPUT)" ] || { echo "Run 'make iso' first"; exit 1; }
	@[ -f work/test-disk.img ] || \
	    qemu-img create -f qcow2 work/test-disk.img 20G
	qemu-system-x86_64 \
	    -enable-kvm \
	    -m 4G \
	    -cpu host \
	    -smp 2 \
	    -bios /usr/share/ovmf/OVMF.fd \
	    -cdrom $(OUTPUT) \
	    -drive file=work/test-disk.img,format=qcow2,if=virtio \
	    -vga $(QEMU_VGA) \
	    -display $(QEMU_DISPLAY) \
	    -device virtio-net,netdev=net0 \
	    -netdev user,id=net0

.PHONY: test-qemu-disk
test-qemu-disk: ## Boot the INSTALLED disk only (no ISO) — tests the real installed system
	@[ -f work/test-disk.img ] || { echo "No work/test-disk.img — run 'make test-qemu-install' first to install"; exit 1; }
	qemu-system-x86_64 \
	    -enable-kvm \
	    -m 4G \
	    -cpu host \
	    -smp 2 \
	    -bios /usr/share/ovmf/OVMF.fd \
	    -drive file=work/test-disk.img,format=qcow2,if=virtio \
	    -vga $(QEMU_VGA) \
	    -display $(QEMU_DISPLAY) \
	    -device virtio-net,netdev=net0 \
	    -netdev user,id=net0

## ── Info ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
