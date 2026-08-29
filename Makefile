# aws-local-lab :: FR-1 core stack
# Every target works from a fresh checkout with only Docker installed.
#
# Sibling tracks (lab-terraform / lab-sampleapp / lab-integration) add their own
# targets BELOW the ">>> sibling-track targets" marker to avoid merge collisions.

SHELL := /bin/bash
.DEFAULT_GOAL := help

EDGE_PORT ?= 4566
LAB_ENDPOINT := http://localhost:$(EDGE_PORT)
export EDGE_PORT LAB_ENDPOINT

NETWORK := aws-local-lab
VOLUME  := aws-local-lab-data
COMPOSE := docker compose

# NO_TOKEN=1 layers the pinned pre-2026 community image (no auth token needed).
ifeq ($(NO_TOKEN),1)
COMPOSE += -f docker-compose.yml -f docker-compose.no-token.yml
endif

.PHONY: help up down restart logs ps status reset shell awslocal network

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

network: ## Create the external Docker network if absent
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || \
		{ echo "creating network $(NETWORK)"; docker network create $(NETWORK) >/dev/null; }

up: network ## Start LocalStack (NO_TOKEN=1 for the no-token image)
	$(COMPOSE) up -d
	@echo "waiting for the edge..."; \
	for i in $$(seq 1 30); do \
		curl -sf $(LAB_ENDPOINT)/_localstack/health >/dev/null 2>&1 && break; \
		sleep 2; \
	done
	@$(MAKE) --no-print-directory status

down: ## Stop and remove containers (keeps the volume)
	$(COMPOSE) down

restart: down up ## Restart the stack

logs: ## Follow LocalStack logs
	$(COMPOSE) logs -f --tail=100

ps: ## Show compose service status
	$(COMPOSE) ps

status: ## Print the service -> state health table
	@./bin/health-check.sh

reset: ## Stop, wipe the volume, prune the network
	-$(COMPOSE) down -v
	-docker volume rm $(VOLUME) 2>/dev/null || true
	-docker network rm $(NETWORK) 2>/dev/null || true
	@echo "lab reset to clean state"

shell: ## Open a shell inside the LocalStack container
	$(COMPOSE) exec localstack /bin/bash

# make awslocal ARGS="s3 ls"
awslocal: ## Run the AWS CLI against the lab: make awslocal ARGS="s3 ls"
	@./bin/awslocal $(ARGS)

# ======================================================================
# >>> sibling-track targets (lab-terraform / lab-sampleapp / lab-integration)
# Add track-specific targets below this line, each in its own block.
# ======================================================================

# --- lab-sampleapp (FR-3): end-to-end serverless CRUD sample -------------
.PHONY: sample-deploy sample-test sample-destroy

sample-deploy: ## Deploy the examples/serverless-crud sample to the lab
	@./examples/serverless-crud/deploy.sh

sample-test: ## Run the serverless-crud end-to-end test (needs sample-deploy)
	@python3 examples/serverless-crud/test/e2e_test.py

sample-destroy: ## Tear down the serverless-crud sample
	@./examples/serverless-crud/destroy.sh

# ----------------------------------------------------------------------
# lab-integration (FR-4 / FR-5) - see integration/README.md
# ----------------------------------------------------------------------
INTEG_DIR      := integration
SMOKE_COMPOSE  := $(COMPOSE) -f $(INTEG_DIR)/examples/docker-compose.smoke.yml
LOAD_COMPOSE   := $(COMPOSE) -f $(INTEG_DIR)/load-harness/docker-compose.yml
LOAD_REPLICAS  ?= 3
SNAPSHOT_DIR   ?= $(INTEG_DIR)/.snapshots
SNAPSHOT_NAME  ?= baseline

.PHONY: integrate-smoke load-up load-run load-fault load-down load-ps lab-seed lab-snapshot lab-restore

integrate-smoke: ## FR-4: run the Python + Node client examples as containers against the lab
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || $(MAKE) --no-print-directory network
	@curl -sf $(LAB_ENDPOINT)/_localstack/health >/dev/null 2>&1 || $(MAKE) --no-print-directory up NO_TOKEN=1
	$(SMOKE_COMPOSE) build
	@set -e; rc=0; \
	  $(SMOKE_COMPOSE) run --rm python-smoke || rc=$$?; \
	  $(SMOKE_COMPOSE) run --rm node-smoke || rc=$$?; \
	  $(SMOKE_COMPOSE) down --remove-orphans >/dev/null 2>&1 || true; \
	  if [ $$rc -ne 0 ]; then echo "integrate-smoke FAILED ($$rc)"; exit $$rc; fi; \
	  echo "integrate-smoke PASS"

load-up: ## FR-5: build + start Traefik and $(LOAD_REPLICAS) app replicas on the lab network
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || $(MAKE) --no-print-directory network
	@curl -sf $(LAB_ENDPOINT)/_localstack/health >/dev/null 2>&1 || $(MAKE) --no-print-directory up NO_TOKEN=1
	$(LOAD_COMPOSE) build
	$(LOAD_COMPOSE) up -d --scale app=$(LOAD_REPLICAS) traefik app
	@echo "balancer: http://localhost:$${LOAD_LB_PORT:-8080}  replicas: $(LOAD_REPLICAS)"

load-run: ## FR-5: run the k6 scenario through the balancer (LOAD_VUS, LOAD_HOLD)
	$(LOAD_COMPOSE) run --rm k6

load-fault: ## FR-5: kill app replicas mid-test with pumba (Ctrl-C to stop; FAULT_INTERVAL)
	$(LOAD_COMPOSE) run --rm pumba

load-ps: ## Show load-harness containers
	$(LOAD_COMPOSE) ps

load-down: ## FR-5: tear the load harness down
	$(LOAD_COMPOSE) --profile tools down --remove-orphans

lab-seed: ## FR-4: (re)create the baseline lab resources - the no-token regression baseline
	@curl -sf $(LAB_ENDPOINT)/_localstack/health >/dev/null 2>&1 || $(MAKE) --no-print-directory up NO_TOKEN=1
	@LAB_ENDPOINT=$(LAB_ENDPOINT) ./$(INTEG_DIR)/seed.sh

lab-snapshot: ## FR-4: tar the named volume to $(SNAPSHOT_DIR)/$(SNAPSHOT_NAME).tgz (see caveat in integration/README.md)
	@mkdir -p $(SNAPSHOT_DIR)
	@$(COMPOSE) stop localstack >/dev/null 2>&1 || true
	docker run --rm -v $(VOLUME):/data:ro -v $(PWD)/$(SNAPSHOT_DIR):/backup alpine \
		tar czf /backup/$(SNAPSHOT_NAME).tgz -C /data .
	@$(COMPOSE) start localstack >/dev/null 2>&1 || true
	@echo "snapshot -> $(SNAPSHOT_DIR)/$(SNAPSHOT_NAME).tgz"

lab-restore: ## FR-4: restore the named volume from $(SNAPSHOT_DIR)/$(SNAPSHOT_NAME).tgz
	@test -f $(SNAPSHOT_DIR)/$(SNAPSHOT_NAME).tgz || { echo "no snapshot $(SNAPSHOT_DIR)/$(SNAPSHOT_NAME).tgz"; exit 1; }
	@$(COMPOSE) stop localstack >/dev/null 2>&1 || true
	docker run --rm -v $(VOLUME):/data -v $(PWD)/$(SNAPSHOT_DIR):/backup alpine \
		sh -c "rm -rf /data/* && tar xzf /backup/$(SNAPSHOT_NAME).tgz -C /data"
	@$(COMPOSE) start localstack >/dev/null 2>&1 || true
	@echo "restored from $(SNAPSHOT_DIR)/$(SNAPSHOT_NAME).tgz"
