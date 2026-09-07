#!/usr/bin/env bash
#
# store-snapshot.sh — capture the store as a restorable baseline, and put it
# back into a fresh one.
#
# WHAT IT IS FOR. Installing Adobe Commerce from empty takes about twenty
# minutes and installing sample data on top takes longer again. A snapshot taken
# once is a seed every later store can start from in about a minute, so a throw-
# away environment stops costing an afternoon.
#
# A snapshot is TWO things, because a store is: the database, and pub/media.
# Sample data ships its images inside the vendor packages and setup:upgrade
# copies them into pub/media on first install -- so a database restored into a
# fresh store finds every product already installed, never re-copies the images,
# and renders a catalogue of broken thumbnails. Capturing the database alone
# looks complete and is not.
#
# Usage:  scripts/store-snapshot.sh <command> [options]
#
#   dump [-n NAME] [-f] [-d]     capture the current store
#   restore [-f FILE] [-y] [-d]  load a snapshot into the running store
#   list                         show what has been captured
#
#   -n   name for the snapshot     (default: a timestamped one)
#   -f   dump:    overwrite an existing snapshot of the same name
#        restore: the snapshot file (default: the newest)
#   -y   restore: skip the confirmation prompt
#   -d   database only — skip pub/media
#   -h   this header
#
# Environment overrides:
#   SNAPSHOT_DIR   where snapshots live
#                  (default: ../snapshots, beside this repository)
#
# IT IS A LOGICAL DUMP, NOT A PHYSICAL COPY, and that is the whole point. A
# physical copy is tied to the MariaDB version, page size and configuration that
# produced it; a logical one restores into any MariaDB that can parse SQL, which
# is what "seed another store" needs.
#
# IT WORKS AGAINST WHICHEVER RUNTIME IS UP -- the Compose stack or the kind
# cluster -- because a snapshot taken from one has to be restorable into the
# other, or it is not a baseline, it is a backup of one environment.
#
# > THE SNAPSHOT DIRECTORY IS NOT BACKED UP. It sits under ~/Development, which
# > is the one tree deliberately excluded from the Deja Dup include list, and it
# > is not in git either -- a multi-hundred-megabyte dump does not belong in a
# > repository. A snapshot is a convenience that saves an afternoon, not a
# > safeguard against losing anything.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${K8S_REPO_ROOT%/*}/snapshots}"

# Tables whose STRUCTURE is kept and whose DATA is not. Every one is either a
# log, a session store or a queue -- state that belongs to the environment that
# produced it and would be actively wrong in a store seeded from this.
#
# Index tables are deliberately NOT here. Dropping their data would halve the
# snapshot and leave every restored store needing a full reindex before it can
# render a category page, which is exactly the twenty minutes this exists to
# avoid.
NO_DATA_TABLES=(
    session
    admin_user_session
    customer_visitor
    report_event
    report_viewed_product_index
    report_compared_product_index
    adminnotification_inbox
    magento_logging_event
    magento_logging_event_changes
    queue_message
    queue_message_status
    queue_lock
    queue_poison_pill
)

# --- which runtime is up ----------------------------------------------------
# Refuses when both are, rather than picking one. They are two runtimes for one
# store and are not supposed to be up together; choosing silently would put a
# snapshot from one environment under a name that says nothing about which.
RUNTIME=""
detect_runtime() {
    local compose=0 cluster=0
    compose_running && compose=1
    cluster_exists && cluster=1
    if (( compose && cluster )); then
        die "both runtimes are up, which should not happen. Stop one: make compose-down, or make down."
    elif (( compose )); then
        RUNTIME=compose
    elif (( cluster )); then
        RUNTIME=cluster
    else
        die "no runtime is up for ${SITE}. Start one: make compose-up SITE=${SITE}, or make up."
    fi
}

# Run a command inside the database container, stdin attached either way.
#
# dc_data rather than dc under Compose: the database belongs to the data tier's
# project, which several sites may share. Which database is dumped is decided
# by DB_NAME from this site's config, not by which container is reached.
db() {
    case "$RUNTIME" in
        compose) dc_data exec -T db "$@" ;;
        cluster) kc -n "$NAMESPACE" exec -i statefulset/mariadb -- "$@" ;;
    esac
}

# Run a shell command in the application container. Used for pub/media, which
# is a volume the app containers mount and the database container does not.
app_sh() {
    case "$RUNTIME" in
        compose) dc exec -T php-cron sh -c "$1" ;;
        cluster) kc -n "$NAMESPACE" exec -i deploy/php-cron -c php-fpm -- sh -c "$1" ;;
    esac
}

# Run a Magento command, for the metadata only.
app() {
    case "$RUNTIME" in
        compose) dc exec -T php-cron php bin/magento "$@" ;;
        cluster) kc -n "$NAMESPACE" exec -i deploy/php-cron -c php-fpm -- php bin/magento "$@" ;;
    esac
}

secret() {
    local f="${SECRETS_DIR}/$1"
    [[ -s "$f" ]] || die "missing ${f}. Run: make secrets SITE=${SITE}"
    cat "$f"
}

# The data tier's own credentials, which in shared mode belong to no site.
data_secret() {
    local f="${DATA_SECRETS_DIR}/$1"
    [[ -s "$f" ]] || die "missing ${f}. Run: make secrets SITE=${SITE}"
    cat "$f"
}

# A FINGERPRINT, NEVER THE KEY. Magento encrypts some core_config_data values
# with MAGENTO_CRYPT_KEY, so a snapshot restored under a different key has rows
# that cannot be decrypted -- and the failure is per-value and quiet rather than
# a refusal to start. Recording a hash lets restore say so; recording the key
# would put a credential in a file next to the data it protects.
crypt_fingerprint() {
    secret magento-crypt-key | sha256sum | cut -c1-12
}

# =============================================================================
# dump
# =============================================================================
cmd_dump() {
    local name="" force=0 db_only=0
    while getopts ":n:fdh" opt; do
        case "$opt" in
            n) name="$OPTARG" ;;
            f) force=1 ;;
            d) db_only=1 ;;
            h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
            *) die "unknown flag -${OPTARG}; try -h" ;;
        esac
    done

    detect_runtime
    need docker
    command -v zstd >/dev/null 2>&1 || die "zstd is not installed. apt-get install zstd"

    local db_name db_root
    db_name="$(env_value DB_NAME)"
    db_root="$(data_secret db-root-password)"

    [[ -n "$name" ]] || name="${db_name}-$(date -u +%Y%m%dT%H%M%SZ)"
    local out="${SNAPSHOT_DIR}/${name}.sql.zst"
    local media="${SNAPSHOT_DIR}/${name}.media.tar.zst"
    local meta="${SNAPSHOT_DIR}/${name}.json"

    mkdir -p "$SNAPSHOT_DIR"
    if [[ -e "$out" && $force -eq 0 ]]; then
        die "${out} already exists. Use -f to overwrite, or -n to name it something else."
    fi

    log "Runtime: ${RUNTIME}   database: ${db_name}"

    # --ignore-table on the disposable tables, then a second pass for their
    # structure alone. Doing it this way round means the big dump never reads a
    # log table at all, rather than reading it and discarding the rows.
    local ignore=()
    local t
    for t in "${NO_DATA_TABLES[@]}"; do
        ignore+=("--ignore-table=${db_name}.${t}")
    done

    log "Dumping (this reads the whole database; --single-transaction, no locks)"
    {
        db mariadb-dump \
            --user=root --password="$db_root" \
            --single-transaction --quick --routines --triggers --events \
            --default-character-set=utf8mb4 \
            "${ignore[@]}" \
            "$db_name"

        # Structure only for the disposable ones. `|| true` because a table in
        # the list may simply not exist on a given Magento edition, and a
        # missing log table must not fail a snapshot.
        db mariadb-dump \
            --user=root --password="$db_root" \
            --no-data --default-character-set=utf8mb4 \
            "$db_name" "${NO_DATA_TABLES[@]}" 2>/dev/null || true
    } | zstd -T0 -3 -q -o "$out" -f

    # pub/media, from the application container rather than the database one.
    # Streamed straight into zstd on the host: the media directory can be
    # hundreds of megabytes and there is no reason for it to exist twice.
    local media_size="none"
    if (( db_only )); then
        log "Skipping pub/media (-d)"
    else
        log "Archiving pub/media"
        app_sh "tar -C /app/pub/media -cf - . 2>/dev/null" | zstd -T0 -3 -q -o "$media" -f
        media_size="$(du -h "$media" | cut -f1)"
        chmod 600 "$media"
        log "Wrote ${media} (${media_size})"
    fi

    # Metadata beside the dump, so a snapshot can say what it is a snapshot OF.
    # A bare .sql.zst six months from now is an unanswerable question.
    local version products
    version="$(app --version 2>/dev/null | tr -d '\r' | head -1 || echo unknown)"
    products="$(db mariadb --user=root --password="$db_root" -N -B \
        -e "SELECT COUNT(*) FROM ${db_name}.catalog_product_entity" 2>/dev/null | tr -d '\r' || echo 0)"

    cat > "$meta" <<META
{
  "name": "${name}",
  "taken_from": "${RUNTIME}",
  "database": "${db_name}",
  "magento_version": "${version}",
  "product_count": ${products:-0},
  "crypt_key_fingerprint": "$(crypt_fingerprint)",
  "base_url_at_capture": "$(env_value MAGENTO_BASE_URL)",
  "media_archive": "${media_size}",
  "tables_without_data": "$(printf '%s ' "${NO_DATA_TABLES[@]}" | sed 's/ $//')"
}
META
    chmod 600 "$out" "$meta"

    log "Wrote ${out} ($(du -h "$out" | cut -f1)), ${products:-0} products, media ${media_size}"
    log "Metadata: ${meta}"
}

# =============================================================================
# restore
# =============================================================================
cmd_restore() {
    local file="" yes=0 db_only=0
    while getopts ":f:ydh" opt; do
        case "$opt" in
            f) file="$OPTARG" ;;
            y) yes=1 ;;
            d) db_only=1 ;;
            h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
            *) die "unknown flag -${OPTARG}; try -h" ;;
        esac
    done

    detect_runtime
    command -v zstd >/dev/null 2>&1 || die "zstd is not installed"

    if [[ -z "$file" ]]; then
        file="$(find "$SNAPSHOT_DIR" -maxdepth 1 -name '*.sql.zst' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
        [[ -n "$file" ]] || die "no snapshots in ${SNAPSHOT_DIR}. Take one: make db-dump"
    fi
    [[ -f "$file" ]] || die "no such snapshot: ${file}"

    local meta="${file%.sql.zst}.json"
    local db_name db_root
    db_name="$(env_value DB_NAME)"
    db_root="$(data_secret db-root-password)"

    # The crypt key check, and it is the reason restore is not just `zstd -dc |
    # mariadb`. Values encrypted under a different key come back as unreadable
    # rows rather than as an error, so this is said out loud BEFORE the data
    # lands rather than discovered later in the admin.
    if [[ -f "$meta" ]]; then
        local want have
        want="$(sed -n 's/.*"crypt_key_fingerprint": "\([^"]*\)".*/\1/p' "$meta")"
        have="$(crypt_fingerprint)"
        if [[ -n "$want" && "$want" != "$have" ]]; then
            warn "This snapshot was taken under a DIFFERENT crypt key (${want}, this store has ${have})."
            warn "Anything Magento encrypted -- payment credentials, API keys in core_config_data --"
            warn "will restore as bytes that cannot be decrypted. Catalogue and customer data are fine."
            warn "make new-site inherits the right key automatically; this path is for a store made another way."
        fi
        log "Snapshot: $(sed -n 's/.*"magento_version": "\([^"]*\)".*/\1/p' "$meta"), $(sed -n 's/.*"product_count": \([0-9]*\).*/\1/p' "$meta") products"
    else
        warn "no metadata beside ${file} — restoring blind, and the crypt key cannot be checked"
    fi

    if [[ $yes -eq 0 ]]; then
        warn "This REPLACES the contents of database '${db_name}' on the ${RUNTIME} runtime."
        read -r -p "  Type the database name to confirm: " reply
        [[ "$reply" == "$db_name" ]] || die "not confirmed — nothing was changed"
    fi

    # Dropped and recreated rather than loaded over. A dump loaded on top of an
    # existing schema leaves behind every table the snapshot does not mention,
    # which is how a "restored" store ends up with rows from two installs.
    log "Recreating database '${db_name}'"
    db mariadb --user=root --password="$db_root" \
        -e "DROP DATABASE IF EXISTS \`${db_name}\`; CREATE DATABASE \`${db_name}\` DEFAULT CHARACTER SET utf8mb4;"

    log "Loading $(basename "$file")"
    zstd -dc "$file" | db mariadb --user=root --password="$db_root" "$db_name"

    # Media, if the snapshot carries it. Extracted over whatever is there rather
    # than replacing the directory: pub/media is a shared volume that other
    # containers have mounted, and removing it out from under them is a worse
    # failure than a few stale files.
    local media="${file%.sql.zst}.media.tar.zst"
    if (( db_only )); then
        log "Skipping pub/media (-d) — product images will be missing"
    elif [[ -f "$media" ]]; then
        log "Restoring pub/media from $(basename "$media")"
        zstd -dc "$media" | app_sh "tar -C /app/pub/media -xf - "
    else
        warn "no media archive beside ${file}."
        warn "The catalogue will restore with every product image missing — the database"
        warn "records that sample data is installed, so setup:upgrade will not re-copy them."
    fi

    cat <<EOF

  Restored. The store's own env.php still supplies the base URL, the crypt key
  and every service address, so the data is now this store's rather than the one
  it came from.

  Finish with:   make compose-install    (or make deploy for the cluster)

  That runs setup:upgrade against the restored schema and reindexes it.

EOF
}

# =============================================================================
# list
# =============================================================================
cmd_list() {
    [[ -d "$SNAPSHOT_DIR" ]] || { log "No snapshots yet (${SNAPSHOT_DIR} does not exist)"; return 0; }
    local found=0 f
    printf '\n  %-34s %8s  %9s  %s\n' "SNAPSHOT" "SIZE" "PRODUCTS" "MAGENTO"
    while IFS= read -r f; do
        found=1
        local meta="${f%.sql.zst}.json" products="?" version="?"
        if [[ -f "$meta" ]]; then
            products="$(sed -n 's/.*"product_count": \([0-9]*\).*/\1/p' "$meta")"
            version="$(sed -n 's/.*"magento_version": "\([^"]*\)".*/\1/p' "$meta" | cut -c1-40)"
        fi
        printf '  %-34s %8s  %9s  %s\n' \
            "$(basename "$f" .sql.zst)" "$(du -h "$f" | cut -f1)" "${products:-?}" "${version:-?}"
    done < <(find "$SNAPSHOT_DIR" -maxdepth 1 -name '*.sql.zst' | sort)
    (( found )) || printf '  (none)\n'
    printf '\n  %s\n' "$SNAPSHOT_DIR"
    printf '  %s\n\n' "Not in git and not in the backup set — see this script's header."
}

# =============================================================================
case "${1:-}" in
    dump)    shift; cmd_dump "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    list)    shift; cmd_list "$@" ;;
    -h|--help|help) print_header "${BASH_SOURCE[0]}" ;;
    "")      die "no command. Try: dump | restore | list  (-h for the header)" ;;
    *)       die "unknown command '${1}'. Try: dump | restore | list" ;;
esac
