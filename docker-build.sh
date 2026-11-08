#!/bin/bash
# docker-build.sh — convenience wrapper for building larch-os inside Docker
#
# Two builds (see docker-entrypoint.sh):
#   ./docker-build.sh                      # both → output/system/ + output/larch-installer.iso
#   ./docker-build.sh system               # the system release files → output/system/
#   ./docker-build.sh installer            # the installer ISO (needs system stages 2-4)
#   ./docker-build.sh system --stage 6     # resume a build from a stage
#   ./docker-build.sh installer --only 2   # run exactly one stage
#   ./docker-build.sh system --to 4        # stop after a stage (4 = the base, enough for the installer)
#   ./docker-build.sh system --desktop gnome   # only some desktops (or LARCH_DESKTOPS="gnome kde")
#
# Modes:
#   --dev     bind-mount the source (faster iteration, no image rebuild)
#   --shell   drop into a shell inside the builder container
#   --clean   delete output/ and work/
#
# LARCH_VERSION (e.g. the release tag) is stamped into the image and shown by
# the updater; local builds default to dev-<timestamp>.
#
# Requirements:
#   - Docker with --privileged support (Linux host recommended)
#   - On macOS/Windows: Docker Desktop with the "Use Rosetta" or standard x86-64 VM

set -euo pipefail

IMAGE_NAME="larch-os-builder"
OUTPUT_DIR="$(pwd)/output"
WORK_DIR="$(pwd)/work"   # shared build cache in dev mode

DEV_MODE=0
SHELL_MODE=0
CLEAN_MODE=0
BUILD_ARGS=()
TARGET=all

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev)    DEV_MODE=1;   shift ;;
        --shell)  SHELL_MODE=1; shift ;;
        --clean)  CLEAN_MODE=1; shift ;;
        system|installer) TARGET="$1"; BUILD_ARGS+=("$1"); shift ;;
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
    -v "$OUTPUT_DIR:/output"          # release files + ISO go here
    -e "LARCH_OUTPUT_DIR=/output"
)
for _var in LARCH_VERSION LARCH_DESKTOPS; do
    if [ -n "${!_var:-}" ]; then DOCKER_RUN_ARGS+=(-e "$_var=${!_var}"); fi
done

# Always mount work/ from the host so the debootstrap rootfs cache
# survives across container runs and --stage N actually resumes correctly.
mkdir -p "$WORK_DIR"
DOCKER_RUN_ARGS+=(-v "$WORK_DIR:/build/work")

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
echo "Output will appear in: $OUTPUT_DIR"
echo ""

if [ "${#BUILD_ARGS[@]}" -gt 0 ]; then
    # Stage flags (--stage/--only/--clean) are forwarded straight to the entrypoint.
    docker run "${DOCKER_RUN_ARGS[@]}" "$IMAGE_NAME" "${BUILD_ARGS[@]}"
else
    docker run "${DOCKER_RUN_ARGS[@]}" "$IMAGE_NAME"
fi

# ── Show result ───────────────────────────────────────────────────────────────
echo ""
case "$TARGET" in
    system)    WANT=("$OUTPUT_DIR/system/SHA256SUMS") ;;
    installer) WANT=("$OUTPUT_DIR/larch-installer.iso") ;;
    *)         WANT=("$OUTPUT_DIR/system/SHA256SUMS" "$OUTPUT_DIR/larch-installer.iso") ;;
esac
# A partial run (--to/--only/--stage) needn't produce the final files.
for f in "${WANT[@]}"; do
    if [ -f "$f" ]; then
        echo "  $f  ($(du -sh "$f" | cut -f1))"
    else
        echo "  (not produced by this run: $f)"
    fi
done
