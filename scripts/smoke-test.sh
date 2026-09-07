#!/usr/bin/env bash
#
# smoke-test.sh — walk the acceptance criteria and report each one pass or fail.
#
# The criteria are listed in docs/operations.md. They are written as checks
# rather than as prose because a criterion nobody can run is an assertion with
# extra steps.
#
# Usage:  scripts/smoke-test.sh [-c LIST] [-h]
#
#   -c   comma-separated criteria to run  (default: all)
#        e.g. -c A2,A4,A11
#   -h   this header
#
# Environment overrides:
#   SITE_HOST      storefront hostname   (default: vanilla.test)
#   NAMESPACE      namespace             (default: vanilla)
#
# Not implemented here, and deliberately so:
#   A1   is `make down && make up` — this script cannot check the thing it
#        runs inside
#   A7   image reproducibility needs two builds; see `make verify-image`
#   A10  resource requests are read, not tested; see `make top`
#   A12  documentation

set -uo pipefail   # NOT -e: every criterion must run even after one fails,
                   # because a report of the first failure is far less useful
                   # than a report of all of them.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

ONLY=""
while getopts ":c:h" opt; do
    case "$opt" in
        c) ONLY="$OPTARG" ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need kubectl
need curl

PASS=0; FAIL=0; SKIP=0

want() {
    [[ -z "$ONLY" ]] && return 0
    [[ ",${ONLY}," == *",$1,"* ]]
}

result() {
    case "$1" in
        pass) PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-4s %s\n' "$2" "$3" ;;
        fail) FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-4s %s\n' "$2" "$3" ;;
        skip) SKIP=$((SKIP+1)); printf '  \033[33m-\033[0m %-4s %s\n' "$2" "$3" ;;
    esac
}

# Requests go through the ingress on the host's 443, which kind maps from the
# node. --resolve rather than relying on /etc/hosts so the check works even
# before `make hosts` has been run, and -k because mkcert's CA is trusted by
# the browser rather than by curl's bundle.
fetch() {
    curl -sk -o /dev/null -w '%{http_code}' --resolve "${SITE_HOST}:443:127.0.0.1" \
        --max-time 60 "https://${SITE_HOST}$1"
}
fetch_headers() {
    curl -sk -D - -o /dev/null --resolve "${SITE_HOST}:443:127.0.0.1" \
        --max-time 60 "https://${SITE_HOST}$1"
}

echo
echo "Acceptance criteria"
echo

# --- A2: the storefront renders ------------------------------------------
if want A2; then
    code="$(fetch /)"
    if [[ "$code" == "200" ]]; then
        result pass A2 "storefront home returns 200"
    else
        result fail A2 "storefront home returned ${code}"
    fi
fi

# --- A3: admin login is reachable and the session store is the shared one --
if want A3; then
    code="$(fetch /admin)"
    if [[ "$code" == "200" || "$code" == "302" ]]; then
        # The half of A3 that matters is not that the page renders — it is
        # that sessions live in Valkey rather than in a pod. A pod-local
        # session store passes a login test and fails the moment there are
        # two replicas.
        if kc -n "$NAMESPACE" exec deploy/php-fpm -- \
                sh -c "grep -q \"'save' => 'redis'\" /etc/magento/env.php" 2>/dev/null; then
            result pass A3 "admin reachable (${code}) and sessions are in Valkey, not the pod"
        else
            result fail A3 "admin reachable but env.php does not put sessions in Valkey"
        fi
    else
        result fail A3 "admin returned ${code}"
    fi
fi

# --- A4: data survives pod replacement -----------------------------------
if want A4; then
    ok=1
    for sts in mariadb opensearch rabbitmq valkey-session; do
        claim="$(kc -n "$NAMESPACE" get sts "$sts" \
            -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null)"
        [[ -n "$claim" ]] || { ok=0; result fail A4 "${sts} has no volumeClaimTemplate"; }
    done
    # The claim is only worth as much as the test, so actually replace a pod.
    if [[ $ok -eq 1 ]]; then
        # The write's own output is not the evidence — the read after the pod
        # replacement is. Capturing it into a variable nothing reads is what
        # SC2034 was pointing at, and it read as a forgotten check. Note that a
        # comment whose first word is 'shellcheck' is parsed as a directive.
        kc -n "$NAMESPACE" exec valkey-session-0 -- valkey-cli set smoke-a4 alive >/dev/null 2>&1
        kc -n "$NAMESPACE" delete pod valkey-session-0 --wait=true >/dev/null 2>&1
        kc -n "$NAMESPACE" wait --for=condition=Ready pod/valkey-session-0 --timeout=120s >/dev/null 2>&1
        after="$(kc -n "$NAMESPACE" exec valkey-session-0 -- valkey-cli get smoke-a4 2>/dev/null | tr -d '\r')"
        if [[ "$after" == "alive" ]]; then
            result pass A4 "value written before \`delete pod\` survived the replacement"
        else
            result fail A4 "value did not survive pod replacement (got '${after}')"
        fi
    fi
fi

# --- A5: no startup ordering ---------------------------------------------
if want A5; then
    # The check is not "are there init containers" — there are two, and both
    # do work. It is "does any init container merely wait", which is what the
    # criterion actually bans.
    waiters="$(kc -n "$NAMESPACE" get deploy,sts -o json 2>/dev/null \
        | grep -oE '"command":\[[^]]*(nc -z|wait-for|until nc|sleep [0-9]+;)[^]]*\]' | wc -l)"
    probed="$(kc -n "$NAMESPACE" get deploy,sts -o json 2>/dev/null | grep -c 'readinessProbe')"
    if [[ "$waiters" == "0" && "$probed" -gt 0 ]]; then
        result pass A5 "no waiting init containers; ${probed} readiness probes declared"
    else
        result fail A5 "${waiters} init container(s) look like they are just waiting"
    fi
fi

# --- A8: scheduled work runs unattended ----------------------------------
if want A8; then
    ran="$(kc -n "$NAMESPACE" get jobs -l app.kubernetes.io/name=magento-cron \
        --no-headers 2>/dev/null | wc -l)"
    consumers="$(kc -n "$NAMESPACE" get deploy -l vanilla.dev/tier=consumer \
        -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
        | grep -c '^1$')"
    if [[ "$ran" -gt 0 && "$consumers" -gt 0 ]]; then
        result pass A8 "${ran} cron Job(s) have fired; ${consumers} consumer(s) running with nobody starting them"
    elif [[ "$ran" -eq 0 ]]; then
        result fail A8 "no cron Job has fired yet (the CronJob runs every minute — wait, then re-run)"
    else
        result fail A8 "cron fired but no consumer Deployment is ready"
    fi
fi

# --- A9: media is shared -------------------------------------------------
if want A9; then
    replicas="$(kc -n "$NAMESPACE" get deploy php-fpm -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    if [[ "${replicas:-0}" -lt 2 ]]; then
        result skip A9 "needs 2 php-fpm replicas to mean anything — run the prod-shaped overlay"
    else
        # read -ra rather than pods=($(...)): the unquoted expansion also globs,
        # so a pod name containing a glob character would be expanded against
        # the filesystem before it ever reached the array (SC2207).
        read -ra pods <<<"$(kc -n "$NAMESPACE" get pod -l app.kubernetes.io/name=php-fpm \
            -o jsonpath='{.items[*].metadata.name}')"
        token="a9-$(date +%s)"
        kc -n "$NAMESPACE" exec "${pods[0]}" -- \
            sh -c "echo ${token} > /app/pub/media/.smoke-a9" >/dev/null 2>&1
        seen="$(kc -n "$NAMESPACE" exec "${pods[1]}" -- \
            sh -c "cat /app/pub/media/.smoke-a9 2>/dev/null" 2>/dev/null | tr -d '\r\n')"
        if [[ "$seen" == "$token" ]]; then
            result pass A9 "a file written by ${pods[0]} is readable from ${pods[1]}"
        else
            result fail A9 "media is not shared between pods — this is the ADR-003 problem, and failing here honestly is a legitimate outcome"
        fi
    fi
fi

# --- A11: the Varnish chain is intact ------------------------------------
if want A11; then
    url="/?smoke=$(date +%s)"
    fetch "$url" >/dev/null                       # prime
    h="$(fetch_headers "$url")"
    xcache="$(printf '%s' "$h" | grep -i '^x-cache:' | tr -d '\r' | awk '{print $2}')"
    if [[ "$xcache" == "HIT" ]]; then
        result pass A11 "second request reports X-Cache: HIT — Varnish is in the chain and caching"
    elif [[ -n "$xcache" ]]; then
        result fail A11 "Varnish answered but the second request was ${xcache}, not HIT"
    else
        result fail A11 "no X-Cache header — the ingress is not going through Varnish"
    fi
fi

# --- A6: no secret in git ------------------------------------------------
if want A6; then
    if "${HERE}/scan-secrets.sh" >/dev/null 2>&1; then
        result pass A6 "nothing credential-shaped is committable (see \`make scan\` for detail)"
    else
        result fail A6 "scan-secrets.sh found something — run \`make scan\`"
    fi
fi

echo
printf '  %d passed, %d failed, %d skipped\n\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
