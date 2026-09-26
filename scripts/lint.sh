#!/usr/bin/env bash
#
# lint.sh — the cheap gate. Everything that can be checked without running the
# application, and nothing that pretends to check more than that.
#
# Usage:  scripts/lint.sh [-h]
#
# It renders both cluster overlays, validates both Compose files for EVERY
# site rather than for one, checks that each site's config is complete and its
# namespaces are unique, checks every Magento line's versions agree wherever
# they are repeated, tests the MariaDB upgrade guard's logic, and shellchecks
# every script including the ones baked into the image.
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

# EVERY MAGENTO LINE'S VERSIONS, EVERYWHERE THEY ARE REPEATED. versions/ holds
# one list per line; the Compose fallbacks, the Dockerfile's ARG defaults and
# the kustomize image tags repeat it because neither kustomize nor Docker can
# read an env file into an image tag. Rendering both overlays on each line
# checks the tags that actually deploy, not the text that sets them. A store's
# own VARNISH_VERSION is outside this check: it lives in a site file, and only
# deploy.sh's generated overlay applies it.
step "magento lines agree"
lines_tmp="$(mktemp -d)"
trap 'rm -rf "$lines_tmp"' EXIT
lines_rendered=1
for o in dev prod-shaped; do
    kubectl kustomize "${K8S_REPO_ROOT}/k8s/overlays/${o}" > "${lines_tmp}/${DEFAULT_LINE}__${o}.yaml" \
        || lines_rendered=0
done
for comp in "${K8S_REPO_ROOT}"/k8s/components/magento-*/; do
    [[ -d "$comp" ]] || continue
    line="$(basename "$comp")"
    line="${line#magento-}"
    for o in dev prod-shaped; do
        # A sibling of the overlays, because kustomize will not take an
        # absolute path in `resources:`; the name matches the gitignored
        # pattern deploy.sh uses for its own dry runs.
        gen="$(mktemp -d "${K8S_REPO_ROOT}/k8s/overlays/.site-XXXXXX")"
        printf '%s\n' \
            'apiVersion: kustomize.config.k8s.io/v1beta1' \
            'kind: Kustomization' \
            'resources:' \
            "  - ../${o}" \
            'components:' \
            "  - ../../components/magento-${line}" > "${gen}/kustomization.yaml"
        kubectl kustomize "$gen" > "${lines_tmp}/${line}__${o}.yaml" || lines_rendered=0
        rm -rf "$gen"
    done
done
if [[ $lines_rendered -eq 1 ]] && python3 - "$K8S_REPO_ROOT" "$lines_tmp" "$DEFAULT_LINE" <<'PY'
import re, sys, pathlib
root, rendered, default = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
# The image each version key tags. PHP and Composer are build arguments only.
IMAGES = {"mariadb": "MARIADB_VERSION", "valkey/valkey": "VALKEY_VERSION",
          "nginx": "NGINX_VERSION", "varnish": "VARNISH_VERSION",
          "opensearchproject/opensearch": "OPENSEARCH_VERSION",
          "rabbitmq": "RABBITMQ_VERSION", "mailhog/mailhog": "MAILHOG_VERSION"}
BUILD = {"PHP_VERSION", "COMPOSER_VERSION"}
KEYS = set(IMAGES.values()) | BUILD

def read_env(path):
    return dict(l.split("=", 1) for l in path.read_text().splitlines()
                if "=" in l and not l.startswith("#"))

lines = {p.name[len("magento-"):-len(".env")]: read_env(p)
         for p in sorted((root / "versions").glob("magento-*.env"))}
bad = []
for line, v in lines.items():
    for k in sorted(KEYS - v.keys()):
        bad.append(f"versions/magento-{line}.env does not set {k}")
    for k in sorted(v.keys() - KEYS):
        bad.append(f"versions/magento-{line}.env sets {k}, which nothing reads")
if default not in lines:
    bad.append(f"common.env names MAGENTO_LINE={default}, and there is no versions/magento-{default}.env")
want = lines.get(default, {})

for f in ("docker-compose.yaml", "docker-compose.data.yaml"):
    text = (root / f).read_text()
    for k, val in re.findall(r"\$\{([A-Z_]+):-([^}]*)\}", text):
        if k in KEYS and want.get(k) != val:
            bad.append(f"{f}: ${{{k}:-{val}}}, but the {default} line says {want.get(k)}")
for k in sorted(set(IMAGES.values()) | BUILD):
    if not any(f"${{{k}:-" in (root / f).read_text()
               for f in ("docker-compose.yaml", "docker-compose.data.yaml")):
        bad.append(f"no Compose file reads {k}")

for k, val in re.findall(r"^ARG (PHP_VERSION|COMPOSER_VERSION)=(.*)$",
                         (root / "build" / "Dockerfile").read_text(), re.M):
    if want.get(k) != val:
        bad.append(f"build/Dockerfile: ARG {k}={val}, but the {default} line says {want.get(k)}")

for r in sorted(rendered.glob("*.yaml")):
    line, overlay = r.stem.split("__")
    if line not in lines:
        bad.append(f"k8s/components/magento-{line} has no versions/magento-{line}.env")
        continue
    seen = set()
    for image in re.findall(r"image:\s*(\S+)", r.read_text()):
        name, _, tag = image.rpartition(":")
        if name not in IMAGES:
            continue
        seen.add(name)
        if tag != lines[line][IMAGES[name]]:
            bad.append(f"the {overlay} overlay on the {line} line runs {image}, but the versions file says {lines[line][IMAGES[name]]}")
    for name in sorted(set(IMAGES) - seen):
        bad.append(f"the {overlay} overlay on the {line} line runs no {name} image")
for line in sorted(lines):
    if not (rendered / f"{line}__prod-shaped.yaml").exists():
        bad.append(f"the {line} line has no cluster component at k8s/components/magento-{line}")

if bad:
    print()
    for b in sorted(set(bad)):
        print(f"    DRIFT    {b}")
    sys.exit(1)
PY
then ok; else bad; fi

# The MariaDB upgrade guard's decisions and its volume reader, without Docker.
step "mariadb upgrade guard"
"${HERE}/test-mariadb-guard.sh" && ok || bad

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "${K8S_REPO_ROOT}"/scripts/*.sh \
        "${K8S_REPO_ROOT}"/build/rootfs/usr/local/bin/* && ok || bad
else
    printf 'skipped (not installed)\n'
fi

exit "$fail"
