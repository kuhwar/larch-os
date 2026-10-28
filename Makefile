# larch-os Makefile
# The OS is built ONLY inside the privileged Docker builder (the pipeline needs
# chroot/mount/mknod, unavailable to an unprivileged `docker build`). Every build
# target is a thin wrapper around ./docker-build.sh, which runs the build pipeline
# (docker-entrypoint.sh) inside the container and writes the ISO to $(OUTPUT).

SHELL     := /bin/bash
SUDO      := sudo
BUILD     := ./docker-build.sh
OUTPUT    := output/larch-os.iso

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

# One target for install and boot: the disk is first in the boot order, so a
# blank disk falls through to the ISO (installer) and an installed one boots
# the system. Delete work/test-disk.img to test a fresh install again.
.PHONY: test-qemu
test-qemu: ## Boot ISO + 20G test disk in QEMU (UEFI); installs if the disk is blank, else boots it
	@[ -f "$(OUTPUT)" ] || { echo "Run 'make iso' first"; exit 1; }
	@[ -f work/test-disk.img ] || \
	    qemu-img create -f qcow2 work/test-disk.img 20G
	qemu-system-x86_64 \
	    -enable-kvm \
	    -m 4G \
	    -cpu host \
	    -smp 2 \
	    -bios /usr/share/ovmf/OVMF.fd \
	    -drive file=work/test-disk.img,format=qcow2,if=none,id=disk \
	    -device virtio-blk-pci,drive=disk,bootindex=0 \
	    -drive file=$(OUTPUT),media=cdrom,readonly=on,if=none,id=cd \
	    -device ide-cd,drive=cd,bootindex=1 \
	    -vga virtio \
	    -display gtk,gl=off \
	    -full-screen \
	    -device virtio-net,netdev=net0 \
	    -netdev user,id=net0
