# The two runtimes

A kind cluster and a Compose stack, deploying the same image from the same configuration. Which one to reach for, how a code change gets into a running store, and what the two cluster overlays differ on.

## Contents

- [Which runtime, and when](#which-runtime-and-when)
- [Two sources: the image, or the working tree](#two-sources-the-image-or-the-working-tree)
- [The two cluster overlays](#the-two-cluster-overlays)

---

## Which runtime, and when

|  | Compose | kind cluster |
|---|---|---|
| Start it | `make compose-up` | `make up` |
| Time to a serving storefront | under a minute | several, plus a cluster |
| Reaches `vanilla.test` via | `nginx-proxy` on `172.17.0.1` | ingress on `127.0.0.1`, needs `/etc/hosts` |
| Publishes a host port | no | 80 and 443, on loopback only |
| Application code | in the image | in the image, or a `hostPath` under the `dev` overlay |
| Scheduled work | a `cron:run` loop in a container | two `CronJob` objects, one per group |
| Consumers | six services | six `Deployment` objects |
| Extra tooling needed | none | `kind`, `kubectl` |
| **How many stores at once** | **as many as fit** — `make new-site` | one; there's no second port for a second host |
| Good for | running the store, day to day | the orchestration questions — probes, claims, rollout, scaling |

**Compose is the one to work in. The cluster is the one that answers questions Compose cannot be asked.** Neither is a toy version of the other: they run the same image, and a bug that appears in one appears in both.

---


## Two sources: the image, or the working tree

**A code change reaches a running store either by rebuilding the image or by not being in the image at all**, and `make compose-source` chooses which:

```bash
make compose-source SOURCE=mounted
```

```bash
make compose-source
```

**`image` is the default, and it is what ships.** It's what the cluster runs, what the prod-shaped overlay runs, and what `verify-image` hashes. Nothing about it changes.

**`mounted` is for developing a module.** `${MAGENTO_SRC}` is bind-mounted at `/app`, the store runs in **developer mode**, and the containers run as the host user. An edit on disk is live in the container; a `cache:flush` is usually the whole deployment step. It's the Compose equivalent of `k8s/overlays/dev`, and `docker-compose.dev.yaml` carries the same four decisions that overlay documents.

> [!danger] Why this exists, and it isn't convenience
> A full `compose-build` re-runs composer, `setup:di:compile` and a static-content deploy and then exports a 1.5 GB image — **ten to twenty minutes, with enough concurrent PHP to make this workstation unusable while it runs.** Paying that to change one line of a module is the wrong trade during development, and paying it repeatedly takes the machine down. The image path is proven; it doesn't need re-proving on every edit.

**It is a property of the SITE, not a flag on a command**, written into the site's env file as `SITE_SOURCE`. That's deliberate and it's the same reasoning `SITE_MODE` carries, with a sharper consequence: **every `docker compose` invocation has to agree about which files the project is made of.**

One that omitted the overlay would see a different desired state and *recreate the containers without the mounts* — so a `make compose-cli` with a forgotten flag would silently put a mounted site back on the image, mid-session, with nothing to say it had happened. `dc()` in `scripts/lib.sh` is the single place that assembles the file list.

**Four things a bind mount at `/app` breaks, and what is done about each:**

- **`var/`, `pub/` and `pub/media` are seeded from the image with the image's ownership.** Left alone, a container running as the host user gets three directories it cannot write — and Magento's failure for that's a 500 with nothing in the log, because the log is one of them. The overlay mounts the tree's own directories on those targets instead; a volume cannot be removed by an overlay, only overridden.
- **`app/etc/env.php` is a symlink to a tmpfs inside the image**, and mounting the tree replaces it with whatever the tree has. A file under `secrets/<site>/` is bind-mounted over it, so the container writes its credentials and service names there and the tree stays the clean source the image is built from — the same shadow the cluster overlay makes with an emptyDir.
- **Nothing in a container trusts this machine's mkcert CA**, so PHP calling another `https://*.test` stack fails with *unable to get local issuer certificate*. The overlay mounts the image's own bundle with the mkcert root appended. **The environment variable is not enough**: libcurl reads `CURL_CA_BUNDLE` and the `curl` binary honours it, but PHP's curl extension sets `CURLOPT_CAINFO` from `curl.cainfo` and ignores the environment — so an ini file is mounted as well. The symptom without it's a container where `curl https://…` works and the identical request from PHP doesn't.
- **Developer mode is the point rather than a detail.** In production mode a new module needs `setup:di:compile` before a single request works. In developer mode Magento generates each interceptor and factory on demand: the first request after a change is slow, and nothing else is.

**Two things a mounted site does that a real one does not**, both worth knowing before measuring anything:

- **Flushing the config cache takes the store out of Varnish's rotation for about half a minute.** The backend probe hits `/health_check.php` every 10s with a 5s timeout and needs 3 of the last 5 to pass; rebuilding the configuration in developer mode makes that endpoint slower than 5s, so the probe fails, the backend is marked sick, and every request is answered with a **503 that says "Backend fetch failed" and nothing about a cache.**
- **Varnish is not purged by `cache:flush`.** A page whose content changed keeps being served from the edge until Varnish is restarted or the object expires, so a rendered check that reads through `https://<site>` can be looking at the previous build.

> [!] **`rm -rf var/cache` does nothing here, and that is not obvious from a mounted tree.** The cache backend is Valkey, so the only way to clear it's `cache:flush` — and a `di.xml` change that `bin/magento` cannot boot past leaves you unable to run even that. The symptom is every command failing with something about the *new* class, such as *"cannot have an empty name"* for a console command whose name is a DI argument. `docker exec magento-data-valkey-cache-1 valkey-cli FLUSHALL` is the way out.

**It resembles production in no way at all** — writable root, host uid, developer mode, no compiled DI. Measure nothing here and ship nothing from here. `make compose-source SOURCE=image` puts it back, and recreating the containers is the whole cost.


## The two cluster overlays

```bash
make deploy OVERLAY=dev           # default
make deploy OVERLAY=prod-shaped
```

|  | `dev` | `prod-shaped` | Compose |
|---|---|---|---|
| Application code | `hostPath` mount of the tree | in the image | in the image |
| Root filesystem | writable | `readOnlyRootFilesystem` | `read_only: true` |
| Capabilities | default | all dropped | all dropped |
| opcache | revalidating every request | `validate_timestamps = 0` | `validate_timestamps = 0` |
| Xdebug | installed, off, switchable per pod | not in the image | not in the image |
| Compiled image required | no | yes — the entrypoint refuses an uncompiled one | no, but it gets one |
| Storefront replicas | 1 | 2 | 1 |

An immutable image and a live-edited tree are directly opposed, and editing Magento in place is how the work actually gets done. **The `dev` overlay is the only thing here that takes the second side.** [ADR-007](adr/ADR-007-dev-overlay-mounted-source.md) records the trade and the risk it carries.

---
