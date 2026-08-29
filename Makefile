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
