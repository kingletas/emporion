#!/usr/bin/env bash
#
# verify-consumers.sh — check that the declared consumer list and the workloads
# that actually consume queues describe the same set, in BOTH runtimes.
#
# This exists because that mismatch is silent in every direction:
#
#   named in env.php, no worker    nothing consumes the queue, no error
#   worker, not named in env.php   the consumer starts and Magento's own
#                                  tooling reports the queue as unhandled
#
# None of it shows up in `kubectl get pods`, in `docker compose ps`, in a log,
# or in a failing probe. No runtime has an opinion about it, so the check has
# to be written down.
#
# THREE sets are compared, not two, because there are now two runtimes:
#
#   declared   MAGENTO_CONSUMERS, from the generated ConfigMap
#   deployed   Deployments carrying a vanilla.dev/consumer label
#   composed   Compose services running `queue:consumers:start`
#
# A queue missing from any one of them is a report, not a warning.
#
# Usage:  scripts/verify-consumers.sh [-o OVERLAY] [-h]
#
#   -o   overlay to render   (default: $OVERLAY, then dev)
#   -h   this header
#
# It reads the rendered overlay and the rendered Compose config rather than
# either running system, so it can run before anything is applied — which is
# when a mismatch is cheapest to fix.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

while getopts ":o:h" opt; do
    case "$opt" in
        o) OVERLAY="$OPTARG" ;;
        h) print_header "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown flag -${OPTARG}; try -h" ;;
    esac
done

need kubectl
need docker
DIR="${K8S_REPO_ROOT}/k8s/overlays/${OVERLAY}"
[[ -d "$DIR" ]] || die "no overlay at ${DIR}"

# Parsed with a real YAML parser rather than with grep and sed. The first
# version of this used both, and it silently reported "no consumer Deployments
# found" because kustomize renders a quoted label value unquoted and because
# the underscore in product_action_attribute.update fell outside a hand-written
# character class. A check that fails open is worse than no check; a check that
# fails closed for the wrong reason is worse still, because it gets disabled.
report="$(
    kubectl kustomize "$DIR" > "${TMPDIR:-/tmp}/vc-k8s.$$.yaml" \
        && dc --profile install config > "${TMPDIR:-/tmp}/vc-compose.$$.yaml" \
        && python3 - "${TMPDIR:-/tmp}/vc-k8s.$$.yaml" "${TMPDIR:-/tmp}/vc-compose.$$.yaml" <<'PYEOF'
import sys, yaml

k8s_file, compose_file = sys.argv[1], sys.argv[2]

declared, deployed, composed = set(), set(), set()

with open(k8s_file) as fh:
    for d in yaml.safe_load_all(fh):
        if not d:
            continue
        if d.get("kind") == "ConfigMap" and d["metadata"]["name"].startswith("vanilla-env"):
            declared |= set((d.get("data") or {}).get("MAGENTO_CONSUMERS", "").split())
        if d.get("kind") == "Deployment":
            q = (d["metadata"].get("labels") or {}).get("vanilla.dev/consumer")
            if q:
                deployed.add(q)

# The queue name is the argument after `queue:consumers:start`. Read positionally
# rather than from the service name: the service name is a label a human chose
# and the argument is what the container actually runs.
with open(compose_file) as fh:
    compose = yaml.safe_load(fh) or {}
for svc in (compose.get("services") or {}).values():
    cmd = svc.get("command") or []
    if isinstance(cmd, str):
        cmd = cmd.split()
    if "queue:consumers:start" in cmd:
        i = cmd.index("queue:consumers:start")
        if i + 1 < len(cmd):
            composed.add(cmd[i + 1])

for label, s in (("DECLARED", declared), ("DEPLOYED", deployed), ("COMPOSED", composed)):
    print(label + " " + " ".join(sorted(s)))
PYEOF
)" || die "could not parse the rendered manifests"
rm -f "${TMPDIR:-/tmp}/vc-k8s.$$.yaml" "${TMPDIR:-/tmp}/vc-compose.$$.yaml"

field() { printf '%s\n' "$report" | sed -n "s/^$1 //p" | tr ' ' '\n' | grep -v '^$' | sort -u; }

declared="$(field DECLARED)"
deployed="$(field DEPLOYED)"
composed="$(field COMPOSED)"

[[ -n "$declared" ]] || die "MAGENTO_CONSUMERS is empty or missing from ConfigMap/vanilla-env"
[[ -n "$deployed" ]] || die "no Deployment carries a vanilla.dev/consumer label"
[[ -n "$composed" ]] || die "no Compose service runs queue:consumers:start"

fail=0
complain() {
    local heading="$1" list="$2"
    [[ -n "$list" ]] || return 0
    printf '%s\n' "$heading" >&2
    printf '  %s\n' $list >&2
    fail=1
}

complain "Named in MAGENTO_CONSUMERS but no cluster Deployment consumes them:" \
    "$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$deployed"))"
complain "Named in MAGENTO_CONSUMERS but no Compose service consumes them:" \
    "$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$composed"))"
complain "Have a cluster Deployment but are absent from MAGENTO_CONSUMERS:" \
    "$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$deployed"))"
complain "Have a Compose service but are absent from MAGENTO_CONSUMERS:" \
    "$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$composed"))"

[[ $fail -eq 0 ]] || die "the consumer declaration and the consumer workloads disagree"
log "Consumers agree across both runtimes: $(printf '%s\n' "$declared" | wc -l | tr -d ' ') queue(s)"
