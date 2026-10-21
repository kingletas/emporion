#!/usr/bin/env bash
#
# make-consumers.sh: write everything that names a queue consumer from the
# one list, k8s/base/config/consumers.list.
#
# A consumer used to be written by hand in four places that had to agree: the
# list in common.env, a Deployment, a Compose service and its entry in the dev
# Compose file. Now it is one line in the list, and this script writes the
# four. What it writes is committed, so a clone runs without it and a change to
# a consumer shows up in review as the lines it changes.
#
# Usage:  scripts/make-consumers.sh [--check] [-r ROOT] [-h]
#
#   --check   write nothing; exit 1, naming each file, if any of the four is
#             not what the list makes. `make verify-consumers` and `make check`
#             run this, so a hand edit to a made file does not survive.
#   -r ROOT   the repository to read and write (default: this one). The test
#             uses it to work on a copy.
#   -h        this header
#
# In docker-compose.yaml and docker-compose.dev.yaml only the lines between the
# two `consumers` markers are written; in common.env only the MAGENTO_CONSUMERS
# line. k8s/base/jobs/consumers.yaml is written whole.
#
# It needs python3 and nothing outside its standard library.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
CHECK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        -r) shift; ROOT="${1:?-r needs a folder}" ;;
        -h) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "make-consumers: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || { echo "make-consumers: python3 is needed" >&2; exit 1; }

python3 - "$ROOT" "$CHECK" <<'PYEOF'
import re
import sys

root, check = sys.argv[1], sys.argv[2] == "1"

LIST = "k8s/base/config/consumers.list"
DEPLOYMENTS = "k8s/base/jobs/consumers.yaml"
COMPOSE = "docker-compose.yaml"
COMPOSE_DEV = "docker-compose.dev.yaml"
ENV = "k8s/base/config/env/common.env"

BEGIN = "  # >>> consumers: made from k8s/base/config/consumers.list by `make consumers`. Edit the list, not these lines."
END = "  # <<< consumers"

HEADER = """# Queue consumers, one Deployment each.
#
# MADE FROM k8s/base/config/consumers.list BY `make consumers`. Do not edit this
# file: add or change a line in the list and run the command, and `make check`
# refuses this file when the two disagree.
#
# Like the CronJobs, these have no Compose service to translate. Under Compose
# a consumer is started by hand with `bin/magento queue:consumers:start`, or
# by cron_consumers_runner in env.php, and the env.php block is commented out
# in this environment, so in practice nothing consumes anything until someone
# notices. That is the silent failure: a consumer that is not named never
# runs, and nothing reports it.
#
# Making each one a Deployment is the change that fixes it. A consumer that
# exits is restarted, and a consumer that was never declared is a missing
# Deployment, which is visible in `kubectl get deploy`. The list in the
# ConfigMap, these Deployments and the Compose services are all made from the
# one list, so they cannot be written to disagree; `make verify-consumers`
# still compares what the two runtimes would actually run.
#
# --max-messages is set on every one. A long-lived PHP process consuming an
# unbounded number of messages accumulates memory until the container limit
# kills it, and a restart at a message boundary is free where an OOMKill
# mid-message is not.
#
# THE LIST IS CORE MAGENTO ONLY, ON PURPOSE, as this repository ships it. A
# store that needs a consumer of its own adds a line to the list in its copy
# of the repository; docs/configuration.md shows one."""

DEPLOYMENT = """apiVersion: apps/v1
kind: Deployment
metadata:
  name: @NAME@
  labels:
    app.kubernetes.io/name: @NAME@
    vanilla.dev/tier: consumer
    vanilla.dev/consumer: "@QUEUE@"
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: @NAME@
  template:
    metadata:
      labels:
        app.kubernetes.io/name: @NAME@
        vanilla.dev/tier: consumer
    spec:
      # A consumer mid-message should be allowed to finish it. Magento's
      # consumer catches SIGTERM and stops at the next message boundary.
      terminationGracePeriodSeconds: 60
      securityContext:
        fsGroup: 1001
      containers:
        - name: consumer
          image: magento-app:local
          imagePullPolicy: IfNotPresent
          args:
            - "php"
            - "bin/magento"
            - "queue:consumers:start"
            - "@QUEUE@"
            - "--max-messages=@MAX@"
          envFrom:
            - configMapRef:
                name: vanilla-env
            - secretRef:
                name: vanilla-app
          volumeMounts:
            - name: var
              mountPath: /app/var
            - name: env-php
              mountPath: /etc/magento
            - name: media
              mountPath: /app/pub/media
          # There is no probe endpoint for a queue consumer, and inventing an
          # HTTP one would be a fiction. What can be checked honestly is that
          # the PHP process for this specific queue is alive. A consumer that
          # has died leaving the container running is the failure mode that
          # matters, and a bare restartPolicy would not catch it.
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - "pgrep -f 'queue:consumers:start @QUEUE@' > /dev/null"
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: @REQUEST@
            limits:
              memory: @LIMIT@
      volumes:
        - name: var
          emptyDir: {}
        - name: env-php
          emptyDir: {}
        - name: media
          persistentVolumeClaim:
            claimName: magento-media"""


def fail(message):
    sys.exit(f"make-consumers: {message}")


def read(path):
    with open(f"{root}/{path}", encoding="utf-8") as handle:
        return handle.read()


def consumers():
    """The list's lines as dictionaries, refused by line number when one cannot be read."""
    found, queues, names, services = [], set(), set(), set()
    for number, line in enumerate(read(LIST).splitlines(), 1):
        entry, _, why = line.partition("#")
        words = entry.split()
        if not words:
            continue
        where = f"{LIST}:{number}"
        queue, settings = words[0], {"max": "100", "memory": "192Mi/384Mi"}
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9._]*", queue):
            fail(f"{where}: '{queue}' is not a queue name")
        for word in words[1:]:
            key, equals, value = word.partition("=")
            if key not in ("max", "memory", "name", "compose") or not equals or not value:
                fail(f"{where}: '{word}' is not a setting; a line takes max=, memory=, name= and compose=")
            settings[key] = value
        if not re.fullmatch(r"[1-9][0-9]*", settings["max"]):
            fail(f"{where}: max={settings['max']} is not a count of messages")
        memory = re.fullmatch(r"([1-9][0-9]*[MG]i)/([1-9][0-9]*[MG]i)", settings["memory"])
        if not memory:
            fail(f"{where}: memory={settings['memory']} is not REQUEST/LIMIT, as in 192Mi/384Mi")
        name = settings.get("name", "consumer-" + re.sub(r"[._]", "-", queue).lower())
        service = settings.get("compose", name)
        for made in (name, service):
            if not re.fullmatch(r"consumer-[a-z0-9]+(-[a-z0-9]+)*", made):
                fail(f"{where}: '{made}' has to start with consumer- and hold only lower-case letters, digits and hyphens")
        if queue in queues or name in names or service in services:
            fail(f"{where}: {queue} is listed twice, or its name is already another consumer's")
        queues.add(queue)
        names.add(name)
        services.add(service)
        found.append({"queue": queue, "max": settings["max"], "request": memory.group(1),
                      "limit": memory.group(2), "name": name, "service": service, "why": why.strip()})
    if not found:
        fail(f"{LIST} names no consumer")
    return found


def deployments(listed):
    parts = [HEADER]
    for one in listed:
        body = (DEPLOYMENT.replace("@NAME@", one["name"]).replace("@QUEUE@", one["queue"])
                .replace("@MAX@", one["max"]).replace("@REQUEST@", one["request"]).replace("@LIMIT@", one["limit"]))
        parts.append((f"# {one['why']}\n" if one["why"] else "") + body)
    return "\n---\n".join(parts) + "\n"


def between_markers(path, lines):
    """The file with the lines between its two consumers markers replaced."""
    text = read(path)
    if text.count(BEGIN + "\n") != 1 or text.count(END + "\n") != 1:
        fail(f"{path} has to hold the two consumers markers once each, and does not")
    before, rest = text.split(BEGIN + "\n")
    _, after = rest.split(END + "\n")
    return before + BEGIN + "\n" + "".join(line + "\n" for line in lines) + END + "\n" + after


def compose(listed):
    lines = []
    for one in listed:
        command = ", ".join(f'"{word}"' for word in ("php", "bin/magento", "queue:consumers:start", one["queue"],
                                                     f"--max-messages={one['max']}"))
        lines += [f"  {one['service']}:", "    <<: *consumer", f"    command: [{command}]", ""]
    return between_markers(COMPOSE, lines[:-1])


def compose_dev(listed):
    lines = []
    for one in listed:
        lines += [f"  {one['service']}:", "    <<: *dev-app"]
    return between_markers(COMPOSE_DEV, lines)


def env(listed):
    text = read(ENV)
    if len(re.findall(r"(?m)^MAGENTO_CONSUMERS=.*$", text)) != 1:
        fail(f"{ENV} has to hold one MAGENTO_CONSUMERS line, and does not")
    return re.sub(r"(?m)^MAGENTO_CONSUMERS=.*$", "MAGENTO_CONSUMERS=" + " ".join(one["queue"] for one in listed), text)


listed = consumers()
made = {DEPLOYMENTS: deployments(listed), COMPOSE: compose(listed), COMPOSE_DEV: compose_dev(listed), ENV: env(listed)}
stale = [path for path, text in made.items() if read(path) != text]

if check:
    if stale:
        for path in stale:
            print(f"    {path} is not what {LIST} makes", file=sys.stderr)
        fail("a consumer was changed by hand outside the list. Put the change in the list and run: make consumers")
    print(f"{len(listed)} consumer(s), and the four files made from the list match it")
else:
    for path in stale:
        with open(f"{root}/{path}", "w", encoding="utf-8") as handle:
            handle.write(made[path])
    print(f"{len(listed)} consumer(s); " + (f"wrote {', '.join(stale)}" if stale else "nothing to write, the four files already match the list"))
PYEOF
