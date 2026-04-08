#!/usr/bin/env python3
"""
DataStax Python Driver demo helper for HCD Entropy modules 43-46.

Usage:
    driver-demo token-aware   [--contact-points IPS] [--keyspace KS] [--local-dc DC]
    driver-demo speculative   [--contact-points IPS] [--keyspace KS] [--enable-speculative]
    driver-demo dc-failover   [--contact-points IPS] [--keyspace KS] [--duration SECS]
    driver-demo retry-policies [--contact-points IPS] [--keyspace KS] [--policy POLICY]

Runs inside the HCD container via: docker exec hcd-nodeN driver-demo <subcommand>
"""

import argparse
import math
import sys
import time

try:
    from cassandra import ConsistencyLevel, WriteTimeout, ReadTimeout, Unavailable
    from cassandra.cluster import Cluster, NoHostAvailable
    from cassandra.policies import (
        DCAwareRoundRobinPolicy,
        TokenAwarePolicy,
        RoundRobinPolicy,
        ConstantSpeculativeExecutionPolicy,
        FallthroughRetryPolicy,
        RetryPolicy,
    )
except ImportError:
    print("ERROR: cassandra-driver package not found.", file=sys.stderr)
    print("Install it with: pip install cassandra-driver==3.29.2", file=sys.stderr)
    sys.exit(1)


# ─── Shared Helpers ──────────────────────────────────────────────────

def parse_contact_points(cp_str):
    return [s.strip() for s in cp_str.split(",")]


def ensure_table(session, table_ddl):
    session.execute(table_ddl)


def ip_to_dc(ip):
    """Map container IPs to DC names for display."""
    last_octet = int(ip.split(".")[-1])
    if last_octet <= 4:
        return "dc1"
    return "dc2"


def print_coordinator_summary(coordinators):
    """Print a histogram of coordinator usage."""
    counts = {}
    for ip in coordinators:
        key = f"{ip} ({ip_to_dc(ip)})"
        counts[key] = counts.get(key, 0) + 1
    print("\n[SUMMARY] Coordinator distribution:")
    for node, count in sorted(counts.items()):
        bar = "█" * count
        print(f"  {node}: {count:3d}  {bar}")


# ─── Subcommand 1: token-aware ──────────────────────────────────────

def cmd_token_aware(args):
    contact_points = parse_contact_points(args.contact_points)
    ks = args.keyspace

    # Phase 1: Round-Robin (naive — no token awareness)
    print("=" * 60)
    print("Phase 1: RoundRobinPolicy (naive — no token awareness)")
    print("=" * 60)
    print("The driver picks coordinators in rotation, regardless of")
    print("which node owns the data. Extra network hop required.\n")

    cluster_rr = Cluster(
        contact_points,
        load_balancing_policy=RoundRobinPolicy(),
        protocol_version=4,
    )
    try:
        session_rr = cluster_rr.connect(ks)
        ensure_table(session_rr, """
            CREATE TABLE IF NOT EXISTS driver_token_aware (
                id int PRIMARY KEY, payload text, written_by text
            )
        """)

        coordinators_rr = []
        for i in range(30):
            result = session_rr.execute(
                "INSERT INTO driver_token_aware (id, payload, written_by) "
                "VALUES (%s, %s, %s)",
                (i, f"round-robin-{i}", "naive"),
            )
            coord = str(result.response_future.coordinator_host or "unknown")
            coordinators_rr.append(coord)
            print(f"[WRITE] row={i:2d}  coordinator={coord} ({ip_to_dc(coord)})  policy=RoundRobin")

        print_coordinator_summary(coordinators_rr)
    finally:
        cluster_rr.shutdown()

    # Phase 2: TokenAwarePolicy + DCAwareRoundRobinPolicy
    print("\n" + "=" * 60)
    print("Phase 2: TokenAwarePolicy(DCAwareRoundRobinPolicy)")
    print("=" * 60)
    print("The driver routes each write directly to the replica that")
    print("owns the partition — zero coordinator hops.\n")

    cluster_ta = Cluster(
        contact_points,
        load_balancing_policy=TokenAwarePolicy(
            DCAwareRoundRobinPolicy(local_dc=args.local_dc)
        ),
        protocol_version=4,
    )
    try:
        session_ta = cluster_ta.connect(ks)

        coordinators_ta = []
        for i in range(30):
            result = session_ta.execute(
                "INSERT INTO driver_token_aware (id, payload, written_by) "
                "VALUES (%s, %s, %s)",
                (i + 100, f"token-aware-{i}", "smart"),
            )
            coord = str(result.response_future.coordinator_host or "unknown")
            coordinators_ta.append(coord)
            print(f"[WRITE] row={i:2d}  coordinator={coord} ({ip_to_dc(coord)})  policy=TokenAware")

        print_coordinator_summary(coordinators_ta)
    finally:
        cluster_ta.shutdown()

    # Summary comparison
    rr_unique = len(set(coordinators_rr))
    ta_unique = len(set(coordinators_ta))
    print("\n" + "=" * 60)
    print("[COMPARISON]")
    print(f"  RoundRobin:  used {rr_unique} distinct coordinators (random spread)")
    print(f"  TokenAware:  used {ta_unique} distinct coordinators (replica-targeted)")
    print("  TokenAware sends writes directly to the owning replica,")
    print("  eliminating the coordinator-to-replica network hop.")
    print("=" * 60)


# ─── Subcommand 2: speculative ──────────────────────────────────────

def cmd_speculative(args):
    contact_points = parse_contact_points(args.contact_points)
    ks = args.keyspace
    use_speculative = args.enable_speculative

    mode = "WITH" if use_speculative else "WITHOUT"
    print("=" * 60)
    print(f"Speculative Execution: {mode}")
    print("=" * 60)

    spec_policy = None
    if use_speculative:
        spec_policy = ConstantSpeculativeExecutionPolicy(delay=0.2, max_attempts=2)
        print("Policy: ConstantSpeculativeExecutionPolicy(delay=200ms, max_attempts=2)")
        print("If the primary replica hasn't responded in 200ms, a backup")
        print("request is sent to another replica. Fastest response wins.\n")
    else:
        print("No speculative execution — waiting for the single response.\n")

    kwargs = dict(
        contact_points=contact_points,
        load_balancing_policy=TokenAwarePolicy(
            DCAwareRoundRobinPolicy(local_dc=args.local_dc)
        ),
        protocol_version=4,
    )
    if spec_policy:
        kwargs["speculative_execution_policy"] = spec_policy

    cluster = Cluster(**kwargs)
    try:
        session = cluster.connect(ks)
        ensure_table(session, """
            CREATE TABLE IF NOT EXISTS driver_speculative (
                id int PRIMARY KEY, payload text
            )
        """)

        latencies = []
        for i in range(100):
            start = time.monotonic()
            session.execute(
                "INSERT INTO driver_speculative (id, payload) VALUES (%s, %s)",
                (i, f"spec-{mode}-{i}"),
            )
            elapsed_ms = (time.monotonic() - start) * 1000
            latencies.append(elapsed_ms)
            if i % 20 == 0:
                print(f"[WRITE] row={i:3d}  latency={elapsed_ms:.1f}ms")

        latencies.sort()
        n = len(latencies)
        p50 = latencies[max(0, math.ceil(n * 0.50) - 1)]
        p95 = latencies[max(0, math.ceil(n * 0.95) - 1)]
        p99 = latencies[max(0, math.ceil(n * 0.99) - 1)]

        print(f"\n[LATENCY] {mode} speculative execution (100 writes):")
        print(f"  p50  = {p50:6.1f} ms")
        print(f"  p95  = {p95:6.1f} ms")
        print(f"  p99  = {p99:6.1f} ms")
        print(f"  min  = {latencies[0]:6.1f} ms")
        print(f"  max  = {latencies[-1]:6.1f} ms")

        if use_speculative:
            print("\n  With speculative execution, p99 ≈ p50 because slow")
            print("  replicas are masked by backup requests to faster ones.")
        else:
            print("\n  Without speculative execution, p99 reflects the slowest")
            print("  replica — tail latency can spike during compaction/repair.")
    finally:
        cluster.shutdown()


# ─── Subcommand 3: dc-failover ──────────────────────────────────────

def cmd_dc_failover(args):
    contact_points = parse_contact_points(args.contact_points)
    ks = args.keyspace
    duration = args.duration

    print("=" * 60)
    print("Live DC Failover with DataStax Driver")
    print("=" * 60)
    print(f"Connecting with local_dc='{args.local_dc}' and used_hosts_per_remote_dc=3.")
    print(f"When {args.local_dc} goes down, the driver automatically routes to the remote DC.\n")

    cluster = Cluster(
        contact_points,
        load_balancing_policy=TokenAwarePolicy(
            DCAwareRoundRobinPolicy(
                local_dc=args.local_dc,
                used_hosts_per_remote_dc=3,
            )
        ),
        protocol_version=4,
        connect_timeout=10,
    )
    try:
        session = cluster.connect(ks)
        session.default_consistency_level = ConsistencyLevel.LOCAL_QUORUM
        ensure_table(session, """
            CREATE TABLE IF NOT EXISTS driver_failover (
                id int PRIMARY KEY, payload text, written_at text
            )
        """)

        total = 0
        success = 0
        errors = 0
        dc1_count = 0
        dc2_count = 0
        failover_detected = False
        failback_detected = False
        prev_dc = None

        start_time = time.monotonic()
        row_id = 0

        while (time.monotonic() - start_time) < duration:
            row_id += 1
            try:
                result = session.execute(
                    "INSERT INTO driver_failover (id, payload, written_at) "
                    "VALUES (%s, %s, %s)",
                    (row_id, f"failover-{row_id}", time.strftime("%H:%M:%S")),
                )
                coord = str(result.response_future.coordinator_host or "unknown")
                dc = ip_to_dc(coord)
                total += 1
                success += 1

                if dc == "dc1":
                    dc1_count += 1
                else:
                    dc2_count += 1

                marker = ""
                if prev_dc == "dc1" and dc == "dc2" and not failover_detected:
                    marker = "  ◄── FAILOVER to dc2!"
                    failover_detected = True
                elif prev_dc == "dc2" and dc == "dc1" and not failback_detected:
                    marker = "  ◄── FAILBACK to dc1!"
                    failback_detected = True
                prev_dc = dc

                print(f"[WRITE] row={row_id:3d}  coordinator={coord} ({dc})  status=OK{marker}")

            except (NoHostAvailable, WriteTimeout, Unavailable) as e:
                total += 1
                errors += 1
                ename = type(e).__name__
                print(f"[WRITE] row={row_id:3d}  coordinator=???           status=FAIL ({ename}: {e})")

            time.sleep(0.5)

        print(f"\n{'=' * 60}")
        print(f"[SUMMARY]")
        print(f"  Total writes:    {total}")
        print(f"  Successful:      {success}")
        print(f"  Errors:          {errors}")
        print(f"  Routed to dc1:   {dc1_count}")
        print(f"  Routed to dc2:   {dc2_count}")
        if failover_detected:
            print(f"  Failover:        DETECTED (dc1 → dc2)")
        if failback_detected:
            print(f"  Failback:        DETECTED (dc2 → dc1)")
        if errors == 0:
            print(f"  Result:          ZERO application errors during DC failure!")
        print(f"{'=' * 60}")
    finally:
        cluster.shutdown()


# ─── Subcommand 4: retry-policies ───────────────────────────────────

class AggressiveRetryPolicy(RetryPolicy):
    """Custom retry policy: retry on the next host up to MAX_RETRIES times."""

    MAX_RETRIES = 3

    def on_read_timeout(self, query, consistency, required_responses,
                        received_responses, data_retrieved, retry_num):
        if retry_num < self.MAX_RETRIES:
            return self.RETRY_NEXT_HOST, consistency
        return self.RETHROW, None

    def on_write_timeout(self, query, consistency, write_type,
                         required_responses, received_responses, retry_num):
        if retry_num < self.MAX_RETRIES:
            return self.RETRY_NEXT_HOST, consistency
        return self.RETHROW, None

    def on_unavailable(self, query, consistency, required_replicas,
                       alive_replicas, retry_num):
        if retry_num < self.MAX_RETRIES:
            return self.RETRY_NEXT_HOST, consistency
        return self.RETHROW, None


def cmd_retry_policies(args):
    contact_points = parse_contact_points(args.contact_points)
    ks = args.keyspace
    policy_name = args.policy

    print("=" * 60)
    print(f"Retry Policy: {policy_name.upper()}")
    print("=" * 60)

    if policy_name == "default":
        retry_policy = RetryPolicy()
        print("DefaultRetryPolicy: retries once on same host if enough")
        print("replicas responded. Otherwise rethrows to application.\n")
    elif policy_name == "fallthrough":
        retry_policy = FallthroughRetryPolicy()
        print("FallthroughRetryPolicy: NEVER retries. Every timeout or")
        print("unavailable exception is thrown directly to the application.\n")
    else:
        # policy_name == "custom" (enforced by argparse choices)
        retry_policy = AggressiveRetryPolicy()
        print("AggressiveRetryPolicy (custom): retries on NEXT HOST up to")
        print("3 times before giving up. Maximizes chance of success.\n")

    cluster = Cluster(
        contact_points,
        load_balancing_policy=TokenAwarePolicy(
            DCAwareRoundRobinPolicy(local_dc=args.local_dc)
        ),
        default_retry_policy=retry_policy,
        protocol_version=4,
    )
    try:
        session = cluster.connect(ks)
        session.default_consistency_level = ConsistencyLevel.LOCAL_QUORUM
        ensure_table(session, """
            CREATE TABLE IF NOT EXISTS driver_retry (
                id int PRIMARY KEY, payload text, policy text
            )
        """)

        success = 0
        errors = 0

        for i in range(20):
            try:
                result = session.execute(
                    "INSERT INTO driver_retry (id, payload, policy) "
                    "VALUES (%s, %s, %s)",
                    (i + (hash(policy_name) % 10000), f"retry-{policy_name}-{i}", policy_name),
                )
                coord = str(result.response_future.coordinator_host or "unknown")
                success += 1
                print(f"[WRITE] row={i:2d}  coordinator={coord} ({ip_to_dc(coord)})  status=OK")
            except (NoHostAvailable, WriteTimeout, ReadTimeout, Unavailable) as e:
                errors += 1
                ename = type(e).__name__
                print(f"[WRITE] row={i:2d}  coordinator=???           status=FAIL ({ename}: {e})")

        print(f"\n[SUMMARY] policy={policy_name}")
        print(f"  Writes attempted: 20")
        print(f"  Successful:       {success}")
        print(f"  Failed:           {errors}")

        if policy_name == "fallthrough":
            print("  → FallthroughRetryPolicy gives ZERO tolerance for errors.")
            print("    Any transient timeout immediately bubbles to the app.")
        elif policy_name == "custom":
            print("  → AggressiveRetryPolicy masks transient failures by trying")
            print("    up to 3 other replicas before giving up.")
        else:
            print("  → DefaultRetryPolicy provides a balanced single-retry approach.")
    finally:
        cluster.shutdown()


# ─── Main ────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="DataStax Python Driver demo for HCD Entropy modules."
    )
    parser.add_argument(
        "--contact-points",
        default="172.28.0.2,172.28.0.3,172.28.0.4,172.28.0.5,172.28.0.6,172.28.0.7",
        help="Comma-separated list of contact points",
    )
    parser.add_argument(
        "--keyspace", default="rf_prod",
        help="Keyspace to use (default: rf_prod)",
    )
    parser.add_argument(
        "--local-dc", default="dc1",
        help="Local datacenter for DCAwareRoundRobinPolicy (default: dc1)",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("token-aware", help="Compare RoundRobin vs TokenAware routing")

    spec = sub.add_parser("speculative", help="Measure speculative execution impact")
    spec.add_argument("--enable-speculative", action="store_true")

    fail = sub.add_parser("dc-failover", help="Live DC failover under continuous writes")
    fail.add_argument("--duration", type=int, default=60, help="Duration in seconds")

    retry = sub.add_parser("retry-policies", help="Compare retry policies under failure")
    retry.add_argument("--policy", choices=["default", "fallthrough", "custom"],
                       default="default")

    args = parser.parse_args()

    commands = {
        "token-aware": cmd_token_aware,
        "speculative": cmd_speculative,
        "dc-failover": cmd_dc_failover,
        "retry-policies": cmd_retry_policies,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()
