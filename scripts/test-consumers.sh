#!/usr/bin/env bash
#
# test-consumers.sh — the one list of consumers and the four files made from
# it, tried on a copy of this repository's files so nothing here is changed.
#
# What it holds: a consumer added with one line reaches the cluster's
# Deployments, both Compose files and MAGENTO_CONSUMERS; the six shipped ones
# come out as they are committed; a made file edited by hand is refused by
# name; and a line that cannot be read is refused by its line number.
#
# Usage:  scripts/test-consumers.sh [-h]
#
# Silent when everything holds, one FAIL line per thing that does not.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

[[ "${1:-}" == "-h" ]] && { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

LIST=k8s/base/config/consumers.list
MADE=(k8s/base/jobs/consumers.yaml docker-compose.yaml docker-compose.dev.yaml k8s/base/config/env/common.env)

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

failures=0
check() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" != "$want" ]]; then
        printf '    FAIL  %s: wanted %q, got %q\n' "$name" "$want" "$got"
        failures=$((failures + 1))
    fi
}

# A fresh copy of the list and the four made files, as committed.
fresh() {
    rm -rf -- "${work:?}/repo"
    mkdir -p "$work/repo/k8s/base/config/env" "$work/repo/k8s/base/jobs"
    local f
    for f in "$LIST" "${MADE[@]}"; do cp "$ROOT/$f" "$work/repo/$f"; done
}
make_consumers() { "$HERE/make-consumers.sh" -r "$work/repo" "$@" 2>&1; }
# yes when the pattern is in the copy's file, no when it is not.
holds() { if grep -qE -- "$2" "$work/repo/$1"; then echo yes; else echo no; fi; }

fresh
check "the shipped files are what the shipped list makes" 0 "$(make_consumers --check >/dev/null; echo $?)"
make_consumers >/dev/null
for f in "${MADE[@]}"; do
    check "making them again changes nothing in $f" same "$(cmp -s "$ROOT/$f" "$work/repo/$f" && echo same || echo changed)"
done

# One line, an invented queue, nothing but its name.
fresh
echo "acme.widget_sync" >> "$work/repo/$LIST"
check "the list with one more line no longer matches the made files" 1 "$(make_consumers --check >/dev/null; echo $?)"
check "making them with one more line succeeds" 0 "$(make_consumers >/dev/null; echo $?)"
check "the new consumer has a Deployment named from its queue" yes "$(holds k8s/base/jobs/consumers.yaml '^  name: consumer-acme-widget-sync$')"
check "which carries the label everything finds consumers by" yes "$(holds k8s/base/jobs/consumers.yaml '^    vanilla.dev/consumer: "acme.widget_sync"$')"
check "and starts that queue with the default batch" yes "$(holds k8s/base/jobs/consumers.yaml '^            - "acme.widget_sync"$')"
check "it has a Compose service" yes "$(holds docker-compose.yaml '^  consumer-acme-widget-sync:$')"
check "running the same queue" yes "$(holds docker-compose.yaml '"queue:consumers:start", "acme.widget_sync", "--max-messages=100"\]$')"
check "it has its entry in the dev Compose file" yes "$(holds docker-compose.dev.yaml '^  consumer-acme-widget-sync:$')"
check "and Magento is told about it" yes "$(holds k8s/base/config/env/common.env '^MAGENTO_CONSUMERS=.* acme\.widget_sync$')"
check "nine Deployments now" 9 "$(grep -c '^kind: Deployment$' "$work/repo/k8s/base/jobs/consumers.yaml")"
check "the eight shipped ones are still there" 8 "$(grep -cE '^  name: consumer-(async-operations-all|product-action-attribute-update|inventory-reservations-update|inventory-reservations-cleanup|media-gallery-synchronization|codegenerator|inventory-salability-status|sales-rule-update-coupon-usage)$' "$work/repo/k8s/base/jobs/consumers.yaml")"
check "after making, the files match the list again" 0 "$(make_consumers --check >/dev/null; echo $?)"

# The settings a line can carry.
fresh
echo "acme.widget_sync max=250 memory=128Mi/256Mi name=consumer-widgets compose=consumer-widgets-local  # Keeps invented widgets in step." >> "$work/repo/$LIST"
make_consumers >/dev/null
check "a line's own name is used for the Deployment" yes "$(holds k8s/base/jobs/consumers.yaml '^  name: consumer-widgets$')"
check "its own batch size" yes "$(holds k8s/base/jobs/consumers.yaml '^            - "--max-messages=250"$')"
check "its own memory request" yes "$(holds k8s/base/jobs/consumers.yaml '^              memory: 128Mi$')"
check "its own Compose name" yes "$(holds docker-compose.yaml '^  consumer-widgets-local:$')"
check "and what it is for, above its Deployment" yes "$(holds k8s/base/jobs/consumers.yaml '^# Keeps invented widgets in step\.$')"

# A made file edited by hand.
fresh
sed -i 's/--max-messages=100"\]$/--max-messages=7"]/' "$work/repo/docker-compose.yaml"
out="$(make_consumers --check || true)"
check "a Compose service edited by hand is refused" 1 "$(make_consumers --check >/dev/null; echo $?)"
check "by the file's name" yes "$(grep -q 'docker-compose.yaml is not what' <<< "$out" && echo yes || echo no)"
check "and the other three are not accused" 1 "$(grep -c 'is not what' <<< "$out")"
fresh
sed -i 's/^MAGENTO_CONSUMERS=.*/MAGENTO_CONSUMERS=async.operations.all/' "$work/repo/k8s/base/config/env/common.env"
check "a consumer taken out of MAGENTO_CONSUMERS by hand is refused" 1 "$(make_consumers --check >/dev/null; echo $?)"
fresh
sed -i '0,/memory: 384Mi/s//memory: 1Mi/' "$work/repo/k8s/base/jobs/consumers.yaml"
check "a Deployment edited by hand is refused" 1 "$(make_consumers --check >/dev/null; echo $?)"
check "a check writes nothing" yes "$(holds k8s/base/jobs/consumers.yaml 'memory: 1Mi')"

# Lines that cannot be read, each refused by where it is.
refused() {
    fresh
    echo "$1" >> "$work/repo/$LIST"
    local out
    out="$(make_consumers || true)"
    if grep -q -- "consumers.list:[0-9]*: .*$2" <<< "$out"; then echo yes; else echo "no: $out"; fi
}
check "a setting nobody knows is refused" yes "$(refused 'acme.widget_sync replicas=3' 'is not a setting')"
check "a queue listed twice is refused" yes "$(refused 'async.operations.all' 'listed twice')"
check "a name that does not start with consumer- is refused" yes "$(refused 'acme.widget_sync name=widgets' 'has to start with consumer-')"
check "a batch size that is not a number is refused" yes "$(refused 'acme.widget_sync max=many' 'is not a count of messages')"
check "a memory setting with one half is refused" yes "$(refused 'acme.widget_sync memory=128Mi' 'is not REQUEST/LIMIT')"
fresh
check "nothing was written by a refused line" 0 "$(echo 'acme.widget_sync replicas=3' >> "$work/repo/$LIST"; make_consumers >/dev/null || true; grep -c 'acme' "$work/repo/docker-compose.yaml" || true)"

# A file that lost a marker cannot be written into safely.
fresh
sed -i '/# <<< consumers/d' "$work/repo/docker-compose.yaml"
out="$(make_consumers || true)"
check "a Compose file without its markers is refused" yes "$(grep -q 'two consumers markers' <<< "$out" && echo yes || echo no)"

if (( failures )); then
    exit 1
fi
