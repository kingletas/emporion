# Security

> [!IMPORTANT]
> **This is a local development environment and the boundary is your workstation.** Every service binds loopback or the Docker bridge, the credentials guard nothing, and the store has no real customers in it. Nothing here is built to survive an adversary, and calling it hardened would be a claim it cannot keep.
>
> What this document is for is the narrower thing that does matter: **no credential, and nothing about the machine that ran it, should ever reach the repository.**

## Contents

- [What is generated, and where it goes](#what-is-generated-and-where-it-goes)
- [The gate](#the-gate)
- [What the hardened overlay does and does not prove](#what-the-hardened-overlay-does-and-does-not-prove)
- [Reporting something](#reporting-something)

## What is generated, and where it goes

**Nothing credential-shaped is a committed literal.** `scripts/secrets.sh` generates every value once, into `secrets/`, which is gitignored:

| Directory | What it holds |
|---|---|
| `secrets/<data-project>/` | the database root password and the RabbitMQ administrator, shared by the stores attached to that tier |
| `secrets/<store-slug>/` | that store's database password, crypt key and admin password |

Directories are created mode `700` and each value mode `600`. **One generator feeds both runtimes** — the cluster gets Secrets, the Compose stack gets `env_file` fragments written beside them. Two generators would mean two sets of credentials for one store, and the first symptom would be a database that authenticates under one runtime and not the other.

**Values are cached, and that is a correctness property rather than a convenience.** The database volume is initialised with the password from the first run; regenerating on every deploy locks the application out of its own database with an authentication error that looks nothing like its cause.

**The crypt key is the one value a store may inherit.** A store seeded from a snapshot cannot read what that snapshot encrypted unless it holds the key that encrypted it, so a seeded store takes the key and an empty one generates its own. A snapshot records a **fingerprint** of the key, never the key. `make sites` prints every store's fingerprint, so two stores sharing one is visible rather than inferred.

**TLS is read at bootstrap and never committed.** `CERTS_HOME` defaults to `certs/` in this repository, which is gitignored precisely because that is where a key would otherwise land.

## The gate

```bash
make check
```

Three things run, and all three fail the build:

- **`make scan`** — that `secrets/` and `certs/` are ignored, that no file git could reach matches a credential pattern, and that no `.key` or `.pem` is inside the tree. **It scans the working tree rather than the index**, because a secret that is merely untracked is still one `git add -A` away from being committed.
- **`scripts/check-no-private-info.sh`** — no absolute home path, and not the login or hostname of whoever is running it. Those two are read at run time rather than written down: a check that hardcoded them would be the leak it exists to prevent, and reading them means it protects the next contributor rather than the last one.
- **`make lint`** — including that no two stores share a namespace. A collision there is not a security boundary, but four of the five fail silently, and a store quietly reading another's data is worth a gate.

## What the hardened overlay does and does not prove

`k8s/overlays/prod-shaped` sets `readOnlyRootFilesystem`, drops all capabilities, turns off opcache revalidation and runs two storefront replicas. **It is named `prod-shaped` because it is a shape, not a posture.** There is no network policy, no admission control, no image scanning, no secret management beyond files on disk, and no cluster here serves traffic.

Read it as evidence that the image can run without writing to its own root — which is a real property, and is the one the `dev` overlay deliberately gives up.

## Reporting something

Open an issue. If it is something you would rather not put in public, email **code@kingletas.com**.

This is a workstation environment with one operator, so there is no embargo process to observe and no security release channel. **A vulnerability in Magento itself is Adobe's**, and should go to them rather than here.
