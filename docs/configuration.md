# Configuration

Every setting here lives in one of four places, and which one it lives in is a decision rather than filing:

| Where | What belongs in it |
|---|---|
| **Environment variables** | facts about *your machine* — where the Magento tree is, where certificates are |
| **`k8s/base/config/env/common.env`** | what every store shares — service addresses, behaviour, the consumer list |
| **`k8s/base/config/env/sites/<slug>.env`** | what one store cannot share with another — its database, its cache keys, its hostname |
| **`secrets/`** | generated credentials. Never edited by hand, never committed |

**Both runtimes read the two env files in the same order, with the site file winning.** Compose does it with two `env_file:` entries and Kustomize with two `envs:` entries. That identity is what makes the split safe rather than a second place to drift.

## Contents

- [Environment variables](#environment-variables)
- [`common.env` — what every store shares](#commonenv--what-every-store-shares)
- [The per-store file](#the-per-store-file)
- [Make variables](#make-variables)
- [Secrets](#secrets)
- [Changing a setting is a deploy, not a restart](#changing-a-setting-is-a-deploy-not-a-restart)

## Environment variables

These describe your machine. Set them in your shell, or accept the defaults.

| Variable | Default | What it's |
|---|---|---|
| `MAGENTO_SRC` | `../commerce-vanilla` | The Magento tree to build and run. The one setting most people change |
| `CERTS_HOME` | `certs/` in the repository | Where `<host>.crt` and `<host>.key` are found. Gitignored |
| `SNAPSHOT_DIR` | `../snapshots` | Where `make snapshot` writes and `snapshot-restore` reads |
| `IMAGE_NAME` | `magento-app` | The image name |
| `IMAGE_TAG` | `local` | The image tag. **Change this to build a second image without replacing the first** |
| `CLUSTER_NAME` | `vanilla` | The kind cluster's name |
| `NAMESPACE` | `vanilla` | The Kubernetes namespace |
| `OVERLAY` | `dev` | Which cluster overlay to render — `dev` or `prod-shaped` |
| `DEV_CERT_TOOL` | `dev-vhost-cert` | A local wrapper around mkcert, if you have one. Plain `mkcert` is used when it's absent |
| `ALLOW_BOTH` | unset | Set to `1` to run both runtimes at once. There's no good reason to |
| `ALLOW_TIGHT` | unset | Set to `1` to create a store the memory check refuses |
| `YES` | unset | Set to `1` to skip confirmation prompts, for unattended use |

> [!WARNING]
> **`IMAGE_TAG` is the one to reach for before building against a different Magento tree.** The tag defaults to `local`, so building from a second tree replaces the first tree's image in place — and the next time you start the first store, it runs the other tree's code against its own database. Give each tree its own tag.

## `common.env` — what every store shares

The rule for this file: **a value belongs here when a second store has no reason to disagree with it.** A service address, a behaviour, a list.

### Service addresses

`DB_HOST`, `DB_PORT`, `REDIS_CACHE_HOST`, `REDIS_SESSION_HOST`, `OPENSEARCH_HOST`, `OPENSEARCH_PORT`, `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USER`, `VARNISH_HOST`, `VARNISH_PORT`.

**These are service names, and the names are a contract.** Every Compose service is named after the Kubernetes Service doing the same job, so the Varnish VCL, the nginx template and the entrypoint all resolve the same names under both runtimes. Rename one and a shared config file has to fork, which is the moment the two runtimes stop being comparable.

### Application behaviour

| Key | What it does |
|---|---|
| `MAGENTO_MODE` | `production` or `developer`. The mounted-source overlay sets `developer` |
| `MAGENTO_ADMIN_URI` | The admin path, `/admin` by default |
| `MAGENTO_CRON_RUN` | Whether `env.php` starts consumers from cron. False here — they are their own containers |
| `MAGENTO_CONSUMERS_WAIT` | Whether a consumer waits for messages or exits when the queue is empty |
| `MAGENTO_FPC_APPLICATION` | The full-page cache backend. Varnish |
| `MAGENTO_FPC_TTL` | How long Varnish keeps a page |
| `MAGENTO_INSTALL_DATE` | **Fixed on purpose.** Magento mixes this into cache identifiers, so a per-container value means two replicas never share a cache entry and the storefront looks intermittently uncached |
| `MAGENTO_SMTP_TRANSPORT` | How Magento sends mail. `smtp` |
| `MAGENTO_SMTP_HOST` | The mail sink. `mailhog`, which is the service name in both runtimes |
| `MAGENTO_SMTP_PORT` | `1025` |
| `MAGENTO_SMTP_AUTH` | `none`, because the sink accepts anything |

### Mail

Every store gets a mail sink, and Magento is pointed at it here rather than in the database, for the same reason as the base URL: the mail host only exists inside the runtime.

**This is not optional wiring.** Magento's default transport is `sendmail`, and the image has no `sendmail` binary — so without these four variables *every* message fails. It is easy to miss for a long time, because the first thing most people notice is being unable to finish two-factor setup on a fresh admin account, and the error says only:

> Failed to send the message. Please contact the administrator

which names neither the transport nor the missing binary.

Read what was sent at `https://mail.<your-site>/` on Compose, or `make port-forward-mailhog` on the cluster.

### `MAGENTO_CACHE_TYPES`

The list of Magento caches to enable. **It is authoritative and fails closed: a type not in the list is disabled**, and an empty value disables every cache.

Modules add cache types, so this list can fall behind. The installer checks it both ways and says so: a type Magento has that the list is missing would be silently switched off, and a type in the list that Magento doesn't have is harmless but stale.

> [!NOTE]
> Three entries — `admin_ui_sdk`, `target_rule` and `webhooks_response` — exist only in Adobe Commerce. On Magento Open Source the installer reports them as stale and carries on. That's expected, not a misconfiguration.

### Install settings

`MAGENTO_ADMIN_USER`, `MAGENTO_ADMIN_EMAIL`, `MAGENTO_ADMIN_FIRSTNAME`, `MAGENTO_ADMIN_LASTNAME`, `MAGENTO_LANGUAGE`, `MAGENTO_CURRENCY`, `MAGENTO_TIMEZONE`.

Read on a first install only. **The admin password is not here** — it's generated into `secrets/` like every other credential.

### `MAGENTO_CONSUMERS`

The queue consumers to run. **Core Magento only, on purpose** — a queue belonging to one store's modules is not infrastructure, and adding one here would make this file specific to a single installation. Add site-specific consumers through the per-store file and an overlay.

This list and the Deployments in `k8s/base/jobs/consumers.yaml` must agree, and the mismatch is invisible in both directions: a consumer that's not named never runs, and nothing reports it. `make verify-consumers` compares three sets — the list, the cluster Deployments and the Compose services.

## The per-store file

`k8s/base/config/env/sites/<slug>.env`, written by `make new-site`. The slug is the hostname with dots replaced by hyphens.

**Five of these are namespaces, and four of the five fail silently when two stores collide.**

| Key | What a collision looks like |
|---|---|
| `DB_NAME` | the only one that fails loudly |
| `MAGENTO_CACHE_PREFIX` | one store's rendered blocks appearing inside another |
| `OPENSEARCH_INDEX_PREFIX` | a catalogue containing another store's products, and a reindex on either deleting the other's documents |
| `RABBITMQ_VIRTUALHOST` | **Magento's queue names are identical in every store.** One vhost means shared queues: a message published by one store is consumed by the other, and the only evidence is work that never happened |
| `REDIS_CACHE_DB`, `REDIS_PAGE_CACHE_DB`, `REDIS_SESSION_DB` | a flush or an eviction reaching across stores |

`make lint` checks that no two stores share any of them.

> [!DANGER] A hyphen in `MAGENTO_CACHE_PREFIX` breaks every command
> Magento validates cache ids against `[a-zA-Z0-9_{}]` from `bin/magento`'s constructor, so a hyphen fails *every* CLI command including the install, with a stack trace that names the id and never the setting:
>
> ```text
> Invalid id or tag 'second-test_MAGE_VERSION' : must use only [a-zA-Z0-9_{}]
> ```
>
> Database names and cache prefixes use underscores for this reason. Search prefixes and queue vhosts accept hyphens and keep the slug.

The rest of the file:

| Key | What it's |
|---|---|
| `SITE_HOST` | the hostname. Everything else is derived from it |
| `MAGENTO_BASE_URL` | the store's base URL |
| `DB_USER` | this store's database user |
| `SITE_MODE` | `shared` or `exclusive` — which data tier this store attaches to |
| `SITE_SOURCE` | `image` or `mounted` — where the application code comes from |
| `SITE_SEED` | which snapshot this store was seeded from, or `none` |
| `SITE_IMAGE_TAG` | overrides `IMAGE_TAG` for this store. Empty means the shared image |
| `SITE_MAGENTO_SRC` | overrides `MAGENTO_SRC` for this store. Empty means the shared tree |
| `SITE_CRYPT_ORIGIN` | which store's encryption key this one inherited, if it was seeded |

> [!INFO] These files are machine state and git doesn't track them
> Creating a store writes one and destroying it removes one, so tracking them would turn *"I needed a scratch store for an afternoon"* into two commits about a store nobody else has. `make sites` reads the filesystem for the list.
>
> **One exception:** `vanilla-test.env` is tracked, because `k8s/base/kustomization.yaml` names that exact path. Without it a fresh clone cannot render either overlay and `make lint` fails on a checkout that has done nothing wrong.

## Make variables

Passed on the command line: `make new-site SITE=second.test MODE=exclusive`.

| Variable | Default | What it's |
|---|---|---|
| `SITE` | `vanilla.test` | The store to act on. Every store command takes it |
| `MODE` | `shared` | `shared` or `exclusive`, for `new-site` |
| `SEED` | `sample-data-baseline` | Which snapshot to seed from. `none` installs from empty |
| `OVERLAY` | `dev` | Which cluster overlay to deploy |
| `NAMESPACE` | `vanilla` | The Kubernetes namespace |
| `CLUSTER` | `vanilla` | The kind cluster name |
| `ARGS` | — | Arguments for `make cli` / `make compose-cli` |
| `NAME`, `FILE` | — | For `make snapshot` and `make snapshot-restore` |

**A hostname can be typed as a bare word** — `make compose-up second.test` — and saying it twice is an error rather than a guess about which one you meant.

## Secrets

Generated by `make secrets` into `secrets/`, which is gitignored. Directories are mode `700` and values `600`.

| Path | What it holds |
|---|---|
| `secrets/<data-project>/` | the database root password and the RabbitMQ administrator |
| `secrets/<store-slug>/` | that store's database password, encryption key and admin password |

**Values are cached, and that is correctness rather than convenience.** The database volume is created with the password from the first run; regenerating on every deploy would lock the application out of its own database with an error that looks nothing like its cause.

**The encryption key is the one value a store may inherit.** A store seeded from a snapshot cannot read what that snapshot encrypted unless it holds the key that encrypted it. A snapshot records a *fingerprint* of the key, never the key, and `make sites` prints every store's fingerprint so two stores sharing one is visible rather than inferred.

## Changing a setting is a deploy, not a restart

> [!DANGER] Magento refuses to serve when the configuration file changes
> It stores a hash of one section of `env.php` in the database and compares them on every request. Change a value in `common.env` or a per-store file, restart, and every storefront request returns 500:
>
> ```text
> The configuration file has changed. Run the "app:config:import" or the
> "setup:upgrade" command to synchronize the configuration.
> ```
>
> **It appears on the storefront rather than where you made the change**, which is what makes it confusing the first time.

After editing either file:

```bash
make compose-install
```

or `make deploy` for the cluster. Both end in a configuration import.

> [!WARNING] A correct config file decides nothing until the image is rebuilt
> The entrypoint that turns these files into `env.php` **lives inside the image**. So the file can be right, `docker compose config` can be right, the container's environment can be right, and the store can still be using another store's search index — because the image predates the change.
>
> `make verify-namespaces` is the check that catches this. It reads the `env.php` each running store actually loaded, rather than the config it should have loaded.
