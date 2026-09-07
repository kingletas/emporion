#!/usr/bin/env bash
#
# sample-data.sh — add Adobe Commerce sample data to the Magento tree.
#
# BUILD-TIME, NOT RUNTIME, and that is the whole shape of this script. Sample
# data arrives as Composer packages, so it lands in vendor/ — and both runtimes
# here carry vendor/ inside an immutable image. There is no runtime toggle that
# could turn it on; the packages have to be in the tree, then in the image,
# then installed. This does the first step and tells you the other two.
#
# Usage:  scripts/sample-data.sh [-n] [-h]
#
#   -n   dry run: check the prerequisites and print the plan, change nothing
#   -h   this header
#
# Environment overrides:
#   MAGENTO_SRC   the Magento tree to modify  (see scripts/lib.sh)
#   AUTH_JSON     Composer auth file          (default: <MAGENTO_SRC>/auth.json)
#
# IT NEEDS repo.magento.com CREDENTIALS. The sample data packages are on
# Adobe's private Composer repository, not Packagist, and there is no way round
# that — so this refuses with a named error rather than half-running. Create the
# auth file from auth.json.sample in the Magento tree, using the Access Keys
# from the Adobe Commerce account (My Account -> Access Keys): the public key is
# the username and the private key is the password.
#
# Composer runs inside the `dev` image rather than on the host, because that
# image already has PHP 8.4 with the extension set Magento's own dependency
# resolution checks against. A host composer with a different PHP resolves a
# different tree.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

DRY=0
while getopts ":nh" opt; do
    case "$opt" in
        n) DRY=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need docker

AUTH_JSON="${AUTH_JSON:-${MAGENTO_SRC}/auth.json}"
DEV_IMAGE="${IMAGE_NAME}:local-dev"

[[ -d "$MAGENTO_SRC" ]] || die "no Magento tree at ${MAGENTO_SRC}"

if [[ ! -f "$AUTH_JSON" ]]; then
    die "no Composer credentials at ${AUTH_JSON}.

  Sample data is a set of packages on repo.magento.com, which is private. Copy
  the sample and fill in your Adobe Commerce Access Keys:

      cp ${MAGENTO_SRC}/auth.json.sample ${AUTH_JSON}

  The PUBLIC key is the username and the PRIVATE key is the password. Find them
  at commercemarketplace.adobe.com under My Profile -> Access Keys.

  Then run this again. Nothing has been changed."
fi

if ! docker image inspect "$DEV_IMAGE" >/dev/null 2>&1; then
    if [[ $DRY -eq 1 ]]; then
        log "Dry run — would first build ${DEV_IMAGE} (it carries composer; the runtime image does not)"
    else
        log "Building ${DEV_IMAGE} — it carries composer, which the runtime image deliberately does not"
        "${HERE}/build-image.sh" -t dev
    fi
fi

if [[ $DRY -eq 1 ]]; then
    log "Dry run — would run, in ${DEV_IMAGE} against ${MAGENTO_SRC}:"
    log "    bin/magento sampledata:deploy"
    log "Then:  make image && make compose-install   (or make deploy for the cluster)"
    exit 0
fi

# Composer needs a writable home, and the image's /composer belongs to the
# image's app user -- while this runs as the invoking user, so that files
# written into the Magento tree belong to the person who will edit them.
#
# THE COMPOSER HOME IS INSIDE THE CONTAINER AND THE CACHE IS NOT, deliberately.
# Mounting auth.json into a directory that is itself a host mount makes Docker
# create the mountpoint on the HOST -- an empty, root-owned auth.json appearing
# inside this repository, which is exactly the shape of file nobody wants to
# find here later. Only the cache is persisted, and sample data is a large
# enough download that a re-run after a failure should not pay for it twice.
COMPOSER_CACHE_HOST="${COMPOSER_CACHE_HOST:-${K8S_REPO_ROOT}/.tmp/composer-cache}"
mkdir -p "$COMPOSER_CACHE_HOST"

# The flags every composer invocation below shares.
composer_mounts=(
    --user "$(id -u):$(id -g)"
    -v "${MAGENTO_SRC}:/app"
    -v "${COMPOSER_CACHE_HOST}:/composer-cache"
    -v "${AUTH_JSON}:/composer-home/auth.json:ro"
    -e COMPOSER_HOME=/composer-home
    -e COMPOSER_CACHE_DIR=/composer-cache
    -w /app
)

log "Deploying sample data packages into ${MAGENTO_SRC}"
log "Composer cache: ${COMPOSER_CACHE_HOST} (kept between runs)"
docker run --rm "${composer_mounts[@]}" \
    --entrypoint php \
    "$DEV_IMAGE" \
    -d memory_limit=-1 bin/magento sampledata:deploy

# sampledata:deploy runs a plain `composer require`, which reinstates every
# require-dev package as a side effect -- phpunit, Codeception, php-cs-fixer,
# phpstan and the functional testing framework, ~180 MB of it. The Magento tree
# is the build context for the runtime image and the builder uses a staged
# vendor/ as it finds it, so leaving them there ships a test harness and a
# webdriver inside a production image.
#
# The tree was --no-dev before this ran. Putting it back is restoring the state
# sampledata:deploy disturbed, not an optimisation.
log "Restoring the tree to --no-dev (sampledata:deploy reinstates require-dev)"
docker run --rm "${composer_mounts[@]}" \
    --entrypoint composer \
    "$DEV_IMAGE" \
    install --no-dev --no-interaction --no-progress --prefer-dist

# ENABLING THEM IS A SEPARATE STEP AND IT IS NOT OPTIONAL.
#
# `composer require` puts the modules in vendor/; it does not add them to
# app/etc/config.php, and a module absent from config.php does not exist as far
# as Magento is concerned. setup:upgrade normally enables new modules itself --
# but config.php is baked into the image, the install container is the only
# writable one, and it runs with --rm. So setup:upgrade enabled all 26, imported
# against them, and then took the enable away with the container.
#
# The visible result was a store with 41 categories, 48 products, no images and
# no setup_module rows: a sample-data install that looks half-finished because
# it was. config.php belongs to the source tree, so the enable happens here and
# reaches the runtime through the image, like every other part of the code.
log "Enabling the sample data modules in app/etc/config.php"
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "${MAGENTO_SRC}:/app" \
    -w /app \
    --entrypoint sh \
    "$DEV_IMAGE" \
    -c 'mods=$(php bin/magento module:status 2>/dev/null | grep -oE "Magento_[A-Za-z]+SampleData" | sort -u | tr "\n" " ");
        [ -n "$mods" ] || { echo "no sample data modules found to enable" >&2; exit 1; };
        echo "enabling: $mods";
        php -d memory_limit=-1 bin/magento module:enable $mods'

cat <<EOF

  Packages are in the tree. THE STORE DOES NOT HAVE THEM YET — vendor/ only
  reaches a container by way of the image, so two steps remain:

    make image                             rebuild with the new packages
    make compose-install                   install them  (Compose)
    make deploy                            install them  (cluster)

EOF
