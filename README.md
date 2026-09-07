# Emporion

A local runtime for a Magento 2 store, in two shapes: a Kubernetes cluster and a Docker Compose stack. They deploy the same image, read the same configuration and the same generated credentials, and run the same install script. Anything that differs between them is a property of the runtime rather than of the application — which is the only reason having both is worth the cost.

> [!IMPORTANT]
> This is a workstation environment, not a production one. No cluster here serves traffic, the hardened overlay is called `prod-shaped` on purpose, and [What this doesn't claim](#what-this-does-not-claim) is a section rather than a footnote.

## The problem

A Magento environment is around twenty containers: PHP-FPM, nginx, Varnish, MariaDB, OpenSearch, RabbitMQ, two Redis-compatible caches, six queue consumers and a cron loop. Getting one running is a day. Getting a second one running beside it, for a different branch or a different client, usually means copying the whole thing and then discovering the two stores are sharing a search index.

They share it because Magento's namespacing is spread across five unrelated settings, and **four of the five fail silently when they collide.** Two stores on one queue vhost consume each other's messages, and the only evidence is work that never happened.

Emporion is one description of a Magento environment with the runtime as a variable. `make compose-up` gives you a store in under a minute. `make new-site SITE=second.test` gives you another one, with its own database, cache keys, search index, queue vhost and mail, in about the time a database restore takes. And `make up` runs the same store on Kubernetes, when the question you've is about probes, claims or rollout rather than about Magento.

```bash
make compose-up && make compose-install
```

Then `https://vanilla.test/`.

## Contents

- [The problem](#the-problem)
- [Documentation](#documentation)
- [Which runtime, and when](#which-runtime-and-when)
- [Requirements](#requirements)
- [Two things to know before you start](#two-things-to-know-before-you-start)
- [Decisions](#decisions)
- [Scope](#scope)
- [Licence](#licence)

## Documentation

| | |
|---|---|
| [From nothing to a storefront](docs/from-nothing.md) | **Start here if you have never run Magento.** A bare machine to a working store, and the errors you'll actually meet |
| [Getting started](docs/getting-started.md) | What you need, bringing a store up, and how the install decides what to do |
| [The two runtimes](docs/runtimes.md) | Cluster or Compose, getting a code change into a running store, and the two cluster overlays |
| [More than one store](docs/sites.md) | A second storefront on demand, what keeps two stores apart, and snapshots |
| [How it's put together](docs/architecture.md) | What the runtimes share, the four hard problems, and the layout |
| [Running it](docs/operations.md) | Commands, the checks, resource limits, and debugging |
| [Configuration](docs/configuration.md) | Every setting, which of the four places it lives in, and why |
| [Decisions](docs/adr/) | Eight ADRs, each naming the alternative that nearly won |
| [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md) | |

## Which runtime, and when

|  | Compose | kind cluster |
|---|---|---|
| Start it | `make compose-up` | `make up` |
| Time to a serving storefront | under a minute | several, plus a cluster |
| Application code | in the image, or bind-mounted | in the image, or a `hostPath` under the `dev` overlay |
| **How many stores at once** | **as many as fit** | one; there's no second port for a second host |
| Extra tooling needed | none | `kind`, `kubectl` |
| Good for | running the store, day to day | the orchestration questions — probes, claims, rollout, scaling |

**Compose is the one to work in. The cluster is the one that answers questions Compose cannot be asked.** Neither is a toy version of the other: they run the same image, and a bug that appears in one appears in both.

> [!danger] The two runtimes must never run at the same time
> Both bind the same edge, and running them together means two MariaDB instances, two OpenSearch JVMs and two PHP pools each allowed 4 GiB. On a 31 GB workstation that reaches a load average in the hundreds with swap exhausted.
>
> **Both `up` targets refuse while the other runtime is present**, and that refusal is the feature. Switching is meant to be cheap instead.
>
> **This is about runtimes, not about stores.** Several stores coexist on Compose because they share the expensive tier and only one does background work at a time. That's a different arrangement with its own guard — see [More than one store](docs/sites.md).

## Requirements

- **Docker**, with BuildKit. That's the whole list for the Compose runtime.
- **A Magento 2 tree** at `MAGENTO_SRC`, defaulting to `commerce-vanilla/` beside this repository. Nothing here vendors Magento or installs it for you.
- **`kind` and `kubectl`** for the cluster runtime only. `make tools` installs both.
- **Wildcard DNS for `.test`** pointing at your Docker bridge, and a reverse proxy in front of it — dnsmasq and nginx-proxy here. The cluster runtime binds `127.0.0.1` and needs one `/etc/hosts` line instead.
- **`mkcert`**, and a certificate per hostname in `CERTS_HOME`. There's no wildcard shortcut; see the callout in [Getting started](docs/getting-started.md#quick-start) for why. If your setup needs a proxy reloaded after issuing, point `DEV_CERT_TOOL` at your own wrapper and it will be called instead.
- **`envsubst`**, from GNU gettext, for the cluster runtime.

## Two things to know before you start

**Adobe Commerce is licensed, and Magento Open Source is not.** `MAGENTO_SRC` points at whichever tree you've and nothing in this repository cares which. `make sample-data` is the one target that does: Adobe's sample data packages come from an authenticated `repo.magento.com`, so it checks for an `auth.json` and exits with a named error rather than half-running.

**A store is machine state and git does not track it.** Creating one writes a small env file and destroying it removes one, so those files are gitignored — with one exception the build needs. `make sites` reads the filesystem for the list, because which stores exist is a fact about your laptop rather than a claim this repository makes.

## Decisions

One file each, in [`docs/adr/`](docs/adr/). Each records the alternative that was nearly chosen and why it lost — that being the single most valuable line in an ADR and the one most often left out.

| # | Decision | The near miss |
|---|---|---|
| [001](docs/adr/ADR-001-local-kubernetes-runtime.md) | kind, single node | k3d — better on memory, lost on vocabulary |
| [002](docs/adr/ADR-002-configuration-mechanism.md) | Kustomize over Helm | Helm — real hooks and loops, lost on indirection |
| [003](docs/adr/ADR-003-shared-media-strategy.md) | Split the concerns; one single-node claim | Object storage — the right answer, not built |
| [004](docs/adr/ADR-004-image-build-strategy.md) | Multi-stage, exclusion made loud | Skip the compile — unpicks ADR-003 as a side effect |
| [005](docs/adr/ADR-005-varnish-stays-in-the-chain.md) | Varnish behind the edge | Varnish as a sidecar — N caches, one purge |
| [006](docs/adr/ADR-006-magento-source-and-licence.md) | The Magento tree is a build parameter | Vendoring it — tidy-looking, and licensed source in the history |
| [007](docs/adr/ADR-007-dev-overlay-mounted-source.md) | Build both overlays | Drop the dev overlay — cleaner artifact, unusable environment |
| [008](docs/adr/ADR-008-two-runtimes-one-image.md) | Compose beside the cluster, one image | Cluster only — one fewer thing, and a minute became several |

ADR-003 and ADR-005 both end with a limitation rather than a resolution. That's the state of the work, not a gap in the writing.

## Scope

**What is here:**

- A multi-service Magento stack on Kubernetes and on Compose, from one image and one configuration source — StatefulSets with persistent claims, probes replacing startup ordering, `CronJob` and consumer workloads, an ingress-to-Varnish edge.
- The specific failure modes worked through and written down: `ReadWriteMany` for a shared webroot, build-time compilation for an immutable image, cache invalidation through an edge that's not the ingress.
- Several stores on one machine, with the five namespaces that keep them apart.

**What is deliberately not here:**

- **Any cloud component.** Nothing targets EKS, GKE or AKS, and nothing has been run on them.
- **Production.** No cluster here serves traffic. `prod-shaped` is a shape, and is named that way on purpose.
- **Cluster operations at scale** — upgrades, capacity planning, operators, service mesh. A single-node local cluster is the wrong place to model any of them.
- **Multi-tenancy, which is not a gap — it is out of scope and stays that way.** Several stores share a data tier as a development convenience on one workstation. There's no isolation between them at the database, network or resource level, none is planned, and nothing here should grow toward it. Calling this tenancy would imply a security boundary that doesn't exist and was never wanted.

## Licence

MIT — see [LICENSE](LICENSE). It covers this repository only. **Magento itself is not included and is licensed separately**, Adobe Commerce commercially and Magento Open Source under OSL-3.0.
