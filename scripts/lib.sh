#!/usr/bin/env bash
#
# Shared helpers for this repository's scripts. Sourced, never executed.
#
# Everything here exists so the individual scripts can stay short enough to
# read in one screen, and so the paths are resolved in exactly one place.

# Reporting first, because everything below can fail and a die() defined after
# its first caller is a command-not-found at exactly the wrong moment.
_c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_off=$'\033[0m'

log()  { printf '%s==>%s %s\n' "$_c_grn" "$_c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$_c_ylw" "$_c_off" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# shellcheck disable=SC2034
K8S_REPO_ROOT="${K8S_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

CLUSTER_NAME="${CLUSTER_NAME:-vanilla}"
NAMESPACE="${NAMESPACE:-vanilla}"
IMAGE_NAME="${IMAGE_NAME:-magento-app}"
IMAGE_TAG="${IMAGE_TAG:-local}"
OVERLAY="${OVERLAY:-dev}"

# The Magento application tree. This is the store the repository exists to run,
# and it is the only path here naming anything outside this repository.
MAGENTO_SRC="${MAGENTO_SRC:-${K8S_REPO_ROOT%/*}/commerce-vanilla}"

# Where mkcert writes the certificate and key for SITE_HOST. Each host needs
# its own pair named <host>.crt and <host>.key: a wildcard may not span a
# whole top-level domain, so *.test is refused by every browser and there is
# no fallback. Point CERTS_HOME wherever you keep them.
CERTS_HOME="${CERTS_HOME:-${K8S_REPO_ROOT}/certs}"

# --- which site -------------------------------------------------------------
# SITE is a hostname and it is the only handle a person types. Everything else
# is derived from it, so a new store is one variable rather than eight.
#
# THE DERIVATION IS A FUNCTION, AND THAT IS NOT TIDINESS. A script that walks
# several sites has to re-derive between them, and doing it inline means every
# caller repeats the same eight assignments and any one of them can be
# forgotten. Worse, the `${VAR:-default}` form that makes these overridable
# also makes a stale value STICKY: a variable already set for the previous site
# is kept rather than recomputed, so the switch appears to happen and the paths
# still point at the site before it.
#
# That is not hypothetical either. It is how the first version of
# verify-namespaces.sh reported every value in a correctly-configured store as
# a mismatch -- it had re-sourced this file with a new SITE while SITE_ENV_FILE
# still held the old one -- and how lint.sh silently validated one site twice.
#
#   resolve_site                   honour the environment's overrides (source time)
#   resolve_site <host>            switch to a named site, overrides ignored
#   resolve_site <host> <mode>     the same, for a site whose file does not
#                                  exist yet -- creation only
#
# The slug is the hostname with dots replaced: it names the Compose project,
# the secrets directory and the per-site env file, and Compose project names
# may not contain a dot.

CONFIG_ENV_DIR="${CONFIG_ENV_DIR:-${K8S_REPO_ROOT}/k8s/base/config/env}"
COMMON_ENV_FILE="${COMMON_ENV_FILE:-${CONFIG_ENV_DIR}/common.env}"
SECRETS_ROOT="${SECRETS_ROOT:-${K8S_REPO_ROOT}/secrets}"
COMPOSE_FILE="${COMPOSE_FILE:-${K8S_REPO_ROOT}/docker-compose.yaml}"
# Applied on top of the base file for a site whose SITE_SOURCE is `mounted`.
DEV_COMPOSE_FILE="${DEV_COMPOSE_FILE:-${K8S_REPO_ROOT}/docker-compose.dev.yaml}"
DATA_COMPOSE_FILE="${DATA_COMPOSE_FILE:-${K8S_REPO_ROOT}/docker-compose.data.yaml}"

# Kept as an override for anything that wants to point the whole lookup at one
# file. Empty by default: the layered pair below is the normal case.
ENV_FILE="${ENV_FILE:-}"

site_exists() { [[ -f "${CONFIG_ENV_DIR}/sites/${1//./-}.env" ]]; }

# Every site that has a config file, as hostnames.
site_list() {
    local f
    for f in "${CONFIG_ENV_DIR}"/sites/*.env; do
        [[ -e "$f" ]] || continue
        sed -n 's/^SITE_HOST=//p' "$f" | head -n1
    done
}

# Called with no arguments at source time, and with a host (and, when creating
# a site, a mode) everywhere else. Older shellchecks read the no-argument call
# as proof the parameters are unused; newer ones do not, so the gate passes
# here and failed on a runner. The no-argument form is deliberate.
# shellcheck disable=SC2120
resolve_site() {
    local named="${1:-}" want_mode="${2:-}"
    if [[ -n "$named" ]]; then
        # An explicit switch. Every derived value is recomputed, and an
        # override left in the environment by the previous site is discarded
        # rather than inherited -- that inheritance is the whole bug.
        SITE="$named"
        unset SITE_ENV_FILE SITE_MODE COMPOSE_PROJECT DATA_PROJECT \
              DATA_NETWORK SECRETS_DIR DATA_SECRETS_DIR
    else
        SITE="${SITE:-vanilla.test}"
    fi

    SITE_SLUG="${SITE//./-}"
    SITE_HOST="$SITE"
    SITE_ENV_FILE="${SITE_ENV_FILE:-${CONFIG_ENV_DIR}/sites/${SITE_SLUG}.env}"
    COMPOSE_PROJECT="${COMPOSE_PROJECT:-$SITE_SLUG}"

    # SITE_MODE is read from the site file rather than passed around: a site's
    # mode is a property of the site, and a command that took it as a flag
    # could point an exclusive site at the shared tier by omitting one
    # argument. A site that does not exist yet defaults to shared, which is
    # what `site.sh new` overrides before it writes the file.
    #
    # A SITE BEING CREATED HAS NO FILE TO READ IT FROM, so the one caller that
    # is creating one passes the mode as the second argument. It cannot set
    # SITE_MODE beforehand instead: the unset above discards it, which is
    # exactly what an explicit switch is for -- so `new -m exclusive` silently
    # built a SHARED site, wrote `SITE_MODE=exclusive` into its file, and left
    # `destroy` tearing down a data project that had never existed while the
    # store's real database stayed in the shared tier.
    if [[ -n "$want_mode" ]]; then
        SITE_MODE="$want_mode"
    elif [[ -f "$SITE_ENV_FILE" ]]; then
        SITE_MODE="${SITE_MODE:-$(env_value_or SITE_MODE shared)}"
        SITE_SOURCE="${SITE_SOURCE:-$(env_value_or SITE_SOURCE image)}"
    else
        SITE_MODE="${SITE_MODE:-shared}"
    fi
    if [[ -f "$SITE_ENV_FILE" ]]; then
        SITE_SOURCE="${SITE_SOURCE:-$(env_value_or SITE_SOURCE image)}"
    else
        SITE_SOURCE="${SITE_SOURCE:-image}"
    fi

    # SITE_SOURCE — where the application code comes from. `image`, which is
    # what ships, or `mounted`, which is the working tree at /app.
    #
    # A PROPERTY OF THE SITE, for the same reason SITE_MODE is one, and here
    # the cost of getting it wrong is worse than a misdirected data tier. Every
    # `docker compose` invocation has to agree about which files compose the
    # project: one that omits the overlay sees a different desired state and
    # RECREATES the containers without the mounts. So a `make compose-cli` run
    # with the flag forgotten would silently put a mounted site back on the
    # image, mid-session, with nothing to say it had happened.
    case "$SITE_SOURCE" in
        image|mounted) ;;
        *) die "SITE_SOURCE must be 'image' or 'mounted', not '${SITE_SOURCE}'" ;;
    esac

    # --- projects, and the two-tier split -----------------------------------
    # ONE SITE IS TWO COMPOSE PROJECTS: an application project named after the
    # site, and a data project it attaches to over a named network.
    #
    # The split is what makes a second store affordable. Measured idle on this
    # machine, the data tier is 1.75 GiB of a 3.22 GiB stack -- MariaDB and the
    # OpenSearch JVM alone are half of it -- and none of it is per-site work. A
    # second site sharing it costs 1.46 GiB rather than 3.22, and 0.60 GiB once
    # parked. Two full stacks is 6.44 GiB idle against ~10 GiB available, which
    # is the shape that took this host to a load average of 300.
    #
    # THE TWO MODES DIFFER ONLY IN WHICH DATA PROJECT THE SITE POINTS AT, which
    # is why there is one code path and not two. An exclusive site is the same
    # data stack started again under a different name; its containers answer to
    # the same service names on a network only it joins, so `db` still resolves
    # to `db` and nothing downstream forks.
    case "$SITE_MODE" in
        shared)    DATA_PROJECT="${DATA_PROJECT:-magento-data}" ;;
        exclusive) DATA_PROJECT="${DATA_PROJECT:-magento-data-${SITE_SLUG}}" ;;
        *)         die "SITE_MODE must be 'shared' or 'exclusive', not '${SITE_MODE}'" ;;
    esac

    # The data project publishes its network under a fixed name so an
    # application project can join it as external. Without `name:` there,
    # this would have to reconstruct the prefix Compose chose.
    DATA_NETWORK="${DATA_NETWORK:-$DATA_PROJECT}"

    SECRETS_DIR="${SECRETS_DIR:-${SECRETS_ROOT}/${SITE_SLUG}}"
    DATA_SECRETS_DIR="${DATA_SECRETS_DIR:-${SECRETS_ROOT}/${DATA_PROJECT}}"
}

# Read one value for this site.
#
# THE SITE FILE WINS OVER THE COMMON ONE, which is the same precedence Compose
# and kustomize both apply to the pair, so a value read here is the value the
# container will see. Reading them in the other order would make this function
# quietly disagree with the runtime.
#
# Deliberately NOT `source`. These are kustomize env files, not shell: values
# are unquoted by requirement, and MAGENTO_INSTALL_DATE alone holds spaces and
# commas, so sourcing it tries to run `01` as a command. Reading a key and
# taking everything after the first `=` keeps one format that both kustomize
# and docker compose already parse natively.
env_value() {
    local key="$1"
    local val="" f
    for f in "$ENV_FILE" "$SITE_ENV_FILE" "$COMMON_ENV_FILE"; do
        [[ -n "$f" && -f "$f" ]] || continue
        local v
        v="$(sed -n "s/^${key}=//p" "$f" | head -n1)"
        [[ -n "$v" ]] && { val="$v"; break; }
    done
    [[ -n "$val" ]] || die "${key} is not set in ${SITE_ENV_FILE} or ${COMMON_ENV_FILE}"
    printf '%s' "$val"
}

# Same lookup, but an absent key is not fatal.
env_value_or() {
    local key="$1" fallback="$2" val="" f
    for f in "$ENV_FILE" "$SITE_ENV_FILE" "$COMMON_ENV_FILE"; do
        [[ -n "$f" && -f "$f" ]] || continue
        local v
        v="$(sed -n "s/^${key}=//p" "$f" | head -n1)"
        [[ -n "$v" ]] && { val="$v"; break; }
    done
    printf '%s' "${val:-$fallback}"
}

# Resolve the default site now that env_value_or exists. Callers that walk
# several sites call resolve_site <host> again for each one.
resolve_site

# Reprint this script's own comment header for -h. Extracts the block rather
# than hardcoding line numbers, so editing the header never desynchronises it.
print_header() {
    sed -n '2,/^$/p' "$1" | sed 's/^# \{0,1\}//'
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH. Run: make tools"
}

kc() { kubectl --context "kind-${CLUSTER_NAME}" "$@"; }

cluster_exists() {
    kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

# The Compose half of the one-stack-at-a-time guard. Matches on the project
# label docker compose stamps on every container it creates, not on a name
# prefix: a container renamed with --name still carries the label, and a name
# prefix would also match an unrelated container that happens to start with the
# same word.
compose_running() {
    [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null)" ]]
}

# Everything the two compose files interpolate. Exported in one place because
# a missing one does not fail: Compose substitutes an empty string and warns on
# stderr, so an unexported SITE_HOST becomes `VIRTUAL_HOST=` and nginx-proxy
# simply never routes to the container.
compose_env() {
    export SITE_HOST SITE_SLUG DATA_NETWORK DATA_PROJECT
    export COMMON_ENV_FILE SITE_ENV_FILE
    export SECRETS_DIR DATA_SECRETS_DIR
    export MAGENTO_SRC SITE_SOURCE
    # The dev overlay writes into the mounted tree, so its containers run as
    # whoever owns it. Exported unconditionally because compose interpolates
    # the overlay only when it is applied.
    DEV_UID="${DEV_UID:-$(id -u)}"
    DEV_GID="${DEV_GID:-$(id -g)}"
    export DEV_UID DEV_GID
    # An empty SITE_IMAGE_TAG means the shared image, which is the whole point
    # of question 2 being answered "share now, vary later": a site diverges by
    # setting this in its env file and nothing else changes.
    APP_IMAGE_TAG="$(env_value_or SITE_IMAGE_TAG "$IMAGE_TAG")"
    export APP_IMAGE_TAG
    local src
    src="$(env_value_or SITE_MAGENTO_SRC "")"
    [[ -n "$src" ]] && export MAGENTO_SRC="$src"
    return 0
}

# Run docker compose against this SITE's application project from anywhere. -p
# is explicit because the project name otherwise comes from the directory the
# command was invoked in, and the guard above matches on it.
# Every compose file this site's project is made of, in order. A mounted site
# adds the dev overlay; an image-backed one is the single base file it always
# was. Assembled in one place so that no caller can assemble it differently --
# see the SITE_SOURCE note above for what happens when two callers disagree.
compose_files() {
    local -n out="$1"
    out=(-f "$COMPOSE_FILE")
    [[ "${SITE_SOURCE:-image}" == "mounted" ]] && out+=(-f "$DEV_COMPOSE_FILE")
    return 0
}

# The env.php a mounted site writes to.
#
# It is bind-mounted over the tree's own path, so it has to exist on the host
# before a container starts -- Docker creates a missing bind source as a
# DIRECTORY, and a directory mounted where PHP expects a file is an error the
# entrypoint reports as "not a directory" with no mention of this file. Seeded
# empty and owned by whoever is running, which is the same thing the cluster
# overlay's init container does and for the same reason.
ensure_dev_env_php() {
    [[ "${SITE_SOURCE:-image}" == "mounted" ]] || return 0
    mkdir -p "$SECRETS_DIR"
    [[ -e "${SECRETS_DIR}/env.php" ]] || install -m 0660 /dev/null "${SECRETS_DIR}/env.php"
    ensure_dev_ca_bundle
    return 0
}

# A CA bundle that also trusts this machine's locally-issued certificates.
#
# Every other stack here is served at https://<name>.test behind nginx-proxy
# with an mkcert certificate. The host and its browsers trust that CA; a
# CONTAINER does not, so PHP calling one of those services gets "unable to get
# local issuer certificate" and the only workaround is to stop using TLS --
# which then breaks in the browser instead, as mixed content on an https page.
#
# The image's own bundle plus the mkcert root, written once per site. Appending
# rather than replacing matters: pointing CURL_CA_BUNDLE at the mkcert root
# alone would make the store trust exactly one CA and no public one.
#
# Mounted sites only. Nothing about the image path changes.
ensure_dev_ca_bundle() {
    local bundle="${SECRETS_DIR}/ca-bundle.pem"
    local caroot system
    caroot="${MKCERT_CAROOT:-$(command -v mkcert >/dev/null 2>&1 && mkcert -CAROOT 2>/dev/null || echo "${HOME}/.local/share/mkcert")}"
    [[ -f "${caroot}/rootCA.pem" ]] || { rm -f "$bundle"; return 0; }

    for system in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        [[ -f "$system" ]] && break
        system=""
    done
    [[ -n "$system" ]] || { rm -f "$bundle"; return 0; }

    # Rebuilt only when an input is newer, so this is not a file write on every
    # `docker compose ps`.
    if [[ ! -f "$bundle" || "$system" -nt "$bundle" || "${caroot}/rootCA.pem" -nt "$bundle" ]]; then
        cat "$system" "${caroot}/rootCA.pem" >"$bundle"
        chmod 0644 "$bundle"
    fi

    # AND AN INI FILE, because the environment variable is not enough.
    # libcurl reads CURL_CA_BUNDLE at init and the `curl` binary therefore
    # honours it -- but PHP's curl extension sets CURLOPT_CAINFO itself from
    # `curl.cainfo`, so it ignores the environment entirely. The symptom is a
    # container where `curl https://...` works and the identical request from
    # PHP fails with "unable to get local issuer certificate".
    local ini="${SECRETS_DIR}/dev-ca.ini"
    if [[ ! -f "$ini" ]]; then
        printf 'curl.cainfo=/etc/ssl/certs/dev-ca-bundle.pem
openssl.cafile=/etc/ssl/certs/dev-ca-bundle.pem
' >"$ini"
        chmod 0644 "$ini"
    fi
    return 0
}

dc() {
    compose_env
    ensure_dev_env_php
    local files
    compose_files files
    docker compose -p "$COMPOSE_PROJECT" "${files[@]}" "$@"
}

# The same, for the data tier this site attaches to. A separate project rather
# than a profile inside the site's own: the data tier outlives any one site in
# shared mode, and `docker compose down` on a site must never be able to take
# the database of another one with it.
dc_data() {
    compose_env
    docker compose -p "$DATA_PROJECT" -f "$DATA_COMPOSE_FILE" "$@"
}

data_running() {
    [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=${DATA_PROJECT}" 2>/dev/null)" ]]
}

# Run a command in the data tier's MariaDB as root. Used to create and drop a
# site's database, which in shared mode is the only thing that makes a site
# distinct there.
data_db() {
    local root
    root="$(cat "${DATA_SECRETS_DIR}/db-root-password")"
    dc_data exec -T db mariadb --user=root --password="$root" "$@"
}

# Create this site's database, user and queue vhost in the data tier it
# attaches to. Every site goes through here including the first, so the path
# that provisions store number two is the one that provisioned store number one.
provision_data() {
    local db_name db_user db_pass vhost rabbit_user
    db_name="$(env_value DB_NAME)"
    db_user="$(env_value DB_USER)"
    db_pass="$(cat "${SECRETS_DIR}/db-password")"
    vhost="$(env_value RABBITMQ_VIRTUALHOST)"
    rabbit_user="$(env_value RABBITMQ_USER)"

    log "Creating database '${db_name}' and its user"
    # IF NOT EXISTS throughout: this runs on every `new`, and a half-created
    # site being retried must not fail on the step that already succeeded.
    data_db -e "
        CREATE DATABASE IF NOT EXISTS \`${db_name}\` DEFAULT CHARACTER SET utf8mb4;
        CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
        ALTER USER '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
        GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%';
        FLUSH PRIVILEGES;"

    if [[ "$vhost" != "/" ]]; then
        log "Creating queue vhost '${vhost}'"
        dc_data exec -T rabbitmq rabbitmqctl add_vhost "$vhost" 2>/dev/null || true
        dc_data exec -T rabbitmq rabbitmqctl set_permissions -p "$vhost" "$rabbit_user" ".*" ".*" ".*"
    fi
}

# Every service that runs Magento and therefore holds a generated env.php.
#
# Derived from the Compose file rather than listed by hand: a service added
# there and forgotten here would keep running against a stale env.php after an
# install, and nothing would say so. The data tier is excluded because it has no
# env.php and restarting a database for no reason is not free.
app_services() {
    dc config --services 2>/dev/null | grep -vxE 'stage-static|stage-media|magento-install|mailhog'
}

# The services a PARKED site keeps running: it serves, and it does no
# background work. Everything left out is a consumer or the cron loop.
#
# THIS IS THE BOUND THAT MATTERS, and it is not about idle memory. Per site the
# declared ceilings are php-cron 4g + magento-cron 4g + six consumers at 1g --
# 14 GiB for one site. Two sites reindexing at once overcommits this host
# whatever the data tier is doing, so what is limited is how many sites do
# background work, not how many exist.
serving_services() {
    dc config --services 2>/dev/null | grep -vxE 'stage-static|stage-media|magento-install|magento-cron|consumer-.*'
}

working_services() {
    dc config --services 2>/dev/null | grep -xE 'magento-cron|consumer-.*'
}
