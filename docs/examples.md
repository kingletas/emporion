# Examples

A recipe for each thing people actually do with Emporion: running a store, working on it, standing up a second one, and asking the cluster the questions Compose cannot answer.

**Compose comes first, and most days it is all you need.** The cluster section assumes you have never used Kubernetes and explains each word where it first matters.

Every recipe here was run against a real store on one workstation. Where a command prints something worth recognising, the output below is copied from that run.

## Contents

- [Everyday, on Compose](#everyday-on-compose)
    - [Start a store](#start-a-store)
    - [See what is running](#see-what-is-running)
    - [Run a Magento command](#run-a-magento-command)
    - [Read the configuration the store actually loaded](#read-the-configuration-the-store-actually-loaded)
    - [Read the mail the store sent](#read-the-mail-the-store-sent)
    - [Work on a module](#work-on-a-module)
    - [Point it at a tree somewhere else](#point-it-at-a-tree-somewhere-else)
    - [Stand up a second store](#stand-up-a-second-store)
    - [Move the background work between stores](#move-the-background-work-between-stores)
    - [Take a snapshot, and seed from it](#take-a-snapshot-and-seed-from-it)
    - [Remove a store](#remove-a-store)
    - [Stop it](#stop-it)
    - [Check that it is really what it says it is](#check-that-it-is-really-what-it-says-it-is)
- [The cluster, in plain words](#the-cluster-in-plain-words)
    - [The words you need, and nothing more](#the-words-you-need-and-nothing-more)
    - [When the cluster is worth it](#when-the-cluster-is-worth-it)
    - [Start it](#start-it)
    - [See what is running, and what went wrong](#see-what-is-running-and-what-went-wrong)
    - [Run a command in the cluster](#run-a-command-in-the-cluster)
    - [Prove the data survives its container being replaced](#prove-the-data-survives-its-container-being-replaced)
    - [Walk the acceptance criteria](#walk-the-acceptance-criteria)
    - [Deploy a change](#deploy-a-change)
    - [The two overlays](#the-two-overlays)
    - [Turn Xdebug on for one pod](#turn-xdebug-on-for-one-pod)
    - [See what each workload is allowed](#see-what-each-workload-is-allowed)
    - [Look before you apply](#look-before-you-apply)
    - [Destroy it](#destroy-it)
- [Things that will bite you](#things-that-will-bite-you)

## Everyday, on Compose

### Start a store

```bash
make compose-up
make compose-install
```

The first command starts about fifteen containers: PHP, nginx, Varnish, MariaDB, OpenSearch, RabbitMQ, two Valkey caches, a mail sink, a cron loop and six queue consumers. The second installs the store, or upgrades it if the database already has one. Then open `https://vanilla.test/`.

**The install decides for itself.** An empty database gets a full install, an installed one gets an upgrade, and a database it cannot reach makes it retry and then fail — it never mistakes "cannot connect" for "empty", because that mistake reinstalls over live data.

```text
[install] checking db:3306/vanilla
[install] database is installed — upgrading
```

Every store command takes a hostname, either way round:

```bash
make compose-up SITE=second.test
make compose-up second.test
```

### See what is running

```bash
make compose-status
```

One line per container, with its health. Everything running Magento is the same image:

```text
vanilla-test-php-fpm-1     magento-app:local   Up 26 seconds (healthy)
vanilla-test-varnish-1     varnish:7.5.0       Up 12 seconds (healthy)
vanilla-test-web-1         nginx:1.28.0        Up 19 seconds (healthy)
```

### Run a Magento command

```bash
make compose-cli ARGS="cache:flush"
make compose-cli ARGS="indexer:reindex catalog_product_price"
make compose-shell
```

Commands run in the **cron** container, not the one serving pages. A reindex inside a container that is also answering requests competes with it for the same memory limit, and the background pool exists so that work has somewhere else to go.

### Read the configuration the store actually loaded

`app/etc/env.php` is written at container start from the shared config and the generated credentials, so reading the file the application loaded is usually the fastest way to a wrong answer:

```bash
docker compose -p vanilla-test exec php-fpm cat /app/app/etc/env.php
```

On a store running from the image the same file is at `/etc/magento/env.php`, with a symlink from the application directory so `/app` can stay read-only.

### Read the mail the store sent

Every store gets its own mail sink at `https://mail.<your-site>/`. Magento's default transport is `sendmail`, which the image does not have, so without the mail settings *every* message fails — and the first thing most people notice is a fresh admin account that cannot finish two-factor setup.

### Work on a module

By default the store runs the code baked into the image, and changing that means a rebuild of ten to twenty minutes. That is the wrong trade while you are editing a file every few minutes:

```bash
make compose-source SOURCE=mounted
```

Now the tree on disk **is** the code in the container, in developer mode, running as your user. Edit a file, flush the cache, see the change. `make compose-source` on its own reports where each store's code comes from:

```text
  SITE                     SOURCE     TREE
  vanilla.test             mounted    /path/to/your/magento
```

```bash
make compose-source SOURCE=image
```

puts it back. **It is a property of the store, not a flag on a command**, so every `docker compose` call agrees about it; a forgotten flag would otherwise recreate the containers without the mounts, mid-session, with nothing to say it had happened.

> [!warning] A mounted store resembles a real deployment in no way at all
> Writable application directory, your own user id, developer mode, no compiled dependency injection. **Measure nothing there and ship nothing from there.**

### Point it at a tree somewhere else

Two settings describe your machine rather than the project, and the defaults sit beside the repository:

```bash
export MAGENTO_SRC=/path/to/magento
export SNAPSHOT_DIR=/path/to/snapshots
```

Without the first, `make compose-up` stops with `no Magento tree at …`. Without the second, `make new-site` stops with `no snapshot 'sample-data-baseline' in …`. Both name the path they looked at, so the fix is the export above or a line in your shell profile.

### Stand up a second store

```bash
make new-site SITE=second.test
```

That writes the store's config file, issues its certificates, generates credentials, creates a database and a queue vhost, starts its application tier, restores a snapshot into it and installs it — while the first store keeps running. A restore is about a minute against roughly forty to install and load sample data from scratch.

```bash
make sites
```

```text
  SITE                 MODE       STATE     WORK    CRYPT KEY     SEEDED FROM
  second.test          shared     up        parked  08f4a47ef3b7  sample-data-baseline
  vanilla.test         shared     up        yes     08f4a47ef3b7  none
```

**The `CRYPT KEY` column is there so two stores sharing a key is something you can see.** A seeded store inherits the key that encrypted the snapshot, deliberately: a store with a different key restores encrypted rows — payment credentials, API keys — as bytes it cannot read, per value and with no error.

`MODE=exclusive` gives the new store its own data tier instead of sharing one, for about twice the memory. `SEED=none` installs from empty.

### Move the background work between stores

Every store serves. **One store holds the consumers and the cron loop**, because a single store already declares more memory ceiling than a laptop has:

```bash
make use SITE=second.test
make park SITE=second.test
```

```text
==> second.test now holds the background work. One site at a time, by design.
```

### Take a snapshot, and seed from it

```bash
make snapshot NAME=sample-data-baseline
make snapshots
make snapshot-restore FILE=/path/to/snapshots/sample-data-baseline.sql.zst
```

```text
  SNAPSHOT                               SIZE   PRODUCTS  MAGENTO
  sample-data-baseline                   1.1M       2042  Magento CLI 2.4.8-p2
```

**A snapshot is two files, because a store is two things**: the database and `pub/media`. Sample data ships its images inside the vendor packages and copies them into `pub/media` on first install, so a database restored without its media renders a catalogue of broken thumbnails.

> [!warning] A snapshot saves an afternoon. It does not protect anything.
> The snapshot directory is not in git, and whether it is backed up is a question about your machine.

### Remove a store

```bash
make destroy-site second.test
```

It prints what it will delete and asks you to type the store's name. It takes the containers, the volumes, the network, the database, the search indices, the cache keyspaces and the queue vhost:

```text
==> Dropping the database, the indices, the keyspaces and the vhost
==> second.test destroyed. Its certificate is left alone — mkcert pairs are cheap and harmless.
```

The destructive targets refuse to run against the default store, so a mistyped name can never delete a different store than the one you named.

### Stop it

```bash
make compose-down      # stop it, keeping the database and media
make compose-destroy   # stop it AND delete its volumes (asks first)
```

### Check that it is really what it says it is

```bash
make lint
```

```text
  kustomize dev                ok
  kustomize prod-shaped        ok
  compose vanilla.test         ok
  site namespaces unique       ok
  shellcheck                   ok
```

That is the cheap gate and it proves nothing about a running store. Two checks ask the running thing instead:

```bash
make verify-consumers     # the declared list, the cluster workloads and the Compose services agree
make verify-namespaces    # each running store uses the database, caches, index and queue its config declares
```

**Five settings keep two stores out of each other's data, and four of the five fail silently when they collide** — a shared index prefix looks like a catalogue with another store's products in it, and a shared queue vhost looks like a message that vanished. `verify-namespaces` reads what each store actually loaded:

```text
  second.test
    database         second_test              ok
    cache prefix     second_test_             ok
    search prefix    second-test              ok
    queue vhost      /second-test             ok
```

## The cluster, in plain words

Everything above is Docker Compose, and it is the runtime to work in. The cluster runs the same store from the same image and the same configuration, and it exists to answer questions Compose cannot be asked.

### The words you need, and nothing more

| Word | What it is here |
|---|---|
| **Pod** | One running container with a name. Roughly what a Compose service instance is |
| **Deployment** | A thing that keeps N pods of one kind alive and replaces them when they die — PHP, nginx, Varnish, each consumer |
| **StatefulSet** | The same, for something with a disk that must survive: MariaDB, OpenSearch, RabbitMQ, the session cache |
| **Claim** (PVC) | A request for a disk. The cluster finds the storage and attaches it to the pod |
| **Probe** | A health check the cluster runs. A failing readiness probe takes a pod out of service without killing it |
| **Service** | A stable name other pods can reach, whichever pod is answering today |
| **Ingress** | The front door. It terminates TLS and passes the request inward, to Varnish here |
| **Job** / **CronJob** | A container that runs once and finishes — the installer — and one that runs on a schedule — Magento's cron |
| **Namespace** | A named box the whole store lives in. `vanilla` here |
| **Overlay** | A set of edits applied over the base manifests. There are two: `dev` and `prod-shaped` |
| **Context** | Which cluster `kubectl` talks to. `kind-vanilla` here |

### When the cluster is worth it

|  | Compose | Cluster |
|---|---|---|
| Time to a serving storefront | under a minute | several, plus building the cluster |
| Stores at once | as many as fit | one |
| Good for | running the store, day to day | probes, claims, rollout, scaling |

**They must never run at the same time.** Both bind the same edge, and two full Magento stacks on one laptop reaches a load average in the hundreds. Both `up` targets refuse while the other is present, and that refusal is the feature.

### Start it

```bash
make tools     # installs kind and kubectl; the only target that downloads anything
make up
```

`make up` creates the cluster, installs an ingress controller, builds the image and loads it into the cluster's own image store, applies the manifests, runs the install Job and waits until everything reports ready. It ends by printing the one line to add to `/etc/hosts`, because the cluster binds `127.0.0.1` rather than the Docker bridge:

```text
127.0.0.1 vanilla.test
```

### See what is running, and what went wrong

```bash
make status     # pods, services, claims, ingress, cronjobs
make events     # newest last
make logs       # every workload at once
```

A pod that keeps dying shows as `CrashLoopBackOff`, and its own log says why:

```bash
kubectl --context kind-vanilla logs -n vanilla deploy/consumer-async-operations-all --tail=20
```

### Run a command in the cluster

```bash
make cli ARGS="config:show web/secure/base_url"
make shell
```

```text
https://vanilla.test/
```

As on Compose, these run in the cron pod rather than the one serving pages.

### Prove the data survives its container being replaced

This is the question Compose cannot be asked, and it is one command:

```bash
make smoke -c A4
```

It writes a value into the session store, deletes that pod, waits for the replacement, and reads the value back. Passing means the claim outlived the container:

```text
  ✓  A4   value written before `delete pod` survived the replacement
```

Deleting a pod by hand is the same experiment, and the cluster replaces it without being asked:

```bash
kubectl --context kind-vanilla delete pod valkey-session-0 -n vanilla
```

### Walk the acceptance criteria

```bash
make smoke
```

It reports every criterion rather than stopping at the first failure, because a report of everything wrong is worth more than the first thing wrong:

```text
  ✓ A2   storefront home returns 200
  ✓ A4   value written before `delete pod` survived the replacement
  ✓ A5   no waiting init containers; 26 readiness probes declared
  ✓ A8   6 cron Job(s) have fired; 6 consumer(s) running with nobody starting them
  -  A9   needs 2 php-fpm replicas to mean anything — run the prod-shaped overlay
  ✓ A11  second request reports X-Cache: HIT — Varnish is in the chain and caching
```

**A5 is worth reading twice.** It passes when nothing is waiting on an init container that merely sleeps until something else is up: ordering is expressed as probes, so a service that restarts at three in the morning does not need its neighbours restarted in the right order.

### Deploy a change

```bash
make deploy
```

Applies the manifests again, runs the install Job, and waits for each rollout. A changed ConfigMap gets a new name from its own content, so editing configuration rolls the pods that read it — an edited ConfigMap applied by hand changes nothing until something restarts, and *"I changed the config and nothing happened"* is the most expensive hour there is.

### The two overlays

```bash
make deploy OVERLAY=dev           # the default
make deploy OVERLAY=prod-shaped
```

|  | `dev` | `prod-shaped` |
|---|---|---|
| Application code | the tree on your disk, mounted in | in the image |
| Root filesystem | writable | read-only |
| Capabilities | default | all dropped |
| opcache | rechecks every request | trusts the image |
| Xdebug | installed, off, switchable per pod | not in the image |
| Storefront pods | 1 | 2 |

`prod-shaped` is a shape, not production. No cluster here serves traffic.

### Turn Xdebug on for one pod

`dev` overlay only, and no rebuild:

```bash
kubectl --context kind-vanilla -n vanilla set env deployment/php-fpm XDEBUG_MODE=debug
```

Turn it back off afterwards. Merely loading Xdebug with a mode set costs about 2× on every request whether or not you attach, so any timing taken against that pod is fiction.

### See what each workload is allowed

```bash
make top
```

```text
  Declared (requests / limits):
NAME                                             CPU_REQ   MEM_REQ   MEM_LIM
consumer-async-operations-all-…                  50m       384Mi     768Mi
consumer-codegenerator-…                         50m       192Mi     384Mi
```

Actual usage needs `metrics-server`, which is not installed by default — it is one more component on a memory-constrained host, and it is worth installing only when you are tuning the numbers. `make top` prints the command.

### Look before you apply

```bash
make render
```

Prints exactly what would be applied, and changes nothing.

### Destroy it

```bash
make down
```

The cluster and every claim in it, gone. The Magento tree on your disk is untouched.

## Things that will bite you

**Flushing the config cache takes the store out of Varnish's rotation for about half a minute.** The backend probe asks the storefront for a health page every ten seconds with a five-second limit and needs three of the last five to pass; rebuilding configuration in developer mode makes that slower, so the backend is marked sick and every request answers **503 Backend fetch failed** — which says nothing about a cache. Wait, or ask nginx directly.

**`rm -rf var/cache` does nothing.** The cache backend is Valkey. When a change stops `bin/magento` booting at all, the way out is the cache container itself:

```bash
docker exec magento-data-valkey-cache-1 valkey-cli FLUSHALL
```

**The configuration file changing is a deploy, not a restart.** Magento hashes one section of `env.php` and refuses to serve when it changes without being re-imported: every storefront request returns 500, on the storefront rather than where you made the edit. Re-run `make compose-install` or `make deploy`; both end by importing.

**An empty `app/etc/env.php` in the tree fails the image build.** A container that once mounted something at that path can leave a zero-byte file behind, and the build then stops inside `setup:di:compile` with `Invalid configuration file: '/app/app/etc/env.php'`, which does not name the tree. Delete the file — a tree that has never been installed has no `env.php` at all — and build again.

**A hyphen in a cache prefix breaks every command.** Magento rejects it from `bin/magento`'s own constructor, so the install fails too, with a trace naming the cache id and never the setting.
