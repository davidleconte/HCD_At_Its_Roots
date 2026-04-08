# HCD Docker Cluster — Developer Shortcuts
# Detects 'docker compose' (v2) vs 'docker-compose' (v1) automatically.

COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
EXPECTED_NODES ?= 6

.DEFAULT_GOAL := help

.PHONY: help build up down destroy restart status logs cqlsh demo demo-dry demo-full demo-score demo-ransomware demo-part minio minio-down test lint validate wait clean monitoring monitoring-down api api-down

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build container images
	@test -f hcd-1.2.3-bin.tar.gz || (echo "ERROR: hcd-1.2.3-bin.tar.gz not found in project root. See README.md Prerequisites." >&2; exit 1)
	$(COMPOSE) build

up: ## Start the 6-node cluster (build if needed)
	@test -f hcd-1.2.3-bin.tar.gz || (echo "ERROR: hcd-1.2.3-bin.tar.gz not found in project root. See README.md Prerequisites." >&2; exit 1)
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

demo-score: ## Validate all 79 modules (dry-run scorecard)
	./scripts/demo-entropy.sh --score

demo-ransomware: ## Run DORA ransomware demo (modules 72-78)
	@for m in 72 73 74 75 76 77 78; do ./scripts/demo-entropy.sh $$m; done

demo-part: ## Run a demo part (1-9): make demo-part P=3
	@case "$(P)" in \
		1) for m in $$(seq 0 13);  do ./scripts/demo-entropy.sh $$m; done ;; \
		2) for m in $$(seq 14 24); do ./scripts/demo-entropy.sh $$m; done ;; \
		3) for m in $$(seq 25 37); do ./scripts/demo-entropy.sh $$m; done ;; \
		4) for m in $$(seq 38 42); do ./scripts/demo-entropy.sh $$m; done ;; \
		5) for m in $$(seq 43 47); do ./scripts/demo-entropy.sh $$m; done ;; \
		6) for m in $$(seq 48 53); do ./scripts/demo-entropy.sh $$m; done ;; \
		7) for m in $$(seq 54 61); do ./scripts/demo-entropy.sh $$m; done ;; \
		8) for m in $$(seq 62 71); do ./scripts/demo-entropy.sh $$m; done ;; \
		9) for m in $$(seq 72 78); do ./scripts/demo-entropy.sh $$m; done ;; \
		*) echo "Usage: make demo-part P=N (where N is 1-9)" >&2; \
		   echo "  1=Foundations  2=Failures  3=Operations  4=Performance  5=Drivers" >&2; \
		   echo "  6=Transactions 7=Enterprise 8=Deep-Dives 9=DORA" >&2; exit 1 ;; \
	esac

minio: ## Start MinIO WORM storage (S3-compatible)
	$(COMPOSE) --profile ransomware up -d minio

minio-down: ## Stop MinIO
	$(COMPOSE) --profile ransomware down

api: ## Start Data API (http://localhost:8181)
	$(COMPOSE) --profile api up -d

api-down: ## Stop Data API
	$(COMPOSE) --profile api down

monitoring: ## Start Prometheus + Grafana (http://localhost:3000)
	$(COMPOSE) --profile monitoring up -d

monitoring-down: ## Stop Prometheus + Grafana
	$(COMPOSE) --profile monitoring down

test: ## Run all pytest tests
	pytest tests/ -v

lint: ## Lint shell scripts (shellcheck) and Python (ruff)
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck scripts/*.sh; else echo "shellcheck not installed, skipping"; fi
	@if command -v ruff >/dev/null 2>&1; then ruff check scripts/*.py tests/*.py; else echo "ruff not installed, skipping"; fi

validate: ## Validate docker-compose.yml syntax
	@$(COMPOSE) config >/dev/null && echo "docker-compose.yml is valid"

wait: ## Wait until all nodes are UN (Up/Normal)
	@echo "Waiting for $(EXPECTED_NODES) nodes to reach UN status..."
	@count=0; \
	while [ "$$(docker exec hcd-node1 nodetool status 2>/dev/null | grep -c '^UN')" -ne "$(EXPECTED_NODES)" ]; do \
		printf "."; sleep 10; count=$$((count + 1)); \
		if [ $$count -ge 30 ]; then echo ""; echo "Timeout."; exit 1; fi; \
	done; echo ""; echo "All $(EXPECTED_NODES) nodes are Up/Normal."

clean: ## Remove dangling images and build cache
	docker image prune -f
	docker builder prune -f
