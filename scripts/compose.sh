#!/usr/bin/env bash
#
# compose.sh — run `docker compose` against one site's application tier.
#
# Usage:  scripts/compose.sh <docker compose arguments...>
#         scripts/compose.sh -h
#
# Environment overrides:
#   SITE   which site   (default: vanilla.test)
#
# A passthrough, and it exists because a raw `docker compose` cannot be used
# here any more. docker-compose.yaml interpolates its project name, its
# hostname, both config files, its secrets directory and its data network, and
# every one of those is derived from SITE in scripts/lib.sh. Running the file
# directly fails on the `:?` guards -- deliberately, because the alternative is
# a stack that starts with an empty VIRTUAL_HOST and simply never routes.
#
# The Makefile's inspection targets go through this rather than through a `DC`
# variable, so there is one place that knows how to address a site.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }
[[ $# -gt 0 ]] || die "nothing to run. Try: scripts/compose.sh ps"

site_exists "$SITE" || die "no site '${SITE}'. Existing sites: $(site_list | tr '\n' ' ')"

dc "$@"
