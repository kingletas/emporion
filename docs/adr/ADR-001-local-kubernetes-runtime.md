---
adr: 001
status: accepted
date: 2026-08-24
---

# ADR-001 — Local Kubernetes runtime

> [!info] Status
> **Accepted.** Revisit if this ever needs more than one node — which it will, the moment ADR-003's media claim is tested honestly. A single-node cluster is the right tool for everything up to that point and the wrong tool immediately after it.

## Context

This needs a Kubernetes cluster on a laptop that also has to run the Compose stack in this same repository. Three things constrain the choice and none of them is about Kubernetes features.

The host runs at roughly 20 of 31 GB with swap engaged before anything here starts. The Compose stack declares about 16.5 GiB of limits against that. Whatever runs the cluster runs inside the same Docker host, so the ceiling doesn't move — but a scheduler will overcommit happily where Compose simply failed to start a container.

The second constraint is what the cluster is for. The problems worth solving here are Magento's — shared media, build-time compilation, cache invalidation through an edge — not the cluster runtime's. A runtime unusual enough to need its own troubleshooting spends the budget on the wrong thing.

The third is fidelity. This exists to model how Magento behaves on Kubernetes, so behaviour observed here has to mean the same thing on any other cluster. A runtime that differs from upstream makes every observation conditional on the runtime.

## Decision

Use **kind**, single node, configured from `cluster/kind-config.yaml`, with the ingress controller published on the host's 80 and 443 through `extraPortMappings`.

Install it into `~/bin` alongside `kubectl` with `make tools`, which is the only target in the repository that downloads anything.

## Alternatives

### k3d

**Advantages** — Lower memory overhead than kind, meaningfully so on a constrained host. Ships with Traefik as an ingress out of the box, so there's one fewer install step. Faster cluster creation.

**Disadvantages** — k3s is not upstream Kubernetes. It replaces etcd with SQLite, bundles a different ingress, and drops components a stock cluster has. Every one of those differences makes an observation here conditional: a probe that behaves one way on k3s has not been shown to behave that way anywhere else, and this repository exists precisely to answer that kind of question.

### minikube

**Advantages** — The most documented option, an addon system that would supply metrics-server and an ingress with one command.

**Disadvantages** — Heaviest of the three, and its default driver runs a VM rather than a container, which puts another memory allocation between the host and the workloads on a host that has none to spare.

### Docker Desktop's built-in cluster

**Advantages** — Nothing to install.

**Disadvantages** — Not present on this machine; Docker Engine is installed directly. Not an option rather than a rejected one.

> [!important] k3d was the near miss, and it lost on fidelity rather than on merit
> On a host this constrained, k3d is the better engineering choice and the memory argument is real. It lost on fidelity: kind runs upstream Kubernetes, so what happens here is what happens anywhere. On k3s, every finding carries a footnote about which difference might be responsible — and a local model whose findings need footnotes is not doing the job it was built for.

## Consequences

- **Single node means `ReadWriteMany` is satisfied by geography, not by a filesystem.** ADR-003 depends on this and says so. The media claim works because every pod lands on the same node, and it will stop working the moment there's a second one. That's a limitation to state, not to hide.
- **The ingress controller has to be installed by hand**, unlike k3d. `make tools` caches the manifest so a rebuild doesn't need the network.
- **80 and 443 on the host are claimed by the cluster while it is up**, on `127.0.0.1` only. The Compose runtime therefore publishes no port at all and reaches the same hostname through the shared `nginx-proxy` on `172.17.0.1`. That makes the two addressable at the same time and it's still not permission to run both — see [ADR-008](ADR-008-two-runtimes-one-image.md). `make down` frees them.
- **`vm.max_map_count` has to be set for OpenSearch**, which needs `allowedUnsafeSysctls` in the kubeadm configuration and a privileged init container. Under Compose this was a `ulimits:` key. It's one of the clearest examples of Kubernetes making a container-runtime convenience into a deliberate act.

## Related

- [ADR-003](ADR-003-shared-media-strategy.md) — the media claim that depends on there being one node
- `cluster/kind-config.yaml` — where every decision here is expressed
