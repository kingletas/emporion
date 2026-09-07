# syntax=docker/dockerfile:1.7
#
# The application image, and the single artefact both runtimes in this
# repository run: the kind cluster's prod-shaped overlay and the Compose stack
# both deploy this image and nothing else. One build, one extension set, one
# compile -- so a difference between the two runtimes can never be the image.
#
# Four targets:
#
#   php-base    extensions + loaders, no application, no composer, no Xdebug
#   dev         php-base + Xdebug + composer, and NO application code —
#               the dev overlay mounts the working tree in (ADR-007)
#   builder     php-base + composer + source, runs composer install,
#               setup:di:compile and setup:static-content:deploy
#   runtime     php-base + the built /app from builder — the default target
#
# COMPILE_EXCLUDES below is the escape hatch for a vendor package that cannot
# be compiled at all. `setup:di:compile` scans the whole of vendor/ regardless
# of module enablement, so a single encoded or incompatible package fails the
# build outright and disabling its module changes nothing -- removing it is the
# only way through. It is EMPTY for this tree, which is the state to keep it
# in. If it ever has to be filled, the build prints the exclusion, writes it
# into the image and the entrypoint prints it again at start: a workaround
# nobody can see is indistinguishable from a bug. See ADR-004.

ARG PHP_VERSION=8.4

# =============================================================================
# php-base — everything the application needs to run, and nothing it needs to
#            be built. Shared by every other target so the extension set is
#            provably identical between the dev pool and the prod-shaped one.
# =============================================================================
FROM php:${PHP_VERSION}-fpm AS php-base

ARG PHP_VERSION
ARG DEBIAN_FRONTEND=noninteractive
ARG SG_DOWNLOAD_URL=https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz

ENV TZ=America/Chicago \
    COMPOSER_HOME=/composer \
    COMPOSER_ALLOW_SUPERUSER=1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libicu-dev \
        libffi-dev libxml2-dev libsodium-dev libxslt1-dev libzip-dev \
        zlib1g-dev g++ make autoconf \
        git unzip patch rsync tzdata ca-certificates curl \
        libfcgi-bin \
    ; \
    rm -rf /var/lib/apt/lists/*

# libfcgi-bin is not decoration. It provides cgi-fcgi, which is what makes a
# real readiness probe possible against php-fpm: a TCP check on 9000 says the
# socket is open, not that the pool can execute PHP. That distinction is the
# whole rule here: every dependency is expressed as a probe, and no init
# container merely waits.

RUN set -eux; \
    docker-php-source extract; \
    pecl install redis; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
        bcmath ftp gd intl opcache pcntl pdo pdo_mysql soap sockets xsl zip; \
    docker-php-ext-enable redis; \
    docker-php-source delete

# SourceGuardian. Required by encoded vendor packages in the on-premise source
# tree; harmless on Magento Open Source, where nothing is encoded. Kept in the
# base rather than made conditional so both source options produce an image
# with the same runtime surface.
RUN set -eux; \
    mkdir -p /tmp/sg; cd /tmp/sg; \
    curl -fsSL "${SG_DOWNLOAD_URL}" -o loaders.tar.gz; \
    tar -xzf loaders.tar.gz; \
    cp -f "ixed.${PHP_VERSION}.lin" "$(php-config --extension-dir)/sourceguardian.so"; \
    echo "zend_extension=sourceguardian.so" > "${PHP_INI_DIR}/conf.d/00-sourceguardian.ini"; \
    cd /; rm -rf /tmp/sg

COPY rootfs/ /

# The php-fpm pool listens on 9000 and exposes /ping and /status. Both are
# probe targets; /status is also how `make top` reads live pool saturation
# rather than guessing at the resource requests.
RUN set -eux; \
    rm -f /usr/local/etc/php-fpm.d/www.conf.default; \
    chmod +x /usr/local/bin/magento-entrypoint \
             /usr/local/bin/magento-install \
             /usr/local/bin/fpm-ping

# The application user. Matches the UID/GID the Compose image uses so a
# hostPath-mounted working tree in the dev overlay has the same ownership it
# has under Compose, and files created by one are writable by the other.
ARG UID=1001
ARG GID=1001
RUN set -eux; \
    groupadd -g "${GID}" app; \
    useradd -u "${UID}" -g "${GID}" -ms /bin/bash app; \
    mkdir -p /app; chown app:app /app

WORKDIR /app
EXPOSE 9000
ENTRYPOINT ["magento-entrypoint"]
CMD ["php-fpm", "-F"]

# =============================================================================
# composer — a thin layer the two targets that need composer share.
# =============================================================================
FROM php-base AS composer
ARG COMPOSER_VERSION=2.9.3
RUN set -eux; \
    curl -fsSL https://getcomposer.org/installer | php -- \
        --install-dir=/usr/local/bin --filename=composer --version="${COMPOSER_VERSION}"; \
    mkdir -p /composer; chown app:app /composer

# =============================================================================
# dev — the developer pool. Xdebug present, application code deliberately
#       absent: the dev overlay mounts the working tree at /app, which is the
#       whole point of having two overlays (ADR-007).
# =============================================================================
FROM composer AS dev
RUN set -eux; \
    docker-php-source extract; \
    pecl install xdebug; \
    docker-php-ext-enable xdebug; \
    docker-php-source delete
COPY rootfs-dev/ /
# Xdebug is installed but OFF by default. Merely loading it with mode != off
# costs roughly 2x on every request — measured at 1.06s vs 0.56s on a product
# page — so leaving it hot would make every timing taken here meaningless.
# Turn it on for a pod with:  kubectl set env deploy/php-fpm XDEBUG_MODE=debug
ENV XDEBUG_MODE=off
USER app

# =============================================================================
# builder — where the image stops being a translation of the Compose file and
#           starts being a build. Everything here has to succeed for the image
#           to be the one artefact both runtimes run.
# =============================================================================
FROM composer AS builder

# Which Magento tree to build. See ADR-006. The default is whatever the caller
# stages into the build context; the published artifact has to stand up on
# Magento Open Source before it goes anywhere, which is why this is an
# argument and not a hardcoded path.
ARG MAGENTO_EDITION=onprem

# Vendor packages removed before `setup:di:compile` runs. Space-separated, and
# EMPTY, which is the goal state: this tree compiles as it is, so the image
# contains exactly what composer.lock resolves to.
#
# Each entry, if there ever is one, is a package that cannot be compiled here
# and the reason it cannot. Excluding one changes what the image contains and
# therefore what the application can do, so the build prints it, records it in
# the image, and the entrypoint prints it again at start.
ARG COMPILE_EXCLUDES=""

# Escape hatch for iterating on the manifests before the compile is solved.
# An image built with this is NOT the one that ships — the entrypoint refuses to
# start it under the prod-shaped overlay.
ARG SKIP_COMPILE=false

# Deployed locales and themes for static content. Narrow on purpose: a full
# static deploy of every theme is the single longest step in the build and
# most of it is never requested locally.
ARG STATIC_LOCALES="en_US"

USER app

# The Magento tree comes in as a BuildKit named context rather than as a
# directory inside build/. Copying or symlinking a ~9 GB working tree into a
# build context to satisfy `COPY src/` wastes minutes and disk on every build,
# and a symlink would not be followed at all. scripts/build-image.sh passes:
#     --build-context magento-src=${MAGENTO_SRC}
COPY --from=magento-src --chown=app:app . /app/

RUN set -eux; \
    cd /app; \
    if [ ! -d vendor ]; then \
        echo "==> vendor/ absent — running composer install"; \
        composer install --no-dev --no-interaction --prefer-dist --no-progress; \
    else \
        echo "==> vendor/ present in the build context — using it as staged"; \
    fi

RUN set -eux; \
    cd /app; \
    for pkg in ${COMPILE_EXCLUDES}; do \
        if [ -d "vendor/${pkg}" ]; then \
            echo "==> EXCLUDING ${pkg} from the image (see ADR-004)"; \
            rm -rf "vendor/${pkg}"; \
        fi; \
    done; \
    if [ -n "${COMPILE_EXCLUDES}" ] && [ -f vendor/composer/installed.json ]; then \
        echo "==> recording the exclusions in the image"; \
        printf '%s\n' ${COMPILE_EXCLUDES} > /app/var/.compile-excludes; \
    fi

# THE MODULE LIST HAS TO EXIST BEFORE ANYTHING ELSE RUNS, and a freshly
# created Magento tree has no app/etc/config.php at all -- that file is written
# by `setup:install`, so a tree that has been installed once carries it and a
# `composer create-project` tree does not. Without it every bin/magento command
# refuses:
#
#   You cannot run this command because modules are not enabled.
#
# `module:enable --all` writes the list and needs no database. It is skipped
# when the tree already carries one, so an installed tree keeps whatever module
# set it was installed with rather than having every module switched back on.
RUN set -eux; \
    cd /app; \
    if [ -f app/etc/config.php ] && grep -q "'modules'" app/etc/config.php; then \
        echo "==> app/etc/config.php already carries a module list — leaving it alone"; \
    else \
        echo "==> no module list in app/etc/config.php — running module:enable --all"; \
        php -d memory_limit=-1 bin/magento module:enable --all; \
    fi

# Static content is deployed here, with NO DATABASE, because it has to be in
# the image. Magento supports that by reading the store scopes out of
# app/etc/config.php instead — but that file carries only the module list,
# with no `scopes` key, and the deploy then resolves every file and dies on
# the first asset that asks for a base URL:
#
#   Error happened during deploy process: The default website isn't defined.
#
# scd-scopes.php adds the installer's own default scopes for the length of the
# deploy, and config.php is put back immediately afterwards. It must NOT ship:
# scopes in the image would be a second, stale source of truth that
# `app:config:import` would reconcile against the database on every deploy.
COPY --chown=app:app scd-scopes.php /tmp/scd-scopes.php

RUN set -eux; \
    cd /app; \
    if [ "${SKIP_COMPILE}" = "true" ]; then \
        echo "==> SKIP_COMPILE=true — this image is for manifest iteration only"; \
        touch /app/var/.skip-compile; \
    else \
        php -d memory_limit=-1 bin/magento setup:di:compile; \
        cp app/etc/config.php /tmp/config.php.orig; \
        php /tmp/scd-scopes.php app/etc/config.php; \
        php -d memory_limit=-1 bin/magento setup:static-content:deploy -f ${STATIC_LOCALES}; \
        cp /tmp/config.php.orig app/etc/config.php; \
        rm -f /tmp/config.php.orig /tmp/scd-scopes.php; \
        echo "==> config.php restored to the source version"; \
    fi

# `var/` is pod-local at runtime, so nothing under it survives into a
# running pod except what is copied out here. generated/ and pub/static do
# survive: they are the two directories that must be in the image rather than
# on a shared claim, and baking them is what removes two of the three writers
# from the ReadWriteMany problem in ADR-003.
RUN set -eux; \
    cd /app; \
    rm -rf var/cache/* var/page_cache/* var/session/* var/view_preprocessed/*; \
    # -prune and -delete do not compose: -delete implies -depth, which makes
    # -prune a no-op, and find says so on every build. The dotfile exclusion is
    # a plain -name test instead, which is what was meant.
    find var -mindepth 1 -maxdepth 1 -type d -empty ! -name '.*' -delete || true

# =============================================================================
# runtime — the default target. Immutable: code, vendor, generated and static
#           content are all inside, and nothing writes to them.
# =============================================================================
FROM php-base AS runtime

ARG GIT_SHA=unknown
ARG BUILD_EDITION=onprem
LABEL org.opencontainers.image.title="magento-app" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      dev.vanilla.magento-edition="${BUILD_EDITION}"

COPY --from=builder --chown=app:app /app /app

# Writable paths, and only these. Everything else in /app is read-only at
# runtime and the prod-shaped overlay enforces that with readOnlyRootFilesystem
# plus explicit volumes, so a component that quietly writes into the code tree
# fails loudly instead of working until the pod is replaced.
# NOT `chown -R`, and the difference is minutes and about a gigabyte. The COPY
# above already lands the whole tree as app:app, so a recursive chown here
# changes nothing about ownership and everything about the image: it touches
# every file, which writes a second full copy of pub/static and vendor into a
# new layer. Only the directories created on the line above need an owner.
RUN set -eux; \
    mkdir -p /app/var /app/pub/media /app/pub/static/_cache; \
    chown app:app /app/var /app/pub/media /app/pub/static /app/pub/static/_cache

# app/etc/env.php is per-environment, holds credentials, and carries
# cron_consumers_runner — the list that decides which queue consumers run at
# all. On Kubernetes it is assembled at pod start from a ConfigMap
# and a Secret, which means it has to live somewhere writable while /app does
# not. Baking the symlink here is what makes that possible without mounting a
# volume over app/etc and hiding config.php in the process.
RUN set -eux; \
    rm -f /app/app/etc/env.php; \
    ln -s /etc/magento/env.php /app/app/etc/env.php; \
    mkdir -p /etc/magento; chown app:app /etc/magento

ENV MAGENTO_ROOT=/app
USER app
