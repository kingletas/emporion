---
adr: 005
status: accepted
date: 2026-08-24
---

# ADR-005 — Varnish stays in the chain

> [!info] Status
> **Accepted.** Revisit if Varnish ever needs more than one replica. The decision holds; the `Recreate` strategy it currently relies on doesn't, and that's a real design problem rather than a tuning one.

## Context

The Compose chain is `proxy` → `varnish` → three nginx pools, each routing FastCGI to a different PHP pool. That's a real edge tier with cache invalidation semantics — Magento sends `X-Magento-Tags` on every cacheable response and purges by ban expression when content changes.

The obvious Kubernetes translation deletes Varnish and lets the ingress controller do the routing, because an ingress controller *is* an nginx that routes by host and path. It looks like a simplification.

It isn't. It removes the component the storefront's performance depends on, and it turns cache invalidation from a mechanism into an absence.

## Decision

**Varnish runs as a `Deployment` behind the ingress**, with its VCL in a `ConfigMap`. The ingress does exactly one thing Varnish cannot: terminate TLS. Every routing decision stays in the VCL.

The `proxy` nginx container is **deleted, not migrated** — it existed to terminate TLS and forward to Varnish, and the ingress controller now does both.

The VCL is rewritten rather than copied, and the rewrite is where the interesting part is:

- **Seven backends collapse to three.** The Compose VCL declared `web02` through `web06` as five separate backends all pointing at the same `web` container, imitating the production fleet's node names. A Kubernetes `Service` already load-balances across a Deployment's replicas, so those five become one backend and `kubectl scale` does what the shard director was imitating.
- **The shard and fallback directors go with them**, except the static-content fallback, which expresses a real preference (serve static from the otherwise-idle cron pool, fall back to the storefront pool).
- **The purge ACL names a CIDR.** Purges arrive from php-fpm pod addresses, which change on every replacement, so an ACL of literal addresses cannot be written at all.

## Alternatives

### Delete Varnish; use the ingress and Magento's built-in full-page cache

**Advantages** — One fewer component. The ingress is already there. Magento's built-in FPC in Redis still works.

**Disadvantages** — Gives up the edge cache entirely. Magento's built-in FPC still executes PHP to serve a cached page; Varnish doesn't. The measured difference is the reason Varnish is in the stack. It would also make this local model unrepresentative of the deployment it exists to reproduce, which is the one failure worth avoiding here.

### Replace Varnish with an ingress-nginx `proxy_cache`

**Advantages** — No extra pod. `proxy_cache` is genuinely fast.

**Disadvantages** — No tag-based invalidation. Magento purges by ban expression over `X-Magento-Tags`; nginx's cache can purge by key, and mapping one onto the other is a project. What looks like a swap is a rewrite of the invalidation model.

### Varnish as a sidecar in each web pod

**Advantages** — Scales with the web tier automatically. No separate Service.

**Disadvantages** — N independent caches with no shared invalidation. A purge reaches one sidecar, and the other pods keep serving the stale page — which produces bugs that appear and disappear depending on which pod answered. This is the same problem as running two Varnish replicas, arrived at by a different route.

> [!important] The sidecar option was the near miss, and it fails for the reason the current design is fragile
> Both the sidecar and a scaled-up Deployment produce multiple independent caches behind one Service, with invalidation reaching one of them. The single-replica `Deployment` with `strategy: Recreate` is not a solution to that — it's an avoidance, and it means the edge tier is the one part of this stack that cannot be scaled or rolled without a gap in service. A real answer needs either a shared cache backend, a purge fan-out, or consistent hashing at the ingress. **None of the three is built here, and that is the honest limit of this decision.**

## Consequences

- **The edge cannot be scaled or rolled without dropping requests.** `strategy: Recreate` means the old Varnish pod is gone before the new one is ready. On a laptop that's a few seconds; in any real deployment it's unacceptable, and the fix is a genuine design problem, not a configuration change.
- **`http_cache_hosts` in `env.php` points at the Varnish Service**, so Magento's purges go to the Service and reach whichever pod is behind it. With one pod that's correct. With two it's silently wrong.
- **Acceptance criterion A11 is checkable and is checked.** `make smoke` requests a URL twice and asserts `X-Cache: HIT` on the second. That single header is the whole difference between "Varnish is in the chain" and "Varnish is running".
- **The three-pool routing is preserved and is now a VCL concern only.** No ingress annotation routes anything. Anyone looking for why `/admin` reaches a different PHP pool will find one answer, in one file.

## Related

- [ADR-001](ADR-001-local-kubernetes-runtime.md) — the ingress that terminates TLS in front of this
- `k8s/base/config/files/varnish/default.vcl`
- `k8s/base/edge/varnish.yaml`
