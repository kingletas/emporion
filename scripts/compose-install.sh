#!/usr/bin/env bash
#
# compose-install.sh — install or upgrade the store in the Compose runtime.
#
# A thin caller. Every decision is inside magento-install, in the image, which
# the cluster's Job runs identically — see build/rootfs/usr/local/bin/
# magento-install. Idempotent: it installs an empty database and upgrades an
# installed one, so this is safe to run on every deploy.
#
# Usage:  scripts/compose-install.sh [-n] [-h]
#
#   -n   dry run: ask magento-install what it would do, change nothing
#   -h   this header
#
# It runs in a one-shot container behind the `install` profile rather than in a
# running service, so a schema change is never something that happens because a
# container restarted.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

DRY=0
while getopts ":nh" opt; do
    case "$opt" in
        n) DRY=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need docker

compose_running || die "${SITE} is not up. Run: make compose-up SITE=${SITE}"

ARGS=(--profile install run --rm --no-deps magento-install magento-install)
[[ $DRY -eq 1 ]] && ARGS+=(-n)

log "Running magento-install for ${SITE} (project ${COMPOSE_PROJECT})"
dc "${ARGS[@]}"

[[ $DRY -eq 1 ]] && exit 0

# Restart the application tier before waiting on it, for the same reason
# scripts/deploy.sh rolls the Deployments after the cluster's install Job:
# setup:install writes its OWN env.php into the shared volume, and the
# containers that were already running still hold the one their entrypoint
# generated. Restarting makes every container regenerate the canonical file
# from the shared config, so all of them agree.
# The consumers are in this list too, and leaving them out was a real bug: they
# start with the stack, crash-loop against a database with no schema, and are
# still looping when the install finishes. Nothing restarts them and the stack
# reports itself up.
log "Restarting the application tier so every container regenerates env.php"
# shellcheck disable=SC2046 # deliberate word splitting: one service per argument
dc restart $(app_services | grep -vx varnish)

# VARNISH LAST, AND ON ITS OWN, because varnishd resolves the backend
# hostnames in its VCL ONCE — when the VCL is compiled at startup — and never
# again. Restarted alongside the pools it points at, it keeps whichever
# addresses those containers had a moment ago, every probe fails against an
# address nothing is listening on, and the edge sits at
#
#   Backend name  Admin  Probe  Health   Last change
#   boot.web      probe  0/5    sick     ...
#
# answering 503 while `getent hosts web` inside that same container returns the
# correct new address. The stack reports itself started and the storefront is
# down, which is the shape of failure this repository keeps finding.
log "Restarting the edge, after its backends, so it resolves them fresh"
dc restart varnish

# The wait belongs here rather than in compose-up.sh. Varnish probes
# health_check.php through the whole chain, which needs a schema -- so before
# this script runs it cannot pass, and after it runs it is the honest proof
# that the edge can serve. Failing here is a real failure.
log "Waiting for the edge to report healthy"
dc up -d --wait

cat <<EOF

  The store is installed and the edge is healthy.

    https://${SITE_HOST}/

  Admin password: ${SECRETS_DIR}/magento-admin-password

EOF
