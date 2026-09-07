# More than one store

Standing up a second storefront beside the first, what keeps the two out of each other's data, and the snapshots that make a new store take a minute instead of an afternoon.

## Contents

- [More than one store](sites.md)
- [Snapshots — seeding the next store](#snapshots--seeding-the-next-store)

---

## Another store, on demand

```bash
make new-site SITE=second.test
```

That produces a working storefront and admin at `https://second.test` with 2042 products and their images in it, and leaves `vanilla.test` running. It writes a config file, issues certificates, generates credentials, creates a database and a queue vhost, starts an application tier, restores a snapshot into it and runs the install.

```bash
make sites
```

```bash
make destroy-site second.test
```

> [!abstract] The shape, in one line each
> **A site is a hostname, a small config file, a set of credentials and its own application tier.** It shares the image, the Magento tree and — by default — one data tier. **Only Compose runs more than one**; the cluster binds `127.0.0.1:80` and serves one store at a time, which it always did.

> [!info] What this is for, and what it isn't
> **The point is standing a store up on demand and switching between stores cheaply — not running a fleet.** This is one workstation with an editor and a browser on it, not a datacenter, and nothing here is capacity planning. Two stores can be up at once because that's cheaper than tearing one down and rebuilding it, and because a parked store costs almost nothing; that's convenience, not a target to fill.
>
> The numbers below exist to justify **why a second store is affordable at all** and to set the one bound that matters. They are not a budget to spend.

### Why a second store is cheap

One installed store, idle, with sample data loaded, measured with `docker stats` rather than budgeted:

| Tier | Containers | Idle | |
|---|---:|---:|---|
| Data — db 684, opensearch 980, rabbit 112, valkey ×2 18 | 5 | **1.75 GiB** | `███████████░░░░░░░░░` 54% |
| App — php ×3 456, web ×3 58, varnish 99, cron 0.6, mail 3 | 9 | 0.60 GiB | `████░░░░░░░░░░░░░░░░` 19% |
| Consumers ×6 | 6 | 0.87 GiB | `█████░░░░░░░░░░░░░░░` 27% |
| | **20** | **3.22 GiB** | |

**The expensive half is the half a second store has no reason to copy.** MariaDB and the OpenSearch JVM alone are 1.66 GiB — over half the stack — and neither does any per-site work. Against roughly 10 GiB available on this host:

| | Idle total | Headroom left |
|---|---:|---|
| One store — the normal case | 3.22 GiB | `██████████████░░░░░░` |
| A second one, parked | 3.82 GiB | `█████████████░░░░░░░` |
| Both doing background work | 4.68 GiB | `██████████░░░░░░░░░░` |
| A full stack each | 6.44 GiB | `████░░░░░░░░░░░░░░░░` |

**Read the first row as the intended state.** A second store is something you stand up when you need one and destroy when you're done, and the rows below it are what that costs while it's there.

> [!warning] Idle is not the risk, and a memory table hides that
> Per site the declared ceilings are `php-cron` 4g + `magento-cron` 4g + six consumers at 1g — **14 GiB of ceiling for one store**. A single site can already overcommit this laptop. So what has to be bounded is **how many sites do background work, not how many exist**, and neither the table above nor any idle measurement licenses concurrency. Running the cluster beside a Compose stack once took this host to a load average of 300.
>
> **`use` and `park` are that bound.** Every site serves; one site holds the consumers and the cron loop.
>
> ```bash
> make use SITE=second.test
> ```
>
> **And `new-site` refuses rather than warning** when the projection doesn't fit — the same idiom as the one-runtime-at-a-time guard, with `ALLOW_TIGHT=1` to override and a reason printed for why you should not.

### The two modes

```bash
make new-site SITE=second.test MODE=exclusive
```

**They differ only in which data project the site attaches to**, which is why there's one code path rather than two:

| | `shared` (default) | `exclusive` |
|---|---|---|
| Data project | `magento-data`, one for every site | `magento-data-<slug>`, this site's own |
| Costs | ~1.5 GiB | ~3.3 GiB |
| Isolation | namespaced — see below | complete |
| `destroy-site` removes | the database, indices, keyspaces and vhost | the whole tier |

An exclusive site is **the same data compose file started again under a different name**. Its containers answer to the same service names on a network only it joins, so `db` still resolves to `db` and nothing downstream forks.

### What keeps two stores out of each other's data

Five namespaces, one per site, and **every one of them fails silently when it is wrong** — which is why they are all in the site's config file where they can be read together, and why `make lint` checks that no two sites share one:

| Namespace | Key | What a collision looks like |
|---|---|---|
| Database | `DB_NAME` | the only one that fails loudly |
| Cache keys | `MAGENTO_CACHE_PREFIX` | one store's block HTML rendering inside another |
| Search index | `OPENSEARCH_INDEX_PREFIX` | a catalogue containing another store's products, and a reindex on either one deleting the other's documents |
| Queue vhost | `RABBITMQ_VIRTUALHOST` | **Magento's queue names are fixed strings, identical in every store.** One vhost means shared queues: a message published by one store is consumed by the other, and the only evidence is work that never happened |
| Valkey databases | `REDIS_CACHE_DB`, `REDIS_PAGE_CACHE_DB`, `REDIS_SESSION_DB` | a `flushdb` or an eviction reaching across stores |

**The entrypoint pinned the search prefix to `magento2` and the vhost to `/` as literals** until this existed, so setting either in the ConfigMap decided nothing at all — the same defect the `MAGENTO_CACHE_PREFIX` comment already described about itself. Both are now read from the config with those literals as defaults, so a store installed before any of this keeps working untouched.

**Mail is per site too**, at `https://mail.<site>/` rather than a published port. Two sites cannot both bind `172.17.0.1:8025`, and a password-reset mail from one store landing in another's inbox is the same class of confusion for 3 MiB.

### Seeding, and the crypt key

**A new site is seeded from a snapshot, not installed.** A restore is 49 seconds measured against roughly forty minutes to install and load sample data from scratch, and `sample-data-baseline` — 2042 products, 78 MB of media — is the default.

```bash
make new-site SITE=second.test SEED=none
```

`SEED=none` installs from empty instead, and says so in the plan it prints before doing anything.

> [!info] A seeded site inherits the crypt key, deliberately and visibly
> A snapshot records a **fingerprint** of the key that encrypted it, never the key. A store with a different key restores those rows as bytes it cannot read — payment credentials and API keys in `core_config_data` — per value and without an error.
>
> So `new-site` **searches `secrets/` for the key whose fingerprint matches the snapshot** and gives the new site that one. The alternative, a fresh key every time, would fire `snapshot-restore`'s warning on the normal case, and a warning that fires every time is one nobody reads.
>
> **It is made visible rather than implicit**: the plan says which store the key came from, the site's config records it as `SITE_CRYPT_ORIGIN`, and `make sites` prints every site's fingerprint so two stores sharing a key is something you can see. `SEED=none` generates its own.

> [!info] A site is machine state, and git doesn't track it
> `k8s/base/config/env/sites/<slug>.env` is **gitignored**, with one exception. Creating a store writes one and destroying it removes one, so tracking them would turn *"I needed a scratch store for an afternoon"* into two commits about a store nobody else has — which is exactly what happened the first time `second.test` was created and destroyed.
>
> **Nothing is lost by that.** The file is derived from the hostname by `scripts/site.sh`, and `make new-site` writes an equivalent one. What is not recoverable is the store's *data*, which was never in git either.
>
> **The exception is `vanilla-test.env`, and it is mechanical rather than sentimental**: `k8s/base/kustomization.yaml` names that exact path in its `configMapGenerator`, so without it a fresh clone cannot render either overlay and `make lint` fails on a checkout that has done nothing wrong. It's also the worked example every generated one is read against.
>
> Which stores exist is a fact about this laptop, so `make sites` reads the filesystem for the list and `docker ps` for the state — a config file existing is not a claim that the store does.

### What is not built

- **The cluster serves one site at a time.** `make deploy SITE=second.test` points it at another store by generating a small overlay over the chosen one — the site's env file merged into the ConfigMap, and the ingress host and TLS secret rewritten. There's no second port for a second hostname, and pretending otherwise would be a claim the runtime cannot keep.
- **The shared Valkey caps a data tier at eight sites**, because a site takes two of its sixteen databases. `site.sh` allocates them from what the config files already use and refuses when they run out, rather than wrapping.
- **The eviction pool is shared.** A busy store can evict a quiet one's cache entries. That's correct for a reconstructible cache and a real difference from a private Valkey; it's stated rather than left to be found.
- **Nothing here bounds CPU.** The memory guard is a memory guard.

---


## Snapshots — seeding the next store

Installing from empty takes about twenty minutes and sample data longer again. Captured once, that becomes about a minute:

```bash
make snapshot NAME=sample-data-baseline
```

```bash
make snapshot-restore FILE=../snapshots/sample-data-baseline.sql.zst
```

```bash
make snapshots
```

**Restoring by hand is the second use for a snapshot; the first is `make new-site`**, which seeds a brand-new store from one and inherits its crypt key so the fingerprint check has nothing to warn about. → [More than one store](sites.md).

**A snapshot is two files, because a store is two things: the database and `pub/media`.** Sample data ships its images inside the vendor packages and `setup:upgrade` copies them into `pub/media` on first install — so a database restored into a fresh store finds every product already installed, never re-copies the images, and renders a catalogue of broken thumbnails.

**Capturing the database alone looks complete and is not.** `-d` skips the media half when that's genuinely what you want, and `snapshot-restore` says so plainly when a snapshot has no media beside it.

**It is a logical dump, and that is the point.** A physical copy is tied to the MariaDB version, page size and configuration that produced it; a logical one restores into any MariaDB that can parse SQL — which is what seeding a *different* store means. It also works against whichever runtime is up, so a snapshot taken from Compose restores into the cluster.

**Structure is kept for thirteen log, session and queue tables and their data is not.** That state belongs to the environment that produced it and would be actively wrong in a store seeded from this one. **Index tables keep their data on purpose** — dropping it would halve the snapshot and leave every restored store needing a full reindex before it can render a category page, which is the twenty minutes this exists to avoid.

**Each snapshot carries a small `.json` beside it** naming the Magento version, the product count, the base URL at capture, and a **fingerprint of the crypt key** — never the key itself. `snapshot-restore` compares that fingerprint and warns when it differs, because values Magento encrypted under another key come back as unreadable rows rather than as an error. Catalogue and customer data are unaffected; payment credentials and API keys in `core_config_data` are not.

**The restore drops and recreates the database rather than loading over it.** A dump loaded on top of an existing schema leaves behind every table it doesn't mention, which is how a "restored" store ends up with rows from two installs.

> [!warning] Snapshots are a convenience, not a safeguard
> `SNAPSHOT_DIR` defaults to a `snapshots/` directory beside this repository, and it isn't in git — a multi-hundred-megabyte dump doesn't belong in one. Whether it's backed up is a question about your machine, and the answer is usually no. **A snapshot saves an afternoon. It does not protect anything.**

---
