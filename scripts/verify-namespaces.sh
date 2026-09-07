#!/usr/bin/env bash
#
# verify-namespaces.sh — check that a RUNNING store is using the namespaces its
# config says it should, and that no two running stores share one.
#
# Usage:  scripts/verify-namespaces.sh [-a] [-h]
#
#   -a   every running site, not just $SITE
#   -h   this header
#
# WHY THIS EXISTS, and it is the same reason verify-consumers.sh does: nothing
# else will make this check, and every way of getting it wrong is silent.
#
# Five values keep two stores out of each other's data — the database, the
# cache prefix, the search index prefix, the queue vhost and the Valkey
# database numbers. All five are set in the site's config file, and all five
# reach Magento through an env.php that magento-entrypoint GENERATES INSIDE THE
# IMAGE. So the config can be right, `docker compose config` can be right, the
# container's environment can be right, and the store can still be using
# somebody else's index — because the image was not rebuilt.
#
# THAT IS NOT HYPOTHETICAL. It is how this check came to exist. The entrypoint
# had `opensearch_index_prefix` and the queue `virtualhost` as literals, both
# were parameterised, both site config files were correct, `env | grep` inside
# the container showed the right values, and env.php still said `magento2` and
# `/` because the image predated the change. A second store was writing into
# the first store's search index and neither of them could tell.
#
# It compares what env.php ACTUALLY says against the config, which is the only
# comparison that can catch a stale artefact.

set -uo pipefail   # NOT -e: every site must be checked even after one fails.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

ALL=0
while getopts ":ah" opt; do
    case "$opt" in
        a) ALL=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

fail=0
declare -A seen_by

# Pull one value out of the generated env.php. Reading the file the application
# loads, rather than asking Magento, so this works on a store that is too
# broken to run a CLI command -- which is exactly when it is worth asking.
env_php_value() {
    local slug="$1" pattern="$2"
    docker exec "${slug}-php-cron-1" sed -n "$pattern" /etc/magento/env.php 2>/dev/null | head -n1
}

check_site() {
    # One `local` per variable — the trap scripts/lib.sh documents: a single
    # `local a=... b="${a}"` localises every name first and only then assigns,
    # so ${a} expands while it is still unset.
    local host="$1"
    local slug="${host//./-}"
    docker ps -q --filter "label=com.docker.compose.project=${slug}" | grep -q . || return 0

    ( # a subshell so SITE and everything lib.sh derives from it stay local
      resolve_site "$host"

      printf '\n  %s\n' "$host"
      local bad=0
      compare() {
          local label="$1" want="$2" have="$3"
          if [[ "$want" == "$have" ]]; then
              printf '    %-16s %-24s ok\n' "$label" "$have"
          else
              printf '    %-16s %-24s MISMATCH — config says %s\n' "$label" "${have:-<empty>}" "$want"
              bad=1
          fi
      }

      compare "database"     "$(env_value DB_NAME)" \
              "$(env_php_value "$slug" "s/.*'dbname' => '\([^']*\)'.*/\1/p")"
      compare "cache prefix"  "$(env_value MAGENTO_CACHE_PREFIX)" \
              "$(env_php_value "$slug" "s/.*'id_prefix' => '\([^']*\)'.*/\1/p")"
      compare "search prefix" "$(env_value OPENSEARCH_INDEX_PREFIX)" \
              "$(env_php_value "$slug" "s/.*'opensearch_index_prefix' => '\([^']*\)'.*/\1/p")"
      compare "queue vhost"   "$(env_value RABBITMQ_VIRTUALHOST)" \
              "$(env_php_value "$slug" "s/.*'virtualhost' => '\([^']*\)'.*/\1/p")"
      compare "base url"      "$(env_value MAGENTO_BASE_URL)" \
              "$(env_php_value "$slug" "s/.*'base_url' => '\([^']*\)'.*/\1/p")"

      # The Valkey database numbers are three values with the same key name, so
      # they are read positionally: session, cache, page_cache, in the order
      # magento-entrypoint writes them.
      local dbs
      dbs="$(docker exec "${slug}-php-cron-1" sed -n "s/.*'database' => '\([0-9]*\)'.*/\1/p" \
             /etc/magento/env.php 2>/dev/null | tr '\n' ' ')"
      compare "valkey dbs" \
          "$(env_value REDIS_SESSION_DB) $(env_value REDIS_CACHE_DB) $(env_value REDIS_PAGE_CACHE_DB) " \
          "$dbs"

      exit $bad
    ) || fail=1

    # Collision detection across sites, in the parent so the map survives.
    local k v
    for k in DB_NAME MAGENTO_CACHE_PREFIX OPENSEARCH_INDEX_PREFIX RABBITMQ_VIRTUALHOST REDIS_CACHE_DB; do
        v="$(SITE="$host" SITE_ENV_FILE="${CONFIG_ENV_DIR}/sites/${slug}.env" \
             sed -n "s/^${k}=//p" "${CONFIG_ENV_DIR}/sites/${slug}.env" | head -n1)"
        [[ -n "$v" ]] || continue
        if [[ -n "${seen_by[${k}=${v}]:-}" ]]; then
            warn "COLLISION: ${k}=${v} is used by both ${seen_by[${k}=${v}]} and ${host}"
            fail=1
        fi
        seen_by[${k}=${v}]="$host"
    done
}

if (( ALL )); then
    while IFS= read -r h; do [[ -n "$h" ]] && check_site "$h"; done < <(site_list)
else
    check_site "$SITE"
fi

echo
if (( fail )); then
    die "a running store is not using the namespaces its config declares.

  The usual cause is a STALE IMAGE: magento-entrypoint writes env.php and lives
  inside the image, so a config change does nothing until the image is rebuilt
  and the containers replaced.

    ./scripts/build-image.sh -t runtime
    make compose-install SITE=<site>"
fi
log "Every running store is using its own namespaces."
