# larch-os Makefile
# The OS is built ONLY inside the privileged Docker builder (the pipeline needs
# chroot/mount/mknod, unavailable to an unprivileged `docker build`). Every build
# target is a thin wrapper around ./docker-build.sh, which runs the build pipeline
# (docker-entrypoint.sh → system/build.sh, installer/build.sh) inside the
# container and writes to output/.

SHELL     := /bin/bash
SUDO      := sudo
TARGET    := system
BUILD     := ./docker-build.sh

.DEFAULT_GOAL := all

## ── Main targets ─────────────────────────────────────────────────────────────

.PHONY: all
all: ## Build both: the system release files (output/system/) and the installer ISO
	$(BUILD)

.PHONY: system
system: ## Build the system release files → output/system/
	$(BUILD) system

.PHONY: installer iso
installer iso: ## Build the installer ISO → output/larch-installer.iso (needs the system rootfs)
	$(BUILD) installer

.PHONY: clean
clean: ## Delete work/ and output/
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
squashfs: ## Rebuild the desktop images and release files (system stages 5+) after rootfs edits
	$(BUILD) system --stage 5

## ── Docker build modes ───────────────────────────────────────────────────────
# The targets above already run in Docker.
# These expose modes the main targets don't.

.PHONY: docker-dev
docker-dev: ## Docker build with source bind-mounted (fast iteration)
	./docker-build.sh --dev

.PHONY: docker-stage
docker-stage: ## Resume a build from a stage: make docker-stage TARGET=system STAGE=6
	./docker-build.sh $(TARGET) --stage $(STAGE)

.PHONY: docker-shell
docker-shell: ## Open a shell inside the builder container
	./docker-build.sh --shell

## ── Testing ──────────────────────────────────────────────────────────────────

# The logic lives in ./test-qemu.sh so it also runs without make (e.g. on
# larch-os itself, using a QEMU AppImage from ~/Applications).
.PHONY: test-qemu
test-qemu: ## Boot the installer ISO + 20G test disk in QEMU (UEFI); installs if the disk is blank, else boots it
	./test-qemu.sh

.PHONY: test-qemu-local
test-qemu-local: ## Same, but install/update from the local output/system/ instead of GitHub
	./test-qemu.sh --local
