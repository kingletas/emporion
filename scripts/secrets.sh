#!/usr/bin/env bash
#
# secrets.sh — generate every credential once, and feed both runtimes from it.
#
# ONE generator for two runtimes, on purpose. The cluster gets Secrets; the
# Compose stack gets env_file fragments written beside them. Two generators
# would mean two sets of credentials for one store, and the first symptom would
# be a database that authenticates under one runtime and not the other.
#
# Nothing generated here is ever committed. These are local development
# credentials guarding nothing, which is exactly why this is a good place to
# practise the pattern rather than a place to be relaxed about it.
#
# TWO DIRECTORIES, SPLIT BY WHAT OWNS THE VALUE:
#
#   secrets/<data-project>/   the database root password and the RabbitMQ
#                             administrator. They belong to the data tier, and
#                             in shared mode several sites read the same pair.
#   secrets/<site-slug>/      this site's database password, crypt key and
#                             admin password. Never shared, with one deliberate
#                             exception below.
#
# Generated values are cached so a re-run produces the same password. That
# matters: the database volume is initialised with the password from the FIRST
# run, and regenerating on every deploy locks the application out of its own
# database with an authentication error that looks nothing like the cause.
#
# THE CRYPT KEY IS THE ONE VALUE A SITE MAY INHERIT, and -k is how. A store
# seeded from a snapshot cannot decrypt what that snapshot encrypted unless it
# holds the key that encrypted it -- and generating a fresh key instead would
# fire store-snapshot.sh's fingerprint warning on every single new site, which
# is how a real warning gets trained into noise. So a seeded site takes the
# key, an empty one generates its own, and `make sites` prints the fingerprint
# of each so two sites sharing a key is visible rather than inferred.
#
# Usage:  scripts/secrets.sh [-k FILE] [-f] [-n] [-h]
#
#   -k   seed this site's crypt key from FILE (another site's key), instead of
#        generating one. Refused if this site already has a key: silently
#        replacing it would make every encrypted row in an existing store
#        unreadable.
#   -f   force: regenerate every value, discarding the cache. Only correct
#        immediately after `make down` / `make compose-down -v`, when the
#        database volume is gone too.
#   -n   dry run
#   -h   this header
#
# Environment overrides:
#   SITE           the site to generate for  (default: vanilla.test)
#   NAMESPACE      target namespace          (default: vanilla)
#   SECRETS_ROOT   cache location            (default: <repo>/secrets)
#
# The cluster apply is SKIPPED when no cluster exists, so this is runnable for
# a Compose-only workflow. It says which of the two it did rather than being
# quietly partial.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

FORCE=0; DRY=0; CRYPT_FROM=""

while getopts ":k:fnh" opt; do
    case "$opt" in
        k) CRYPT_FROM="$OPTARG" ;;
        f) FORCE=1 ;;
        n) DRY=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

# A dry run must not create anything, including the cache directory. Checked
# before any of it rather than just before the apply.
if [[ $DRY -eq 1 ]]; then
    log "Dry run — would generate ${SITE}'s credentials into ${SECRETS_DIR} (dir 700, values 600) and reuse them on later runs"
    log "Dry run — would generate the ${DATA_PROJECT} tier's credentials into ${DATA_SECRETS_DIR}"
    log "Dry run — would write compose-app.env, and compose-db.env / compose-rabbit.env beside the tier's"
    log "Dry run — would apply Secret/vanilla-db, Secret/vanilla-app and Secret/vanilla-rabbit to namespace ${NAMESPACE} if a cluster existed"
    exit 0
fi

mkdir -p "$SECRETS_DIR" "$DATA_SECRETS_DIR"
chmod 700 "$SECRETS_DIR" "$DATA_SECRETS_DIR" "$SECRETS_ROOT"

# Read a cached value, or generate and cache one. Alphanumeric only: these
# strings end up in a MySQL DSN, a RabbitMQ URI and a PHP array literal, and a
# shell-or-URL-special character in any of them fails somewhere unhelpful.
value_for() {
    # One `local` per variable, deliberately. `local a="$1" b="/x/${a}"`
    # localises every name first and only then assigns left to right, so ${a}
    # in the second word expands while it is still unset — which is silent
    # without `set -u` and an "unbound variable" with it.
    local dir="$1"
    local name="$2"
    local bytes="${3:-24}"
    local file="${dir}/${name}"
    if [[ $FORCE -eq 0 && -s "$file" ]]; then
        cat "$file"
        return
    fi
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$bytes" > "$file"
    chmod 600 "$file"
    cat "$file"
}

# The data tier's own two, shared by every site attached to it.
DB_ROOT_PASSWORD="$(value_for "$DATA_SECRETS_DIR" db-root-password)"
RABBIT_PASSWORD="$(value_for "$DATA_SECRETS_DIR" rabbit-password)"

# This site's three.
DB_PASSWORD="$(value_for "$SECRETS_DIR" db-password)"
ADMIN_PASSWORD="$(value_for "$SECRETS_DIR" magento-admin-password)"

# The crypt key, and the one place -k applies. Copied BEFORE value_for runs, so
# the cache-or-generate below finds it already there and treats it as cached --
# which also means a second run with -k is a no-op rather than a re-copy.
if [[ -n "$CRYPT_FROM" ]]; then
    [[ -s "$CRYPT_FROM" ]] || die "no crypt key at ${CRYPT_FROM}"
    if [[ -s "${SECRETS_DIR}/magento-crypt-key" ]]; then
        if ! cmp -s "$CRYPT_FROM" "${SECRETS_DIR}/magento-crypt-key"; then
            die "${SITE} already has a DIFFERENT crypt key.

  Replacing it would make every value this store has encrypted unreadable --
  payment credentials and API keys in core_config_data -- with no error at the
  point of the change. Destroy the site and recreate it if that is what you
  want:  make destroy-site SITE=${SITE}"
        fi
    else
        install -m 600 "$CRYPT_FROM" "${SECRETS_DIR}/magento-crypt-key"
        log "Crypt key inherited from ${CRYPT_FROM}"
    fi
fi
CRYPT_KEY="$(value_for "$SECRETS_DIR" magento-crypt-key 32)"

# Non-secret names come from the site's layered config rather than being
# repeated here. A database called `vanilla` in one place and something else in
# the other is a class of bug this removes entirely.
DB_USER="$(env_value DB_USER)"
DB_NAME="$(env_value DB_NAME)"
RABBIT_USER="$(env_value RABBITMQ_USER)"

# --- the Compose runtime's half --------------------------------------------
# Written to match the three Secrets below one for one, rather than to a single
# combined file: it keeps the root database password out of the application
# containers, which is the same split the Secrets make and the same reason.
write_env() {
    local file="$1/$2"; shift 2
    printf '%s\n' "$@" > "$file"
    chmod 600 "$file"
}

log "Writing Compose env fragments"
# NO MARIADB_DATABASE AND NO MARIADB_USER. Those variables only ever provision
# the FIRST database in a volume, so a shared tier would create site one that
# way and every later site some other way -- two mechanisms for one job, the
# second of them only exercised after the first store already exists.
# scripts/site.sh creates every site's database and user through root,
# including the first, so there is one path and it is the tested one.
write_env "$DATA_SECRETS_DIR" compose-db.env \
    "MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
write_env "$DATA_SECRETS_DIR" compose-rabbit.env \
    "RABBITMQ_DEFAULT_USER=${RABBIT_USER}" \
    "RABBITMQ_DEFAULT_PASS=${RABBIT_PASSWORD}"
write_env "$SECRETS_DIR" compose-app.env \
    "DB_PASSWORD=${DB_PASSWORD}" \
    "RABBITMQ_PASSWORD=${RABBIT_PASSWORD}" \
    "MAGENTO_CRYPT_KEY=${CRYPT_KEY}" \
    "MAGENTO_ADMIN_PASSWORD=${ADMIN_PASSWORD}"

# --- the cluster's half -----------------------------------------------------
# Skipped rather than failed when there is no cluster: a Compose-only workflow
# still needs the credentials above, and `make up` creates the cluster before
# calling this anyway.
if ! command -v kubectl >/dev/null 2>&1 || ! cluster_exists; then
    log "No '${CLUSTER_NAME}' cluster — wrote the credential cache and the Compose fragments, applied no Secret"
    exit 0
fi

log "Applying Secret/vanilla-db"
kc -n "$NAMESPACE" create secret generic vanilla-db \
    --from-literal=MARIADB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
    --from-literal=MARIADB_PASSWORD="$DB_PASSWORD" \
    --from-literal=MARIADB_USER="$DB_USER" \
    --from-literal=MARIADB_DATABASE="$DB_NAME" \
    --dry-run=client -o yaml | kc apply -f -

log "Applying Secret/vanilla-app"
kc -n "$NAMESPACE" create secret generic vanilla-app \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
    --from-literal=RABBITMQ_PASSWORD="$RABBIT_PASSWORD" \
    --from-literal=MAGENTO_CRYPT_KEY="$CRYPT_KEY" \
    --from-literal=MAGENTO_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kc apply -f -

log "Applying Secret/vanilla-rabbit"
kc -n "$NAMESPACE" create secret generic vanilla-rabbit \
    --from-literal=RABBITMQ_DEFAULT_USER="$RABBIT_USER" \
    --from-literal=RABBITMQ_DEFAULT_PASS="$RABBIT_PASSWORD" \
    --dry-run=client -o yaml | kc apply -f -

cat <<EOF

  Secrets applied. The admin password for the Magento install job is cached at

    ${SECRETS_DIR}/magento-admin-password

  Nothing above is in git: secrets/ is ignored by this repository's .gitignore,
  and no manifest, Compose file or config file carries a credential literal.
  \`make scan\` is what checks that rather than anybody remembering.

EOF
