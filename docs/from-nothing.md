# From nothing to a storefront

This guide assumes you have a Linux machine, Docker, and no Magento experience beyond knowing it's a PHP shop. By the end you'll have a Magento store running on your own machine, you'll know which command does what, and you'll recognise the handful of errors that account for most of the trouble.

**Nothing here reaches a production system.** Everything runs on your machine, the credentials are generated locally and guard nothing, and no step costs money.

## Contents

**Part one — one store, about an hour, most of it waiting:**

- [What you're building](#what-you-are-building)
- [Step 1: the things this cannot supply](#step-1-the-things-this-cannot-supply)
- [Step 2: a hostname that resolves](#step-2-a-hostname-that-resolves)
- [Step 3: a certificate for that hostname](#step-3-a-certificate-for-that-hostname)
- [Step 4: a Magento tree](#step-4-a-magento-tree)
- [Step 5: credentials](#step-5-credentials)
- [Step 6: start it](#step-6-start-it)
- [Step 7: install the store](#step-7-install-the-store)
- [Step 8: look at it](#step-8-look-at-it)

**Part two — when one store is not enough:**

- [A second store](#a-second-store)
- [Snapshots, so the next store takes a minute](#snapshots-so-the-next-store-takes-a-minute)
- [Working on a module](#working-on-a-module)
- [The cluster](#the-cluster)

**Part three — when it goes wrong:**

- [The errors you'll actually meet](#the-errors-you-will-actually-meet)

## What you're building

A Magento store is not one program. It's about twenty containers that have to agree with each other:

| Part | What it does |
|---|---|
| **PHP-FPM** | runs the Magento code. Three pools: storefront, admin, and background work |
| **nginx** | serves files and hands PHP requests to FPM |
| **Varnish** | caches whole pages in memory, in front of nginx |
| **MariaDB** | the database |
| **OpenSearch** | the catalogue search index |
| **RabbitMQ** | a queue, for work that happens later |
| **Valkey** ×2 | one cache, one for sessions. Valkey is a Redis fork; Magento calls it Redis |
| **Consumers** ×6 | processes that take jobs off the queue |
| **Cron** | Magento's scheduler |

**This repository is the description of all of that**, in two forms — a Docker Compose stack and a Kubernetes cluster — from one image and one set of configuration files.

You want the Compose one. It starts in under a minute and it's what you work in day to day. The cluster is for questions Compose cannot be asked, and [The two runtimes](runtimes.md) explains when that's.

## Step 1: the things this cannot supply

**Docker**, with BuildKit and the Compose plugin. Check it:

```bash
docker compose version
```

**A Magento tree.** Nothing here contains Magento, and that's deliberate — see [ADR-006](adr/ADR-006-magento-source-and-licence.md). Step 4 gets you one.

**`mkcert`**, for the certificate in step 3. Your package manager probably has it.

**`envsubst`**, from GNU gettext. Only the cluster runtime needs it.

Now get the repository:

```bash
git clone https://github.com/kingletas/emporion.git
```

```bash
cd emporion
```

## Step 2: a hostname that resolves

The store is served at a hostname, not at `http://localhost:8080`. That's not decoration. **A browser will not store a `Secure` cookie on an origin it does not trust**, and a Magento admin session is a secure cookie — so on a plain loopback address you log in, the session vanishes, and the dashboard never opens. The error message tells you nothing.

You need two things: every `*.test` name to resolve to your Docker bridge, and a reverse proxy on that address routing by hostname.

**The short version, if you have neither.** Add one line to `/etc/hosts`:

```bash
echo '172.17.0.1  vanilla.test mail.vanilla.test' | sudo tee -a /etc/hosts
```

That works for one store. The moment you want a second you'll be editing that file again, which is why the fuller answer is a wildcard DNS resolver — `dnsmasq` with `address=/test/172.17.0.1` — plus `nginx-proxy`, which reads a `VIRTUAL_HOST` label off each container and routes to it. Set that up once and every future store needs no DNS step at all.

> [!NOTE]
> `172.17.0.1` is the default Docker bridge address. Check yours with `ip addr show docker0`. It reaches your machine *and* every container, which is what makes it the right address for both a browser and a container to use.

## Step 3: a certificate for that hostname

```bash
mkcert -install
```

That creates a local certificate authority and tells your system and browsers to trust it. Once.

```bash
mkdir -p certs
```

```bash
mkcert -cert-file certs/vanilla.test.crt -key-file certs/vanilla.test.key vanilla.test
```

`certs/` is gitignored, so nothing you generate here can be committed.

> [!DANGER] There's no wildcard shortcut, and the failure is silent
> A certificate whose only name is `*.test` covers **nothing**. A wildcard may not span an entire top-level domain, so every client rejects it for every host — while every configuration file on disk says TLS is set up.
>
> **Each hostname gets its own certificate or it has none.** If you add `mail.vanilla.test` later, issue one for that too.

## Step 4: a Magento tree

`MAGENTO_SRC` points at a Magento installation. By default it looks for a directory called `commerce-vanilla` **next to** this repository:

```text
somewhere/
├── emporion/            <- you are here
└── commerce-vanilla/    <- the Magento tree
```

Magento comes in two editions. **Magento Open Source** is free and is what this guide uses. **Adobe Commerce** is the paid one; point `MAGENTO_SRC` at it instead and everything here works the same.

Both are installed with Composer from `repo.magento.com`, which needs an account. It's free: sign in at the Magento Marketplace, go to Access Keys, and create a pair. The **public** key is the username and the **private** key is the password.

```bash
cd ..
```

```bash
composer create-project --repository-url=https://repo.magento.com/ \
    magento/project-community-edition=2.4.8-p2 commerce-vanilla
```

Composer will ask for those two keys the first time. This downloads roughly 900 MB and takes a few minutes.

```bash
cd emporion
```

> [!NOTE]
> You don't need to install or configure Magento yourself. Step 7 does that. What you need now is the code and its `vendor/` directory, which is what `create-project` produced.

## Step 5: credentials

```bash
make secrets
```

This generates every password once — the database root password, the store's database password, the RabbitMQ user, the admin password and Magento's encryption key — into `secrets/`, which is gitignored. Files are created readable only by you.

**Run it again and you get the same values back.** That matters more than it sounds: the database volume is created with the password from the first run, so a password that changed on every start would lock the application out of its own database, with an authentication error that says nothing about the cause.

## Step 6: start it

```bash
make compose-up
```

About a minute. It starts the shared data tier first, waits for it to be healthy, then starts the application containers.

The first run also **builds the application image**, which is a different matter — ten to twenty minutes, and it will make the machine slow while it runs. It's compiling Magento's dependency injection code and deploying every static asset into the image, so that the running containers need no writable application directory.

```bash
make compose-status
```

> [!NOTE]
> **Varnish will report unhealthy at this point, and that is correct.** Its health check asks the storefront for a page, and there's no store yet. It goes healthy at the end of step 7.

## Step 7: install the store

```bash
make compose-install
```

Twenty minutes or so from empty. It creates the database schema, loads Magento's default data, creates the admin user, reindexes and clears the caches.

**It decides for itself what to do.** An empty database gets a full install; an already-installed one gets an upgrade. Running it twice is safe. If the database is *unreachable* it retries and then fails — it will never mistake "cannot connect" for "empty", because that mistake would reinstall over live data.

When it finishes it prints the storefront URL and where the admin password is.

## Step 8: look at it

```bash
open https://vanilla.test/
```

The admin is at `https://vanilla.test/admin`, the username is `admin`, and the password is in a file:

```bash
cat secrets/vanilla-test/magento-admin-password
```

Mail is caught rather than sent. Every message the store generates — password resets, order confirmations — goes to a catcher you can read in a browser at `https://mail.vanilla.test/`. Nothing leaves your machine.

Check the whole thing honestly:

```bash
make compose-status
```

```bash
make verify-namespaces
```

The first shows every container and whether it's healthy. The second reads the configuration the running store actually loaded and checks it against the store's config file — the one mistake a healthy-looking store can still be making.

## A second store

```bash
make new-site SITE=second.test
```

That gives you a whole separate store — its own database, its own cache keys, its own search index, its own queue, its own mail — sharing the image, the Magento tree and the data tier with the first one. Issue its certificate first, the same way as step 3.

```bash
make sites
```

**Only one store does background work at a time.** Every store serves, but the consumers and the cron loop belong to whichever one you name:

```bash
make use SITE=second.test
```

The reason is memory. A single store declares up to 14 GiB of ceilings for its background processes, so what has to be limited is not how many stores exist but how many are *working*. [More than one store](sites.md) has the measurements.

```bash
make destroy-site SITE=second.test
```

## Snapshots, so the next store takes a minute

Installing from empty is twenty minutes. Capturing an installed store and restoring it's about one.

```bash
make snapshot NAME=baseline
```

```bash
make new-site SITE=third.test SEED=baseline
```

A snapshot is two files, because a store is two things: the database and the uploaded images in `pub/media`. Capturing only the database looks complete and gives you a catalogue of broken thumbnails.

## Working on a module

By default the store runs the code that's baked into the image, and changing that code means rebuilding — ten to twenty minutes. That's the wrong trade while you're editing a file every few minutes.

```bash
make compose-source SOURCE=mounted
```

Now the Magento tree on disk **is** the code in the container. Edit a file, flush the cache, see the change:

```bash
make compose-cli ARGS="cache:flush"
```

```bash
make compose-source SOURCE=image
```

puts it back.

> [!WARNING]
> A mounted store resembles a real deployment in no way at all — writable application directory, your own user id, developer mode, no compiled dependency injection. **Measure nothing there and ship nothing from there.**

## The cluster

Everything above is Docker Compose. The same store also runs on Kubernetes, from the same image and the same configuration:

```bash
make tools
```

```bash
make up
```

**Never run both at once.** They serve the same hostname on one machine, and running two full Magento stacks will take the machine down. Both `up` commands refuse while the other is present, and that refusal is the feature.

Once it's up, check it:

```bash
make smoke
```

That walks the acceptance criteria and reports each one pass, fail or skip. It doesn't stop at the first failure, because a report of everything that's wrong is worth more than the first thing that's wrong.

The cluster is worth it for questions Compose cannot be asked: what happens when a pod is replaced, whether a storage claim binds, whether a readiness probe measures the thing it claims to, whether a rollout is safe. For everything else, use Compose.

## The errors you'll actually meet

Every one of these has happened here. The message is what you'll see; the cause is rarely what the message suggests.

### `You cannot run this command because modules are not enabled`

**During the image build.** A freshly created Magento tree has no `app/etc/config.php` — that file is written by the installer, so a tree that has been installed once has it and a `composer create-project` tree doesn't.

The build handles this now by running `module:enable --all` first. If you see it, you're on an older build or you're running `bin/magento` by hand against a tree that has never been installed.

### `The configuration file has changed. Run the "app:config:import" command`

**Every storefront request returns 500**, and the message appears on the storefront rather than where you made the change.

Magento stores a hash of one section of its configuration in the database, and refuses to serve when the file no longer matches. It happens after you edit `common.env` or a per-store env file. The fix is to re-run the install, which ends by importing:

```bash
make compose-install
```

### `503 Backend fetch failed`

**Varnish is answering, and the store behind it is not.** Varnish asks the storefront for a health page every ten seconds with a five-second limit, and marks the backend sick after three failures.

The usual cause is that the store is genuinely busy rebuilding configuration — flushing the config cache in developer mode makes that page slow enough to fail the probe. Wait half a minute. **The message says nothing about a cache, which is why it is on this list.**

### `Invalid id or tag '...' : must use only [a-zA-Z0-9_{}]`

**A hyphen in a cache prefix.** Magento rejects it from `bin/magento`'s constructor, so *every* command fails, including the install, with a stack trace naming the id and never the setting.

Store hostnames are turned into prefixes automatically and use underscores for exactly this reason. If you set `MAGENTO_CACHE_PREFIX` by hand, don't put a hyphen in it. `make lint` checks this.

### `ERROR 1045 (28000): Access denied for user 'root'`

**The database volume is older than the credentials.** MariaDB records the root password when its data directory is first created. If the volume survives but `secrets/` doesn't, they no longer match.

It happens when a store is removed in a way that leaves its data behind. Remove both:

```bash
docker compose -p magento-data down --volumes
```

then `make secrets` again.

### A TLS failure on a host that "has a certificate"

You have a `*.test` wildcard. It covers nothing — see step 3. Issue one per hostname.

### `no secrets/ yet`

You ran `make check` or `make lint` on a fresh clone. The Compose files read files that `make secrets` writes:

```bash
make secrets
```

## Where to go next

- [Getting started](getting-started.md) — the same ground, condensed, for when you've done it once
- [The two runtimes](runtimes.md) — Compose or the cluster, and getting code into a running store
- [More than one store](sites.md) — what keeps two stores out of each other's data
- [Running it](operations.md) — every command, the checks, and debugging
- [Configuration](configuration.md) — every setting and where it lives
- [How it's put together](architecture.md) — and [the decisions](adr/) behind it
