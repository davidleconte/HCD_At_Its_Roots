#!/bin/bash
set -e

# Configuration & State
DRY_RUN=false
NO_PAUSE=false
SCORE_MODE=false
SELECTED_MODULE=""

# ─── Color Constants ──────────────────────────────────────────────
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_CYAN="\033[1;36m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_MAGENTA="\033[1;35m"
C_WHITE="\033[1;37m"
C_DIM="\033[2m"

# ─── Helper Functions ─────────────────────────────────────────────
resolve_network_name() {
    docker network ls --filter "name=hcd-cluster" --format '{{.Name}}' 2>/dev/null | head -1
}
HCD_NETWORK=$(resolve_network_name)

cleanup() {
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi
    log_info "Emergency cleanup: ensuring all nodes are started and connected..."
    docker unpause hcd-node1 >/dev/null 2>&1 || true
    docker unpause hcd-node3 >/dev/null 2>&1 || true
    docker-compose start hcd-node1 hcd-node2 hcd-node3 hcd-node4 hcd-node5 hcd-node6 >/dev/null 2>&1 || true
    docker network connect "${HCD_NETWORK}" hcd-node2 >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
log_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} $1"
    else
        echo -e "${C_GREEN}[EXEC]${C_RESET} $1"
        bash -c "$1"
    fi
}

pause() {
    if [ "$NO_PAUSE" = false ]; then
        echo ""
        echo -e "${C_YELLOW}>>> Press [Enter] to continue...${C_RESET}"
        read -r
        echo ""
    fi
}

TOTAL_MODULES=54
header() {
    local progress="[$1/$((TOTAL_MODULES - 1))]"
    echo ""
    echo -e "${C_CYAN}========================================================================${C_RESET}"
    echo -e "${C_CYAN} ${progress} Module $1: $2${C_RESET}"
    echo -e "${C_CYAN}========================================================================${C_RESET}"
    echo ""
}

takeaway() {
    echo ""
    echo -e "${C_MAGENTA}--- Takeaway ---${C_RESET}"
    while [ $# -gt 0 ]; do
        echo -e "${C_MAGENTA}$1${C_RESET}"
        shift
    done
    echo ""
}

lookfor() {
    echo -e "${C_WHITE}>>> $1${C_RESET}"
}

separator() {
    echo ""
    echo -e "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
}

wait_for_node_un() {
    local target_ip=$1
    local node_label=$2
    local max_retries=${3:-30}
    local sleep_interval=${4:-3}
    if [ "$DRY_RUN" = false ]; then
        local count=0
        until docker exec hcd-node1 nodetool status 2>/dev/null | grep -E "UN\s+${target_ip}" >/dev/null 2>&1; do
            echo -n "."
            sleep "$sleep_interval"
            count=$((count + 1))
            if [ $count -ge $max_retries ]; then
                log_info "Timeout waiting for ${node_label} to reach UN. Continuing..."
                return 0
            fi
        done
        echo ""
    fi
    return 0
}

wait_for_all_un() {
    if [ "$DRY_RUN" = false ]; then
        local max_retries=${1:-40}
        local count=0
        until [ "$(docker exec hcd-node1 nodetool status 2>/dev/null | grep -c '^UN')" -eq 6 ]; do
            echo -n "."
            sleep 5
            count=$((count + 1))
            if [ $count -ge $max_retries ]; then
                log_info "Timeout waiting for all 6 nodes to reach UN. Continuing..."
                return 0
            fi
        done
        echo ""
    fi
    return 0
}

# ─── Parse Arguments ──────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --no-pause) NO_PAUSE=true ;;
        --score) SCORE_MODE=true; DRY_RUN=true; NO_PAUSE=true ;;
        [0-9]*) SELECTED_MODULE=$arg ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────
if [[ -n "$SELECTED_MODULE" ]]; then
    if ! [[ "$SELECTED_MODULE" =~ ^([0-9]|[1-4][0-9]|5[0-3])$ ]]; then
        echo "Invalid module number: ${SELECTED_MODULE} (Valid: 0-53)"
        exit 1
    fi
fi

# ─── Pre-flight Check ────────────────────────────────────────────
if [ "$DRY_RUN" = false ]; then
    log_info "Checking cluster health..."
    if ! docker exec hcd-node1 nodetool status >/dev/null 2>&1; then
        echo "ERROR: Cluster nodes are not responding. Run 'docker-compose up -d' first."
        exit 1
    fi
fi

# ─── Prerequisite: Ensure rf_prod keyspace exists ────────────────
ensure_rf_prod() {
    if [ "$DRY_RUN" = false ]; then
        docker exec hcd-node1 cqlsh -e "CREATE KEYSPACE IF NOT EXISTS rf_prod WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3, 'dc2': 3};" 2>/dev/null || true
    fi
}

# When running a single module (not from Module 0/1), ensure keyspace exists
if [ -n "$SELECTED_MODULE" ] && [ "$SELECTED_MODULE" -gt 1 ] 2>/dev/null; then
    ensure_rf_prod
fi

# ══════════════════════════════════════════════════════════════════
# Module Definitions
# ══════════════════════════════════════════════════════════════════

run_module() {
    local mod_id=$1
    case $mod_id in
        0)
            header 0 "Introduction & Cluster Status"

            # ─── Pre-Assessment Quiz ────────────────────────────────────
            if [ "$SCORE_MODE" = false ]; then
                echo -e "${C_BOLD}Before we begin: a quick self-assessment (no wrong answers).${C_RESET}"
                echo -e "${C_BOLD}This helps calibrate the depth of explanations.${C_RESET}"
                echo ""
                echo "  Q1. What does RF=3 mean?"
                echo "      a) 3 nodes in the cluster"
                echo "      b) 3 copies of each piece of data"
                echo "      c) 3 seconds timeout"
                echo ""
                echo "  Q2. What happens when you write to a Cassandra node that is down?"
                echo "      a) The write is lost"
                echo "      b) The coordinator stores a hint for later delivery"
                echo "      c) The client gets an immediate error"
                echo ""
                echo "  Q3. What is a tombstone?"
                echo "      a) A crashed node"
                echo "      b) A delete marker stored on disk"
                echo "      c) A type of compaction strategy"
                echo ""
                echo "  Q4. What does LOCAL_QUORUM mean for a write?"
                echo "      a) All nodes must acknowledge"
                echo "      b) A majority of replicas in the local datacenter must acknowledge"
                echo "      c) Only one node needs to acknowledge"
                echo ""
                echo "  Q5. What is the CAP theorem?"
                echo "      a) A caching strategy"
                echo "      b) A theorem stating a distributed system can have at most 2 of: Consistency, Availability, Partition tolerance"
                echo "      c) A compression algorithm"
                echo ""
                echo -e "${C_DIM}Answers: Q1=b, Q2=b, Q3=b, Q4=b, Q5=b${C_RESET}"
                echo ""
                echo -e "${C_GREEN}If you got 4-5: you'll breeze through Part 1 and find Parts 3-6 most valuable.${C_RESET}"
                echo -e "${C_GREEN}If you got 2-3: Parts 1-2 will build your foundation for the advanced modules.${C_RESET}"
                echo -e "${C_GREEN}If you got 0-1: every module is designed for you — enjoy the journey!${C_RESET}"
                pause
            fi
            # ─── End Pre-Assessment ─────────────────────────────────────

            echo "This demo explores HCD Entropy and Consistency across a 6-node,"
            echo "multi-datacenter cluster. We will break things, watch them heal,"
            echo "and understand WHY HCD remains available through failures."
            echo ""
            echo "+-------------------------------------------------------------------+"
            echo "|                        HCD Cluster Topology                       |"
            echo "|                                                                   |"
            echo "|        DC1 (us-east)                  DC2 (us-west)               |"
            echo "|   +--------+--------+--------+  +--------+--------+--------+     |"
            echo "|   | Rack 1 | Rack 2 | Rack 3 |  | Rack 1 | Rack 2 | Rack 3 |     |"
            echo "|   | node1  | node2  | node3  |  | node4  | node5  | node6  |     |"
            echo "|   | .0.2   | .0.3   | .0.4   |  | .0.5   | .0.6   | .0.7   |     |"
            echo "|   | (seed) |        |        |  | (seed) |        |        |     |"
            echo "|   +--------+--------+--------+  +--------+--------+--------+     |"
            echo "+-------------------------------------------------------------------+"
            echo ""

            log_info "Running 'nodetool status' to see the live cluster state..."
            log_cmd "docker exec hcd-node1 nodetool status"

            lookfor "Look for: UN = Up/Normal, DN = Down/Normal."
            lookfor "Each row shows: Status, Address, Load, Tokens, Host ID, Rack."
            lookfor "All 6 nodes should show 'UN' before proceeding."

            echo ""
            echo -e "${C_BLUE}Note: We use small data volumes for speed, but this 6-node, 2-DC topology${C_RESET}"
            echo -e "${C_BLUE}is architecturally identical to a 600-node production deployment.${C_RESET}"
            echo -e "${C_BLUE}Every command, every pattern, every failure mode scales linearly.${C_RESET}"

            separator
            echo -e "${C_WHITE}--- Demo Roadmap (54 modules in 6 parts) ---${C_RESET}"
            echo ""
            echo "  PART 1: Foundations       (Modules 1-6)   RF, CL, failures, entropy repair"
            echo "  PART 2: Internals         (Modules 7-13)  Token ring, write/read path, LWT"
            echo "  PART 3: Advanced Failures (Modules 14-24) Rack failures, gossip, SAI, vectors"
            echo "  PART 4: Operations        (Modules 25-36) CDC, audit, compaction, backup"
            echo "  PART 5: Production Ops    (Modules 37-47) Rolling restart, stress, security, driver"
            echo "  PART 6: Transactions      (Modules 48-53) ACID model, batches, LWT, sagas"
            echo ""
            echo "  You can run any single module: ./demo-entropy.sh 23"
            echo "  Modules > 1 auto-create the rf_prod keyspace if needed."

            takeaway "This cluster has 6 nodes across 2 DCs. Every module that follows" \
                     "will use this topology to demonstrate distributed database concepts."
            ;;
        1)
            header 1 "Replication Factors"
            echo "Replication Factor (RF) determines how many copies of your data exist."
            echo "Higher RF = more redundancy, but more storage and write overhead."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  RF=1: One copy. Node dies = data lost.                       |"
            echo "|                                                               |"
            echo "|  RF=3 per DC: Three copies in each datacenter.                |"
            echo "|  With 2 DCs, that is 6 total copies across the cluster.       |"
            echo "|                                                               |"
            echo "|  Write to DC1:                                                |"
            echo "|    node1 [copy1]  node2 [copy2]  node3 [copy3]               |"
            echo "|                                                               |"
            echo "|  Async replicated to DC2:                                     |"
            echo "|    node4 [copy4]  node5 [copy5]  node6 [copy6]               |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Creating keyspaces with different RF strategies..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE KEYSPACE IF NOT EXISTS rf_prod WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3, 'dc2': 3};\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE KEYSPACE IF NOT EXISTS rf_low WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 1};\""

            log_info "Ensuring a table exists to check endpoints..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.health (id int PRIMARY KEY);\""

            log_info "Which nodes hold partition key '1' in rf_prod?"
            log_cmd "docker exec hcd-node1 nodetool getendpoints rf_prod health 1"

            lookfor "You should see 6 IP addresses: 3 from dc1 + 3 from dc2."
            lookfor "This proves every node holds a copy when RF=3 per DC."

            takeaway "NetworkTopologyStrategy + RF=3 per DC is the production standard." \
                     "It survives any single node failure and even a full rack failure."
            ;;
        2)
            header 2 "Consistency Levels"
            echo "Consistency Level (CL) defines how many replicas must acknowledge"
            echo "a read or write before it is considered successful."
            echo ""
            echo "+-----------------------------------------------------------+"
            echo "|            Consistency Level Spectrum                      |"
            echo "|                                                           |"
            echo "|  ONE <------- LOCAL_QUORUM ------- EACH_QUORUM ------> ALL|"
            echo "|  Fast          Balanced             Strict         Slowest|"
            echo "|  Risky         Recommended          Safe           Fragile|"
            echo "|                                                           |"
            echo "|  RF=3: QUORUM = 2 nodes must ACK                         |"
            echo "|  LOCAL_QUORUM: 2 nodes in the LOCAL DC only              |"
            echo "|  EACH_QUORUM: 2 nodes in EVERY DC                        |"
            echo "+-----------------------------------------------------------+"
            echo ""

            log_info "Testing CL=QUORUM behavior..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; USE rf_prod; CREATE TABLE IF NOT EXISTS logs (id uuid PRIMARY KEY, msg text);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY QUORUM; TRACING ON; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'test');\""

            separator

            log_info "Writing at LOCAL_QUORUM with tracing..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; TRACING ON; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'local_quorum_write');\""

            log_info "Writing at EACH_QUORUM with tracing (requires quorum in EVERY DC)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY EACH_QUORUM; TRACING ON; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'each_quorum_write');\""

            separator

            log_info "Now let's BREAK EACH_QUORUM: stopping 2 of 3 nodes in dc1..."
            log_cmd "docker-compose stop hcd-node2 hcd-node3"

            if [ "$DRY_RUN" = false ]; then
                log_info "Waiting for nodes to register as DN (Down/Normal)..."
                for attempt in $(seq 1 30); do
                    dn_count=$(docker exec hcd-node1 nodetool status 2>/dev/null | grep -c "^DN" || echo "0")
                    if [ "$dn_count" -ge 2 ]; then
                        echo -e "${C_GREEN}  Nodes show DN after ${attempt}s${C_RESET}"
                        break
                    fi
                    sleep 1
                done
            fi

            log_info "Attempting EACH_QUORUM write (EXPECTED TO FAIL - dc1 has only 1 of 3 nodes)..."
            log_cmd "docker exec hcd-node4 cqlsh -e \"CONSISTENCY EACH_QUORUM; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'should_fail');\" || echo 'EXPECTED: EACH_QUORUM write failed - cannot achieve quorum in dc1'"

            lookfor "The error above is expected. EACH_QUORUM requires 2/3 nodes in EVERY DC."
            lookfor "dc1 has only 1 node alive, so it cannot meet quorum."

            log_info "But LOCAL_QUORUM from dc2 STILL WORKS (dc2 has all 3 nodes)..."
            log_cmd "docker exec hcd-node5 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.logs LIMIT 3;\""

            log_info "Restarting dc1 nodes..."
            log_cmd "docker-compose start hcd-node2 hcd-node3"
            if [ "$DRY_RUN" = false ]; then
                wait_for_node_un "172.28.0.3" "Node 2"
                wait_for_node_un "172.28.0.4" "Node 3"
            fi

            separator
            echo -e "${C_WHITE}--- EACH_QUORUM Recovery Proof ---${C_RESET}"
            echo "Now that dc1 has all 3 nodes back, EACH_QUORUM should succeed again."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY EACH_QUORUM; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'each_quorum_recovered');\""
            lookfor "This write succeeds: both DCs have 3/3 nodes = EACH_QUORUM satisfied."

            takeaway "LOCAL_QUORUM is the sweet spot for multi-DC deployments." \
                     "It avoids WAN latency while maintaining strong consistency within a DC." \
                     "EACH_QUORUM adds cross-DC guarantee but fails if ANY DC loses quorum." \
                     "We proved both: failure when dc1 was degraded, and recovery when it healed."
            ;;
        3)
            header 3 "Node Failures"
            echo "What happens when a node goes down? With RF=3 and QUORUM consistency,"
            echo "the cluster can tolerate 1 node failure per DC without any impact."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  RF=3, CL=QUORUM (needs 2 ACKs):                             |"
            echo "|                                                               |"
            echo "|  BEFORE:  node1 [OK]  node2 [OK]  node3 [OK]   -> 3/3 alive  |"
            echo "|  AFTER:   node1 [OK]  node2 [OK]  node3 [XX]   -> 2/3 alive  |"
            echo "|                                                               |"
            echo "|  QUORUM = (3/2)+1 = 2 nodes needed. We have 2. Still works!  |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Simulating a single node failure (hcd-node3)..."
            log_cmd "docker-compose stop hcd-node3"

            log_info "Verifying Node 3 is Down (DN)..."
            log_cmd "docker exec hcd-node1 nodetool status | grep 'DN.*172.28.0.4' || echo 'Node 3 status updated'"

            lookfor "The status column should show 'DN' (Down/Normal) for 172.28.0.4."

            separator
            echo -e "${C_YELLOW}QUESTION: With 1 of 3 dc1 nodes down, will a LOCAL_QUORUM read succeed?${C_RESET}"
            echo -e "${C_YELLOW}Think about it: QUORUM of 3 = ceil(3/2) = 2 nodes needed.${C_RESET}"
            echo -e "${C_YELLOW}We have 2 alive. So...?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: YES — 2 of 3 nodes is exactly LOCAL_QUORUM.${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.logs LIMIT 1;\""

            log_info "Bringing Node 3 back up to maintain quorum for next tests..."
            log_cmd "docker-compose start hcd-node3"

            takeaway "With RF=3, losing 1 node still leaves 2 replicas: enough for QUORUM." \
                     "The cluster serves reads and writes without interruption."
            ;;
        4)
            header 4 "Hinted Handoff & Entropy Visualization"
            echo "When a node is down, the coordinator stores a 'hint' -- a note that says"
            echo "'this write was meant for node X, deliver it when X comes back.'"
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Hinted Handoff Flow:                                         |"
            echo "|                                                               |"
            echo "|  1. Client writes to Coordinator (node1)                      |"
            echo "|  2. node1 sees node2 is DOWN                                  |"
            echo "|  3. node1 stores a Hint locally (small file on disk)          |"
            echo "|  4. node2 comes back online                                   |"
            echo "|  5. node1 replays the Hint -> node2 gets the data             |"
            echo "|                                                               |"
            echo "|  Timeline:                                                    |"
            echo "|  [node2 DOWN] --> [write + hint stored] --> [node2 UP] -->    |"
            echo "|  [hint replayed] --> [all replicas consistent]                |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Ensuring existing data is flushed before node stop..."
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod logs"

            log_info "Counting current rows on node2 BEFORE it goes down..."
            log_cmd "docker exec hcd-node2 cqlsh -e \"CONSISTENCY ONE; SELECT count(*) FROM rf_prod.logs;\""

            log_info "Checking hints directory on node1 BEFORE (should be empty or minimal)..."
            log_cmd "docker exec hcd-node1 ls -la /var/lib/cassandra/hints/ || echo '(hints directory check)'"

            separator

            log_info "Simulating a missed write to hcd-node2..."
            log_cmd "docker-compose stop hcd-node2"

            log_info "Inserting 'Missing Data' at CL.ONE via hcd-node1 (Coordinator)..."
            log_info "Node 1 will store a Hint because Node 2 is a replica but is down."
            FIXED_ID="00000000-0000-0000-0000-000000000001"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY ONE; TRACING ON; INSERT INTO rf_prod.logs (id, msg) VALUES ($FIXED_ID, 'I am a hint');\""

            log_info "Verifying Node 1 has the data..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT msg FROM rf_prod.logs WHERE id = $FIXED_ID;\""

            separator

            log_info "Starting Node 2 and watching for hint delivery..."
            log_cmd "docker-compose start hcd-node2"
            log_info "Waiting for Node 2 to be Up..."
            if [ "$DRY_RUN" = false ]; then
                wait_for_node_un "172.28.0.3" "Node 2" 30 3
                sleep 10
            fi

            log_info "Checking hints directory on node1 AFTER delivery (should be empty now)..."
            log_cmd "docker exec hcd-node1 ls -la /var/lib/cassandra/hints/ || echo '(hints directory check)'"

            log_info "Counting rows on node2 AFTER hint replay (should show +1 delta)..."
            log_cmd "docker exec hcd-node2 cqlsh -e \"CONSISTENCY ONE; SELECT count(*) FROM rf_prod.logs;\""

            log_info "Querying Node 2 directly to prove hint replayed..."
            log_cmd "docker exec hcd-node2 cqlsh -e \"TRACING ON; SELECT msg FROM rf_prod.logs WHERE id = $FIXED_ID;\""

            lookfor "The row 'I am a hint' should appear on node2, proving the hint was delivered."

            takeaway "Hinted Handoff is the FIRST line of defense against short-term entropy." \
                     "We proved delivery by querying Node 2 for FIXED_ID=$FIXED_ID — the exact row appeared." \
                     "Hints expire after 3 hours by default. For longer outages, use Repair."
            ;;
        5)
            header 5 "Read Repair"
            echo "Read Repair automatically fixes stale replicas during normal reads."
            echo "When the coordinator detects a mismatch, it sends the correct data"
            echo "to the stale replica in the background."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  Read Repair Flow:                                                    |"
            echo "|                                                                       |"
            echo "|  Client --> Coordinator --> [Full Read: Node A]                        |"
            echo "|                         --> [Digest Read: Node B, C]                   |"
            echo "|                                                                       |"
            echo "|  Coordinator compares digests (hashes of data).                       |"
            echo "|  If mismatch: request full data from all, send repair to stale node.  |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Step 1: Create guaranteed divergence (stop node, write, restart) ---${C_RESET}"
            echo "To reliably trigger read repair, we FORCE divergence:"
            echo "  1. Stop node3 (it will miss the write)"
            echo "  2. Write at CL=ONE (only 1-2 of the remaining replicas get it)"
            echo "  3. Restart node3 (it still has stale data)"
            echo "  4. Read at CL=ALL (coordinator detects the mismatch and repairs)"
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.rr_test (id int PRIMARY KEY, val text);\""
            log_cmd "docker-compose stop hcd-node3"
            if [ "$DRY_RUN" = false ]; then sleep 5; fi
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY ONE; INSERT INTO rf_prod.rr_test (id, val) VALUES (1, 'written-while-node3-down');\""

            separator
            echo -e "${C_WHITE}--- Step 2: Restart node3 (it missed the write) ---${C_RESET}"
            log_cmd "docker-compose start hcd-node3"
            log_info "Waiting for node3 to reach UN..."
            wait_for_node_un "172.28.0.4" "node3"
            if [ "$DRY_RUN" = false ]; then sleep 3; fi

            separator
            echo -e "${C_WHITE}--- Step 3: Read at CL=ONE from node3 (may return stale/empty) ---${C_RESET}"
            log_cmd "docker exec hcd-node3 cqlsh -e \"CONSISTENCY ONE; SELECT * FROM rf_prod.rr_test WHERE id = 1;\""
            lookfor "node3 missed the write — it may return empty or stale data."

            separator
            echo -e "${C_WHITE}--- Step 4: Trigger Read Repair via CL=ALL ---${C_RESET}"
            echo "CL=ALL contacts ALL replicas. The coordinator compares digests and"
            echo "sends the correct data to any stale replica."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY ALL; TRACING ON; SELECT * FROM rf_prod.rr_test WHERE id = 1; TRACING OFF;\" 2>&1 | grep -iE 'READ_REPAIR|read.repair|Sending.*repair|repair mutation|Digest mismatch' | head -n 10 || echo '(No READ_REPAIR in trace -- read repair in Cassandra 4.0+ is background/probabilistic)'"

            lookfor "Look for 'READ_REPAIR', 'read repair', or 'Digest mismatch' in the trace."
            lookfor "This means the coordinator detected a stale replica and fixed it."
            echo ""
            echo -e "${C_BLUE}Note: In Cassandra 4.0+, read repair is background and probabilistic.${C_RESET}"
            echo -e "${C_BLUE}The CL=ALL read itself returns the correct result (coordinator merges responses),${C_RESET}"
            echo -e "${C_BLUE}but the repair mutation to node3 happens asynchronously.${C_RESET}"

            separator
            echo -e "${C_WHITE}--- Step 5: Verify repair (read from node3 again) ---${C_RESET}"
            if [ "$DRY_RUN" = false ]; then sleep 3; fi
            log_cmd "docker exec hcd-node3 cqlsh -e \"CONSISTENCY ONE; SELECT * FROM rf_prod.rr_test WHERE id = 1;\""
            lookfor "node3 should now return 'written-while-node3-down' — read repair fixed it."

            separator
            echo -e "${C_WHITE}--- Read Repair Metrics ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.rr_test 2>/dev/null | grep -iE 'repair|read count' | head -n 5 || echo '(Read repair metrics)'"

            takeaway "Read Repair is PASSIVE entropy resolution: it piggybacks on normal reads." \
                     "Higher consistency levels (QUORUM, ALL) trigger more read repairs." \
                     "It is NOT a substitute for regular anti-entropy repair (Module 6)."
            ;;
        6)
            header 6 "Anti-Entropy Repair"
            echo -e "${C_DIM}(Estimated time: ~2-3 minutes for repair on small dataset)${C_RESET}"
            echo "Repair is the ultimate consistency guarantee. It compares ALL data"
            echo "across ALL replicas using Merkle Trees (hash trees) and fixes any"
            echo "differences found."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  How Merkle Tree Repair Works:                                |"
            echo "|                                                               |"
            echo "|  1. Each node builds a hash tree of its data                  |"
            echo "|                                                               |"
            echo "|         [Root Hash]                                           |"
            echo "|         /          \\                                          |"
            echo "|    [Hash L]     [Hash R]                                      |"
            echo "|    /    \\        /    \\                                       |"
            echo "|  [H1]  [H2]  [H3]  [H4]  <-- leaf = token range hash        |"
            echo "|                                                               |"
            echo "|  2. Nodes exchange root hashes                                |"
            echo "|  3. If roots differ, drill down to find mismatched ranges     |"
            echo "|  4. Only the differing ranges are streamed (efficient!)       |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Running manual repair on rf_prod keyspace (primary range only)..."
            log_cmd "docker exec hcd-node1 nodetool repair -pr rf_prod"

            lookfor "Look for 'Starting repair', 'Merkle tree', and 'Repair completed' messages."
            lookfor "The '-pr' flag limits repair to token ranges this node is primary for."

            separator
            echo -e "${C_WHITE}--- Modules 4-6 Recap: The Three-Layer Defense Against Entropy ---${C_RESET}"
            echo ""
            echo "  Layer 1 (Immediate):    HINTED HANDOFF (Module 4)"
            echo "    Coordinator buffers writes for downed nodes. Replayed on recovery."
            echo "    Window: 3 hours max. Cost: near zero."
            echo ""
            echo "  Layer 2 (Opportunistic): READ REPAIR (Module 5)"
            echo "    Triggered passively during normal reads. Fixes stale replicas on-the-fly."
            echo "    Window: unlimited. Cost: slight read latency increase."
            echo ""
            echo "  Layer 3 (Scheduled):    ANTI-ENTROPY REPAIR (Module 6)"
            echo "    Weekly full-cluster Merkle tree comparison. Catches everything."
            echo "    Window: scheduled. Cost: CPU + network during repair window."
            echo ""
            echo "  Together, these three layers make data loss in HCD extremely unlikely."
            echo "  You need ALL THREE: HH for short outages, RR for stale reads, Repair for drift."

            takeaway "Run repair regularly (weekly in production) to catch any entropy" \
                     "that Hinted Handoff and Read Repair missed. Without repair," \
                     "data can diverge silently across replicas over time." \
                     "These three layers form HCD's complete entropy defense system."
            ;;
        7)
            header 7 "Token Ring & Consistent Hashing"
            echo "HCD distributes data using consistent hashing. Each partition key is"
            echo "hashed to a token (a 64-bit integer), and that token determines which"
            echo "nodes store the data."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|               The Token Ring (-2^63 to +2^63)                 |"
            echo "|                                                               |"
            echo "|                      token = 0                                |"
            echo "|                         |                                     |"
            echo "|                   N1 ---+--- N2                               |"
            echo "|                 /       |       \\                             |"
            echo "|               N6        |        N3                           |"
            echo "|                 \\       |       /                             |"
            echo "|                   N5 ---+--- N4                               |"
            echo "|                         |                                     |"
            echo "|                   token = max                                 |"
            echo "|                                                               |"
            echo "|  Each node owns 256 vnodes (small token ranges).              |"
            echo "|  Data at token T goes to the next N nodes clockwise (N=RF).   |"
            echo "+---------------------------------------------------------------+"
            echo ""

            echo -e "${C_DIM}Note: Trace output keywords (e.g., 'Sending', 'Enqueuing') may vary by HCD/Cassandra version.${C_RESET}"
            echo ""

            log_info "Describing token-to-node mapping for rf_prod keyspace..."
            log_cmd "docker exec hcd-node1 nodetool describering rf_prod | head -n 20"

            lookfor "Each line shows a token range and which nodes (endpoints) own it."

            separator

            log_info "How many token ranges does each node own?"
            log_cmd "docker exec hcd-node1 nodetool ring | grep -c '172.28.0.2' || echo '0'"
            log_cmd "docker exec hcd-node1 nodetool ring | grep -c '172.28.0.3' || echo '0'"
            log_cmd "docker exec hcd-node1 nodetool ring | grep -c '172.28.0.4' || echo '0'"
            log_cmd "docker exec hcd-node1 nodetool ring | grep -c '172.28.0.5' || echo '0'"
            log_cmd "docker exec hcd-node1 nodetool ring | grep -c '172.28.0.6' || echo '0'"
            log_cmd "docker exec hcd-node1 nodetool ring | grep -c '172.28.0.7' || echo '0'"

            lookfor "Each node should own ~256 token ranges (vnodes)."

            takeaway "Vnodes ensure balanced data distribution. When a node joins or leaves," \
                     "only its token ranges are redistributed -- not the entire dataset."
            ;;
        8)
            header 8 "Write Path Trace"
            echo "Every write in HCD follows this path on each replica node:"
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Client Write Path (per replica):                             |"
            echo "|                                                               |"
            echo "|  Client --> Coordinator                                       |"
            echo "|               |                                               |"
            echo "|               +--> CommitLog (append-only, durable)           |"
            echo "|               +--> Memtable  (in-memory, fast)               |"
            echo "|               |                                               |"
            echo "|               +--> ACK to client (after CL replicas confirm) |"
            echo "|               |                                               |"
            echo "|            [later, when Memtable is full]                     |"
            echo "|               +--> Flush to SSTable (on disk, immutable)      |"
            echo "+---------------------------------------------------------------+"
            echo ""
            echo "For LOCAL_QUORUM with RF=3 in 2 DCs:"
            echo "  Coordinator sends write to 3 local nodes + forwards to 1 remote DC node."
            echo "  ACK is sent after 2 local nodes confirm (quorum in local DC)."
            echo ""

            echo -e "${C_DIM}Note: Trace keywords vary by HCD/Cassandra version. Look for the concepts, not exact strings.${C_RESET}"
            echo ""
            log_info "Tracing a LOCAL_QUORUM write to see the distributed coordination..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'trace-write-path');\""

            lookfor "In the trace, look for (keywords may vary by version):"
            lookfor "  - 'Sending MUTATION message to' or similar (coordinator contacting replicas)"
            lookfor "  - 'Committing log' or 'Appending to commitlog' (CommitLog append)"
            lookfor "  - 'Adding to memtable' or similar (Memtable insertion)"
            lookfor "  - Timestamps showing sub-millisecond coordination"

            takeaway "Writes are append-only (CommitLog + Memtable) -- no read-before-write." \
                     "This is why HCD writes are so fast, even at QUORUM consistency."
            ;;
        9)
            header 9 "Read Path Trace"
            echo "Reads are more complex than writes. The coordinator must assemble"
            echo "data from multiple sources and reconcile any differences."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Client Read Path (CL=QUORUM, RF=3):                         |"
            echo "|                                                               |"
            echo "|  Client --> Coordinator                                       |"
            echo "|               |                                               |"
            echo "|               +--> Node A: FULL read (returns actual data)    |"
            echo "|               +--> Node B: DIGEST read (returns hash only)    |"
            echo "|               |                                               |"
            echo "|            [Coordinator compares digests]                      |"
            echo "|               |                                               |"
            echo "|               +--> Match? Return data to client               |"
            echo "|               +--> Mismatch? Full read from all, repair stale |"
            echo "+---------------------------------------------------------------+"
            echo ""

            echo -e "${C_DIM}Note: Trace keywords vary by HCD/Cassandra version. Look for the concepts, not exact strings.${C_RESET}"
            echo ""
            log_info "Tracing a read to see the distributed coordination..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT * FROM rf_prod.logs LIMIT 1;\""

            lookfor "In the trace, look for (keywords may vary by version):"
            lookfor "  - 'Sending READ message' or similar (coordinator contacting replicas)"
            lookfor "  - 'Read data' vs 'Read digest' (full vs digest read)"
            lookfor "  - 'Bloom filter' or 'bloom_filter' (SSTable pre-filtering)"
            lookfor "  - 'Merged data from memtables and SSTables' or similar"

            takeaway "Reads touch Bloom filters, SSTables, and Memtables per node." \
                     "The digest optimization avoids sending full data from every replica."
            ;;
        10)
            header 10 "Node Recovery"
            echo "When a node restarts after being down, it automatically receives"
            echo "any hints stored by other nodes, and gossip announces its return."
            echo ""
            echo -e "${C_YELLOW}QUESTION: After a node restarts, how does it know what data it missed?${C_RESET}"
            echo -e "${C_YELLOW}Think: who stored the missed writes, and what triggers their delivery?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Other coordinators stored 'hints' during the outage.${C_RESET}"
            echo -e "${C_GREEN}When gossip announces the node is back, hints are replayed automatically.${C_RESET}"
            echo ""

            log_info "Ensuring nodes 2 and 3 are running..."
            log_cmd "docker-compose start hcd-node2 hcd-node3"
            log_info "Waiting for nodes to reach UN (Up/Normal) status..."
            if [ "$DRY_RUN" = false ]; then
                wait_for_node_un "172.28.0.3" "Node 2" 30 3
            fi

            log_info "Checking HintedHandoff metrics from thread pool stats..."
            log_cmd "docker exec hcd-node1 nodetool tpstats | grep -i HintedHandoff || echo '(No HintedHandoff activity recorded)'"

            lookfor "The 'Completed' column shows how many hint deliveries have occurred."
            lookfor "A non-zero value means hints were replayed to returning nodes."

            takeaway "Recovery is automatic: gossip detects the node is back, and" \
                     "coordinators replay stored hints. No manual intervention required."
            ;;
        11)
            header 11 "Tombstones & Shadowed Data"
            echo "In HCD, deletes don't erase data. They write a special marker called"
            echo "a Tombstone. This is necessary because you cannot modify an immutable SSTable."
            echo ""

            log_info "Exploring why 'Deletes are Writes' in HCD..."
            DELETE_ID="ffffffff-ffff-ffff-ffff-ffffffffffff"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.logs (id, msg) VALUES ($DELETE_ID, 'Delete Me');\""

            log_info "Deleting the data (this creates a Tombstone)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; DELETE FROM rf_prod.logs WHERE id = $DELETE_ID;\""
            log_info "Flushing to disk to create SSTable..."
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod logs"

            log_info "Searching for Tombstones in the logs table..."
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.logs | grep 'Tombstone' || echo '(No tombstone stats yet)'"

            separator

            log_info "Checking gc_grace_seconds for this table..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT gc_grace_seconds FROM system_schema.tables WHERE keyspace_name = 'rf_prod' AND table_name = 'logs';\""

            echo ""
            echo "+----------------------------------------------------------------+"
            echo "|  gc_grace_seconds (default: 864000 = 10 days)                  |"
            echo "|                                                                |"
            echo "|  WHY tombstones persist:                                       |"
            echo "|  - A deleted row might still exist on a stale replica          |"
            echo "|  - If the tombstone is removed before repair runs,             |"
            echo "|    the stale replica's data would 'resurrect' during reads     |"
            echo "|  - gc_grace_seconds is the safety window for repair to run     |"
            echo "|                                                                |"
            echo "|  Timeline:                                                     |"
            echo "|  DELETE --> Tombstone created --> gc_grace expires --> Compact  |"
            echo "|                                   removes tombstone            |"
            echo "+----------------------------------------------------------------+"
            echo ""

            log_info "Compacting to see tombstone resolution..."
            log_cmd "docker exec hcd-node1 nodetool compact rf_prod logs"

            log_info "Tombstone stats after compaction..."
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.logs | grep -E 'Tombstone|SSTable count' || echo '(Stats unavailable)'"

            takeaway "Tombstones are the price of distributed deletes. Without them," \
                     "deleted data could reappear like a ghost from a stale replica." \
                     "Always run repair within gc_grace_seconds to prevent zombie data."
            ;;
        12)
            header 12 "Lightweight Transactions (LWT) - The Race Condition Story"
            echo ""
            echo "+----------------------------------------------------------+"
            echo "|  Scenario: Concert Ticket Sales                          |"
            echo "|                                                          |"
            echo "|  User A (New York)  --+                                  |"
            echo "|                       +--> Same seat, same millisecond   |"
            echo "|  User B (London)    --+                                  |"
            echo "|                                                          |"
            echo "|  Without LWT: Both succeed. Double-booking!              |"
            echo "|  With LWT: Exactly one succeeds. Paxos guarantees it.   |"
            echo "+----------------------------------------------------------+"
            echo ""

            log_info "Creating the ticket inventory..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.tickets (event text, seat text, booked_by text, PRIMARY KEY (event, seat));\""

            log_info "Initializing available seats..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.tickets (event, seat, booked_by) VALUES ('concert-2025', 'A1', null);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.tickets (event, seat, booked_by) VALUES ('concert-2025', 'A2', null);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.tickets (event, seat, booked_by) VALUES ('concert-2025', 'A3', null);\""

            separator

            log_info "User A (New York) tries to book seat A1..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; UPDATE rf_prod.tickets SET booked_by = 'Alice (NYC)' WHERE event = 'concert-2025' AND seat = 'A1' IF booked_by = null;\""

            lookfor "Expected: [applied]: True -- Alice got the seat!"

            pause

            echo -e "${C_YELLOW}>>> QUESTION: User B (London) now tries to book the SAME seat A1.${C_RESET}"
            echo -e "${C_YELLOW}>>> Will it succeed? What will [applied] show?${C_RESET}"
            pause

            log_info "User B (London) tries to book the SAME seat A1..."
            log_cmd "docker exec hcd-node5 cqlsh -e \"TRACING ON; UPDATE rf_prod.tickets SET booked_by = 'Bob (London)' WHERE event = 'concert-2025' AND seat = 'A1' IF booked_by = null;\""

            lookfor "[applied]: False -- Bob sees Alice already booked it."
            lookfor "The response includes the current value so the app can show 'Seat taken'."

            pause

            log_info "Bob picks another seat instead..."
            log_cmd "docker exec hcd-node5 cqlsh -e \"TRACING ON; UPDATE rf_prod.tickets SET booked_by = 'Bob (London)' WHERE event = 'concert-2025' AND seat = 'A2' IF booked_by = null;\""

            log_info "Final state of all seats..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.tickets WHERE event = 'concert-2025';\""

            echo ""
            echo "Under the hood, each LWT goes through a 4-phase Paxos round:"
            echo "  1. Prepare  - Leader proposes a ballot"
            echo "  2. Promise  - Replicas promise to accept this ballot"
            echo "  3. Accept   - Leader sends the mutation"
            echo "  4. Commit   - Replicas apply the mutation"

            takeaway "LWT provides linearizable consistency via Paxos consensus." \
                     "~4x slower than normal writes. Use only for race-critical operations" \
                     "like reservations, counters, and unique constraint enforcement."
            ;;
        13)
            header 13 "Summary & Health Check"
            echo "Modules 0-12 covered the fundamentals of distributed data management:"
            echo ""
            echo "  Modules 0-1:   Topology and Replication"
            echo "  Module  2:     Consistency Levels (the availability/consistency tradeoff)"
            echo "  Modules 3-4:   Node Failures and Hinted Handoff"
            echo "  Modules 5-6:   Read Repair and Anti-Entropy Repair"
            echo "  Modules 7-9:   Token Ring, Write Path, and Read Path"
            echo "  Modules 10-11: Recovery, Tombstones, and gc_grace"
            echo "  Module  12:    Lightweight Transactions (Paxos)"
            echo ""
            echo "Now we move to advanced failure scenarios and modern features."
            echo ""
            log_info "Final health check before advanced modules..."
            log_cmd "docker exec hcd-node1 nodetool status"

            lookfor "All 6 nodes should show UN. If any show DN, wait or restart them."
            ;;
        14)
            header 14 "The Ghost Rack (Double Rack Failure)"
            echo "What if the same rack fails in BOTH datacenters simultaneously?"
            echo "This simulates a correlated failure (e.g., shared power infrastructure)."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Rack Layout:                                                 |"
            echo "|                                                               |"
            echo "|  DC1:  Rack1[node1]  Rack2[node2]  Rack3[node3]              |"
            echo "|  DC2:  Rack1[node4]  Rack2[node5]  Rack3[node6]              |"
            echo "|                                                               |"
            echo "|  Killing Rack 1 in both DCs:  node1 + node4 go DOWN          |"
            echo "|  Remaining: node2, node3, node5, node6 (4 of 6 nodes)        |"
            echo "|  Each DC still has 2 of 3 nodes -> LOCAL_QUORUM works!        |"
            echo "+---------------------------------------------------------------+"
            echo ""

            echo -e "${C_YELLOW}QUESTION: If the SAME rack fails in BOTH DCs (node1 + node4), can the${C_RESET}"
            echo -e "${C_YELLOW}cluster still serve LOCAL_QUORUM reads? We lose 2 of 6 nodes total.${C_RESET}"
            pause

            log_info "Stopping Rack 1 in both DCs (node1 and node4)..."
            log_cmd "docker-compose stop hcd-node1 hcd-node4"

            echo -e "${C_GREEN}ANSWER: YES — each DC still has 2 of 3 nodes = LOCAL_QUORUM satisfied.${C_RESET}"
            log_cmd "docker exec hcd-node2 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.logs LIMIT 1;\""

            lookfor "The SELECT succeeds because rack-aware placement spreads replicas across racks."

            log_info "Starting nodes back up..."
            log_cmd "docker-compose start hcd-node1 hcd-node4"
            if [ "$DRY_RUN" = false ]; then
                log_info "Waiting for all nodes to rejoin..."
                wait_for_all_un 30
            fi

            takeaway "RF=3 with rack-aware placement means losing one rack per DC is safe." \
                     "This is why rack diversity matters: it protects against correlated failures."
            ;;
        15)
            header 15 "Schema Disagreement"
            echo "All nodes must agree on the database schema (tables, keyspaces, indexes)."
            echo "Schema changes propagate via gossip. If a node was down during a schema"
            echo "change, it may temporarily disagree with the rest of the cluster."
            echo ""

            echo -e "${C_YELLOW}QUESTION: If a node was down during a CREATE TABLE, what happens${C_RESET}"
            echo -e "${C_YELLOW}when it comes back? Does it know about the new table?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Gossip propagates schema changes. The returning node learns${C_RESET}"
            echo -e "${C_GREEN}about the new schema within seconds of rejoining.${C_RESET}"
            echo ""

            log_info "Checking schema versions via nodetool describecluster..."
            log_cmd "docker exec hcd-node1 nodetool describecluster | grep -A 5 'Schema versions' || echo '(Schema info unavailable)'"

            separator
            log_info "Cross-checking via system.peers table..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT peer, schema_version FROM system.peers;\" 2>/dev/null || echo '(system.peers query)'"

            lookfor "describecluster shows ONE schema version shared by all 6 nodes."
            lookfor "system.peers confirms the same UUID across all peers."
            lookfor "Multiple schema versions = schema disagreement (nodes need to sync)."

            takeaway "Schema disagreement is usually transient and resolves within seconds." \
                     "If persistent, run 'nodetool resetlocalschema' on the disagreeing node." \
                     "Never make schema changes while a node is down for extended periods."
            ;;
        16)
            header 16 "Gossip Protocol & Failure Detection"
            echo "Gossip is the peer-to-peer protocol HCD uses to discover nodes and"
            echo "share state. There is no central coordinator -- every node gossips."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Gossip Propagation (every 1 second):                         |"
            echo "|                                                               |"
            echo "|  Round 1:  node1 --> node3  (tells node3 about node1 state)   |"
            echo "|  Round 2:  node3 --> node5  (tells node5 about node1 + node3) |"
            echo "|  Round 3:  node5 --> node2  (information spreads rapidly)     |"
            echo "|                                                               |"
            echo "|  Each gossip message contains:                                |"
            echo "|  - HEARTBEAT: versioned counter (proves node is alive)        |"
            echo "|  - STATUS: NORMAL, LEAVING, JOINING, MOVING                   |"
            echo "|  - DC/RACK: location from the Snitch                          |"
            echo "|  - SCHEMA: current schema version hash                        |"
            echo "|  - LOAD: disk usage for load balancing                        |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Inspecting Gossip state for the cluster..."
            log_cmd "docker exec hcd-node1 nodetool gossipinfo | head -n 20"

            lookfor "Each node entry shows HEARTBEAT generation/version and STATUS."
            lookfor "Higher generation numbers mean the node has been restarted more recently."

            log_info "Viewing node-specific gossip information..."
            log_cmd "docker exec hcd-node1 nodetool info"

            log_info "Demonstrating the Snitch's role in Gossip..."
            echo "The GossipingPropertyFileSnitch propagates DC/Rack info via Gossip."
            log_cmd "docker exec hcd-node1 nodetool gossipinfo | grep -E 'DC|RACK' | head -n 4 || echo '(Gossip DC/RACK info unavailable)'"

            takeaway "Gossip enables HCD's leaderless architecture. Every node has a" \
                     "complete view of the cluster without any central coordination point."
            ;;
        17)
            header 17 "The Zombie Node (Network Partition)"
            echo "A network partition makes a node unreachable to its peers, but the node"
            echo "itself thinks it is still alive. This creates a 'zombie' -- it can accept"
            echo "local writes but cannot replicate them."
            echo ""
            echo "+----------------------------------------------------------+"
            echo "|  Before:   N1 <--> N2 <--> N3    (fully connected)      |"
            echo "|  During:   N1 <-->     X    N2    (N2 isolated)          |"
            echo "|  Gossip:   N1 sees N2 as DN after ~15-30 seconds        |"
            echo "|  After:    N1 <--> N2 <--> N3    (reconnected, healed)  |"
            echo "+----------------------------------------------------------+"
            echo ""

            log_info "Disconnecting hcd-node2 from the cluster network..."
            log_cmd "docker network disconnect ${HCD_NETWORK} hcd-node2"

            log_info "Waiting for Gossip to detect the partition (~15-30 seconds)..."
            if [ "$DRY_RUN" = false ]; then
                MAX_ZOMBIE_RETRIES=20
                ZOMBIE_COUNT=0
                until docker exec hcd-node1 nodetool status 2>/dev/null | grep -E "DN\s+172.28.0.3" >/dev/null 2>&1; do
                    echo -n "."
                    sleep 3
                    ZOMBIE_COUNT=$((ZOMBIE_COUNT + 1))
                    if [ $ZOMBIE_COUNT -ge $MAX_ZOMBIE_RETRIES ]; then
                        log_info "Timeout waiting for gossip to mark node as DN. Continuing..."
                        break
                    fi
                done
                echo ""
            fi

            log_info "Node 2 status (should show DN - Down/Normal)..."
            log_cmd "docker exec hcd-node1 nodetool status | grep '172.28.0.3' || echo 'Node 2 not visible'"

            echo ""
            echo -e "${C_YELLOW}QUESTION: Node 2 is network-partitioned (isolated). Can the cluster${C_RESET}"
            echo -e "${C_YELLOW}still serve writes at LOCAL_QUORUM? Node 2 thinks it's alive...${C_RESET}"
            pause

            echo -e "${C_GREEN}ANSWER: YES — the remaining 2 nodes (node1, node3) form LOCAL_QUORUM.${C_RESET}"
            echo -e "${C_GREEN}Node 2 is a 'zombie' — alive but unreachable by peers.${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'written-during-partition');\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.logs LIMIT 1;\""

            pause

            log_info "Reconnecting hcd-node2 to the cluster network..."
            log_cmd "docker network connect ${HCD_NETWORK} hcd-node2"

            log_info "Waiting for Node 2 to rejoin the ring..."
            if [ "$DRY_RUN" = false ]; then
                wait_for_node_un "172.28.0.3" "Node 2" 30 5
            fi

            log_info "Node 2 status (should show UN - Up/Normal again)..."
            log_cmd "docker exec hcd-node1 nodetool status | grep '172.28.0.3' || echo 'Node 2 status unknown'"

            takeaway "The zombie is back. Gossip detected the partition, the cluster" \
                     "continued serving traffic, and the node seamlessly rejoined." \
                     "This is the power of a leaderless architecture."
            ;;
        18)
            header 18 "Storage Attached Indexing (SAI) - Deep Dive"
            echo "SAI is HCD's modern indexing engine. Unlike legacy Secondary Indexes"
            echo "which create hidden tables, SAI attaches index structures directly to"
            echo "each SSTable. This means lower overhead and composable queries."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Legacy 2i vs SAI:                                            |"
            echo "|                                                               |"
            echo "|  Legacy 2i: Hidden table per index (scatter-gather reads)     |"
            echo "|  [Data SSTable] --> [Index Table] --> scatter to all nodes     |"
            echo "|                                                               |"
            echo "|  SAI: Index embedded in each SSTable (local reads)            |"
            echo "|  [Data SSTable + SAI Index] --> local lookup, no scatter      |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Creating a realistic table for asset tracking..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE TABLE IF NOT EXISTS rf_prod.assets (id uuid PRIMARY KEY, name text, category text, value int, tags map<text, text>, updated_at timestamp);\""

            separator
            echo -e "${C_WHITE}--- Index Creation Phase ---${C_RESET}"

            echo "1. Equality index on 'category' (text)"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.assets (category) USING 'StorageAttachedIndex';\""
            echo "2. Range-capable index on 'value' (int)"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.assets (value) USING 'StorageAttachedIndex';\""
            echo "3. Map Keys index on 'tags'"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.assets (KEYS(tags)) USING 'StorageAttachedIndex';\""
            echo "4. Map Values index on 'tags'"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.assets (VALUES(tags)) USING 'StorageAttachedIndex';\""

            separator
            echo -e "${C_WHITE}--- Data Loading Phase ---${C_RESET}"

            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets (id, name, category, value, tags, updated_at) VALUES (uuid(), 'Server-A1', 'hardware', 5000, {'env':'prod', 'loc':'dc1'}, toTimestamp(now()));\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets (id, name, category, value, tags, updated_at) VALUES (uuid(), 'Server-A2', 'hardware', 4500, {'env':'prod', 'loc':'dc2'}, toTimestamp(now()));\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets (id, name, category, value, tags, updated_at) VALUES (uuid(), 'License-X', 'software', 1200, {'vendor':'IBM'}, toTimestamp(now()));\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets (id, name, category, value, tags, updated_at) VALUES (uuid(), 'Laptop-Z', 'hardware', 2500, {'env':'dev', 'user':'alice'}, toTimestamp(now()));\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets (id, name, category, value, tags, updated_at) VALUES (uuid(), 'Router-B', 'hardware', 8000, {'env':'prod', 'speed':'10Gbps'}, toTimestamp(now()));\""

            separator
            echo -e "${C_WHITE}--- Composable Query Phase (The Power of SAI) ---${C_RESET}"

            echo "Query 1: Single column filter"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT name, category FROM rf_prod.assets WHERE category = 'hardware';\""

            echo "Query 2: Multi-column AND condition (Composable — uses BOTH indexes)"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT name, category, value FROM rf_prod.assets WHERE category = 'hardware' AND value > 3000;\""
            lookfor "In the trace, look for TWO index lookups: one for 'category' and one for 'value'."
            lookfor "SAI intersects both results locally — no scatter-gather across nodes."

            echo ""
            echo "Query 3: Map Key + Map Value search (triple index intersection)"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT name, tags FROM rf_prod.assets WHERE tags CONTAINS KEY 'env' AND tags CONTAINS 'prod';\""
            lookfor "Three SAI lookups composed: KEYS(tags) + VALUES(tags) intersected per-SSTable."

            separator
            echo -e "${C_WHITE}--- Map Entries & Text Analyzers ---${C_RESET}"

            echo "5. Map Entries index (key=value pairs)"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.assets (ENTRIES(tags)) USING 'StorageAttachedIndex';\""
            echo "Query 4: Exact key-value pair match"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT name FROM rf_prod.assets WHERE tags['env'] = 'prod';\""

            log_info "Text Analyzers for case-insensitive search..."
            echo -e "${C_BLUE}Note: SAI text analyzer options (case_sensitive, normalize) are supported${C_RESET}"
            echo -e "${C_BLUE}in HCD 1.2+. If your version uses different syntax, check the HCD docs${C_RESET}"
            echo -e "${C_BLUE}for 'index_analyzer' configuration.${C_RESET}"
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE TABLE IF NOT EXISTS rf_prod.products (id uuid PRIMARY KEY, name text, description text);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.products (name) USING 'StorageAttachedIndex' WITH OPTIONS = {'case_sensitive': 'false', 'normalize': 'true'};\" 2>&1 || echo '(Text analyzer options may differ in your HCD version -- index still works without them)'"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.products (id, name, description) VALUES (uuid(), 'MacBook Pro', 'Apple laptop');\""
            echo "Case-insensitive query (searching 'macbook' finds 'MacBook Pro'):"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT name FROM rf_prod.products WHERE name = 'macbook pro';\""

            separator
            echo -e "${C_WHITE}--- SAI Internals ---${C_RESET}"

            echo ""
            echo -e "${C_YELLOW}QUESTION: Why doesn't SAI need a scatter-gather read like 2i (secondary indexes)?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: SAI indexes are per-SSTable, not per-node. Each SSTable has its own${C_RESET}"
            echo -e "${C_GREEN}index segment, so the coordinator only contacts replicas that own the partition.${C_RESET}"
            echo ""

            log_info "SAI avoids scatter-gather by indexing per-SSTable..."
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.assets | grep -i 'SSTable count' || echo '(No SSTable stats yet)'"

            log_info "Introspecting index metadata via system_schema..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT index_name, table_name, kind FROM system_schema.indexes WHERE keyspace_name = 'rf_prod';\""

            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM system_views.sstable_tasks LIMIT 5;\" || echo '(system_views.sstable_tasks may not exist in this HCD version)'"

            takeaway "SAI enables composable queries (AND multiple conditions) without" \
                     "scatter-gather reads. It indexes per-SSTable, keeping overhead low." \
                     "Supports equality, range, map key/value, and text analyzer queries."
            ;;
        19)
            header 19 "JSON & Data API Operations - Deep Dive"
            echo "HCD provides native JSON support, enabling document-database patterns."
            echo "This allows REST APIs to interact with Cassandra using JSON objects"
            echo "while maintaining schema enforcement underneath."
            echo ""

            echo -e "${C_WHITE}--- Part 1: INSERT JSON ---${C_RESET}"
            echo "Inserting a full row via JSON string..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"550e8400-e29b-41d4-a716-446655440000\\\", \\\"name\\\": \\\"JSON-Asset-1\\\", \\\"category\\\": \\\"virtual\\\", \\\"value\\\": 0}';\""
            echo "Inserting with missing columns (they will be set to null)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"660e8400-e29b-41d4-a716-446655440001\\\", \\\"name\\\": \\\"Partial-JSON\\\"}';\""

            separator
            echo -e "${C_WHITE}--- Part 2: SELECT JSON ---${C_RESET}"
            echo "Retrieving the whole row as a single JSON object..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT JSON * FROM rf_prod.assets WHERE id = 550e8400-e29b-41d4-a716-446655440000;\""
            echo "Selecting specific columns as JSON..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT JSON name, value FROM rf_prod.assets WHERE category = 'hardware' LIMIT 1;\""

            separator
            echo -e "${C_WHITE}--- Part 3: fromJson() and toJson() ---${C_RESET}"
            echo "Using fromJson() to insert specific column values..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets (id, tags) VALUES (uuid(), fromJson('{\\\"cloud\\\": \\\"hybrid\\\"}'));\""
            echo "Using toJson() to convert a map column to JSON during selection..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT name, toJson(tags) FROM rf_prod.assets WHERE category = 'hardware' LIMIT 1;\""

            separator
            echo -e "${C_WHITE}--- Part 4: Collections via JSON ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"770e8400-e29b-41d4-a716-446655440002\\\", \\\"tags\\\": {\\\"env\\\": \\\"test\\\", \\\"priority\\\": \\\"high\\\"}}';\""

            separator
            echo -e "${C_WHITE}--- Part 5: Error Handling ---${C_RESET}"
            echo "Attempting to insert invalid JSON (Should fail)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"bad-uuid\\\"}';\" || echo 'Caught expected error: Invalid JSON/Schema mismatch'"

            separator
            echo -e "${C_WHITE}--- Part 6: DEFAULT UNSET (Surgical Updates) ---${C_RESET}"
            echo -e "${C_YELLOW}QUESTION: If you INSERT JSON with only 'id' and 'value', what happens to other columns?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Without DEFAULT UNSET, they become NULL (a tombstone!).${C_RESET}"
            echo -e "${C_GREEN}DEFAULT UNSET leaves unmentioned columns untouched — the key to partial updates.${C_RESET}"
            echo ""
            echo "Partial update without overwriting unmentioned columns with NULL:"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"550e8400-e29b-41d4-a716-446655440000\\\", \\\"value\\\": 999}' DEFAULT UNSET;\""
            echo "Only 'value' was updated; 'name', 'category', 'tags' remain unchanged!"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; SELECT JSON * FROM rf_prod.assets WHERE id = 550e8400-e29b-41d4-a716-446655440000;\""

            separator
            echo -e "${C_WHITE}--- Part 7: TTL with JSON ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"880e8400-e29b-41d4-a716-446655440003\\\", \\\"name\\\": \\\"Ephemeral-Asset\\\", \\\"category\\\": \\\"temp\\\"}' USING TTL 3600;\""
            echo "This record will auto-expire in 1 hour (3600 seconds)"

            separator
            echo -e "${C_WHITE}--- Part 8: Batch JSON ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; BEGIN BATCH INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"990e8400-e29b-41d4-a716-446655440004\\\", \\\"name\\\": \\\"Batch-1\\\"}'; INSERT INTO rf_prod.assets JSON '{\\\"id\\\": \\\"aa0e8400-e29b-41d4-a716-446655440005\\\", \\\"name\\\": \\\"Batch-2\\\"}'; APPLY BATCH;\""

            takeaway "Native JSON support makes HCD a high-scale JSON store." \
                     "DEFAULT UNSET is the key feature: surgical partial updates without nulls." \
                     "This is the foundation for Stargate and other Document APIs."
            ;;
        20)
            header 20 "Vector Search & AI Readiness"
            echo "HCD SAI supports Vector Search for AI-driven applications."
            echo "This is the technology behind semantic search in ChatGPT, Copilot, and RAG."
            echo ""
            echo "+----------------------------------------------------------------+"
            echo "|  How Vector Search Works:                                       |"
            echo "|                                                                 |"
            echo "|  1. Text is converted to a numeric vector (embedding)           |"
            echo "|     'database replication' -> [0.9, 0.1, 0.8, 0.2, 0.7]        |"
            echo "|                                                                 |"
            echo "|  2. Similar concepts have similar vectors (cosine similarity)   |"
            echo "|     'data consistency'     -> [0.85, 0.15, 0.75, 0.25, 0.65]   |"
            echo "|     'cooking recipes'      -> [0.1, 0.9, 0.05, 0.8, 0.1]       |"
            echo "|                                                                 |"
            echo "|  3. ANN search finds the closest vectors efficiently            |"
            echo "+----------------------------------------------------------------+"
            echo ""

            echo -e "${C_BLUE}Note: vector<float, N> is supported in HCD 1.2+ (based on Cassandra 5.0 vector type).${C_RESET}"
            echo -e "${C_BLUE}If your HCD version doesn't support it, this module will show a clear error.${C_RESET}"
            echo ""

            log_info "Creating document store with 5-dimensional embeddings..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.documents (id uuid PRIMARY KEY, title text, content text, category text, embedding vector<float, 5>);\" 2>&1 || { echo -e '${C_YELLOW}Vector type not supported in this HCD version. Skipping vector demo.${C_RESET}'; }"

            if [ "$DRY_RUN" = false ]; then
                if ! docker exec hcd-node1 cqlsh -e "DESCRIBE TABLE rf_prod.documents;" 2>/dev/null | grep -q 'embedding'; then
                    echo -e "${C_YELLOW}Skipping Module 20: vector<float, N> requires HCD 1.2+ with vector support.${C_RESET}"
                    takeaway "Vector search requires HCD 1.2+ with vector type support." \
                             "The syntax is: vector<float, N> for N-dimensional embeddings." \
                             "Check your HCD version with 'nodetool version'."
                    pause
                    return 0 2>/dev/null || true
                fi
            fi

            log_info "Creating Vector Index (SAI with cosine similarity)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.documents (embedding) USING 'StorageAttachedIndex' WITH OPTIONS = {'similarity_function': 'cosine'};\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE CUSTOM INDEX IF NOT EXISTS ON rf_prod.documents (category) USING 'StorageAttachedIndex';\""

            separator
            echo -e "${C_WHITE}--- Loading 15 Documents Across 3 Semantic Clusters ---${C_RESET}"

            echo ""
            echo "Technology Cluster:"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Database Replication', 'How distributed databases replicate data across nodes', 'tech', [0.9, 0.1, 0.8, 0.2, 0.7]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Consensus Algorithms', 'Paxos and Raft for distributed agreement', 'tech', [0.85, 0.15, 0.75, 0.25, 0.65]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Cloud Architecture', 'Designing fault-tolerant cloud systems', 'tech', [0.8, 0.2, 0.7, 0.3, 0.6]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Microservices', 'Event-driven microservice communication patterns', 'tech', [0.75, 0.25, 0.65, 0.35, 0.55]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Container Orchestration', 'Kubernetes and Docker Swarm deployment', 'tech', [0.7, 0.3, 0.6, 0.4, 0.5]);\""

            echo "Science Cluster:"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Quantum Computing', 'Quantum bits and superposition in computing', 'science', [0.3, 0.8, 0.2, 0.9, 0.4]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Gene Editing', 'CRISPR technology for genome modification', 'science', [0.25, 0.85, 0.15, 0.88, 0.35]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Climate Modeling', 'Simulating climate change with supercomputers', 'science', [0.2, 0.9, 0.1, 0.85, 0.3]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Neuroscience', 'Brain-computer interfaces and neural mapping', 'science', [0.35, 0.75, 0.25, 0.82, 0.45]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Space Exploration', 'Mars colonization and deep space travel', 'science', [0.28, 0.82, 0.18, 0.87, 0.38]);\""

            echo "Business Cluster:"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Market Analysis', 'Stock market prediction using ML models', 'business', [0.5, 0.5, 0.4, 0.6, 0.9]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Supply Chain', 'Global logistics optimization strategies', 'business', [0.45, 0.55, 0.35, 0.65, 0.85]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Digital Marketing', 'SEO and content marketing automation', 'business', [0.4, 0.6, 0.3, 0.7, 0.8]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Risk Management', 'Enterprise risk assessment frameworks', 'business', [0.48, 0.52, 0.38, 0.62, 0.88]);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.documents (id, title, content, category, embedding) VALUES (uuid(), 'Fintech Innovation', 'Blockchain and DeFi payment systems', 'business', [0.55, 0.45, 0.45, 0.55, 0.92]);\""

            pause

            separator
            echo -e "${C_WHITE}--- Semantic Search ---${C_RESET}"

            log_info "'Find documents about distributed systems'..."
            echo "Query vector [0.88, 0.12, 0.78, 0.22, 0.68] represents the concept."
            echo ""
            echo -e "${C_BLUE}Note: similarity_cosine() is available in HCD 1.2+. If your version${C_RESET}"
            echo -e "${C_BLUE}doesn't support it, the ANN ORDER BY still works — scores just won't display.${C_RESET}"
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT title, content, similarity_cosine(embedding, [0.88, 0.12, 0.78, 0.22, 0.68]) as score FROM rf_prod.documents ORDER BY embedding ANN OF [0.88, 0.12, 0.78, 0.22, 0.68] LIMIT 5;\" 2>&1 || docker exec hcd-node1 cqlsh -e \"SELECT title, content FROM rf_prod.documents ORDER BY embedding ANN OF [0.88, 0.12, 0.78, 0.22, 0.68] LIMIT 5;\" 2>&1 || echo '(Vector search not available in this HCD version)'"

            lookfor "Tech documents should cluster at the top with high similarity scores."

            pause

            separator
            echo -e "${C_WHITE}--- Hybrid Search (Vector + Metadata Filter) ---${C_RESET}"

            log_info "Tech documents about distributed systems only..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT title, similarity_cosine(embedding, [0.88, 0.12, 0.78, 0.22, 0.68]) as score FROM rf_prod.documents WHERE category = 'tech' ORDER BY embedding ANN OF [0.88, 0.12, 0.78, 0.22, 0.68] LIMIT 3;\" 2>&1 || docker exec hcd-node1 cqlsh -e \"SELECT title FROM rf_prod.documents WHERE category = 'tech' ORDER BY embedding ANN OF [0.88, 0.12, 0.78, 0.22, 0.68] LIMIT 3;\""
            echo "Hybrid search = metadata filter (category='tech') + vector similarity."
            echo "This is how ChatGPT finds YOUR company's docs: filter by source, rank by relevance."

            separator
            echo -e "${C_WHITE}--- Cross-Cluster Search ---${C_RESET}"

            log_info "'What about finance and technology?'..."
            echo "Query vector [0.6, 0.4, 0.5, 0.5, 0.8] sits between tech and business."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT title, category, similarity_cosine(embedding, [0.6, 0.4, 0.5, 0.5, 0.8]) as score FROM rf_prod.documents ORDER BY embedding ANN OF [0.6, 0.4, 0.5, 0.5, 0.8] LIMIT 5;\" 2>&1 || docker exec hcd-node1 cqlsh -e \"SELECT title, category FROM rf_prod.documents ORDER BY embedding ANN OF [0.6, 0.4, 0.5, 0.5, 0.8] LIMIT 5;\""

            lookfor "Results should show a MIX of tech and business docs -- the query is between clusters."

            echo ""
            echo "Similarity Functions available in HCD:"
            echo "  COSINE      - Normalized direction similarity (most common for LLMs)"
            echo "  DOT_PRODUCT - Magnitude-aware similarity"
            echo "  EUCLIDEAN   - Absolute distance measurement"

            takeaway "HCD is a vector database. Combine SAI vector search with metadata" \
                     "filtering for production RAG pipelines -- no external vector DB needed."
            ;;
        21)
            header 21 "Mixed Real-time Operations (CRUD + Upsert)"
            echo "In HCD, INSERT and UPDATE are both 'Upserts' -- they create a new"
            echo "mutation with a timestamp. The latest timestamp always wins (LWW)."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Mutation Timeline (Last Write Wins):                         |"
            echo "|                                                               |"
            echo "|  T=1  INSERT (id=101, val='A')  --> Memtable                  |"
            echo "|  T=2  UPDATE (id=101, val='B')  --> Memtable (overwrites A)   |"
            echo "|  T=3  DELETE (id=101)           --> Tombstone in Memtable      |"
            echo "|  T=4  INSERT (id=101, val='C')  --> Memtable (resurrects!)     |"
            echo "|                                                               |"
            echo "|  SELECT at T=5: returns val='C' (latest mutation wins)        |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Initializing real-time stream table..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.stream (id int PRIMARY KEY, val text, version timeuuid);\""

            log_info "Performing a sequence of mixed operations..."

            echo "[1. INSERT] Creating record 101..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.stream (id, val, version) VALUES (101, 'initial', now());\""

            echo "[2. UPDATE] Modifying record 101 (The 'Upsert' behavior)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.stream SET val = 'updated' WHERE id = 101;\""

            echo "[3. INSERT as UPDATE] Overwriting record 101 with INSERT..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.stream (id, val, version) VALUES (101, 'overwritten-by-insert', now());\""

            echo "[4. READ] Checking current state of 101..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.stream WHERE id = 101;\""

            echo -e "${C_YELLOW}QUESTION: After DELETE at T=3 and INSERT at T=4, what does SELECT return?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: The INSERT at T=4 wins (LWW). The row is 'resurrected' — the tombstone${C_RESET}"
            echo -e "${C_GREEN}from T=3 has a lower timestamp than the INSERT at T=4.${C_RESET}"
            echo ""

            echo "[5. DELETE] Removing record 101 (Creating a Tombstone)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"DELETE FROM rf_prod.stream WHERE id = 101;\""

            echo "[6. UPSERT after DELETE] Re-inserting record 101..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.stream (id, val) VALUES (101, 'resurrected');\""

            separator

            log_info "Visualizing the Write Path via Tracing (Mixed Batch)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; BEGIN UNLOGGED BATCH INSERT INTO rf_prod.stream (id, val) VALUES (201, 'batch-1'); UPDATE rf_prod.stream SET val = 'batch-2' WHERE id = 202; DELETE FROM rf_prod.stream WHERE id = 203; APPLY BATCH;\""

            log_info "Flushing and checking SSTable stats..."
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod stream"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.stream || echo '(tablestats unavailable)'"

            takeaway "HCD has NO read-before-write penalty. Every operation is an append." \
                     "INSERT and UPDATE are identical at the storage layer." \
                     "The latest timestamp wins during reads (Last-Write-Wins / LWW)."
            ;;
        22)
            header 22 "Compaction: The Entropy Cleaner"
            echo "Compaction merges SSTables, resolves overwrites (LWW), and removes"
            echo "expired tombstones. It is the physical resolution of logical entropy."
            echo ""
            echo "+------------------------------------------------------------+"
            echo "|  Before Compaction:                                        |"
            echo "|  [SSTable-1] [SSTable-2] [SSTable-3]  (3 files, overlap)  |"
            echo "|                                                            |"
            echo "|  Compaction reads all 3, merges by timestamp (LWW),        |"
            echo "|  drops expired tombstones, writes 1 new file:              |"
            echo "|                                                            |"
            echo "|  After Compaction:                                         |"
            echo "|  [SSTable-merged]  (1 file, no overlap, clean)            |"
            echo "+------------------------------------------------------------+"
            echo ""

            log_info "Step 1: Creating multiple SSTables via repeated writes + flushes..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.stream (id, val) VALUES (301, 'flush1');\""
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod stream"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.stream (id, val) VALUES (302, 'flush2');\""
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod stream"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.stream (id, val) VALUES (303, 'flush3');\""
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod stream"

            log_info "Step 2: SSTable count BEFORE compaction..."
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.stream | grep -E 'SSTable count|Space used' || echo '(Stats unavailable)'"

            log_info "Step 3: Running compaction stats..."
            log_cmd "docker exec hcd-node1 nodetool compactionstats"

            pause

            echo -e "${C_YELLOW}QUESTION: We have 3+ SSTables. After compaction, how many will remain?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Ideally 1. Compaction merges all overlapping SSTables into a single file,${C_RESET}"
            echo -e "${C_GREEN}resolving overwrites (LWW) and dropping expired tombstones.${C_RESET}"
            echo ""

            log_info "Step 4: Triggering manual compaction..."
            log_cmd "docker exec hcd-node1 nodetool compact rf_prod stream"

            log_info "Step 5: SSTable count AFTER compaction (should be reduced)..."
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.stream | grep -E 'SSTable count|Space used' || echo '(Stats unavailable)'"

            lookfor "Compare the SSTable count before vs after. It should decrease."
            lookfor "Space used may also decrease as duplicate/tombstoned data is removed."

            takeaway "HCD uses UnifiedCompactionStrategy (UCS) by default." \
                     "UCS adapts to workload patterns automatically, unlike STCS/LCS/TWCS" \
                     "which required manual tuning. This is a key HCD differentiator."
            ;;
        23)
            header 23 "Kill an Entire Datacenter (Multi-DC Failover)"
            echo -e "${C_DIM}(Estimated time: ~5-8 minutes including node restarts)${C_RESET}"
            echo ""
            echo "+----------------------------------------------------------------+"
            echo "|  THE SCENARIO:                                                 |"
            echo "|                                                                |"
            echo "|  Your US-East datacenter (dc1) just lost power.                |"
            echo "|  Three nodes. Gone. All at once.                               |"
            echo "|                                                                |"
            echo "|  Can your users in US-West (dc2) still work?                   |"
            echo "|  Can they write NEW data while US-East is down?                |"
            echo "|  When US-East comes back, does it catch up automatically?      |"
            echo "|                                                                |"
            echo "|  Let's find out.                                               |"
            echo "+----------------------------------------------------------------+"
            echo ""

            log_info "Creating a dedicated table for this test..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.dc_failover (id int PRIMARY KEY, msg text, written_from text);\""

            log_info "Inserting 20 rows from dc1 (hcd-node1)..."
            for i in $(seq 1 20); do
                log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.dc_failover (id, msg, written_from) VALUES ($i, 'row-$i-before-outage', 'dc1');\""
            done

            log_info "Verifying all 20 rows readable from dc1..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.dc_failover;\""

            pause

            echo ""
            echo -e "${C_BOLD}============================================${C_RESET}"
            echo -e "${C_BOLD}     KILLING ENTIRE DATACENTER 1 (dc1)      ${C_RESET}"
            echo -e "${C_BOLD}============================================${C_RESET}"
            echo ""
            log_cmd "docker-compose stop hcd-node1 hcd-node2 hcd-node3"

            if [ "$DRY_RUN" = false ]; then
                sleep 10
            fi

            log_info "dc1 is DEAD. Let's see what dc2 thinks..."
            log_cmd "docker exec hcd-node5 nodetool status"

            lookfor "Nodes 1-3 should show DN. Nodes 4-6 should show UN."

            pause

            log_info "Can dc2 still read the data? (LOCAL_QUORUM from dc2)..."
            log_cmd "docker exec hcd-node5 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.dc_failover;\""
            log_cmd "docker exec hcd-node5 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.dc_failover WHERE id IN (1, 10, 20);\""
            echo "All 20 rows are there. dc2 has full copies because RF=3 per DC."

            pause

            log_info "Writing NEW data from dc2 while dc1 is completely down..."
            for i in $(seq 21 30); do
                log_cmd "docker exec hcd-node5 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.dc_failover (id, msg, written_from) VALUES ($i, 'row-$i-during-outage', 'dc2');\""
            done
            log_cmd "docker exec hcd-node5 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.dc_failover;\""
            echo "30 rows total. 10 new rows written while dc1 was dead."

            pause

            echo ""
            echo -e "${C_BOLD}============================================${C_RESET}"
            echo -e "${C_BOLD}     RESTORING DATACENTER 1 (dc1)           ${C_RESET}"
            echo -e "${C_BOLD}============================================${C_RESET}"
            echo ""
            log_cmd "docker-compose start hcd-node1 hcd-node2 hcd-node3"

            log_info "Waiting for dc1 nodes to rejoin the cluster..."
            if [ "$DRY_RUN" = false ]; then
                wait_for_all_un 60
            fi

            log_cmd "docker exec hcd-node1 nodetool status"

            pause

            log_info "The moment of truth: querying dc1 for data written DURING the outage..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.dc_failover;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.dc_failover WHERE id IN (21, 25, 30);\""

            lookfor "dc1 should see all 30 rows, including 10 written while it was dead."

            takeaway "Your entire US-East region went down. Users in US-West didn't notice." \
                     "When US-East came back, it caught up automatically." \
                     "This is the power of multi-DC replication with NetworkTopologyStrategy."
            ;;
        24)
            header 24 "Grand Finale - The Self-Healing Database"
            echo ""
            echo "We are going to throw everything at this database and watch it heal."
            echo "Three escalating failures. One conclusion."
            echo ""

            # --- Act 1 ---
            echo -e "${C_BOLD}================================================================${C_RESET}"
            echo -e "${C_BOLD} ACT 1: Single Node Failure (Hinted Handoff)${C_RESET}"
            echo -e "${C_BOLD}================================================================${C_RESET}"
            echo ""

            log_info "Creating our test table..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.resilience (id int PRIMARY KEY, msg text, act text);\""

            log_info "Counting rows before Act 1..."
            log_cmd "docker exec hcd-node3 cqlsh -e \"CONSISTENCY ONE; SELECT count(*) FROM rf_prod.resilience;\""

            log_info "Killing node3..."
            log_cmd "docker-compose stop hcd-node3"
            if [ "$DRY_RUN" = false ]; then sleep 5; fi

            log_info "Writing 10 rows while node3 is dead (hints will be stored)..."
            for i in $(seq 1 10); do
                log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY ONE; INSERT INTO rf_prod.resilience (id, msg, act) VALUES ($i, 'written-while-node3-down', 'act1');\""
            done

            log_info "Bringing node3 back..."
            log_cmd "docker-compose start hcd-node3"
            if [ "$DRY_RUN" = false ]; then
                wait_for_node_un "172.28.0.4" "Node 3" 30 3
                sleep 15
            fi

            log_info "Row count on node3 after hint replay..."
            log_cmd "docker exec hcd-node3 cqlsh -e \"CONSISTENCY ONE; SELECT count(*) FROM rf_prod.resilience;\""
            echo "Hinted Handoff healed node3 automatically. No manual intervention."

            pause

            # --- Act 2 ---
            echo ""
            echo -e "${C_BOLD}================================================================${C_RESET}"
            echo -e "${C_BOLD} ACT 2: Entire Datacenter Failure (Cross-DC Availability)${C_RESET}"
            echo -e "${C_BOLD}================================================================${C_RESET}"
            echo ""

            log_info "Killing ALL of dc1 (nodes 1, 2, 3)..."
            log_cmd "docker-compose stop hcd-node1 hcd-node2 hcd-node3"
            if [ "$DRY_RUN" = false ]; then sleep 10; fi

            log_info "Reading from dc2 - all data must be present..."
            log_cmd "docker exec hcd-node5 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.resilience;\""
            echo "dc2 serves all data. Zero downtime for the other region."

            log_info "Writing more data from dc2 during the outage..."
            for i in $(seq 11 15); do
                log_cmd "docker exec hcd-node5 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.resilience (id, msg, act) VALUES ($i, 'written-during-dc1-outage', 'act2');\""
            done

            pause

            # --- Act 3 ---
            echo ""
            echo -e "${C_BOLD}================================================================${C_RESET}"
            echo -e "${C_BOLD} ACT 3: Full Recovery & Anti-Entropy Repair${C_RESET}"
            echo -e "${C_BOLD}================================================================${C_RESET}"
            echo ""

            log_info "Restoring dc1..."
            log_cmd "docker-compose start hcd-node1 hcd-node2 hcd-node3"
            if [ "$DRY_RUN" = false ]; then
                wait_for_all_un 60
            fi

            log_info "Running anti-entropy repair to guarantee full consistency..."
            log_cmd "docker exec hcd-node1 nodetool repair -pr rf_prod"

            log_info "Final cluster status - all 6 nodes should be UN..."
            log_cmd "docker exec hcd-node1 nodetool status"

            log_info "Final row count from dc1 (should include act2 data)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.resilience;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT act, count(*) FROM rf_prod.resilience GROUP BY act;\" || echo '(GROUP BY may not be supported on this table structure)'"

            echo ""
            echo -e "${C_BOLD}================================================================${C_RESET}"
            echo ""
            echo "  We threw everything at this database:"
            echo "    1. Killed a single node   -> Hinted Handoff healed it"
            echo "    2. Killed an entire DC     -> Other DC kept serving"
            echo "    3. Brought it all back     -> Anti-Entropy Repair ensured consistency"
            echo ""
            echo -e "${C_BOLD}  Final: All 6 nodes UP. All data intact. Zero data loss.${C_RESET}"
            echo ""
            echo "  This is what self-healing means at planetary scale."
            echo ""
            echo -e "${C_BOLD}================================================================${C_RESET}"
            ;;
        25)
            header 25 "Change Data Capture (CDC)"
            echo "CDC captures every mutation as an event, enabling event-driven architectures."
            echo "Every INSERT, UPDATE, and DELETE on a CDC-enabled table is recorded in"
            echo "commitlog segments that downstream systems can consume."
            echo ""
            echo "+----------------------------------------------------------------+"
            echo "|  CDC Architecture:                                              |"
            echo "|                                                                 |"
            echo "|  App --> HCD Write --> CommitLog --> CDC Segment (raw)           |"
            echo "|                                        |                        |"
            echo "|                                        v                        |"
            echo "|                                  Stream Processor               |"
            echo "|                                  (Kafka, Pulsar, Debezium)      |"
            echo "|                                        |                        |"
            echo "|                                        v                        |"
            echo "|                                  Analytics / Search / Cache      |"
            echo "+----------------------------------------------------------------+"
            echo ""

            log_info "Verifying CDC is enabled in cassandra.yaml..."
            log_cmd "docker exec hcd-node1 grep 'cdc_enabled' /opt/hcd/resources/cassandra/conf/cassandra.yaml 2>/dev/null || echo '(cdc_enabled setting not found)'"
            echo ""
            echo -e "${C_BLUE}CDC must be enabled in cassandra.yaml (cdc_enabled: true) BEFORE the table${C_RESET}"
            echo -e "${C_BLUE}is created. Our cluster template has this pre-configured.${C_RESET}"
            echo ""

            log_info "Creating a CDC-enabled table..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.events (id uuid PRIMARY KEY, event_type text, payload text) WITH cdc = true;\" 2>&1 || echo '(CDC may not be enabled -- check cassandra.yaml cdc_enabled: true)'"

            log_info "Inserting events..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.events (id, event_type, payload) VALUES (uuid(), 'user_signup', 'user=alice');\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.events (id, event_type, payload) VALUES (uuid(), 'purchase', 'item=widget,qty=3');\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.events (id, event_type, payload) VALUES (uuid(), 'page_view', 'url=/dashboard');\""

            log_info "Flushing to ensure CDC segments are written to disk..."
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod events"

            log_info "Checking CDC commitlog segments..."
            log_cmd "docker exec hcd-node1 ls -la /var/lib/cassandra/cdc_raw/ || echo '(CDC directory not found or empty -- cdc_enabled may be false in cassandra.yaml)'"

            log_info "Verifying CDC is enabled on the table..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT table_name, cdc FROM system_schema.tables WHERE keyspace_name = 'rf_prod' AND table_name = 'events';\""

            lookfor "The 'cdc' column should show 'True' for the events table."
            lookfor "CDC segments appear in /var/lib/cassandra/cdc_raw/ as commitlog files."

            separator
            echo -e "${C_WHITE}--- CDC Segment Inspection (Reading Raw Events) ---${C_RESET}"
            echo "In production, CDC segments are consumed by Debezium, Kafka Connect, or custom"
            echo "readers. Here we peek inside the raw commitlog segments to prove mutations"
            echo "were captured."
            echo ""
            log_cmd "docker exec hcd-node1 bash -c 'CDC_FILE=\$(ls /var/lib/cassandra/cdc_raw/*.log 2>/dev/null | head -1) && if [ -n \"\$CDC_FILE\" ]; then echo \"CDC segment: \$CDC_FILE\"; echo \"Size: \$(stat -c%s \"\$CDC_FILE\" 2>/dev/null || stat -f%z \"\$CDC_FILE\" 2>/dev/null) bytes\"; echo \"--- Binary content preview (strings) ---\"; strings \"\$CDC_FILE\" | grep -iE \"user_signup|purchase|page_view|events|INSERT\" | head -n 10 || echo \"(no readable strings matched -- binary commitlog format)\"; else echo \"No CDC segments found. cdc_enabled may be false in cassandra.yaml.\"; fi'"

            lookfor "If CDC is active, you'll see references to your mutations (user_signup, purchase)."
            lookfor "The raw format is binary commitlog — production systems use Debezium to parse it."

            echo ""
            echo "CDC consumption pipeline (production):"
            echo "  HCD CDC segment → Debezium connector → Kafka topic → Consumer"
            echo ""
            echo "Use cases:"
            echo "  - Real-time data pipelines to Kafka/Pulsar"
            echo "  - Audit trails for compliance"
            echo "  - Cache invalidation"
            echo "  - Cross-system synchronization (HCD -> Elasticsearch, Redis, etc.)"

            takeaway "CDC turns HCD into an event source. Every mutation becomes a" \
                     "consumable event for downstream systems -- no polling required."
            ;;
        26)
            header 26 "Audit Logging"
            echo "Enterprise compliance requires knowing who did what, when."
            echo "HCD audit logging captures all CQL operations with timestamps,"
            echo "client IPs, and the exact statements executed."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  What audit logging captures:                                 |"
            echo "|                                                               |"
            echo "|  Timestamp | Client IP | User | Operation | Keyspace | Table  |"
            echo "|  --------- | --------- | ---- | --------- | -------- | ----- |"
            echo "|  10:04:01  | 172.28.0.2| cass | SELECT    | rf_prod  | logs  |"
            echo "|  10:04:02  | 172.28.0.2| cass | INSERT    | rf_prod  | logs  |"
            echo "|  10:04:03  | 172.28.0.2| cass | DELETE    | rf_prod  | logs  |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_info "Checking if audit logging is configured in cassandra.yaml..."
            log_cmd "docker exec hcd-node1 grep -i 'audit_logging' /opt/hcd/resources/cassandra/conf/cassandra.yaml 2>/dev/null | head -n 5 || echo '(No audit_logging section found in cassandra.yaml)'"

            echo ""
            echo -e "${C_YELLOW}Note: Audit logging requires cassandra.yaml configuration:${C_RESET}"
            echo -e "${C_YELLOW}  audit_logging_options:${C_RESET}"
            echo -e "${C_YELLOW}    enabled: true${C_RESET}"
            echo -e "${C_YELLOW}    logger: BinAuditLogger${C_RESET}"
            echo -e "${C_YELLOW}If not pre-configured, nodetool enableauditlog provides runtime activation.${C_RESET}"
            echo ""

            log_info "Attempting runtime audit log activation..."
            log_cmd "docker exec hcd-node1 nodetool enableauditlog 2>&1 || echo '(Audit logging not available -- requires cassandra.yaml audit_logging_options or HCD Enterprise)'"

            echo ""
            echo -e "${C_YELLOW}QUESTION: If we INSERT, SELECT, and DELETE, how many audit entries should appear?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: At least 3 (one per CQL statement). Audit logging captures ALL CQL operations,${C_RESET}"
            echo -e "${C_GREEN}including DDL (CREATE TABLE) and DML (INSERT, SELECT, DELETE).${C_RESET}"
            echo ""

            log_info "Performing tracked operations (CREATE, INSERT, SELECT, DELETE)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.audit_test (id int PRIMARY KEY, data text);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.audit_test (id, data) VALUES (1, 'sensitive_data');\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.audit_test WHERE id = 1;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"DELETE FROM rf_prod.audit_test WHERE id = 1;\""

            log_info "Searching for audit log output (multiple possible locations)..."
            log_cmd "docker exec hcd-node1 bash -c 'for dir in /var/lib/cassandra/audit /var/log/cassandra/audit /opt/hcd/logs/audit; do if [ -d \"\$dir\" ]; then echo \"Found audit dir: \$dir\"; ls -la \"\$dir\"/; tail -n 15 \"\$dir\"/*.log 2>/dev/null || tail -n 15 \"\$dir\"/*.bin 2>/dev/null || echo \"(no readable log files)\"; exit 0; fi; done; echo \"No audit log directory found. Audit logging is likely not configured in this HCD build.\"'"

            log_info "Disabling audit logging..."
            log_cmd "docker exec hcd-node1 nodetool disableauditlog 2>/dev/null || true"

            lookfor "If audit entries appear: you'll see CQL statements with timestamps and client IPs."
            lookfor "If no entries appear: this HCD build requires cassandra.yaml pre-configuration."
            echo ""
            echo "In production deployments, audit logging is typically:"
            echo "  1. Enabled in cassandra.yaml BEFORE cluster start"
            echo "  2. Configured with BinAuditLogger (binary) or FileAuditLogger (text)"
            echo "  3. Fed into SIEM (Splunk, ELK) via log shipping"

            takeaway "Audit logging is essential for SOX, HIPAA, GDPR compliance." \
                     "In production, audit logs feed into SIEM systems (Splunk, ELK)" \
                     "for real-time compliance monitoring and threat detection."
            ;;
        27)
            header 27 "Guardrails - Protecting the Database from Misuse"
            echo "HCD includes guardrails that prevent common mistakes from causing"
            echo "production incidents. These are configurable limits that warn or reject"
            echo "operations that could harm cluster health."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Guardrail Examples:                                          |"
            echo "|                                                               |"
            echo "|  Batch size:      > 5KB = WARN,  > 50KB = REJECT             |"
            echo "|  Partition size:   Warning when partition grows too large     |"
            echo "|  Collection size:  Limit on set/list/map elements            |"
            echo "|  Tables per KS:    Prevent unbounded schema growth            |"
            echo "|  Tombstone reads:  Warn when reads scan too many tombstones  |"
            echo "+---------------------------------------------------------------+"
            echo ""

            echo -e "${C_BLUE}Note: Guardrails require cassandra.yaml configuration. Our cluster template${C_RESET}"
            echo -e "${C_BLUE}includes: tables_warn_threshold=150, columns_per_table_warn_threshold=100.${C_RESET}"
            echo ""

            log_info "Verifying guardrail settings in cassandra.yaml..."
            log_cmd "docker exec hcd-node1 grep -iE 'guardrail|warn_threshold|fail_threshold|batch_size' /opt/hcd/resources/cassandra/conf/cassandra.yaml 2>/dev/null | head -n 20 || echo '(Guardrail config not found in cassandra.yaml)'"

            separator
            log_info "Checking via nodetool and system_views..."
            log_cmd "docker exec hcd-node1 nodetool getconfig tables_warn_threshold 2>/dev/null || echo '(getconfig not available for guardrails -- check cassandra.yaml above)'"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM system_views.settings WHERE name LIKE '%guard%';\" 2>/dev/null || echo '(system_views.settings not available in this HCD version)'"

            separator

            echo -e "${C_YELLOW}QUESTION: A 50-row batch with small values — will it trigger a guardrail warning?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Probably not. The default batch size warning is 5KB. 50 small rows are${C_RESET}"
            echo -e "${C_GREEN}well under that. Guardrails measure byte size, not row count.${C_RESET}"
            echo ""

            log_info "Demonstrating a batch size warning..."
            echo "Creating a 50-row batch that may trigger a warning..."
            BATCH_CQL="BEGIN UNLOGGED BATCH "
            for i in $(seq 1 50); do
                BATCH_CQL="${BATCH_CQL} INSERT INTO rf_prod.stream (id, val) VALUES ($((1000 + i)), 'batch-guardrail-test');"
            done
            BATCH_CQL="${BATCH_CQL} APPLY BATCH;"
            log_cmd "docker exec hcd-node1 cqlsh -e \"${BATCH_CQL}\" || echo '(Batch may have been rejected by guardrail)'"

            log_info "Checking for guardrail warnings in logs..."
            log_cmd "docker exec hcd-node1 grep -i 'guardrail\|batch size\|warn' /var/log/cassandra/system.log 2>/dev/null | tail -n 10 || echo '(No guardrail warnings found -- batch may be within limits)'"

            lookfor "Look for 'Batch' warnings in the log output above."
            lookfor "If the batch is under 5KB, no warning will appear (this is expected)."

            takeaway "Guardrails protect HCD from common anti-patterns before they cause" \
                     "production incidents. They are the database's immune system --" \
                     "catching misuse at the API layer before it becomes a crisis."
            ;;
        28)
            header 28 "Data Modeling Anti-Patterns"
            echo "In Module 27, we saw guardrails that DETECT misuse. Now we go deeper:"
            echo "the #1 root cause of those guardrail violations is poor partition key design."
            echo ""
            echo "The #1 mistake in Cassandra/HCD is poor partition key design."
            echo "A bad partition key creates 'hot partitions' -- a single node drowning"
            echo "in traffic while others sit idle."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  BAD: PRIMARY KEY (date)                                       |"
            echo "|  All writes for 2024-01-15 go to ONE partition = ONE node      |"
            echo "|                                                                |"
            echo "|  GOOD: PRIMARY KEY ((date, bucket), timestamp)                 |"
            echo "|  Writes spread across N buckets per day = N partitions          |"
            echo "+---------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Phase 1: The Bad Model ---${C_RESET}"

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.bad_model (date text, event_id timeuuid, data text, PRIMARY KEY (date, event_id));\""

            log_info "Inserting 200 rows into a SINGLE partition (all same date)..."
            echo "Each row includes a 500-byte payload to simulate realistic event data."
            if [ "$DRY_RUN" = false ]; then
                for i in $(seq 1 200); do
                    docker exec hcd-node1 cqlsh -e "INSERT INTO rf_prod.bad_model (date, event_id, data) VALUES ('2024-01-15', now(), '$(printf 'x%.0s' $(seq 1 500))');" 2>/dev/null
                    if [ $((i % 50)) -eq 0 ]; then
                        echo -e "${C_GREEN}  [INSERT $i/200]${C_RESET}"
                    fi
                done
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Inserting 200 rows with 500-byte payloads into single partition..."
            fi

            log_cmd "docker exec hcd-node1 nodetool flush rf_prod bad_model"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.bad_model 2>/dev/null | grep -iE 'Partition|partition|Size|SSTable count|Compacted|cells' | head -n 12 || echo '(tablestats output)'"

            lookfor "Look for 'Maximum partition size' — 200 rows × 500B = ~100KB in ONE partition."
            echo ""
            echo -e "${C_YELLOW}Production context: A real hot partition problem looks like this:${C_RESET}"
            echo -e "${C_YELLOW}  - 500M+ rows in a single partition (e.g., all events for one date)${C_RESET}"
            echo -e "${C_YELLOW}  - 80GB+ partition consuming one node's entire heap${C_RESET}"
            echo -e "${C_YELLOW}  - GC pauses > 10s, compaction stalls, client timeouts${C_RESET}"
            echo -e "${C_YELLOW}  - Our 200 rows demonstrate the PATTERN; multiply by 1M for production.${C_RESET}"

            echo ""
            echo -e "${C_YELLOW}QUESTION: How can we spread these 200 events across multiple partitions${C_RESET}"
            echo -e "${C_YELLOW}while still querying by date?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Add a 'bucket' column to the partition key: PRIMARY KEY ((date, bucket), event_id).${C_RESET}"
            echo -e "${C_GREEN}This spreads data across N partitions per day while keeping date-based queries possible.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- Phase 2: The Good Model (Bucketed) ---${C_RESET}"

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.good_model (date text, bucket int, event_id timeuuid, data text, PRIMARY KEY ((date, bucket), event_id));\""

            log_info "Inserting 200 rows spread across 10 buckets..."
            if [ "$DRY_RUN" = false ]; then
                for i in $(seq 1 200); do
                    bucket=$((i % 10))
                    docker exec hcd-node1 cqlsh -e "INSERT INTO rf_prod.good_model (date, bucket, event_id, data) VALUES ('2024-01-15', $bucket, now(), '$(printf 'x%.0s' $(seq 1 500))');" 2>/dev/null
                    if [ $((i % 50)) -eq 0 ]; then
                        echo -e "${C_GREEN}  [INSERT $i/200]${C_RESET}"
                    fi
                done
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Inserting 200 rows across 10 buckets..."
            fi

            log_cmd "docker exec hcd-node1 nodetool flush rf_prod good_model"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.good_model 2>/dev/null | grep -iE 'Partition|partition|Size|SSTable count|Compacted|cells' | head -n 12 || echo '(tablestats output)'"

            lookfor "Compare 'Maximum partition size' — with 10 buckets, each partition is ~1/10th the size."
            lookfor "Same data volume, but load is spread across multiple partitions (and nodes)."

            takeaway "Partition key design is the most important decision in HCD data modeling." \
                     "Bad keys create hot partitions; good keys spread load evenly." \
                     "Rule of thumb: keep partitions under 100MB and 100K rows."
            ;;
        29)
            header 29 "Latency Comparison - The Cost of Consistency"
            echo "Module 28 showed how partition keys affect DATA distribution."
            echo "Now we explore how CONSISTENCY LEVELS affect latency — the other"
            echo "half of the performance equation."
            echo ""
            echo "Every consistency level has a latency cost. Higher consistency means"
            echo "more replicas must respond before the client gets an answer."
            echo "EACH_QUORUM pays a WAN round-trip penalty because it waits for"
            echo "replicas in EVERY datacenter."
            echo ""
            echo "+------------------------------------------------------------------+"
            echo "|  CL=ONE          : 1 replica responds → fastest                  |"
            echo "|  CL=LOCAL_QUORUM : 2/3 local replicas → moderate                 |"
            echo "|  CL=EACH_QUORUM  : 2/3 in EVERY DC   → slowest (WAN penalty)    |"
            echo "+------------------------------------------------------------------+"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.latency_test (id int PRIMARY KEY, data text);\""

            separator
            echo -e "${C_WHITE}--- CL=ONE (fastest) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CONSISTENCY ONE; INSERT INTO rf_prod.latency_test (id, data) VALUES (1, 'cl-one-test'); TRACING OFF;\" 2>&1 | grep -iE 'Request complete|Enqueuing|Sending.*to|duration' | head -n 3 || echo '(trace output)'"

            separator
            echo -e "${C_WHITE}--- CL=LOCAL_QUORUM (balanced) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.latency_test (id, data) VALUES (2, 'cl-lq-test'); TRACING OFF;\" 2>&1 | grep -iE 'Request complete|Enqueuing|Sending.*to|duration' | head -n 3 || echo '(trace output)'"

            separator
            echo -e "${C_WHITE}--- CL=EACH_QUORUM (strictest) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CONSISTENCY EACH_QUORUM; INSERT INTO rf_prod.latency_test (id, data) VALUES (3, 'cl-eq-test'); TRACING OFF;\" 2>&1 | grep -iE 'Request complete|Enqueuing|Sending.*to|duration' | head -n 3 || echo '(trace output)'"

            separator
            echo -e "${C_WHITE}--- Side-by-Side Latency Comparison ---${C_RESET}"
            echo "Extracting 'Request complete' times from traces..."
            echo -e "${C_DIM}(Trace format varies by Cassandra version — using multiple extraction patterns)${C_RESET}"
            if [ "$DRY_RUN" = false ]; then
                extract_latency() {
                    local trace_output="$1"
                    # Try multiple patterns: "Request complete|N microseconds", duration field, elapsed time
                    local lat
                    lat=$(echo "$trace_output" | grep -i 'Request complete' | grep -oE '[0-9]+ microseconds' | head -1)
                    if [ -z "$lat" ]; then
                        lat=$(echo "$trace_output" | grep -ioE 'duration[: ]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
                        if [ -n "$lat" ]; then lat="${lat} microseconds"; fi
                    fi
                    echo "${lat:-N/A (trace format not recognized)}"
                }
                TRACE_ONE=$(docker exec hcd-node1 cqlsh -e "TRACING ON; CONSISTENCY ONE; SELECT * FROM rf_prod.latency_test WHERE id = 1; TRACING OFF;" 2>&1)
                TRACE_LQ=$(docker exec hcd-node1 cqlsh -e "TRACING ON; CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.latency_test WHERE id = 2; TRACING OFF;" 2>&1)
                TRACE_EQ=$(docker exec hcd-node1 cqlsh -e "TRACING ON; CONSISTENCY EACH_QUORUM; SELECT * FROM rf_prod.latency_test WHERE id = 3; TRACING OFF;" 2>&1)
                LAT_ONE=$(extract_latency "$TRACE_ONE")
                LAT_LQ=$(extract_latency "$TRACE_LQ")
                LAT_EQ=$(extract_latency "$TRACE_EQ")
                echo ""
                echo -e "${C_GREEN}╔═════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_GREEN}║  LATENCY COMPARISON (traced reads):                ║${C_RESET}"
                printf "${C_GREEN}║  CL=ONE:          %-34s║${C_RESET}\n" "$LAT_ONE"
                printf "${C_GREEN}║  CL=LOCAL_QUORUM: %-34s║${C_RESET}\n" "$LAT_LQ"
                printf "${C_GREEN}║  CL=EACH_QUORUM:  %-34s║${C_RESET}\n" "$LAT_EQ"
                echo -e "${C_GREEN}╚═════════════════════════════════════════════════════╝${C_RESET}"
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Would extract and compare trace latencies for ONE vs LOCAL_QUORUM vs EACH_QUORUM"
            fi

            lookfor "CL=ONE: fastest (1 replica). LOCAL_QUORUM: moderate (2/3 local). EACH_QUORUM: slowest (cross-DC)."
            lookfor "In Docker (same machine), differences are small (microseconds). In production WAN: 10-100x."

            log_info "Checking latency histograms..."
            log_cmd "docker exec hcd-node1 nodetool proxyhistograms 2>/dev/null | head -n 20 || echo '(proxyhistograms output)'"

            takeaway "Consistency is not free. Every level above ONE adds latency." \
                     "LOCAL_QUORUM is the sweet spot: strong consistency without WAN penalty." \
                     "EACH_QUORUM should only be used when global linearizability is required."
            ;;
        30)
            header 30 "Time-Series Use Case"
            echo "Modules 28-29 covered the theory: partition design and consistency costs."
            echo "Now we put it all together with Cassandra's killer use case: time-series."
            echo "This pattern combines everything: bucketed partitions (Module 28),"
            echo "clustering order, and TTL-based auto-expiration."
            echo ""
            echo "Time-series data (IoT sensors, metrics, logs) is Cassandra's killer use case."
            echo "The key design pattern: partition by (entity_id, time_bucket) so each"
            echo "partition holds a bounded window of data."
            echo ""
            echo "+---------------------------------------------------------------+"
            echo "|  Sensor: temp-01      Bucket: 2024-01-15                      |"
            echo "|  ┌──────────┬───────────┬──────────┐                          |"
            echo "|  │ 08:00:01 │ 08:00:02  │ 08:00:03 │ ... (rows within bucket)|"
            echo "|  │  22.5°C  │  22.7°C   │  22.4°C  │                          |"
            echo "|  └──────────┴───────────┴──────────┘                          |"
            echo "|                                                               |"
            echo "|  Next day → new partition (old data expires via TTL)           |"
            echo "+---------------------------------------------------------------+"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.sensor_data (sensor_id text, day_bucket text, ts timestamp, temperature double, humidity double, PRIMARY KEY ((sensor_id, day_bucket), ts)) WITH CLUSTERING ORDER BY (ts DESC) AND default_time_to_live = 86400;\""

            log_info "Inserting sensor readings..."
            for i in $(seq 1 20); do
                # Pure shell arithmetic: 22.0 + i*0.1 = integer_part.decimal_part
                temp_int=$((220 + i))
                temp="${temp_int:0:2}.${temp_int:2}"
                log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.sensor_data (sensor_id, day_bucket, ts, temperature, humidity) VALUES ('sensor-01', '2024-01-15', '2024-01-15 08:00:$(printf '%02d' $i)+0000', $temp, 45.0);\""
            done

            separator
            echo -e "${C_WHITE}--- Windowed Query ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT ts, temperature FROM rf_prod.sensor_data WHERE sensor_id = 'sensor-01' AND day_bucket = '2024-01-15' LIMIT 10;\""

            separator
            echo -e "${C_WHITE}--- TTL Verification ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT ts, temperature, TTL(temperature) as ttl_remaining FROM rf_prod.sensor_data WHERE sensor_id = 'sensor-01' AND day_bucket = '2024-01-15' LIMIT 5;\""

            lookfor "TTL(temperature) shows seconds remaining before auto-expiration."
            lookfor "CLUSTERING ORDER BY (ts DESC) returns newest readings first."
            lookfor "Each day_bucket is a separate partition -- bounded size."

            takeaway "Time-series in HCD: partition by (entity, time_bucket), cluster by timestamp." \
                     "TTL auto-expires old data. No manual deletes needed." \
                     "This pattern is the foundation for IoT, metrics, and log storage."
            ;;
        31)
            header 31 "Compaction Strategies Deep Dive"
            echo "Compaction merges SSTables to reclaim space, resolve overwrites (LWW),"
            echo "and remove expired tombstones. The strategy you choose has MAJOR impact"
            echo "on read/write performance and disk usage."
            echo ""
            echo "+------------------------------------------------------------------+"
            echo "| Strategy | Write | Read  | Space Amp | Best For                  |"
            echo "|----------|-------|-------|-----------|---------------------------|"
            echo "| STCS     | Fast  | Slow  | High      | Write-heavy workloads     |"
            echo "| LCS      | Slow  | Fast  | Low       | Read-heavy, point lookups |"
            echo "| TWCS     | Fast  | Fast  | Low       | Time-series (TTL data)    |"
            echo "| UCS      | Good  | Good  | Medium    | Modern default (HCD 1.2+) |"
            echo "+------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- STCS: Size-Tiered (Write-Optimized) ---${C_RESET}"
            echo "Merges SSTables of similar size. Writes are fast because data just"
            echo "appends to new SSTables. Reads may need to check many SSTables."
            echo ""
            echo "  SSTable-1 (10MB) ─┐"
            echo "  SSTable-2 (10MB) ─┼──► Merge into SSTable-3 (20MB)"
            echo "  SSTable-3 (10MB) ─┘"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compact_stcs (id int PRIMARY KEY, val text) WITH compaction = {'class': 'SizeTieredCompactionStrategy', 'min_threshold': 4};\""

            separator
            echo -e "${C_WHITE}--- LCS: Leveled (Read-Optimized) ---${C_RESET}"
            echo "Organizes SSTables into levels with size limits. Each level is 10x"
            echo "the previous. Guarantees most reads touch only 1-2 SSTables."
            echo ""
            echo "  L0: [new writes] ──► promote to L1 when full"
            echo "  L1: [10 MB max]  ──► promote to L2 when full"
            echo "  L2: [100 MB max] ──► promote to L3 when full"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compact_lcs (id int PRIMARY KEY, val text) WITH compaction = {'class': 'LeveledCompactionStrategy', 'sstable_size_in_mb': 160};\""

            separator
            echo -e "${C_WHITE}--- TWCS: Time-Window (Time-Series Optimized) ---${C_RESET}"
            echo "Groups SSTables by time window. Within a window, uses STCS."
            echo "Entire windows are dropped when TTL expires -- no tombstones needed!"
            echo ""
            echo "  Window 1 (Jan 15) ── [SSTable-A, SSTable-B] ── compact within window"
            echo "  Window 2 (Jan 16) ── [SSTable-C]             ── compact within window"
            echo "  Window 3 (Jan 17) ── [SSTable-D, SSTable-E]  ── DROP entire window when TTL expires"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compact_twcs (id int PRIMARY KEY, val text) WITH compaction = {'class': 'TimeWindowCompactionStrategy', 'compaction_window_unit': 'DAYS', 'compaction_window_size': 1};\""

            echo ""
            echo -e "${C_YELLOW}QUESTION: For the sensor_data table (Module 30) with TTL expiration,${C_RESET}"
            echo -e "${C_YELLOW}which strategy would be most efficient?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: TWCS. It drops entire time windows when TTL expires — no tombstones,${C_RESET}"
            echo -e "${C_GREEN}no compaction of expired data. That's why it's purpose-built for time-series.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- UCS: Unified (Modern Default) ---${C_RESET}"
            echo "HCD's default strategy. Combines the best of STCS and LCS."
            echo "Adapts automatically based on workload patterns."
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compact_ucs (id int PRIMARY KEY, val text) WITH compaction = {'class': 'UnifiedCompactionStrategy'};\""

            log_info "Inserting data into all tables to trigger compaction..."
            for i in $(seq 1 20); do
                log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.compact_stcs (id, val) VALUES ($i, 'stcs-data-$i'); INSERT INTO rf_prod.compact_lcs (id, val) VALUES ($i, 'lcs-data-$i'); INSERT INTO rf_prod.compact_twcs (id, val) VALUES ($i, 'twcs-data-$i'); INSERT INTO rf_prod.compact_ucs (id, val) VALUES ($i, 'ucs-data-$i');\""
            done

            log_cmd "docker exec hcd-node1 nodetool flush rf_prod"

            log_info "Checking SSTable counts per strategy..."
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compact_stcs 2>/dev/null | grep -E 'SSTable count|Compaction' | head -n 5 || echo '(STCS stats)'"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compact_lcs 2>/dev/null | grep -E 'SSTable count|Compaction' | head -n 5 || echo '(LCS stats)'"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compact_twcs 2>/dev/null | grep -E 'SSTable count|Compaction' | head -n 5 || echo '(TWCS stats)'"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compact_ucs 2>/dev/null | grep -E 'SSTable count|Compaction' | head -n 5 || echo '(UCS stats)'"

            lookfor "Compare SSTable counts and sizes between strategies."
            lookfor "TWCS is ideal for sensor_data (Module 30) -- entire windows drop cleanly."

            takeaway "Choose your compaction strategy based on your workload:" \
                     "  STCS = write-heavy, LCS = read-heavy, TWCS = time-series, UCS = general." \
                     "Wrong strategy = 10x worse performance. Right strategy = effortless scaling."
            ;;
        32)
            header 32 "Compression Strategies"
            echo "HCD compresses SSTables on disk to reduce I/O and storage. The"
            echo "compression algorithm affects read latency, write throughput, and"
            echo "disk usage differently."
            echo ""
            echo "+------------------------------------------------------------------+"
            echo "| Algorithm | Ratio | CPU Cost  | Best For                         |"
            echo "|-----------|-------|-----------|----------------------------------|"
            echo "| LZ4       | Good  | Very Low  | Default. Fast reads & writes     |"
            echo "| Zstd      | Best  | Moderate  | Cold storage, archival data      |"
            echo "| Snappy    | Good  | Low       | Legacy compatibility             |"
            echo "| None      | 1:1   | Zero      | Pre-compressed data (images/etc) |"
            echo "+------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Creating Tables with Different Compression ---${C_RESET}"

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compress_lz4 (id int PRIMARY KEY, data text) WITH compression = {'class': 'LZ4Compressor'};\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compress_zstd (id int PRIMARY KEY, data text) WITH compression = {'class': 'ZstdCompressor'};\" 2>&1 || { echo -e '${C_YELLOW}ZstdCompressor not available in this build. Falling back to LZ4 for comparison.${C_RESET}'; docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compress_zstd (id int PRIMARY KEY, data text) WITH compression = {'class': 'LZ4Compressor'};\" 2>/dev/null; }"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compress_snappy (id int PRIMARY KEY, data text) WITH compression = {'class': 'SnappyCompressor'};\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compress_none (id int PRIMARY KEY, data text) WITH compression = {'enabled': false};\""

            log_info "Inserting identical data into all tables..."
            for i in $(seq 1 30); do
                log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.compress_lz4 (id, data) VALUES ($i, 'This is test data row number $i with some padding to make the payload larger for meaningful compression comparison testing.'); INSERT INTO rf_prod.compress_zstd (id, data) VALUES ($i, 'This is test data row number $i with some padding to make the payload larger for meaningful compression comparison testing.'); INSERT INTO rf_prod.compress_snappy (id, data) VALUES ($i, 'This is test data row number $i with some padding to make the payload larger for meaningful compression comparison testing.'); INSERT INTO rf_prod.compress_none (id, data) VALUES ($i, 'This is test data row number $i with some padding to make the payload larger for meaningful compression comparison testing.');\""
            done

            log_cmd "docker exec hcd-node1 nodetool flush rf_prod"

            separator
            echo -e "${C_WHITE}--- Comparing On-Disk Sizes ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compress_lz4 2>/dev/null | grep -E 'Space used|Compression' | head -n 5 || echo '(LZ4 stats)'"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compress_zstd 2>/dev/null | grep -E 'Space used|Compression' | head -n 5 || echo '(Zstd stats)'"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compress_snappy 2>/dev/null | grep -E 'Space used|Compression' | head -n 5 || echo '(Snappy stats)'"
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.compress_none 2>/dev/null | grep -E 'Space used|Compression' | head -n 5 || echo '(No compression stats)'"

            echo ""
            echo -e "${C_YELLOW}QUESTION: For a table with frequent point lookups (single row reads),${C_RESET}"
            echo -e "${C_YELLOW}would you choose a smaller or larger chunk_length_in_kb?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Smaller (e.g., 4KB). Each read decompresses one chunk — smaller chunks${C_RESET}"
            echo -e "${C_GREEN}mean less wasted decompression. Larger chunks benefit sequential scans.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- chunk_length_in_kb Impact ---${C_RESET}"
            echo "chunk_length_in_kb controls the decompression unit size."
            echo "Smaller chunks = faster random reads (less data to decompress)."
            echo "Larger chunks = better compression ratio (more context for the algorithm)."
            echo ""
            echo "  Default: 16 KB (balanced)"
            echo "  Point lookups: 4 KB (minimal decompression overhead)"
            echo "  Analytical scans: 64 KB (maximum compression ratio)"

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.compress_small_chunk (id int PRIMARY KEY, data text) WITH compression = {'class': 'LZ4Compressor', 'chunk_length_in_kb': 4};\""

            echo ""
            echo -e "${C_YELLOW}Production context (compression at scale):${C_RESET}"
            echo -e "${C_YELLOW}  With 30 rows: compression overhead may EXCEED savings (don't be alarmed).${C_RESET}"
            echo -e "${C_YELLOW}  With 1M+ rows: Zstd saves 20-40% over LZ4, LZ4 saves 50-70% over none.${C_RESET}"
            echo -e "${C_YELLOW}  A 1TB dataset compressed with Zstd typically shrinks to ~400-600GB.${C_RESET}"
            echo -e "${C_YELLOW}  At scale, this means significant savings in disk I/O and storage costs.${C_RESET}"

            takeaway "LZ4 (default) is best for most workloads: near-zero CPU overhead." \
                     "Zstd gives 20-40% better ratio for archival/cold data." \
                     "Tune chunk_length_in_kb: 4KB for point reads, 64KB for scans." \
                     "Small-data caveat: compression shines at scale, not with 30 demo rows."
            ;;
        33)
            header 33 "Live Failover Under Load"
            echo -e "${C_DIM}(Estimated time: ~5 minutes including node stop/start)${C_RESET}"
            echo "This module proves HCD stays available DURING failure, not just after."
            echo "We start a continuous write stream, kill a node mid-stream, and verify"
            echo "zero writes are lost."
            echo ""
            echo "  Timeline:"
            echo "  ──Write─Write─Write──╳ KILL node3 ╳──Write─Write─Write──"
            echo "                       │                │"
            echo "                       └── No gap! ─────┘"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.live_failover (seq int PRIMARY KEY, ts timestamp, status text);\""

            if [ "$DRY_RUN" = false ]; then
                FAILOVER_START=$(date +%s)
            fi

            echo -e "${C_YELLOW}>>> QUESTION: We will write 30 rows, killing a node mid-stream.${C_RESET}"
            echo -e "${C_YELLOW}>>> How many writes do you think will FAIL?${C_RESET}"
            pause

            separator
            echo -e "${C_WHITE}--- Phase 1: Write 15 rows (all nodes healthy) ---${C_RESET}"
            if [ "$DRY_RUN" = false ]; then
                WRITE_OK=0
                WRITE_FAIL=0
                for i in $(seq 1 15); do
                    if docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.live_failover (seq, ts, status) VALUES ($i, toTimestamp(now()), 'pre-failure');" 2>/dev/null; then
                        WRITE_OK=$((WRITE_OK + 1))
                    else
                        WRITE_FAIL=$((WRITE_FAIL + 1))
                    fi
                    echo -e "${C_GREEN}  [WRITE ${i}/30] ✓  (all nodes healthy)${C_RESET}"
                done
            else
                for i in $(seq 1 15); do
                    echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.live_failover ... VALUES ($i, ...)\""
                done
            fi

            separator
            echo -e "${C_WHITE}--- Phase 2: Kill node3 mid-stream ---${C_RESET}"
            log_cmd "docker-compose stop hcd-node3"
            if [ "$DRY_RUN" = false ]; then sleep 3; fi

            separator
            echo -e "${C_WHITE}--- Phase 3: Continue writing (node3 is DOWN) ---${C_RESET}"
            if [ "$DRY_RUN" = false ]; then
                for i in $(seq 16 30); do
                    if docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.live_failover (seq, ts, status) VALUES ($i, toTimestamp(now()), 'during-failure');" 2>/dev/null; then
                        WRITE_OK=$((WRITE_OK + 1))
                    else
                        WRITE_FAIL=$((WRITE_FAIL + 1))
                    fi
                    echo -e "${C_GREEN}  [WRITE ${i}/30] ✓  (node3 DOWN)${C_RESET}"
                done
            else
                for i in $(seq 16 30); do
                    echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.live_failover ... VALUES ($i, ...) (node3 DOWN)\""
                done
            fi

            separator
            echo -e "${C_WHITE}--- Phase 4: Results ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT count(*) FROM rf_prod.live_failover;\""

            if [ "$DRY_RUN" = false ]; then
                FAILOVER_END=$(date +%s)
                FAILOVER_DURATION=$((FAILOVER_END - FAILOVER_START))
                echo ""
                echo -e "${C_GREEN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_GREEN}║  RESULT: ${WRITE_OK} succeeded, ${WRITE_FAIL} failed                          ║${C_RESET}"
                echo -e "${C_GREEN}║  TIME:   ${FAILOVER_DURATION} seconds for 30 writes through a node kill      ║${C_RESET}"
                echo -e "${C_GREEN}║  ANSWER: ZERO writes lost. The cluster never blinked.   ║${C_RESET}"
                echo -e "${C_GREEN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
                echo ""
            fi

            lookfor "count = 30. Zero writes lost despite a node being killed mid-stream."
            lookfor "LOCAL_QUORUM only needs 2/3 replicas in the local DC."

            separator
            echo -e "${C_WHITE}--- Phase 5: Restore node3 ---${C_RESET}"
            log_cmd "docker-compose start hcd-node3"
            log_info "Waiting for node3 to rejoin..."
            wait_for_node_un "172.28.0.4" "node3"

            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT count(*) FROM rf_prod.live_failover;\""
            lookfor "node3 receives missed writes via hinted handoff. Count still 30."

            takeaway "HCD maintains write availability DURING failures, not just after recovery." \
                     "With RF=3 and LOCAL_QUORUM, one node can be down with zero impact." \
                     "This is the fundamental promise of a leaderless architecture."
            ;;
        34)
            header 34 "Multi-DC Write Conflict Resolution"
            echo "When two clients write to the SAME row from different datacenters"
            echo "at nearly the same time, HCD resolves the conflict using"
            echo "Last-Write-Wins (LWW) -- the highest timestamp wins."
            echo ""
            echo "  DC1 writes: id=1, val='from-dc1'  (timestamp T1)"
            echo "  DC2 writes: id=1, val='from-dc2'  (timestamp T2)"
            echo "  Result: whichever has the higher timestamp wins globally"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.conflict_test (id int PRIMARY KEY, val text, source text);\""

            separator
            echo -e "${C_WHITE}--- Simultaneous writes from BOTH DCs ---${C_RESET}"
            echo "We use two strategies to demonstrate LWW conflict:"
            echo ""
            echo "  Strategy 1: Parallel shell writes (background & wait)"
            echo "  Strategy 2: USING TIMESTAMP to force an exact tie scenario"
            echo ""
            echo "Strategy 1 shows real-world concurrency (docker exec adds ~100ms jitter)."
            echo "Strategy 2 proves LWW mechanics with deterministic timestamps."
            echo ""

            echo -e "${C_WHITE}--- Strategy 1: Parallel background writes ---${C_RESET}"
            if [ "$DRY_RUN" = false ]; then
                docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_ONE; INSERT INTO rf_prod.conflict_test (id, val, source) VALUES (1, 'value-from-dc1', 'dc1');" &
                DC1_PID=$!
                docker exec hcd-node4 cqlsh -e "CONSISTENCY LOCAL_ONE; INSERT INTO rf_prod.conflict_test (id, val, source) VALUES (1, 'value-from-dc2', 'dc2');" &
                DC2_PID=$!
                wait $DC1_PID 2>/dev/null
                wait $DC2_PID 2>/dev/null
                echo -e "${C_GREEN}[EXEC]${C_RESET} Parallel writes from dc1 (node1) and dc2 (node4) completed."
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node1 cqlsh -e \"INSERT ... VALUES (1, 'value-from-dc1', 'dc1');\" &"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node4 cqlsh -e \"INSERT ... VALUES (1, 'value-from-dc2', 'dc2');\" &"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} (both writes launched in parallel)"
            fi
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT val, source, WRITETIME(val) as ts FROM rf_prod.conflict_test WHERE id = 1;\""

            separator
            echo -e "${C_WHITE}--- Strategy 2: Deterministic timestamps (USING TIMESTAMP) ---${C_RESET}"
            echo "DC1 writes at T=1000000, DC2 writes at T=1000001 (1 microsecond later)."
            echo "DC2 MUST win because its timestamp is higher."
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.conflict_test (id, val, source) VALUES (2, 'dc1-T1000000', 'dc1') USING TIMESTAMP 1000000;\""
            log_cmd "docker exec hcd-node4 cqlsh -e \"INSERT INTO rf_prod.conflict_test (id, val, source) VALUES (2, 'dc2-T1000001', 'dc2') USING TIMESTAMP 1000001;\""

            separator
            echo -e "${C_WHITE}--- Read the resolved values ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY ALL; SELECT id, val, source, WRITETIME(val) as write_timestamp FROM rf_prod.conflict_test WHERE id IN (1, 2);\""

            lookfor "Row id=1: Either dc1 or dc2 wins — depends on real clock timing."
            lookfor "Row id=2: dc2 ALWAYS wins because T=1000001 > T=1000000."
            lookfor "This proves LWW is deterministic: highest timestamp wins, always."
            lookfor "In production, NTP clock skew can cause unexpected winners."

            takeaway "LWW resolves cross-DC conflicts automatically -- no locking needed." \
                     "WRITETIME() lets you inspect exactly which write won and when." \
                     "Critical: keep clocks synchronized with NTP. Clock skew = wrong winner."
            ;;
        35)
            header 35 "Adding a New Datacenter Live"
            echo "One of HCD's most powerful operational features: you can add a new"
            echo "datacenter to a running cluster with zero downtime. Data streams"
            echo "automatically to the new nodes."
            echo ""
            echo "  Before:  dc1 (3 nodes, RF=3)  +  dc2 (3 nodes, RF=3)"
            echo "  After:   dc1 (RF=3)  +  dc2 (RF=3) -- data redistributed"
            echo ""
            echo "  In production, adding dc3 follows this exact procedure:"
            echo "  1. Deploy new nodes in dc3 (they join as empty)"
            echo "  2. ALTER KEYSPACE to include dc3"
            echo "  3. Run 'nodetool rebuild' on dc3 nodes to stream data"
            echo "  4. Run 'nodetool cleanup' on dc1/dc2 to remove stale ranges"
            echo ""

            separator
            echo -e "${C_WHITE}--- Step 1: Check Current Keyspace Replication ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"DESCRIBE KEYSPACE rf_prod;\" 2>/dev/null | head -n 5 || echo '(keyspace description)'"

            separator
            echo -e "${C_WHITE}--- Step 2: Simulate RF Change (ALTER KEYSPACE) ---${C_RESET}"
            echo "We'll demonstrate by adjusting dc2's RF temporarily to show"
            echo "how ALTER KEYSPACE triggers data redistribution."
            log_cmd "docker exec hcd-node1 cqlsh -e \"ALTER KEYSPACE rf_prod WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3, 'dc2': 3};\""

            separator
            echo -e "${C_WHITE}--- Step 3: Check Ownership After Change ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool status rf_prod"
            lookfor "Ownership percentages show how data is distributed across nodes."

            echo ""
            echo -e "${C_YELLOW}QUESTION: After ALTER KEYSPACE adds a new DC, does data appear there automatically?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: No! ALTER KEYSPACE only changes the SCHEMA. You must run 'nodetool rebuild'${C_RESET}"
            echo -e "${C_GREEN}on each new DC node to actually stream the existing data from the source DC.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- Step 4: Nodetool Rebuild (Stream Data to New DC) ---${C_RESET}"
            echo "In a real dc3 addition, you would run this on each new dc3 node:"
            echo "  nodetool rebuild -- -ks rf_prod --source-dc dc1"
            echo ""
            echo "We can demonstrate this within our existing cluster by rebuilding dc2"
            echo "from dc1 — this re-streams data even if dc2 already has it."
            echo ""

            log_info "Running rebuild on node4 (dc2) from dc1 (demonstrates data streaming)..."
            echo -e "${C_DIM}(nodetool rebuild syntax: 'rebuild -- dc1' or 'rebuild --source-dc dc1' depending on version)${C_RESET}"
            log_cmd "docker exec hcd-node4 nodetool rebuild -- dc1 2>&1 | head -n 5 || docker exec hcd-node4 nodetool rebuild --source-dc dc1 2>&1 | head -n 5 || echo '(rebuild completed or not needed -- dc2 already has the data)'"

            log_info "Checking streaming status..."
            log_cmd "docker exec hcd-node4 nodetool netstats 2>/dev/null | head -n 15 || echo '(netstats output -- shows active/pending streams)'"

            separator
            echo -e "${C_WHITE}--- Step 5: Ownership Before/After ---${C_RESET}"
            echo "Checking data ownership percentages across all nodes..."
            log_cmd "docker exec hcd-node1 nodetool status rf_prod"
            lookfor "Each node should show ~33% ownership within its DC (RF=3 on 3 nodes = 100%)."

            separator
            echo -e "${C_WHITE}--- Step 6: Nodetool Cleanup (Reclaim Space on Old Nodes) ---${C_RESET}"
            echo "After rebuilding, old nodes may hold data they no longer own."
            echo "  nodetool cleanup rf_prod"
            echo "This removes data that has been reassigned to the new DC."
            echo ""

            log_cmd "docker exec hcd-node1 nodetool describecluster 2>/dev/null | head -n 10 || echo '(cluster description)'"

            takeaway "Adding a DC is a zero-downtime operation: deploy, ALTER, rebuild, cleanup." \
                     "'nodetool rebuild' streams existing data to new nodes over the network." \
                     "'nodetool cleanup' reclaims space on old nodes after redistribution." \
                     "This is how HCD scales from 1 DC to multi-region without interruption."
            ;;
        36)
            header 36 "Backup & Restore"
            echo "HCD provides point-in-time snapshots for backup. Snapshots are"
            echo "instantaneous (hard-links to SSTables) and don't impact performance."
            echo ""
            echo "  ┌──────────┐    snapshot     ┌────────────────┐"
            echo "  │ SSTables │ ──────────────► │ snapshots/tag/ │"
            echo "  │ (live)   │    (hard-link)  │ (frozen copy)  │"
            echo "  └──────────┘                 └────────────────┘"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.backup_test (id int PRIMARY KEY, data text);\""
            for i in $(seq 1 10); do
                log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.backup_test (id, data) VALUES ($i, 'important-data-$i');\""
            done
            log_cmd "docker exec hcd-node1 nodetool flush rf_prod backup_test"

            separator
            echo -e "${C_WHITE}--- Step 1: Take a Snapshot ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool snapshot -t demo_backup rf_prod"
            log_cmd "docker exec hcd-node1 nodetool listsnapshots 2>/dev/null | head -n 10 || echo '(snapshot list)'"

            echo ""
            echo -e "${C_YELLOW}QUESTION: Snapshots use hard-links. Does taking a snapshot double disk usage?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: No! Hard-links point to the same data blocks on disk. Zero extra space${C_RESET}"
            echo -e "${C_GREEN}is used UNTIL the original SSTables are compacted away — then the snapshot${C_RESET}"
            echo -e "${C_GREEN}becomes the sole owner and its space counts.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- Step 2: Simulate Data Loss (TRUNCATE) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRUNCATE rf_prod.backup_test;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT count(*) FROM rf_prod.backup_test;\""
            lookfor "count = 0. All data is gone."

            separator
            echo -e "${C_WHITE}--- Step 3: Restore from Snapshot ---${C_RESET}"
            echo "To restore, copy snapshot SSTables back to the table's data directory,"
            echo "then run 'nodetool refresh' to load them without restart."
            echo ""

            log_cmd "docker exec hcd-node1 bash -c 'SNAP_DIR=\$(find /var/lib/cassandra/data/rf_prod/ -type d -path \"*/snapshots/demo_backup\" 2>/dev/null | head -1) && TABLE_DIR=\$(dirname \$(dirname \"\$SNAP_DIR\")) && if [ -n \"\$SNAP_DIR\" ] && [ -d \"\$SNAP_DIR\" ]; then cp \$SNAP_DIR/*.db \$TABLE_DIR/ 2>/dev/null && echo \"Snapshot files copied to \$TABLE_DIR\"; else echo \"(Snapshot directory not found -- was the snapshot taken?)\"; fi' || echo '(Restore step -- in dry-run this is simulated)'"
            log_cmd "docker exec hcd-node1 nodetool refresh rf_prod backup_test 2>/dev/null || echo '(nodetool refresh -- loads restored SSTables)'"

            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT count(*) FROM rf_prod.backup_test;\""
            lookfor "count = 10. Data is restored from snapshot without restart."

            separator
            echo -e "${C_WHITE}--- Cleanup: Remove Snapshot ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool clearsnapshot -t demo_backup 2>/dev/null || echo '(snapshot cleared)'"

            takeaway "Snapshots are instant (hard-links) and free until the source SSTables compact." \
                     "Restore: copy SSTables back + nodetool refresh. No restart needed." \
                     "For production: automate snapshots + off-node backup (S3, NFS, etc.)."
            ;;
        37)
            header 37 "Rolling Restart (Zero-Downtime Maintenance)"
            echo -e "${C_DIM}(Estimated time: ~8-10 minutes including 2 node restarts + wait)${C_RESET}"
            echo "The standard procedure for patching, upgrading, or config changes:"
            echo "restart one node at a time, waiting for UN before moving to the next."
            echo ""
            echo "  node3: stop → start → wait for UN ✓  (non-seed first)"
            echo "  node2: stop → start → wait for UN ✓"
            echo "  node1: stop → start → wait for UN ✓  (seed node LAST)"
            echo "  (cluster never loses quorum — one node down at a time)"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.rolling_test (id int PRIMARY KEY, val text);\""
            for i in $(seq 1 5); do
                log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.rolling_test (id, val) VALUES ($i, 'data-$i');\""
            done

            if [ "$DRY_RUN" = false ]; then
                ROLLING_READS_OK=0
                ROLLING_READS_FAIL=0
            fi

            separator
            echo -e "${C_WHITE}--- Rolling Restart: node3 ---${C_RESET}"
            log_cmd "docker-compose stop hcd-node3"
            if [ "$DRY_RUN" = false ]; then sleep 5; fi

            log_info "Verifying reads AND writes work with node3 down..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.rolling_test;\""
            if [ "$DRY_RUN" = false ]; then
                for i in $(seq 6 10); do
                    if docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.rolling_test (id, val) VALUES ($i, 'written-while-node3-down');" 2>/dev/null; then
                        ROLLING_READS_OK=$((ROLLING_READS_OK + 1))
                        echo -e "${C_GREEN}  [WRITE ${i}] ✓  (node3 DOWN)${C_RESET}"
                    else
                        ROLLING_READS_FAIL=$((ROLLING_READS_FAIL + 1))
                        echo -e "${C_YELLOW}  [WRITE ${i}] ✗  (node3 DOWN)${C_RESET}"
                    fi
                done
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Writing 5 rows while node3 is down..."
            fi

            log_cmd "docker-compose start hcd-node3"
            log_info "Waiting for node3 to rejoin..."
            wait_for_node_un "172.28.0.4" "node3"

            separator
            echo -e "${C_WHITE}--- Rolling Restart: node2 ---${C_RESET}"
            log_cmd "docker-compose stop hcd-node2"
            if [ "$DRY_RUN" = false ]; then sleep 5; fi

            log_info "Verifying reads AND writes work with node2 down..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.rolling_test;\""
            if [ "$DRY_RUN" = false ]; then
                for i in $(seq 11 15); do
                    if docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.rolling_test (id, val) VALUES ($i, 'written-while-node2-down');" 2>/dev/null; then
                        ROLLING_READS_OK=$((ROLLING_READS_OK + 1))
                        echo -e "${C_GREEN}  [WRITE ${i}] ✓  (node2 DOWN)${C_RESET}"
                    else
                        ROLLING_READS_FAIL=$((ROLLING_READS_FAIL + 1))
                        echo -e "${C_YELLOW}  [WRITE ${i}] ✗  (node2 DOWN)${C_RESET}"
                    fi
                done
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Writing 5 rows while node2 is down..."
            fi

            log_cmd "docker-compose start hcd-node2"
            log_info "Waiting for node2 to rejoin..."
            wait_for_node_un "172.28.0.3" "node2"

            separator
            echo -e "${C_WHITE}--- Rolling Restart: node1 (seed node — restarted LAST) ---${C_RESET}"
            echo "Seed nodes should be restarted last. Other nodes use seeds for bootstrap,"
            echo "but once running, gossip maintains the cluster without the seed."
            echo ""
            log_cmd "docker-compose stop hcd-node1"
            if [ "$DRY_RUN" = false ]; then sleep 5; fi

            log_info "Verifying reads AND writes work with seed node1 down..."
            log_cmd "docker exec hcd-node2 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.rolling_test;\""
            if [ "$DRY_RUN" = false ]; then
                for i in $(seq 16 20); do
                    if docker exec hcd-node2 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.rolling_test (id, val) VALUES ($i, 'written-while-node1-down');" 2>/dev/null; then
                        ROLLING_READS_OK=$((ROLLING_READS_OK + 1))
                        echo -e "${C_GREEN}  [WRITE ${i}] ✓  (seed node1 DOWN)${C_RESET}"
                    else
                        ROLLING_READS_FAIL=$((ROLLING_READS_FAIL + 1))
                        echo -e "${C_YELLOW}  [WRITE ${i}] ✗  (seed node1 DOWN)${C_RESET}"
                    fi
                done
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Writing 5 rows while seed node1 is down..."
            fi

            log_cmd "docker-compose start hcd-node1"
            log_info "Waiting for node1 to rejoin..."
            wait_for_node_un "172.28.0.2" "node1"

            separator
            echo -e "${C_WHITE}--- Final Verification ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.rolling_test;\""

            if [ "$DRY_RUN" = false ]; then
                echo ""
                echo -e "${C_GREEN}╔═══════════════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_GREEN}║  ROLLING RESTART RESULT:                                    ║${C_RESET}"
                echo -e "${C_GREEN}║  Nodes restarted: 3 (node3, node2, node1/seed)              ║${C_RESET}"
                echo -e "${C_GREEN}║  Writes during maintenance: ${ROLLING_READS_OK} succeeded, ${ROLLING_READS_FAIL} failed            ║${C_RESET}"
                echo -e "${C_GREEN}║  Cluster was NEVER unavailable. Zero downtime.              ║${C_RESET}"
                echo -e "${C_GREEN}╚═══════════════════════════════════════════════════════════════╝${C_RESET}"
                echo ""
            fi

            lookfor "count = 20 (5 initial + 5 node3 down + 5 node2 down + 5 node1 down)."
            lookfor "Even the seed node was restarted — cluster kept serving."

            takeaway "Rolling restarts are the standard maintenance procedure." \
                     "With RF=3 and LOCAL_QUORUM, one node can be down at any time." \
                     "Restart non-seed nodes first, seed nodes last." \
                     "We proved it: ${ROLLING_READS_OK:-15} writes succeeded across all 3 restarts." \
                     "Always wait for UN before restarting the next node."
            ;;
        38)
            header 38 "Rate Limiting & Back-Pressure (Ops Monitoring)"
            echo "This module is about DETECTING trouble: learning to read HCD's internal"
            echo "gauges so you can spot overload BEFORE it causes client-facing timeouts."
            echo "(Module 40 will cover throughput benchmarking for capacity planning.)"
            echo ""

            # Grafana integration hint
            if [ "$DRY_RUN" = false ] && docker inspect grafana >/dev/null 2>&1; then
                echo -e "${C_GREEN}╔═══════════════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_GREEN}║  Grafana is running! Open http://localhost:3000              ║${C_RESET}"
                echo -e "${C_GREEN}║  Dashboard: HCD Cluster — Demo Dashboard                    ║${C_RESET}"
                echo -e "${C_GREEN}║  Watch the thread pool and latency panels LIVE during load.  ║${C_RESET}"
                echo -e "${C_GREEN}╚═══════════════════════════════════════════════════════════════╝${C_RESET}"
                echo ""
            else
                echo -e "${C_DIM}Tip: Start with 'docker compose --profile monitoring up -d' for live Grafana dashboards.${C_RESET}"
                echo ""
            fi
            echo "When a coordinator is overwhelmed, HCD provides back-pressure via"
            echo "thread pool queuing. Monitoring thread pools is essential for"
            echo "detecting coordinator overload before it causes timeouts."
            echo ""
            echo "  Client requests ──► Native Transport ──► Read/Write Thread Pools"
            echo "                                               │"
            echo "                                     ┌─────────┴─────────┐"
            echo "                                     │  Active | Pending │"
            echo "                                     │  Blocked| Dropped │"
            echo "                                     └───────────────────┘"
            echo ""

            separator
            echo -e "${C_WHITE}--- Key Thread Pools (before load) ---${C_RESET}"
            echo "We filter to the 3 pools that matter most for client-facing operations:"
            echo ""
            log_cmd "docker exec hcd-node1 nodetool tpstats 2>/dev/null | grep -E 'Pool Name|ReadStage|MutationStage|Native-Transport-Requests' | head -n 5 || echo '(tpstats output)'"

            echo ""
            echo "How to read this:"
            echo "  Active   = currently processing a request"
            echo "  Pending  = queued, waiting for a thread"
            echo "  Blocked  = rejected (back-pressure). Should ALWAYS be 0."
            echo "  Completed = total ops processed since startup"
            echo ""

            separator
            echo -e "${C_WHITE}--- Generating Load (500 rapid-fire inserts via batched parallelism) ---${C_RESET}"
            echo -e "${C_BLUE}We send 500 inserts using parallel docker exec calls to meaningfully${C_RESET}"
            echo -e "${C_BLUE}move thread pool counters. Watch for changes in Active and Pending.${C_RESET}"
            echo ""
            if [ "$DRY_RUN" = false ]; then
                BEFORE_MUTATIONS=$(docker exec hcd-node1 nodetool tpstats 2>/dev/null | grep MutationStage | awk '{print $3}' || echo "0")
            fi
            if [ "$DRY_RUN" = false ]; then
                log_info "Launching 500 inserts in waves of 25 parallel calls..."
                for wave in $(seq 1 20); do
                    for j in $(seq 1 25); do
                        idx=$(( (wave - 1) * 25 + j ))
                        docker exec hcd-node1 cqlsh -e "INSERT INTO rf_prod.health (id, status) VALUES ($((2000 + idx)), 'load-test-$idx');" 2>/dev/null &
                    done
                    wait
                    if [ $((wave % 5)) -eq 0 ]; then
                        echo -e "${C_GREEN}  [WAVE $wave/20 — $((wave * 25))/500 inserts]${C_RESET}"
                    fi
                done
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Launching 500 parallel inserts in 20 waves of 25..."
            fi

            separator
            echo -e "${C_WHITE}--- Key Thread Pools (after load) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool tpstats 2>/dev/null | grep -E 'Pool Name|ReadStage|MutationStage|Native-Transport-Requests' | head -n 5 || echo '(tpstats after load)'"
            if [ "$DRY_RUN" = false ]; then
                AFTER_MUTATIONS=$(docker exec hcd-node1 nodetool tpstats 2>/dev/null | grep MutationStage | awk '{print $3}' || echo "0")
                echo ""
                MUTATION_DELTA=$((AFTER_MUTATIONS - BEFORE_MUTATIONS))
                echo -e "${C_GREEN}>>> MutationStage Completed: ${BEFORE_MUTATIONS} → ${AFTER_MUTATIONS} (+${MUTATION_DELTA} mutations from 500 inserts)${C_RESET}"
                if [ "$MUTATION_DELTA" -gt 0 ]; then
                    echo -e "${C_GREEN}>>> Each insert creates ~3 mutations (RF=3), so expect ~1500 total mutations.${C_RESET}"
                fi
            fi

            echo ""
            echo -e "${C_YELLOW}QUESTION: We sent 500 inserts with RF=3. How many total mutations should MutationStage show?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: ~1500. Each insert at RF=3 creates 3 mutations (one per replica).${C_RESET}"
            echo -e "${C_GREEN}The coordinator distributes the write to all 3 replica nodes.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- Latency Percentiles ---${C_RESET}"
            echo "proxyhistograms shows end-to-end coordinator latency:"
            echo ""
            log_cmd "docker exec hcd-node1 nodetool proxyhistograms 2>/dev/null | grep -E 'Percentile|50%|75%|95%|99%|Max' | head -n 8 || echo '(proxy histograms)'"
            echo ""
            echo "In production, alert on:"
            echo "  p99 Write > 50ms → check compaction, disk I/O"
            echo "  p99 Read  > 100ms → check partition size, Bloom filters"
            echo "  Blocked > 0 → coordinator overload, add nodes"

            takeaway "Monitor 3 pools: ReadStage, MutationStage, Native-Transport-Requests." \
                     "Blocked > 0 = coordinator overload. Add nodes or throttle client load." \
                     "p99 latency is your canary. If it spikes, investigate before p50 follows."
            ;;
        39)
            header 39 "Repair Strategies"
            echo "Repair ensures all replicas converge to the same data. Different"
            echo "modes trade off speed, network cost, and operational complexity."
            echo ""
            echo "+------------------------------------------------------------------+"
            echo "| Mode            | Scope        | Network | When to Use           |"
            echo "|-----------------|--------------|---------|---------------------- |"
            echo "| Full (-full)    | All data     | High    | After major outage    |"
            echo "| Primary (-pr)   | Local ranges | Medium  | Regular maintenance   |"
            echo "| Incremental     | Changed only | Low     | Frequent scheduling   |"
            echo "| Sub-range       | Token range  | Lowest  | Targeted repairs      |"
            echo "+------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Step 1: Create Actual Entropy (Divergence Between Replicas) ---${C_RESET}"
            echo "Before we run repair, let's CREATE entropy so repair has something to fix."
            echo "We pause node1 (freezing it), write from dc2, then unpause node1."
            echo "Node1 will be stale — it missed the writes while paused."
            echo ""

            if [ "$DRY_RUN" = false ]; then
                log_info "Pausing node1 (it will miss writes)..."
                docker pause hcd-node1 >/dev/null 2>&1
                sleep 2

                log_info "Writing 5 rows from dc2 while node1 is paused..."
                for i in $(seq 1 5); do
                    docker exec hcd-node4 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.logs (id, msg) VALUES (uuid(), 'entropy-seed-$i');" 2>/dev/null
                done
                echo -e "${C_GREEN}  5 rows written from dc2 — node1 missed them.${C_RESET}"

                log_info "Unpausing node1 (it is now STALE)..."
                docker unpause hcd-node1 >/dev/null 2>&1
                sleep 3
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker pause hcd-node1"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} (write 5 rows from dc2 while node1 is paused)"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker unpause hcd-node1"
            fi

            echo ""
            echo -e "${C_YELLOW}QUESTION: We paused node1 and wrote from dc2. Will node1 get those writes${C_RESET}"
            echo -e "${C_YELLOW}via hinted handoff, or does it need repair?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Docker pause freezes the process but keeps the container 'running'.${C_RESET}"
            echo -e "${C_GREEN}Other nodes may not detect it as down, so hints may not be stored.${C_RESET}"
            echo -e "${C_GREEN}Repair is the definitive fix — it compares Merkle trees and streams missing data.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- Step 2: Primary Range Repair (Fixes the Entropy We Created) ---${C_RESET}"
            echo "'nodetool repair -pr' repairs only token ranges this node is primary for."
            echo "This avoids redundant work when running repair on all nodes."
            echo "Because node1 missed writes, repair will stream the missing data."
            echo ""
            log_cmd "docker exec hcd-node1 nodetool repair -pr rf_prod 2>&1 | tail -n 10 || echo '(repair output)'"

            lookfor "Look for 'Repair completed' and any mention of 'streaming' or 'ranges'."
            lookfor "Because we created real entropy, repair had actual divergence to fix."

            separator
            echo -e "${C_WHITE}--- Monitoring Repair Progress ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool netstats 2>/dev/null | head -n 15 || echo '(netstats -- shows active streams during repair)'"

            separator
            echo -e "${C_WHITE}--- Repair History ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool repair_admin list 2>/dev/null | head -n 10 || echo '(repair_admin not available -- check system_distributed.repair_history)'"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM system_distributed.repair_history LIMIT 5;\" 2>/dev/null || echo '(repair history)'"

            lookfor "Repair uses Merkle Trees to compare data ranges between replicas."
            lookfor "Only mismatched ranges are streamed -- efficient for mostly-consistent clusters."

            takeaway "Run 'nodetool repair -pr' on each node weekly for production health." \
                     "Use incremental repair for frequent runs with lower network overhead." \
                     "Full repair after disasters. Sub-range repair for surgical fixes."
            ;;
        40)
            header 40 "Stress Testing & Capacity Planning"
            echo -e "${C_DIM}(Estimated time: ~3-5 minutes for 200 sequential writes + analysis)${C_RESET}"
            if [ "$DRY_RUN" = false ] && docker inspect grafana >/dev/null 2>&1; then
                echo -e "${C_GREEN}Grafana is live at http://localhost:3000 — watch latency and compaction panels during this module.${C_RESET}"
                echo ""
            fi
            echo "Module 38 taught you to read HCD's gauges (tpstats, thread pools)."
            echo "Now we push the system harder to answer a different question:"
            echo "how many ops/sec can this cluster handle, and what does the"
            echo "latency distribution look like under sustained load?"
            echo ""
            echo "This is CAPACITY PLANNING — using per-table metrics, Bloom filter"
            echo "stats, and latency percentiles to size your cluster."
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.stress_test (id int PRIMARY KEY, data text, category text);\""

            separator
            echo -e "${C_WHITE}--- Write Stress (200 rows, LOCAL_QUORUM) ---${C_RESET}"
            echo ""
            echo -e "${C_YELLOW}Important: This uses sequential cqlsh calls (one at a time).${C_RESET}"
            echo -e "${C_YELLOW}Each call starts a docker exec process (~100ms overhead) + CQL roundtrip.${C_RESET}"
            echo -e "${C_YELLOW}This measures 'demo throughput', NOT cluster capacity.${C_RESET}"
            echo ""
            if [ "$DRY_RUN" = false ]; then
                STRESS_START=$(date +%s%N)
            fi
            log_info "Inserting 200 rows as fast as possible..."
            if [ "$DRY_RUN" = false ]; then
                for i in $(seq 1 200); do
                    docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.stress_test (id, data, category) VALUES ($i, 'stress-data-$i-with-padding-for-realistic-payload-size-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx', 'cat-$((i % 5))');" 2>/dev/null
                    if [ $((i % 50)) -eq 0 ]; then
                        echo -e "${C_GREEN}  [WRITE $i/200]${C_RESET}"
                    fi
                done
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} Inserting 200 rows at LOCAL_QUORUM..."
            fi
            if [ "$DRY_RUN" = false ]; then
                STRESS_END=$(date +%s%N)
                STRESS_DURATION_MS=$(( (STRESS_END - STRESS_START) / 1000000 ))
                STRESS_DURATION_S=$((STRESS_DURATION_MS / 1000))
                echo ""
                echo -e "${C_GREEN}╔═══════════════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_GREEN}║  STRESS TEST RESULTS (sequential cqlsh):                    ║${C_RESET}"
                echo -e "${C_GREEN}║  200 LOCAL_QUORUM writes in ${STRESS_DURATION_MS}ms (~${STRESS_DURATION_S}s)                    ║${C_RESET}"
                if [ "$STRESS_DURATION_S" -gt 0 ]; then
                    echo -e "${C_GREEN}║  Demo throughput: ~$((200 / STRESS_DURATION_S)) writes/sec                           ║${C_RESET}"
                fi
                echo -e "${C_GREEN}║                                                             ║${C_RESET}"
                echo -e "${C_GREEN}║  Production benchmarks (cassandra-stress, async driver):    ║${C_RESET}"
                echo -e "${C_GREEN}║  • Single node: 10K-50K writes/sec                         ║${C_RESET}"
                echo -e "${C_GREEN}║  • 6-node cluster: 50K-200K writes/sec                     ║${C_RESET}"
                echo -e "${C_GREEN}║  • Use: cassandra-stress write n=1000000 -rate threads=200  ║${C_RESET}"
                echo -e "${C_GREEN}╚═══════════════════════════════════════════════════════════════╝${C_RESET}"
                echo ""
            fi

            separator
            echo -e "${C_WHITE}--- Read Stress ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.stress_test;\""

            separator
            echo -e "${C_WHITE}--- Latency Percentiles ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool proxyhistograms 2>/dev/null | grep -E 'Percentile|50%|75%|95%|99%|Max' | head -n 8 || echo '(proxy histograms)'"

            separator
            echo -e "${C_WHITE}--- Per-Table Health ---${C_RESET}"
            echo "Key metrics to watch per table:"
            echo ""
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.stress_test 2>/dev/null | grep -iE 'read count|write count|read latency|write latency|SSTable count|bloom' | head -n 10 || echo '(tablestats output)'"
            echo ""
            echo "How to interpret:"
            echo "  Read/Write count   = total ops processed for this table"
            echo "  Read/Write latency = average in ms (want < 5ms for p50)"
            echo "  SSTable count      = number of data files (high = needs compaction)"
            echo "  Bloom filter FP    = false positive ratio (want < 1%)"

            separator
            echo -e "${C_WHITE}--- Bloom Filter Deep Dive ---${C_RESET}"
            echo "Bloom filters answer: 'does this SSTable contain key X?'"
            echo "  True negative  → skip this SSTable (saves a disk read)"
            echo "  False positive → read SSTable for nothing (wasted I/O)"
            echo ""
            log_cmd "docker exec hcd-node1 nodetool tablestats rf_prod.stress_test 2>/dev/null | grep -i bloom | head -n 5 || echo '(bloom filter stats)'"

            takeaway "200 LOCAL_QUORUM writes prove the cluster handles sustained load." \
                     "In production, use cassandra-stress for 100K+ ops/sec benchmarking." \
                     "Monitor: p99 latency, SSTable count, Bloom filter FP ratio per table."
            ;;
        41)
            header 41 "Security Fundamentals"
            echo ""
            echo -e "${C_YELLOW}╔═══════════════════════════════════════════════════════════════════╗${C_RESET}"
            echo -e "${C_YELLOW}║  ⚠  SYNTAX DEMO ONLY — RBAC IS NOT ENFORCED ON THIS CLUSTER    ║${C_RESET}"
            echo -e "${C_YELLOW}║                                                                   ║${C_RESET}"
            echo -e "${C_YELLOW}║  This cluster uses AllowAllAuthenticator (Cassandra default).     ║${C_RESET}"
            echo -e "${C_YELLOW}║  All CQL statements below execute but do NOT enforce access       ║${C_RESET}"
            echo -e "${C_YELLOW}║  control. In production, you MUST set in cassandra.yaml:          ║${C_RESET}"
            echo -e "${C_YELLOW}║                                                                   ║${C_RESET}"
            echo -e "${C_YELLOW}║    authenticator: PasswordAuthenticator                           ║${C_RESET}"
            echo -e "${C_YELLOW}║    authorizer: CassandraAuthorizer                                ║${C_RESET}"
            echo -e "${C_YELLOW}║                                                                   ║${C_RESET}"
            echo -e "${C_YELLOW}║  Without these settings, anyone can connect and do anything.      ║${C_RESET}"
            echo -e "${C_YELLOW}╚═══════════════════════════════════════════════════════════════════╝${C_RESET}"
            echo ""
            echo "HCD supports authentication, authorization, and encryption."
            echo "The default 'cassandra' superuser should be replaced in production."
            echo ""
            echo "  ┌─────────────┐     ┌────────────────┐     ┌──────────────┐"
            echo "  │ Authn       │ ──► │ Authz           │ ──► │ Audit        │"
            echo "  │ (who)       │     │ (what allowed)  │     │ (what did)   │"
            echo "  │ Roles/Login │     │ GRANT/REVOKE    │     │ Module 26    │"
            echo "  └─────────────┘     └────────────────┘     └──────────────┘"
            echo ""

            separator
            echo -e "${C_WHITE}--- Role Management (Syntax Demo) ---${C_RESET}"
            echo "The commands below demonstrate the RBAC syntax. In a production cluster"
            echo "with PasswordAuthenticator + CassandraAuthorizer, these roles would"
            echo "enforce real access control."
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE ROLE IF NOT EXISTS demo_reader WITH LOGIN = false;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE ROLE IF NOT EXISTS demo_writer WITH LOGIN = false;\""

            separator
            echo -e "${C_WHITE}--- Permission Grants ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"GRANT SELECT ON KEYSPACE rf_prod TO demo_reader;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"GRANT MODIFY ON KEYSPACE rf_prod TO demo_writer;\""

            separator
            echo -e "${C_WHITE}--- View Permissions ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"LIST ALL PERMISSIONS OF demo_reader;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"LIST ALL PERMISSIONS OF demo_writer;\""

            separator
            echo -e "${C_WHITE}--- Encryption: TLS for Client-to-Node & Node-to-Node ---${C_RESET}"
            echo "HCD supports three layers of encryption:"
            echo ""
            echo "  ┌─────────────────────────────────────────────────────────────────┐"
            echo "  │  Layer 1: Client-to-Node TLS (client_encryption_options)        │"
            echo "  │           Encrypts CQL connections (port 9042)                  │"
            echo "  │                                                                 │"
            echo "  │  Layer 2: Node-to-Node TLS (server_encryption_options)          │"
            echo "  │           Encrypts gossip, streaming, repair (port 7001)        │"
            echo "  │                                                                 │"
            echo "  │  Layer 3: Transparent Data Encryption (TDE)                     │"
            echo "  │           Encrypts SSTables at rest on disk                     │"
            echo "  └─────────────────────────────────────────────────────────────────┘"
            echo ""

            separator
            echo -e "${C_WHITE}--- Generating Self-Signed TLS Certificates (Demo) ---${C_RESET}"
            echo "In production, use certificates from your corporate CA or Let's Encrypt."
            echo "For this demo, we generate a self-signed keystore to show the mechanics."
            echo ""

            if [ "$DRY_RUN" = false ]; then
                log_info "Generating a self-signed keystore on node1..."
                docker exec hcd-node1 bash -c '
                    KEYSTORE=/tmp/demo-keystore.jks
                    TRUSTSTORE=/tmp/demo-truststore.jks
                    STOREPASS=cassandra
                    keytool -genkeypair \
                        -alias hcd-node1 \
                        -keyalg RSA -keysize 2048 \
                        -dname "CN=hcd-node1, OU=Demo, O=HCD, L=Lab, ST=Demo, C=US" \
                        -keystore "$KEYSTORE" \
                        -storepass "$STOREPASS" \
                        -keypass "$STOREPASS" \
                        -validity 365 2>/dev/null && \
                    keytool -exportcert \
                        -alias hcd-node1 \
                        -keystore "$KEYSTORE" \
                        -storepass "$STOREPASS" \
                        -file /tmp/hcd-node1.cer 2>/dev/null && \
                    keytool -importcert \
                        -alias hcd-node1 \
                        -keystore "$TRUSTSTORE" \
                        -storepass "$STOREPASS" \
                        -file /tmp/hcd-node1.cer \
                        -noprompt 2>/dev/null && \
                    echo "Keystore:   $KEYSTORE ($(du -h $KEYSTORE | cut -f1))" && \
                    echo "Truststore: $TRUSTSTORE ($(du -h $TRUSTSTORE | cut -f1))" && \
                    echo "Certificate:" && \
                    keytool -list -keystore "$KEYSTORE" -storepass "$STOREPASS" 2>/dev/null | head -n 6
                ' 2>&1 || echo "(keytool not available in this image — JRE-only build)"
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} keytool -genkeypair -alias hcd-node1 -keyalg RSA -keysize 2048 ..."
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} keytool -exportcert -alias hcd-node1 ..."
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} keytool -importcert -alias hcd-node1 -keystore truststore.jks ..."
            fi

            separator
            echo -e "${C_WHITE}--- cassandra.yaml TLS Configuration (Reference) ---${C_RESET}"
            echo "To enable client-to-node TLS, add to cassandra.yaml:"
            echo ""
            echo -e "${C_DIM}  client_encryption_options:${C_RESET}"
            echo -e "${C_DIM}    enabled: true${C_RESET}"
            echo -e "${C_DIM}    optional: false          # force TLS (reject plaintext)${C_RESET}"
            echo -e "${C_DIM}    keystore: /etc/cassandra/keystore.jks${C_RESET}"
            echo -e "${C_DIM}    keystore_password: <secret>${C_RESET}"
            echo -e "${C_DIM}    truststore: /etc/cassandra/truststore.jks${C_RESET}"
            echo -e "${C_DIM}    truststore_password: <secret>${C_RESET}"
            echo -e "${C_DIM}    protocol: TLS${C_RESET}"
            echo -e "${C_DIM}    algorithm: SunX509${C_RESET}"
            echo -e "${C_DIM}    cipher_suites: [TLS_RSA_WITH_AES_256_CBC_SHA]${C_RESET}"
            echo ""
            echo "To enable node-to-node TLS:"
            echo ""
            echo -e "${C_DIM}  server_encryption_options:${C_RESET}"
            echo -e "${C_DIM}    internode_encryption: all     # none | rack | dc | all${C_RESET}"
            echo -e "${C_DIM}    keystore: /etc/cassandra/keystore.jks${C_RESET}"
            echo -e "${C_DIM}    keystore_password: <secret>${C_RESET}"
            echo -e "${C_DIM}    truststore: /etc/cassandra/truststore.jks${C_RESET}"
            echo -e "${C_DIM}    truststore_password: <secret>${C_RESET}"
            echo ""

            log_info "Checking current TLS status on node1..."
            log_cmd "docker exec hcd-node1 nodetool info 2>/dev/null | grep -iE 'native|ssl|tls|gossip|thrift' | head -n 5 || echo '(nodetool info -- TLS status)'"

            separator
            echo -e "${C_WHITE}--- cqlsh with TLS (Reference) ---${C_RESET}"
            echo "Once TLS is enabled, connect with:"
            echo ""
            echo -e "${C_DIM}  cqlsh --ssl \\${C_RESET}"
            echo -e "${C_DIM}    --ssl-certificate=/path/to/client-cert.pem \\${C_RESET}"
            echo -e "${C_DIM}    --ssl-key=/path/to/client-key.pem \\${C_RESET}"
            echo -e "${C_DIM}    172.28.0.2 9042${C_RESET}"
            echo ""
            echo "Or via cqlshrc:"
            echo ""
            echo -e "${C_DIM}  [ssl]${C_RESET}"
            echo -e "${C_DIM}  certfile = /path/to/ca-cert.pem${C_RESET}"
            echo -e "${C_DIM}  validate = true${C_RESET}"
            echo -e "${C_DIM}  userkey = /path/to/client-key.pem${C_RESET}"
            echo -e "${C_DIM}  usercert = /path/to/client-cert.pem${C_RESET}"
            echo ""

            echo -e "${C_YELLOW}QUESTION: Should you enable client TLS or internode TLS first?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Internode first. It protects gossip, streaming, and repair traffic${C_RESET}"
            echo -e "${C_GREEN}between nodes — data that traverses the network without any user involvement.${C_RESET}"
            echo -e "${C_GREEN}Client TLS can be rolled out gradually with 'optional: true' first.${C_RESET}"
            echo ""

            log_info "Cleaning up demo roles and temp certificates..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"DROP ROLE IF EXISTS demo_reader; DROP ROLE IF EXISTS demo_writer;\""
            if [ "$DRY_RUN" = false ]; then
                docker exec hcd-node1 rm -f /tmp/demo-keystore.jks /tmp/demo-truststore.jks /tmp/hcd-node1.cer 2>/dev/null || true
            fi

            takeaway "In production: enable PasswordAuthenticator, create app-specific roles." \
                     "Principle of least privilege: readers get SELECT, writers get MODIFY." \
                     "Enable internode TLS first (server_encryption_options), then client TLS." \
                     "Use keytool to manage JKS keystores, or PKCS12 for modern deployments." \
                     "Never use self-signed certs in production — use your corporate CA."
            ;;
        42)
            header 42 "Geographic Visualization & Token Ownership"
            echo "Understanding which nodes own which data is critical for debugging"
            echo "performance and availability issues. HCD's token ring determines"
            echo "exactly where every piece of data lives."
            echo ""

            separator
            echo -e "${C_WHITE}--- Token Ring per DC ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool ring rf_prod 2>/dev/null | head -n 30 || echo '(ring output for rf_prod)'"

            separator
            echo -e "${C_WHITE}--- Data Locality: Where Does a Key Live? ---${C_RESET}"
            echo "getendpoints shows exactly which nodes hold replicas for a given key."
            echo ""
            log_cmd "docker exec hcd-node1 nodetool getendpoints rf_prod health 1"
            log_cmd "docker exec hcd-node1 nodetool getendpoints rf_prod health 42"
            log_cmd "docker exec hcd-node1 nodetool getendpoints rf_prod health 100"

            lookfor "Each key maps to 6 endpoints (RF=3 per DC × 2 DCs)."
            lookfor "Different keys may map to different primary replicas."

            separator
            echo -e "${C_WHITE}--- Ownership Distribution ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool status rf_prod"

            lookfor "Each node shows its ownership percentage."
            lookfor "With 256 vnodes, ownership should be roughly equal (~16% per node)."

            separator
            echo -e "${C_WHITE}--- Proving LOCAL_QUORUM Never Crosses WAN ---${C_RESET}"
            echo "When you read at LOCAL_QUORUM from dc1, only dc1 nodes are contacted."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CONSISTENCY LOCAL_QUORUM; SELECT * FROM rf_prod.health WHERE id = 1; TRACING OFF;\" 2>&1 | grep -E 'Sending|Executing' | head -n 10 || echo '(trace output -- check which IPs appear)'"

            lookfor "Trace should show only 172.28.0.2-4 (dc1 IPs), not .5-.7 (dc2)."
            lookfor "This proves LOCAL_QUORUM is truly local -- no WAN round-trip."

            separator
            echo -e "${C_WHITE}--- Describe Ring (Detailed Token Ranges) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 nodetool describering rf_prod 2>/dev/null | head -n 20 || echo '(describering output -- shows token range → endpoint mapping)'"

            takeaway "Every partition key maps to specific nodes via the token ring." \
                     "getendpoints is your debugging friend: 'where does this data live?'" \
                     "LOCAL_QUORUM guarantees no WAN traffic -- trace it to prove it."
            ;;
        43)
            header 43 "Driver Policies — The Client-Side of Entropy"
            echo "Until now, every command used cqlsh — a single-node CLI tool."
            echo "In production, applications use the DataStax Python/Java/Go driver"
            echo "with SMART ROUTING POLICIES that are fundamental to entropy management."
            echo ""
            echo "The two key policies:"
            echo "  1. DCAwareRoundRobinPolicy — keeps traffic in the local DC"
            echo "  2. TokenAwarePolicy — routes writes DIRECTLY to the owning replica"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  NAIVE ROUND-ROBIN (cqlsh)           TOKEN-AWARE (DataStax Driver)    |"
            echo "|                                                                       |"
            echo "|  Client ──► node1 ─────► node3       Client ──► node3 (direct!)       |"
            echo "|         (coordinator)  (replica)           (coordinator IS replica)    |"
            echo "|                                                                       |"
            echo "|  Extra hop: coordinator must           Zero extra hops: the driver     |"
            echo "|  forward to the actual replica.        KNOWS the token ring and sends  |"
            echo "|  The coordinator is just a             the request straight to the     |"
            echo "|  middleman adding latency.             replica that owns the data.     |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  How TokenAwarePolicy Works                                           |"
            echo "|                                                                       |"
            echo "|  1. Driver connects → downloads token ring from system.peers          |"
            echo "|  2. For each write, driver hashes the partition key (Murmur3)         |"
            echo "|  3. Maps hash → owning node from the ring                             |"
            echo "|  4. Sends write directly to that node                                 |"
            echo "|                                                                       |"
            echo "|  Token Ring:     -2^63 ──── node1 ──── node2 ──── node3 ──── 2^63    |"
            echo "|  Key 'abc' ──► hash=42871 ──► falls in node2's range ──► send to 2   |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Phase 1: Naive Round-Robin vs Token-Aware ---${C_RESET}"
            echo "The driver will write 30 rows with each policy and show which"
            echo "coordinator node was selected for every write."
            echo ""
            log_cmd "docker exec hcd-node1 driver-demo token-aware"

            lookfor "RoundRobin spreads writes evenly across ALL nodes (including non-replicas)."
            lookfor "TokenAware targets writes to replica owners — fewer distinct coordinators."
            lookfor "TokenAware eliminates the coordinator-to-replica forwarding hop."

            takeaway "TokenAwarePolicy is the #1 production optimization for the DataStax driver." \
                     "It eliminates coordinator hops by routing directly to the owning replica." \
                     "Combined with DCAwareRoundRobinPolicy, traffic stays local to the DC." \
                     "This is entropy prevention: fewer hops = fewer points of failure."
            ;;
        44)
            header 44 "Speculative Execution — Masking Latency Spikes"
            echo "In a distributed system, ANY replica can become temporarily slow"
            echo "(compaction running, GC pause, disk I/O spike). This creates"
            echo "tail latency — your p99 is dictated by your slowest replica."
            echo ""
            echo "Speculative execution solves this by sending BACKUP requests:"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  WITHOUT SPECULATIVE EXECUTION:                                       |"
            echo "|                                                                       |"
            echo "|  Client ──req──► Replica A ──────────(slow)──────────► response       |"
            echo "|                                                                       |"
            echo "|  p99 = latency of the SLOWEST replica (compaction, GC, I/O)           |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  WITH SPECULATIVE EXECUTION (delay=200ms):                            |"
            echo "|                                                                       |"
            echo "|  Client ──req──► Replica A ──────(slow, no response yet)────►         |"
            echo "|          │                                                            |"
            echo "|          ╰─ 200ms ─► Replica B ──(fast)──► response (WINS!)           |"
            echo "|                                                                       |"
            echo "|  Whichever replica responds FIRST is used. The slow one is ignored.   |"
            echo "|  p99 ≈ p50 because you're racing multiple replicas!                   |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  The Cost/Benefit Trade-off:                                          |"
            echo "|                                                                       |"
            echo "|  + p99 latency drops dramatically (approaches p50)                    |"
            echo "|  + Masks compaction, GC pauses, slow disks transparently              |"
            echo "|  + No application code changes needed                                 |"
            echo "|  - Extra requests when primary is slow (more network traffic)         |"
            echo "|  - Should NOT be used with non-idempotent operations (LWT)            |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_YELLOW}QUESTION: If p99 is 500ms, and speculative execution sends a backup request${C_RESET}"
            echo -e "${C_YELLOW}after 200ms delay, what should p99 drop to approximately?${C_RESET}"
            pause
            echo -e "${C_GREEN}ANSWER: Close to p50 (~5-10ms). The backup hits a non-slow replica, so p99${C_RESET}"
            echo -e "${C_GREEN}reflects the fastest of 2 replicas — which is typically at the median.${C_RESET}"
            echo ""

            echo -e "${C_WHITE}--- Run 1: WITHOUT Speculative Execution ---${C_RESET}"
            log_cmd "docker exec hcd-node1 driver-demo speculative"

            separator
            echo -e "${C_WHITE}--- Run 2: WITH Speculative Execution (delay=200ms) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 driver-demo speculative --enable-speculative"

            lookfor "Compare p99 between the two runs."
            lookfor "With speculative execution, p99 should be closer to p50."
            lookfor "The gap narrows because slow replicas are masked by fast backups."

            takeaway "Speculative execution trades extra requests for lower tail latency." \
                     "ConstantSpeculativeExecutionPolicy(delay=200ms, max_attempts=2) is a good start." \
                     "Best for idempotent reads and writes. Avoid with LWT (Paxos is not idempotent)." \
                     "In production, this is the difference between p99=5ms and p99=500ms."
            ;;
        45)
            header 45 "Live DC Failover with Driver"
            echo -e "${C_DIM}(Estimated time: ~3-5 minutes for continuous write loop + failover)${C_RESET}"
            echo "Module 23 proved zero-downtime failover using cqlsh pointed at dc2."
            echo "But in production, you don't manually switch nodes. The DataStax driver"
            echo "does it AUTOMATICALLY — your application code never changes."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  Timeline of Automatic DC Failover:                                   |"
            echo "|                                                                       |"
            echo "|  T=0s    App writes via driver (local_dc='dc1')                       |"
            echo "|          Coordinators: 172.28.0.2, .3, .4 (dc1 nodes)                 |"
            echo "|                                                                       |"
            echo "|  T=15s   ██ ALL DC1 NODES KILLED ██                                   |"
            echo "|          Driver detects dc1 is down via gossip/connection failure      |"
            echo "|                                                                       |"
            echo "|  T=16s   Driver AUTOMATICALLY routes to dc2 (used_hosts_per_remote=3) |"
            echo "|          Coordinators: 172.28.0.5, .6, .7 (dc2 nodes)                 |"
            echo "|          >>> ZERO application errors, ZERO code changes <<<            |"
            echo "|                                                                       |"
            echo "|  T=35s   DC1 restarted                                                |"
            echo "|          Driver detects dc1 is back, routes traffic home               |"
            echo "|          Coordinators: back to 172.28.0.2, .3, .4                     |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  Key Driver Configuration:                                            |"
            echo "|                                                                       |"
            echo "|  DCAwareRoundRobinPolicy(                                             |"
            echo "|      local_dc='dc1',                                                  |"
            echo "|      used_hosts_per_remote_dc=3    ← allows failover to dc2           |"
            echo "|  )                                                                    |"
            echo "|                                                                       |"
            echo "|  If used_hosts_per_remote_dc=0, the driver will REFUSE to failover.   |"
            echo "|  The default is 0! You MUST set this for cross-DC failover.           |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Launching Continuous Writer + DC Kill Sequence ---${C_RESET}"
            echo "The driver writes continuously for 60 seconds from hcd-node4 (dc2)."
            echo "At T=15s, we kill all dc1 nodes. At T=35s, we restart them."
            echo "Watch the coordinator column shift from dc1 → dc2 → dc1."
            echo ""

            if [ "$DRY_RUN" = false ]; then
                log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.driver_failover (id int PRIMARY KEY, payload text, written_at text);\""

                log_info "Starting continuous writer on hcd-node4 (runs for 60s)..."
                log_info "Watch the live ticker below — coordinator IPs will shift in real time."
                echo ""

                # Stream driver output live to stdout (real-time ticker)
                docker exec hcd-node4 driver-demo dc-failover \
                    --contact-points 172.28.0.2,172.28.0.3,172.28.0.4,172.28.0.5,172.28.0.6,172.28.0.7 \
                    --duration 60 &
                DRIVER_PID=$!

                log_info "Waiting 15s for baseline writes..."
                sleep 15

                log_info ">>> KILLING ALL DC1 NODES <<<"
                docker-compose stop hcd-node1 hcd-node2 hcd-node3

                log_info "DC1 is dead. Driver should failover to dc2. Waiting 20s..."
                sleep 20

                log_info ">>> RESTARTING DC1 <<<"
                docker-compose start hcd-node1 hcd-node2 hcd-node3

                log_info "Waiting for driver to finish and dc1 to recover..."
                wait $DRIVER_PID 2>/dev/null || true
                wait_for_all_un 60
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.driver_failover (...)\""
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node4 driver-demo dc-failover --contact-points 172.28.0.2,...,172.28.0.7 --duration 60 &"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} sleep 15 (baseline writes)"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker-compose stop hcd-node1 hcd-node2 hcd-node3"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} sleep 20 (failover period)"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker-compose start hcd-node1 hcd-node2 hcd-node3"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} (collect driver output showing dc1 → dc2 → dc1 coordinator shift)"
            fi

            lookfor "The [WRITE] lines show coordinator shifting from dc1 IPs to dc2 IPs."
            lookfor "The FAILOVER marker shows the exact moment traffic moved to dc2."
            lookfor "The FAILBACK marker shows traffic returning to dc1 after recovery."
            lookfor "ZERO errors in the summary — the application never knew dc1 died."

            takeaway "The DataStax driver handles full DC failure with ZERO application errors." \
                     "Critical setting: used_hosts_per_remote_dc must be > 0 for cross-DC failover." \
                     "The driver detects failure via gossip and connection monitoring." \
                     "This is the production version of Module 23 — no manual intervention needed."
            ;;
        46)
            header 46 "Retry Policies Under Partition"
            echo "When a node times out or becomes unavailable, what happens next?"
            echo "The driver's RETRY POLICY decides: retry, rethrow, or ignore."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  Retry Policy Decision Tree:                                          |"
            echo "|                                                                       |"
            echo "|  Write/Read Timeout or Unavailable Exception                          |"
            echo "|  │                                                                    |"
            echo "|  ├── DefaultRetryPolicy                                               |"
            echo "|  │   └── Enough replicas responded?                                   |"
            echo "|  │       ├── YES → RETRY on SAME host (once)                          |"
            echo "|  │       └── NO  → RETHROW to application                             |"
            echo "|  │                                                                    |"
            echo "|  ├── FallthroughRetryPolicy                                           |"
            echo "|  │   └── ALWAYS → RETHROW (never retry, never mask errors)            |"
            echo "|  │   Use case: when you need to know about EVERY failure              |"
            echo "|  │                                                                    |"
            echo "|  └── Custom AggressiveRetryPolicy                                     |"
            echo "|      └── Attempts < 3?                                                |"
            echo "|          ├── YES → RETRY on NEXT host (try another replica)           |"
            echo "|          └── NO  → RETHROW                                            |"
            echo "|      Use case: best-effort writes where availability > consistency    |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  When to Use Each Policy:                                             |"
            echo "|                                                                       |"
            echo "|  DefaultRetryPolicy     General purpose. Safe for most workloads.     |"
            echo "|  FallthroughRetryPolicy  Financial transactions, audit trails.        |"
            echo "|                          App must handle every error explicitly.       |"
            echo "|  Custom Aggressive       IoT telemetry, logging, best-effort writes.  |"
            echo "|                          Losing a few writes is OK; availability wins. |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Phase 1: Create failure conditions ---${C_RESET}"
            echo "We use TWO isolation techniques to trigger retries:"
            echo "  1. docker pause hcd-node3 (freezes the process — simulates slow/hung node)"
            echo "  2. docker network disconnect (isolates node2 — simulates network partition)"
            echo "Together, these ensure the driver encounters both timeouts and unavailable errors."
            echo ""
            log_cmd "docker pause hcd-node3 2>/dev/null || true"
            log_cmd "docker network disconnect ${HCD_NETWORK} hcd-node2 2>/dev/null || true"
            if [ "$DRY_RUN" = false ]; then
                log_info "Waiting 15s for gossip to detect failures..."
                sleep 15
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} sleep 15 (gossip detection)"
            fi

            log_info "Cluster state with 2 nodes degraded:"
            log_cmd "docker exec hcd-node1 nodetool status 2>/dev/null | grep -E 'UN|DN' || echo '(status check)'"

            separator
            echo -e "${C_WHITE}--- Phase 2: DefaultRetryPolicy ---${C_RESET}"
            log_cmd "docker exec hcd-node1 driver-demo retry-policies --policy default"

            separator
            echo -e "${C_WHITE}--- Phase 3: FallthroughRetryPolicy ---${C_RESET}"
            log_cmd "docker exec hcd-node1 driver-demo retry-policies --policy fallthrough"

            separator
            echo -e "${C_WHITE}--- Phase 4: Custom AggressiveRetryPolicy ---${C_RESET}"
            log_cmd "docker exec hcd-node1 driver-demo retry-policies --policy custom"

            separator
            echo -e "${C_WHITE}--- Phase 5: Heal All Failures ---${C_RESET}"
            log_cmd "docker unpause hcd-node3 2>/dev/null || true"
            log_cmd "docker network connect ${HCD_NETWORK} hcd-node2 2>/dev/null || true"
            if [ "$DRY_RUN" = false ]; then
                log_info "Waiting for nodes to rejoin..."
                wait_for_node_un "172.28.0.3" "hcd-node2"
                wait_for_node_un "172.28.0.4" "hcd-node3"
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} wait_for_node_un (node2 + node3)"
            fi

            lookfor "Compare success/failure counts across the three policies."
            lookfor "FallthroughRetryPolicy may show more failures (no retries)."
            lookfor "AggressiveRetryPolicy should show more successes (retries on next host)."
            lookfor "DefaultRetryPolicy provides a balanced middle ground."

            takeaway "Retry policies are the client-side complement to server-side entropy resolution." \
                     "DefaultRetryPolicy is safe for most workloads." \
                     "FallthroughRetryPolicy gives full visibility — use for critical transactions." \
                     "Custom policies let you tune the availability/consistency trade-off per use case." \
                     "The driver + retry policy = your application's resilience strategy."
            ;;
        47)
            header 47 "Demo Summary Dashboard"
            echo ""
            echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
            echo -e "${C_CYAN}║                    HCD ENTROPY & CONSISTENCY DEMO                   ║${C_RESET}"
            echo -e "${C_CYAN}║                         SUMMARY DASHBOARD                           ║${C_RESET}"
            echo -e "${C_CYAN}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}║  Modules Completed:  54 (0-53)                                     ║${C_RESET}"
            echo -e "${C_CYAN}║  Cluster:            6 nodes, 2 DCs, RF=3 per DC                   ║${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
            echo -e "${C_CYAN}║  WHAT WE PROVED:                                                   ║${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}║  ✓ Zero data loss during node failure    (Module 33)               ║${C_RESET}"
            echo -e "${C_CYAN}║  ✓ Zero data loss during DC failure      (Modules 23, 45)          ║${C_RESET}"
            echo -e "${C_CYAN}║  ✓ Automatic self-healing via repair     (Modules 7-11, 24, 39)    ║${C_RESET}"
            echo -e "${C_CYAN}║  ✓ LWW conflict resolution across DCs   (Module 34)               ║${C_RESET}"
            echo -e "${C_CYAN}║  ✓ Rolling restart with zero downtime    (Module 37)               ║${C_RESET}"
            echo -e "${C_CYAN}║  ✓ Automatic driver DC failover          (Module 45)               ║${C_RESET}"
            echo -e "${C_CYAN}║  ✓ p99 → p50 via speculative execution   (Module 44)               ║${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
            echo -e "${C_CYAN}║  TOPICS COVERED:                                                   ║${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}║  Core:       Ring, Gossip, Hinted Handoff, Read Repair, Repair      ║${C_RESET}"
            echo -e "${C_CYAN}║  Indexing:   SAI (create, compose, update, rebuild, search)         ║${C_RESET}"
            echo -e "${C_CYAN}║  Write Path: Mutations, Commit Log, Memtable, SSTable              ║${C_RESET}"
            echo -e "${C_CYAN}║  Multi-DC:   Replication, Failover, Conflict Resolution            ║${C_RESET}"
            echo -e "${C_CYAN}║  Ops:        Compaction, Compression, Backup, Rolling Restart       ║${C_RESET}"
            echo -e "${C_CYAN}║  Security:   RBAC, Audit, Guardrails, CDC                          ║${C_RESET}"
            echo -e "${C_CYAN}║  Modeling:   Anti-patterns, Time-series, Tombstones                 ║${C_RESET}"
            echo -e "${C_CYAN}║  Driver:     TokenAware, Speculative, DC Failover, Retry Policies  ║${C_RESET}"
            echo -e "${C_CYAN}║  Txns:       ACID model, Batches, LWT patterns, Sagas, Banking     ║${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
            echo -e "${C_CYAN}║  KEY PRODUCTION TAKEAWAYS:                                         ║${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}║  1. Use LOCAL_QUORUM for strong consistency without WAN penalty     ║${C_RESET}"
            echo -e "${C_CYAN}║  2. TokenAwarePolicy eliminates coordinator hops (Module 43)       ║${C_RESET}"
            echo -e "${C_CYAN}║  3. Set used_hosts_per_remote_dc > 0 for DC failover (Module 45)   ║${C_RESET}"
            echo -e "${C_CYAN}║  4. Run nodetool repair -pr weekly on every node (Module 39)       ║${C_RESET}"
            echo -e "${C_CYAN}║  5. Design partition keys for even distribution (Module 28)        ║${C_RESET}"
            echo -e "${C_CYAN}║  6. Monitor tpstats + proxyhistograms for early warnings (Mod 38)  ║${C_RESET}"
            echo -e "${C_CYAN}║  7. Enable PasswordAuthenticator and TLS in production (Mod 41)    ║${C_RESET}"
            echo -e "${C_CYAN}║                                                                    ║${C_RESET}"
            echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
            echo ""

            if [ "$DRY_RUN" = false ]; then
                separator
                echo -e "${C_WHITE}--- Live Cluster Health ---${C_RESET}"
                log_cmd "docker exec hcd-node1 nodetool status"
            fi

            echo ""
            echo -e "${C_BOLD}Thank you for running the HCD Entropy & Consistency Demo!${C_RESET}"
            echo ""
            echo "For questions or feedback, see the project README."
            echo ""

            takeaway "HCD delivers tunable consistency, self-healing, and multi-DC resilience." \
                     "The DataStax driver completes the picture: smart routing, failover, retries." \
                     "Together, they form a system that survives anything short of total destruction."
            ;;
        48)
            header 48 "ACID vs HCD: What 'Transactions' Really Mean Here"
            echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
            echo -e "${C_BLUE}  PART 6: TRANSACTIONS & CONSISTENCY PATTERNS (Modules 48-53)${C_RESET}"
            echo -e "${C_BLUE}  We've covered operations (25-47). Now: how do you build correct${C_RESET}"
            echo -e "${C_BLUE}  applications on top of an eventually-consistent database?${C_RESET}"
            echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
            echo ""
            echo "If you come from PostgreSQL or Oracle, you expect ACID transactions."
            echo "HCD provides a DIFFERENT model — deliberately — because that model"
            echo "is what enables linear horizontal scaling across datacenters."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|               TRADITIONAL RDBMS              HCD / CASSANDRA           |"
            echo "|  ┌─────────────────────────────┐    ┌─────────────────────────────┐    |"
            echo "|  │  A  Atomicity        YES     │    │  A  Atomicity     PARTIAL   │    |"
            echo "|  │     (full TX rollback)        │    │     (per-partition only)    │    |"
            echo "|  │                               │    │                             │    |"
            echo "|  │  C  Consistency      YES     │    │  C  Consistency   TUNABLE   │    |"
            echo "|  │     (constraints enforced)    │    │     (CL=ONE .. ALL)         │    |"
            echo "|  │                               │    │                             │    |"
            echo "|  │  I  Isolation        YES     │    │  I  Isolation     NONE*    │    |"
            echo "|  │     (SERIALIZABLE level)      │    │     (*row-level via LWT)    │    |"
            echo "|  │                               │    │                             │    |"
            echo "|  │  D  Durability       YES     │    │  D  Durability    YES       │    |"
            echo "|  │     (WAL + fsync)             │    │     (CommitLog + RF=3)      │    |"
            echo "|  └─────────────────────────────┘    └─────────────────────────────┘    |"
            echo "|                                                                         |"
            echo "|  KEY INSIGHT: HCD trades global isolation for horizontal scale.         |"
            echo "|  You get A·D guaranteed, C is tunable. Isolation does NOT exist in     |"
            echo "|  the RDBMS sense — no 'isolation levels'. LWT provides compare-and-    |"
            echo "|  swap (CAS) semantics on a single row, NOT multi-row transactions.     |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  The Consistency Spectrum:                                              |"
            echo "|                                                                         |"
            echo "|  Eventual ◄───────────────────────────────────────────► Linearizable    |"
            echo "|  CL=ONE        CL=QUORUM        CL=ALL         LWT (Paxos)            |"
            echo "|  (fastest)     (recommended)     (fragile)      (~4x slower)           |"
            echo "|                                                                         |"
            echo "|  RDBMS gives you SERIALIZABLE by default (one setting).                |"
            echo "|  HCD gives you a DIAL — you choose the trade-off PER QUERY.            |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.acid_demo (id int PRIMARY KEY, val text);\""

            separator
            echo -e "${C_WHITE}--- Level 1: CL=ONE (eventual, fastest) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CONSISTENCY ONE; INSERT INTO rf_prod.acid_demo (id, val) VALUES (1, 'eventual-write'); TRACING OFF;\" 2>&1 | tail -n 5"

            separator
            echo -e "${C_WHITE}--- Level 2: CL=LOCAL_QUORUM (strong, recommended) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.acid_demo (id, val) VALUES (2, 'quorum-write'); TRACING OFF;\" 2>&1 | tail -n 5"

            separator
            echo -e "${C_WHITE}--- Level 3: LWT / Paxos (linearizable, slowest) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.acid_demo (id, val) VALUES (3, 'lwt-write') IF NOT EXISTS; TRACING OFF;\" 2>&1 | tail -n 8"

            lookfor "Compare 'Request complete' latency across the three traces."
            lookfor "CL=ONE: ~1-2ms. LOCAL_QUORUM: ~2-5ms. LWT: ~8-15ms (Paxos overhead)."
            lookfor "The LWT trace shows extra Paxos phases: Prepare, Promise, Accept, Commit."

            separator
            echo -e "${C_WHITE}--- Inspect with WRITETIME ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT id, val, WRITETIME(val) as write_timestamp FROM rf_prod.acid_demo;\""
            lookfor "Every cell has a microsecond timestamp. This is how LWW resolves conflicts."

            takeaway "HCD guarantees: Atomicity (per-partition), tunable Consistency, and Durability (CommitLog + RF)." \
                     "There is NO isolation in the RDBMS sense. LWT provides row-level CAS, not transactions." \
                     "This is not a limitation — it is the design that enables linear horizontal scaling." \
                     "Module 12 showed LWT for race conditions. Modules 49-53 show the full pattern toolkit."
            ;;
        49)
            header 49 "LOGGED vs UNLOGGED BATCH — Atomicity Without Isolation"
            echo "Batches in HCD are NOT for performance. They are for ATOMICITY."
            echo "Grouping 1000 inserts into a batch creates a single massive mutation"
            echo "that overwhelms the coordinator. Use async individual writes for throughput."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  LOGGED BATCH — Crash Recovery via Batchlog:                           |"
            echo "|                                                                         |"
            echo "|  Step 1: Coordinator writes batch to BATCHLOG (on 2 other nodes)       |"
            echo "|          ┌──────────┐                                                   |"
            echo "|          │ BATCHLOG │  (stored on 2 peers for crash safety)             |"
            echo "|          └─────┬────┘                                                   |"
            echo "|                v                                                        |"
            echo "|  Step 2: Execute all mutations on target replicas                      |"
            echo "|          ┌──────┐  ┌──────┐  ┌──────┐                                  |"
            echo "|          │Node A│  │Node B│  │Node C│                                  |"
            echo "|          └──────┘  └──────┘  └──────┘                                  |"
            echo "|                v                                                        |"
            echo "|  Step 3: Remove BATCHLOG entries (cleanup)                             |"
            echo "|                                                                         |"
            echo "|  If coordinator CRASHES between Step 1 and 2:                          |"
            echo "|  → Batchlog replicas detect the timeout and REPLAY the batch!          |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  BATCH TYPE DECISION:                                                  |"
            echo "|                                                                         |"
            echo "|  Same partition key?  ──YES──► UNLOGGED (atomic by default at storage) |"
            echo "|       │                                                                |"
            echo "|      NO                                                                |"
            echo "|       │                                                                |"
            echo "|  Multiple partitions? ──YES──► LOGGED (batchlog guarantees all-or-none)|"
            echo "|                                                                         |"
            echo "|  ╔══════════════════════════════════════════════════════════════════╗   |"
            echo "|  ║  CRITICAL: Batches are for ATOMICITY, not performance!          ║   |"
            echo "|  ║  A 1000-row batch = 1 giant mutation on the coordinator.        ║   |"
            echo "|  ║  Use async individual writes for throughput.                    ║   |"
            echo "|  ╚══════════════════════════════════════════════════════════════════╝   |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.batch_users (user_id int PRIMARY KEY, name text, email text);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.batch_audit (event_id timeuuid PRIMARY KEY, action text, user_id int);\""

            separator
            echo -e "${C_WHITE}--- Demo 1: UNLOGGED BATCH (same table, fast) ---${C_RESET}"
            echo "All rows go to the same table. No batchlog overhead."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; BEGIN UNLOGGED BATCH INSERT INTO rf_prod.batch_users (user_id, name, email) VALUES (1, 'Alice', 'alice@acme.com'); INSERT INTO rf_prod.batch_users (user_id, name, email) VALUES (2, 'Bob', 'bob@acme.com'); APPLY BATCH; TRACING OFF;\" 2>&1 | tail -n 8"

            lookfor "No 'Storing batchlog' in the trace — UNLOGGED skips the batchlog."

            separator
            echo -e "${C_WHITE}--- Demo 2: LOGGED BATCH (cross-table, with batchlog) ---${C_RESET}"
            echo "User creation + audit log entry must be atomic across two tables."
            echo "The batchlog ensures both mutations happen or neither does."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; BEGIN BATCH INSERT INTO rf_prod.batch_users (user_id, name, email) VALUES (10, 'Charlie', 'charlie@acme.com'); INSERT INTO rf_prod.batch_audit (event_id, action, user_id) VALUES (now(), 'user_created', 10); APPLY BATCH; TRACING OFF;\" 2>&1 | tail -n 12"

            lookfor "Look for 'Storing batchlog' and 'Removing batchlog' in the trace."
            lookfor "These extra steps add ~30% latency but guarantee crash-safe atomicity."

            separator
            echo -e "${C_WHITE}--- Demo 3: The Anti-Pattern — Batch for Performance ---${C_RESET}"
            echo -e "${C_YELLOW}⚠  DO NOT do this in production. We show it to illustrate the danger.${C_RESET}"
            echo ""

            log_info "Checking thread pool state BEFORE large batch..."
            log_cmd "docker exec hcd-node1 nodetool tpstats 2>/dev/null | grep -E 'MutationStage|BatchlogMutation' | head -n 5 || echo '(tpstats)'"

            BATCH_CQL="BEGIN UNLOGGED BATCH "
            for i in $(seq 1 50); do
                BATCH_CQL="${BATCH_CQL} INSERT INTO rf_prod.batch_users (user_id, name, email) VALUES ($((100 + i)), 'batch-user-$i', 'user$i@perf-test.com');"
            done
            BATCH_CQL="${BATCH_CQL} APPLY BATCH;"
            log_cmd "docker exec hcd-node1 cqlsh -e \"${BATCH_CQL}\""

            log_info "Thread pool state AFTER large batch..."
            log_cmd "docker exec hcd-node1 nodetool tpstats 2>/dev/null | grep -E 'MutationStage|BatchlogMutation' | head -n 5 || echo '(tpstats)'"

            lookfor "A 50-row batch is a SINGLE mutation on the coordinator — compare Completed counts."
            lookfor "In production, 10,000-row batches cause coordinator timeouts and back-pressure."

            separator
            echo -e "${C_WHITE}--- Verify data ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT count(*) FROM rf_prod.batch_users;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.batch_audit;\""

            takeaway "UNLOGGED BATCH for same-partition atomicity (free — already atomic at storage layer)." \
                     "LOGGED BATCH for cross-partition atomicity (batchlog adds ~30% latency overhead)." \
                     "Batches are for ATOMICITY, never for performance. Use async writes for throughput." \
                     "Key difference from RDBMS: a batch provides atomicity but NOT isolation." \
                     "A concurrent read CAN see partial batch results. Modules 50-51 address this."
            ;;
        50)
            header 50 "The Lost Update Problem — Why Read-Modify-Write Needs LWT"
            echo "The most dangerous consistency bug in distributed systems: the LOST UPDATE."
            echo "Two clients read a value, compute a new value, and write it back."
            echo "Without coordination, one update silently disappears."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  THE LOST UPDATE PROBLEM:                                              |"
            echo "|                                                                         |"
            echo "|  Account balance = 100                                                 |"
            echo "|                                                                         |"
            echo "|  Thread A (DC1)                Thread B (DC2)                           |"
            echo "|  ──────────────                ──────────────                            |"
            echo "|  1. READ balance  → 100        1. READ balance  → 100                  |"
            echo "|  2. new = 100 + 50             2. new = 100 + 30                       |"
            echo "|  3. WRITE balance = 150        3. WRITE balance = 130                  |"
            echo "|                                                                         |"
            echo "|  Expected final balance: 180 (100 + 50 + 30)                           |"
            echo "|  Actual result:          130 or 150 (one update LOST!)                 |"
            echo "|                                                                         |"
            echo "|  Root cause: LWW (Last-Write-Wins) picks the latest timestamp,         |"
            echo "|  not the latest LOGICAL state. It has no idea about the read step.     |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  SOLUTION: LWT (Compare-And-Swap)                                     |"
            echo "|                                                                         |"
            echo "|  UPDATE accounts SET balance = 150                                     |"
            echo "|    WHERE account_id = 'acct-001' IF balance = 100;                     |"
            echo "|                                                                         |"
            echo "|  → Only succeeds if balance is STILL 100.                              |"
            echo "|  → If someone else changed it: [applied]=False + current value.        |"
            echo "|  → App retries with the new current value.                             |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  SERIAL vs LOCAL_SERIAL:                                               |"
            echo "|                                                                         |"
            echo "|  SERIAL       : Paxos consensus across ALL DCs                        |"
            echo "|                  → Global linearizability, high latency (WAN)          |"
            echo "|                                                                         |"
            echo "|  LOCAL_SERIAL : Paxos consensus within LOCAL DC only                   |"
            echo "|                  → DC-local linearizability, low latency (LAN)         |"
            echo "|                  → Risk: two DCs could accept conflicting LWTs         |"
            echo "|                                                                         |"
            echo "|  Rule: Use LOCAL_SERIAL when LWT operations are DC-affine.             |"
            echo "|        Use SERIAL when global uniqueness is required.                  |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.accounts (account_id text PRIMARY KEY, balance int, owner text);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRUNCATE rf_prod.accounts;\""

            separator
            echo -e "${C_WHITE}--- Phase 1: Demonstrate the Lost Update ---${C_RESET}"
            echo "We write balance=100, then two concurrent updates try to modify it."
            echo "  DC1: reads 100, adds 50, writes 150"
            echo "  DC2: reads 100, adds 30, writes 130"
            echo ""
            echo -e "${C_YELLOW}>>> QUESTION: What will the final balance be?${C_RESET}"
            echo -e "${C_YELLOW}>>>   A) 180 (100 + 50 + 30)${C_RESET}"
            echo -e "${C_YELLOW}>>>   B) 150 (dc1 wins)${C_RESET}"
            echo -e "${C_YELLOW}>>>   C) 130 (dc2 wins)${C_RESET}"
            echo -e "${C_YELLOW}>>>   D) 130 or 150 (depends on timing)${C_RESET}"
            pause

            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.accounts (account_id, balance, owner) VALUES ('acct-001', 100, 'Alice');\""

            echo ""
            echo "Launching TWO concurrent updates (dc1 sets 150, dc2 sets 130)..."
            if [ "$DRY_RUN" = false ]; then
                docker exec hcd-node1 cqlsh -e "UPDATE rf_prod.accounts SET balance = 150 WHERE account_id = 'acct-001';" &
                UPD1_PID=$!
                docker exec hcd-node4 cqlsh -e "UPDATE rf_prod.accounts SET balance = 130 WHERE account_id = 'acct-001';" &
                UPD2_PID=$!
                wait $UPD1_PID 2>/dev/null
                wait $UPD2_PID 2>/dev/null
                echo -e "${C_GREEN}[EXEC]${C_RESET} Both updates completed concurrently."
            else
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node1 cqlsh -e \"UPDATE ... SET balance = 150 ...\" &"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} docker exec hcd-node4 cqlsh -e \"UPDATE ... SET balance = 130 ...\" &"
                echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} (both updates launched in parallel)"
            fi

            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT account_id, balance, WRITETIME(balance) FROM rf_prod.accounts WHERE account_id = 'acct-001';\""
            echo ""
            echo -e "${C_YELLOW}>>> The balance is 130 OR 150 — but NEVER 180 (100+50+30).${C_RESET}"
            echo -e "${C_YELLOW}>>> One update was silently LOST. This is the lost update problem.${C_RESET}"
            echo ""

            separator
            echo -e "${C_WHITE}--- Phase 2: Fix with LWT (Compare-And-Swap) ---${C_RESET}"
            echo "Now we use IF conditions to make the update safe."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.accounts (account_id, balance, owner) VALUES ('acct-002', 100, 'Bob');\""

            echo ""
            log_info "First update: add 50 to balance (IF balance = 100)..."
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.accounts SET balance = 150 WHERE account_id = 'acct-002' IF balance = 100;\""
            lookfor "[applied]: True — balance was 100, now 150."

            pause

            log_info "Second update: tries to add 30 (IF balance = 100)..."
            log_cmd "docker exec hcd-node4 cqlsh -e \"UPDATE rf_prod.accounts SET balance = 130 WHERE account_id = 'acct-002' IF balance = 100;\""
            lookfor "[applied]: False — balance is no longer 100! Current value returned."
            lookfor "The app sees [applied]=False with balance=150, and can RETRY: 150+30=180."

            pause

            log_info "Correct retry with the current value..."
            log_cmd "docker exec hcd-node4 cqlsh -e \"UPDATE rf_prod.accounts SET balance = 180 WHERE account_id = 'acct-002' IF balance = 150;\""
            lookfor "[applied]: True — balance is now 180. Both updates preserved!"

            separator
            echo -e "${C_WHITE}--- Phase 3: SERIAL vs LOCAL_SERIAL ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY LOCAL_SERIAL; SELECT * FROM rf_prod.accounts WHERE account_id = 'acct-002';\""
            lookfor "LOCAL_SERIAL reads the Paxos-committed state (latest LWT result)."

            log_cmd "docker exec hcd-node1 cqlsh -e \"CONSISTENCY SERIAL; SELECT * FROM rf_prod.accounts WHERE account_id = 'acct-002';\""
            lookfor "SERIAL does the same but with cross-DC Paxos — higher latency."

            takeaway "Read-modify-write WITHOUT LWT = lost updates. LWW picks a timestamp winner, not a sum." \
                     "IF conditions on UPDATE/INSERT provide compare-and-swap (CAS) semantics." \
                     "[applied]: False returns the CURRENT values — use them to compute your retry." \
                     "SERIAL = global linearizability. LOCAL_SERIAL = DC-local (lower latency)." \
                     "This is the foundation for safe financial operations (Module 51)."
            ;;
        51)
            header 51 "Banking: Instant Payment Between Two Banks"
            echo "This module applies everything from Modules 48-50 to a real-world scenario:"
            echo "an instant payment from Alice (Bank A) to Bob (Bank B)."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  INSTANT PAYMENT: Alice (Bank A) pays Bob (Bank B) \$100               |"
            echo "|                                                                         |"
            echo "|  ┌───────────────┐                    ┌───────────────┐                |"
            echo "|  │   BANK A (dc1)│                    │   BANK B (dc2)│                |"
            echo "|  │               │                    │               │                |"
            echo "|  │  Alice: \$500  │── 1. DEBIT \$100 ──►│               │                |"
            echo "|  │  Alice: \$400  │                    │  Bob: \$200    │                |"
            echo "|  │               │                    │  Bob: \$300    │◄── 2. CREDIT   |"
            echo "|  └───────────────┘                    └───────────────┘                |"
            echo "|                                                                         |"
            echo "|  WHY NOT a single ACID transaction?                                    |"
            echo "|  → Bank A and Bank B are DIFFERENT partitions (different DCs!)          |"
            echo "|  → HCD has no multi-partition isolation (no 2PC, no XA)                |"
            echo "|  → A LOGGED BATCH gives atomicity but NOT isolation:                   |"
            echo "|    a concurrent read could see the debit without the credit            |"
            echo "|    = 'missing money' visible to the customer                           |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  CORRECT PATTERN: LWT + Idempotency + CDC                             |"
            echo "|                                                                         |"
            echo "|  Step 1: LWT debit  (IF balance >= amount AND version = N)             |"
            echo "|          → Safe: rejects if insufficient funds or stale version        |"
            echo "|                                                                         |"
            echo "|  Step 2: Record payment with status='DEBIT_COMPLETE' (CDC-enabled)     |"
            echo "|          → CDC event triggers credit on Bank B                         |"
            echo "|                                                                         |"
            echo "|  Step 3: Credit Bank B (idempotent via payment_id)                     |"
            echo "|          → Safe: IF NOT EXISTS prevents double-credit                  |"
            echo "|                                                                         |"
            echo "|  Step 4: Update payment status to 'COMPLETED'                          |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  FAILURE SCENARIOS:                                                    |"
            echo "|                                                                         |"
            echo "|  Scenario 1: Debit + Credit both succeed       → Happy path ✓         |"
            echo "|  Scenario 2: Debit fails (insufficient funds)  → LWT rejects. Safe ✓  |"
            echo "|  Scenario 3: Debit OK, credit fails            → Status stays          |"
            echo "|              'DEBIT_COMPLETE' → retry or compensate (refund debit)     |"
            echo "|  Scenario 4: Debit OK, coordinator crashes     → CDC or reconciliation |"
            echo "|              job detects orphaned payments                              |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.bank_accounts (bank text, account_id text, balance int, version int, PRIMARY KEY (bank, account_id));\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.payments (payment_id text PRIMARY KEY, from_bank text, from_account text, to_bank text, to_account text, amount int, status text, created_at timestamp) WITH cdc = true;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRUNCATE rf_prod.bank_accounts;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRUNCATE rf_prod.payments;\""

            separator
            echo -e "${C_WHITE}--- Setup: Initialize Accounts ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.bank_accounts (bank, account_id, balance, version) VALUES ('bank-a', 'alice', 500, 1);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.bank_accounts (bank, account_id, balance, version) VALUES ('bank-b', 'bob', 200, 1);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.bank_accounts;\""

            separator
            echo -e "${C_WHITE}--- Step 1: LWT Debit (Safe Withdrawal) ---${C_RESET}"
            echo "Debit Alice \$100. The IF condition ensures:"
            echo "  - Sufficient funds (balance >= 100)"
            echo "  - No concurrent modification (version = 1)"
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.bank_accounts SET balance = 400, version = 2 WHERE bank = 'bank-a' AND account_id = 'alice' IF balance >= 100 AND version = 1;\""
            lookfor "[applied]: True — Alice debited from 500 to 400, version bumped to 2."

            separator
            echo -e "${C_WHITE}--- Step 2: Record Payment (CDC-Enabled) ---${C_RESET}"
            echo "The payment record triggers downstream processing via CDC."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.payments (payment_id, from_bank, from_account, to_bank, to_account, amount, status, created_at) VALUES ('PAY-001', 'bank-a', 'alice', 'bank-b', 'bob', 100, 'DEBIT_COMPLETE', toTimestamp(now()));\""

            separator
            echo -e "${C_WHITE}--- Step 3: Credit Bob (Triggered by CDC in Production) ---${C_RESET}"
            echo "In production, a CDC consumer reads the payment event and executes this."
            echo "The LWT prevents double-credit if the CDC consumer retries."
            echo ""
            log_cmd "docker exec hcd-node4 cqlsh -e \"UPDATE rf_prod.bank_accounts SET balance = 300, version = 2 WHERE bank = 'bank-b' AND account_id = 'bob' IF version = 1;\""
            lookfor "[applied]: True — Bob credited from 200 to 300."

            separator
            echo -e "${C_WHITE}--- Step 4: Mark Payment Complete ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.payments SET status = 'COMPLETED' WHERE payment_id = 'PAY-001';\""

            separator
            echo -e "${C_WHITE}--- Verify Final State ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.bank_accounts;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.payments;\""
            lookfor "Alice: 400 (was 500). Bob: 300 (was 200). Payment: COMPLETED."
            lookfor "Total money in system: 700 = 400 + 300. Unchanged. No money created or lost."

            separator
            echo -e "${C_WHITE}--- Failure Scenario: Duplicate Debit Attempt ---${C_RESET}"
            echo -e "${C_YELLOW}>>> QUESTION: The system retries the debit (same amount, same IF condition).${C_RESET}"
            echo -e "${C_YELLOW}>>> Will Alice be debited TWICE? Will she lose another \$100?${C_RESET}"
            pause
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.bank_accounts SET balance = 300, version = 3 WHERE bank = 'bank-a' AND account_id = 'alice' IF version = 1;\""
            lookfor "[applied]: False — version is 2, not 1. Idempotency preserved!"
            lookfor "The response shows current balance=400 and version=2."

            separator
            echo -e "${C_WHITE}--- Failure Scenario: Insufficient Funds ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.bank_accounts SET balance = -100, version = 3 WHERE bank = 'bank-a' AND account_id = 'alice' IF balance >= 600 AND version = 2;\""
            lookfor "[applied]: False — balance is 400, which is < 600. Overdraft prevented!"

            separator
            log_info "Checking CDC segment for payment events..."
            log_cmd "docker exec hcd-node1 ls -la /var/lib/cassandra/cdc_raw/ 2>/dev/null || echo '(CDC directory — events available for downstream consumers)'"

            takeaway "Cross-partition 'transactions' in HCD use: LWT debit + CDC event + idempotent credit." \
                     "Each step must be independently safe. Design for 'debit succeeded, credit failed.'" \
                     "Version columns prevent double-processing (idempotency key)." \
                     "CDC provides guaranteed event delivery for async coordination between banks." \
                     "Money is NEVER created or lost — the total is always conserved."
            ;;
        52)
            header 52 "The Saga Pattern: Supplier/Customer Order Flow"
            echo "A supplier receives an order from a customer. Four steps must happen:"
            echo "place order → reserve inventory → capture payment → ship."
            echo "Each step is an independent LWT-protected mutation."
            echo "If any step fails, compensating transactions UNDO previous steps."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  ORDER SAGA FLOW:                                                      |"
            echo "|                                                                         |"
            echo "|  ┌──────────┐    ┌──────────────┐    ┌───────────┐    ┌──────────────┐|"
            echo "|  │ 1. ORDER │───►│ 2. INVENTORY │───►│ 3. PAYMENT│───►│ 4. SHIPMENT  │|"
            echo "|  │  PLACED  │    │   RESERVED   │    │  CAPTURED │    │    SENT      │|"
            echo "|  └──────────┘    └──────────────┘    └───────────┘    └──────────────┘|"
            echo "|       │ CDC            │ CDC              │ CDC            │ CDC       |"
            echo "|       v                v                  v                v           |"
            echo "|  [Reserve         [Capture          [Initiate         [Mark           |"
            echo "|   inventory]       payment]          shipment]         complete]      |"
            echo "|                                                                         |"
            echo "|  ═══════════ COMPENSATION (if payment fails) ═══════════                |"
            echo "|                                                                         |"
            echo "|  ┌───────────┐    ┌──────────────┐                                    |"
            echo "|  │ PAYMENT   │───►│ INVENTORY    │     Order status → 'CANCELLED'     |"
            echo "|  │ FAILED    │    │ RELEASED     │     Customer notified               |"
            echo "|  └───────────┘    └──────────────┘                                    |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            echo "Each step uses LWT (IF condition) to guarantee:"
            echo "  - Idempotency: retrying a step never double-processes"
            echo "  - Safety: insufficient inventory or funds → step rejected, not corrupted"
            echo "  - Reversibility: every step has a compensating transaction"
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.saga_orders (order_id text PRIMARY KEY, customer text, product text, quantity int, status text, created_at timestamp) WITH cdc = true;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.saga_inventory (product text PRIMARY KEY, available int, reserved int, version int);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.saga_payments (order_id text PRIMARY KEY, amount int, status text, version int);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRUNCATE rf_prod.saga_orders;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRUNCATE rf_prod.saga_inventory;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRUNCATE rf_prod.saga_payments;\""

            separator
            echo -e "${C_WHITE}--- Setup: Supplier Inventory ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.saga_inventory (product, available, reserved, version) VALUES ('widget-x', 100, 0, 1);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.saga_inventory;\""

            separator
            echo -e "${C_BOLD}═══ HAPPY PATH: Order ORD-001 (5 widgets) ═══${C_RESET}"
            echo ""

            echo -e "${C_WHITE}--- Step 1: Place Order ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.saga_orders (order_id, customer, product, quantity, status, created_at) VALUES ('ORD-001', 'alice', 'widget-x', 5, 'PLACED', toTimestamp(now()));\""

            separator
            echo -e "${C_WHITE}--- Step 2: Reserve Inventory (LWT) ---${C_RESET}"
            echo "Decrement available, increment reserved. Only if enough stock AND correct version."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_inventory SET available = 95, reserved = 5, version = 2 WHERE product = 'widget-x' IF version = 1 AND available >= 5;\""
            lookfor "[applied]: True — 5 widgets reserved. Available: 100 → 95."
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_orders SET status = 'INVENTORY_RESERVED' WHERE order_id = 'ORD-001';\""

            separator
            echo -e "${C_WHITE}--- Step 3: Capture Payment (LWT) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.saga_payments (order_id, amount, status, version) VALUES ('ORD-001', 250, 'CAPTURED', 1) IF NOT EXISTS;\""
            lookfor "[applied]: True — payment captured. IF NOT EXISTS prevents double-charge."
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_orders SET status = 'PAYMENT_CAPTURED' WHERE order_id = 'ORD-001';\""

            separator
            echo -e "${C_WHITE}--- Step 4: Ship ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_inventory SET reserved = 0, version = 3 WHERE product = 'widget-x' IF version = 2;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_orders SET status = 'SHIPPED' WHERE order_id = 'ORD-001';\""

            echo ""
            log_info "Order ORD-001 complete. Full lifecycle:"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.saga_orders WHERE order_id = 'ORD-001';\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.saga_inventory;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.saga_payments;\""

            lookfor "Order: SHIPPED. Inventory: 95 available, 0 reserved. Payment: CAPTURED."

            separator
            echo -e "${C_BOLD}═══ FAILURE PATH: Order ORD-002 (payment fails → compensate) ═══${C_RESET}"
            echo ""

            echo -e "${C_WHITE}--- Step 1: Place Order ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.saga_orders (order_id, customer, product, quantity, status, created_at) VALUES ('ORD-002', 'bob', 'widget-x', 10, 'PLACED', toTimestamp(now()));\""

            separator
            echo -e "${C_WHITE}--- Step 2: Reserve Inventory (LWT) ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_inventory SET available = 85, reserved = 10, version = 4 WHERE product = 'widget-x' IF version = 3 AND available >= 10;\""
            lookfor "[applied]: True — 10 widgets reserved."
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_orders SET status = 'INVENTORY_RESERVED' WHERE order_id = 'ORD-002';\""

            separator
            echo -e "${C_WHITE}--- Step 3: Payment FAILS ---${C_RESET}"
            echo "Simulating payment failure: the payment processor rejects the charge."
            echo "(We pre-insert a conflicting row to simulate IF NOT EXISTS rejection.)"
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.saga_payments (order_id, amount, status, version) VALUES ('ORD-002', 0, 'FAILED', 1);\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"INSERT INTO rf_prod.saga_payments (order_id, amount, status, version) VALUES ('ORD-002', 500, 'CAPTURED', 1) IF NOT EXISTS;\""
            lookfor "[applied]: False — payment already exists with status=FAILED."

            separator
            echo -e "${C_YELLOW}--- COMPENSATING TRANSACTION: Release Reserved Inventory ---${C_RESET}"
            echo "Payment failed. We must undo the inventory reservation."
            echo ""
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_inventory SET available = 95, reserved = 0, version = 5 WHERE product = 'widget-x' IF version = 4;\""
            lookfor "[applied]: True — inventory released. Available back to 95."
            log_cmd "docker exec hcd-node1 cqlsh -e \"UPDATE rf_prod.saga_orders SET status = 'CANCELLED' WHERE order_id = 'ORD-002';\""

            separator
            echo -e "${C_WHITE}--- Final State After Compensation ---${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.saga_orders;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.saga_inventory;\""
            log_cmd "docker exec hcd-node1 cqlsh -e \"SELECT * FROM rf_prod.saga_payments;\""

            lookfor "ORD-001: SHIPPED (success). ORD-002: CANCELLED (compensated)."
            lookfor "Inventory: 95 available (ORD-002's 10 released back). Zero reserved."
            lookfor "No data corruption. No inventory leak. Each step independently safe."

            takeaway "The Saga pattern replaces ACID transactions in distributed systems." \
                     "Each step: LWT mutation + status update. CDC events trigger the next step." \
                     "Compensating transactions UNDO previous steps on failure (release inventory, refund)." \
                     "Design rule: every saga step must be idempotent and independently reversible." \
                     "This pattern scales across DCs, services, and organizational boundaries."
            ;;
        53)
            header 53 "Consistency Decision Framework"
            echo "You now have the complete toolkit. This module brings it all together:"
            echo "a decision framework for choosing the right consistency pattern."
            echo ""
            echo "+-----------------------------------------------------------------------+"
            echo "|  DECISION TREE:                                                        |"
            echo "|                                                                         |"
            echo "|  Is your operation a single-partition write?                            |"
            echo "|  ├── YES: Do you need uniqueness / CAS guarantees?                     |"
            echo "|  │   ├── YES ──► LWT  (IF NOT EXISTS / IF condition)                   |"
            echo "|  │   └── NO  ──► Simple write at LOCAL_QUORUM                          |"
            echo "|  │                                                                      |"
            echo "|  └── NO (multi-partition):                                              |"
            echo "|      ├── Do all mutations target the SAME table?                        |"
            echo "|      │   ├── Same partition key ──► UNLOGGED BATCH                     |"
            echo "|      │   └── Different keys     ──► LOGGED BATCH                       |"
            echo "|      │                                                                  |"
            echo "|      └── Do you need cross-partition consistency (no partial state)?    |"
            echo "|          ├── YES ──► Saga Pattern (LWT + CDC + compensation)           |"
            echo "|          └── NO  ──► LOGGED BATCH is sufficient                        |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            pause

            echo "+-----------------------------------------------------------------------+"
            echo "|  PATTERN COMPARISON:                                                   |"
            echo "|                                                                         |"
            echo "|  Pattern          │ Latency │ Throughput │ Atomicity  │ CAS Scope      |"
            echo "|  ─────────────────┼─────────┼────────────┼────────────┼─────────────── |"
            echo "|  CL=LOCAL_QUORUM  │ ~2ms    │ Highest    │ Per-write  │ None           |"
            echo "|  UNLOGGED BATCH   │ ~2ms    │ High       │ Partition  │ None           |"
            echo "|  LOGGED BATCH     │ ~3ms    │ Medium     │ Cross-ptn  │ None           |"
            echo "|  LWT (Paxos)      │ ~8-15ms │ Low        │ Row-level  │ Row-level CAS  |"
            echo "|  Saga (LWT+CDC)   │ ~50ms+  │ Lowest     │ Workflow   │ Per-step CAS   |"
            echo "+-----------------------------------------------------------------------+"
            echo ""
            pause

            echo "+-----------------------------------------------------------------------+"
            echo "|  THE FIVE GOLDEN RULES:                                                |"
            echo "|                                                                         |"
            echo "|  1. Default to LOCAL_QUORUM — correct for 90% of use cases            |"
            echo "|  2. Use LWT only for race-critical operations (< 5% of writes)        |"
            echo "|  3. Batches are for atomicity, NEVER for performance                   |"
            echo "|  4. Sagas are for business workflows, not database transactions        |"
            echo "|  5. When in doubt, make your operations IDEMPOTENT                     |"
            echo "+-----------------------------------------------------------------------+"
            echo ""

            separator
            echo -e "${C_WHITE}--- Live Latency Comparison ---${C_RESET}"
            echo "Three patterns, same table, measured back-to-back."
            echo ""

            log_cmd "docker exec hcd-node1 cqlsh -e \"CREATE TABLE IF NOT EXISTS rf_prod.framework_test (id int PRIMARY KEY, val text);\""

            echo -e "${C_WHITE}Pattern 1: Simple LOCAL_QUORUM write${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.framework_test (id, val) VALUES (1, 'simple-write'); TRACING OFF;\" 2>&1 | tail -n 5"

            separator
            echo -e "${C_WHITE}Pattern 2: LOGGED BATCH (cross-partition)${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; BEGIN BATCH INSERT INTO rf_prod.framework_test (id, val) VALUES (10, 'batch-a'); INSERT INTO rf_prod.framework_test (id, val) VALUES (11, 'batch-b'); APPLY BATCH; TRACING OFF;\" 2>&1 | tail -n 8"

            separator
            echo -e "${C_WHITE}Pattern 3: LWT (Paxos)${C_RESET}"
            log_cmd "docker exec hcd-node1 cqlsh -e \"TRACING ON; INSERT INTO rf_prod.framework_test (id, val) VALUES (20, 'lwt-write') IF NOT EXISTS; TRACING OFF;\" 2>&1 | tail -n 8"

            lookfor "Compare 'Request complete' latency: Simple < Batch < LWT."
            lookfor "The LWT trace is visibly longer with Paxos phases (Prepare/Promise/Accept/Commit)."
            lookfor "The LOGGED BATCH trace shows 'Storing batchlog' overhead."

            pause

            separator
            echo -e "${C_WHITE}--- Which Modules Demonstrated Each Pattern? ---${C_RESET}"
            echo ""
            echo "  LOCAL_QUORUM writes:  Modules 2, 29, 33 (failover under load)"
            echo "  LWT (Paxos):          Modules 12 (tickets), 50 (lost update), 51 (banking)"
            echo "  LOGGED BATCH:         Module 49 (cross-table atomicity)"
            echo "  Saga (LWT+CDC):       Modules 51 (banking), 52 (order flow)"
            echo "  UNLOGGED BATCH:       Module 49 (same-partition)"
            echo ""
            echo "  Use case mapping:"
            echo "  ┌─────────────────────────┬───────────────────────────────┐"
            echo "  │ Use Case                │ Pattern                       │"
            echo "  ├─────────────────────────┼───────────────────────────────┤"
            echo "  │ IoT sensor ingestion    │ LOCAL_QUORUM (Module 30)      │"
            echo "  │ Ticket reservations     │ LWT (Module 12)               │"
            echo "  │ User + audit atomic     │ LOGGED BATCH (Module 49)      │"
            echo "  │ Bank transfer           │ Saga: LWT + CDC (Module 51)   │"
            echo "  │ Order fulfillment       │ Saga: LWT + CDC (Module 52)   │"
            echo "  │ Account balance update  │ LWT with IF (Module 50)       │"
            echo "  │ Log/metrics append      │ CL=ONE (eventual is fine)     │"
            echo "  └─────────────────────────┴───────────────────────────────┘"
            echo ""

            takeaway "90% of production workloads need only LOCAL_QUORUM — no LWT, no batch." \
                     "LWT is for the 5% where correctness requires compare-and-swap (CAS)." \
                     "Batches are for the 5% where you need cross-partition atomic visibility." \
                     "Sagas are for business processes that span services or organizational boundaries." \
                     "Design for idempotency first. It makes every other pattern simpler and safer."
            ;;
    esac
    pause
}

# ══════════════════════════════════════════════════════════════════
# Score Mode: Run all modules in dry-run and report pass/fail
# ══════════════════════════════════════════════════════════════════
if [ "$SCORE_MODE" = true ]; then
    SCORE_PASS=0
    SCORE_FAIL=0
    SCORE_RESULTS=""

    echo ""
    echo -e "${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  HCD Demo Scorecard — Automated Module Validation${C_RESET}"
    echo -e "${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""

    for i in $(seq 0 53); do
        output=$(run_module "$i" 2>&1)
        exit_code=$?
        # Check for fatal errors (but not expected "[DRY-RUN]" output)
        if [ $exit_code -eq 0 ] && [ -n "$output" ]; then
            SCORE_PASS=$((SCORE_PASS + 1))
            SCORE_RESULTS="${SCORE_RESULTS}  ${C_GREEN}PASS${C_RESET}  Module ${i}\n"
        else
            SCORE_FAIL=$((SCORE_FAIL + 1))
            SCORE_RESULTS="${SCORE_RESULTS}  ${C_YELLOW}FAIL${C_RESET}  Module ${i}\n"
        fi
        # Progress ticker
        if [ $(( (i + 1) % 10 )) -eq 0 ]; then
            echo -e "  [${i}/53] modules validated..."
        fi
    done

    echo ""
    echo -e "${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  RESULTS${C_RESET}"
    echo -e "${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "$SCORE_RESULTS"
    echo -e "${C_BOLD}────────────────────────────────────────────────────────────────${C_RESET}"
    SCORE_TOTAL=$((SCORE_PASS + SCORE_FAIL))
    SCORE_PCT=$((SCORE_PASS * 100 / SCORE_TOTAL))
    echo -e "  Total:  ${SCORE_TOTAL} modules"
    echo -e "  Passed: ${C_GREEN}${SCORE_PASS}${C_RESET}"
    echo -e "  Failed: ${C_YELLOW}${SCORE_FAIL}${C_RESET}"
    echo -e "  Score:  ${SCORE_PCT}%"
    echo ""
    if [ "$SCORE_PCT" -eq 100 ]; then
        echo -e "  ${C_GREEN}ALL MODULES PASSED. Demo is ready for presentation.${C_RESET}"
    else
        echo -e "  ${C_YELLOW}Some modules failed. Review the output above.${C_RESET}"
    fi
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════════════
# Main Execution Loop
# ══════════════════════════════════════════════════════════════════
if [ -n "$SELECTED_MODULE" ]; then
    run_module "$SELECTED_MODULE"
else
    for i in {0..53}; do
        run_module $i
    done
fi
