#!/usr/bin/env bash
#
# test-mariadb-guard.sh — prove the MariaDB major-upgrade guard's decisions
# without Docker.
#
# Usage:  scripts/test-mariadb-guard.sh [-h]
#
# It runs the pure functions in lib.sh against version strings, and the shell
# the guard runs inside its short-lived container against directories made
# here, standing in for a volume. What it cannot prove is that a real MariaDB
# volume carries mariadb_upgrade_info where and as the guard expects; only
# reading one does that.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }

failures=0
check() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" != "$want" ]]; then
        printf '    FAIL  %s: wanted %q, got %q\n' "$name" "$want" "$got"
        failures=$((failures + 1))
    fi
}

# Whether a start goes ahead, as a word, for readable expectations.
decision() {
    if mariadb_upgrade_allowed "$1" "$2" "${3:-}"; then echo start; else echo refuse; fi
}

# --- decisions ------------------------------------------------------------
check "an older line is refused"             refuse "$(decision 11.4.13-MariaDB 12.3)"
check "an older line is an upgrade"          upgrade "$(mariadb_upgrade_verdict 11.4.13-MariaDB 12.3)"
check "the flag lets an upgrade through"     start  "$(decision 11.4.13-MariaDB 12.3 1)"
check "the same line starts"                 start  "$(decision 12.3.2-MariaDB 12.3)"
check "a newer patch tag is the same line"   same   "$(mariadb_upgrade_verdict 12.3.2-MariaDB 12.3.3)"
check "a tag with a suffix is read"          same   "$(mariadb_upgrade_verdict 11.4.13-MariaDB 11.4-noble)"
check "a new or empty volume starts"         start  "$(decision "" 12.3)"
check "a database with no info is refused"   refuse "$(decision "?" 12.3)"
check "the flag lets that through"           start  "$(decision "?" 12.3 1)"
check "a newer volume is a downgrade"        downgrade "$(mariadb_upgrade_verdict 12.3.1-MariaDB 11.4)"
check "a downgrade is refused with the flag" refuse "$(decision 12.3.1-MariaDB 11.4 1)"
check "an unreadable tag is unknown"         unknown "$(mariadb_upgrade_verdict 11.4.13-MariaDB latest)"
check "a minor line compares as a number"    upgrade "$(mariadb_upgrade_verdict 10.11.9-MariaDB 11.4)"
check "and within one major"                 upgrade "$(mariadb_upgrade_verdict 11.4.2-MariaDB 11.10)"

# --- the reader, against directories standing in for a volume ------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/empty" "$tmp/noinfo/mysql" "$tmp/recorded/mysql"
printf '11.4.13-MariaDB' > "$tmp/recorded/mariadb_upgrade_info"
check "an empty volume records nothing"      ""   "$(sh -c "$MARIADB_RECORDED_SH" sh "$tmp/empty")"
check "a database with no info records ?"    "?"  "$(sh -c "$MARIADB_RECORDED_SH" sh "$tmp/noinfo")"
check "a recorded version is read"           11.4.13-MariaDB "$(sh -c "$MARIADB_RECORDED_SH" sh "$tmp/recorded")"

# --- the refusal names both versions and the image that wrote the volume ---
msg="$( (mariadb_refusal upgrade magento-data_db-data 11.4.13-MariaDB mariadb:12.3) 2>&1 || true)"
check "the refusal names the recorded version" yes "$([[ "$msg" == *"11.4.13-MariaDB"* ]] && echo yes || echo no)"
check "the refusal names the new image"        yes "$([[ "$msg" == *"mariadb:12.3"* ]] && echo yes || echo no)"
check "the refusal names the copying image"    yes "$([[ "$msg" == *"mariadb:11.4"* ]] && echo yes || echo no)"

# --- the guard itself, with docker replaced by a stand-in ------------------
# The stand-in answers the three questions the guard asks: which image the db
# container runs, which volume holds the data, and what the volume records.
docker() {
    case "$1 $2" in
        "ps -a")     printf '%s\n' "${STUB_CURRENT:-}" ;;
        "volume ls") printf '%s\n' "${STUB_VOLUME:-}" ;;
        "run --rm")  [[ -z "${STUB_RUN_FAILS:-}" ]] || return 1
                     printf '%s\n' "${STUB_RECORDED:-}" ;;
    esac
}
guard() { ( guard_mariadb_upgrade ) >/dev/null 2>&1 && echo start || echo refuse; }
target="mariadb:$(sed -n 's/^MARIADB_VERSION=//p' "$LINE_FILE")"

check "the guard skips a container already on the image" start \
    "$(STUB_CURRENT="$target" STUB_RECORDED=11.4.13-MariaDB STUB_VOLUME=v guard)"
check "the guard starts when there is no volume"         start "$(STUB_CURRENT=mariadb:11.4 guard)"
check "the guard refuses an older volume"                refuse \
    "$(STUB_CURRENT=mariadb:11.4 STUB_VOLUME=v STUB_RECORDED=11.4.13-MariaDB guard)"
check "the guard starts an older volume with the flag"   start \
    "$(ALLOW_MAJOR_UPGRADE=1 STUB_CURRENT=mariadb:11.4 STUB_VOLUME=v STUB_RECORDED=11.4.13-MariaDB guard)"
check "the guard starts a new volume"                    start "$(STUB_VOLUME=v STUB_RECORDED='' guard)"
check "the guard refuses when it cannot read the volume" refuse \
    "$(ALLOW_MAJOR_UPGRADE=1 STUB_VOLUME=v STUB_RUN_FAILS=1 guard)"
unset -f docker

if (( failures )); then
    exit 1
fi
