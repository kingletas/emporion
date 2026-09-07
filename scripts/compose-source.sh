#!/usr/bin/env bash
#
# compose-source.sh — report or change where a site's application code comes from.
#
# Usage:  scripts/compose-source.sh              report every site
#         scripts/compose-source.sh mounted      switch this site to the working tree
#         scripts/compose-source.sh image        switch it back to the built image
#
# Environment overrides:
#   SITE   which site   (default: vanilla.test)
#
# Two sources, and the choice is a property of the site rather than a flag on a
# command — see the SITE_SOURCE note in scripts/lib.sh for why a flag would be
# unsafe here.
#
#   image     the built artifact, `compose-build` puts the code inside it.
#             The deliverable, the default, and what the prod-shaped overlay
#             and the cluster both use.
#
#   mounted   ${MAGENTO_SRC} is bind-mounted at /app, in developer mode, with
#             the containers running as the host user. An edit is live; nothing
#             is rebuilt. It resembles production in no way at all.
#
# Changing it RECREATES this site's containers, because it changes which
# compose files the project is made of. Nothing else is touched: the database,
# the media and the site's configuration are all outside the application tier.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }

want="${1:-}"

if [[ -z "$want" ]]; then
    printf '  %-24s %-10s %s\n' SITE SOURCE TREE
    while read -r site; do
        [[ -n "$site" ]] || continue
        SITE="$site" SITE_SOURCE="" SITE_ENV_FILE="" MAGENTO_SRC="" resolve_site >/dev/null 2>&1 || true
        src="$(SITE_ENV_FILE="${CONFIG_ENV_DIR}/sites/${site//./-}.env" env_value_or SITE_SOURCE image)"
        tree="$(SITE_ENV_FILE="${CONFIG_ENV_DIR}/sites/${site//./-}.env" env_value_or SITE_MAGENTO_SRC "$MAGENTO_SRC")"
        printf '  %-24s %-10s %s\n' "$site" "$src" "${tree:-—}"
    done < <(site_list)
    exit 0
fi

case "$want" in
    image|mounted) ;;
    *) die "source must be 'image' or 'mounted', not '${want}'" ;;
esac

site_exists "$SITE" || die "no site '${SITE}'. Existing sites: $(site_list | tr '\n' ' ')"

current="$(env_value_or SITE_SOURCE image)"
if [[ "$current" == "$want" ]]; then
    log "${SITE} already reads its code from the ${want}"
    exit 0
fi

# Rewritten in place: the key is either already there or it is appended.
if grep -q '^SITE_SOURCE=' "$SITE_ENV_FILE"; then
    sed -i "s/^SITE_SOURCE=.*/SITE_SOURCE=${want}/" "$SITE_ENV_FILE"
else
    printf '\n# Where the application code comes from: image | mounted.\n# See scripts/compose-source.sh.\nSITE_SOURCE=%s\n' "$want" >>"$SITE_ENV_FILE"
fi

log "${SITE}: ${current} -> ${want}"

if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null)" ]]; then
    cat <<MSG

  The site is up and still running on the ${current}. Recreate it:

    make compose-up SITE=${SITE}

MSG
fi

if [[ "$want" == "mounted" ]]; then
    cat <<MSG
  Mounted sites run in DEVELOPER MODE against ${MAGENTO_SRC}.
  Nothing measured there says anything about production.

MSG
fi
