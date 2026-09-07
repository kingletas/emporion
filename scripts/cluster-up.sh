#!/usr/bin/env bash
#
# cluster-up.sh — create the kind cluster and everything that is not workload.
#
# Idempotent: safe to run against an existing cluster, which is what makes
# `make up` re-runnable after a failure partway through.
#
# Usage:  scripts/cluster-up.sh [-n] [-h]
#
#   -n   dry run: print the steps without creating anything
#   -h   this header
#
# Environment overrides:
#   CLUSTER_NAME   kind cluster name          (default: vanilla)
#   NAMESPACE      target namespace           (default: vanilla)
#   CERTS_HOME     mkcert certificate dir     (default: certs/ in this repo)
#   SITE_HOST      storefront hostname        (default: vanilla.test)
#
# Steps, in order and each independently skippable if already done:
#   1. kind cluster from cluster/kind-config.yaml
#   2. ingress-nginx from the cached manifest
#   3. namespace
#   4. TLS Secret built from the existing mkcert files
#
# It deliberately does NOT create application Secrets — see secrets.sh, which
# generates them so nothing sensitive is ever a committed literal.

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

run() { if [[ $DRY -eq 1 ]]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

need kind
need kubectl
need docker
need envsubst

INGRESS_MANIFEST="${K8S_REPO_ROOT}/cluster/ingress-nginx.yaml"
[[ -f "$INGRESS_MANIFEST" ]] \
    || die "missing ${INGRESS_MANIFEST}. Run: make tools"

# --- 1. cluster ------------------------------------------------------------
if cluster_exists; then
    log "Cluster '${CLUSTER_NAME}' already exists — leaving it alone"
else
    log "Creating kind cluster '${CLUSTER_NAME}'"
    # THIS REFUSES RATHER THAN WARNS. Both runtimes in this repository serve
    # the same store and the same hostname, and running them together takes
    # this host to a load average in the hundreds with swap exhausted -- two
    # MariaDB instances, two OpenSearch JVMs and two PHP pools each allowed
    # 4Gi because app:config:import needs it, beside an editor and a browser
    # on a 31 GB machine.
    #
    # Measure the stack about to run, not the one sitting still: an idle stack
    # is a fraction of its working footprint, and mistaking one for the other
    # is how this goes wrong.
    #
    # compose_running() matches the compose project LABEL rather than a name
    # prefix, so a renamed container is still caught and an unrelated container
    # that merely starts with the same word is not.
    if compose_running; then
        if [[ "${ALLOW_BOTH:-0}" == "1" ]]; then
            warn "the Compose stack is running and ALLOW_BOTH=1 was set."
            warn "Watch free memory. This combination has made this laptop unusable."
        else
            die "the Compose runtime is up (project '${COMPOSE_PROJECT}'), and the two do not fit together.

  Stop it first:      make compose-down
  Then come back:     make up

  These are two runtimes for ONE store, not two environments. Switching is
  cheap by design -- the cluster takes over ${SITE_HOST} with a single
  /etc/hosts line -- and that is what the port work buys, not concurrency.
  Set ALLOW_BOTH=1 to override, and watch free memory if you do."
        fi
    fi
    # kind reads the config as literal YAML, so ${MAGENTO_SRC} has to be
    # substituted before it ever sees the file. Rendering to .tmp/ keeps the
    # committed config free of any one machine's paths.
    rendered="${K8S_REPO_ROOT}/.tmp/kind-config.yaml"
    mkdir -p "$(dirname "$rendered")"
    MAGENTO_SRC="$MAGENTO_SRC" envsubst '${MAGENTO_SRC}' \
        < "${K8S_REPO_ROOT}/cluster/kind-config.yaml" > "$rendered"
    run kind create cluster --config "$rendered" --wait 120s
fi

# --- 2. ingress ------------------------------------------------------------
log "Installing ingress-nginx"
run kc apply -f "$INGRESS_MANIFEST"
if [[ $DRY -eq 0 ]]; then
    log "Waiting for the ingress controller to become ready"
    kc -n ingress-nginx wait --for=condition=Ready pod \
        --selector=app.kubernetes.io/component=controller --timeout=300s
fi

# --- 3. namespace ----------------------------------------------------------
log "Ensuring namespace '${NAMESPACE}'"
if [[ $DRY -eq 0 ]]; then
    kc get namespace "$NAMESPACE" >/dev/null 2>&1 || kc create namespace "$NAMESPACE"
else
    printf '  would run: kubectl create namespace %s\n' "$NAMESPACE"
fi

# --- 4. TLS ----------------------------------------------------------------
# The mkcert certificate the host browser already trusts. Reusing it is the
# whole reason the ingress can serve https://${SITE_HOST} with no warning and
# no cert-manager, and it replaces the nginx-proxy CERT_NAME mechanism, which
# does not survive the move into a cluster.
#
# IT MUST BE A PER-HOST PAIR, and this used to fall back to the `test.crt`
# wildcard on the grounds that its *.test SAN covered every host on the
# machine. It does not. A wildcard may not span an entire top-level domain, so
# OpenSSL, curl and every browser reject `*.test` for a `.test` hostname:
#
#   openssl verify -CAfile rootCA.crt -verify_hostname second.test test.crt
#   -> error 62 at 0 depth lookup: hostname mismatch
#
# The same cert verifies fine for the names it lists explicitly, which is why
# the fallback looked like it worked for years — nginx-proxy serves it and the
# four hosts that ARE in its SAN list are happy. Any host that is not gets TLS
# a browser refuses, while every file on disk says it is configured.
#
# There is no fallback. Each host gets its own certificate or it has none.
CRT="${CERTS_HOME}/${SITE_HOST}.crt"
KEY="${CERTS_HOME}/${SITE_HOST}.key"
TLS_SECRET="${SITE_SLUG}-tls"
if [[ -f "$CRT" && -f "$KEY" ]]; then
    log "Creating TLS secret ${TLS_SECRET} from ${CRT}"
    if [[ $DRY -eq 0 ]]; then
        kc -n "$NAMESPACE" create secret tls "$TLS_SECRET" \
            --cert="$CRT" --key="$KEY" \
            --dry-run=client -o yaml | kc apply -f -
    else
        printf '  would run: kubectl create secret tls %s --cert=%s --key=%s\n' "$TLS_SECRET" "$CRT" "$KEY"
    fi
else
    warn "no certificate for ${SITE_HOST} at ${CRT}. Issue one with:"
    warn "  mkcert -cert-file ${CRT} -key-file ${KEY} ${SITE_HOST}"
    warn "Until then TLS falls back to the ingress controller's self-signed default,"
    warn "which every browser refuses. This is not cosmetic: a Secure cookie is not"
    warn "stored on an origin the browser does not trust, so the admin will not log in."
fi

log "Cluster is ready. Next: make secrets && make image && make deploy"
