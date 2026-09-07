vcl 4.1;

import std;
import directors;

# Varnish for the Kubernetes deployment.
#
# It is here because deleting it and letting the ingress route straight to
# nginx would remove the component the storefront's performance depends on,
# and would make the result unrepresentative of the thing it replaces
# (ADR-005). The chain is:
#
#     ingress-nginx  ->  varnish  ->  web / web-admin / web-cron  ->  php-*
#
# What changed from the Compose VCL, and why:
#
#   - Seven backends collapse to three. The Compose file declared web02..web06
#     as five separate backends all pointing at the same `web` container,
#     mimicking the production fleet's node names. On Kubernetes a Service
#     already load-balances across the replicas of a Deployment, so those five
#     become one backend and `kubectl scale` does what the shard director was
#     imitating. This is one of the places the literal translation is wrong.
#
#   - The shard and fallback directors go with them. A shard director over
#     five identical endpoints is a no-op with extra failure modes.
#
#   - The purge ACL names a CIDR, not "localhost". Purges arrive from php-fpm
#     pod addresses, which change on every replacement, so an ACL of literal
#     addresses cannot be written. The pod CIDR is the honest expression of
#     "any pod in this cluster", and it is stated here rather than left as an
#     open ACL.

backend web {
    .host = "web";
    .port = "8080";
    .first_byte_timeout = 600s;
    .probe = {
        .url = "/health_check.php";
        .timeout = 5s;
        .interval = 10s;
        .window = 5;
        .threshold = 3;
    }
}

backend admin {
    .host = "web-admin";
    .port = "8080";
    .first_byte_timeout = 600s;
    .probe = {
        .url = "/health_check.php";
        .timeout = 5s;
        .interval = 10s;
        .window = 5;
        .threshold = 3;
    }
}

backend cron {
    .host = "web-cron";
    .port = "8080";
    .first_byte_timeout = 600s;
    .probe = {
        .url = "/health_check.php";
        .timeout = 5s;
        .interval = 10s;
        .window = 5;
        .threshold = 3;
    }
}

sub vcl_init {
    # Static and media prefer the cron pool, which is otherwise idle, and fall
    # back to the storefront pool. Same intent as the Compose `static`
    # fallback director, with the dead nodes removed.
    new static_pool = directors.fallback();
    static_pool.add_backend(cron);
    static_pool.add_backend(web);
}

acl purge {
    # Who may send a PURGE. This names CIDRs rather than hostnames because the
    # senders are php-fpm containers whose addresses change on every
    # replacement -- an ACL of literal IPs would be wrong within a day.
    #
    # BOTH runtimes are covered, and they use different ranges: the kind
    # cluster's default pod CIDR, and Docker's bridge pools for the Compose
    # stack. One VCL serves both, so the ACL has to as well, and a purge that
    # is silently refused shows up as a storefront that never updates rather
    # than as an error anywhere.
    "10.244.0.0"/16;    # kind pods
    "172.16.0.0"/12;    # docker bridge networks
    "127.0.0.1";
}

sub vcl_recv {
    if (req.url ~ "^/admin" || req.url ~ "(?i)admin=(true|yes|1)") {
        set req.backend_hint = admin;
    } elsif (req.url ~ "^/(media|static)/") {
        set req.backend_hint = static_pool.backend();
    } else {
        set req.backend_hint = web;
    }

    if (req.method == "PURGE") {
        if (client.ip !~ purge) {
            return (synth(405, "Method not allowed"));
        }
        if (!req.http.X-Magento-Tags-Pattern && !req.http.X-Magento-Tags-Pattern-Regex) {
            return (purge);
        }
        if (req.http.X-Magento-Tags-Pattern) {
            ban("obj.http.X-Magento-Tags ~ " + req.http.X-Magento-Tags-Pattern);
        }
        if (req.http.X-Magento-Tags-Pattern-Regex) {
            ban("obj.http.X-Magento-Tags ~ " + req.http.X-Magento-Tags-Pattern-Regex);
        }
        return (synth(200, "Purged"));
    }

    if (req.method != "GET" && req.method != "HEAD" && req.method != "PUT" &&
        req.method != "POST" && req.method != "TRACE" && req.method != "OPTIONS" &&
        req.method != "DELETE") {
        return (pipe);
    }

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # Static files are cacheable regardless of what Magento says about them.
    if (req.url ~ "^/(pub/)?(media|static)/") {
        unset req.http.Https;
        unset req.http.X-Forwarded-Proto;
        unset req.http.Cookie;
    }

    if (req.url ~ "/checkout" || req.url ~ "/customer" || req.url ~ "/admin") {
        return (pass);
    }

    # Magento's own health endpoint must never be answered from cache — a
    # cached 200 would make a dead backend look alive to anything checking it.
    if (req.url ~ "^/health_check\.php$") {
        return (pass);
    }

    if (req.http.Authorization) {
        return (pass);
    }

    return (hash);
}

sub vcl_hash {
    if (req.http.cookie ~ "X-Magento-Vary=") {
        hash_data(regsub(req.http.cookie, "^.*?X-Magento-Vary=([^;]+);*.*$", "\1"));
    }
    if (req.http.X-Forwarded-Proto) {
        hash_data(req.http.X-Forwarded-Proto);
    }
}

sub vcl_backend_response {
    set beresp.grace = 3d;

    if (beresp.http.content-type ~ "text") {
        set beresp.do_esi = true;
    }

    if (bereq.url ~ "\.js$" || beresp.http.content-type ~ "text") {
        set beresp.do_gzip = true;
    }

    if (beresp.http.X-Magento-Debug) {
        set beresp.http.X-Magento-Cache-Control = beresp.http.Cache-Control;
    }

    if (beresp.http.Content-Type ~ "text/html" || beresp.http.Content-Type ~ "text/xml") {
        if (!beresp.http.Cache-Control ~ "private" && beresp.status == 200) {
            unset beresp.http.Set-Cookie;
        }
    }

    if (beresp.http.Cache-Control ~ "private" || beresp.status != 200) {
        set beresp.uncacheable = true;
        set beresp.ttl = 86400s;
        return (deliver);
    }
}

sub vcl_deliver {
    # X-Cache is what acceptance criterion A11 reads: a second request for the
    # same URL must report HIT. scripts/smoke-test.sh checks exactly this.
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
    set resp.http.X-Cache-Hits = obj.hits;

    unset resp.http.X-Magento-Debug;
    unset resp.http.X-Magento-Tags;
    unset resp.http.X-Powered-By;
    unset resp.http.Server;
    unset resp.http.Via;
    unset resp.http.Link;
}
