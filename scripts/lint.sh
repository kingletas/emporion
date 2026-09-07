#!/usr/bin/env bash
#
# lint.sh — the cheap gate. Everything that can be checked without running the
# application, and nothing that pretends to check more than that.
#
# Usage:  scripts/lint.sh [-h]
#
# It renders both cluster overlays, validates both Compose files for EVERY
# site rather than for one, checks that each site's config is complete and its
# namespaces are unique, and shellchecks every script including the ones baked
# into the image.
#
# IT PROVES NOTHING ABOUT AN ASSEMBLED APPLICATION. Valid YAML, a parseable
# Compose file and a clean shellcheck are all true of a store that returns 500
# on every request. `make smoke` is the one that asks the running thing.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

[[ "${1:-}" == "-h" ]] && { print_header "${BASH_SOURCE[0]}"; exit 0; }

fail=0
step() { printf '  %-28s ' "$1"; }
ok()   { printf 'ok\n'; }
bad()  { printf 'FAIL\n'; fail=1; }

for o in dev prod-shaped; do
    step "kustomize $o"
    kubectl kustomize "${K8S_REPO_ROOT}/k8s/overlays/${o}" > /dev/null && ok || bad
done

# The Compose files read env fragments that only secrets.sh writes, so a fresh
# clone fails here on a missing FILE rather than on anything being wrong. Say
# which command produces it instead of letting Compose report the symptom.
if [[ ! -d "${K8S_REPO_ROOT}/secrets" ]]; then
    die "no secrets/ yet — the Compose files read fragments it writes. Run: make secrets"
fi

# Every site, not just the default one. A compose file that interpolates its
# paths is only as valid as the values it is given, so validating it once for
# one site says nothing about the next.
while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    step "compose ${host}"
    (
        resolve_site "$host"
        dc --profile install config > /dev/null && dc_data config > /dev/null
    ) && ok || bad
done < <(site_list)

# THE CHECK NOTHING ELSE MAKES. Two sites sharing a database name, a cache
# prefix, a search prefix, a queue vhost or a Valkey database do not fail --
# they interleave, and the symptom looks like corruption rather than config.
step "site namespaces unique"
if python3 - "$CONFIG_ENV_DIR" <<'PY'
import re, sys, pathlib, collections
keys = ["DB_NAME", "MAGENTO_CACHE_PREFIX", "OPENSEARCH_INDEX_PREFIX",
        "RABBITMQ_VIRTUALHOST", "REDIS_CACHE_DB", "REDIS_PAGE_CACHE_DB",
        "REDIS_SESSION_DB", "MAGENTO_BASE_URL"]
# Magento validates every cache id against this set and throws from
# bin/magento's constructor on anything else, so a hyphen in the prefix breaks
# every CLI command with a trace that names the id rather than the setting.
# Cheap to check here, expensive to meet at install time.
CACHE_ID = re.compile(r"^[a-zA-Z0-9_{}]+$")
seen = collections.defaultdict(dict)
missing, clash = [], []
for f in sorted(pathlib.Path(sys.argv[1], "sites").glob("*.env")):
    vals = dict(l.split("=", 1) for l in f.read_text().splitlines()
                if "=" in l and not l.startswith("#"))
    for k in keys:
        if k not in vals or vals[k] == "":
            missing.append(f"{f.name}: {k}")
            continue
        if k == "MAGENTO_CACHE_PREFIX" and not CACHE_ID.match(vals[k]):
            clash.append(f"{f.name}: MAGENTO_CACHE_PREFIX={vals[k]} has a "
                         f"character Magento rejects ([a-zA-Z0-9_{{}}] only)")
        other = seen[k].get(vals[k])
        if other:
            clash.append(f"{k}={vals[k]} in both {other} and {f.name}")
        seen[k][vals[k]] = f.name
if missing or clash:
    print()
    for m in missing: print(f"    missing  {m}")
    for c in clash:   print(f"    CLASH    {c}")
    sys.exit(1)
PY
then ok; else bad; fi

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "${K8S_REPO_ROOT}"/scripts/*.sh \
        "${K8S_REPO_ROOT}"/build/rootfs/usr/local/bin/* && ok || bad
else
    printf 'skipped (not installed)\n'
fi

exit "$fail"
