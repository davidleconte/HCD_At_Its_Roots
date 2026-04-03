# HCD Docker Cluster — Developer Shortcuts
# Detects 'docker compose' (v2) vs 'docker-compose' (v1) automatically.

COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
EXPECTED_NODES ?= 6

.PHONY: help build up down restart status logs cqlsh demo demo-dry demo-score test clean monitoring monitoring-down

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build container images
	$(COMPOSE) build

up: ## Start the 6-node cluster (build if needed)
	$(COMPOSE) up -d --build

down: ## Stop the cluster (preserve volumes)
	$(COMPOSE) down

restart: down up ## Restart the cluster

destroy: ## Stop the cluster and delete all data volumes
	$(COMPOSE) down -v

status: ## Show nodetool status
	@docker exec hcd-node1 nodetool status

logs: ## Tail cluster logs
	$(COMPOSE) logs -f

cqlsh: ## Open CQL shell on node1
	docker exec -it hcd-node1 cqlsh

demo: ## Run the interactive entropy demo
	./scripts/demo-entropy.sh

demo-dry: ## Run the demo in dry-run mode (no cluster needed)
	./scripts/demo-entropy.sh --dry-run --no-pause

demo-full: ## Build cluster + run full automated demo
	./scripts/execute-full-demo.sh

demo-score: ## Validate all 54 modules (dry-run scorecard)
	./scripts/demo-entropy.sh --score

monitoring: ## Start Prometheus + Grafana (http://localhost:3000)
	$(COMPOSE) --profile monitoring up -d

monitoring-down: ## Stop Prometheus + Grafana
	$(COMPOSE) --profile monitoring down

test: ## Run all pytest tests
	pytest tests/ -v

wait: ## Wait until all nodes are UN (Up/Normal)
	@echo "Waiting for $(EXPECTED_NODES) nodes to reach UN status..."
	@count=0; \
	while [ "$$(docker exec hcd-node1 nodetool status 2>/dev/null | grep -c '^UN')" -ne "$(EXPECTED_NODES)" ]; do \
		printf "."; sleep 10; count=$$((count + 1)); \
		if [ $$count -ge 30 ]; then echo "\nTimeout."; exit 1; fi; \
	done; echo "\nAll $(EXPECTED_NODES) nodes are Up/Normal."

clean: ## Remove dangling images and build cache
	docker image prune -f
	docker builder prune -f
