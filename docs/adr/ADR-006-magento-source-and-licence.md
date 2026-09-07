---
adr: 006
status: accepted
date: 2026-08-24
updated: 2026-08-27
---

# ADR-006 — Magento source and licence posture

> [!info] Status
> **Accepted, and materially revised on 2026-08-27** when this repository was repointed at a Magento tree of its own. The original decision — *develop against an existing on-disk webroot, publish against Open Source* — is superseded. The publication precondition below is not.

## Context

The store is `commerce-vanilla`, a sibling of this repository: a fresh Adobe Commerce 2.4.7-p7 tree in its own repository, installed from empty by this one. Two facts about it drive everything here.

**It contains no application of anyone's.** No custom modules, no business rules, no store-specific routing, no data. That removes at a stroke the reason the earlier version of this decision existed — this repository no longer builds an image from a tree that cannot be disclosed, and the boundary it spent most of its length policing is now a boundary between two directories that both belong to this work.

**It is still Adobe Commerce, and Adobe Commerce is licensed.** Its packages come from an authenticated `repo.magento.com`, so someone else cannot build this from a clean checkout however public the manifests are. **Magento Open Source remains the only thing that can be.**

A third fact is worth recording because it closed a problem rather than opening one. **The compile failure this decision used to share an answer with is gone.** `setup:di:compile` failed on a SourceGuardian-encoded third-party extension present in the tree this was originally built against. Nothing in a stock Magento `vendor/` is encoded and nothing in it fails to compile, so `COMPILE_EXCLUDES` is empty — which [ADR-004](ADR-004-image-build-strategy.md) named as the goal state and can now record as reached.

## Decision

**The source stays a build parameter, and never a hardcoded path.**

`MAGENTO_SRC` defaults to a `commerce-vanilla` tree beside this repository and is passed to the build as a BuildKit named context. One environment variable builds the same manifests, and the same Compose stack, against a different tree. That was the right shape when the default was an existing webroot and it's still the right shape now that it isn't.

**Nothing in `k8s/`, `build/` or `docker-compose.yaml` names any particular store's application**, and that survives the move as a property to preserve rather than a cleanup to perform:

- The consumer list is **core Magento queues only**. Anything site-specific is added through the shared env file and an overlay, which is the correct layering regardless.
- `config/files/nginx/magento.conf` carries no multisite `MAGE_RUN_CODE` map and no store-specific rewrite table. Those are business routing, not infrastructure.
- The Varnish VCL was written for this deployment rather than copied from one.
- No credential, key or certificate is **committable** from this directory. `CERTS_HOME` defaults to `certs/` inside the repository and `secrets/` sits beside it; both are gitignored, and `make scan` asks git rather than trusting the paths — it failed once on a `certs/` pattern that didn't match a symlink.

**Publishing remains a separate, deliberate act with a precondition**: the repository has to build and run against Magento Open Source, on a clean checkout, using only the documented commands. Adobe Commerce being the development target makes this more necessary rather than less — an authenticated Composer repository is a harder barrier than an unfamiliar directory layout.

**That was done on 2026-09-07 and the precondition is met.** A clean checkout, a `magento/project-community-edition` 2.4.8-p2 tree created from empty beside it, and `make new-site SEED=none` unattended to a storefront answering 200 over TLS, an admin answering 200, every namespace verified against the running `env.php`, the consumer sets agreeing, and `X-Cache: HIT` from the edge.

**It took four attempts and found four defects, none of which any gate here could see** — the image build required an already-installed Magento tree, `MODE=exclusive` silently built a shared store, the from-empty install never imported its configuration so the storefront returned 500, and this repository's own documentation stated the `app/etc/config.php` premise backwards. Every one of them was invisible while the only tree ever built against had been installed once already.

## Alternatives

### Run Magento Open Source here instead

**Advantages** — The publication question disappears entirely. Anyone could clone and build. Smaller image, faster compile, no `auth.json` for sample data.

**Disadvantages** — It isn't the store being run. The point of this repository is to run *this* store, and this store is Adobe Commerce: EE-only modules, EE data patches, the EE admin. An environment that cannot run what it's meant to run has optimised for a property nobody asked for. Open Source stays the **publication** target, which is a different question from the **development** target and is answered separately above.

### Vendor the Magento tree into this repository

**Advantages** — Self-contained. One clone, one build.

**Disadvantages** — Puts licensed source into this repository's history, where removing it later doesn't remove it. It also welds the runtime to one version of the application, which is exactly what `MAGENTO_SRC` exists to avoid. This is the option that looks tidy and is not.

### Keep the old posture and carry on developing against the existing webroot

**Advantages** — No move, no rewrite, no new store to install.

**Disadvantages** — Every change to the runtime risked touching a working environment that other work depends on, and the whole publication boundary had to be maintained by hand and by memory. The failure mode was *forgetting which mode you're in*, and it was invisible until the first push to a remote. Moving to a store of its own deletes the failure mode rather than guarding against it.

## Consequences

- **`make sample-data` cannot work without `repo.magento.com` credentials**, and it says so with a named error rather than half-running. That's this decision's most visible day-to-day cost, and it's the licence showing through.
- **`make scan` is a real gate, not decoration.** It fails on credential-shaped strings, on key material inside the directory, and if `secrets/` stops being ignored.
- **The repository-local `.gitignore` is still load-bearing, for a shorter list of reasons.** `core.excludesFile` points at `~/.gitignore`, a Magento project's list: its `*.sh` rule would exclude every script here and its `docker-compose.yaml` rule would exclude the Compose runtime. The `*.json`, `*.php` and `*.cnf` negations the old parent repository required are gone, because that parent is gone.
- **The licence file is committed**, which it could not honestly have been before the precondition was met.

## Related

- [ADR-004](ADR-004-image-build-strategy.md) — the compile problem, now closed
- [ADR-008](ADR-008-two-runtimes-one-image.md) — why one image serves both runtimes
- `scripts/scan-secrets.sh`, `scripts/sample-data.sh`, `.gitignore`
