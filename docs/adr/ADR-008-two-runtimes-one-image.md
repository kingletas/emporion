---
adr: 008
status: accepted
date: 2026-08-27
---

# ADR-008 — Two runtimes, one image

> [!info] Status
> **Accepted.** Revisit if the two ever need different images, which would be the signal that this has stopped paying for itself.

## Context

This repository was a Kubernetes deployment and nothing else. Running the store meant creating a kind cluster, loading an image into it, applying an overlay and waiting — several minutes, plus `kind` and `kubectl` installed, before a storefront answers. That cost is worth paying for the questions a cluster is uniquely good at asking: what happens when a pod is replaced, whether a claim binds, whether a probe is measuring the thing it claims to measure, whether a rollout is safe.

It is not worth paying to look at a page.

Adding a Compose stack is the obvious answer and it carries an equally obvious risk: **two environments that drift**. That is the failure the Magento estate already knows well — an environment that behaves one way locally and another way in the thing it is supposed to resemble, with nothing anywhere saying which is right. Two runtimes with two images, two configuration files and two sets of credentials would be a worse position than one runtime and a slow feedback loop.

## Decision

**Add the Compose runtime, and make drift structurally impossible rather than a thing to be careful about.**

Four things have exactly one copy, and each is a place the two could otherwise disagree:

| Shared | Where it lives | How both reach it |
|---|---|---|
| The application image | `build/Dockerfile`, target `runtime` | Compose builds it; `build-image.sh` builds it and loads it into kind |
| Non-secret configuration | `k8s/base/config/env/common.env` | kustomize `configMapGenerator: envs:`; Compose `env_file:` |
| Credentials | `scripts/secrets.sh` → `secrets/` | k8s Secrets; `compose-*.env` fragments beside them |
| nginx, Varnish, MariaDB config | `k8s/base/config/files/` | ConfigMaps; bind mounts |

**The service names are what make it work.** Every Compose service is named after the Kubernetes Service doing the same job. The Varnish VCL names `web`, `web-admin` and `web-cron` as backends; the nginx template resolves `${FASTCGI_BACKEND}`; `magento-entrypoint` defaults to `db`, `opensearch`, `rabbitmq`, `valkey-cache` and `valkey-session`. Because Compose and Kubernetes both provide service DNS under those names, **every one of those files is used unmodified in both**. Rename a service and one of them has to fork, which is the exact moment the two stop being comparable.

**The Compose stack is prod-shaped, not a third mode.** Read-only root filesystems, all capabilities dropped, no source bind-mount, code in the image. There are already two modes — `dev` and `prod-shaped` — and the interesting comparison is between *those*. A Compose stack that mounted source would have made three, with the third being a duplicate of the first.

**They never run together, and both `up` paths refuse.** `cluster-up.sh` checks for containers carrying the Compose project label; `compose-up.sh` checks for the kind cluster. Two MariaDB instances, two OpenSearch JVMs and two PHP pools each allowed 4 GiB do not fit on a 31 GB laptop that is also running an editor and a browser, and the way that failure presents is a load average in the hundreds with swap exhausted.

**The guard checks the compose project LABEL, not a container-name prefix.** A name prefix misses a container started with `--name` and catches unrelated containers that happen to begin with the same word.

## Alternatives

### Cluster only, as before

**Advantages** — One runtime, one set of manifests, nothing to keep in step. No possibility of the two drifting apart.

**Disadvantages** — Every trivial look at the store costs a cluster. In practice that means the store gets looked at less, which is the opposite of what a development environment is for. It also makes the cluster carry two jobs — being the interesting artefact and being the daily driver — and being the daily driver is what erodes an artefact.

### Compose only, dropping Kubernetes

**Advantages** — Simplest. Fastest. No second toolchain.

**Disadvantages** — Deletes the entire reason this repository exists. Compose cannot be asked what happens when a pod is replaced, whether a claim binds, or whether a rollout is safe, because it has no pods, no claims and no rollouts.

### Both, but with separate images and configuration

**Advantages** — Each runtime tuned freely for itself. No shared file constrains either.

**Disadvantages** — This is the drift failure, adopted deliberately. The first divergence is always defensible and the tenth is a second environment nobody trusts. Rejected outright; the sharing above is not an optimisation, it is the point.

## Consequences

- **A change to a shared file changes both runtimes.** That is the intent, and it means the blast radius of editing `common.env` or the VCL is larger than it looks. `make lint` renders both.
- **`verify-consumers` now compares three sets**, not two: the declared list, the cluster Deployments, and the Compose services. A queue present in two of the three is the silent failure it always was, with one more place to go missing.
- **One VCL means one purge ACL for two IP ranges** — the kind pod CIDR and the Docker bridge range. A purge refused by the ACL shows up as a storefront that never updates and as nothing else.
- **Compose has no scheduler**, so `magento-cron` is a `cron:run` loop in a container where the cluster has two `CronJob` objects, one per group. This is the one place the two runtimes genuinely differ in shape rather than in configuration, and it is a difference in the runtime rather than in the application — which is exactly the kind this design is meant to expose.
- **The edges differ and the hostname does not.** Compose reaches `vanilla.test` through the shared `nginx-proxy` on `172.17.0.1` and publishes no port; the cluster binds `127.0.0.1:80` and takes the name with one `/etc/hosts` line. Switching is a one-line change, which is what makes refusing to run both an easy rule to keep.

## Related

- [ADR-005](ADR-005-varnish-stays-in-the-chain.md) — the edge both runtimes share
- [ADR-007](ADR-007-dev-overlay-mounted-source.md) — the other mode split, and the one this deliberately does not add to
- `docker-compose.yaml`, `scripts/compose-up.sh`, `scripts/lib.sh`
