---
adr: 003
status: accepted
date: 2026-08-24
---

# ADR-003 — Shared media strategy

> [!info] Status
> **Accepted, with a limit stated in the decision itself.** This one is only correct on a single-node cluster. Revisit the moment a second node exists — not because it will degrade, but because it will stop working entirely, and that is the more useful failure.

## Context

This is the problem the whole repository is organised around. Magento writes to `pub/media`, `pub/static`, `var/` and `generated/` at runtime, and under Compose every PHP and web container has the entire application tree bind-mounted, so all four are shared by accident.

Three pods reading and writing one filesystem is `ReadWriteMany`, the single hardest storage mode to provide. The existing local lab notes already name it as the crux: an EFS-backed shared webroot over CSI is what makes Magento-on-Kubernetes a project rather than a migration.

The forces in tension: an honest solution has to keep the application working, has to not require a distributed filesystem on a laptop, and has to not quietly pretend the hard part was solved when it was avoided.

## Decision

**Stop needing `ReadWriteMany` for three of the four paths, and use one single-node `ReadWriteOnce` claim for the fourth.**

| Path | Where it goes | Why |
|---|---|---|
| `generated/` | Into the image at build time | Produced by `setup:di:compile`; identical for every pod running that image |
| `pub/static` | Into the image at build time | Produced by `setup:static-content:deploy`; same argument |
| `var/` | Pod-local `emptyDir` | Once the cache is in Valkey, the page cache in Varnish, the sessions in Valkey and the logs on stdout, what remains is scratch |
| `pub/media` | One `ReadWriteOnce` PVC | Genuinely shared, genuinely mutable, genuinely written by a running application |

That reduces a shared root filesystem to a single shared directory, which is the difference between a design and a bind mount with extra steps.

**And state the limit in the manifest, not only here:** this works because the cluster has one node. `k8s/base/app/media-pvc.yaml` says so in its header.

> [!warning] This decision was written asking for `ReadWriteMany`, and that was wrong — corrected 2026-08-26 on the cluster's first run
> The reasoning was that kind's local-path provisioner backs a PVC with a hostPath, so every pod sees the same directory and RWX is satisfied by geography. **The provisioner does not reason about geography. It reads the access mode and rejects the claim outright** — *NodePath only supports ReadWriteOnce and ReadWriteOncePod (1.22+) access modes* — so the volume never bound and the `setup:upgrade` Job and both CronJobs sat in `Pending`, with the explanation only in the provisioner's log.
>
> `ReadWriteOnce` binds a volume to one **node**, not to one **pod**. Every pod on that node may mount it, which is precisely the sharing this design needs and precisely what the geography argument was reaching for. The multi-node limitation below is unchanged. **What changed is that the single-node case now works, and that an argument which had never been executed turned out to be false in the one way that mattered.**

## Alternatives

### An in-cluster NFS provisioner

**Advantages** — Real `ReadWriteMany`, satisfied by an actual network filesystem. Survives multiple nodes. Closest local analogue to the EFS-over-CSI arrangement in production.

**Disadvantages** — Another stateful component to run, back, and debug on a host with no memory to spare — and an NFS server pod whose own storage is a `ReadWriteOnce` claim, which means the hard problem has been moved rather than solved. NFS locking semantics under Magento are their own investigation.

### Object storage through Magento's remote-storage module

**Advantages** — The architecturally correct answer, and the one a real deployment should reach. Media stops being a filesystem concern; the claim disappears; it scales to any number of nodes and any number of clusters.

**Disadvantages** — Adds MinIO to the stack. Magento's remote-storage path is patchy in practice — the admin image uploader, the product image resizer and the media gallery each interact with it differently, and the failure modes are subtle rather than loud. It is also, unlike the other options, a change to how the *application* works, which puts it outside what this repository can validate: nothing here tests Magento's own behaviour.

### `hostPath` mounted directly into every pod

**Advantages** — Works immediately, needs no provisioner.

**Disadvantages** — It is the Compose bind mount with a Kubernetes accent. It models nothing a real deployment would do, so anything learned from it about storage would be false.

> [!important] Object storage was the near miss and it is the one that should have been built
> Splitting the concerns is the correct answer and the most work, and object storage for the remaining shared path is the answer that survives a second node. What is built here does the split, which is most of the value, and then takes the *easy* option for the path that is left. **The single-node claim is a real solution to a smaller problem than the one posed**, and this ADR says so rather than letting the shape of the code imply otherwise.

## Consequences

- **A second node breaks the media claim.** Not degrades — breaks. A pod scheduled elsewhere gets an empty directory, and images uploaded through admin vanish for half the requests. Anyone adding a node has to resolve this first.
- **`pub/static` and `generated/` are now build outputs, which makes the build a hard dependency of the deploy.** A deploy without a successful `setup:di:compile` produces pods with no static content, which is [ADR-004](ADR-004-image-build-strategy.md)'s problem and is why these two decisions were made together.
- **`var/` being pod-local means nothing in it is a record.** Anything worth keeping — reports, exception logs — has to leave the pod at the time it is written. Logs go to stdout for this reason.
- **Acceptance criterion A9 is checkable and can fail honestly.** `make smoke` writes a file through one php-fpm pod and reads it from another; it skips rather than passes when there is only one replica, because a shared-storage test with one pod proves nothing.

## Related

- [ADR-001](ADR-001-local-kubernetes-runtime.md) — the single node this rests on
- [ADR-004](ADR-004-image-build-strategy.md) — decided together with this one
- `k8s/base/app/media-pvc.yaml`
