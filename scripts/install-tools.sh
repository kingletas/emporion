#!/usr/bin/env bash
#
# install-tools.sh — install kind and kubectl into ~/bin.
#
# Nothing else in this repository downloads anything. This is the one place,
# so the network surface of `make up` is auditable in a single file.
#
# It also caches the ingress-nginx manifest that cluster-up.sh applies, so a
# cluster can be rebuilt later without reaching the network again.
#
# Usage:  scripts/install-tools.sh [-n] [-y] [-h]
#
#   -n   dry run: print what would be downloaded and where it would land
#   -y   skip the confirmation prompt (unattended use)
#   -h   this header
#
# Environment overrides:
#   BIN_DIR        install destination                  (default: $HOME/bin)
#   KIND_VERSION   pin a kind release, e.g. v0.30.0     (default: latest tag)
#   KUBECTL_VERSION pin a kubectl release               (default: stable.txt)
#   ARCH           amd64 | arm64                        (default: uname -m)
#   INGRESS_REF    ingress-nginx git ref for the manifest (default: main)
#
# Both binaries are installed under $HOME/bin per the house rule that every
# tool lives there and nothing is invoked by absolute path. They are binaries,
# so ~/bin/.gitignore must keep excluding them — see that repo's first commit
# for why 2 GB of downloaded tools is not history worth keeping.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

BIN_DIR="${BIN_DIR:-$HOME/bin}"
DRY=0; YES=0

while getopts ":nyh" opt; do
    case "$opt" in
        n) DRY=1 ;;
        y) YES=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

case "${ARCH:-$(uname -m)}" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

resolve_kind_version() {
    [[ -n "${KIND_VERSION:-}" ]] && { echo "$KIND_VERSION"; return; }
    # Ask GitHub rather than pinning a version that will 404 in six months.
    #
    # The response is captured before it is filtered, deliberately. Piping
    # curl straight into `grep -m1` makes grep exit on the first match, curl
    # take SIGPIPE, and `set -o pipefail` fail the whole function with
    # "Failure writing output to destination" — which reads like a network
    # problem and is not one.
    local body
    body="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest)" || return 1
    printf '%s\n' "$body" | grep '"tag_name"' | head -1 | cut -d'"' -f4
}

resolve_kubectl_version() {
    [[ -n "${KUBECTL_VERSION:-}" ]] && { echo "$KUBECTL_VERSION"; return; }
    curl -fsSL https://dl.k8s.io/release/stable.txt
}

log "Resolving versions..."
KIND_V="$(resolve_kind_version)"    || die "could not resolve the latest kind release"
KUBECTL_V="$(resolve_kubectl_version)" || die "could not resolve the latest kubectl release"

KIND_URL="https://kind.sigs.k8s.io/dl/${KIND_V}/kind-linux-${ARCH}"
KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_V}/bin/linux/${ARCH}/kubectl"
INGRESS_REF="${INGRESS_REF:-main}"
INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_REF}/deploy/static/provider/kind/deploy.yaml"
INGRESS_DEST="${K8S_REPO_ROOT}/cluster/ingress-nginx.yaml"

cat <<EOF

  This will download two binaries and install them into ${BIN_DIR}:

    kind     ${KIND_V}      ${KIND_URL}
    kubectl  ${KUBECTL_V}   ${KUBECTL_URL}

  and cache one manifest (~1 MB, not a binary, gitignored):

    ingress-nginx (kind provider)  ${INGRESS_URL}
      -> ${INGRESS_DEST}

  kubectl is verified against the official sha256 published alongside it.
  kind is verified against the checksum file in its GitHub release.

EOF

if [[ $DRY -eq 1 ]]; then
    log "Dry run — nothing downloaded."
    exit 0
fi

if [[ $YES -eq 0 ]]; then
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "aborted"
fi

mkdir -p "$BIN_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Downloading kind ${KIND_V}"
curl -fsSL -o "${tmp}/kind" "$KIND_URL"
if curl -fsSL -o "${tmp}/kind.sha256sum" \
        "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_V}/kind-linux-${ARCH}.sha256sum" 2>/dev/null; then
    ( cd "$tmp" && awk '{print $1"  kind"}' kind.sha256sum | sha256sum -c - ) \
        || die "kind checksum mismatch — not installing"
else
    warn "no published checksum for kind ${KIND_V}; skipping verification"
fi

log "Downloading kubectl ${KUBECTL_V}"
curl -fsSL -o "${tmp}/kubectl" "$KUBECTL_URL"
curl -fsSL -o "${tmp}/kubectl.sha256" "${KUBECTL_URL}.sha256"
( cd "$tmp" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - ) \
    || die "kubectl checksum mismatch — not installing"

log "Caching the ingress-nginx manifest"
curl -fsSL -o "${tmp}/ingress-nginx.yaml" "$INGRESS_URL"
grep -q 'kind: Deployment' "${tmp}/ingress-nginx.yaml" \
    || die "the ingress-nginx manifest does not look like Kubernetes YAML — refusing to cache it"
install -m 0644 "${tmp}/ingress-nginx.yaml" "$INGRESS_DEST"

install -m 0755 "${tmp}/kind"    "${BIN_DIR}/kind"
install -m 0755 "${tmp}/kubectl" "${BIN_DIR}/kubectl"

log "Installed:"
"${BIN_DIR}/kind" --version
"${BIN_DIR}/kubectl" version --client --output=yaml | head -4

cat <<'EOF'

  One thing to fix by hand, because a script should not edit a shell rc:

    ~/.bash_aliases line 60 defines

        alias kubectl='minikube kubectl --'

    minikube is not installed, so that alias makes `kubectl` fail with
    "command not found: minikube" and shadows the binary just installed.
    Remove the alias, or start a new shell after removing it.

EOF
