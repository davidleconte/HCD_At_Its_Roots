#!/bin/bash
set -e

# HCD Full Demo Automated Executor
# This script builds the cluster and runs the entire entropy demo non-interactively.

log_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# Cleanup on failure: show status for debugging
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        log_info "Script failed (exit $exit_code). Showing cluster status for debugging:"
        docker exec hcd-node1 nodetool status 2>/dev/null || echo "(node1 unreachable)"
    fi
}
trap cleanup_on_error INT TERM EXIT

# 1. Pre-flight checks
if [ ! -f "hcd-1.2.3-bin.tar.gz" ]; then
    log_error "hcd-1.2.3-bin.tar.gz not found in root directory."
fi

if [ ! -f "scripts/demo-entropy.sh" ]; then
    log_error "scripts/demo-entropy.sh not found."
fi

# Detect compose command: prefer 'docker compose' (v2), fallback to 'docker-compose' (v1)
if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    log_error "Neither 'docker compose' nor 'docker-compose' found in PATH."
fi

# 2. Start Cluster
log_info "Starting HCD cluster..."
${COMPOSE} up -d --build

# 3. Wait for Health
EXPECTED_NODES=${EXPECTED_NODES:-6}
log_info "Waiting for ${EXPECTED_NODES} nodes to initialize (this may take 2-3 minutes)..."
MAX_RETRIES=30
COUNT=0
until [ "$(docker exec hcd-node1 nodetool status 2>/dev/null | grep -c '^UN')" -eq "$EXPECTED_NODES" ]; do
    echo -n "."
    sleep 10
    COUNT=$((COUNT + 1))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo ""
        docker exec hcd-node1 nodetool status 2>/dev/null || true
        log_error "Timeout waiting for cluster to reach ${EXPECTED_NODES} UN nodes after $((MAX_RETRIES * 10))s."
    fi
done
echo ""
log_success "Cluster is healthy with ${EXPECTED_NODES} nodes Up/Normal."

# 4. Run Demo
log_info "Executing Full Entropy & Consistency Demo..."
./scripts/demo-entropy.sh --no-pause

log_success "Full demo completed successfully!"
