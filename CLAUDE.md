# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dockerized multi-node IBM HCD (Hyper-Converged Database) cluster for development, testing, and demos. Runs a 6-node cluster across 2 datacenters (dc1: nodes 1-3, dc2: nodes 4-6) on a single machine using Docker Compose with static IPs on a `172.28.0.0/24` bridge network.

**Prerequisite:** `hcd-1.2.3-bin.tar.gz` must be placed in the project root before building.

## Common Commands

```bash
# Makefile shortcuts (auto-detects docker compose v1/v2)
make up              # build and start 6-node cluster
make down            # stop cluster (preserve volumes)
make destroy         # stop cluster and delete all data
make status          # nodetool status
make cqlsh           # open CQL shell on node1
make demo            # interactive entropy demo
make demo-dry        # dry-run (no cluster needed)
make demo-full       # build cluster + run full demo
make demo-score      # validate all 84 modules (scorecard)
make demo-ransomware # run DORA ransomware demo (modules 72-78)
make minio           # start MinIO WORM storage
make minio-down      # stop MinIO
make api             # start Data API (http://localhost:8181)
make api-down        # stop Data API
make monitoring      # start Prometheus + Grafana (http://localhost:3000)
make monitoring-down # stop Prometheus + Grafana
make test            # run all pytest tests
make lint            # shellcheck + ruff
make validate        # validate docker-compose.yml syntax
make wait            # wait until all nodes are UN

# Direct commands (equivalent)
docker compose up -d --build
docker exec hcd-node1 nodetool status
./scripts/demo-entropy.sh 3              # run specific module (0-83)
./scripts/demo-entropy.sh --dry-run      # dry-run mode
./scripts/demo-entropy.sh --score        # automated 84-module scorecard

# Generate topology for different cluster sizes
python3 scripts/generate-topology.py -i                        # interactive
python3 scripts/generate-topology.py --nodes 5                 # single DC
python3 scripts/generate-topology.py --datacenters "dc1:3,dc2:2"  # multi-DC

# Run tests (requires pytest and pyyaml)
pytest tests/
pytest tests/test_demo_entropy.py        # demo script tests (dry-run)
pytest tests/test_topology.py            # topology generator tests
pytest tests/test_scripts.py             # script syntax + helper tests
pytest tests/test_topology_unit.py       # topology generator unit tests
```

## Architecture

- **Dockerfile** - Single image based on `eclipse-temurin:11-jre`. Installs HCD from local tarball, sets up Python 3.11 via `uv`, creates wrapper scripts for `nodetool`/`cqlsh`/etc. that set `HCD_CONF` paths. Runs as non-root `cassandra` user (UID/GID 999).
- **docker-compose.yml** - Defines 6 services using YAML anchors (`x-hcd-common`). Node 1 is the primary seed; nodes 2-6 depend on node 1's health. Seeds are nodes 1 and 4 (one per DC). Port 9042 bound to localhost on node 1. Hardened with `cap_drop: ALL`, `no-new-privileges`, ulimits (`nofile: 100000`, `memlock: unlimited`), and CPU/memory limits.
- **config/cassandra.yaml.template** - Cassandra config template using `${ENV_VAR}` substitution, processed by `envsubst` at container startup. Includes CDC, audit logging, and guardrails configuration for modules 25-27.
- **scripts/docker-entrypoint.sh** - Generates `cassandra.yaml` from template, writes rack/DC properties, waits for seed node with exponential backoff before starting HCD.
- **Makefile** - Developer shortcuts with auto-detection of `docker compose` (v2) vs `docker-compose` (v1).
- **scripts/generate-topology.py** - Generates `docker-compose.yml` for arbitrary cluster sizes and multi-DC configurations. Uses atomic file writes and validates DC node count consistency.
- **scripts/demo-entropy.sh** - Interactive 84-module demo (modules 0-83) in 10 parts. Parts 1-6 cover entropy, consistency, SAI, vector search, CDC, audit logging, guardrails, data modeling, compaction, compression, DC expansion (with chaos test), backup/restore, rolling restart, repair, stress testing, security (RBAC + TLS), GDPR data sovereignty, driver policies, ACID model, batches, LWT, sagas, and consistency decision framework. Part 7 (Enterprise, modules 54-61) adds: HCD Data API (REST/JSON via HTTP), multi-tenant isolation, node decommission, disaster recovery, silent data corruption, cross-service saga, LWT contention, and repair deep-dive. Part 8 (Ops Deep-Dives, modules 62-71) adds: live RBAC demo, encryption at rest (TDE), commitlog crash recovery, hint expiration & data gaps, dynamic RF change, streaming & bootstrap monitoring, materialized views, nodetool ops deep-dive, cross-DC consistency window, and bloom filter & cache tuning. Part 9 (DORA Ransomware, modules 72-78) adds: kill chain overview, WORM backup to MinIO Object Lock, commitlog archiving to WORM, ransomware attack simulation (TRUNCATE + snapshot wipe), recovery from WORM backups, DC failover under attack, and DORA compliance scorecard with K8ssandra auto-healing. Part 10 (Production Essentials, modules 79-83) adds: counter columns, prepared statements & driver best practices, JVM & GC tuning, CQL aggregation functions, and collection types deep-dive (frozen vs non-frozen). Supports `--dry-run`, `--no-pause`, and `--score` flags. Progress counter `[N/83]` in every module header.
- **config/prometheus.yml** - Prometheus scrape config for JMX exporter metrics on all 6 nodes (port 9404).
- **config/jmx-exporter.yml** - JMX-to-Prometheus metric mapping for Cassandra thread pools, latencies, compaction, hints, and caches.
- **config/grafana/** - Grafana provisioning (datasource + dashboard). Pre-built dashboard shows write/read p99, thread pool activity, compaction pending, dropped messages, and hints.
- **scripts/driver-demo.py** - Python helper script using the DataStax cassandra-driver for modules 43-46. Subcommands: `token-aware`, `speculative`, `dc-failover`, `retry-policies`. Use `--local-dc` to override the default datacenter (default: `dc1`).

## Code Style

- Shell scripts: `set -e`, quote variable expansions (`"${VAR}"`), lowercase for locals, UPPERCASE for env vars
- YAML: 2-space indentation, use anchors to reduce duplication
- Docker: specific base image tags, minimize layers, clean caches in same layer, non-root user
