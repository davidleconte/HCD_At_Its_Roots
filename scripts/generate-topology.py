#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import os
import sys
import tempfile

def parse_datacenters(dc_str: str) -> list[tuple[str, int]]:
    """Parses 'dc1:2,dc2:3' into [('dc1', 2), ('dc2', 3)]"""
    try:
        dcs = []
        for part in dc_str.split(','):
            name, count = part.split(':')
            count = int(count.strip())
            if count <= 0:
                raise argparse.ArgumentTypeError(f'Node count must be positive, got {count} for {name.strip()}')
            dcs.append((name.strip(), count))
        return dcs
    except ValueError:
        raise argparse.ArgumentTypeError('Datacenters must be in format name:count,name:count')

def get_input(prompt: str, default: str) -> str:
    value = input(f"{prompt} [{default}]: ").strip()
    return value if value else default

def generate_topology(nodes_count: int, cluster_name: str = "HCDCluster", dcs: list[tuple[str, int]] | None = None, subnet: str = "172.28.0.0/24") -> str:
    """Generate a docker-compose.yml string for an HCD cluster.

    Args:
        nodes_count: Total number of nodes (must be positive).
        cluster_name: Cassandra cluster name.
        dcs: Optional list of (dc_name, count) tuples for multi-DC.
             If None, a single DC 'dc1' is used with rack distribution.
        subnet: /24 subnet for the cluster network (e.g., '172.28.0.0/24').

    Returns:
        A complete docker-compose.yml content as a string.

    Raises:
        ValueError: On invalid inputs (bad subnet, node count, DC mismatch).
    """
    # Validate subnet
    try:
        network = ipaddress.ip_network(subnet, strict=False)
    except ValueError as e:
        raise ValueError(f"Invalid subnet '{subnet}': {e}")

    # Only /24 subnets are supported (simplifies IP assignment)
    if network.prefixlen != 24:
        raise ValueError(f"Only /24 subnets are supported, got /{network.prefixlen}")

    # Validate node count fits in subnet (reserve .0 for network, .1 for gateway, .255 for broadcast)
    max_hosts = network.num_addresses - 3
    if nodes_count > max_hosts:
        raise ValueError(f"{nodes_count} nodes exceed subnet capacity ({max_hosts} usable addresses in {subnet})")

    if nodes_count <= 0:
        raise ValueError("Node count must be positive")

    # Validate DC counts sum matches nodes_count
    if dcs:
        dc_total = sum(count for _, count in dcs)
        if dc_total != nodes_count:
            raise ValueError(f"DC node counts sum ({dc_total}) does not match nodes_count ({nodes_count})")

    # Extract base IP from network address (e.g., "172.28.0" from "172.28.0.0/24")
    base_ip = str(network.network_address).rsplit('.', 1)[0]

    # Seed selection: one per DC in multi-DC, or 2 seeds for large single-DC clusters
    if dcs and len(dcs) > 1:
        seed_ips = [f"{base_ip}.2", f"{base_ip}.{dcs[0][1] + 2}"]
        seed_ip_str = ",".join(seed_ips)
    elif nodes_count >= 3:
        # Two seeds for clusters with 3+ nodes (Cassandra best practice).
        # Place second seed near the midpoint of the node range for even gossip spread.
        second_seed_offset = int(nodes_count / 2) + 2  # +2 because IPs start at .2
        second_seed_offset = min(second_seed_offset, nodes_count + 1)  # clamp to last node
        seed_ip_str = f"{base_ip}.2,{base_ip}.{second_seed_offset}"
    else:
        seed_ip_str = f"{base_ip}.2"
        
    # Always use GossipingPropertyFileSnitch for consistency when expanding later
    snitch = "GossipingPropertyFileSnitch"
    
    compose = [
        "x-hcd-common: &hcd-common",
        "  build: .",
        "  restart: on-failure:3",
        "  stop_grace_period: 120s",
        "  cap_drop:",
        "    - ALL",
        "  cap_add:",
        "    - NET_ADMIN",
        "  security_opt:",
        "    - no-new-privileges:true",
        "  ulimits:",
        "    nofile:",
        "      soft: 100000",
        "      hard: 100000",
        "    memlock:",
        "      soft: -1",
        "      hard: -1",
        "  logging:",
        "    driver: json-file",
        "    options:",
        '      max-size: "50m"',
        '      max-file: "3"',
        "  deploy:",
        "    resources:",
        "      limits:",
        '        cpus: "0.50"',
        "        memory: 1024M",
        "  networks:",
        "    hcd-cluster:",
        "",
        "x-healthcheck: &hcd-healthcheck",
        '  test: ["CMD-SHELL", "cqlsh -e \'SELECT release_version FROM system.local\' || exit 1"]',
        "  interval: 15s",
        "  timeout: 10s",
        "  retries: 15",
        "  start_period: 180s",
        "",
        "x-shared-env: &shared-env",
        f"  CASSANDRA_CLUSTER_NAME: ${{CASSANDRA_CLUSTER_NAME:-{cluster_name}}}",
        "  CASSANDRA_SEEDS: ${CASSANDRA_SEEDS:-" + seed_ip_str + "}",
        "  CASSANDRA_RPC_ADDRESS: 0.0.0.0",
        f"  CASSANDRA_ENDPOINT_SNITCH: {snitch}",
        "  MAX_HEAP_SIZE: ${MAX_HEAP_SIZE:-512M}",
        "  HEAP_NEWSIZE: ${HEAP_NEWSIZE:-100M}",
        "  # JMX Prometheus exporter (active only when jmx_prometheus_javaagent.jar exists)",
        "  JVM_EXTRA_OPTS: >-",
        "    -javaagent:/opt/hcd/jmx_prometheus_javaagent.jar=9404:/opt/hcd/jmx-exporter.yml",
        "",
        "services:"
    ]

    node_configs = []
    if dcs:
        node_idx = 1
        for dc_name, count in dcs:
            for j in range(count):
                node_configs.append((node_idx, dc_name, j))
                node_idx += 1
    else:
        # Single-DC: assign dc1 with rack distribution across 3 racks
        for i in range(1, nodes_count + 1):
            node_configs.append((i, "dc1", i - 1))

    prev_node = None
    for i, dc_name, dc_local in node_configs:
        ip = f"{base_ip}.{i+1}"
        node_name = f"hcd-node{i}"

        compose.extend([
            f"  {node_name}:",
            "    <<: *hcd-common",
            f"    container_name: {node_name}",
            f"    hostname: {node_name}",
            "    networks:",
            "      hcd-cluster:",
            f"        ipv4_address: {ip}",
            "    environment:",
            "      <<: *shared-env",
            f"      CASSANDRA_LISTEN_ADDRESS: {ip}",
            f"      CASSANDRA_BROADCAST_ADDRESS: {ip}",
        ])

        if dc_name:
            # Distribute nodes across 3 racks per DC (reset per DC)
            rack_idx = (dc_local % 3) + 1
            compose.append(f"      CASSANDRA_DC: {dc_name}")
            compose.append(f"      CASSANDRA_RACK: rack{rack_idx}")

        if i == 1:
            compose.append("    ports:")
            compose.append('      - "127.0.0.1:9042:9042"')

        if prev_node:
            compose.append("    depends_on:")
            compose.append(f"      {prev_node}:")
            compose.append("        condition: service_healthy")

        compose.append("    volumes:")
        compose.append(f"      - {node_name}-data:/var/lib/cassandra")
        compose.append("    healthcheck:")
        compose.append("      <<: *hcd-healthcheck")
        compose.append("")
        prev_node = node_name

    compose.extend([
        "networks:",
        "  hcd-cluster:",
        "    driver: bridge",
        "    ipam:",
        "      config:",
        f"        - subnet: {subnet}",
        "",
        "volumes:"
    ])
    
    for node_cfg in node_configs:
        compose.append(f"  hcd-node{node_cfg[0]}-data:")

    return "\n".join(compose) + "\n"

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate HCD Docker Topology")
    parser.add_argument("--nodes", type=int, default=3, help="Number of nodes to generate (ignored if --datacenters is used)")
    parser.add_argument("--datacenters", type=parse_datacenters, help="DC specification, e.g., 'dc1:2,dc2:2'")
    parser.add_argument("--cluster-name", default="HCDCluster", help="Cluster name")
    parser.add_argument("--subnet", default="172.28.0.0/24", help="Subnet for the cluster")
    parser.add_argument("-i", "--interactive", action="store_true", help="Interactive mode")
    args = parser.parse_args()

    if args.interactive:
        print("HCD Topology Generator (Interactive Mode)")
        print("==========================================")
        try:
            while True:
                try:
                    nodes = int(get_input("Enter number of nodes", "3"))
                    if nodes <= 0:
                        print("Node count must be positive. Try again.")
                        continue
                    break
                except ValueError:
                    print("Invalid number. Try again.")

            cluster_name = get_input("Enter cluster name", "HCDCluster")
            use_multi_dc = get_input("Use multi-datacenter topology? (y/n)", "n").lower().startswith('y')

            dcs = None
            if use_multi_dc:
                while True:
                    dc_spec = get_input("Enter datacenter configuration (e.g., 'dc1:2,dc2:3')", "dc1:2,dc2:1")
                    try:
                        dcs = parse_datacenters(dc_spec)
                        nodes = sum(count for _, count in dcs)
                        break
                    except (ValueError, argparse.ArgumentTypeError) as e:
                        print(f"Invalid format: {e}. Try again.")

            subnet = get_input("Enter subnet (/24 only)", "172.28.0.0/24")

            print("\nGenerating topology:")
            print(f"- Cluster: {cluster_name}")
            if dcs:
                dc_summary = ", ".join([f"{name} ({count} nodes)" for name, count in dcs])
                print(f"- Datacenters: {dc_summary}")
            print(f"- Total Nodes: {nodes}")
            print(f"- Network: {subnet}")

            args.nodes = nodes
            args.cluster_name = cluster_name
            args.datacenters = dcs
            args.subnet = subnet
        except (KeyboardInterrupt, EOFError):
            print("\nAborted.")
            sys.exit(0)
        except Exception as e:
            print(f"\nError during interactive input: {e}")
            sys.exit(1)
    else:
        if args.datacenters:
            args.nodes = sum(count for _, count in args.datacenters)

    output_file = "docker-compose.yml"
    backup_file = None
    if os.path.exists(output_file):
        backup_file = output_file + ".bak"
        os.rename(output_file, backup_file)
        print(f"Backed up existing {output_file} to {backup_file}")

    try:
        content = generate_topology(args.nodes, args.cluster_name, args.datacenters, args.subnet)
    except ValueError as e:
        # Restore backup if generation fails
        if backup_file and os.path.exists(backup_file):
            os.rename(backup_file, output_file)
            print(f"Restored {output_file} from backup.")
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Atomic write: write to temp file then rename to prevent partial output
    fd, tmp_path = tempfile.mkstemp(dir=".", prefix=".docker-compose-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.rename(tmp_path, output_file)
    except BaseException:
        os.unlink(tmp_path)
        if backup_file and os.path.exists(backup_file):
            os.rename(backup_file, output_file)
            print(f"Restored {output_file} from backup after write failure.")
        raise

    dc_info = f" across {len(args.datacenters)} datacenters" if args.datacenters else ""
    print(f"\nSuccessfully generated docker-compose.yml with {args.nodes} nodes{dc_info}.")
