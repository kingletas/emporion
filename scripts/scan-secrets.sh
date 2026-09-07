#!/usr/bin/env bash
#
# scan-secrets.sh — fail if anything that would be committed looks like a
# credential. This is acceptance criterion A6, made runnable.
#
# Usage:  scripts/scan-secrets.sh [-h]
#
# Checks, in order:
#   1. secrets/ is ignored by git
#   2. no tracked-or-trackable file in this repository matches a credential
#      pattern, with the known-safe exceptions listed inline below
#   3. the mkcert private keys are not inside this directory
#
# It scans the working tree, not the index, on purpose: a secret that is
# merely untracked is still one `git add -A` away from being committed, and
# `git add -A` is exactly the habit this estate's rules already ban.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }

cd "$K8S_REPO_ROOT"
fails=0

log "1. secrets/ must be ignored"
if git check-ignore -q secrets/x 2>/dev/null; then
    echo "   ok"
else
    echo "   FAIL: secrets/ is not ignored by any .gitignore in scope"
    fails=$((fails + 1))
fi

log "2. no credential-shaped strings in committed files"
# BEGIN_PASSWORD / password-looking assignments with a literal on the right.
# The exceptions are deliberate and each is a placeholder, not a value.
pattern='(password|passwd|secret|api[_-]?key|access[_-]?key|crypt[_-]?key)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9+/=_-]{8,}'
hits="$(grep -rInE "$pattern" \
        --exclude-dir=secrets --exclude-dir=.git --exclude-dir=.tmp \
        --exclude='*.md' \
        . 2>/dev/null \
    | grep -vE 'valueFrom|secretKeyRef|name: (vanilla-db|vanilla-app|vanilla-rabbit)' \
    | grep -vE 'CHANGE_ME|REDACTED|<generated>|value_for|--from-literal' \
    || true)"
if [[ -z "$hits" ]]; then
    echo "   ok"
else
    echo "   FAIL: possible credentials in committed files:"
    printf '%s\n' "$hits" | sed 's/^/     /'
    fails=$((fails + 1))
fi

log "3. no private keys anywhere git could reach"
# CERTS_HOME may be certs/ inside this repository, which is why that directory
# is gitignored and why this check reads git's own answer rather than trusting
# the path. -print on a symlink reports the link and does not descend it.
# Asked about `certs` and not `certs/x`: once CERTS_HOME is a symlink git
# refuses a path through it with "beyond a symbolic link", and a `certs/`
# pattern does not match a symlink at all.
if ! git check-ignore -q certs 2>/dev/null; then
    echo "   FAIL: certs/ is not ignored by any .gitignore in scope"
    fails=$((fails + 1))
fi
keys="$(find . -path ./secrets -prune -o -path ./certs -prune -o \
        -name '*.key' -print -o -name '*.pem' -print 2>/dev/null || true)"
if [[ -z "$keys" ]]; then
    echo "   ok (key material lives in ${CERTS_HOME} and secrets/, both ignored)"
else
    echo "   FAIL: key material inside the repository:"
    printf '%s\n' "$keys" | sed 's/^/     /'
    fails=$((fails + 1))
fi

if [[ $fails -eq 0 ]]; then
    log "A6 satisfied: nothing credential-shaped is committable from here."
else
    die "${fails} check(s) failed"
fi
