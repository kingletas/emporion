#!/usr/bin/env bash
#
# compose-down.sh — stop the Compose runtime.
#
# Usage:  scripts/compose-down.sh [-v] [-y] [-n] [-h]
#
#   -v   ALSO delete this SITE's volumes: pub/media and its staged static
#        content. Destructive and irreversible, and it prompts.
#
#        IT DOES NOT TOUCH THE DATABASE, the search index or the queues. Those
#        belong to the data project, which several sites may share, and taking
#        them down from here would destroy other stores' data to clean up this
#        one. To remove a site completely -- its database, its indices, its
#        keyspaces and its vhost included -- use the command that knows which
#        of those are this site's:
#
#          make destroy-site SITE=<host>
#   -y   skip the prompt (for unattended use)
#   -n   dry run
#   -h   this header
#
# Without -v the containers go and every volume stays, so `make compose-up`
# comes back to the same installed store. The data tier keeps running either
# way: it is a different project, and other sites are attached to it.
#
# It never touches the shared proxy network: that is declared external in
# docker-compose.yaml precisely so stopping this stack cannot take down the
# proxy every other .test host on this machine routes through.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

VOLUMES=0; YES=0; DRY=0
while getopts ":vynh" opt; do
    case "$opt" in
        v) VOLUMES=1 ;;
        y) YES=1 ;;
        n) DRY=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need docker

ARGS=(down --remove-orphans)
if [[ $VOLUMES -eq 1 ]]; then
    ARGS+=(--volumes)
    if [[ $DRY -eq 0 && $YES -eq 0 ]]; then
        warn "This deletes pub/media and the staged static content for ${SITE} (project '${COMPOSE_PROJECT}')."
    warn "Its database, search index and queues are in ${DATA_PROJECT} and are NOT touched."
    warn "To remove those too:  make destroy-site SITE=${SITE}"
        read -r -p "  Type the project name to confirm: " reply
        [[ "$reply" == "$COMPOSE_PROJECT" ]] || die "not confirmed — nothing was removed"
    fi
fi

if [[ $DRY -eq 1 ]]; then
    log "Dry run — would run: docker compose -p ${COMPOSE_PROJECT} ${ARGS[*]}"
    exit 0
fi

dc "${ARGS[@]}"
log "${SITE} stopped$([[ $VOLUMES -eq 1 ]] && printf ', its volumes removed' || printf ', volumes kept')"
