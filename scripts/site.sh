#!/usr/bin/env bash
#
# site.sh — stand up, list, park and destroy Magento stores on this machine.
#
# WHAT A SITE IS. A hostname, a small config file, a set of credentials, and a
# Compose project running its own application tier. Everything else it shares:
# the image, the Magento tree, and — in the default mode — one data tier.
#
#   scripts/site.sh new second.test [-m MODE] [-s SNAPSHOT] [-y] [-n]
#   scripts/site.sh list
#   scripts/site.sh up|down|destroy second.test
#   scripts/site.sh use second.test          give this site the background work
#   scripts/site.sh park second.test         take it away again
#   scripts/site.sh data-up|data-down
#
#   -m   shared (default) or exclusive. Shared attaches to the one data tier;
#        exclusive gives this site its own MariaDB, OpenSearch, RabbitMQ and
#        Valkey pair, and costs 3.2 GiB instead of 1.5.
#   -s   seed from this snapshot          (default: sample-data-baseline)
#        `-s none` installs from empty instead, which takes about 20 minutes
#        against a restore's 49 seconds.
#   -y   skip prompts, for unattended use
#   -n   dry run: print the plan, change nothing
#   -h   this header
#
# Environment overrides:
#   SNAPSHOT_DIR   where snapshots live   (default: ../snapshots, beside this repo)
#   DEV_CERT_TOOL  a local wrapper around mkcert, if you have one
#                  (default: dev-vhost-cert; plain mkcert is used if absent)
#   ALLOW_TIGHT    set to 1 to create a site the memory check refuses
#
# THIS IS A WORKSTATION, NOT A DATACENTER, and nothing below is capacity
# planning. The point is standing a store up on demand and switching between
# stores cheaply; two being up at once is convenience rather than a target.
# One store is the normal state, and `destroy` is expected to be used.
#
# WHY SHARED IS THE DEFAULT, in numbers measured on this host rather than
# assumed. One installed store idles at 3.22 GiB across 21 containers, and the
# data tier is 1.75 GiB of it — MariaDB and the OpenSearch JVM alone are half
# the stack, and neither is per-site work. So:
#
#   two full stacks            6.44 GiB idle, against ~10 GiB available
#   shared, both working       4.68 GiB
#   shared, one parked         3.82 GiB
#
# IDLE IS NOT THE RISK, AND THIS IS THE PART A MEMORY TABLE HIDES. Per site the
# declared ceilings are php-cron 4g + magento-cron 4g + six consumers at 1g:
# 14 GiB for ONE site. A single store can already overcommit this laptop, so
# what has to be bounded is how many sites do background work, not how many
# exist. `use` and `park` are that bound — every site serves, one site works.
#
# THE CRYPT KEY IS INHERITED WHEN A SITE IS SEEDED, deliberately and visibly.
# A snapshot records a fingerprint of the key that encrypted it; a store with a
# different key restores those rows as bytes it cannot read. Generating a fresh
# key for every seeded site would fire that warning every single time, and a
# warning that fires on the normal case is one nobody reads. So a seeded site
# takes the key of the store the snapshot came from, `list` prints every site's
# fingerprint so sharing is visible, and only an empty site gets its own.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${K8S_REPO_ROOT%/*}/snapshots}"
DEFAULT_SNAPSHOT="${DEFAULT_SNAPSHOT:-sample-data-baseline}"

# Valkey offers 16 databases by default and a site takes two of the cache one,
# so a shared tier holds eight stores. Refused rather than wrapped: two sites
# on one keyspace is the collision this allocation exists to prevent.
MAX_SITES=8

# --- helpers ----------------------------------------------------------------

# A site is reachable only because dnsmasq maps *.test to the proxy and mkcert
# can issue for it. Any other suffix resolves nowhere and has no cert path, so
# it is refused at the point a person types it rather than four steps later.
validate_host() {
    local host="$1"
    [[ "$host" =~ ^[a-z0-9][a-z0-9.-]*\.test$ ]] \
        || die "'${host}' is not usable as a site hostname.

  It must be lowercase and end in .test — that suffix is what dnsmasq already
  resolves to the proxy on 172.17.0.1, and what mkcert can issue for. Anything
  else needs a DNS entry and a certificate that do not exist."
    [[ "$host" != "mail."* ]] || die "'mail.' is reserved: every site's mail sink is served at mail.<site>"
}

# The Redis databases already spoken for, so a new site cannot be handed one
# that is in use. Read from the site files rather than tracked in a counter: a
# counter and the files can disagree, and only one of them is what runs.
allocate_dbs() {
    local used=() f n
    for f in "${CONFIG_ENV_DIR}"/sites/*.env; do
        [[ -e "$f" ]] || continue
        n="$(sed -n 's/^REDIS_CACHE_DB=//p' "$f" | head -n1)"
        [[ -n "$n" ]] && used+=("$n")
    done
    local i
    for (( i = 0; i < MAX_SITES; i++ )); do
        local cache=$(( i * 2 ))
        local taken=0 u
        for u in "${used[@]:-}"; do [[ "$u" == "$cache" ]] && taken=1; done
        (( taken )) && continue
        printf '%s %s %s' "$cache" "$(( cache + 1 ))" "$i"
        return 0
    done
    die "all ${MAX_SITES} Valkey database slots are in use. Destroy a site first: make sites"
}

# Refuse to create a site this machine cannot hold, in the same shape as the
# one-runtime-at-a-time guard: a named refusal with an override, rather than a
# warning nobody reads. The projections are measured, not budgeted.
check_memory() {
    local mode="$1" need avail
    case "$mode" in
        shared)    need=1500 ;;
        exclusive) need=3300 ;;
    esac
    avail="$(free -m | awk '/^Mem:/ {print $7}')"
    # 2 GiB of headroom on top, because a site that fits with nothing left over
    # does not fit: an install, a reindex or a browser is what comes next.
    local want=$(( need + 2048 ))
    if (( avail < want )); then
        if [[ "${ALLOW_TIGHT:-0}" == "1" ]]; then
            warn "only ${avail} MiB available and a ${mode} site needs about ${need} MiB plus headroom."
            warn "ALLOW_TIGHT=1 was set. Watch free memory; this is the shape that produced a load average of 300."
        else
            die "not enough memory for another site.

  Available now      ${avail} MiB
  A ${mode} site     ~${need} MiB, plus 2048 MiB of headroom

  Free some first — park a site you are not working in, which drops it to
  serving only and gives back about 870 MiB:

    make park SITE=<other-site>

  Or stop one entirely:  make compose-down SITE=<other-site>
  Override deliberately: ALLOW_TIGHT=1 make new-site SITE=... "
        fi
    fi
}

# Certificates. The *.test wildcard does NOT cover a new hostname — a wildcard
# may not span a whole top-level domain, so OpenSSL and every browser reject
# `*.test` for `second.test` with a plain hostname mismatch. Each host gets its
# own certificate or it has none.
#
# mkcert is the tool, and a local wrapper around it is used when there is one:
# some setups have to reload a proxy after issuing, which mkcert cannot know
# about. DEV_CERT_TOOL names that wrapper; it is called as `<tool> issue <host>...`.
issue_certs() {
    local host="$1" tool="${DEV_CERT_TOOL:-dev-vhost-cert}"

    if command -v "$tool" >/dev/null 2>&1; then
        log "Issuing certificates for ${host} and mail.${host} with ${tool}"
        "$tool" issue "$host" "mail.${host}"
        return 0
    fi

    if command -v mkcert >/dev/null 2>&1; then
        log "Issuing certificates for ${host} and mail.${host} with mkcert"
        mkdir -p "$CERTS_HOME"
        local name
        for name in "$host" "mail.${host}"; do
            mkcert -cert-file "${CERTS_HOME}/${name}.crt" \
                   -key-file  "${CERTS_HOME}/${name}.key" "$name"
        done
        return 0
    fi

    warn "no mkcert on PATH, so no certificate was issued for ${host}."
    warn "The site will serve, and every browser will refuse it. Issue one with:"
    warn "    mkcert -cert-file ${CERTS_HOME}/${host}.crt \\"
    warn "           -key-file  ${CERTS_HOME}/${host}.key ${host}"
}

# =============================================================================
# new
# =============================================================================
cmd_new() {
    local host="${1:-}"; shift || true
    [[ -n "$host" ]] || die "which site? scripts/site.sh new second.test"
    local mode=shared snapshot="$DEFAULT_SNAPSHOT" yes=0 dry=0
    while getopts ":m:s:ynh" opt; do
        case "$opt" in
            m) mode="$OPTARG" ;;
            s) snapshot="$OPTARG" ;;
            y) yes=1 ;;
            n) dry=1 ;;
            h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
            *) die "unknown flag -${OPTARG}; try -h" ;;
        esac
    done

    validate_host "$host"
    [[ "$mode" == "shared" || "$mode" == "exclusive" ]] \
        || die "MODE must be 'shared' or 'exclusive', not '${mode}'"
    site_exists "$host" && die "${host} already exists. Start it with: make compose-up SITE=${host}"

    # Switch every derived path to the site being created rather than to
    # whatever SITE defaulted to when lib.sh was sourced. The mode is passed
    # in because this site has no config file yet to read it from, and setting
    # SITE_MODE beforehand does not survive the switch.
    resolve_site "$host" "$mode"

    local seed_file="" seed_meta="" crypt_from=""
    if [[ "$snapshot" != "none" ]]; then
        seed_file="${SNAPSHOT_DIR}/${snapshot}.sql.zst"
        [[ -f "$seed_file" ]] || die "no snapshot '${snapshot}' in ${SNAPSHOT_DIR}. See: make snapshots"
        seed_meta="${SNAPSHOT_DIR}/${snapshot}.json"
        # Find the site whose crypt key matches the snapshot's fingerprint.
        # Searching for it beats naming one: the snapshot records what
        # encrypted it, and that is the only correct answer.
        if [[ -f "$seed_meta" ]]; then
            local want d
            want="$(sed -n 's/.*"crypt_key_fingerprint": "\([^"]*\)".*/\1/p' "$seed_meta")"
            for d in "${SECRETS_ROOT}"/*/magento-crypt-key; do
                [[ -e "$d" ]] || continue
                if [[ "$(sha256sum "$d" | cut -c1-12)" == "$want" ]]; then
                    crypt_from="$d"; break
                fi
            done
            [[ -n "$crypt_from" ]] || warn "no local crypt key matches this snapshot's fingerprint (${want}).
  ${host} will get a fresh key, and anything the snapshot encrypted will restore
  as unreadable bytes. Catalogue and customer data are unaffected."
        fi
    fi

    read -r cache_db page_db session_db <<<"$(allocate_dbs)"
    check_memory "$mode"

    cat <<PLAN

  New site
    Hostname          https://${host}/
    Mail              https://mail.${host}/
    Mode              ${mode}   (data tier: ${DATA_PROJECT})
    Compose project   ${COMPOSE_PROJECT}
    Database          ${SITE_SLUG//-/_}
    Cache prefix      ${SITE_SLUG//-/_}_   (underscores: Magento rejects a hyphen here)
    Search prefix     ${SITE_SLUG}
    Queue vhost       /${SITE_SLUG}
    Valkey databases  cache ${cache_db}, page ${page_db}, session ${session_db}
    Seed              ${snapshot}$( [[ -n "$crypt_from" ]] && printf ', inheriting the crypt key from %s' "$(basename "$(dirname "$crypt_from")")" )
    Image             magento-app:${IMAGE_TAG} (shared)

PLAN

    if [[ $dry -eq 1 ]]; then
        log "Dry run — nothing was created"
        exit 0
    fi
    if [[ $yes -eq 0 ]]; then
        read -r -p "  Create it? [y/N] " reply
        [[ "$reply" == "y" || "$reply" == "Y" ]] || die "not confirmed — nothing was created"
    fi

    # --- the config file, which is what makes the site exist at all
    mkdir -p "$(dirname "$SITE_ENV_FILE")"
    cat > "$SITE_ENV_FILE" <<ENV
# ${host} — the per-site half of the configuration.
#
# Generated by scripts/site.sh. It holds only what a second store on this
# machine cannot share; everything else is in ../common.env, and both runtimes
# read the pair in that order with this file winning. See vanilla-test.env for
# what each key prevents.
#
# EDITING THIS FILE IS A DEPLOY, NOT A RESTART:
#   make compose-install SITE=${host}

# --- namespaces, one per site -----------------------------------------------
# UNDERSCORES, NOT HYPHENS, in the database name and the cache prefix. Magento
# validates every cache id against [a-zA-Z0-9_{}] and throws on anything else
# -- from bin/magento's own constructor, so a hyphenated prefix breaks every
# CLI command including the install, with a Zend_Cache stack trace that names
# the id and never the setting. The search prefix and the queue vhost both
# accept hyphens and keep the slug unchanged.
DB_NAME=${SITE_SLUG//-/_}
DB_USER=${SITE_SLUG//-/_}
MAGENTO_BASE_URL=https://${host}/
MAGENTO_CACHE_PREFIX=${SITE_SLUG//-/_}_
OPENSEARCH_INDEX_PREFIX=${SITE_SLUG}
RABBITMQ_VIRTUALHOST=/${SITE_SLUG}
REDIS_CACHE_DB=${cache_db}
REDIS_PAGE_CACHE_DB=${page_db}
REDIS_SESSION_DB=${session_db}

# --- read by the tooling, not by Magento ------------------------------------
SITE_HOST=${host}
SITE_MODE=${mode}
SITE_SEED=${snapshot}
SITE_IMAGE_TAG=
SITE_MAGENTO_SRC=
SITE_CRYPT_ORIGIN=$( [[ -n "$crypt_from" ]] && basename "$(dirname "$crypt_from")" || echo own )
ENV
    log "Wrote ${SITE_ENV_FILE}"

    issue_certs "$host"

    log "Generating credentials"
    if [[ -n "$crypt_from" ]]; then
        SITE="$host" "${HERE}/secrets.sh" -k "$crypt_from"
    else
        SITE="$host" "${HERE}/secrets.sh"
    fi

    log "Starting the data tier '${DATA_PROJECT}'"
    dc_data up -d --wait

    provision_data

    log "Starting ${host}"
    dc up -d

    if [[ -n "$seed_file" ]]; then
        log "Seeding from ${snapshot} — a restore is seconds against about twenty minutes"
        SITE="$host" "${HERE}/store-snapshot.sh" restore -f "$seed_file" -y
    fi

    log "Installing or upgrading the store"
    SITE="$host" "${HERE}/compose-install.sh"

    # PARKED ON ARRIVAL, and the message below says so. compose-install ends in
    # `dc up -d --wait`, which starts the consumers and the cron loop -- so
    # without this a new site silently takes background work alongside whichever
    # site already had it, which is the one thing the use/park bound exists to
    # prevent. Creating a store is not the same as deciding to work in it.
    cmd_park "$host"

    cat <<DONE

  ${host} is up.

    Storefront   https://${host}/
    Admin        https://${host}/admin
    Mail         https://mail.${host}/
    Password     ${SECRETS_DIR}/magento-admin-password

  It SERVES and is PARKED — no consumers, no cron, and whichever site already
  held the background work still holds it. One site at a time does that work,
  because two stores reindexing together is what overcommits this host:

    make use SITE=${host}

  Every site:  make sites

DONE
}

# =============================================================================
# list
# =============================================================================
cmd_list() {
    printf '\n  %-20s %-10s %-9s %-7s %-13s %s\n' \
        "SITE" "MODE" "STATE" "WORK" "CRYPT KEY" "SEEDED FROM"
    local host
    local found=0
    while IFS= read -r host; do
        [[ -n "$host" ]] || continue
        found=1
        local slug="${host//./-}"
        local f="${CONFIG_ENV_DIR}/sites/${slug}.env"
        local mode seed fp="—" state work
        mode="$(sed -n 's/^SITE_MODE=//p' "$f" | head -n1)"
        seed="$(sed -n 's/^SITE_SEED=//p' "$f" | head -n1)"
        [[ -s "${SECRETS_ROOT}/${slug}/magento-crypt-key" ]] \
            && fp="$(sha256sum "${SECRETS_ROOT}/${slug}/magento-crypt-key" | cut -c1-12)"
        if [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=${slug}" 2>/dev/null)" ]]; then
            state="up"
            # Working means the consumers are running, which is the thing that
            # is bounded. Checked against what docker reports rather than
            # against a flag in a file, so it cannot claim a site is parked
            # while six consumers are running.
            if [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=${slug}" \
                                      --filter "name=${slug}-consumer" 2>/dev/null)" ]]; then
                work="yes"
            else
                work="parked"
            fi
        else
            state="down"; work="—"
        fi
        printf '  %-20s %-10s %-9s %-7s %-13s %s\n' \
            "$host" "${mode:-?}" "$state" "$work" "$fp" "${seed:-?}"
    done < <(site_list)
    (( found )) || printf '  (none)\n'

    printf '\n  Data tiers:\n'
    local net
    while IFS= read -r net; do
        [[ -n "$net" ]] || continue
        printf '    %-24s %s attached\n' "$net" \
            "$(docker network inspect "$net" -f '{{len .Containers}}' 2>/dev/null || echo 0) containers"
    done < <(docker network ls --format '{{.Name}}' | grep -E '^magento-data' || true)

    printf '\n  Two sites sharing a CRYPT KEY is expected when both were seeded from one\n'
    printf '  snapshot — it is what lets them decrypt it. Two sharing it by accident is\n'
    printf '  not, which is why the column exists.\n\n'
}

# =============================================================================
# up / down / use / park
# =============================================================================
cmd_up() {
    require_site "${1:-}"
    log "Starting the data tier '${DATA_PROJECT}'"
    dc_data up -d --wait
    log "Starting ${SITE}"
    dc up -d
    log "Up. If the storefront 500s, the config changed and needs: make compose-install SITE=${SITE}"
}

cmd_down() {
    require_site "${1:-}"
    dc down --remove-orphans
    log "${SITE} stopped. Its data is untouched; the tier stays up for the other sites."
}

cmd_use() {
    require_site "${1:-}"
    local other
    while IFS= read -r other; do
        [[ -n "$other" && "$other" != "$SITE" ]] || continue
        local slug="${other//./-}"
        [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=${slug}" 2>/dev/null)" ]] || continue
        log "Parking ${other}"
        SITE="$other" "${BASH_SOURCE[0]}" park "$other"
    done < <(site_list)

    log "Waking ${SITE} — consumers and cron"
    # shellcheck disable=SC2046 # deliberate word splitting: one service per argument
    dc up -d $(working_services)
    log "${SITE} now holds the background work. One site at a time, by design."
}

cmd_park() {
    require_site "${1:-}"
    local svcs
    svcs="$(working_services)"
    [[ -n "$svcs" ]] || { log "${SITE} has no background workloads to park"; return 0; }
    # shellcheck disable=SC2046 # deliberate word splitting: one service per argument
    dc stop $(printf '%s' "$svcs") >/dev/null
    log "${SITE} parked — it still serves, and gives back about 870 MiB"
}

# =============================================================================
# destroy
# =============================================================================
cmd_destroy() {
    local host="${1:-}"; shift || true
    require_site "$host"
    local yes=0 dry=0
    while getopts ":ynh" opt; do
        case "$opt" in
            y) yes=1 ;;
            n) dry=1 ;;
            h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
            *) die "unknown flag -${OPTARG}; try -h" ;;
        esac
    done

    local db_name vhost cache_db page_db session_db prefix
    db_name="$(env_value DB_NAME)"
    vhost="$(env_value RABBITMQ_VIRTUALHOST)"
    cache_db="$(env_value REDIS_CACHE_DB)"
    page_db="$(env_value REDIS_PAGE_CACHE_DB)"
    session_db="$(env_value REDIS_SESSION_DB)"
    prefix="$(env_value OPENSEARCH_INDEX_PREFIX)"

    cat <<PLAN

  Destroying ${SITE} removes, permanently:

    containers and volumes   project ${COMPOSE_PROJECT}, including pub/media
    database                 ${db_name} on ${DATA_PROJECT}
    search indices           ${prefix}_* on ${DATA_PROJECT}
    valkey databases         cache ${cache_db}, page ${page_db}, session ${session_db}
    queue vhost              ${vhost}
    credentials              ${SECRETS_DIR}
    config                   ${SITE_ENV_FILE}

PLAN
    if [[ "$SITE_MODE" == "exclusive" ]]; then
        printf '  Its data tier %s goes too — that tier is this site.\n\n' "$DATA_PROJECT"
    else
        printf '  The shared data tier stays up. Other sites are untouched.\n\n'
    fi

    if [[ $dry -eq 1 ]]; then log "Dry run — nothing was removed"; return 0; fi
    if [[ $yes -eq 0 ]]; then
        read -r -p "  Type the hostname to confirm: " reply
        [[ "$reply" == "$SITE" ]] || die "not confirmed — nothing was removed"
    fi

    log "Removing the application project"
    dc down --volumes --remove-orphans || true

    if [[ "$SITE_MODE" == "exclusive" ]]; then
        log "Removing its data tier"
        dc_data down --volumes --remove-orphans || true
    elif data_running; then
        log "Dropping the database, the indices, the keyspaces and the vhost"
        data_db -e "DROP DATABASE IF EXISTS \`${db_name}\`; DROP USER IF EXISTS '$(env_value DB_USER)'@'%';" || true
        dc_data exec -T opensearch curl -fsS -XDELETE "localhost:9200/${prefix}_*" >/dev/null 2>&1 || true
        dc_data exec -T valkey-cache valkey-cli -n "$cache_db" flushdb >/dev/null 2>&1 || true
        dc_data exec -T valkey-cache valkey-cli -n "$page_db" flushdb >/dev/null 2>&1 || true
        dc_data exec -T valkey-session valkey-cli -n "$session_db" flushdb >/dev/null 2>&1 || true
        [[ "$vhost" == "/" ]] || dc_data exec -T rabbitmq rabbitmqctl delete_vhost "$vhost" >/dev/null 2>&1 || true
    else
        warn "the data tier is not running, so ${db_name}, the ${prefix}_* indices and"
        warn "the ${vhost} vhost were LEFT IN PLACE. Start it and destroy again to reclaim them:"
        warn "    make data-up && make destroy-site SITE=${SITE}"
    fi

    rm -rf "$SECRETS_DIR"
    rm -f "$SITE_ENV_FILE"
    log "${SITE} destroyed. Its certificate is left alone — mkcert pairs are cheap and harmless."
}

# =============================================================================
# the data tier itself
# =============================================================================
cmd_data_up() {
    log "Starting ${DATA_PROJECT}"
    dc_data up -d --wait
}

cmd_data_down() {
    # Refuse while a site is attached. `docker compose down` here would take
    # the database out from under every store on the network, and in shared
    # mode that is several of them.
    local attached
    attached="$(docker ps --filter "network=${DATA_NETWORK}" --format '{{.Label "com.docker.compose.project"}}' \
                | sort -u | grep -v "^${DATA_PROJECT}$" || true)"
    if [[ -n "$attached" ]]; then
        die "sites are still attached to ${DATA_NETWORK}:

$(printf '    %s\n' $attached)

  Stop them first, or this takes their database away while they are serving."
    fi
    dc_data down --remove-orphans
    log "${DATA_PROJECT} stopped. Its volumes are kept — nothing was destroyed."
}

# Resolve the site named on the command line, refusing a name that has no
# config file. lib.sh resolved SITE at source time from the environment; this
# is the switch, and resolve_site is what makes it complete.
require_site() {
    local host="${1:-}"
    [[ -n "$host" ]] || die "which site? Try: make sites"
    site_exists "$host" || die "no site '${host}'. Existing sites: $(site_list | tr '\n' ' ')"
    resolve_site "$host"
}

# =============================================================================
case "${1:-}" in
    new)       shift; cmd_new "$@" ;;
    list)      shift; cmd_list "$@" ;;
    up)        shift; cmd_up "$@" ;;
    down)      shift; cmd_down "$@" ;;
    use)       shift; cmd_use "$@" ;;
    park)      shift; cmd_park "$@" ;;
    destroy)   shift; cmd_destroy "$@" ;;
    data-up)   shift; cmd_data_up "$@" ;;
    data-down) shift; cmd_data_down "$@" ;;
    -h|--help|help) print_header "${BASH_SOURCE[0]}" ;;
    "")        die "no command. Try: new | list | up | down | use | park | destroy | data-up | data-down" ;;
    *)         die "unknown command '${1}'. Try -h" ;;
esac
