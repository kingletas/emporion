# Running it

The commands, the checks that decide whether it works, and where to look when it doesn't.

## Contents

- [Commands](#commands)
- [Checking it](#checking-it)
- [Setting resources from measurement](#setting-resources-from-measurement)
- [Debugging](#debugging)

---

## Commands

`make` with no arguments lists everything.

Every Compose command takes `SITE=<hostname>` and defaults to `vanilla.test`.

```bash
make compose-up            # start one site
make compose-install       # install its store, or upgrade it
make compose-cli ARGS="cache:flush"
make compose-logs
make compose-down          # stop it, keeping the database and media
make compose-destroy       # stop AND delete its volumes (prompts)
```

```bash
make new-site SITE=second.test   # a whole new store, seeded
make sites                      # what exists, and which one is working
make use SITE=second.test        # give it the consumers and cron
make park SITE=second.test       # take them away again
make destroy-site SITE=second.test
make data-up / data-down        # the shared tier, on its own
```

```bash
make up                    # cluster, image, deploy, install, wait
make down                  # destroy the cluster, PVCs included
make deploy                # redeploy after a change
make logs
make shell
make cli ARGS="cache:flush"
```

`make cli` and `make compose-cli` both run in `php-cron`, not `php-fpm` — a reindex inside a container that's also serving storefront traffic competes with it for the same memory limit, and the background pool exists so that work has somewhere else to go.

---


## Checking it

```bash
make lint
```

Renders both overlays, validates **both Compose files for every site**, checks that no two sites share a namespace and that each one's cache prefix is a string Magento will accept, and shellchecks every script including the ones baked into the image. It's the cheap gate, and it proves nothing about an assembled application.

```bash
make verify-namespaces
```

**The runtime counterpart, and the one that catches a stale image.** It reads the `env.php` each running store actually loaded and compares its database, cache prefix, search index prefix, queue vhost, base URL and Valkey database numbers against that site's config.

> [!warning] A correct config decides nothing until the image is rebuilt
> `magento-entrypoint` writes `env.php` and **lives inside the image**. So the config file can be right, `docker compose config` can be right, `env` inside the container can be right, and the store can still be using another store's search index.
>
> That's not hypothetical — it's why this check exists. Both new namespaces were parameterised, both site files were correct, the container's environment showed the right values, and `env.php` still said `magento2` and `/` because the image predated the change. **`make lint` cannot see this and neither can Compose.** Only reading the file the application loaded can.

```bash
make smoke
```

Walks the acceptance criteria against the cluster and reports each one pass, fail or skip. It doesn't stop at the first failure: a report of everything that's wrong is worth more than the first thing that's wrong. **On Compose it stops straight away and names the Compose checks instead**, because every check it makes goes through the cluster.

**It runs eight of them: A2 to A6, A8, A9 and A11.** A1, A7 and A10 each have a command of their own, named in the table. A12 is this documentation, and A13 is `make verify-namespaces`, above, because it asks about *every* store on the machine rather than about the one the smoke is pointed at.

| | Criterion | How it's checked |
|---|---|---|
| A1 | Builds from nothing | `make rebuild` — the script cannot check the thing it runs inside |
| A2 | Storefront renders | HTTP 200 through the ingress |
| A3 | Admin login works | Admin reachable **and** `env.php` puts sessions in Valkey — the half that matters |
| A4 | Data survives pod replacement | Writes a key, deletes the pod, reads it back |
| A5 | No startup ordering | No init container that merely waits; readiness probes present |
| A6 | No secret in git | `make scan` |
| A7 | Image is reproducible | `make verify-image` — **and it says what it cannot check** |
| A8 | Scheduled work runs unattended | A cron Job has fired; a consumer is running that nobody started |
| A9 | Media is shared | Write through one pod, read from another. **Skips with one replica** |
| A10 | Resources from measurement | `make top` |
| A11 | Varnish chain intact | Second request returns `X-Cache: HIT` |
| A12 | Documented | This file |
| A13 | **Each store uses its own namespaces** | `make verify-namespaces` — against the running `env.php`, not the config. **Not part of `make smoke`** |

**A7 cannot be fully met, and this repository says so rather than measuring something easier.** Two builds from one commit don't produce the same digest: the base image is a moving tag, apt pulls whatever the mirror has, and every layer carries a timestamp. `scripts/verify-image.sh` hashes the *application content* instead — same code, same vendor tree, same `generated/`, same static content — and its header states plainly which four things it isn't checking and which three of them cannot be fixed from inside this repository.

**A11 is thinner than it looks against an empty catalogue.** A cache HIT on the CMS home page proves the chain is intact; it doesn't prove anything about the catalogue path, because there's no catalogue until `make sample-data` or real products exist. Read it as what it is.

---


## Setting resources from measurement

Every workload has a request. The limits are not guesses, but they are also not yet measurements — they are conventions sized for a laptop, and that's stated rather than implied.

```bash
make top
```

prints declared requests and limits beside actual usage. Actual usage needs `metrics-server`, which is **not installed by default** — it's one more component on a memory-constrained host, and it's only worth installing when the numbers are actually being tuned:

```bash
kubectl --context kind-vanilla apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

```bash
kubectl --context kind-vanilla -n kube-system patch deployment metrics-server --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

The `--kubelet-insecure-tls` patch is required on kind, whose kubelet serving certificates are self-signed.

Requests are what the scheduler honours; limits are the ceiling. The gap between them is deliberate — **a scheduler will overcommit happily where Compose simply failed to start a container**, so low requests and honest limits are what keeps the host alive.

---


## Debugging

```bash
make status            # cluster: pods, services, claims, ingress, cronjobs
make compose-status    # compose: what is running, and is it healthy
make events            # newest last
make render            # what would be applied, without applying it
```

Reading the assembled `env.php` from inside a container is usually the fastest way to a wrong answer:

```bash
kubectl --context kind-vanilla -n vanilla exec deploy/php-fpm -- cat /etc/magento/env.php
```

```bash
docker compose -p vanilla exec php-fpm cat /etc/magento/env.php
```

Watching Varnish decide:

```bash
kubectl --context kind-vanilla -n vanilla exec deploy/varnish -- varnishlog -g request
```

Turning Xdebug on for one pod, without a rebuild — `dev` overlay only:

```bash
kubectl --context kind-vanilla -n vanilla set env deployment/php-fpm XDEBUG_MODE=debug
```

Turn it back off afterwards. Merely loading Xdebug with `mode != off` costs about 2× on every request whether or not a session is attached, and any timing taken against a pod with it on is fiction.

---
