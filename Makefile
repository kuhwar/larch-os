# larch-os Makefile
# All targets that touch the rootfs or produce output require root.
# Convenience wrapper around build.sh.

SHELL     := /bin/bash
SUDO      := sudo
BUILD     := $(SUDO) ./build.sh
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
	    ovmf \
	    qemu-system-x86 \
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
test-qemu: ## Boot larch-os.iso in QEMU with UEFI (requires ovmf + qemu)
	@[ -f "$(OUTPUT)" ] || { echo "Run 'make iso' first"; exit 1; }
	qemu-system-x86_64 \
	    -enable-kvm \
	    -m 4G \
	    -cpu host \
	    -smp 2 \
	    -bios /usr/share/ovmf/OVMF.fd \
	    -cdrom $(OUTPUT) \
	    -vga virtio \
	    -display gtk,gl=on \
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
	    -vga virtio \
	    -display gtk,gl=on \
	    -device virtio-net,netdev=net0 \
	    -netdev user,id=net0

## ── Info ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
