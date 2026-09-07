# Architecture Decision Records

Nine decisions, one file each.

Every one records the alternative that was nearly chosen and why it lost. An ADR with no real alternatives is a note, not a decision record.

| # | Decision | Status |
|---|---|---|
| [ADR-001](ADR-001-local-kubernetes-runtime.md) | Local Kubernetes runtime — kind | Accepted |
| [ADR-002](ADR-002-configuration-mechanism.md) | Configuration mechanism — Kustomize over Helm | Accepted |
| [ADR-003](ADR-003-shared-media-strategy.md) | Shared media strategy | Accepted, with a stated limit |
| [ADR-004](ADR-004-image-build-strategy.md) | Image build strategy, and what it drops | Accepted |
| [ADR-005](ADR-005-varnish-stays-in-the-chain.md) | Varnish kept in the chain, not replaced by the ingress | Accepted |
| [ADR-006](ADR-006-magento-source-and-licence.md) | Magento source and licence posture | Accepted |
| [ADR-007](ADR-007-dev-overlay-mounted-source.md) | Dev overlay — mounted source | Accepted |
| [ADR-008](ADR-008-two-runtimes-one-image.md) | Two runtimes, one image | Accepted |
| [ADR-009](ADR-009-publishing-as-emporion.md) | Published as Emporion, from a fresh root commit | Accepted |

**ADR-006 was materially revised on 2026-08-27**, when this repository was repointed at a Magento tree of its own. The compile problem it shared an answer with is closed: `COMPILE_EXCLUDES` is empty, which is the state ADR-004 named as the goal.

**ADR-006 set a precondition on publication — an Open Source build from a clean checkout — and it was met on 2026-09-07**, at the cost of four defects nothing else had found. [ADR-009](ADR-009-publishing-as-emporion.md) records how it is published. Read the two together.
