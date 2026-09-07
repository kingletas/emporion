#!/usr/bin/env bash
#
# cluster-down.sh — destroy the kind cluster completely.
#
# Destructive and deliberately total: every PVC goes with it, which is the
# point: the requirement is that the cluster can be destroyed and recreated
# unattended, and a teardown that preserves state does not test that.
#
# Usage:  scripts/cluster-down.sh [-n] [-y] [-h]
#
#   -n   dry run: say what would be destroyed, destroy nothing
#   -y   skip the confirmation prompt (unattended use, e.g. `make down`
#        inside a CI-shaped rebuild loop)
#   -h   this header
#
# Environment overrides:
#   CLUSTER_NAME   kind cluster name   (default: vanilla)
#
# It does not touch the Compose runtime, its named volumes, or the Magento
# tree at MAGENTO_SRC. The only state it destroys is state the cluster itself
# created -- which for this store is all of it, since the database is installed
# into the cluster rather than copied in.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

DRY=0; YES=0
while getopts ":nyh" opt; do
    case "$opt" in
        n) DRY=1 ;;
        y) YES=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need kind

if ! cluster_exists; then
    log "No cluster named '${CLUSTER_NAME}' — nothing to do"
    exit 0
fi

cat <<EOF

  This destroys the kind cluster '${CLUSTER_NAME}' and everything in it:

    - every PersistentVolumeClaim (database, search indexes, queues,
      sessions, uploaded media) — irrecoverably
    - the node container and its image cache, so the next \`make up\`
      rebuilds and reloads the application image

  Nothing outside the cluster is touched.

EOF

if [[ $DRY -eq 1 ]]; then
    log "Dry run — cluster left alone."
    exit 0
fi

if [[ $YES -eq 0 ]]; then
    read -r -p "Destroy it? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "aborted"
fi

log "Deleting cluster '${CLUSTER_NAME}'"
kind delete cluster --name "$CLUSTER_NAME"
log "Gone."
