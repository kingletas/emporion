# The Magento store's runtimes — a kind cluster and a Compose stack — and the
# sites that run on them.
#
# TWO RUNTIMES, ONE IMAGE. Both deploy the image built from build/Dockerfile,
# read k8s/base/config/env/common.env layered under a site's own env file, and
# use the credentials scripts/secrets.sh generates. Anything that differs
# between them is a property of the runtime rather than of the application,
# which is the only reason having both is worth the cost.
#
# MANY SITES, ON COMPOSE. `make new-site SITE=second.test` stands up another
# store beside the first: its own hostname, database, cache prefix, search
# index prefix, queue vhost and media, sharing one data tier and one image.
# The cluster serves ONE site at a time and always did — it binds 127.0.0.1:80
# — so multi-site is a Compose feature and this file does not pretend
# otherwise.
#
# EVERY SITE COMMAND TAKES A HOSTNAME, either way round:
#
#   make new-site SITE=second.test
#   make new-site second.test
#
# The second is not valid Make on its own -- a bare word is a second GOAL, so
# `destroy-site` would run first against whatever SITE defaulted to and then
# Make would fail looking for a rule to build `second.test`. It is made to work
# below by binding a single bare `<name>.test` goal to SITE and consuming it,
# because that is what a person types and the alternative was a destructive
# command quietly aiming somewhere else. A `--flag` is a second goal too, and
# is not rescued: MODE=exclusive is the spelling.
#
# The two runtimes must never run at the same time: they serve the same
# hostname on one laptop, and both `up` targets refuse while the other is
# present.
#
# The hard requirement is `make down && make up` from nothing, unattended, to a
# working storefront. Every other target exists to make that one honest.
#
# Run `make` with no arguments for the list.

SHELL      := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

SCRIPTS    := ./scripts
# The one variable a person types. Everything else — the Compose project, the
# secrets directory, the config file, the data network — is derived from it in
# scripts/lib.sh, so a second store is one variable rather than eight.
SITE       ?= vanilla.test
MODE       ?= shared
SEED       ?= sample-data-baseline
# YES=1 skips the confirmation prompts, for unattended use.
YES        ?=
OVERLAY    ?= dev
NAMESPACE  ?= vanilla
CLUSTER    ?= vanilla

# --- a hostname typed as a bare word ----------------------------------------
# `make destroy-site second.test` is the natural thing to type, and Make reads
# it as TWO GOALS: run `destroy-site`, then build a target called `second.test`.
# The first of those ran against whatever SITE defaulted to.
#
# ON A DESTRUCTIVE TARGET THAT MEANT OFFERING TO DELETE A DIFFERENT STORE than
# the one named on the command line. It was caught by a person reading the
# plan, which is luck rather than a guard, and documenting the trap in a
# comment did nothing to stop it.
#
# So a single bare `<name>.test` goal is TAKEN as the site and consumed by a
# no-op rule, rather than being ignored and then failing with "no rule to make
# target". Saying it twice, or saying two hostnames, is an error rather than a
# guess about which one was meant.
SITE_EXPLICIT := $(if $(filter command line,$(origin SITE)),1,)
BARE_SITE     := $(filter %.test,$(MAKECMDGOALS))

ifneq ($(BARE_SITE),)
  ifneq ($(words $(BARE_SITE)),1)
    $(error more than one hostname given ($(BARE_SITE)) — one site per command)
  endif
  ifneq ($(SITE_EXPLICIT),)
    $(error both SITE=$(SITE) and a bare $(BARE_SITE) were given — say it once)
  endif
  ifeq ($(words $(MAKECMDGOALS)),1)
    $(error $(BARE_SITE) is a site, not a command — try: make sites)
  endif
  SITE          := $(BARE_SITE)
  SITE_EXPLICIT := 1
.PHONY: $(BARE_SITE)
$(BARE_SITE):
	@:
endif

export SITE OVERLAY NAMESPACE
export CLUSTER_NAME = $(CLUSTER)

KC := kubectl --context kind-$(CLUSTER) -n $(NAMESPACE)

.PHONY: help
help: ## Show this help
	@echo
	@echo "  Magento — site: $(SITE),  cluster overlay: $(OVERLAY)"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Another site:  make new-site SITE=second.test [MODE=exclusive] [SEED=none]"
	@echo "  Overlays:      make deploy OVERLAY=prod-shaped"
	@echo "  One site works at a time:  make use SITE=second.test"
	@echo

# --- the cluster runtime ---------------------------------------------------

.PHONY: up
up: ## Cluster: create it, build the image, deploy, wait for ready
	@$(SCRIPTS)/cluster-up.sh
	@$(SCRIPTS)/secrets.sh
	@$(MAKE) --no-print-directory image
	@$(SCRIPTS)/deploy.sh -o $(OVERLAY)
	@$(SCRIPTS)/hosts.sh || true
	@echo
	@echo "  Storefront: https://$(SITE_HOST)"
	@echo "  Check it:   make smoke"
	@echo

.PHONY: down
down: ## Cluster: destroy it entirely, including every PVC
	@$(SCRIPTS)/cluster-down.sh

.PHONY: deploy
deploy: ## Cluster: redeploy after a code or manifest change
	@$(SCRIPTS)/deploy.sh -o $(OVERLAY)

.PHONY: logs
logs: ## Cluster: tail logs across every workload
	@$(KC) logs -f --max-log-requests 30 --prefix \
		-l app.kubernetes.io/part-of=emporion --tail=20

.PHONY: shell
shell: ## Cluster: shell into the PHP pod
	@$(KC) exec -it deploy/php-fpm -- bash

.PHONY: cli
cli: ## Cluster: run bin/magento — make cli ARGS="cache:flush"
	@$(SCRIPTS)/magento.sh $(ARGS)

# --- the Compose runtime ----------------------------------------------------
# Production-shaped: the same image, read-only roots, no source mount. It
# reaches https://$(SITE_HOST) through the shared nginx-proxy and publishes no
# port, which is what leaves 127.0.0.1:80 free for the cluster.

.PHONY: compose-up
compose-up: ## Compose: start it (refuses while the cluster exists)
	@$(SCRIPTS)/compose-up.sh

.PHONY: compose-build
compose-build: ## Compose: rebuild the image, then start it
	@$(SCRIPTS)/compose-up.sh -b

.PHONY: compose-source
compose-source: ## Where a site's code comes from — make compose-source SOURCE=mounted|image
	@$(SCRIPTS)/compose-source.sh $(SOURCE)

.PHONY: compose-install
compose-install: ## Compose: install the store, or upgrade it if already installed
	@$(SCRIPTS)/compose-install.sh

.PHONY: compose-down
compose-down: ## Compose: stop it, keeping the database and media
	@$(SCRIPTS)/compose-down.sh

.PHONY: compose-destroy
compose-destroy: require-named-site ## Compose: stop it AND delete its volumes (prompts)
	@$(SCRIPTS)/compose-down.sh -v

.PHONY: compose-logs
compose-logs: ## Compose: tail logs across every service
	@$(SCRIPTS)/compose.sh logs -f --tail=20

.PHONY: compose-status
compose-status: ## Compose: what is running, and is it healthy
	@$(SCRIPTS)/compose.sh ps

.PHONY: compose-shell
compose-shell: ## Compose: shell into the PHP container
	@$(SCRIPTS)/compose.sh exec php-fpm bash

.PHONY: compose-cli
compose-cli: ## Compose: run bin/magento — make compose-cli ARGS="cache:flush"
	@$(SCRIPTS)/compose.sh exec php-cron php bin/magento $(ARGS)

# --- sites ------------------------------------------------------------------
# A site is a hostname, a small config file, a set of credentials and its own
# application tier. It shares the image, the Magento tree and — by default —
# one data tier, because that tier is 1.75 GiB of a 3.22 GiB stack and none of
# it is per-site work.

.PHONY: new-site
new-site: ## Stand up another store — make new-site SITE=second.test [MODE=exclusive] [SEED=none]
	@$(SCRIPTS)/site.sh new $(SITE) -m $(MODE) -s $(SEED) $(if $(YES),-y)

.PHONY: sites
sites: ## Every site: mode, state, whether it holds the background work
	@$(SCRIPTS)/site.sh list

# THIS ONE REFUSES TO DEFAULT, and that is the second half of the fix above.
# A destructive target aimed at whatever SITE happened to be is how the wrong
# store gets deleted; a destructive target is worth one extra word.
.PHONY: destroy-site
destroy-site: require-named-site ## Remove a store and everything it owns (prompts)
	@$(SCRIPTS)/site.sh destroy $(SITE) $(if $(YES),-y)

.PHONY: use
use: ## Give this site the consumers and cron, and park every other one
	@$(SCRIPTS)/site.sh use $(SITE)

.PHONY: park
park: ## Stop this site's background work; it keeps serving
	@$(SCRIPTS)/site.sh park $(SITE)

.PHONY: data-up
data-up: ## Start the shared data tier on its own
	@$(SCRIPTS)/site.sh data-up

.PHONY: data-down
data-down: ## Stop it (refuses while a site is attached)
	@$(SCRIPTS)/site.sh data-down

# --- build ------------------------------------------------------------------

.PHONY: tools
tools: ## Install kind and kubectl into ~/bin (the only target that downloads)
	@$(SCRIPTS)/install-tools.sh

.PHONY: image
image: ## Build the application image and load it into the cluster
ifeq ($(OVERLAY),dev)
	@$(SCRIPTS)/build-image.sh -t dev
else
	@$(SCRIPTS)/build-image.sh -t runtime
endif

.PHONY: image-all
image-all: ## Build both the dev and the runtime image
	@$(SCRIPTS)/build-image.sh -t dev
	@$(SCRIPTS)/build-image.sh -t runtime

.PHONY: secrets
secrets: ## Generate every credential; feeds both runtimes
	@$(SCRIPTS)/secrets.sh

.PHONY: sample-data
sample-data: ## Add Adobe Commerce sample data (needs repo.magento.com keys)
	@$(SCRIPTS)/sample-data.sh

# --- store snapshots --------------------------------------------------------
# A seed, not a backup. Installing from empty takes ~20 minutes and sample data
# longer again; a snapshot makes the next store about a minute. Database AND
# pub/media, because a catalogue without its images is not a store. Logical
# dump, so it restores into either runtime.

.PHONY: snapshot
snapshot: ## Capture the store as a reusable seed — make snapshot NAME=baseline
	@$(SCRIPTS)/store-snapshot.sh dump $(if $(NAME),-n $(NAME))

.PHONY: snapshot-restore
snapshot-restore: ## Load a snapshot (newest by default) — make snapshot-restore FILE=path
	@$(SCRIPTS)/store-snapshot.sh restore $(if $(FILE),-f $(FILE))

.PHONY: snapshots
snapshots: ## List what has been captured
	@$(SCRIPTS)/store-snapshot.sh list

# --- checks -----------------------------------------------------------------

.PHONY: smoke
smoke: ## Walk the acceptance criteria and report each one
	@$(SCRIPTS)/smoke-test.sh

# Every destructive site target depends on this. It cannot be satisfied by the
# default, only by naming the site — either way round:
#
#   make destroy-site SITE=second.test
#   make destroy-site second.test
.PHONY: require-named-site
require-named-site:
	@if [ -z "$(SITE_EXPLICIT)" ]; then \
		printf '\n  \033[31m[fail]\033[0m this destroys a store, so it will not guess which one.\n\n'; \
		printf '  SITE is currently \033[33m%s\033[0m, which is only the default — nothing on the\n' '$(SITE)'; \
		printf '  command line named it. Name the store you mean:\n\n'; \
		printf '      make $(firstword $(MAKECMDGOALS)) SITE=second.test\n'; \
		printf '      make $(firstword $(MAKECMDGOALS)) second.test\n\n'; \
		printf '  What exists:  make sites\n\n'; \
		exit 2; \
	fi

.PHONY: check
check: ## Everything a commit has to pass — lint, secrets, and no machine names
	@${SCRIPTS}/lint.sh
	@${SCRIPTS}/scan-secrets.sh
	@${SCRIPTS}/check-no-private-info.sh

.PHONY: private-info
private-info: ## Fail if anything in the tree names the machine it was written on
	@${SCRIPTS}/check-no-private-info.sh

.PHONY: scan
scan: ## A6 — fail if anything credential-shaped is committable
	@$(SCRIPTS)/scan-secrets.sh

.PHONY: verify-consumers
verify-consumers: ## Check MAGENTO_CONSUMERS and the consumer Deployments agree
	@$(SCRIPTS)/verify-consumers.sh -o $(OVERLAY)

.PHONY: verify-namespaces
verify-namespaces: ## Check a running store uses the namespaces its config declares
	@$(SCRIPTS)/verify-namespaces.sh -a

.PHONY: verify-image
verify-image: ## A7 — hash the application content of the built image
	@$(SCRIPTS)/verify-image.sh

.PHONY: render
render: ## Render the overlay to stdout without applying it
	@kubectl kustomize k8s/overlays/$(OVERLAY)

.PHONY: lint
lint: ## Check every site parses, both overlays render, and shellcheck passes
	@$(SCRIPTS)/lint.sh

# --- inspection -------------------------------------------------------------

.PHONY: status
status: ## Everything, at a glance
	@$(KC) get pods,svc,pvc,ingress,cronjob -o wide

.PHONY: top
top: ## A10 — requests and limits beside actual usage
	@echo
	@echo "  Declared (requests / limits):"
	@$(KC) get pods -o custom-columns=\
'NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,MEM_LIM:.spec.containers[*].resources.limits.memory'
	@echo
	@echo "  Actual (needs metrics-server; not installed by default):"
	@$(KC) top pods 2>/dev/null || echo "    metrics-server is not installed — see README, 'Setting resources from measurement'"
	@echo

.PHONY: events
events: ## Recent cluster events, newest last
	@$(KC) get events --sort-by=.lastTimestamp | tail -40

.PHONY: hosts
hosts: ## Print the /etc/hosts line the cluster needs
	@$(SCRIPTS)/hosts.sh

.PHONY: port-forward-mailhog
port-forward-mailhog: ## Cluster: MailHog UI on http://localhost:8025
	@$(KC) port-forward svc/mailhog 8025:8025

.PHONY: port-forward-rabbit
port-forward-rabbit: ## RabbitMQ management UI on http://localhost:15672
	@$(KC) port-forward svc/rabbitmq 15672:15672

.PHONY: port-forward-db
port-forward-db: ## Cluster: MariaDB on localhost:13306
	@$(KC) port-forward svc/db 13306:3306

.PHONY: rebuild
rebuild: ## End to end: destroy everything and build it back unattended
	@$(SCRIPTS)/cluster-down.sh -y
	@$(MAKE) --no-print-directory up
	@$(SCRIPTS)/smoke-test.sh
