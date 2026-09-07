#!/usr/bin/env bash
#
# build-image.sh — build the application image and load it into the cluster.
#
# No registry. kind takes an image straight from the local daemon, and
# introducing a registry for a single-node local cluster would be scope
# invented for its own sake.
#
# Usage:  scripts/build-image.sh [-t TARGET] [-n] [-h]
#
#   -t   build target: runtime (default) | dev | builder | php-base
#   -n   dry run: print the docker command, build nothing
#   -h   this header
#
# Environment overrides:
#   MAGENTO_SRC        Magento tree to build   (default: the commerce-vanilla
#                                              tree; see scripts/lib.sh)
#   IMAGE_NAME         image name              (default: magento-app)
#   IMAGE_TAG          image tag               (default: dev)
#   COMPILE_EXCLUDES   vendor packages removed before di:compile
#                                              (default: empty — nothing in
#                                              this tree needs excluding)
#   SKIP_COMPILE       true to skip di:compile and static deploy
#   STATIC_LOCALES     locales for the static deploy  (default: en_US)
#   CLUSTER_NAME       kind cluster to load into      (default: vanilla)
#   NO_LOAD            set to 1 to build without loading into the cluster
#
# The dev target contains no application code on purpose — the dev overlay
# mounts the working tree in. See ADR-007.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

TARGET=runtime
DRY=0
while getopts ":t:nh" opt; do
    case "$opt" in
        t) TARGET="$OPTARG" ;;
        n) DRY=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need docker

# Empty, and that is the correct state rather than an oversight. Nothing in
# this tree is SourceGuardian-encoded and nothing in it fails di:compile, so
# the image contains exactly what composer.lock says it should. The mechanism
# stays because the next dependency that cannot be compiled should be excluded
# loudly rather than worked around silently -- see the Dockerfile's own note.
COMPILE_EXCLUDES="${COMPILE_EXCLUDES-}"
SKIP_COMPILE="${SKIP_COMPILE:-false}"
STATIC_LOCALES="${STATIC_LOCALES:-en_US}"

case "$TARGET" in
    runtime|builder) TAG="${IMAGE_NAME}:${IMAGE_TAG}" ;;
    dev)             TAG="${IMAGE_NAME}:${IMAGE_TAG}-dev" ;;
    php-base)        TAG="${IMAGE_NAME}:${IMAGE_TAG}-base" ;;
    *) die "unknown target '${TARGET}'; try -h" ;;
esac

args=(
    docker build
    --progress=plain
    --target "$TARGET"
    --tag "$TAG"
    --build-arg "COMPILE_EXCLUDES=${COMPILE_EXCLUDES}"
    --build-arg "SKIP_COMPILE=${SKIP_COMPILE}"
    --build-arg "STATIC_LOCALES=${STATIC_LOCALES}"
)

# Only the targets that actually contain application code need the source.
if [[ "$TARGET" == "runtime" || "$TARGET" == "builder" ]]; then
    [[ -d "$MAGENTO_SRC" ]] || die "MAGENTO_SRC does not exist: ${MAGENTO_SRC}"
    [[ -f "${MAGENTO_SRC}/bin/magento" ]] \
        || die "${MAGENTO_SRC} has no bin/magento — that is not a Magento root"
    args+=( --build-context "magento-src=${MAGENTO_SRC}" )
    args+=( --build-arg "GIT_SHA=$(git -C "$MAGENTO_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)" )
    log "Source: ${MAGENTO_SRC}"
    if [[ -n "$COMPILE_EXCLUDES" ]]; then
        warn "This image will NOT contain: ${COMPILE_EXCLUDES}"
        warn "That is a deliberate divergence from the Compose environment. See ADR-004."
    fi
fi

args+=( "${K8S_REPO_ROOT}/build" )

if [[ $DRY -eq 1 ]]; then
    # printf reuses its format string once per argument, so a single
    # "would run: %q" prefix repeats itself for every word. The prefix is
    # printed once and the arguments quoted after it.
    printf '  would run:'
    printf ' %q' "${args[@]}"
    printf '\n'
    exit 0
fi

log "Building ${TAG} (target: ${TARGET})"
DOCKER_BUILDKIT=1 "${args[@]}"

if [[ "${NO_LOAD:-0}" == "1" ]]; then
    log "NO_LOAD=1 — not loading into the cluster"
    exit 0
fi

need kind
if ! cluster_exists; then
    warn "no cluster '${CLUSTER_NAME}' — image built but not loaded"
    exit 0
fi

log "Loading ${TAG} into kind cluster '${CLUSTER_NAME}'"
kind load docker-image "$TAG" --name "$CLUSTER_NAME"

log "Done: ${TAG}"
docker image inspect "$TAG" --format '  digest: {{index .RepoDigests 0}}{{"\n"}}  id:     {{.Id}}{{"\n"}}  size:   {{.Size}}' 2>/dev/null \
    || docker image inspect "$TAG" --format '  id:   {{.Id}}{{"\n"}}  size: {{.Size}}'
