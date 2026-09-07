# Changelog

Notable changes, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]: 2026-09-07

First public release, under the name **Emporion**.

This grew out of running a real Magento store on a workstation and wanting the environment to be one description rather than two. It works, it's used daily, and the interfaces will still move — treat it as a prototype with a substantial body of work behind it.

It's published from a fresh root commit. The development history stayed private because it carried absolute paths, hostnames and machine names belonging to the environment it grew out of, and a text sweep of the working tree cannot reach a git history.

### What it does

Two runtimes for one Magento store — a kind cluster and a Docker Compose stack — deploying the same image, reading the same configuration files and the same generated credentials, and running the same install script. Anything that differs between them is a property of the runtime rather than of the application.

It also runs more than one store on Compose. `make new-site SITE=second.test` produces a working storefront and admin with sample data in it, in about the time a database restore takes, without touching the first one. Stores share the image, the Magento tree and one data tier; what they never share is the five namespaces that would otherwise make two stores read each other's data.

The Magento tree is a build parameter rather than something this repository vendors. Nothing here contains Magento, and nothing here is bound to one version of it.

### Prepared for publication

- **MIT licence, contributing guide, security policy and code of conduct.**
- **A GitHub Actions workflow** runs the gate somewhere other than the machine that wrote it, with every action pinned to a commit SHA resolved against the API rather than typed. A second job asserts that a fresh clone can reach a passing gate in two documented commands.
- **`make check`** is one command for everything a commit must pass: the overlays render, both Compose files validate for every store, no two stores share a namespace, shellcheck is clean, nothing credential-shaped is committable, and nothing in the tree names anyone's machine.
- **The README is a front door again.** It was 672 lines doing the job of five documents; the material now lives under `docs/` and nothing was cut. Seven guides, including [From nothing to a storefront](docs/from-nothing.md) — a bare machine to a serving store — and a configuration reference.
- **Nothing points at a document a reader cannot open.** Thirty-seven citations of a private requirements document, across the ADRs, the Dockerfile, the manifests, the nginx and Varnish configs and six scripts, are replaced by the substance they were pointing at. So are the internal objective numbers, which were defined nowhere public.
- **Machine-specific paths became variables with defaults** — `MAGENTO_SRC`, `CERTS_HOME` and `SNAPSHOT_DIR` — resolved relative to the repository rather than to one person's home directory. The kind cluster config is rendered from a template at cluster-create time for the same reason.

### Proven against Magento Open Source

The publication precondition in [ADR-006](docs/adr/ADR-006-magento-source-and-licence.md) is met: a clean checkout, a `magento/project-community-edition` 2.4.8-p2 tree created from empty beside it, and `make new-site SEED=none` unattended to a storefront answering 200 over TLS.

**It took four attempts, and each failure was a real defect.** Every one had been invisible because the only Magento tree this had ever been built against was one that had already been installed:

- **The image build required an already-installed tree.** `setup:di:compile` failed with *You cannot run this command because modules are not enabled* — a freshly created Magento tree has no `app/etc/config.php` at all, because that file is written by the installer. The build now writes the module list first, and skips that when the tree already carries one.
- **The from-empty install never imported its configuration**, so every storefront request returned 500 with *The configuration file has changed*. `setup:install` records a hash of the `env.php` it was given; every container then regenerates the canonical one at start, and the two no longer match. The install now regenerates the canonical file and imports against it. Seeding a store from a snapshot takes the upgrade path, which always imported — which is why this stayed broken while every seeded store worked.
- **`MODE=exclusive` silently built a shared store.** An explicit switch discards the requested mode, so the store attached to the shared data tier while its own config file recorded `exclusive` — leaving `destroy` tearing down a data project that never existed and orphaning the real database.
- **The documentation stated a premise backwards**, claiming a `composer create-project` tree carries a `config.php` with the module list. It carries no such file.

### Fixed

- **`make lint` could not pass, and had not been able to for some time.** A nameref parameter named `out` in one function made shellcheck read a plain string named `out` in another as an array, and it reported twelve findings across five lines. The string is called `bundle` now.
- **A fresh clone could not pass `make lint` either**, because the Compose files read env fragments that only `make secrets` writes, and the failure named a missing file rather than the missing step. That step is now the documented first command and the first thing CI runs.
- **`certs/` in `.gitignore` did not ignore `certs`.** A trailing slash matches a directory, and the obvious way to supply certificates — a symlink to a shared mkcert directory — is not one. The link showed up as untracked, one `git add -A` from being committed, while every file beneath it looked ignored. Git won't even answer a `check-ignore` for a path through the link once it exists.
