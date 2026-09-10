---
adr: 004
status: accepted
date: 2026-08-24
---

# ADR-004 — Image build strategy, and what it drops

> [!info] Status
> **Accepted.** Revisit when the SourceGuardian loader problem is fixed upstream, or when the source moves to Magento Open Source — either removes the exclusion this decision exists to record.

## Context

The goal is one image per commit containing application code, `vendor/`, `generated/` and compiled static content — built once, run everywhere. Before this decision there was no application image at all: the tree was bind-mounted live and the PHP images were build variants of one Dockerfile differing only in whether Xdebug was installed.

An immutable image requires a successful compile at build time, and the compile scans all of `vendor/` regardless of whether a module is enabled — so a single package that cannot be compiled fails the whole build and disabling its module changes nothing.

**That was a live blocker when this decision was written.** The Magento tree this repository was originally built against contained a SourceGuardian-encoded third-party package built for an older PHP, which died during repository code generation with `SourceGuardian Loader ... Error code [16]`.

**It is closed.** `commerce-vanilla` contains no encoded package and nothing that fails to compile; `setup:di:compile` completes in about 50 seconds and `COMPILE_EXCLUDES` is empty. The mechanism below stays anyway, because the next dependency that cannot be compiled should be excluded loudly rather than worked around silently.

This is a defect that has nothing to do with Kubernetes, and it blocks the whole build. There are three ways past it: build against a tree that doesn't contain the package, exclude it at build time and accept a divergent image, or fix the loader — which is out of scope here.

## Decision

**Build a multi-stage image with four targets**, and make the exclusion an explicit, printed, recorded build argument rather than a silent workaround.

- `php-base` — extensions and loaders. No application, no composer, no Xdebug. Shared by every other target, so the runtime surface is provably identical between the development pool and the production-shaped one.
- `dev` — `php-base` plus Xdebug and composer, and **no application code**: the dev overlay mounts the working tree. See [ADR-007](ADR-007-dev-overlay-mounted-source.md).
- `builder` — runs `composer install`, removes the packages named in `COMPILE_EXCLUDES`, then `setup:di:compile` and `setup:static-content:deploy`.
- `runtime` — `php-base` plus the built `/app`. The default target, and the one that ships.

`COMPILE_EXCLUDES` is **empty**, which is the goal state. When it isn't, the build **prints what it is removing**, writes the list to `/app/var/.compile-excludes` inside the image, and the entrypoint prints it again at container start.

`SKIP_COMPILE=true` exists so the manifests can be iterated on before any of this is settled. An image built with it carries a marker file, and the prod-shaped overlay sets `MAGENTO_REQUIRE_COMPILED=true` so the entrypoint **refuses to start it**.

## Alternatives

### Fix the SourceGuardian loader

**Advantages** — Removes the problem instead of routing around it. The image would then contain everything `composer.lock` names.

**Disadvantages** — Required a vendor to ship a build for the PHP version in use, which is the vendor's decision and not one this repository can make. A licence and supply question wearing a technical costume.

### Keep the package and skip `di:compile` entirely, running in developer mode

**Advantages** — Nothing to exclude; the image contains exactly what `composer.lock` resolves to.

**Disadvantages** — Abandons the self-contained image, which is the point of building one at all. Developer mode generates interceptors at runtime into `generated/`, which puts a writable shared directory back — undoing [ADR-003](ADR-003-shared-media-strategy.md) as a side effect. The two decisions are coupled, and this option unpicks both.

### Bake `generated/` from a compile run elsewhere and copy it in

**Advantages** — Sidesteps the failing compile without removing anything.

**Disadvantages** — There was no *elsewhere*: the compile failed in the only environment that had the source. It also produces an image whose `generated/` doesn't correspond to its `vendor/`, which is a worse failure than a missing package because it's invisible until a specific interceptor is needed.

> [!important] Excluding a package makes the image diverge from what `composer.lock` says it is, and that's the cost
> Whatever the excluded package does is simply absent — and absent in a way that will look like an infrastructure problem when someone hits it, because nothing in the runtime says a package was removed. That's why an exclusion is printed at build time, written to `/app/var/.compile-excludes` inside the image, and printed again at container start. **A workaround nobody can see is indistinguishable from a bug.**
>
> Nothing is excluded today. This is the mechanism waiting for the next package that needs it, not a description of the current image.

## Consequences

- **Two things the production release process carries have nowhere to live, and are dropped rather than translated:**
    - **`custom_files`** — hand-placed per-release artifacts. There's no per-release hand placement step in an immutable-image model.
    - **The patch library** — 201 hotfixes with apply and revert parity. In this model patches are applied at build time, and reverting one means redeploying the previous image. **That is a capability change, not a like-for-like translation**, and it's the single most consequential thing this decision gives up. Reverting one patch independently of everything else in the release is not possible here.
- **A deploy now depends on a build.** Under Compose, changing a file changed the running application. Here it changes nothing until an image is built, loaded and rolled. That's the point, and it's also the thing that will feel worst in daily use — which is what [ADR-007](ADR-007-dev-overlay-mounted-source.md) exists to answer.
- **Acceptance criterion A7 cannot be fully met and the repository says so.** Two builds from one commit don't produce the same digest: the base image is a moving tag, apt pulls whatever the mirror has, and every layer carries a timestamp. `scripts/verify-image.sh` checks the part that's achievable — that the *application content* of two builds is identical — and its header states plainly what it isn't checking and why.
- **No registry.** kind loads an image straight from the local daemon. Introducing a registry for a single-node local cluster would be scope invented to fill a section.

## Related

- [ADR-003](ADR-003-shared-media-strategy.md) — decided together with this one
- [ADR-006](ADR-006-magento-source-and-licence.md) — the source question whose answer removes the exclusion
- [ADR-007](ADR-007-dev-overlay-mounted-source.md) — the answer to what this costs day to day
- `build/Dockerfile`
