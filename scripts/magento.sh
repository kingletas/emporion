#!/usr/bin/env bash
#
# magento.sh — run bin/magento inside the background PHP pool.
#
# Usage:  scripts/magento.sh <magento arguments...>
#         scripts/magento.sh cache:flush
#         scripts/magento.sh indexer:reindex catalog_product_price
#
# Environment overrides:
#   NAMESPACE   namespace              (default: vanilla)
#   POOL        deployment to exec in  (default: php-cron)
#
# php-cron rather than php-fpm on purpose: a reindex run inside a pod that is
# also serving storefront traffic competes with it for the container's memory
# limit, and the php-cron pool exists precisely so that work has somewhere
# else to go.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }
[[ $# -gt 0 ]] || die "nothing to run. Try: scripts/magento.sh cache:flush"

need kubectl
POOL="${POOL:-php-cron}"

# `kc` is a shell FUNCTION from lib.sh, and `exec` replaces the process image
# with a file on PATH -- it cannot run a function, so `exec kc ...` failed
# with "exec: kc: not found" and made `make cli` unusable. Calling the
# function normally is the fix; the exec was only ever saving one process.
#
# -c names the container explicitly. The dev overlay adds init containers,
# and kubectl picks the first container in the pod spec when none is given,
# which prints a "Defaulted container" warning onto the output that callers
# parse.
kc -n "$NAMESPACE" exec -i "deploy/${POOL}" -c "${CONTAINER:-php-fpm}" -- \
    php -d memory_limit=-1 bin/magento "$@"
