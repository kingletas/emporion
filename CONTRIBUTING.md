# Contributing

## From a fresh clone

```bash
make secrets
```

```bash
make check
```

`make secrets` generates the local development credentials the Compose files read. It is idempotent and cached, so running it again produces the same values — which matters, because the database volume is initialised with the password from the first run. You only need it explicitly before `make check`; `make compose-up` calls it for you.

## The gate

```bash
make check
```

That is lint, the secret scan, and the check that no machine's paths or names have got into the tree. A commit has to pass it, and CI runs the same thing on every push and pull request.

`make lint` on its own renders both cluster overlays, validates both Compose files for every store, checks that no two stores share a namespace, and shellchecks every script — including the ones baked into the image.

## What a gate here cannot tell you

**Valid YAML, a rendering overlay and a passing shellcheck prove nothing about an assembled application.** Nearly every real defect in this repository was found by running the thing:

- A cache id prefix containing a hyphen broke *every* CLI command, including the install, with a `Zend_Cache` trace naming the id and never the setting.
- Two of the five per-store namespaces were pinned as literals inside the entrypoint, so setting them in the config decided nothing at all. Every file on disk was correct.
- A `*.test` certificate had covered nothing for years while every configuration file said TLS was set up.

So there are runtime checks as well as static ones, and they are the ones that matter:

```bash
make smoke              # walks the acceptance criteria and reports each one
make verify-namespaces  # reads the env.php a running store actually loaded
make verify-consumers   # the declared list, the Deployments and the services agree
```

**`make smoke` is not part of `make check` and is not a CI gate.** It needs a running store, which a runner does not have. Run it for anything that touches a workload, a probe or the install.

## Test both directions

A passing check tells you nothing about the case it is meant to catch until you have watched it fail. The namespace-collision check was verified by breaking a store's config on purpose; **a green gate proves nothing about the alarm.** Do the same for anything you add.

## Where a change goes

- **A value two stores could disagree about goes in the per-store env file.** Anything else goes in `common.env`. The split is by whether a second store has a reason to differ, not by how interesting the value is.
- **A service name is a contract.** Every Compose service is named after the Kubernetes Service doing the same job, and the Varnish VCL, the nginx template and the entrypoint all depend on that. Rename one and a shared config file has to fork, which is the moment the two runtimes stop being comparable.
- **Scripts hold the logic; the Makefile holds none.** A recipe delegates to `scripts/`. A target that needs an argument checks for it, prints a usage block with real examples, and exits non-zero.
- **A decision that a future reader would otherwise have to reverse-engineer goes in an ADR**, in `docs/adr/`. Record the alternative that nearly won and why it lost — that is the line most often left out and the most valuable one.

## Nothing about your machine goes in the tree

`scripts/check-no-private-info.sh` fails on an absolute home path, and on the login and hostname of whoever is running it — read at run time rather than written down, because a check that hardcoded them would be the leak it exists to prevent.

Machine-specific values are environment variables with defaults: `MAGENTO_SRC`, `CERTS_HOME`, `SNAPSHOT_DIR`. Add a new one the same way rather than a literal path.

## Comments

Say what the code does or what it guards against, in a sentence or two, then stop. History belongs in the commit message and the changelog. A comment has no diff and no timestamp, so it is the one place nothing will ever check.

The scripts are the exception in one direction only: their header block is what `-h` prints, so it is documentation and should be written generously.

## Commit messages

Say what changed and who it affects. The subject is a sentence, not a category prefix. Detail belongs in the CHANGELOG.
