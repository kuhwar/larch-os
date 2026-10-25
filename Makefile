# larch-os Makefile
# The OS is built ONLY inside the privileged Docker builder (the pipeline needs
# chroot/mount/mknod, unavailable to an unprivileged `docker build`). Every build
# target is a thin wrapper around ./docker-build.sh, which runs the build pipeline
# (docker-entrypoint.sh) inside the container and writes the ISO to $(OUTPUT).

SHELL     := /bin/bash
SUDO      := sudo
BUILD     := ./docker-build.sh
OUTPUT    := output/larch-os.iso

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
install-deps: ## Install host-side tools for QEMU testing (the build itself only needs Docker)
	apt-get update
	apt-get install -y \
	    ovmf \
	    qemu-system-x86 \
	    qemu-utils

## ── Incremental rebuild targets ──────────────────────────────────────────────

.PHONY: squashfs
squashfs: ## Re-run squashfs stage only (stage 6) — use after rootfs edits
	$(BUILD) --stage 6

.PHONY: initramfs
initramfs: ## Re-pack the bootable OS initramfs from the existing squashfs (stage 7). NOTE: installer/payload/module changes live in the squashfs — use `make squashfs` (stage 6) for those.
	$(BUILD) --only 7

.PHONY: iso-only
iso-only: ## Re-assemble and re-pack ISO (stages 8+9) — skips rootfs build
	$(BUILD) --stage 8

## ── Docker build modes ───────────────────────────────────────────────────────
# `iso`, `clean`, `squashfs`, `initramfs`, `iso-only` above already run in Docker.
# These expose modes the main targets don't.

.PHONY: docker-dev
docker-dev: ## Docker build with source bind-mounted (fast iteration)
	./docker-build.sh --dev

.PHONY: docker-stage
docker-stage: ## Resume Docker build from an arbitrary stage: make docker-stage STAGE=6
	./docker-build.sh --stage $(STAGE)

.PHONY: docker-shell
docker-shell: ## Open a shell inside the builder container
	./docker-build.sh --shell

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

.PHONY: test-qemu-install-usb
test-qemu-install-usb: ## Like test-qemu-install but with a USB keyboard+mouse (exercises the USB-HID module fix)
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
	    -device qemu-xhci,id=xhci \
	    -device usb-kbd,bus=xhci.0 \
	    -device usb-mouse,bus=xhci.0 \
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
