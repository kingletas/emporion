# Getting started

What you need, how to bring a store up, and how it gets installed.

## Contents

- [Getting started](getting-started.md#quick-start)
- [Installing the store](#installing-the-store)

---

## Quick start

Two prerequisites this repository cannot supply: Docker, and the Magento tree at `MAGENTO_SRC`.

The Compose stack is the shorter path and needs no extra tooling:

```bash
make compose-up
```

```bash
make compose-install
```

Both default to `vanilla.test`. Every site command takes a hostname either way round:

```bash
make compose-up SITE=second.test
```

```bash
make compose-up second.test
```

> [!warning] The bare word is made to work; it isn't free
> A bare word is a second *goal* to Make, not an argument — so `make destroy-site second.test` originally ran `destroy-site` against whatever `SITE` defaulted to and only then failed looking for a rule to build `second.test`. **On a destructive target that meant offering to delete a different store than the one named.**
>
> A single `<name>.test` goal is now bound to `SITE` and consumed, saying it twice is an error rather than a guess, and **`destroy-site` and `compose-destroy` refuse to run on the default at all** — they require the store to be named. A `--flag` is a second goal for the same reason and is not rescued: `MODE=exclusive` is the spelling.

Then `https://vanilla.test/`. No `/etc/hosts` line is needed — dnsmasq already sends every `*.test` name to `172.17.0.1`, where `nginx-proxy` terminates TLS.

> [!danger] A `*.test` certificate covers nothing, and the failure is silent
> A wildcard may not span an entire top-level domain. So a certificate whose only name is `*.test` is refused by every client for every host, while every configuration file on disk says TLS is set up.
>
> Measured in isolation — one certificate, one throwaway listener, a real client — so nothing else can be the cause. A host present in the certificate's SAN list verified and returned 200; a host covered only by the `*.test` entry failed the TLS handshake outright:
>
> ```text
> curl --resolve covered.test:18443:127.0.0.1     https://covered.test:18443/     200
> curl --resolve wildcard.test:18443:127.0.0.1    https://wildcard.test:18443/    TLS failure
> ```
>
> **The explicit names verify and the wildcard never matches anything**, which is exactly why a shared wildcard file can look like it's working for years.
>
> **So each host gets its own certificate or it has none.** `make new-site` issues one for the site and for its mail host, and `cluster-up.sh` prints the `mkcert` command rather than substituting a certificate no client accepts. **Measured with OpenSSL and curl** — a browser wasn't put in front of a wildcard-only host, so that part is reasoning from the rule rather than a measurement.


## Installing the store

The database starts empty in both runtimes, which is the point: this store is installed, never imported.

```bash
make compose-install      # Compose
```

```bash
make deploy               # cluster — the install Job runs as part of it
```

**Both run the same script.** `magento-install` lives in the image at `/usr/local/bin/magento-install`; the cluster runs it as `Job/magento-install` and Compose runs it as a one-shot service. Writing the install once is the whole point — an install that behaved differently depending on which runtime performed it's a difference nobody would think to look for.

It's **idempotent**, and decides for itself:

| Database state | What it does |
|---|---|
| empty | `setup:install`, every parameter passed explicitly, then `app:config:import` |
| installed | `setup:upgrade --keep-generated`, then `app:config:import` |
| **unreachable** | **retries, then fails** — see below |

**The third state is why this is not a one-liner.** An unreachable database must never read as an empty one: that mistake turns a transient network failure into an attempted reinstall over live data. It retries for `DB_WAIT_SECONDS`, then dies saying exactly that.

**Every `setup:install` parameter is passed explicitly**, including `--key`. That's what keeps the install from depending on the `env.php` the entrypoint wrote, so the two can never disagree — and because the crypt key is *ours* rather than a generated one, the `env.php` regenerated on the next container start still decrypts everything the install encrypted.

> [!warning] Changing the shared config is a deploy, not a restart
> Magento hashes the `system` section of `env.php` and **refuses to serve** when it changes without being re-imported. Every storefront request returns 500 with *"The configuration file has changed. Run `app:config:import`"*, and it does so on the storefront rather than at the point of the edit.
>
> After editing `k8s/base/config/env/common.env` — or anything the entrypoint writes into that section — rebuild if the image changed and then run `make compose-install` or `make deploy`. Both end in `app:config:import`.
>
> **It fails loudly, which is the good case.** What wasn't loud is that `health_check.php` kept returning 200 throughout, so the Varnish container reported itself healthy while the whole storefront was down. That probe asks for the storefront now.

### Sample data

```bash
make sample-data
```

**It needs `repo.magento.com` credentials and says so rather than half-running.** The sample data packages are on Adobe's private Composer repository, so the target checks for `commerce-vanilla/auth.json` first and exits with a named error naming the file and the Access Keys it wants.

**It is a build-time step, not a runtime toggle.** Sample data arrives as Composer packages, so it lands in `vendor/` — and `vendor/` only reaches a container by way of the image. The target modifies the tree; `make image` and another install are what put it in the store, and the script says so when it finishes.

**It restores the tree to `--no-dev` afterwards, and that is not tidying.** `sampledata:deploy` runs a plain `composer require`, which reinstates every `require-dev` package as a side effect — phpunit, Codeception, php-cs-fixer, phpstan and the functional testing framework, about 180 MB. The tree is the build context for the runtime image and the builder uses a staged `vendor/` as it finds it, so leaving them there ships a test harness and a webdriver inside a production image.
