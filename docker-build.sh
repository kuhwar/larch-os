#!/bin/bash
# docker-build.sh — convenience wrapper for building larch-os inside Docker
#
# Modes:
#   ./docker-build.sh              # full build, ISO goes to ./output/larch-os.iso
#   ./docker-build.sh --dev        # bind-mount source (faster iteration, no rebuild image)
#   ./docker-build.sh --stage 6    # resume from a specific stage
#   ./docker-build.sh --only 7     # run exactly one stage
#   ./docker-build.sh --shell      # drop into a shell inside the builder container
#   ./docker-build.sh --clean      # delete the output directory
#
# Requirements:
#   - Docker with --privileged support (Linux host recommended)
#   - On macOS/Windows: Docker Desktop with the "Use Rosetta" or standard x86-64 VM

set -euo pipefail

IMAGE_NAME="larch-os-builder"
OUTPUT_DIR="$(pwd)/output"
WORK_DIR="$(pwd)/work"   # shared build cache in dev mode
KERNEL_CACHE="$(pwd)/kernel-cache"   # downloaded kernel .debs — survives --clean

DEV_MODE=0
SHELL_MODE=0
CLEAN_MODE=0
BUILD_ARGS=()

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev)    DEV_MODE=1;   shift ;;
        --shell)  SHELL_MODE=1; shift ;;
        --clean)  CLEAN_MODE=1; shift ;;
        *)        BUILD_ARGS+=("$1"); shift ;;
    esac
done

# ── Clean ─────────────────────────────────────────────────────────────────────
if [ "$CLEAN_MODE" -eq 1 ]; then
    echo "Removing output/ and work/ directories"
    # Contents are root-owned (created inside privileged container), so delete
    # them via Docker. Use find -mindepth 1 to clear contents without trying to
    # remove the bind-mount points themselves (which would fail as "busy").
    if [ -d "$OUTPUT_DIR" ] || [ -d "$WORK_DIR" ]; then
        mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
        docker run --rm \
            -v "$OUTPUT_DIR:/output" \
            -v "$WORK_DIR:/work" \
            debian:trixie-slim \
            sh -c 'find /output /work -mindepth 1 -delete 2>/dev/null; true'
    fi
    rm -rf "$OUTPUT_DIR" "$WORK_DIR"
    echo "Done."
    exit 0
fi

# ── Build the Docker image (if not already built or source changed) ───────────
echo "Building Docker image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" .

mkdir -p "$OUTPUT_DIR"

# ── Construct docker run arguments ────────────────────────────────────────────
DOCKER_RUN_ARGS=(
    --rm
    --privileged                      # required: chroot + bind mounts + mknod
    -v "$OUTPUT_DIR:/output"          # ISO output goes here
    -e "LARCH_OUTPUT_ISO=/output/larch-os.iso"
)

# Always mount work/ from the host so the debootstrap rootfs cache
# survives across container runs and --stage N actually resumes correctly.
mkdir -p "$WORK_DIR"
DOCKER_RUN_ARGS+=(-v "$WORK_DIR:/build/work")

# The kernel .debs (scripts/fetch-kernel.sh, from the larch-kernel releases)
# live outside work/ and are kept across --clean. LARCH_KERNEL_REPO /
# LARCH_KERNEL_TAG pick another repo or pin a release.
mkdir -p "$KERNEL_CACHE"
DOCKER_RUN_ARGS+=(-v "$KERNEL_CACHE:/build/kernel-cache")
for _var in LARCH_KERNEL_REPO LARCH_KERNEL_TAG; do
    [ -n "${!_var:-}" ] && DOCKER_RUN_ARGS+=(-e "$_var=${!_var}")
done

if [ "$DEV_MODE" -eq 1 ]; then
    # Also bind-mount the full source so edits are reflected without rebuilding the image.
    DOCKER_RUN_ARGS+=(-v "$(pwd):/build")
    echo "Dev mode: source bind-mounted from $(pwd)"
fi

# ── Shell mode ────────────────────────────────────────────────────────────────
if [ "$SHELL_MODE" -eq 1 ]; then
    echo "Dropping into builder shell (--privileged)"
    # The image entrypoint is the build pipeline, so override it to get a shell.
    docker run -it --entrypoint bash "${DOCKER_RUN_ARGS[@]}" "$IMAGE_NAME"
    exit $?
fi

# ── Run the build ─────────────────────────────────────────────────────────────
echo ""
echo "Starting larch-os build inside Docker (--privileged)"
echo "Output will appear at: $OUTPUT_DIR/larch-os.iso"
echo ""

if [ "${#BUILD_ARGS[@]}" -gt 0 ]; then
    # Stage flags (--stage/--only/--clean) are forwarded straight to the entrypoint.
    docker run "${DOCKER_RUN_ARGS[@]}" "$IMAGE_NAME" "${BUILD_ARGS[@]}"
else
    docker run "${DOCKER_RUN_ARGS[@]}" "$IMAGE_NAME"
fi

# ── Show result ───────────────────────────────────────────────────────────────
ISO="$OUTPUT_DIR/larch-os.iso"
if [ -f "$ISO" ]; then
    SIZE=$(du -sh "$ISO" | cut -f1)
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "  Build successful!"
    echo "  $ISO  ($SIZE)"
    echo "╚══════════════════════════════════════════════╝"
else
    echo "WARNING: ISO not found at $ISO — check build output above." >&2
    exit 1
fi
