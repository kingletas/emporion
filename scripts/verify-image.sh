#!/usr/bin/env bash
#
# verify-image.sh — acceptance criterion A7, and an honest report of how far
# it actually gets.
#
# A7 asks that two builds from one commit produce the same digest. That is not
# achievable here and saying so precisely is worth more than a check that
# passes by measuring something easier:
#
#   - the base image is php:8.4-fpm by tag, and that tag moves
#   - apt-get pulls whatever the Debian mirror currently has
#   - composer resolves within its constraints unless a lock is committed
#   - every layer carries a build timestamp
#
# Byte-identical image digests need a fully pinned base by digest, a pinned
# apt snapshot, a committed composer.lock and SOURCE_DATE_EPOCH with BuildKit
# timestamp rewriting. Three of those four are outside this repository.
#
# What IS checkable, and what this script checks, is the part the build
# actually depends on: that the APPLICATION CONTENT of two builds is identical
# — the same code, the same vendor tree, the same generated/ and the same
# compiled static content. If that holds, the image is reproducible in the
# sense that matters for a deploy, and the remaining difference is the base OS.
#
# Usage:  scripts/verify-image.sh [-h]
#
# Environment overrides:
#   IMAGE_NAME / IMAGE_TAG   the image to verify

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }
need docker

TAG="${IMAGE_NAME}:${IMAGE_TAG}"
docker image inspect "$TAG" >/dev/null 2>&1 || die "no image ${TAG}. Run: make image"

log "Hashing the application content of ${TAG}"
log "(this reads /app out of the image; it does not rebuild)"

# tar --sort=name --mtime with a fixed epoch, numeric owner: everything that
# is not file content is normalised away, so the hash describes the tree and
# nothing else.
content_hash() {
    docker run --rm --entrypoint sh "$1" -c \
        'cd /app && tar --sort=name --mtime="@0" --owner=0 --group=0 --numeric-owner \
             --exclude=./var --exclude=./pub/media \
             -cf - . 2>/dev/null' \
        | sha256sum | cut -d' ' -f1
}

first="$(content_hash "$TAG")"
printf '\n  application content sha256: %s\n\n' "$first"

cat <<EOF
  To complete A7, build a second time from the same commit and compare:

      make image
      scripts/verify-image.sh

  Equal hashes mean the application content is reproducible. They do NOT mean
  the image digests match — see the header of this script for the four
  reasons, three of which cannot be fixed from inside this repository.

  Record the result either way. An unsolved problem described precisely is
  worth more than a solved one described vaguely.
EOF
