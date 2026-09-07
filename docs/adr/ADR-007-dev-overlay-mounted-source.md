---
adr: 007
status: accepted
date: 2026-08-24
---

# ADR-007 — The dev overlay mounts the working tree

> [!info] Status
> **Accepted.** Revisit if the dev overlay ever becomes the one people treat as the real thing. That is the failure this decision is most exposed to, and it would not announce itself.

## Context

An immutable image and a live-edited application tree are directly opposed, and editing Magento in place is how the work actually gets done — a module changed and reloaded in the browser, not a module changed and then built.

**Nothing in Kubernetes reproduces that**, and the risk is worth stating plainly: pretending otherwise is how a local environment quietly stops resembling the thing it models.

The open question it leaves is whether building a development overlay at all undermines the self-contained image, or whether having both is the point.

## Decision

**Build both, explicitly, and make them visibly different.**

The `dev` overlay replaces `/app` with a `hostPath` mount of the working tree, sets `MAGENTO_MODE=developer`, and mounts a PHP ini that puts `opcache.validate_timestamps` back to 1 — because the image sets it to 0, which is correct for immutable code and would silently ignore every edit against a mounted tree.

**It is the only thing in this repository that mounts source.** The `prod-shaped` overlay and the Compose runtime both carry the code inside the image; see [ADR-008](ADR-008-two-runtimes-one-image.md).

The `prod-shaped` overlay refuses every one of those: code from the image only, `readOnlyRootFilesystem`, `runAsNonRoot`, all capabilities dropped, `MAGENTO_REQUIRE_COMPILED=true`, and two replicas of the storefront pools.

**The overlay boundary is where the honesty lives.** Being able to say why the two modes are different, and what each one costs, is worth more than making either one perfect.

## Alternatives

### Drop the dev overlay; build an image for every change

**Advantages** — One mode. No hostPath anywhere. The image is unambiguously the only source of code, and nothing in the repository can be mistaken for a production pattern.

**Disadvantages** — Makes the environment unusable for the work it is meant to support. A one-line change costing a full image build and roll is not a development environment; it is a deployment pipeline with no development in front of it. It also removes the ability to *compare* the two modes, which is where the understanding is.

### Use a file-sync tool (Skaffold, Mutagen, Tilt) instead of a hostPath

**Advantages** — Works on multi-node and on remote clusters. The pattern real teams use for exactly this problem.

**Disadvantages** — A fourth binary and a sync daemon whose failure modes — a file that did not sync, a partial write — are indistinguishable from application bugs. On a single-node cluster where a hostPath is available and exact, that is a lot of machinery to reproduce a bind mount.

### Run the storefront under Compose and only the data tier on Kubernetes

**Advantages** — Keeps the working development environment untouched.

**Disadvantages** — Makes the environment unusable for the work it exists to support. The interesting problems are all in the application tier.

> [!important] The near miss was dropping the dev overlay, and the reason it lost is also the reason it is dangerous
> A single prod-shaped mode would be a cleaner artefact. The dev overlay exists because the environment has to remain usable — and the risk it carries is that it is *nicer to use*, so it becomes the one everybody runs, and what gets reasoned about is a hostPath mount with a Kubernetes accent. The mitigation is that `prod-shaped` is the default for anything being measured or verified, and the overlay names say which is which without needing a footnote.

## Consequences

- **`cluster/kind-config.yaml` carries one host path in `extraMounts`, and it is `${MAGENTO_SRC}` rather than a literal.** `scripts/cluster-up.sh` substitutes it before kind reads the file, so the mount follows the same variable the image build uses and there is nothing here for a reader to edit. The path is still machine-specific at cluster-create time, which is unavoidable for a hostPath overlay — kind resolves it once, and a wrong one produces pods that start with no Magento in them rather than an error naming the mount.
- **The dev overlay is single-node-only and unportable, by construction.** Same limit as [ADR-003](ADR-003-shared-media-strategy.md), for the same reason, and it is fine here because the overlay is not claiming to be anything else.
- **A pod in this overlay must never write into the tree it mounts.** That tree is the build input for the runtime image and for the Compose stack, so `var/`, `generated/` and `env.php` are all container-local or shadowed here. A developer-mode pod regenerating interceptors into the source would mean the next image is built from something nobody chose.
- **The `dev` image target contains no application code at all.** That is what makes the overlay boundary enforceable rather than conventional: running the dev image without the dev overlay produces a pod with an empty `/app`, which fails immediately instead of subtly.

## Related

- [ADR-004](ADR-004-image-build-strategy.md) — the immutable image this exists in tension with
- [ADR-003](ADR-003-shared-media-strategy.md) — the same single-node limit
- `k8s/overlays/dev/`
