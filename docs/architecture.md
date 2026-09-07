# How it's put together

What the two runtimes share, the four problems that were genuinely hard, and where everything lives.

## Contents

- [What is shared, and why that matters](#what-is-shared-and-why-that-matters)
- [What was hard, and what was done about it](#what-was-hard-and-what-was-done-about-it)
- [Layout](#layout)
- [History](#history)

The reasoning behind each decision is in [`adr/`](adr/).

---

## What is shared, and why that matters

Four things have exactly one copy, and every one of them would otherwise be a place the two runtimes could quietly disagree:

| Shared | Where it lives | Read by |
|---|---|---|
| The application image | `build/Dockerfile`, target `runtime` | both runtimes and every site — there's no second image |
| Non-secret configuration | `k8s/base/config/env/common.env` | kustomize `configMapGenerator`, Compose `env_file` |
| **Per-site** configuration | `k8s/base/config/env/sites/<slug>.env` | the same two, layered *over* the common file |
| Credentials | generated into `secrets/<slug>/` and `secrets/<data-project>/` | k8s Secrets, and `compose-*.env` fragments beside them |
| nginx, Varnish and MariaDB config | `k8s/base/config/files/` | ConfigMaps, and bind mounts |

**The split between those first two config files is by whether two stores can share the value, not by how interesting it is.** A service address, a behaviour and a list are all things a second site has no reason to disagree with. A database name, a cache prefix, a search index prefix, a queue vhost and a Valkey database number are not.

**Both runtimes read the pair in the same order, with the site file winning** — Compose as two `env_file:` entries and kustomize as two `envs:` entries. That identity is what makes the split safe rather than a second place to drift.

**The service names are the contract that makes that possible.** Every Compose service is named after the Kubernetes Service doing the same job — `db`, `opensearch`, `rabbitmq`, `valkey-cache`, `valkey-session`, `php-fpm`, `web`, `web-admin`, `web-cron`, `varnish`. The Varnish VCL names three of them as backends, the nginx template resolves `${FASTCGI_BACKEND}` to another, and `magento-entrypoint` defaults to the rest. **Rename one service and one of those files has to fork**, which is the moment the two runtimes stop being comparable.

> [!warning] The shared env file lives under `k8s/base/` and cannot be moved
> Not tidiness. Kustomize refuses to read a file outside the kustomization root — *security; file '…' is not in or below '…/k8s/base'* — and the alternative is passing `--load-restrictor LoadRestrictionsNone` to every kustomize call in the repository, which disables that check for everything else too. Compose can read any path, so Compose is the one that reaches across.

---


## What was hard, and what was done about it

### The shared writable webroot

Magento writes to `pub/media`, `pub/static`, `var/` and `generated/`. A bind-mounted tree shares all four by accident, because they sit inside one mount. Nothing here does that — so three of the four had to stop needing to be shared:

| Path | Where it went |
|---|---|
| `generated/` | into the image at build time |
| `pub/static` | into the image at build time |
| `var/` | container-local — `emptyDir` in the cluster, an anonymous volume in Compose |
| `pub/media` | one shared claim / one named volume |

**The honest caveat, stated in the manifest as well as here: the cluster's media claim works because there is one node, and the access mode has to say so.** It asked for `ReadWriteMany` until the cluster was first run; kind's local-path provisioner doesn't inspect the geography, it inspects the access mode, and refuses — *NodePath only supports ReadWriteOnce and ReadWriteOncePod*. The claim never bound and the three workloads that mount it sat in `Pending` with no event on the pod to say why.

`ReadWriteOnce` is what expresses the truth. **RWO binds a volume to one _node_, not to one _pod_** — every pod on that node can mount it, which is the sharing this needs. A second node still breaks it outright; the difference is that the limitation is declared rather than assumed. Object storage through Magento's remote-storage module is the answer that survives, and it isn't built here. [ADR-003](adr/ADR-003-shared-media-strategy.md).

### Varnish is not an ingress controller

Deleting Varnish and letting the ingress route is the translation that looks like a simplification and is not: it removes the component the storefront's performance depends on, and turns cache invalidation from a mechanism into an absence.

Varnish stays in the chain in both runtimes. In the cluster it runs behind the ingress, which does the one thing Varnish cannot — terminate TLS; under Compose `nginx-proxy` does the same job. **One VCL serves both**, which is why its purge ACL names two CIDRs: the kind pod range and the Docker bridge range. A purge that's silently refused shows up as a storefront that never updates rather than as an error anywhere. [ADR-005](adr/ADR-005-varnish-stays-in-the-chain.md).

### `env.php`, and the consumer list nobody checks

`app/etc/env.php` is per-environment, holds credentials, and carries `cron_consumers_runner` — **and a consumer that is not named in it never runs, with no error anywhere**. It cannot be baked into the image (credentials) and cannot be omitted (consumers).

So it's assembled at container start from the shared config and the generated credentials, by `magento-entrypoint`, into `/etc/magento/env.php` — with a symlink baked into the image so `/app` can stay read-only. And because the mismatch between that list and the workloads is invisible in every direction, there's a check for it:

```bash
make verify-consumers
```

It compares **three** sets now — the declared list, the cluster Deployments, and the Compose services — and `deploy.sh` runs it before applying, because the failure is silent once it's running.

### What a second store actually cost

Four things, and none of them was the part that looked hard. Splitting the compose file was mechanical; these were not.

**`depends_on` cannot reach across Compose projects.** Moving the data tier to its own project deleted the `condition: service_healthy` every application service carried. That ordering didn't disappear — it became an explicit `dc_data up -d --wait` before any application tier starts, which is the same two-step split `compose-up.sh` and `deploy.sh` already made for their own reasons. The guarantee is unchanged and now lives somewhere a person reads rather than somewhere Compose enforces.

**The entrypoint pinned two of the five namespaces as literals.** `opensearch_index_prefix` was `'magento2'` and the queue `virtualhost` was `'/'`, hardcoded — so a second store would have shared an index and a set of queues with the first, and setting either in the ConfigMap decided nothing at all.

That's the identical defect the `MAGENTO_CACHE_PREFIX` comment already confessed to about itself two sections earlier: *"this value was defaulted here and referenced nowhere until the id_prefix entries below existed."* One instance of a bug was documented and the other two were still live beside it.

**Magento rejects a hyphen in a cache id prefix**, and it does so from `bin/magento`'s constructor. `second.test` slugs to `second-test`, so the generated prefix `second-test_` broke *every* CLI command — including the install — with a `Zend_Cache` trace naming the id and never the setting:

```text
Invalid id or tag 'second-test_MAGE_VERSION' : must use only [a-zA-Z0-9_{}]
```

Found by running it. The database name and the cache prefix now use underscores; the search prefix and the queue vhost accept hyphens and keep the slug. **`make lint` checks the pattern**, and the check was verified by breaking a site's config on purpose and watching it fail — a green gate proves nothing about the alarm.

**A `*.test` certificate covers nothing**, which is the one in this list that had been silently false for years rather than newly introduced. It has its own callout under [Getting started](getting-started.md#quick-start).

### Static content, deployed with no database

Static content is deployed at **build** time so it can live in the image, which means it is deployed with no database to read from. Magento supports that — it reads websites, groups and stores out of `app/etc/config.php` instead.

**A freshly created tree has no `app/etc/config.php` at all.** That file is written by `setup:install`, so a tree that has been installed once carries it and a `composer create-project` tree doesn't — and without it every `bin/magento` command refuses with *You cannot run this command because modules are not enabled*. The build runs `module:enable --all` first, which writes the list and needs no database, and skips it when the tree already carries one.

**That still leaves no `scopes` key**, and the deploy then resolves every asset and dies on the first one that asks for a base URL:

```text
Error happened during deploy process: The default website isn't defined.
```

`build/scd-scopes.php` writes the scopes in, and the Dockerfile keeps a copy of the original to put back. **The values are not a guess at a configuration** — they are the rows Magento's own installer creates, and the store this image serves is installed with exactly them.

**Restoring `config.php` afterwards is the part that matters.** Scopes left in the shipped image are a second source of truth, and `app:config:import` reconciles them against the database on every deploy. Build-time only.

### Startup ordering

`depends_on: condition: service_healthy` maps to **nothing** in Kubernetes, deliberately. Every dependency there's a readiness probe on the dependency plus retry in the dependent. Compose has the condition and uses it, plus `--wait` on `up`.

The php-fpm probe is a real FastCGI request through `cgi-fcgi`, not a TCP check on 9000 — the difference between *"the listener is bound"* and *"the pool can execute PHP"*. There are two init containers in the whole deployment and **neither of them waits**: one sets a sysctl, one stages static content. `make smoke` checks for waiting init containers specifically.

---


## Layout

```text
infrastructure/
├── docker-compose.yaml       one SITE's application tier
├── docker-compose.data.yaml  the data tier, as its own project
├── build/                    Dockerfile, php-fpm config, entrypoint, installer
│   └── rootfs/               baked into the image at /
├── cluster/                  kind config; ingress manifest is cached here
├── k8s/
│   ├── base/                 workloads, services, and the config both
│   │   └── config/           runtimes read
│   │       ├── env/
│   │       │   ├── common.env    what every site shares
│   │       │   └── sites/        one small file per site
│   │       └── files/        nginx, varnish, mariadb
│   └── overlays/
│       ├── dev/              mounted source, Xdebug, relaxed
│       ├── prod-shaped/      immutable image, read-only, hardened
│       └── site/             GENERATED, gitignored — which store the cluster
│                             is serving today
├── scripts/                  everything the Makefile drives
├── docs/adr/                 the decision records
├── secrets/
│   ├── <site-slug>/          one site's crypt key, admin and db passwords
│   └── <data-project>/       the tier's root and RabbitMQ passwords
└── Makefile
```

> [!info] Why the scripts live in the repository
> They are build steps rather than tools: they are invoked only through the Makefile, they take no arguments a person would type, and a repository whose scripts live in somebody's home directory is not reproducible by anyone else. If you want a command on your `PATH`, write a two-line wrapper that execs this Makefile.

> [!warning] `.gitignore` here is load-bearing, and one of its rules is not a file rule
> A global `core.excludesFile` applies to every repository under your home directory, and a Magento project's ignore list is a common thing to have there. Such a list excludes `*.sh` — every script here — and **`docker-compose.yaml`**, at any depth. Without the negations in this repository's own `.gitignore` the tree looks clean, `make compose-up` works on the machine that wrote it, and nothing is reproducible anywhere else.
>
> **The harder ones are directory-level and cannot be negated at all.** A bare `nginx` excludes the *directory* `k8s/base/config/files/nginx/`, and git doesn't descend into an excluded directory, so no `!*.conf` inside it's ever seen — the directory itself has to be re-included first. `docker` and `production` are excluded the same way, which is why build inputs live in `build/` and nothing here is named `production`.
>
> The gate is `git ls-files --others --ignored --exclude-standard`. It should list `secrets/`, `.tmp/`, `.state/`, the cached ingress manifest, any generated cluster overlay, and one env file per site created on this machine — and nothing else.

---


## History

This began as a Kubernetes migration of an existing store's Compose environment, and was repointed at a Magento tree of its own on 2026-08-27. It's published from a fresh root commit: the development history stayed private because it carried paths, hostnames and machine names belonging to the environment it grew out of. The [CHANGELOG](../CHANGELOG.md) carries the narrative, and the ADRs carry the reasoning.
