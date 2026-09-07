#!/usr/bin/env bash
#
# check-no-private-info.sh — fail if anything in this repository names the
# machine it was written on.
#
# Usage:  scripts/check-no-private-info.sh [-h]
#
# A sweep of the tree is necessary and not sufficient, but it is the half that
# can be automated. What it looks for:
#
#   1. an absolute home path -- /home/<anyone> or /Users/<anyone>
#   2. the login and hostname of whoever is running it
#   3. a path into a personal source tree
#
# THE LOGIN AND HOSTNAME ARE READ AT RUN TIME, NEVER WRITTEN DOWN. A check that
# hardcoded them would publish the two strings it exists to keep out, and it
# would only ever protect the person who wrote it. Reading them means this
# works for the next contributor, whose name nobody here knows.
#
# It excludes its own source, because a scanner that scans its own patterns
# reports them as findings.
#
# Machine-specific values belong in an environment variable with a default --
# MAGENTO_SRC, CERTS_HOME, SNAPSHOT_DIR -- rather than in a literal.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }

cd "$K8S_REPO_ROOT"
fails=0

# Every text file git tracks, plus anything staged. A file git cannot see
# cannot be published, and secrets/ and certs/ are ignored by construction.
mapfile -t FILES < <(git ls-files --cached --others --exclude-standard \
    | grep -vE '^scripts/check-no-private-info\.sh$' || true)

# A LOGIN THAT IS AN ORDINARY WORD CANNOT BE SEARCHED FOR. On a GitHub runner
# the account is called `runner`, which appears all over this repository as
# English -- "a GitHub runner", "an in-process runner". Searching for it fails
# the gate on a tree that is perfectly clean.
#
# So a name from this list is skipped, and the skip is PRINTED. A check that
# quietly decides nothing is worse than one that fails, because nobody can tell
# it apart from a check that passed.
GENERIC="runner root user users admin build builder ci docker ubuntu debian test guest app node"

is_generic() {
    local name="$1" g
    [[ ${#name} -lt 4 ]] && return 0
    for g in $GENERIC; do [[ "$name" == "$g" ]] && return 0; done
    return 1
}

scan() {
    local label="$1" pattern="$2" hits
    hits="$(grep -InE "$pattern" "${FILES[@]}" 2>/dev/null || true)"
    if [[ -z "$hits" ]]; then
        echo "   ok — ${label}"
    else
        echo "   FAIL: ${label}"
        printf '%s\n' "$hits" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}

log "Nothing in the tree may name this machine"

scan "no absolute home path"        '/(home|Users)/[a-zA-Z0-9._-]+'

check_identity() {
    local what="$1" who="$2"
    if is_generic "$who"; then
        echo "   skip — the ${what} here is '${who}', too generic to search for"
    else
        scan "not this ${what}" "\\b${who}\\b"
    fi
}

check_identity "account's login"   "$(id -un)"
check_identity "machine's hostname" "$(hostname)"
# The tilde is a literal in a regex, not an expansion, so SC2088 is wrong here.
# shellcheck disable=SC2088
scan "no personal source tree"      '~/(Development|Projects|src|code)/'

if [[ $fails -eq 0 ]]; then
    log "Clean: nothing here names the machine it was written on."
else
    die "${fails} check(s) failed"
fi
