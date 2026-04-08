# HCD Entropy & Consistency Didactic Demo
> **Executive Summary:** An 84-module interactive demo proving that IBM HCD delivers zero-downtime resilience, automatic self-healing, and tunable consistency across datacenters — including a full DORA ransomware resilience scenario with WORM-protected backups. Designed for live stakeholder presentations and hands-on engineering onboarding.
>
> **Why this matters:** Unplanned database downtime costs enterprises $5,600-$9,000 per minute [1]. This demo proves — live, on your laptop — that HCD survives datacenter-level failures with zero data loss and zero application errors, eliminating the single largest source of availability risk in distributed data infrastructure.

| | |
|---|---|
| **Modules** | 84 (0-83), organized in 10 parts |
| **Cluster** | 6 nodes, 2 DCs, RF=3 per DC |
| **Time (interactive)** | ~4-5 hours (full), ~20-35 min per part |
| **Time (non-interactive)** | ~60-90 minutes |
| **Prerequisites** | Docker, `hcd-1.2.3-bin.tar.gz` |

---

## Preface

### Who This Book Is For

This handbook is for **database engineers, architects, SREs, and technical decision-makers** evaluating or operating IBM HCD (Hyperledger Cassandra Distribution) in production. It assumes basic familiarity with relational databases and Linux command-line tools. No prior Cassandra experience is required — Part 1 builds from first principles.

**If you are a:**
- **Database engineer** — you will learn HCD internals through hands-on experiments that reveal how distributed consensus, replication, and repair actually work under the hood.
- **Solutions architect** — you will gain the technical vocabulary and live demonstrations to evaluate HCD against RDBMS alternatives for high-availability use cases.
- **SRE / Operations engineer** — Parts 3, 4, 7, 8, and 10 focus on production operations: backup/restore, repair scheduling, JVM tuning, monitoring, and incident response.
- **Compliance officer / CISO** — Part 9 provides a complete DORA ransomware resilience demonstration mapped to specific EU regulation articles.

### How to Use This Book

This is a **hands-on lab manual**, not a reference text. Every concept is demonstrated with live commands against a real 6-node cluster running on your laptop. The 84 modules are organized in 10 parts of increasing complexity.

**Three ways to use this material:**

1. **Full sequential walkthrough** (~4-5 hours): Run all 84 modules in order. Best for first-time learners and comprehensive onboarding.
2. **Part-by-part sessions** (~20-35 min each): Work through one part per sitting. Suggested break points are marked in the demo roadmap.
3. **Targeted deep-dives**: Jump to any module by number (`./demo-entropy.sh 23`). Modules > 1 auto-create required keyspaces.

**Conventions used:**
- `[DRY-RUN]` — commands shown but not executed (use `--dry-run` flag)
- `>>> Look for:` — observation hints telling you what to verify in the output
- `--- Takeaway ---` — key learning points summarizing each module
- `QUESTION:` / `ANSWER:` — interactive questions to test understanding before revealing answers
- `CHALLENGE:` — optional stretch exercises for deeper exploration

### What You Will Learn

By the end of this handbook, you will be able to:

- Design and operate a multi-datacenter HCD cluster with tunable consistency
- Explain and demonstrate the three-layer entropy defense (hinted handoff, read repair, anti-entropy repair)
- Perform live failover, backup/restore, rolling restart, and repair operations
- Evaluate HCD's suitability for DORA-regulated financial services environments
- Tune JVM, compaction, compression, and caching for production workloads
- Build applications using HCD drivers with token-aware routing, speculative execution, and retry policies

---

## Getting Started

1.  **Initialize the Cluster**:
    ```bash
    make up          # or: docker compose up -d --build
    ```
2.  **Monitor Readiness**:
    Wait until all 6 nodes show status `UN` (Up/Normal):
    ```bash
    make wait        # or: watch "docker exec hcd-node1 nodetool status"
    ```
3.  **Execute the Script**:
    ```bash
    make demo                        # full interactive demo
    ./scripts/demo-entropy.sh 23     # jump to a specific module
    ./scripts/demo-entropy.sh --dry-run --no-pause  # dry-run, no cluster needed
    ./scripts/demo-entropy.sh --score              # validate all 84 modules (scorecard)
    ```
    > **Single-module execution:** When jumping to Module N > 1, the script auto-creates the `rf_prod` keyspace via `ensure_rf_prod()` so prerequisites are satisfied.

4.  **Optional: Live Metrics Dashboard**:
    ```bash
    make monitoring      # starts Prometheus + Grafana
    ```
    Open [http://localhost:3000](http://localhost:3000) (admin/admin) for live cluster dashboards showing thread pools, latency percentiles, compaction, and dropped messages. Modules 38-40 reference Grafana when it's running.

---

## Glossary

| Term | Definition |
|------|-----------|
| **ANN** (Approximate Nearest Neighbor) | Search algorithm used with SAI vector indexes that finds semantically similar vectors without exhaustive comparison, trading recall for speed. |
| **Anti-Entropy Repair** | Process that synchronizes data across replicas by comparing Merkle trees and streaming missing or divergent data to bring replicas into agreement. |
| **Bloom Filter** | Probabilistic, space-efficient data structure used to test whether a partition exists in an SSTable; false positives are possible but false negatives are not. |
| **Bootstrap** | Process by which a new node joins the ring, streams the data it is responsible for from existing replicas, and begins serving traffic. |
| **CAP Theorem** | Theoretical result stating that a distributed system can guarantee at most two of Consistency, Availability, and Partition Tolerance simultaneously. |
| **CDC** (Change Data Capture) | Feature that logs every mutation to special CDC log files, enabling downstream consumers to stream real-time changes out of HCD. |
| **CL** (Consistency Level) | Per-operation setting controlling how many replicas must acknowledge a read or write before the coordinator considers the operation successful. |
| **Clustering Key** | Column(s) that determine on-disk sort order within a partition; combined with the partition key, they form the full primary key. |
| **CommitLog** | Write-ahead log on each node that durably records every mutation before it is applied to the Memtable, used for crash recovery. |
| **Compaction (LCS)** | Leveled Compaction Strategy — organizes SSTables into size-bounded levels, keeping read amplification low at the cost of higher write I/O. |
| **Compaction (STCS)** | Size-Tiered Compaction Strategy — merges SSTables of similar size, optimizing for write throughput but potentially producing large SSTables. |
| **Compaction (TWCS)** | Time-Window Compaction Strategy — groups SSTables by configurable time windows, ideal for time-series data with TTL-based expiry. |
| **Compaction (UCS)** | Unified Compaction Strategy — single tunable framework (HCD 1.2+ / Cassandra 5.0+) that can approximate STCS, LCS, or TWCS behavior. |
| **CompressedOops** | JVM optimization that compresses 64-bit object pointers to 32 bits when heap size is below ~31 GB, reducing memory overhead. |
| **Coordinator** | Node that receives a client request, routes it to the appropriate replicas, and aggregates the response based on consistency level. |
| **Counter** | Special column type supporting atomic increment/decrement operations; must live in a dedicated table and cannot use LWT. |
| **CQL** (Cassandra Query Language) | SQL-like query language for HCD/Cassandra; shares SELECT/INSERT/UPDATE/DELETE syntax but operates on distributed partitions. |
| **Datacenter** | Logical grouping of nodes within a cluster, typically mapped to a physical location or cloud region; used for replication targeting. |
| **Decommission** | Graceful removal of a node whereby it streams all token ranges to remaining replicas before leaving the cluster permanently. |
| **DORA** | EU Regulation 2022/2554 (Digital Operational Resilience Act) requiring financial entities to demonstrate ICT risk management and resilience testing. |
| **Frozen Collection** | Collection type (list, set, or map) serialized as a single opaque blob; the entire value must be overwritten to update any element. |
| **gc_grace_seconds** | Period after which a tombstone is eligible for purging during compaction; must exceed the repair cycle interval to prevent zombie data. |
| **Gossip** | Peer-to-peer protocol by which nodes periodically exchange state information (load, tokens, status) with a small set of peers. |
| **Hinted Handoff** | Mechanism where the coordinator stores a "hint" for writes destined for an unavailable replica and replays them on recovery. |
| **K8ssandra** | Open-source Kubernetes operator stack for HCD/Cassandra bundling automated repair (Reaper), backup (Medusa), and monitoring. |
| **LWT** (Lightweight Transaction) | Conditional read-modify-write operation via Paxos consensus, providing linearizable consistency at the cost of additional round trips. |
| **LWW** (Last-Write-Wins) | Default conflict-resolution strategy using cell-level timestamps to determine which value survives concurrent writes. |
| **Materialized View** | Server-side denormalization that automatically maintains a derived table with a different primary key, updated with the base table. |
| **Medusa** | Open-source backup/restore tool for Cassandra/HCD supporting S3-compatible, GCS, and Azure blob storage backends. |
| **Memtable** | In-memory write buffer where mutations accumulate after being written to the CommitLog; flushed to an SSTable when full. |
| **Merkle Tree** | Hash tree used during repair where each leaf represents a token range digest; differing subtrees identify ranges needing sync. |
| **Nodetool** | Primary CLI administration tool for HCD/Cassandra; used for status, repair, decommission, compaction, and operational tasks. |
| **Object Lock** | S3-compatible WORM enforcement preventing objects from being deleted or overwritten for a defined retention period. |
| **Off-Heap Memory** | JVM memory outside the managed heap; used for row caches, Bloom filters, and key caches to reduce GC impact. |
| **Partition Key** | First component of a table's primary key; its hash determines which token range — and which replicas — own the row. |
| **Prepared Statement** | CQL statement parsed and validated on the server once, then executed repeatedly by referencing its ID, reducing per-query overhead. |
| **RBAC** | Role-Based Access Control — security model where permissions on keyspaces, tables, and functions are granted to named roles. |
| **Rack** | Logical subdivision within a datacenter used by the snitch to place replicas on different failure domains. |
| **Read Repair** | Consistency mechanism where the coordinator compares replica responses during a read and patches stale replicas with the latest data. |
| **Reaper** | Open-source repair scheduler that orchestrates incremental or full repairs across the cluster with configurable parallelism. |
| **Replica** | A node holding a copy of the data for a particular token range, as determined by the replication factor. |
| **RF** (Replication Factor) | Total number of copies of each partition stored across the cluster; RF=3 means every row exists on three distinct nodes. |
| **SAI** (Storage-Attached Index) | Per-SSTable index implementation enabling efficient predicate queries on non-primary-key columns without global index tables. |
| **Seed Node** | Well-known node address that new or restarting nodes contact first to bootstrap gossip and learn cluster topology. |
| **Snitch** | Component that tells HCD about network topology (rack and datacenter membership), used to optimize replica placement. |
| **Speculative Execution** | Driver-side strategy that issues a duplicate request to a second replica if the first hasn't responded within a latency threshold. |
| **SSTable** (Sorted String Table) | Immutable on-disk file written when a Memtable is flushed; merged during compaction but never modified in place. |
| **Streaming** | Bulk transfer of SSTable data between nodes during bootstrap, decommission, repair, or DC expansion. |
| **TDE** (Transparent Data Encryption) | Encryption of SSTable data at rest; data is decrypted on read without application-level changes. |
| **Token** | 64-bit integer derived from a partition key hash; the full token ring is divided into ranges assigned to nodes. |
| **TokenAwarePolicy** | Driver load-balancing policy that routes requests directly to partition-owning replicas, minimizing coordinator hops. |
| **Tombstone** | Deletion marker written to flag data as deleted; retained until `gc_grace_seconds` has elapsed and purged during compaction. |
| **TTL** (Time To Live) | Per-cell or per-row expiry value in seconds; after TTL elapses, data is tombstoned and removed during compaction. |
| **UDT** (User-Defined Type) | Named, reusable composite type defined at keyspace level that groups multiple named fields, embeddable as a column type. |
| **Vnode** (Virtual Node) | Logical subdivision of the token ring assigned to a physical node; enables smoother load distribution and faster bootstrapping. |
| **WORM** (Write Once Read Many) | Storage policy preventing data modification or deletion after initial write, used for immutable backup archives. |

---

## Introduction: What is Entropy?

In a distributed database like HCD, **Entropy** refers to the natural divergence of data between replicas over time. Because HCD is a "leaderless" system designed for high availability, data is written to multiple nodes. If a node is down, under heavy load, or experiences network issues during a write, it may miss an update. This creates a "stale" replica.

### Why it Matters
If entropy is not managed, "stale" data might be returned to users, or data might be lost permanently if enough replicas fail before they are synchronized.

### How HCD Handles It
HCD uses three primary mechanisms to resolve entropy:
1.  **Hinted Handoff**: A short-term buffer where healthy nodes "remember" writes for a downed peer.
2.  **Read Repair**: On-the-fly synchronization triggered when data is read.
3.  **Anti-Entropy Repair**: A scheduled, manual, or background process that compares all data across replicas using Merkle Trees to ensure 100% consistency.

---

## Cluster Topology
This demo uses a 6-node, multi-DC cluster simulated in Docker.

```text
┌─────────────────────────────────────────────────────────────────────┐
│                         HCD Cluster                                 │
├─────────────────────────────────┬───────────────────────────────────┤
│           DC1 (us-east)         │           DC2 (us-west)           │
├───────────┬───────────┬─────────┼───────────┬───────────┬───────────┤
│  Rack 1   │  Rack 2   │ Rack 3  │  Rack 1   │  Rack 2   │  Rack 3   │
│ (AZ-1a)   │ (AZ-1b)   │ (AZ-1c) │ (AZ-2a)   │ (AZ-2b)   │ (AZ-2c)   │
├───────────┼───────────┼─────────┼───────────┼───────────┼───────────┤
│ hcd-node1 │ hcd-node2 │hcd-node3│ hcd-node4 │ hcd-node5 │ hcd-node6 │
│ 172.28.0.2│ 172.28.0.3│172.28.0.4│172.28.0.5│ 172.28.0.6│ 172.28.0.7│
│  (seed)   │           │         │  (seed)   │           │           │
└───────────┴───────────┴─────────┴───────────┴───────────┴───────────┘
```

---

## Demo Modules Overview

#### Part 1 — Foundations (Modules 0-13)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 0 | Introduction & Cluster Status | 6-node topology verified, HCD vs Apache Cassandra differentiation table |
| 1 | Replication Factors | RF=1 vs RF=3 endpoint comparison |
| 2 | Consistency Levels | Active DN polling + EACH_QUORUM fails then recovers |
| 3 | Node Failures | Interactive: "Will LOCAL_QUORUM succeed?" |
| 4 | Hinted Handoff | FIXED_ID query proves exact hint delivery |
| 5 | Read Repair | Forced divergence (stop/write/restart) + digest repair |
| 6 | Anti-Entropy Repair | Three-layer defense recap (HH/RR/Repair) |
| 7 | Token Ring | 256 vnodes per node, trace version disclaimer |
| 8 | Write Path Trace | LOCAL_QUORUM mutation forwarding, version-aware trace notes |
| 9 | Read Path Trace | Digest vs full-data request, version-aware trace notes |
| 10 | Node Recovery — The Full Picture | Gossip state, hint metrics, max_hint_window gap, three-layer defense recap |
| 11 | Tombstones | Delete markers survive compaction until gc_grace |
| 12 | Lightweight Transactions | Paxos IF NOT EXISTS prevents double-booking |
| 13 | Summary & Health Check | Schema agreement, all nodes UN |

#### Part 2 — Advanced Failures (Modules 14-24)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 14 | Ghost Rack (Double Rack Failure) | Interactive: "Can the cluster serve reads?" |
| 15 | Schema Disagreement | Interactive question + describecluster + system.peers + zero-downtime schema evolution patterns |
| 16 | Gossip Protocol | HEARTBEAT, STATUS, DC/RACK live inspection |
| 17 | Zombie Node (Network Partition) | Dynamic network name + interactive partition demo |
| 18 | SAI (Storage Attached Indexing) | Interactive Q + composable multi-index AND queries |
| 19 | Native JSON Ops | 13-part deep dive: basics + UDT nested docs, versioning, event sourcing, bulk perf, SAI composable queries |
| 20 | Vector Search & AI Readiness | Compatibility guard + ANN similarity with fallback + RAG pipeline architecture |
| 21 | Mixed Real-time Operations | Interactive Q + INSERT = UPDATE = mutation (LWW) |
| 22 | Compaction | Interactive Q + SSTable merge resolves physical entropy |
| 23 | Kill an Entire Datacenter (~5-8 min) | Zero data loss, LOCAL_QUORUM from dc2, RPO=0/RTO=seconds |
| 24 | Grand Finale | Three cascading failures, full self-healing |

#### Part 3 — Operations (Modules 25-37)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 25 | CDC (Change Data Capture) | `strings` on raw CDC segments proves capture + Debezium/Kafka integration |
| 26 | Audit Logging | Interactive Q + cassandra.yaml pre-check, multi-dir log search |
| 27 | Guardrails | Interactive Q + batch size warning/failure thresholds |
| 28 | Data Modeling Anti-Patterns | Interactive Q + 200 rows: hot partition vs bucketed + multi-tenancy patterns |
| 29 | Latency Comparison | Side-by-side: CL=ONE vs LQ vs ALL extraction |
| 30 | Time-Series Data Modeling | Compound keys, TTL, windowed queries |
| 31 | Compaction Deep Dive | Interactive Q + 4 strategies (STCS/LCS/TWCS/UCS) |
| 32 | Compression Strategies | Interactive Q + LZ4/Zstd/Snappy comparison |
| 33 | Live Failover Under Load (~5 min) | 30 rows survive mid-stream node kill |
| 34 | Multi-DC Write Conflict | Two strategies: parallel + USING TIMESTAMP |
| 35 | Adding a Datacenter Live | Interactive Q + rebuild + multi-cloud mapping + chaos test (rebuild + 2 nodes down) |
| 36 | Backup & Restore | Interactive Q + snapshot, truncate, restore, refresh |
| 37 | Rolling Restart (~8-10 min) | All 3 nodes restarted (seed last), 20 writes succeed |

#### Part 4 — Performance (Modules 38-42)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 38 | Rate Limiting & Thread Pools | Grafana link + 500 parallel inserts move tpstats |
| 39 | Repair Strategies | Interactive Q + pause/write/unpause creates real entropy + Reaper scheduling |
| 40 | Stress Testing | 200 rows, bloom filter stats, latency histogram |
| 41 | Security & Access Control | Syntax-only banner, RBAC + TLS keytool demo |
| 42 | Geographic Visualization | LOCAL_QUORUM trace: zero WAN hops + GDPR data sovereignty patterns |

#### Part 5 — Driver Policies (Modules 43-47)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 43 | Driver Policies | TokenAwarePolicy: coordinator IS the replica |
| 44 | Speculative Execution | Interactive Q + p99 drops to ~p50 with backup requests |
| 45 | Live DC Failover with Driver (~3-5 min) | Zero errors during DC kill, RPO=0/RTO=1-3s |
| 46 | Retry Policies Under Partition | pause+disconnect dual failure, 3 policies compared |
| 47 | Parts 1-5 Checkpoint | Visual recap of Parts 1-5, key production takeaways |

#### Part 6 — Transactions & Patterns (Modules 48-53)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 48 | ACID vs HCD | Tunable consistency spectrum with traced latency |
| 49 | LOGGED vs UNLOGGED BATCH | Batchlog overhead ~30%, crash recovery |
| 50 | Lost Update Problem | LWT CAS prevents concurrent overwrites |
| 51 | Banking: Instant Payment | LWT debit + CDC credit, money conserved + SOX/PCI-DSS/PSD2 compliance |
| 52 | Saga Pattern: Order Flow | Compensating transactions release inventory |
| 53 | Consistency Decision Framework | Decision tree, golden rules, evidence-based positioning framework |

#### Part 7 — Enterprise (Modules 54-61)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 54 | HCD Data API | REST/JSON document access via HTTP:8181, Postman collection, insertOne/find/update/delete |
| 55 | Multi-Tenant Isolation | Tenant ID partition key, RBAC per tenant, GDPR erasure, DC affinity |
| 56 | Node Decommission | Controlled shrink, drain+stop, data verification, decommission vs removenode vs assassinate |
| 57 | Disaster Recovery Runbook | Coordinated multi-node snapshot, truncate+restore, commitlog archival, Medusa |
| 58 | Silent Data Corruption | SSTable CRC corruption, nodetool verify/scrub detection, repair recovery |
| 59 | Cross-Service Saga | Outbox pattern, payment timeout compensation, shipping failure refund, idempotency |
| 60 | LWT Contention Under Load | 5 concurrent writers, Paxos 4-phase tracing, mitigation strategies |
| 61 | Repair Deep-Dive | Merkle tree visualization, gc_grace zombie rows, 4 repair modes, production scheduling |

#### Part 8 — Operational Deep-Dives (Modules 62-71)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 62 | Live RBAC Demo | PasswordAuthenticator, role creation, granular GRANT/REVOKE, permission denial, role inheritance |
| 63 | Encryption at Rest (TDE) | Transparent data encryption config, encrypted SSTables (hexdump), key rotation workflow |
| 64 | Commitlog Durability & Crash Recovery | docker kill (SIGKILL) crash, commitlog replay, zero data loss proof |
| 65 | Hint Expiration & Data Gaps | Hint lifecycle, max_hint_window, expired hints → data gap, repair recovery |
| 66 | Dynamic RF Change | ALTER KEYSPACE RF=1→3, empty replicas, QUORUM failure, repair to populate |
| 67 | Streaming & Bootstrap Monitoring | netstats, bootstrap lifecycle, stream rate limiting, time estimation |
| 68 | Materialized Views | Base table + MV, write-through, consistency risks, write amplification, production caveats |
| 69 | Nodetool Ops Deep-Dive | tablestats, tpstats, proxyhistograms, compactionstats, troubleshooting decision tree |
| 70 | Cross-DC Consistency Window | Network partition between DCs, LOCAL_QUORUM staleness, EACH_QUORUM trade-off |
| 71 | Bloom Filter & Cache Tuning | bloom_filter_fp_chance, key cache hit ratio, row cache, chunk cache, FP trade-offs |

#### Part 9 — DORA Ransomware Resilience (Modules 72-78)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 72 | DORA Ransomware — Kill Chain & Infrastructure Setup | Ransomware kill chain, DORA quiz, dora_bank keyspace, MinIO WORM bucket creation with Object Lock COMPLIANCE |
| 73 | Backup to WORM & Integrity | nodetool snapshot on all nodes, upload to MinIO WORM, SHA-256 integrity verification, deletion attempt blocked by Object Lock |
| 74 | Commitlog Archiving to WORM | commitlog_archiving.properties, WAL segment archiving, two-tier WORM (snapshots + commitlogs), PITR explanation |
| 75 | The Attack Simulation | 5-phase ransomware: recon, exfil, TRUNCATE all tables, clearsnapshot --all, ransom note — WORM backups survive |
| 76 | Recovery from WORM Backups | Integrity verification, SSTable restore from WORM, data verification (5 accounts, 4 transactions), DC2 consistency check |
| 77 | DC Failover Under Attack | dc1 network partition (3 nodes disconnected), dc2 serves at LOCAL_QUORUM, writes during partition, repair reconvergence |
| 78 | DORA Compliance Scorecard & K8s | DORA article mapping (Art. 6,9-13,19,26), Art. 19 incident reporting timeline, 5 recovery paths matrix, K8ssandra CRD + auto-healing |

#### Part 10 — Production Essentials (Modules 79-83)
| Module | Title | Key Proof |
|--------|-------|-----------|
| 79 | Counter Columns | Non-idempotent counters, dedicated counter tables, increment/decrement, counter repair |
| 80 | Prepared Statements & Driver Best Practices | Parse-once execute-many, connection pooling, idempotency flags, driver anti-patterns |
| 81 | JVM & GC Tuning | Heap sizing rules, GC stats, compressed oops, off-heap memory, production tuning checklist |
| 82 | CQL Aggregation & Analytics Functions | COUNT, SUM, AVG, MIN, MAX, GROUP BY, coordinator-side aggregation, UDA, Spark integration |
| 83 | Collection Types Deep-Dive | SET, LIST, MAP, frozen vs non-frozen, partial updates, concurrent semantics, nested collections |

## Cleanup

To stop the cluster and remove data volumes:
```bash
make destroy     # or: docker compose down -v
```

---

## Module 0: Introduction & Cluster Status

The opening module verifies the cluster is healthy, introduces the 6-node, 2-DC topology, and presents a 9-part roadmap of the entire demo.

### 10-Part Roadmap
- **Part 1 — Foundations** (Modules 0-13): Replication, consistency levels, hinted handoff, read repair, anti-entropy repair
- **Part 2 — Advanced Failures** (Modules 14-24): Ghost rack, zombie node, network partition, SAI, vector search, DC kill
- **Part 3 — Operations** (Modules 25-37): CDC, audit logging, guardrails, data modeling, compaction, compression, backup/restore
- **Part 4 — Performance** (Modules 38-42): Stress testing, rate limiting, thread pools
- **Part 5 — Driver Policies** (Modules 43-47): Token-aware routing, speculative execution, DC failover, retry policies
- **Part 6 — Transactions & Patterns** (Modules 48-53): ACID model, batches, LWT, saga patterns, decision framework
- **Part 7 — Enterprise** (Modules 54-61): HCD Data API, multi-tenant isolation, node decommission, disaster recovery, silent data corruption, cross-service saga, LWT contention, repair deep-dive
- **Part 8 — Operational Deep-Dives** (Modules 62-71): RBAC, encryption at rest, commitlog crash recovery, hint expiration, dynamic RF change, streaming, materialized views, nodetool ops, cross-DC consistency, bloom filter & cache tuning
- **Part 9 — DORA Ransomware Resilience** (Modules 72-78): Kill chain, WORM backups (MinIO Object Lock), commitlog archiving, ransomware attack simulation, recovery from WORM, DC failover under attack, DORA compliance scorecard, K8ssandra auto-healing
- **Part 10 — Production Essentials** (Modules 79-83): Counter columns, prepared statements, JVM/GC tuning, CQL aggregations, collection types deep-dive

### What You'll Learn
- How to verify cluster health with `nodetool status`
- The meaning of `UN` (Up/Normal) status flags
- How a 6-node demo cluster maps to production architectures (same gossip, same repair, same consistency — only scale differs)

### Key Commands
```bash
# Check cluster status
docker exec hcd-node1 nodetool status

# Verify all 6 nodes show UN
docker exec hcd-node1 nodetool status | grep '^UN' | wc -l
```

### Takeaway
A 6-node, 2-DC cluster on a laptop is architecturally identical to a 600-node production deployment. Every gossip protocol, repair mechanism, and consistency guarantee demonstrated here works the same way at scale.

---

## Module 1: Understanding Replication Factors (RF)

RF determines how many copies of your data exist.

### Exercise: Create Keyspaces
```sql
-- RF=1: No redundancy. If one node fails, data is lost.
CREATE KEYSPACE rf_low WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 1};

-- RF=3: Production standard. Can survive 1 node failure per DC with QUORUM.
CREATE KEYSPACE rf_prod WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3, 'dc2': 3};
```

### Visualizing Endpoints
Check which specific nodes hold a piece of data for a specific partition key:
```bash
docker exec hcd-node1 nodetool getendpoints rf_prod health 1
# Expected output: 6 IPs (3 in DC1, 3 in DC2)
```

---

## Module 2: Consistency Levels (CL) Deep Dive

CL defines how many replicas must acknowledge a read or write for it to be considered successful. The demo kills a dc1 node then tests each CL to show which survive and which fail.

| Level | Nodes Required | Latency | Availability | Use Case |
|-------|----------------|---------|--------------|----------|
| **ONE** | 1 | Lowest | Highest | Logging, IoT telemetry |
| **QUORUM** | (RF/2)+1 total | Medium | Balanced | General purpose |
| **LOCAL_QUORUM** | (RF/2)+1 in local DC | Low (No WAN) | High | Most multi-DC apps |
| **EACH_QUORUM** | (RF/2)+1 in EVERY DC | High (WAN) | Lower | Critical global sync |

**What to look for:** ONE, LOCAL_QUORUM, QUORUM succeed even with a node down. EACH_QUORUM fails because the downed dc1 node cannot provide its quorum share. After restarting the node, EACH_QUORUM is re-tested to prove recovery.

---

## Module 3: Simulating Node Failures

The demo poses an interactive question before revealing the result: **"Will LOCAL_QUORUM reads succeed with one node down?"** — pause — then proves the answer with a live query.

### Scenario A: Single Node Failure
```bash
docker compose stop hcd-node3
docker exec hcd-node1 nodetool status | grep "DN"
# LOCAL_QUORUM still works: 2 of 3 replicas available
```

### Scenario B: Rack Failure
```bash
# Stop Rack 1 in both DCs
docker compose stop hcd-node1 hcd-node4
```

---

## Module 4: Hinted Handoff — Short-term Entropy Resolution

### Writing While a Node is Down
1. Stop `hcd-node2`.
2. Write data using `CONSISTENCY ONE`.
3. Node 1 sees Node 2 is down and saves a "Hint".
4. Check hints directory: `docker exec hcd-node1 ls -R /var/lib/cassandra/hints/`.
5. Start `hcd-node2`. Node 1 will replay hints automatically.

**What to look for:** Row count before = row count after. The hints directory empties once replay completes. Hints expire after 3 hours (`max_hint_window_in_ms`).

---

## Module 5: Read Repair - Triggering On-the-fly Synchronization

Read repair is HCD's mechanism for detecting and fixing stale data at read time. The coordinator sends a digest request to replicas alongside the full data request. If digests don't match, a background repair is triggered.

> **Note:** In Cassandra 4.0+, read repair is background and probabilistic — it is NOT guaranteed on every read. To reliably demonstrate it, the script forces divergence by stopping a node, writing, then restarting it.

```text
Client ──► Coordinator (node1)
               │
               ├── Full data request ──► Replica A (returns full data)
               ├── Digest request   ──► Replica B (returns hash only)
               └── Digest request   ──► Replica C (returns hash only)
               │
               ▼
          Compare digests
               │
       ┌───────┴───────┐
     Match?          Mismatch?
       │                 │
    Return data     Request full data
                    from all replicas,
                    send corrections
```

**Demo steps (guaranteed divergence):**
1. Stop node3 (`docker compose stop hcd-node3`)
2. Write at CL=ONE while node3 is down — node3 misses the write
3. Restart node3 — it has stale data
4. Read at CL=ALL — coordinator detects digest mismatch
5. Verify node3 has the data after background repair

**What to look for in the trace:**
- "Digest mismatch" or "READ_REPAIR" messages
- "Read-repair mutation" sent to the stale replica
- After repair: reading from node3 at CL=ONE returns the correct data

---

## Module 6: Anti-Entropy Repair & Three-Layer Defense Recap

Runs `nodetool repair` with Merkle Tree comparison and summarizes HCD's three-layer entropy defense.

### The Three-Layer Defense
| Layer | Mechanism | Timing | Scope |
|-------|-----------|--------|-------|
| **Layer 1** | Hinted Handoff | Immediate (seconds) | Single missed write |
| **Layer 2** | Read Repair | Opportunistic (on read) | Single partition |
| **Layer 3** | Anti-Entropy Repair | Scheduled (hours/days) | Full token range |

```bash
# Run primary-range repair (recommended for regular maintenance)
docker exec hcd-node1 nodetool repair -pr rf_prod
```

**Estimated time:** ~2-3 minutes for repair to complete on this small dataset.

**Takeaway:** These three layers form a defense-in-depth: HH catches immediate misses, read repair fixes staleness on access, and scheduled repair guarantees 100% consistency across the full token range. No single mechanism is sufficient alone.

---

## Module 7: Token Ring - Visualizing the Topology

Each node owns a range of tokens on a circular hash space (the "ring"). HCD uses the Murmur3 partitioner to hash each partition key into a 64-bit token. The node owning that token range is the primary replica; data is then copied to the next N-1 nodes clockwise (where N = RF).

With `num_tokens: 256` (vnodes), each node owns 256 small, non-contiguous ranges scattered around the ring. This improves load balancing and makes adding/removing nodes more efficient.

```text
           Token 0
             │
    Node6 ───┤─── Node1    ← Each node owns 256 token ranges
   /         │         \      scattered around this ring
  Node5      │        Node2
   \         │         /
    Node4 ───┤─── Node3
             │
        Token 2^63
```

```bash
# View the full token ring (each vnode range)
docker exec hcd-node1 nodetool ring | head -20

# Count how many token ranges each node owns
docker exec hcd-node1 nodetool ring | grep -c "172.28.0.2"
# Expected: ~256 (vnodes per node)

# View ownership percentages
docker exec hcd-node1 nodetool status
# Each node should own ~16.7% (1/6) of the ring
```

**What to look for:** With 6 nodes and 256 vnodes each, the ring has 1536 total ranges. Ownership should be roughly equal (~16-17% per node).

---

## Module 8: Write Path Trace

Traces the full lifecycle of a LOCAL_QUORUM write to reveal coordinator selection, replica forwarding, and acknowledgment timing.

```sql
TRACING ON;
CONSISTENCY LOCAL_QUORUM;
INSERT INTO rf_prod.health (id, status) VALUES (100, 'traced-write');
TRACING OFF;
```

**What to look for in the trace output:**
- Coordinator node selection
- "Sending mutation" messages to local replicas
- "Forwarding write" to remote DC
- Acknowledgment timestamps showing LOCAL_QUORUM latency

---

## Module 9: Read Path Trace

Traces a read operation to show the digest request optimization: the coordinator asks one replica for full data and others for lightweight digests, comparing them to detect staleness.

```sql
TRACING ON;
CONSISTENCY LOCAL_QUORUM;
SELECT * FROM rf_prod.health WHERE id = 100;
TRACING OFF;
```

**What to look for:**
- "Sending read" vs "Sending digest request" messages
- Digest comparison step
- Read repair triggered if digests mismatch

---

## Module 10: Node Recovery — The Full Picture

Interactive question: **"After a node restarts, how does it know what data it missed?"** — pause — answer: other coordinators stored hints during the outage, and gossip triggers automatic replay.

Demonstrates what happens when a downed node returns: pending hints are automatically replayed, synchronizing the node without a full repair.

1. Stop node3: `docker compose stop hcd-node3`
2. Write data while node3 is down
3. Restart node3: `docker compose start hcd-node3`
4. Watch hints replay in the logs: `docker compose logs -f hcd-node3`
5. Verify data is consistent across all replicas

**What to look for:** In the node3 logs, messages like "Finished hinted handoff" or "Replaying hints". Row count on node3 matches the other replicas after replay completes.

---

## Module 11: Tombstones - Deletes as Writes

In HCD, deletes don't erase data — they write a **Tombstone** marker with a timestamp. This is necessary because SSTables are immutable on disk. Tombstones propagate to all replicas and are physically removed during compaction after `gc_grace_seconds` (default: 864000 seconds = 10 days).

```text
Timeline of a Delete:
  T1: INSERT id=1 val='hello'  ──► Written to SSTable-A
  T2: DELETE id=1              ──► Tombstone written to SSTable-B
  T3: SELECT id=1              ──► SSTable-A + SSTable-B merged, tombstone wins → empty result
  T4: Compaction               ──► If gc_grace passed, both entries physically removed
```

```sql
-- Delete creates a tombstone
DELETE FROM rf_prod.health WHERE id = 1;

-- Verify with tracing
TRACING ON;
SELECT * FROM rf_prod.health WHERE id = 1;
-- Empty result, but the tombstone exists on disk
TRACING OFF;
```

**Why gc_grace_seconds matters:** If you compact and remove a tombstone before all replicas have seen it, the old data can "resurrect" — reappear on a replica that missed the delete. This is why `gc_grace_seconds` defaults to 10 days: it gives repair enough time to propagate the tombstone everywhere.

---

## Module 12: Lightweight Transactions (LWT)

LWT provides linearizable consistency using the Paxos protocol. Unlike normal writes (which are "last-write-wins"), LWT performs a read-before-write to ensure conditional updates.

```sql
-- Book a seat only if not already taken (compare-and-set)
INSERT INTO rf_prod.tickets (seat_id, owner) VALUES ('A1', 'Alice')
IF NOT EXISTS;

-- Second attempt fails
INSERT INTO rf_prod.tickets (seat_id, owner) VALUES ('A1', 'Bob')
IF NOT EXISTS;
-- Returns: [applied: false, seat_id: 'A1', owner: 'Alice']
```

**Trade-off:** LWT is 4x slower than normal writes due to the Paxos round-trips (Prepare → Promise → Accept → Commit). Use only when correctness requires it (inventory, reservations, counters).

---

## Module 13: Summary & Health Check

A checkpoint module that verifies the cluster is healthy before proceeding to advanced scenarios.

```bash
docker exec hcd-node1 nodetool status
# All 6 nodes should show UN (Up/Normal)
docker exec hcd-node1 nodetool describecluster
# Schema versions should show a single version across all nodes
```

---

## Module 14: The "Ghost Rack" (Double Rack Failure)

Interactive question: **"Can the cluster still serve reads with 2 of 6 nodes dead?"** — pause — then proves it.

Simulates simultaneous failure of Rack 1 in both DCs — a scenario where 2 of 6 nodes go down at once. With RF=3 and `NetworkTopologyStrategy`, data remains available because each DC still has 2 replicas in Racks 2 and 3.

```text
DC1                          DC2
┌────────┬────────┬────────┐ ┌────────┬────────┬────────┐
│ Rack 1 │ Rack 2 │ Rack 3 │ │ Rack 1 │ Rack 2 │ Rack 3 │
│  DEAD  │   OK   │   OK   │ │  DEAD  │   OK   │   OK   │
│ node1  │ node2  │ node3  │ │ node4  │ node5  │ node6  │
└────────┴────────┴────────┘ └────────┴────────┴────────┘
```

```bash
# Kill Rack 1 in both DCs
docker compose stop hcd-node1 hcd-node4

# Verify: LOCAL_QUORUM still succeeds (2 of 3 replicas per DC alive)
docker exec hcd-node2 cqlsh -e "CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.health;"

# Restore
docker compose start hcd-node1 hcd-node4
```

**Why this works:** `NetworkTopologyStrategy` places one replica per rack. With 3 racks per DC, losing Rack 1 leaves 2 replicas alive — still enough for LOCAL_QUORUM (requires 2 of 3).

---

## Module 15: Schema Disagreement

Interactive question: **"If a node was down during a CREATE TABLE, what happens when it comes back?"** — pause — answer: Gossip propagates schema changes within seconds.

Shows what happens when nodes have different schema versions — typically caused by a schema change that hasn't fully propagated. HCD's gossip protocol detects this and resolves it automatically.

```bash
# Check for schema agreement (most precise method)
docker exec hcd-node1 nodetool describecluster | grep -A 5 "Schema versions"

# Cross-check via system.peers
docker exec hcd-node1 cqlsh -e "SELECT peer, schema_version FROM system.peers;"

# If disagreement exists, force schema pull
docker exec hcd-node1 nodetool resetlocalschema
```

---

## Module 16: Gossip Protocol Deep Dive

Gossip is HCD's peer-to-peer failure detection and metadata propagation mechanism. Every second, each node picks 1-3 random peers and exchanges state information.

```bash
# View gossip state for all known peers
docker exec hcd-node1 nodetool gossipinfo

# Key fields to inspect:
# - HEARTBEAT: incrementing counter (proves node is alive)
# - STATUS: NORMAL, BOOT, LEAVING, etc.
# - DC/RACK: datacenter and rack assignment
# - SCHEMA: schema version hash
```

---

## Module 17: The "Zombie Node" (Network Partition)

Interactive question: **"Can the cluster write while a node is partitioned?"** — pause — then proves it.

Simulates a network partition by disconnecting a node from the Docker network. The node is still running but unreachable — a "zombie" from the cluster's perspective. Gossip will mark it as DOWN.

> **Note:** The script dynamically resolves the Docker network name via `docker network ls --filter "name=hcd-cluster"`. This works regardless of the project directory name.

```bash
# Resolve the network name dynamically
HCD_NETWORK=$(docker network ls --filter "name=hcd-cluster" --format '{{.Name}}' | head -1)

# Partition node2 from the network
docker network disconnect "$HCD_NETWORK" hcd-node2

# Watch gossip detect the failure (takes ~10-30 seconds)
docker exec hcd-node1 nodetool status
# node2 transitions from UN to DN

# Heal the partition
docker network connect "$HCD_NETWORK" hcd-node2
# node2 transitions back to UN
```

**What to look for:** After disconnect, `nodetool status` shows node2 as DN (Down/Normal). Writes at LOCAL_QUORUM still succeed because 2 of 3 dc1 replicas remain. After reconnect, node2 returns to UN and receives missed writes via hinted handoff.

---

## Module 18: Storage Attached Indexing (SAI) - Deep Dive

SAI (Storage Attached Indexing) stores index structures alongside data in SSTables, unlike legacy 2i indexes which maintain separate hidden tables.

### SAI vs Legacy 2i
```text
Legacy 2i:  Data SSTable ──► Separate Hidden Index Table (extra write amplification)
SAI:        Data SSTable ──► Embedded Index Component (collocated, no extra tables)
```

### SAI Architecture
```text
SSTable on Disk
┌─────────────────────────────────────────────────────────────────┐
│ [ Data Component ]   [ Index Component (SAI) ]                  │
│ Row 1: {id:A, val:1} ──► BitMap/Trie Index (val:1 -> Row A)      │
└─────────────────────────────────────────────────────────────────┘
```

### Code Examples
```sql
CREATE TABLE rf_prod.assets (
    id uuid PRIMARY KEY,
    name text,
    category text,
    value int,
    tags map<text, text>
);

CREATE CUSTOM INDEX ON rf_prod.assets (category) USING 'StorageAttachedIndex';
CREATE CUSTOM INDEX ON rf_prod.assets (value) USING 'StorageAttachedIndex';

-- Advanced Indexing (Map Entries & Analyzers)
CREATE CUSTOM INDEX ON rf_prod.assets (ENTRIES(tags)) USING 'StorageAttachedIndex';
CREATE CUSTOM INDEX ON rf_prod.products (name) USING 'StorageAttachedIndex'
WITH OPTIONS = {'case_sensitive': 'false', 'normalize': 'true'};

-- Composable Querying (multiple SAI indexes in one WHERE clause)
SELECT * FROM rf_prod.assets WHERE category = 'hardware' AND value > 1000;

-- Inspect SAI index metadata via virtual tables
SELECT * FROM system_views.indexes;
```

---

## Module 19: Native JSON Operations - Deep Dive

HCD's native JSON support provides document-database flexibility with schema enforcement.

### Syntax Reference
```sql
-- Insert
INSERT INTO assets JSON '{"id": "...", "name": "Server-X", "value": 500}';

-- Select
SELECT JSON name, value FROM assets WHERE category = 'hardware';

-- Surgical Updates (Partial JSON — DEFAULT UNSET leaves other columns unchanged)
INSERT INTO assets JSON '{"id": "...", "value": 999}' DEFAULT UNSET;

-- TTL and Batches
INSERT INTO assets JSON '{"id": "...", "name": "Temp"}' USING TTL 3600;
BEGIN BATCH
  INSERT INTO assets JSON '...';
  INSERT INTO assets JSON '...';
APPLY BATCH;
```

### Module 19 — Enterprise Pattern Reference

#### Sub-section 9: UDT + Nested JSON (Document Modeling)
```sql
-- User-Defined Types for nested structures
CREATE TYPE rf_prod.address (street text, city text, state text, zip text, country text);
CREATE TYPE rf_prod.line_item (product_name text, quantity int, unit_price decimal);

CREATE TABLE rf_prod.orders (
    order_id uuid,
    customer_name text,
    shipping_address frozen<rf_prod.address>,
    items frozen<list<frozen<rf_prod.line_item>>>,
    order_total decimal, status text,
    PRIMARY KEY (order_id)
);

-- Nested JSON insert: UDT fields become JSON objects, lists become JSON arrays
INSERT INTO rf_prod.orders JSON '{"order_id": "...",
  "shipping_address": {"street": "123 Main St", "city": "Austin", ...},
  "items": [{"product_name": "SSD 1TB", "quantity": 2, "unit_price": 89.99}]}';

-- Schema enforced: unknown UDT fields (e.g., "phone") are rejected
-- Key constraint: frozen<> means atomic replacement — no partial UDT updates
```

#### Sub-section 10: JSON Document Versioning (Audit Trail Pattern)
```sql
CREATE TABLE rf_prod.document_versions (
    doc_id uuid,
    version timeuuid,
    author text, content text, metadata text,
    PRIMARY KEY (doc_id, version)
) WITH CLUSTERING ORDER BY (version DESC);

-- Latest version (DESC = newest first, single-row read):
SELECT JSON * FROM rf_prod.document_versions WHERE doc_id = ... LIMIT 1;

-- Full history (all versions, newest to oldest):
SELECT JSON version, author, metadata FROM rf_prod.document_versions WHERE doc_id = ...;

-- INSERT JSON cannot use CQL functions like now() — use standard INSERT for timeuuid
-- Combine with CDC (Module 25) for real-time change notifications
-- Add TTL to old versions for automatic cleanup
```

#### Sub-section 11: Event Sourcing with JSON Payloads
```sql
CREATE TABLE rf_prod.event_store (
    aggregate_id uuid,
    event_id timeuuid,
    event_type text,
    payload text,          -- JSON string: flexible schema per event type
    PRIMARY KEY (aggregate_id, event_id)
);

-- Domain events: OrderCreated → ItemAdded → PaymentProcessed → OrderShipped
-- Each event is immutable — replay events to reconstruct any past state
-- payload as text (not UDT) because each event type has different fields

-- Architecture: App → event_store → CDC → Kafka → {Search, Cache, Alerts}
-- This is the CQRS pattern — see Module 25 (CDC) and Module 51 (banking)
```

#### Sub-section 12: Bulk JSON & Performance
```
INSERT method         Round-trips  Use when
──────────────────────────────────────────────────────────────
INSERT JSON           1 per row    REST API, individual writes
UNLOGGED BATCH+JSON   1 total      Same-partition bulk (≤30 rows)
Prepared statements   1 per row    Max throughput (skips JSON parsing)
COPY FROM (CSV/JSON)  bulk         Initial data load, migration

Rule: JSON parsing adds ~0.1ms vs 2-5ms total latency — negligible <10K writes/sec
UNLOGGED BATCH is safe ONLY for same-partition writes (see Module 49)
```

#### Sub-section 13: JSON + SAI Composable Queries
```sql
CREATE TABLE rf_prod.catalog (
    product_id uuid PRIMARY KEY,
    name text, brand text, category text,
    price decimal, in_stock boolean,
    specs map<text, text>
);

-- SAI indexes on brand, category, price, in_stock, ENTRIES(specs)
-- Composable JSON queries (no ALLOW FILTERING needed):
SELECT JSON * FROM rf_prod.catalog WHERE category = 'laptop' AND price < 1200;
SELECT JSON name, brand, price FROM rf_prod.catalog WHERE specs['ram'] = '12GB';
SELECT JSON * FROM rf_prod.catalog WHERE in_stock = true AND category = 'phone';

-- The "JSON API" pattern: POST→INSERT JSON, GET→SELECT JSON with SAI filters
-- No ORM, no serialization layer — JSON in, JSON out
```

### Design Best Practices
1. **Schema First**: Define table schema precisely — use UDTs for nested structures.
2. **Collections**: Maps and Lists for dynamic data; index with SAI `ENTRIES()`.
3. **Primary Keys**: Must always be provided in the JSON object.
4. **Versioning**: Use timeuuid clustering (DESC) for audit trails and document history.
5. **Event Sourcing**: JSON payloads in text columns + CDC = reactive CQRS architecture.
6. **Performance**: UNLOGGED BATCH for same-partition bulk writes; JSON parsing overhead is negligible for most workloads. Switch to prepared statements above 10K writes/sec.
7. **frozen<> Trade-off**: Faster reads and simpler storage, but requires full UDT replacement on update.

---

## Module 20: Vector Search & AI Readiness (SAI Vector)

HCD leverages SAI to provide native Vector Search capabilities, enabling Retrieval-Augmented Generation (RAG) and semantic search directly within the database.

### The Vector Data Type
HCD introduces the `vector<float, n>` type (requires HCD 1.2+ with vector support, based on the Cassandra 5.0 vector type). Unlike standard columns, vector columns are searched using Approximate Nearest Neighbor (ANN) algorithms via SAI.

> **Compatibility:** If your HCD version doesn't support `vector<float, N>`, the script will detect this and skip the module with a clear message. Check your version with `nodetool version`.

### Code Examples

```sql
-- Create a table for AI embeddings (5-dimensional vectors)
CREATE TABLE rf_prod.documents (
    id uuid PRIMARY KEY,
    title text,
    content text,
    category text,
    embedding vector<float, 5>
);

-- Create a Vector Index with cosine similarity
CREATE CUSTOM INDEX ON rf_prod.documents (embedding)
USING 'StorageAttachedIndex'
WITH OPTIONS = {'similarity_function': 'cosine'};

-- Create a Metadata Index for Hybrid Search
CREATE CUSTOM INDEX ON rf_prod.documents (category)
USING 'StorageAttachedIndex';

-- Semantic Search (find documents similar to a query vector)
SELECT title, content FROM rf_prod.documents
ORDER BY embedding ANN OF [0.9, 0.1, 0.8, 0.2, 0.7]
LIMIT 3;

-- Hybrid Search (Vector + Metadata Filtering)
SELECT title, similarity_cosine(embedding, [0.9, 0.1, 0.8, 0.2, 0.7]) as score
FROM rf_prod.documents
WHERE category = 'tech'
ORDER BY embedding ANN OF [0.9, 0.1, 0.8, 0.2, 0.7]
LIMIT 3;
```

The demo inserts 15 documents across 3 semantic clusters (database, AI/ML, networking) and shows how vector similarity groups them correctly.

---

## Module 21: Mixed Real-time Operations (The Mutation Model)

In HCD, there is no fundamental difference between `INSERT` and `UPDATE` at the storage layer. Both are treated as **Mutations**. This is the key insight that distinguishes HCD from traditional RDBMS.

### The "Upsert" Nature
HCD does not perform a "Read-Before-Write". When you issue an `INSERT` or `UPDATE`, the node simply appends the new data (with a timestamp) to the Memtable. This makes writes incredibly fast.

### Data Resolution (LWW)
During a `SELECT` operation, HCD retrieves all versions of the data from different SSTables and replicas, then applies **Last-Write-Wins (LWW)** logic based on the timestamp to return the correct value.

### Deletes as Writes (Tombstones)
When you `DELETE` data, HCD writes a special marker called a **Tombstone**. This is necessary because HCD is immutable on disk; you cannot "erase" data from an existing SSTable. The Tombstone ensures that older versions of the data (with earlier timestamps) do not reappear during a compaction or read.

### Code Examples
```sql
-- These two are functionally identical if the row exists:
INSERT INTO stream (id, val) VALUES (1, 'A');
UPDATE stream SET val = 'A' WHERE id = 1;

-- Batching different operations together:
BEGIN UNLOGGED BATCH
  INSERT INTO stream (id, val) VALUES (10, 'new');
  UPDATE stream SET val = 'changed' WHERE id = 11;
  DELETE FROM stream WHERE id = 12;
APPLY BATCH;
```

---

## Module 22: Compaction - The Physical Resolution of Entropy

Compaction is the background process that merges SSTables, resolves overwritten values by comparing timestamps (LWW), and physically removes data marked with Tombstones once they have exceeded `gc_grace_seconds`.

In this module, we trigger a manual compaction to see multiple SSTables merge into a single optimized file.

```bash
# View current SSTables
docker exec hcd-node1 nodetool cfstats rf_prod.stream

# Force compaction
docker exec hcd-node1 nodetool compact rf_prod stream

# Verify SSTable count decreased
docker exec hcd-node1 nodetool cfstats rf_prod.stream
```

---

## Module 23: Kill an Entire Datacenter (Multi-DC Failover)

This is the "wow moment" of the demo (~5-8 minutes). We prove zero-downtime cross-DC failover through a 5-step sequence:

```text
Step 1: Insert 20 rows via dc1     Step 2: Kill ALL of dc1
┌──────┐  ┌──────┐                  ┌──────┐  ┌──────┐
│ DC1  │  │ DC2  │                  │ DC1  │  │ DC2  │
│ 20   │──│ 20   │  (replicated)    │ DEAD │  │ 20   │  ← still has all data
│ rows │  │ rows │                  │      │  │ rows │
└──────┘  └──────┘                  └──────┘  └──────┘

Step 3: Read from dc2 (success!)   Step 4: Write 10 new rows from dc2
LOCAL_QUORUM → 20 rows returned     dc2 stores rows 21-30 + hints for dc1

Step 5: Restart dc1
dc1 receives hints → all 30 rows on all nodes
```

```sql
-- Create test table
CREATE TABLE rf_prod.dc_failover (id int PRIMARY KEY, msg text, written_from text);

-- Insert 20 rows from dc1
INSERT INTO rf_prod.dc_failover (id, msg, written_from) VALUES (1, 'row-1', 'dc1');
-- ... (20 rows total)

-- Kill dc1: docker compose stop hcd-node1 hcd-node2 hcd-node3

-- Read from dc2 (all data present)
CONSISTENCY LOCAL_QUORUM; SELECT count(*) FROM rf_prod.dc_failover;

-- Write from dc2 during outage
INSERT INTO rf_prod.dc_failover (id, msg, written_from) VALUES (21, 'during-outage', 'dc2');

-- Restore dc1: docker compose start hcd-node1 hcd-node2 hcd-node3
-- dc1 sees all data including rows written during outage
```

---

## Module 24: Grand Finale - The Self-Healing Database

Three escalating failure scenarios demonstrating HCD's resilience:

| Act | Failure | Resolution | Proof |
|-----|---------|------------|-------|
| 1 | Kill node3 | Hinted Handoff | Row count match after restart |
| 2 | Kill entire dc1 | Cross-DC reads | LOCAL_QUORUM from dc2 |
| 3 | Restore dc1 + repair | Anti-Entropy Repair | All nodes UN, full row count |

---

## Module 25: CDC (Change Data Capture)

CDC captures every mutation as an event for downstream systems. When enabled on a table, every write is recorded to commitlog segments in `/var/lib/cassandra/cdc_raw/`, ready for consumption by event pipelines.

### Prerequisites
CDC must be enabled globally in `cassandra.yaml` (`cdc_enabled: true`) and per-table (`WITH cdc = true`). The demo cluster has CDC pre-enabled in the configuration template.

### CDC Segment Inspection
The demo uses `strings` to peek at raw CDC segment contents, proving mutations are captured at the binary level:
```bash
docker exec hcd-node1 bash -c "strings /var/lib/cassandra/cdc_raw/*.log 2>/dev/null | grep -i cdc | head -5"
```

### Architecture
```text
Client Write ──► Memtable ──► CommitLog ──► CDC Segment
                                              │
                                              ▼
                                    /var/lib/cassandra/cdc_raw/
                                              │
                                              ▼
                                    External Consumer (Kafka, Pulsar, etc.)
```

### Code Examples
```sql
-- Create a CDC-enabled table
CREATE TABLE rf_prod.events (
    id uuid PRIMARY KEY,
    event_type text,
    payload text
) WITH cdc = true;

-- Write events (automatically captured to CDC segments)
INSERT INTO rf_prod.events (id, event_type, payload)
VALUES (uuid(), 'user_signup', '{"email": "alice@example.com"}');

-- Verify CDC is active on the table
SELECT table_name, cdc FROM system_schema.tables
WHERE keyspace_name = 'rf_prod' AND table_name = 'events';
```

```bash
# Check CDC segments on disk
docker exec hcd-node1 ls -la /var/lib/cassandra/cdc_raw/
```

**What to look for:** After writing events, new segment files appear in `cdc_raw/`. In production, a CDC consumer (like Debezium or a custom reader) would process and delete these segments.

---

## Module 26: Audit Logging

Enterprise audit logging tracks all CQL operations for compliance. HCD can log every SELECT, INSERT, UPDATE, DELETE to a file, with filtering by category, keyspace, or user.

### Prerequisites
Audit logging is configured in `cassandra.yaml` under `audit_logging_options` but disabled by default. It is enabled/disabled at runtime via `nodetool`. The demo pre-checks `cassandra.yaml` for the `audit_logging_options` section and searches multiple log directories (`/var/log/cassandra/`, `/opt/hcd/logs/`) for audit output.

### Usage
```bash
# Enable audit logging
docker exec hcd-node1 nodetool enableauditlog

# Run some operations that will be captured
docker exec hcd-node1 cqlsh -e "SELECT * FROM rf_prod.health;"
docker exec hcd-node1 cqlsh -e "INSERT INTO rf_prod.health (id, status) VALUES (999, 'audit-test');"

# Check audit logs
docker exec hcd-node1 cat /var/lib/cassandra/audit/audit.log

# Disable audit logging
docker exec hcd-node1 nodetool disableauditlog
```

### What gets logged
| Category | Operations | Example |
|----------|-----------|---------|
| QUERY | SELECT statements | `SELECT * FROM rf_prod.health` |
| DML | INSERT, UPDATE, DELETE | `INSERT INTO rf_prod.health ...` |
| DDL | CREATE, ALTER, DROP | `CREATE TABLE rf_prod.new_table ...` |
| AUTH | LOGIN, permission changes | `GRANT SELECT ON rf_prod.health TO user` |

**What to look for:** The audit log shows timestamped entries with the CQL statement, source IP, keyspace, and operation category. This is essential for SOC2/HIPAA compliance.

---

## Module 27: Guardrails

HCD guardrails prevent common anti-patterns that cause performance degradation or outages in production. They act as safety nets configured via `cassandra.yaml`.

### Key Guardrails

| Guardrail | Warn Threshold | Fail Threshold | Purpose |
|-----------|---------------|----------------|---------|
| Batch size | 5 KB | 50 KB | Prevent coordinator overload |
| Collection size | 100 KB | -- | Prevent partition bloat |
| Tables per keyspace | 150 | -- | Prevent metadata bloat |
| Columns per table | 100 | -- | Prevent wide-row anti-patterns |
| Unlogged batch across partitions | 10 | -- | Prevent scatter-gather batches |

```bash
# View current guardrail configuration
docker exec hcd-node1 grep -i 'warn_threshold\|fail_threshold' \
  /opt/hcd/resources/cassandra/conf/cassandra.yaml
```

```sql
-- Trigger a batch size warning (intentionally large batch of 50 rows)
BEGIN UNLOGGED BATCH
  INSERT INTO rf_prod.health (id, status) VALUES (1000, 'guardrail-test-1');
  -- ... 49 more rows ...
APPLY BATCH;
```

**What to look for:** The batch triggers a WARN log message if it exceeds 5KB or a failure if it exceeds 50KB. Check `docker compose logs hcd-node1` for "Batch ... is too large" warnings.

---

## Module 28: Data Modeling Anti-Patterns

The #1 mistake in Cassandra/HCD is poor partition key design. A bad key creates "hot partitions" — a single node drowning in traffic while others sit idle.

```text
BAD:  PRIMARY KEY (date)              → All writes for one day hit ONE partition
GOOD: PRIMARY KEY ((date, bucket), ts) → Writes spread across N buckets per day
```

The demo inserts 200 rows with 500-byte payloads to make hot partition effects visible, then compares with a bucketed design.

> **Production context:** In real systems, hot partitions involve 500M+ rows and 80GB+ partitions. The 200-row demo uses the same mechanics at observable scale.

```sql
-- Bad model: single partition per day
CREATE TABLE rf_prod.bad_model (
    date text, event_id timeuuid, data text,
    PRIMARY KEY (date, event_id)
);

-- Good model: bucketed partitions
CREATE TABLE rf_prod.good_model (
    date text, bucket int, event_id timeuuid, data text,
    PRIMARY KEY ((date, bucket), event_id)
);
```

**What to look for:** Compare `nodetool tablestats` — the bad model has one massive partition; the good model spreads data across 5 smaller partitions. Rule of thumb: keep partitions under 100MB and 100K rows.

---

## Module 29: Latency Comparison

Traces the same write at three consistency levels to show the latency/availability trade-off.

```sql
TRACING ON;
CONSISTENCY ONE;
INSERT INTO rf_prod.health (id, status) VALUES (200, 'cl-one');
-- Fastest: only 1 replica ack needed

CONSISTENCY LOCAL_QUORUM;
INSERT INTO rf_prod.health (id, status) VALUES (201, 'cl-lq');
-- Medium: 2 of 3 local replicas

CONSISTENCY EACH_QUORUM;
INSERT INTO rf_prod.health (id, status) VALUES (202, 'cl-eq');
-- Slowest: quorum in EVERY DC (WAN latency)
TRACING OFF;
```

The demo also traces **reads** at CL=ONE, LOCAL_QUORUM, and ALL to show latency differences:

**What to look for:** The demo extracts `Request complete` timing from each trace and displays a side-by-side comparison box. Writes use EACH_QUORUM (valid for writes, requires quorum in every DC). Reads use ALL (waits for all 6 replicas) since EACH_QUORUM is write-only in Cassandra. ONE completes in microseconds, LOCAL_QUORUM in low milliseconds, ALL/EACH_QUORUM adds WAN round-trip time.

---

## Module 30: Time-Series Data Modeling

Demonstrates proper time-series design with compound partition keys, TTL, and windowed queries.

```sql
CREATE TABLE rf_prod.sensor_data (
    sensor_id text,
    day_bucket text,
    ts timestamp,
    value double,
    PRIMARY KEY ((sensor_id, day_bucket), ts)
) WITH CLUSTERING ORDER BY (ts DESC)
  AND default_time_to_live = 86400;
```

**What to look for:** Each sensor+day combination is a bounded partition. TTL auto-expires old data. Queries within a day-bucket are efficient sequential reads.

---

## Module 31: Compaction Deep Dive

Creates four tables with different compaction strategies and compares their SSTable behavior.

```text
STCS (Size-Tiered)     LCS (Leveled)          TWCS (Time-Window)     UCS (Unified)
┌───┐ ┌───┐ ┌───┐     L0: ┌─┐┌─┐┌─┐         Window 1: ┌───────┐   Adaptive hybrid
│ S │ │ M │ │ L │     L1: ┌──────────┐       Window 2: ┌───────┐   that auto-tunes
└───┘ └───┘ └───┘     L2: ┌────────────────┐  Window 3: ┌───────┐   based on workload
Similar sizes merge     Fixed-size levels     Time-bounded windows
Best: write-heavy      Best: read-heavy       Best: TTL/time-series   Best: mixed/default
```

```sql
CREATE TABLE rf_prod.compact_stcs (...) WITH compaction = {'class': 'SizeTieredCompactionStrategy'};
CREATE TABLE rf_prod.compact_lcs  (...) WITH compaction = {'class': 'LeveledCompactionStrategy'};
CREATE TABLE rf_prod.compact_twcs (...) WITH compaction = {'class': 'TimeWindowCompactionStrategy', 'compaction_window_size': '1', 'compaction_window_unit': 'MINUTES'};
CREATE TABLE rf_prod.compact_ucs  (...) WITH compaction = {'class': 'UnifiedCompactionStrategy'};
```

**What to look for:** After inserting data and flushing, compare SSTable counts and sizes via `nodetool tablestats`. STCS accumulates more SSTables; LCS maintains fixed-size levels; TWCS groups by time window.

---

## Module 32: Compression Strategies

Compares on-disk compression algorithms and their trade-offs.

| Algorithm | Ratio | Speed | CPU | Use Case |
|-----------|-------|-------|-----|----------|
| LZ4 | Good | Fastest | Low | Default, general purpose |
| Zstd | Best | Medium | Medium | Cold data, archival |
| Snappy | Good | Fast | Low | Legacy compatibility |
| None | 1:1 | N/A | None | Already-compressed data |

```sql
CREATE TABLE rf_prod.comp_lz4    (...) WITH compression = {'sstable_compression': 'LZ4Compressor'};
CREATE TABLE rf_prod.comp_zstd   (...) WITH compression = {'sstable_compression': 'ZstdCompressor'};
CREATE TABLE rf_prod.comp_snappy (...) WITH compression = {'sstable_compression': 'SnappyCompressor'};
CREATE TABLE rf_prod.comp_none   (...) WITH compression = {'enabled': 'false'};
```

**What to look for:** After inserting identical data into all four tables and flushing, compare `Space used (live)` from `nodetool tablestats`. Zstd typically achieves the best compression ratio; uncompressed is largest.

> **Production context:** A 1TB dataset typically compresses to 400-600GB with Zstd, significantly reducing storage costs and I/O amplification during compaction.

---

## Module 33: Live Failover Under Load

Writes data continuously, kills a node mid-stream, then verifies zero data loss (~5 minutes).

1. Insert 30 rows via dc1 (15 before + 15 during node failure)
2. Kill node3 mid-stream (after row 25)
3. Continue writing rows 26-50
4. Restart node3
5. Verify all 30 rows present

**What to look for:** All 30 rows survive despite the failure. Hinted handoff delivers missed writes to node3 after restart.

---

## Module 34: Multi-DC Write Conflict

Writes the same row from both datacenters simultaneously, then shows Last-Write-Wins resolution using two strategies.

### Strategy 1: Parallel Shell Writes
```bash
# Concurrent writes from dc1 and dc2 (shell & for parallelism)
docker exec hcd-node1 cqlsh -e "INSERT INTO rf_prod.conflict_test ..." &
docker exec hcd-node4 cqlsh -e "INSERT INTO rf_prod.conflict_test ..." &
wait
```

### Strategy 2: Deterministic Proof with USING TIMESTAMP
```sql
-- dc1 write with explicit timestamp
INSERT INTO rf_prod.conflict_test (id, val, source) VALUES (1, 'dc1-wins', 'dc1') USING TIMESTAMP 1000;
-- dc2 write with higher timestamp (guaranteed winner)
INSERT INTO rf_prod.conflict_test (id, val, source) VALUES (1, 'dc2-wins', 'dc2') USING TIMESTAMP 2000;

-- Check which write won:
SELECT val, source, WRITETIME(val) FROM rf_prod.conflict_test WHERE id = 1;
```

**What to look for:** The row with the higher `WRITETIME()` wins. There is no merge — it's pure Last-Write-Wins. Strategy 2 uses `USING TIMESTAMP` for a deterministic proof independent of network timing.

---

## Module 35: Adding a Datacenter Live

Demonstrates the full workflow for expanding a cluster with a new datacenter without downtime.

```text
Step 1: ALTER KEYSPACE to include new DC
Step 2: nodetool rebuild on new nodes (streams data from existing DCs)
Step 3: nodetool cleanup on old nodes (reclaims space from moved ranges)
```

```sql
-- Add dc2 to a dc1-only keyspace
ALTER KEYSPACE rf_low WITH replication = {
    'class': 'NetworkTopologyStrategy', 'dc1': 3, 'dc2': 3
};
```

```bash
# Stream data to dc2 nodes
docker exec hcd-node4 nodetool rebuild -- dc1
# Clean up old nodes
docker exec hcd-node1 nodetool cleanup rf_low
```

**What to look for:** During rebuild, `nodetool netstats` shows streaming progress. After rebuild completes, data is queryable from dc2 nodes. Cleanup on dc1 nodes reclaims space from token ranges that moved.

---

## Module 36: Backup & Restore

Demonstrates the snapshot-based backup and restore workflow.

```bash
# Take a snapshot
docker exec hcd-node1 nodetool snapshot rf_prod -t backup1

# Verify snapshot exists
docker exec hcd-node1 nodetool listsnapshots

# Simulate disaster: TRUNCATE the table
docker exec hcd-node1 cqlsh -e "TRUNCATE rf_prod.health;"

# Restore: copy snapshot SSTables back and refresh
docker exec hcd-node1 nodetool refresh rf_prod health
```

**What to look for:** After TRUNCATE, the table is empty. After restoring from snapshot and running `nodetool refresh`, all data reappears. In production, you'd copy snapshots to external storage (S3, NFS) for disaster recovery.

---

## Module 37: Rolling Restart

Demonstrates zero-downtime node-by-node restart of ALL nodes (including the seed) while verifying reads and writes succeed throughout (~8-10 minutes).

**Restart order:** Non-seed nodes first (node3, node2), seed node last (node1). Seed nodes should be restarted last because other nodes use seeds for initial bootstrap, but once running, gossip maintains the cluster independently.

```bash
# Restart node3 (non-seed), verify writes work
docker compose stop hcd-node3
docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.rolling_test ...;"
docker compose start hcd-node3
# Wait for UN...

# Restart node2 (non-seed), verify writes work
docker compose stop hcd-node2
docker exec hcd-node1 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.rolling_test ...;"
docker compose start hcd-node2
# Wait for UN...

# Restart node1 (SEED — last), verify writes work from node2
docker compose stop hcd-node1
docker exec hcd-node2 cqlsh -e "CONSISTENCY LOCAL_QUORUM; INSERT INTO rf_prod.rolling_test ...;"
docker compose start hcd-node1
# Wait for UN...
```

**What to look for:** 20 total rows (5 initial + 5 per restart phase). Reads and writes succeed at LOCAL_QUORUM throughout, including while the seed node is down. The cluster is NEVER unavailable.

---

## Module 38: Rate Limiting & Thread Pools

Monitors HCD's internal thread pools and latency histograms to understand resource utilization.

```bash
# View thread pool statistics
docker exec hcd-node1 nodetool tpstats

# View read/write latency histograms
docker exec hcd-node1 nodetool proxyhistograms

# Key thread pools:
# - ReadStage: handles read requests
# - MutationStage: handles writes
# - CompactionExecutor: runs compactions
# - GossipStage: peer communication
```

**What to look for:** `Pending` column shows queued tasks (indicates overload). `All time blocked` indicates thread pool exhaustion. Healthy systems show 0 pending and 0 blocked.

---

## Module 39: Repair Strategies

Compares different repair approaches and their trade-offs.

| Strategy | Scope | Speed | I/O Impact | Use Case |
|----------|-------|-------|-----------|----------|
| Full repair | All ranges | Slow | High | After long outage |
| Primary-range (-pr) | Owned ranges | Medium | Medium | Regular maintenance |
| Incremental | Changed data | Fast | Low | Frequent runs |

```bash
# Full repair (repairs all ranges — use sparingly)
docker exec hcd-node1 nodetool repair rf_prod

# Primary-range repair (preferred for regular maintenance)
docker exec hcd-node1 nodetool repair -pr rf_prod

# Check repair history
docker exec hcd-node1 cqlsh -e "SELECT * FROM system_distributed.repair_history LIMIT 5;"
```

**What to look for:** Repair output shows Merkle tree comparisons between replicas. `repair_history` table records when each repair ran and which ranges were repaired.

---

## Module 40: Stress Testing

Rapid-fire writes (200 rows) with nanosecond timing to observe latency distribution and storage engine behavior under load.

```bash
# Insert 200 rows rapidly with timing
for i in $(seq 1 200); do
    docker exec hcd-node1 cqlsh -e "INSERT INTO rf_prod.health (id, status) VALUES ($((5000+i)), 'stress-$i');"
done

# Check latency histogram
docker exec hcd-node1 nodetool proxyhistograms

# Check bloom filter effectiveness
docker exec hcd-node1 nodetool tablestats rf_prod.health | grep -i bloom
```

> **Production benchmark context:** Single-node throughput typically reaches 10K-50K ops/sec; cluster-wide throughput 50K-200K ops/sec depending on hardware, data model, and consistency level.

**What to look for:** Proxyhistograms show p50/p99 latencies. Bloom filter stats show false-positive ratio — a high ratio indicates too many SSTables (needs compaction).

---

## Module 41: Security & Access Control

Demonstrates role-based access control (RBAC) concepts.

> **Note:** This demo cluster uses `AllowAllAuthenticator` (default). The commands below demonstrate RBAC syntax. In production, enable `PasswordAuthenticator` in `cassandra.yaml` before roles enforce real access control.

```sql
-- Create non-login roles (permission groups)
CREATE ROLE IF NOT EXISTS demo_reader WITH LOGIN = false;
CREATE ROLE IF NOT EXISTS demo_writer WITH LOGIN = false;

-- Grant permissions
GRANT SELECT ON KEYSPACE rf_prod TO demo_reader;
GRANT MODIFY ON KEYSPACE rf_prod TO demo_writer;

-- View permissions
LIST ALL PERMISSIONS OF demo_reader;
LIST ALL PERMISSIONS OF demo_writer;
```

**What to look for:** `demo_reader` has SELECT only; `demo_writer` has MODIFY only. In production: enable `PasswordAuthenticator` and `CassandraAuthorizer` in `cassandra.yaml`, create login roles with passwords, and enable TLS for client-to-node and node-to-node encryption.

---

## Module 42: Geographic Visualization

Maps data placement to physical nodes, proving LOCAL_QUORUM avoids WAN round-trips.

```bash
# Show which nodes hold a specific partition
docker exec hcd-node1 nodetool getendpoints rf_prod health 1
# Returns 6 IPs (3 per DC with RF=3)

# View the full ring structure
docker exec hcd-node1 nodetool describering rf_prod
```

```sql
-- Trace a LOCAL_QUORUM read to prove no WAN hops
TRACING ON;
CONSISTENCY LOCAL_QUORUM;
SELECT * FROM rf_prod.health WHERE id = 1;
TRACING OFF;
```

**What to look for:** The trace shows all coordination happens within the local DC — no messages to dc2 IPs (172.28.0.5-7). `getendpoints` confirms data exists on 6 nodes but LOCAL_QUORUM only contacts 3 local ones.

---

## Module 43: Driver Policies — The Client-Side of Entropy

Until now, every command used `cqlsh` — a single-node CLI tool. In production, applications use the DataStax Python/Java/Go driver with **smart routing policies** that are fundamental to entropy management.

### Key Policies

| Policy | What it Does | Entropy Impact |
|--------|-------------|----------------|
| `RoundRobinPolicy` | Picks coordinators in rotation | Naive — extra hop to actual replica |
| `DCAwareRoundRobinPolicy` | Keeps traffic in local DC | Avoids WAN, reduces cross-DC entropy |
| `TokenAwarePolicy` | Routes to owning replica | Zero coordinator hop — minimum latency |

### How TokenAwarePolicy Works

```text
NAIVE ROUND-ROBIN (cqlsh)            TOKEN-AWARE (DataStax Driver)

Client ──► node1 ─────► node3       Client ──► node3 (direct!)
       (coordinator)  (replica)           (coordinator IS the replica)

Extra hop: coordinator must           Zero extra hops: the driver
forward to the actual replica.        KNOWS the token ring and sends
                                      the request straight to the owner.
```

1. Driver connects → downloads token ring from `system.peers`
2. For each write, driver hashes the partition key (Murmur3)
3. Maps hash → owning node from the ring
4. Sends write directly to that node

### Code Example

```python
from cassandra.cluster import Cluster
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy

cluster = Cluster(
    ['172.28.0.2', '172.28.0.3', '172.28.0.4'],
    load_balancing_policy=TokenAwarePolicy(
        DCAwareRoundRobinPolicy(local_dc='dc1')
    ),
)
session = cluster.connect('rf_prod')
# Every write goes directly to the replica that owns the partition
result = session.execute("INSERT INTO health (id, status) VALUES (%s, %s)", (1, 'ok'))
print(result.response_future.coordinator_host)  # Shows the owning replica
```

**What to look for:** RoundRobin spreads writes across ALL nodes (including non-replicas). TokenAware targets writes to replica owners — fewer distinct coordinators, lower latency.

---

## Module 44: Speculative Execution — Masking Latency Spikes

In a distributed system, any replica can become temporarily slow (compaction, GC pause, disk I/O). Speculative execution sends **backup requests** to mask these latency spikes.

### Timeline

```text
WITHOUT SPECULATIVE:
Client ──req──► Replica A ────────────(slow)─────────► response
                                                p99 = slow node

WITH SPECULATIVE (delay=200ms):
Client ──req──► Replica A ────(slow, no response yet)────►
        │
        ╰─ 200ms ─► Replica B ──(fast)──► response (WINS!)

Whichever replica responds FIRST is used. The slow one is ignored.
p99 ≈ p50 because you're racing multiple replicas!
```

### Trade-offs

| | Without | With Speculative |
|---|---------|-----------------|
| p99 latency | High (slowest replica) | Low (≈ p50) |
| Network traffic | Normal | Slightly higher |
| Best for | Simple workloads | Latency-sensitive reads/writes |
| Avoid with | — | LWT (Paxos is not idempotent) |

### Code Example

```python
from cassandra.policies import ConstantSpeculativeExecutionPolicy

cluster = Cluster(
    contact_points,
    speculative_execution_policy=ConstantSpeculativeExecutionPolicy(
        delay=0.2,        # 200ms before sending backup
        max_attempts=2,   # up to 2 backup requests
    ),
)
```

**What to look for:** Compare p99 latencies between runs with and without speculative execution. With speculative enabled, p99 drops closer to p50 because slow replicas are masked.

---

## Module 45: Live DC Failover with Driver

Module 23 proved zero-downtime failover using `cqlsh` pointed at a dc2 node. In production, **the application never switches nodes manually** — the DataStax driver does it automatically (~3-5 minutes including DC restart).

### Failover Timeline

```text
T=0s    App writes via driver (local_dc='dc1')
        Coordinators: 172.28.0.2, .3, .4 (dc1 nodes)

T=15s   ██ ALL DC1 NODES KILLED ██
        Driver detects dc1 is down via connection monitoring

T=16s   Driver AUTOMATICALLY routes to dc2 (used_hosts_per_remote_dc=3)
        Coordinators: 172.28.0.5, .6, .7 (dc2 nodes)
        >>> ZERO application errors, ZERO code changes <<<

T=35s   DC1 restarted
        Driver detects dc1 is back, routes traffic home
        Coordinators: back to 172.28.0.2, .3, .4
```

### Critical Configuration

```python
DCAwareRoundRobinPolicy(
    local_dc='dc1',
    used_hosts_per_remote_dc=3,  # ← MUST be > 0 for cross-DC failover!
)
# Default is 0 — the driver will REFUSE to failover without this!
```

### What the Demo Shows

1. Start continuous writer on hcd-node4 (dc2) with `local_dc='dc1'`
2. Kill all dc1 nodes (`docker compose stop hcd-node1 hcd-node2 hcd-node3`)
3. Driver automatically routes to dc2 — zero errors
4. Restart dc1 — driver routes traffic back home

**What to look for:** The `[WRITE]` output shows coordinator shifting from dc1 IPs to dc2 IPs and back. The `◄── FAILOVER` and `◄── FAILBACK` markers show the exact moments. The summary shows ZERO application errors.

---

## Module 46: Retry Policies Under Partition

When a node times out or becomes unavailable, the driver's **retry policy** decides what happens next: retry on same host, retry on next host, or throw to the application.

### Decision Tree

```text
Write/Read Timeout or Unavailable Exception
│
├── DefaultRetryPolicy
│   └── Enough replicas responded?
│       ├── YES → RETRY on SAME host (once)
│       └── NO  → RETHROW to application
│
├── FallthroughRetryPolicy
│   └── ALWAYS → RETHROW (never retry, never mask errors)
│   Use case: financial transactions, audit trails
│
└── Custom AggressiveRetryPolicy
    └── Attempts < 3?
        ├── YES → RETRY on NEXT host (try another replica)
        └── NO  → RETHROW
    Use case: IoT telemetry, logging, best-effort writes
```

### When to Use Each

| Policy | Use Case | Trade-off |
|--------|----------|-----------|
| DefaultRetryPolicy | General purpose | Balanced retry/visibility |
| FallthroughRetryPolicy | Financial, compliance | Every error visible to app |
| Custom Aggressive | IoT, telemetry, logging | Max availability, some masking |

### Code Example

```python
from cassandra.policies import RetryPolicy

class AggressiveRetryPolicy(RetryPolicy):
    def on_write_timeout(self, query, consistency, write_type,
                         required_responses, received_responses, retry_num):
        if retry_num < 3:
            return self.RETRY_NEXT_HOST, consistency
        return self.RETHROW, None
```

### Dual-Failure Setup
The script uses TWO isolation techniques to reliably trigger retries:
1. `docker pause hcd-node3` — freezes the process (simulates a hung/slow node, causes timeouts)
2. `docker network disconnect` — isolates node2 (simulates network partition, causes unavailable errors)

This ensures the driver encounters both timeout and unavailable exceptions, making the retry policy behavior clearly visible.

**What to look for:** Compare success/failure counts across the three policies. FallthroughRetryPolicy shows more failures (no retries). AggressiveRetryPolicy shows more successes (retries on next host). DefaultRetryPolicy provides a balanced middle ground.

---

## Module 47: Parts 1-5 Checkpoint

A visual recap of everything covered in the demo, presented as an ASCII dashboard showing:

- **Total modules**: 84 (0-83)
- **What was proved**: Zero data loss during node/DC failure, automatic self-healing, LWW conflict resolution, rolling restart with zero downtime, automatic driver DC failover, p99 latency masking, safe banking transfers, saga compensation
- **Topics covered**: Core, Indexing (SAI), Write Path, Multi-DC, Ops, Security, Data Modeling, Driver Policies, Transactions (ACID, Batches, LWT, Sagas)
- **Key production takeaways**: LOCAL_QUORUM, TokenAwarePolicy, used_hosts_per_remote_dc, weekly repair, partition key design, monitoring, PasswordAuthenticator

Includes a live cluster health check (`nodetool status`) when running against a real cluster.

---

## Module 48: ACID vs HCD — What 'Transactions' Really Mean Here

Compares the traditional RDBMS ACID model with HCD's consistency model:
- **Atomicity**: Per-partition only (no multi-partition rollback)
- **Consistency**: Tunable per query (CL=ONE through ALL)
- **Isolation**: None in the RDBMS sense. LWT provides row-level compare-and-swap (CAS), NOT multi-row transactions. There are no "isolation levels" in Cassandra.
- **Durability**: Full (CommitLog + RF=3)

Demonstrates the consistency spectrum with traced writes at CL=ONE, LOCAL_QUORUM, and LWT, showing increasing latency for increasing guarantees.

**What to look for:** Compare trace latency across the three levels. LWT shows Paxos phases (Prepare/Promise/Accept/Commit). CL=ONE is fastest but weakest. LOCAL_QUORUM is the recommended default.

---

## Module 49: LOGGED vs UNLOGGED BATCH — Atomicity Without Isolation

Explains the batchlog mechanism for crash-safe cross-partition atomicity:
- **UNLOGGED BATCH**: For same-partition mutations (atomic at storage layer, no overhead)
- **LOGGED BATCH**: For cross-partition mutations (batchlog on 2 peers ensures replay on crash)
- **Anti-pattern**: Demonstrates why large batches are dangerous for performance

Uses tracing to show the "Storing batchlog" and "Removing batchlog" steps in LOGGED batches. Includes a 50-row batch anti-pattern demo with tpstats comparison.

**What to look for:** UNLOGGED trace has no batchlog entries. LOGGED trace shows batchlog overhead (~30%). The large batch shows MutationStage pressure in tpstats.

---

## Module 50: The Lost Update Problem — Why Read-Modify-Write Needs LWT

The most dangerous consistency bug demonstrated live:
1. **Lost update**: Two concurrent updates to the same account balance — expected 180, actual 130 or 150
2. **Fix with LWT**: IF conditions provide compare-and-swap (CAS). Second update gets `[applied]: False` with current value for retry
3. **SERIAL vs LOCAL_SERIAL**: Global vs DC-local Paxos consistency for LWT reads

**What to look for:** The non-LWT parallel writes produce a lost update (one value overwrites the other). The LWT version rejects the stale write with `[applied]: False` and returns current values for retry. This is the foundation for Module 51's banking pattern.

---

## Module 51: Banking — Instant Payment Between Two Banks

Real-world cross-partition payment pattern: Alice (Bank A, dc1) pays Bob (Bank B, dc2) $100.

**Pattern**: LWT debit (IF balance >= amount AND version = N) → CDC-enabled payment record → LWT credit (IF version = N) → status update to COMPLETED.

**Failure scenarios demonstrated**:
- Duplicate debit attempt (version guard prevents double-debit, `[applied]: False`)
- Insufficient funds (balance guard rejects overdraft, `[applied]: False`)
- CDC captures payment events for downstream processing

**What to look for:** Total money in system is always conserved (500+200 = 400+300 = 700). LWT prevents double-processing. Version columns provide idempotency.

---

## Module 52: Saga Pattern — Supplier/Customer Order Flow

Multi-step business workflow with compensating transactions:

**Happy path** (ORD-001): Place order → Reserve inventory (LWT) → Capture payment (LWT IF NOT EXISTS) → Ship → SHIPPED

**Failure path** (ORD-002): Place order → Reserve inventory (LWT) → Payment FAILS → **Compensate**: release inventory (LWT) → CANCELLED

Each saga step uses LWT with version guards for idempotency. CDC on the orders table triggers subsequent steps in production.

**What to look for:** Each LWT returns `[applied]: True/False`. When payment fails, the compensating transaction releases reserved inventory back. Final state shows no inventory leak and no data corruption.

---

## Module 53: Consistency Decision Framework

The capstone module presents four sections with pauses between each for discussion:

1. **Decision tree** — flowchart from "single partition?" to pattern selection
2. **Pattern comparison matrix** — latency, throughput, atomicity, isolation
3. **Five golden rules** — actionable defaults
4. **Use case mapping** — pattern per real-world scenario with module references

| Pattern | Latency | Throughput | Atomicity | CAS Scope |
|---------|---------|------------|-----------|-----------|
| LOCAL_QUORUM | ~2ms | Highest | Per-write | None |
| UNLOGGED BATCH | ~2ms | High | Partition | None |
| LOGGED BATCH | ~3ms | Medium | Cross-ptn | None |
| LWT (Paxos) | ~8-15ms | Low | Row-level | Row-level CAS |
| Saga (LWT+CDC) | ~50ms+ | Lowest | Workflow | Per-step CAS |

**Five Golden Rules**: (1) Default to LOCAL_QUORUM, (2) LWT only for race-critical ops, (3) Batches for atomicity not performance, (4) Sagas for business workflows, (5) Design for idempotency first.

---

## Module 54: HCD Data API (REST/JSON Document Access)

Demonstrates the HCD Data API running on `http://localhost:8181`, providing REST/JSON access to Cassandra data without CQL. Uses a Postman collection with CRUD operations: `insertOne`, `find`, `updateOne`, `deleteOne`. Shows document-style access patterns alongside traditional CQL, proving HCD supports both relational and document paradigms.

**What to look for:** HTTP 200 responses for all CRUD operations. The Data API translates JSON documents to/from Cassandra tables transparently. Compare latency of REST vs native CQL.

---

## Module 55: Multi-Tenant Isolation

Shows how to design multi-tenant applications on HCD using tenant ID as partition key prefix, RBAC roles per tenant, GDPR-compliant data erasure (DELETE WHERE tenant_id = X), and DC affinity for data sovereignty.

**What to look for:** Each tenant's data is isolated at the partition level. RBAC prevents cross-tenant access. GDPR erasure removes all data for a single tenant without affecting others.

---

## Module 56: Node Decommission (Controlled Cluster Shrink)

Walks through safe node removal: `nodetool drain` (stop accepting writes), `nodetool decommission` (stream data to remaining nodes), and verification. Compares `decommission` (graceful) vs `removenode` (node already dead) vs `assassinate` (force-remove from gossip).

**What to look for:** Decommission streams all data off the node before it leaves the ring. `nodetool status` shows the node transitioning from UN to UL (Leaving) to gone.

---

## Module 57: Disaster Recovery Runbook

Demonstrates a 4-level DR strategy: (1) `nodetool snapshot` for point-in-time backups, (2) coordinated multi-node snapshots, (3) `truncate` + restore from snapshot, (4) commitlog archival for RPO=0. References Medusa for production-grade automated backups to cloud storage.

**What to look for:** Snapshot creates hard links (instant, zero-copy). Restore from snapshot + commitlog replay recovers to the exact pre-failure state.

---

## Module 58: Silent Data Corruption Detection

Injects corruption into an SSTable's `Data.db` file using `dd` with random bytes, then detects it with `nodetool verify` (CRC32 scan) and `nodetool scrub` (row-level rebuild). Demonstrates recovery via `nodetool repair` from healthy replicas (majority wins with RF=3).

**What to look for:** `nodetool verify` reports the corrupted SSTable path. After `scrub` + `repair`, all 10 test rows are restored from healthy replicas.

---

## Module 59: Cross-Service Saga (Simulated External Services)

Extends the saga pattern from Modules 51-52 to cross-service transactions spanning Order, Payment, and Shipping services. Demonstrates happy path (5-step lifecycle), payment timeout with compensation, and post-capture shipping failure with refund. Uses the outbox pattern for reliable event delivery and LWT for idempotent step execution.

**What to look for:** Three saga scenarios with different outcomes. Replaying a completed step returns `[applied]: False` (idempotency). All outbox events are generated atomically with state changes.

---

## Module 60: LWT Contention Under Load

Launches 5 concurrent LWT writers targeting the same row to demonstrate Paxos contention. Compares single-writer baseline (zero retries) with concurrent contention (only 1 winner per round). Uses `TRACING ON` to show the 4-phase Paxos round-trip cost vs normal writes. Covers mitigation strategies: partition sharding, exponential backoff, application queuing.

**What to look for:** Single-writer: all 10 updates succeed immediately. Concurrent: only 1 of 5 writers wins. LWT trace shows Prepare/Promise/Propose/Commit phases (4x round-trips vs 1 for normal writes).

---

## Module 61: Repair Deep-Dive (The Most Critical Ops Procedure)

Goes beyond Module 39's repair basics: visualizes Merkle trees, demonstrates the zombie row problem (deleted data resurrected after gc_grace expiry), and compares 4 repair modes (full, primary-range, incremental, sub-range). Creates deliberate entropy by stopping a node during writes, then repairs it. Covers gc_grace_seconds interaction and Reaper scheduling for production.

**What to look for:** Node3 shows fewer rows than Node1 after the outage. After repair, counts match. Repair history visible in `system_distributed.repair_history`.

---

## Module 62: Live RBAC Demo (Role-Based Access Control)

Demonstrates HCD's authentication and authorization: PasswordAuthenticator, role creation (`CREATE ROLE`), granular permissions (`GRANT SELECT/MODIFY`), permission denial, and role inheritance. Shows the full privilege hierarchy from superuser to read-only analyst roles.

**What to look for:** Each role has precisely scoped permissions. Unauthorized operations are denied with clear error messages. Role inheritance allows hierarchical access models.

---

## Module 63: Encryption at Rest (Transparent Data Encryption)

Shows TDE configuration: JKS/JCEKS keystore setup, `AES/CBC/PKCS5Padding` cipher, encrypted SSTable verification via `hexdump` (random bytes vs plaintext), and key rotation workflow using `nodetool upgradesstables`.

**What to look for:** Encrypted SSTables show random bytes in hexdump (no readable text). Key rotation re-encrypts all SSTables with the new key without downtime.

---

## Module 64: Commitlog Durability & Crash Recovery

Uses `docker kill` (SIGKILL) to simulate an unclean process crash after writing data. Demonstrates that commitlog replay on restart recovers all committed writes with zero data loss. Compares `commitlog_sync: periodic` (default, 10s window) vs `batch` (fsync per write, slower but durable).

**What to look for:** After SIGKILL + restart, all rows written before the crash are present. The commitlog replay message appears in startup logs.

---

## Module 65: Hint Expiration & Data Gaps

Demonstrates the hinted handoff lifecycle: stops a node, writes data that generates hints on the coordinator, then shows hint delivery on restart. Explains `max_hint_window_in_ms` (3 hours default) — if a node is down longer, hints expire and data gaps require repair.

**What to look for:** Hints are stored on the coordinator while the target is down. After restart, `nodetool handoffwindow` or system.hints shows hint delivery. For outages > 3 hours, repair is mandatory.

---

## Module 66: Dynamic RF Change (ALTER KEYSPACE)

Changes replication factor from RF=1 to RF=3 via `ALTER KEYSPACE` and demonstrates that this is metadata-only — new replicas are empty until `nodetool repair` populates them. Shows that QUORUM reads fail on empty replicas until repair completes.

**What to look for:** After ALTER KEYSPACE, `nodetool describering` shows new token assignments but new replicas have zero data. QUORUM reads may fail. After repair, all replicas have consistent data.

---

## Module 67: Streaming & Bootstrap Monitoring

Walks through the bootstrap lifecycle when a new node joins: token allocation, streaming from existing nodes, and monitoring via `nodetool netstats`. Covers `stream_throughput_outbound_megabits_per_sec` (200 Mbps default) for rate limiting.

**What to look for:** `nodetool netstats` shows active streams with progress percentages. Stream throughput can be adjusted to avoid saturating the network during bootstrap.

---

## Module 68: Materialized Views (Write-Through Consistency)

Creates a base table and materialized view, demonstrating write-through semantics (MV updates automatically on base table writes). Shows the 2x+ write amplification cost, consistency risks (MV can silently diverge from base), and the production caveat that the only fix for a diverged MV is `DROP` + `CREATE`.

**What to look for:** MV rows appear automatically after base table inserts. Write amplification is visible in `nodetool tablestats` (MV receives same write volume as base table).

---

## Module 69: Nodetool Ops Deep-Dive (Troubleshooting Toolkit)

Covers the essential nodetool commands for production troubleshooting: `tablestats` (per-table metrics), `tpstats` (thread pool activity), `proxyhistograms` (coordinator-level latency distribution), and `compactionstats` (pending compactions). Presents a troubleshooting decision tree for common production issues.

**What to look for:** Each command reveals different operational metrics. The decision tree maps symptoms (high latency, dropped messages, pending compactions) to diagnostic commands and remediation steps.

---

## Module 70: Cross-DC Consistency Window

Uses `docker network disconnect` to partition dc2 from dc1, then demonstrates that LOCAL_QUORUM reads in dc1 succeed but return stale data when dc2 has newer writes. Shows EACH_QUORUM as the cross-DC consistency guarantee (at the cost of higher latency and reduced availability).

**What to look for:** During partition, LOCAL_QUORUM in dc1 succeeds but may miss dc2 writes. EACH_QUORUM fails during partition (by design — it requires both DCs). After reconnection, data converges.

---

## Module 71: Bloom Filter & Cache Tuning

Creates tables with different `bloom_filter_fp_chance` settings (0.001, 0.01, 0.1) and compares memory usage via `nodetool tablestats`. Explains the trade-off: lower FP chance = larger bloom filters in memory = fewer wasted disk reads. Covers key cache, row cache, and chunk cache hit ratios.

**What to look for:** Tables with lower `bloom_filter_fp_chance` show larger bloom filter sizes in `tablestats`. The FP trade-off table shows ~15 bits/key at 0.001 vs ~10 bits/key at 0.01 (default).

---

## Appendix A: Wow Moments for Stakeholder Demos

The highest-impact modules for executive presentations, ordered by audience reaction:

| # | Module | What You Show | Time |
|---|--------|---------------|------|
| 1 | 23 | Kill an entire datacenter. Query from the other. Zero data loss. | ~5-8 min |
| 2 | 45 | Driver auto-failover: zero application errors during DC kill | ~3-5 min |
| 3 | 24 | Chain 3 cascading failures, prove self-healing after each | ~10 min |
| 4 | 51 | Cross-partition banking transfer: money always conserved | ~5 min |
| 5 | 17 | Network partition: watch gossip detect a zombie node live | ~3 min |
| 6 | 2 | EACH_QUORUM fails, LOCAL_QUORUM survives, then EACH_QUORUM recovers | ~3 min |
| 7 | 12 | Two users, two continents, one seat — LWT prevents double-booking | ~2 min |
| 8 | 35 | Add a datacenter live and watch data stream in real-time | ~8 min |

### Framing for Business Audiences

Before each wow moment, anchor the demonstration with the audience's own cost of downtime:

> *"What is your per-minute cost of unplanned downtime? Industry benchmarks range from $5,600 to $9,000/min (Gartner). Now multiply that by zero — that's what Module 23 proves."*

| Wow Moment | Business Risk Eliminated | Ask Your Audience |
|------------|------------------------|-------------------|
| DC Kill (23) | Unplanned datacenter outage | "How many minutes of downtime did your last DR test show?" |
| Driver Failover (45) | Application-level single point of failure | "Does your app code change when infrastructure fails?" |
| Banking (51) | Double-processing in financial transactions | "What is the cost of a duplicate payment in your system?" |
| LWT Booking (12) | Overselling / double-booking | "How do you prevent two customers from buying the last item?" |

---

## Appendix B: Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| "Cluster nodes are not responding" | Cluster not started | `make up` |
| Node stuck at DN after restart | Slow gossip convergence | Wait 30s; check `nodetool gossipinfo` |
| Read repair not triggering | Data already consistent | Stop a node, write data, restart, then read to force mismatch |
| Hints not replaying | Node was down > 3 hours | Run `nodetool repair -pr <keyspace>` instead |
| Module 17 network disconnect fails | Docker network name mismatch | Check `docker network ls` (usually `brokk_hcd-cluster`) |
| Audit log empty after enableauditlog | Need CQL after enabling | Run queries AFTER `nodetool enableauditlog` |
| Guardrail warnings not appearing | Batch too small to trigger | Increase batch to > 5KB (50+ rows with data) |
| Single-module fails on missing keyspace | Prerequisites not met | Script auto-creates `rf_prod` for Module > 1; verify cluster is running |
| MinIO Object Lock error | MinIO started without `--with-lock` | `docker rm -f minio` and let demo-entropy.sh re-create it |
| WORM deletion succeeds (should fail) | Bucket created without Object Lock | Re-create bucket: `mc mb --with-lock myminio/hcd-snapshots` |

---

## Module 72: DORA Ransomware — Kill Chain & Infrastructure Setup

Introduces the DORA (EU Regulation 2022/2554) ransomware resilience demo. Presents the ransomware kill chain (7 phases) and defense layers (6 tiers). Interactive DORA quiz (5 questions). Creates `dora_bank` keyspace (RF=3 per DC) with `accounts`, `transactions`, and `audit_log` tables. Inserts 5 sample banking accounts. Starts MinIO with Object Lock support and creates two WORM-enabled buckets (`hcd-snapshots`, `hcd-commitlogs`) with 30-day COMPLIANCE retention.

**What to look for:** The kill chain diagram shows how ransomware escalates from Initial Access to Impact. The DORA quiz calibrates your regulatory knowledge. MinIO bucket creation should show `Object Lock: Enabled`.

**Takeaway:** DORA Art. 6 mandates ICT risk management frameworks; Art. 12 mandates backup separation. WORM storage with Object Lock in COMPLIANCE mode satisfies Art. 12 — even root cannot delete before retention expires.

**Key concepts:** DORA Art. 6 (risk framework), Art. 12 (backup policies), WORM storage, Object Lock COMPLIANCE mode, MinIO S3-compatible storage.

## Module 73: Backup to WORM & Integrity Verification

Takes `nodetool snapshot` on all 6 nodes, uploads snapshot SSTables to MinIO WORM bucket with SHA-256 checksums. Verifies integrity by downloading and comparing checksums. Attempts to delete from WORM bucket — Object Lock blocks the deletion, proving immutability. Demonstrates that even the MinIO root admin cannot bypass COMPLIANCE retention.

**What to look for:** The `mc rm` command should fail with an Object Lock error. The `mc stat` command should still show the object after the deletion attempt. SHA-256 checksums should match between source and WORM copy.

**Takeaway:** WORM backups with integrity verification satisfy DORA Art. 12's backup testing requirement. The key insight: COMPLIANCE mode Object Lock is truly immutable — no override exists, unlike GOVERNANCE mode.

**Key concepts:** nodetool snapshot (instant hard-links), SHA-256 integrity verification, Object Lock COMPLIANCE (no override), DORA Art. 12 backup testing requirement.

## Module 74: Commitlog Archiving to WORM

Explains the gap between snapshots: commitlog archiving captures every mutation written after the last snapshot. Configures `commitlog_archiving.properties` on node1. Generates transaction data, flushes commitlogs, and archives segments to MinIO WORM. Verifies Object Lock protects commitlog archives. Two-tier WORM: snapshots (bulk recovery) + commitlogs (incremental PITR).

**What to look for:** The commitlog segments should appear in MinIO after flush. Object Lock should protect them just like SSTable snapshots. The RPO drops from "time since last snapshot" to "time since last commitlog flush" (~10 seconds).

**Takeaway:** Two-tier WORM (snapshots + commitlogs) provides defense in depth: snapshots for bulk recovery, commitlogs for point-in-time recovery. RPO approaches zero with continuous commitlog archiving.

**Key concepts:** Write-ahead log (WAL), commitlog segments (32MB default), Point-in-Time Recovery (PITR), `archive_command`/`restore_command`, RPO calculation.

## Module 75: The Attack Simulation

Simulates a full ransomware attack in 5 phases: (1) Reconnaissance — enumerate cluster topology and schema, (2) Exfiltration — read and count all data, (3) Destruction — TRUNCATE all 3 tables across all replicas, (4) Snapshot wipe — `clearsnapshot --all` on all 6 nodes, (5) Ransom note — plant message in database. Verifies total data loss (count=0 on all tables, no local snapshots). Then proves WORM backups in MinIO are untouched — Object Lock survived the attack.

**What to look for:** After TRUNCATE, all tables show count=0 across both DCs — multi-DC replication does NOT protect against TRUNCATE. After clearsnapshot, `nodetool listsnapshots` returns empty. But `mc ls` against MinIO still shows all backup files intact.

**Takeaway:** TRUNCATE is a cluster-wide coordinated operation — it propagates to ALL replicas in ALL DCs. Local snapshots are also vulnerable to `clearsnapshot`. WORM storage is the only line of defense that survives a full ransomware attack.

**Key concepts:** TRUNCATE is cluster-wide (multi-DC does NOT protect), clearsnapshot wipes local backups, WORM is the ONLY defense, DORA Art. 12 separation requirement.

## Module 76: Recovery from WORM Backups

Full recovery procedure: (1) Verify WORM backup integrity (checksums), (2) Download snapshots from MinIO, (3) Restore SSTables (simulates sstableloader), (4) Verify all 5 accounts and 4 transactions recovered, (5) Verify DC2 has consistent data. Drops the ransom note table. Shows recovery timeline aligned with DORA Art. 11 requirements (target RTO < 2 hours).

**What to look for:** SHA-256 checksums match before and after download. All 5 accounts and 4 transactions reappear after restore. DC2 shows the same data as DC1 (cross-DC consistency). The ransom note table is dropped as part of cleanup.

**Takeaway:** Recovery from WORM backups restores full data integrity. The procedure is repeatable and verifiable — critical for DORA Art. 11(6) which requires documented RTO/RPO objectives. Target: RTO < 2 hours for critical banking systems.

**Key concepts:** sstableloader, backup integrity verification, RTO/RPO measurement, cross-DC consistency after restore, DORA Art. 11(6) recovery requirements.

## Module 77: DC Failover Under Attack

Simulates a datacenter-level attack: disconnects all 3 dc1 nodes from the network. Verifies dc2 continues serving reads and writes at LOCAL_QUORUM. Writes new data during the partition. Reconnects dc1 nodes and runs `nodetool repair` to sync missed mutations. Verifies both DCs converge to identical data, including data written during the partition.

**What to look for:** After dc1 disconnection, dc2 queries at LOCAL_QUORUM succeed immediately — zero downtime. New writes during the partition are captured by dc2. After reconnection, `nodetool repair` syncs the data. Both DCs show identical results.

**Takeaway:** LOCAL_QUORUM (not QUORUM) is essential for DC independence — QUORUM requires cross-DC acknowledgment and would fail during a partition. DC failover RTO is under 1 minute. Repair after reconnection ensures full convergence. Note: hints expire after `max_hint_window` (default 3h); for longer partitions, repair is mandatory.

**Key concepts:** Network partition, LOCAL_QUORUM (not QUORUM) for DC independence, hinted handoff + repair for reconvergence, RTO < 1 minute for DC failover, DORA Art. 11 business continuity.

## Module 78: DORA Compliance Scorecard & K8s Auto-Healing

Maps all demo modules to specific DORA articles (Art. 6, 9, 10, 11, 12, 13, 19, 26). Presents Art. 19 incident reporting timeline (4h initial, 72h intermediate, 1 month final) with ransomware-specific examples. Shows 5 recovery paths with RTO/RPO matrix. Introduces K8ssandra CRD for Kubernetes auto-healing: pod killed → auto-recreated in ~5 minutes with zero manual action. Covers Medusa (backup), Reaper (repair), cass-operator (auto-healing), and Data API (REST gateway). Cleanup: drops `dora_bank` keyspace; MinIO container intentionally left running (stop with `docker rm -f minio`).

**What to look for:** The DORA compliance matrix maps each defense (RBAC, TLS, WORM, repair, DC failover) to specific articles. The recovery path matrix shows 5 options with increasing RTO/RPO trade-offs. K8ssandra auto-healing demonstrates Art. 13 (learning/evolving) — the system self-corrects without human intervention.

**Takeaway:** DORA compliance is not a checkbox — it requires demonstrated, tested resilience. This demo provides live proof for Art. 6 (risk framework), Art. 9 (protection), Art. 10 (detection), Art. 11 (business continuity), Art. 12 (backup), Art. 13 (learning), Art. 19 (reporting), and Art. 26 (TLPT). K8ssandra automates ongoing compliance.

**Key concepts:** DORA compliance matrix, incident reporting (Art. 19), recovery path selection, K8ssandra operator, Medusa automated backups, Reaper repair scheduling.

## Module 79: Counter Columns

Demonstrates counter columns — the only non-idempotent operation in HCD. Creates a `page_views` counter table, performs increments and decrements, and explains the counter shard replication model. Covers why counters must live in dedicated tables, cannot use LWT, and require frequent repair.

**What to look for:** Counter values accumulate across multiple UPDATE statements. Decrement is supported (counters can go negative). No INSERT syntax — only UPDATE with `+ N` or `- N`.

**Takeaway:** Counters are add-only operations that cannot be replayed safely. Use them for approximate metrics (page views, API calls), never for financial balances. Run `nodetool repair -pr` frequently on counter tables to prevent shard drift.

**Key concepts:** Non-idempotent writes, counter shards, dedicated counter tables, counter repair, CL recommendations for counters.

## Module 80: Prepared Statements & Driver Best Practices

Covers the performance difference between simple and prepared CQL statements (parse-once, execute-many pattern). Demonstrates connection pooling defaults, idempotency flags, and the prepared statement leak anti-pattern. References Modules 43-46 for driver policy details.

**What to look for:** Tracing output shows "Parsing" and "Preparing statement" steps that prepared statements skip on re-execution. Connection pool defaults show 1 connection per host handles ~1024 concurrent requests.

**Takeaway:** Prepare statements once at startup, reuse forever — 10x less coordinator CPU. Never concatenate values into CQL strings. Mark idempotent queries for safe retry and speculative execution.

**Key concepts:** Prepared vs simple statements, bind variables, connection multiplexing (protocol v4), idempotency flags, prepared statement cache leak.

## Module 81: JVM & GC Tuning

Inspects live JVM heap usage and GC statistics. Explains heap sizing rules (max 31 GB for CompressedOops), GC algorithm selection (G1 default, ZGC experimental), and off-heap memory components. Provides a production tuning checklist.

**What to look for:** `nodetool info` shows heap used/total and off-heap memory. `nodetool gcstats` shows GC interval and pause times. JVM options file reveals the configured GC algorithm.

**Takeaway:** Never exceed 31 GB heap (CompressedOops boundary). Set -Xms = -Xmx to avoid resize pauses. Leave 30-50% of RAM for OS page cache — it is critical for SSTable read performance. Monitor GC pauses: > 1 second = client timeouts.

**Key concepts:** CompressedOops, G1GC vs ZGC, off-heap memory (bloom filters, compression metadata), page cache, heap sizing rules.

## Module 82: CQL Aggregation & Analytics Functions

Demonstrates COUNT, SUM, AVG, MIN, MAX within a partition (safe) and across partitions (dangerous). Creates a `daily_sales` table and shows GROUP BY with clustering columns. Explains coordinator-side aggregation and why full-table scans are problematic.

**What to look for:** Within-partition aggregation is fast and bounded. Cross-partition COUNT scans the entire cluster. GROUP BY must follow PRIMARY KEY column order.

**Takeaway:** CQL aggregates work best within a single partition. For cross-partition analytics, use pre-aggregated counter tables, materialized views, or Apache Spark. Full-table aggregation is O(n) on the dataset — there is no global row count metadata.

**Key concepts:** Coordinator-side aggregation, partition-scoped queries, GROUP BY restrictions, user-defined aggregates (UDA), Spark integration.

## Module 83: Collection Types Deep-Dive (Frozen vs Non-Frozen)

Demonstrates SET, LIST, and MAP collection types with both frozen and non-frozen semantics. Shows partial updates (non-frozen) vs full replacement (frozen), nested collections with frozen inner types, and concurrent set mutation semantics (element-level LWW).

**What to look for:** Non-frozen collections allow adding/removing individual elements. Frozen collections require full replacement. Nested collections require `frozen<>` on inner types. Concurrent adds to non-frozen sets produce a union (both survive).

**Takeaway:** Use non-frozen for element-level updates, frozen for atomic replacement or nesting. Prefer SETs over LISTs (lists have read-before-write anti-patterns). Keep collections small (< 64 KB) — for large datasets, model as separate tables.

**Key concepts:** Frozen vs non-frozen storage, element-level LWW, nested collection requirements, LIST anti-patterns, collection size limits.

---

## Appendix C: Learning Objectives & Exercises

### Part 1 — Foundations (Modules 0-13)

**Learning Objectives**

After completing this part, you will be able to:
- Explain how replication factor and consistency level interact to determine quorum requirements
- Trace the write and read paths through a node, including memtable, commit log, and SSTable
- Describe how hinted handoff and read repair restore consistency after transient node failures
- Differentiate anti-entropy repair from read repair and explain when each applies
- Predict the impact of tombstones on read performance and compaction behavior
- Identify scenarios where Lightweight Transactions (LWT) are necessary and understand their cost

**Review Questions**

1. A cluster has RF=3 and you write at CL=QUORUM. How many nodes must acknowledge? (a) 1 (b) 2 (c) 3 (d) All replicas
2. Which mechanism temporarily stores a write on behalf of an unreachable node? (a) Read repair (b) Anti-entropy repair (c) Hinted handoff (d) Compaction
3. What is the primary risk of letting tombstones accumulate without running repair? (a) Token imbalance (b) Ghost reads of deleted data (c) Schema drift (d) Gossip timeouts
4. LWT uses Paxos. What is the minimum participants for CAS with RF=3? (a) 1 (b) 2 (c) 3 (d) Depends on CL
5. During a CL=QUORUM read, one replica returns a stale value. What happens? (a) Read fails (b) Stale replica removed (c) Background read repair triggered (d) Coordinator retries at CL=ONE

**Hands-on Challenges**

1. Kill one node, write 100 rows at CL=QUORUM, restart it, and use `nodetool tpstats` to confirm hints were delivered. Then run repair and verify consistency.
2. Create a table with `gc_grace_seconds=60`, delete 10 rows, wait 90 seconds, trigger manual compaction. Observe SSTable counts before/after with `nodetool cfstats`.

---

### Part 2 — Advanced Failures (Modules 14-24)

**Learning Objectives**

After completing this part, you will be able to:
- Identify symptoms of a ghost rack and schema disagreement, and how to recover
- Describe what happens to reads and writes during a network partition
- Configure and query a Storage-Attached Index (SAI) and explain its advantages over ALLOW FILTERING
- Perform JSON insert/select operations and describe their serialization behavior
- Interpret compaction metrics and explain when compaction falls behind

**Review Questions**

1. SAI differs from legacy 2i primarily because: (a) Separate process (b) Stored per-SSTable with range predicate support (c) Requires ALLOW FILTERING (d) Only indexes partition keys
2. During a full partition between dc1 and dc2, a write at CL=LOCAL_QUORUM will: (a) Fail (b) Succeed if local DC has quorum (c) Block indefinitely (d) Downgrade to CL=ONE
3. Schema disagreement most commonly results from: (a) Mismatched RF (b) A DDL not reaching all nodes (c) Compaction behind (d) Expired hints
4. Which compaction strategy suits a workload with mostly INSERT and no updates? (a) STCS (b) LCS (c) TWCS (d) UCS
5. A node appears DN in `nodetool status` but gossip shows UP. This suggests: (a) Ghost rack (b) Schema disagreement (c) Network partition (d) Hinted handoff overflow

**Hands-on Challenges**

1. Simulate a network partition between dc1 and dc2 using `docker network disconnect`, issue a write at CL=EACH_QUORUM, observe the failure, restore connectivity, and verify self-healing.
2. Create a table with an SAI index on a non-PK column. Compare query latency with and without the index using `TRACING ON`.

---

### Part 3 — Operations (Modules 25-37)

**Learning Objectives**

After completing this part, you will be able to:
- Enable and interpret CDC output for change stream processing
- Configure audit logging and guardrails to prevent runaway queries
- Select an appropriate compaction strategy based on workload access patterns
- Execute a zero-downtime rolling restart and validate cluster health at each step
- Design a backup and restore workflow using snapshots

**Review Questions**

1. CDC writes change records to: (a) A Kafka topic (b) The `cdc_raw` directory on each node (c) A CDC keyspace (d) The system log
2. For time-series data deleted by time window, which compaction strategy minimizes read amplification? (a) STCS (b) LCS (c) TWCS (d) No compaction
3. During a rolling restart with RF=3 and CL=QUORUM, writes will: (a) Fail (b) Succeed using remaining nodes (c) Block (d) Downgrade
4. `nodetool snapshot` creates: (a) A full backup to object storage (b) Hard links to current SSTables (c) A schema export (d) A compressed tarball
5. Guardrails can prevent: (a) Node failures (b) Unbounded IN clauses and full table scans (c) Schema disagreement (d) Compaction backlogs

**Hands-on Challenges**

1. Enable CDC on a table, insert 50 rows, then inspect the `cdc_raw` directory on node1 and identify the operation type for each mutation.
2. Perform a rolling restart of all 6 nodes one at a time, draining each before restart. Time the full cycle and document any client-visible errors.

---

### Part 4 — Performance (Modules 38-42)

**Learning Objectives**

After completing this part, you will be able to:
- Interpret `nodetool tpstats` output to identify thread pool saturation and dropped messages
- Choose between incremental and full repair strategies based on cluster size
- Run stress tests and interpret throughput and latency percentile output
- Configure basic RBAC in HCD

**Review Questions**

1. `MutationStage` shows a large `Blocked` count. This indicates: (a) Network partition (b) Writes arriving faster than the node can process (c) Failing disk (d) Schema disagreement
2. Incremental repair differs from full repair in that it: (a) Skips already-repaired SSTables (b) Only repairs locally (c) Runs automatically (d) Skips hints
3. With 6 nodes and `num_tokens=16`, token ownership is: (a) Exactly equal (b) Approximately equal with variance (c) Determined by seed (d) Fixed at 1/6
4. A super-user creates a role with `LOGIN=true` but no GRANTs. That role can: (a) Read all tables (b) Write system tables (c) Authenticate but access nothing (d) Access its own keyspace
5. Which thread pool handles read requests? (a) MutationStage (b) ReadStage (c) GossipStage (d) CompactionExecutor

**Hands-on Challenges**

1. Run 500 writes at CL=QUORUM while monitoring `nodetool tpstats`. Identify which thread pools are active and whether any messages were dropped.
2. Create a role `app_user` with login, grant SELECT on one keyspace, and verify it cannot write or read from another keyspace.

---

### Part 5 — Driver Policies (Modules 43-47)

**Learning Objectives**

After completing this part, you will be able to:
- Explain how TokenAware routing reduces coordinator hops and improves latency
- Configure speculative execution and describe the latency vs. resource trade-off
- Implement DC-aware load balancing with failover
- Select an appropriate retry policy for different failure modes

**Review Questions**

1. TokenAwarePolicy reduces latency by: (a) Caching results (b) Routing directly to partition-owning replicas (c) Bypassing the coordinator (d) Using persistent connections
2. Speculative execution's main risk is: (a) Duplicate writes if not idempotent (b) Token imbalance (c) GC pressure (d) Schema conflicts
3. A `WriteTimeoutException` at CL=QUORUM means: (a) Write definitely failed (b) Coordinator didn't get enough ACKs — write may or may not have applied (c) Row locked (d) Node down
4. With `DCAwareRoundRobinPolicy(local_dc='dc1')` and all dc1 nodes unreachable: (a) Queries fail (b) Driver can fall back to dc2 (c) Retries indefinitely (d) Queued locally
5. Which driver-demo.py subcommand demonstrates cross-DC failover? (a) token-aware (b) speculative (c) dc-failover (d) retry-policies

**Hands-on Challenges**

1. Run `driver-demo.py token-aware` with tracing enabled. Verify the coordinator is always a partition-owning replica for 10 queries.
2. Stop all dc1 nodes and run `driver-demo.py dc-failover --local-dc dc1`. Observe failover to dc2, restart dc1, and verify rebalancing.

---

### Part 6 — Transactions (Modules 48-53)

**Learning Objectives**

After completing this part, you will be able to:
- Articulate specific ACID guarantees HCD provides and where it deviates from RDBMS
- Construct a logged batch and explain when it guarantees atomicity
- Demonstrate the lost update problem and how LWT prevents it
- Implement a saga pattern with compensating transactions
- Apply the consistency decision framework to choose the right CL

**Review Questions**

1. A logged batch guarantees: (a) Full ACID isolation (b) Atomicity only — all or nothing, no isolation (c) Serializability (d) Durability across all replicas before returning
2. The lost update problem occurs because: (a) Async writes (b) Read-then-write is not atomic (c) Compaction merges versions (d) Tombstones suppress old values
3. `INSERT ... IF NOT EXISTS` uses which protocol? (a) Gossip (b) Paxos (c) Raft (d) Zab
4. A compensating transaction in the saga pattern: (a) Rolls back to a snapshot (b) Applies a logical undo of a prior step (c) Locks rows (d) Uses LWT to verify
5. For a financial debit that must never double-apply: (a) CL=ONE with retry (b) LWT with IF condition (c) CL=ALL (d) Logged batch at QUORUM

**Hands-on Challenges**

1. Reproduce the lost update: two concurrent sessions read a balance, compute, and write back. Verify the bug, then fix with LWT `UPDATE ... IF balance = X`.
2. Implement a two-step saga (debit A, credit B). Deliberately fail step 2 and write a compensating transaction. Document account states at each stage.

---

### Part 7 — Enterprise (Modules 54-61)

**Learning Objectives**

After completing this part, you will be able to:
- Interact with the HCD Data API using HTTP/REST for JSON document access
- Design keyspace-level isolation for multi-tenant workloads
- Execute a safe node decommission and verify token redistribution
- Identify silent data corruption symptoms and how checksums and repair detect it
- Analyze LWT contention metrics and apply mitigation strategies

**Review Questions**

1. The HCD Data API exposes data over: (a) Binary native protocol (b) REST/HTTP with JSON (c) gRPC (d) GraphQL
2. Multi-tenant isolation at keyspace level provides: (a) Hardware isolation (b) Logical separation with independent RF/compaction (c) Encrypted inter-tenant traffic (d) Separate gossip rings
3. `nodetool decommission` is safe when: (a) Node is seed (b) Enough replicas remain for RF (c) Zero pending hints (d) All repairs complete
4. Silent data corruption is dangerous because: (a) Immediate crash (b) Incorrect values without error signal (c) Corrupts commitlog (d) Gossip instability
5. High LWT contention is best reduced by: (a) Increasing RF (b) Partitioning contended rows (c) CL=ALL (d) Disabling speculative execution

**Hands-on Challenges**

1. Start the Data API (`make api`), use `curl` to insert 5 documents, retrieve with a filter, update one, and verify in cqlsh.
2. Decommission node6, verify token redistribution with `nodetool status`, then recommission by starting a new container.

---

### Part 8 — Ops Deep-Dives (Modules 62-71)

**Learning Objectives**

After completing this part, you will be able to:
- Configure RBAC roles with fine-grained permissions and verify enforcement
- Explain how TDE protects data at rest and its key rotation process
- Describe commitlog replay after a crash and what data can be lost
- Predict behavior when hints expire before delivery and the resulting data gaps
- Tune bloom filter false positive rates and cache sizes for read workloads

**Review Questions**

1. After a crash, HCD recovers in-flight writes by: (a) Re-reading hints (b) Replaying the commitlog (c) Full repair from seed (d) Reloading latest SSTable
2. Default hint window is 3 hours. A 4-hour outage means: (a) Hints replayed (b) Gap must be closed by repair (c) Auto repair triggered (d) CL=ALL used
3. A bloom filter false positive causes: (a) Write dropped (b) Unnecessary SSTable disk seek (c) Read repair triggered (d) Token reassignment
4. ALTER KEYSPACE RF change takes effect: (a) Immediately (b) After repair completes redistribution (c) After restart (d) Only for new tables
5. Materialized views carry consistency risk because: (a) Separate compaction (b) View updates applied asynchronously (c) Cannot query at QUORUM (d) Require LWT

**Hands-on Challenges**

1. Simulate crash recovery: `docker kill hcd-node3`, write 500 rows, restart node3, verify data present via `nodetool cfstats`.
2. Adjust bloom filter `bloom_filter_fp_chance` from 0.01 to 0.1 on a table and measure the impact on SSTable read counts.

---

### Part 9 — DORA Ransomware (Modules 72-78)

**Learning Objectives**

After completing this part, you will be able to:
- Map ransomware kill chain stages to a distributed database environment
- Configure MinIO Object Lock in WORM mode and validate immutability
- Implement commitlog archiving to immutable storage
- Execute a ransomware attack simulation and measure RTO
- Restore from WORM backups and validate data completeness
- Assess cluster compliance against DORA requirements using the scorecard

**Review Questions**

1. WORM storage protects backups by: (a) Encrypting with rotating keys (b) Preventing deletion for a retention period (c) Replicating to a second cluster (d) MFA access
2. In the attack simulation, the primary destructive operations are: (a) TRUNCATE + clearsnapshot (b) Commitlog corruption (c) Deleting gossip state (d) Removing seed config
3. Commitlog archiving to WORM provides: (a) Point-in-time recovery beyond snapshots (b) Faster bootstrap (c) Auto compaction of archives (d) Cross-DC schema sync
4. TRUNCATE in Cassandra: (a) Affects only one DC (b) Propagates to ALL replicas in ALL DCs (c) Creates tombstones (d) Is blocked by guardrails
5. The DORA scorecard validates: (a) Only backup integrity (b) Backup immutability, RTO, DC failover, and audit trail (c) Network segmentation (d) Encryption standards

**Hands-on Challenges**

1. Take a snapshot, upload to MinIO WORM, attempt to delete before retention expires. Confirm deletion is rejected.
2. Run the full ransomware simulation (module 75), record attack and restoration timestamps, compute actual RTO and compare against the DORA 2-hour threshold.

---

### Part 10 — Production Essentials (Modules 79-83)

**Learning Objectives**

After completing this part, you will be able to:
- Explain the counter implementation and its consistency limitations
- Use prepared statements to reduce parse overhead and prevent CQL injection
- Identify GC pause patterns and apply JVM tuning to reduce stop-the-world events
- Write partition-scoped CQL aggregation queries and understand coordinator-side cost
- Choose the appropriate collection type (list, set, map, frozen) for a given requirement

**Review Questions**

1. Counter columns cannot mix with non-counter columns because: (a) Different compaction (b) Incompatible write paths (c) Require CL=ALL (d) Stored in separate keyspace
2. Prepared statements improve performance by: (a) Caching results (b) Parsing once, reusing the plan (c) Compressing payloads (d) Bypassing coordinator
3. A long GC pause causes other nodes to: (a) Mark it down immediately (b) Time out requests, generating TimeoutException (c) Trigger repair (d) Reroute to seed
4. `SELECT COUNT(*) FROM large_table` is dangerous because: (a) Not supported (b) Requires CL=ALL (c) Coordinator aggregates all partitions, causing heap pressure (d) Locks the table
5. A `frozen<map<text, text>>` differs from non-frozen in that: (a) Cannot be queried (b) Entire map must be rewritten to change any entry (c) Supports per-entry TTL (d) Stored off-heap

**Hands-on Challenges**

1. Create a counter table, perform 1000 increments, then query aggregated values. Verify counter accuracy after running `nodetool repair -pr`.
2. Convert ad-hoc CQL in a Python script to use prepared statements. Benchmark 1000 executions with and without, and measure the p99 latency difference.

---

## Bibliography & References

1. Ponemon Institute / Gartner (attributed). *Cost of Data Center Outages*. Ponemon Institute, 2014. The widely cited $5,600–$9,000 per minute downtime figure originates from this era of research.

2. Sophos. *The State of Ransomware in Financial Services 2024*. Sophos Ltd., 2024. Reports that 65% of financial organizations were hit by ransomware.

3. Veeam Software. *2024 Ransomware Trends Report: Lessons Learned from 1,200 Victims and Nearly 3,000 Cyberattacks*. Veeam, 2024. Reports that 96% of ransomware attacks targeted backup infrastructure.

4. Reuters. *ICBC's U.S. Arm Hit by Ransomware Attack Disrupting Treasury Markets*. November 2023. LockBit ransomware struck ICBC's U.S. broker-dealer, forcing manual settlement of U.S. Treasury trades.

5. European Parliament and Council. *Regulation (EU) 2022/2554 — Digital Operational Resilience Act (DORA)*. Official Journal of the European Union, 2022. In force from 17 January 2025. https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32022R2554

6. Apache Software Foundation. *Apache Cassandra Documentation* (v4.x / v5.x). https://cassandra.apache.org/doc/latest/

7. DataStax. *DataStax Python Driver for Apache Cassandra — Documentation*. https://docs.datastax.com/en/developer/python-driver/latest/

8. K8ssandra Community. *K8ssandra Documentation: Kubernetes Operator for Apache Cassandra*. https://docs.k8ssandra.io/

9. Carpenter, Jeff, and Eben Hewitt. *Cassandra: The Definitive Guide*, 3rd Edition. O'Reilly Media, 2022. ISBN 978-1-098-11054-3.

10. DeCandia, Giuseppe, et al. "Dynamo: Amazon's Highly Available Key-Value Store." *ACM SIGOPS Operating Systems Review* 41(6), 2007. Foundational paper describing consistent hashing, hinted handoff, and eventual consistency.

11. Brewer, Eric A. "Towards Robust Distributed Systems." Keynote, *ACM PODC*, 2000. Introduced the CAP conjecture; formally proved by Gilbert and Lynch (2002).

12. Lamport, Leslie. "Paxos Made Simple." *ACM SIGACT News* 32(4), 2001. Foundational paper on Paxos consensus, which underlies Cassandra's LWT.

13. DataStax / IBM. *HCD (Hyperledger Cassandra Distribution) Documentation and Release Notes*. https://docs.datastax.com/en/hcd/

14. Abadi, Daniel. "Consistency Tradeoffs in Modern Distributed Database System Design." *IEEE Computer* 45(2), 2012. Introduces the PACELC model extending CAP.

15. Veeam Software. *Immutable Backups and the 3-2-1-1-0 Rule*. Veeam, 2023. Best practices for ransomware-resistant backup strategies.
