#!/usr/bin/env bash
#
# hosts.sh — print (or check) the /etc/hosts entry the cluster needs.
#
# It PRINTS rather than edits. /etc/hosts is a system file, editing it needs
# sudo, and a script that quietly takes root to change name resolution is not
# a script anyone should run without reading it first.
#
# Usage:  scripts/hosts.sh [-c] [-h]
#
#   -c   check only: exit non-zero if the entry is missing
#   -h   this header
#
# Environment overrides:
#   SITE_HOST   hostname to map   (default: vanilla.test)
#
# Why /etc/hosts rather than the existing dnsmasq container: dnsmasq resolves
# *.test to nginx-proxy on 172.17.0.1, which is how the Compose runtime in this
# repository is reached. The cluster's edge is the kind node's published 80/443
# on 127.0.0.1. Repointing dnsmasq would mean one runtime or the other, for
# every .test host on the machine; a hosts entry is per-name, reversible with
# one line, and leaves the other eight vhosts alone.
#
# This is what makes switching between the two runtimes cheap. It is NOT
# permission to run both — see scripts/compose-up.sh and scripts/cluster-up.sh,
# which refuse.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

CHECK=0
while getopts ":ch" opt; do
    case "$opt" in
        c) CHECK=1 ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

ENTRY="127.0.0.1  ${SITE_HOST}"

if grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+.*\b${SITE_HOST}\b" /etc/hosts 2>/dev/null; then
    log "${SITE_HOST} already resolves to 127.0.0.1 via /etc/hosts"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    die "${SITE_HOST} is not in /etc/hosts"
fi

cat <<EOF

  ${SITE_HOST} does not resolve to 127.0.0.1 yet. Add it with:

    echo '${ENTRY}' | sudo tee -a /etc/hosts

  Remove it again with:

    sudo sed -i '/^127\\.0\\.0\\.1[[:space:]]\\+${SITE_HOST}\$/d' /etc/hosts

  Note that ${SITE_HOST} is also served by the Compose stack through dnsmasq
  and nginx-proxy. Whichever of the two is running answers on 443; they cannot
  both hold the port, so this entry does not have to be removed to go back to
  Compose — the port conflict resolves itself.

EOF
