#!/usr/bin/env bash
#
# compose-up.sh — start the production-shaped Compose runtime.
#
# The mirror of cluster-up.sh, and it refuses in the same direction: these are
# two runtimes for ONE store, sharing a hostname and a host, and running both
# takes this machine to a load average in the hundreds with swap exhausted.
#
# Usage:  scripts/compose-up.sh [-b] [-n] [-h]
#
#   -b   rebuild the application image before starting
#   -n   dry run: print what it would do, start nothing
#   -h   this header
#
# Environment overrides:
#   SITE              which site to start     (default: vanilla.test)
#   COMPOSE_PROJECT   compose project name   (default: the site's slug)
#   MAGENTO_SRC       Magento tree to build  (see scripts/lib.sh)
#   ALLOW_BOTH        set to 1 to override the cluster guard
#
# It regenerates the credential files first, so a fresh clone needs no manual
# step before this works.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

BUILD=0; DRY=0
while getopts ":bnh" opt; do
    case "$opt" in
        b) BUILD=1 ;;
        n) DRY=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need docker

[[ -d "$MAGENTO_SRC" ]] || die "no Magento tree at ${MAGENTO_SRC}. Set MAGENTO_SRC, or check scripts/lib.sh."

# --- the other half of the one-stack-at-a-time guard ------------------------
# cluster-up.sh refuses while this stack is running; this refuses while the
# cluster exists. Checking for the CLUSTER rather than for running pods is
# deliberate: a stopped kind cluster still holds its node container, its
# volumes and its port bindings on 127.0.0.1:80.
if cluster_exists; then
    if [[ "${ALLOW_BOTH:-0}" == "1" ]]; then
        warn "the '${CLUSTER_NAME}' cluster exists and ALLOW_BOTH=1 was set."
        warn "Watch free memory. This combination has made this laptop unusable."
    else
        die "the '${CLUSTER_NAME}' kind cluster exists, and the two runtimes do not fit together.

  Destroy it first:   make down
  Then come back:     make compose-up

  Switching is meant to be cheap, not simultaneous. Set ALLOW_BOTH=1 to
  override, and watch free memory if you do."
    fi
fi

if [[ $DRY -eq 1 ]]; then
    log "Dry run — would generate credentials, then bring up project '${COMPOSE_PROJECT}'"
    dc config --services | sed 's/^/    /'
    exit 0
fi

log "Generating credentials"
"${HERE}/secrets.sh"

if [[ $BUILD -eq 1 ]]; then
    log "Building the application image from ${MAGENTO_SRC}"
    dc build
fi

# TWO STEPS, TWO PROJECTS, and the split is the same one scripts/deploy.sh
# makes for the cluster. The data tier can be healthy on its own, so it is
# waited for: --wait blocks until every healthcheck passes and exits non-zero
# if one never does, which is what stops the next command failing because
# MariaDB was still recovering InnoDB.
#
# This wait is also what REPLACED the `depends_on: service_healthy` the
# application services used to carry. Those could not survive the data tier
# moving to its own Compose project — depends_on does not reach across one —
# so the ordering became explicit here rather than implicit there. Same
# guarantee, in a place a person can read.
#
# The application tier CANNOT be healthy before the store is installed --
# varnish probes health_check.php, which needs a schema -- so waiting on it here
# would time out on every fresh stack and report a failure that is just the
# ordering. compose-install.sh does that wait, after the install.
log "Starting the data tier '${DATA_PROJECT}'"
dc_data up -d --wait

# Idempotent, and run on every `up` rather than only at creation. A site whose
# database was dropped, or whose data tier was recreated from empty, would
# otherwise come up and fail its install with an access-denied error that reads
# like a wrong password.
provision_data

log "Starting the application tier for ${SITE}"
dc up -d

cat <<EOF

  Data tier is healthy and the application tier is starting.

  THE STOREFRONT DOES NOT ANSWER YET if this is a fresh stack -- there is no
  schema in the database until:

    make compose-install       install the store, or upgrade it if installed

  Then:  https://${SITE_HOST}/         through nginx-proxy, no /etc/hosts line
  Mail:  https://mail.${SITE_HOST}/

EOF
