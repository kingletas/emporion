---
adr: 009
status: accepted
date: 2026-09-07
---

# ADR-009 — Publishing as Emporion, from a fresh root commit

## Context

This repository was prepared for a GitHub remote, having never had one. It's now published at `kingletas/emporion`, private to begin with.

**[ADR-006](ADR-006-magento-source-and-licence.md) set a precondition on exactly this act**: the repository has to build and run against Magento Open Source, on a clean checkout, before it's published.

**It has since been done, and it is what made this decision safe to act on.** A clean checkout built and ran against a Magento Open Source tree created from empty, and reached a serving storefront unattended. [ADR-006](ADR-006-magento-source-and-licence.md) records the result and the four defects it surfaced.

Two further facts drove the shape of the decision.

**The working tree named the machine it was written on.** Absolute home paths as build defaults, an admin email address, a real second-store hostname, and — the one no text search would have caught by category — a warning that told the reader to run a command that only exists on that machine. A tool that's not on someone else's `PATH` is not an instruction, it's a dead end with a confident tone.

**The git history named it too, in more places than the tree did**, across sixteen commits: home paths in three, a private repository name in one, real hostnames in seven. Unlike the tree, a history cannot be swept by editing files.

## Decision

**The repository is published under the name `emporion`, from a single fresh root commit.**

**The name was measured before it was taken**, on the same checks a previous rename in this estate used: free on PyPI, npm and crates.io; the GitHub repository name free; `emporion.com` and `emporion.dev` unregistered; no software company holding the word.

Two candidates were rejected on that measurement rather than on taste — one because a payments company holds its PyPI name, which is the adjacency that matters most for something in commerce, and one because an npm CLI already has it. *Emporion* is Greek for a trading post and gives English *emporium*, so it says what the thing is for without the reader knowing any Greek.

**The sixteen existing commits stay local.** They are not deleted and not rewritten; they simply don't become public.

**A gate keeps the machine out of the tree from here on.** `scripts/check-no-private-info.sh` fails on an absolute home path, on a personal source tree, and on the login and hostname of whoever runs it — read at run time, never written down.

## Alternatives

### Rewrite the history with `git filter-repo`

**Advantages** — The development narrative stays public. Sixteen commits is few enough to check, and there are no binary blobs in this history, so unlike a repository full of screenshots a text filter here could actually be complete.

**Disadvantages** — Every replacement has to be right at every revision, and being *nearly* right produces a history that looks clean and is not. It also rewrites commit messages, which are statements about what happened rather than pointers to anything; a rewritten one is internally consistent and false. The narrative is not lost either way — the CHANGELOG and these nine ADRs carry it, in prose, which is where it reads better.

### Publish the history as it stands

**Advantages** — Nothing to do.

**Disadvantages** — Publishes the paths, hostnames and repository names the sweep exists to remove. `git log -p` shows every one of them, and nobody thinks to look there.

### Do the Open Source build first, and prepare afterwards

**Advantages** — Honours ADR-006 in order.

**Disadvantages** — Confuses two things that are separable. Preparing a repository to be publishable is most of the work and none of the risk; pushing it's one command and all of the risk. Preparing first meant the Open Source build was attempted against a repository that was already clean, documented and gated — and the four defects it found were fixed in a tree where the gate could confirm each fix immediately.

## Consequences

- **A green gate is not a proven Open Source build**, and the difference wasn't academic: every gate here passed for weeks while four defects sat in the build and install path. Only running it against a tree that had never been installed found them.
- **`make sample-data` will not work for most readers**, because Adobe's sample data packages need authenticated `repo.magento.com` credentials. It says so with a named error rather than half-running. That's the licence showing through, and it's the most visible day-to-day cost of the development target being Adobe Commerce.
- **The gate reads text and nothing else.** It cannot see inside an image, so a future screenshot could leak what no check here would catch.
- **The name was checked against the open web, not against a trademark register.** A web search finds companies that market themselves; it doesn't find registered marks. The USPTO's search is free and public and is the check worth running before this matters.

## Related

- [ADR-006](ADR-006-magento-source-and-licence.md) — the source and licence posture, and the precondition this one waited for
- [CONTRIBUTING](../../CONTRIBUTING.md), [SECURITY](../../SECURITY.md)
