"""Unit tests for generate_topology() called directly as a Python function."""
import argparse
import sys
import os
import pytest
import yaml

# Add scripts/ to path so we can import directly
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from importlib import import_module

gen_topo = import_module("generate-topology")
generate_topology = gen_topo.generate_topology
parse_datacenters = gen_topo.parse_datacenters


class TestGenerateTopology:
    def test_single_node(self):
        result = generate_topology(1)
        assert "hcd-node1" in result
        assert "hcd-node2" not in result

    def test_default_three_nodes(self):
        result = generate_topology(3)
        assert "hcd-node1" in result
        assert "hcd-node3" in result
        assert "hcd-node4" not in result

    def test_multi_dc(self):
        dcs = [("dc1", 2), ("dc2", 2)]
        result = generate_topology(4, dcs=dcs)
        assert "CASSANDRA_DC: dc1" in result
        assert "CASSANDRA_DC: dc2" in result
        assert "hcd-node4" in result

    def test_custom_cluster_name(self):
        result = generate_topology(1, cluster_name="MyCluster")
        assert "MyCluster" in result

    def test_custom_subnet(self):
        result = generate_topology(2, subnet="10.0.0.0/24")
        assert "10.0.0.2" in result
        assert "10.0.0.3" in result
        assert "subnet: 10.0.0.0/24" in result

    def test_invalid_subnet_raises(self):
        with pytest.raises(ValueError, match="Invalid subnet"):
            generate_topology(1, subnet="999.999.0.0/24")

    def test_non_24_subnet_raises(self):
        with pytest.raises(ValueError, match="Only /24 subnets"):
            generate_topology(1, subnet="10.0.0.0/16")

    def test_zero_nodes_raises(self):
        with pytest.raises(ValueError, match="positive"):
            generate_topology(0)

    def test_negative_nodes_raises(self):
        with pytest.raises(ValueError, match="positive"):
            generate_topology(-1)

    def test_exceeds_subnet_capacity(self):
        with pytest.raises(ValueError, match="exceed subnet capacity"):
            generate_topology(254, subnet="10.0.0.0/24")

    def test_dc_sum_mismatch_raises(self):
        dcs = [("dc1", 2), ("dc2", 3)]
        with pytest.raises(ValueError, match="does not match"):
            generate_topology(3, dcs=dcs)  # sum is 5, not 3

    def test_always_uses_gossiping_snitch(self):
        result = generate_topology(3)  # single DC
        assert "GossipingPropertyFileSnitch" in result
        assert "SimpleSnitch" not in result

    def test_multi_dc_seeds(self):
        dcs = [("dc1", 3), ("dc2", 3)]
        result = generate_topology(6, dcs=dcs)
        # First DC seed is .2, second DC seed is first node of dc2 (.2 + 3 = .5)
        assert "172.28.0.2,172.28.0.5" in result

    def test_localhost_port_binding(self):
        result = generate_topology(1)
        assert "127.0.0.1:9042:9042" in result

    def test_security_hardening_present(self):
        result = generate_topology(1)
        assert "no-new-privileges:true" in result
        assert "nofile:" in result
        assert "memlock:" in result
        assert 'cpus: "0.50"' in result

    def test_depends_on_chain(self):
        result = generate_topology(3)
        assert "depends_on:" in result
        assert "condition: service_healthy" in result

    def test_volumes_generated(self):
        result = generate_topology(3)
        assert "hcd-node1-data:" in result
        assert "hcd-node2-data:" in result
        assert "hcd-node3-data:" in result

    def test_rack_distribution(self):
        dcs = [("dc1", 6)]
        result = generate_topology(6, dcs=dcs)
        assert "CASSANDRA_RACK: rack1" in result
        assert "CASSANDRA_RACK: rack2" in result
        assert "CASSANDRA_RACK: rack3" in result

    def test_max_capacity_node(self):
        """253 nodes should be the max for /24."""
        result = generate_topology(253, subnet="10.0.0.0/24")
        assert "hcd-node253" in result

    def test_single_dc_assigns_dc_and_racks(self):
        """Single-DC mode should still assign dc1 and distribute racks."""
        result = generate_topology(3)
        assert "CASSANDRA_DC: dc1" in result
        assert "CASSANDRA_RACK: rack1" in result
        assert "CASSANDRA_RACK: rack2" in result
        assert "CASSANDRA_RACK: rack3" in result

    def test_single_dc_two_seeds(self):
        """Single-DC with 3+ nodes should have two seeds."""
        result = generate_topology(6)
        for line in result.split("\n"):
            if "CASSANDRA_SEEDS:" in line and ":-" in line:
                # Extract the default value between :- and }
                default_seeds = line[line.find(":-") + 2 : line.rfind("}")]
                assert "," in default_seeds, f"3+ node single-DC should have two seeds, got: {default_seeds}"
                seeds = default_seeds.split(",")
                assert len(seeds) == 2, f"Expected exactly 2 seeds, got {len(seeds)}"
                break
        else:
            pytest.fail("CASSANDRA_SEEDS line not found in generated output")

    def test_single_node_single_seed(self):
        """Single node should have only one seed."""
        result = generate_topology(1)
        for line in result.split("\n"):
            if "CASSANDRA_SEEDS:" in line and ":-" in line:
                # Extract the default value between :- and }
                default_seeds = line[line.find(":-") + 2 : line.rfind("}")]
                assert "," not in default_seeds, f"Single node should have one seed, got: {default_seeds}"
                assert default_seeds == "172.28.0.2"
                break
        else:
            pytest.fail("CASSANDRA_SEEDS line not found in generated output")

    def test_generated_yaml_parses(self):
        """Generated output must be valid YAML."""
        result = generate_topology(6, dcs=[("dc1", 3), ("dc2", 3)])
        config = yaml.safe_load(result)
        assert "services" in config
        assert len(config["services"]) == 6
        assert "networks" in config
        assert "volumes" in config

    def test_depends_on_chain_correct(self):
        """Verify node N depends on node N-1 (linear chain)."""
        result = generate_topology(3)
        config = yaml.safe_load(result)
        assert "depends_on" not in config["services"]["hcd-node1"]
        assert "hcd-node1" in config["services"]["hcd-node2"]["depends_on"]
        assert "hcd-node2" in config["services"]["hcd-node3"]["depends_on"]

    def test_unique_ips(self):
        """All nodes must have unique IP addresses."""
        result = generate_topology(6, dcs=[("dc1", 3), ("dc2", 3)])
        config = yaml.safe_load(result)
        ips = []
        for svc in config["services"].values():
            ip = svc["networks"]["hcd-cluster"]["ipv4_address"]
            ips.append(ip)
        assert len(ips) == len(set(ips)), f"Duplicate IPs found: {ips}"

    def test_trailing_newline(self):
        """Generated output should end with a newline."""
        result = generate_topology(1)
        assert result.endswith("\n")


class TestParseDatacenters:
    def test_basic(self):
        result = parse_datacenters("dc1:2,dc2:3")
        assert result == [("dc1", 2), ("dc2", 3)]

    def test_whitespace(self):
        result = parse_datacenters("dc1 : 2 , dc2 : 3")
        assert result == [("dc1", 2), ("dc2", 3)]

    def test_single_dc(self):
        result = parse_datacenters("dc1:5")
        assert result == [("dc1", 5)]

    def test_invalid_format(self):
        with pytest.raises(argparse.ArgumentTypeError):
            parse_datacenters("invalid")

    def test_zero_count(self):
        with pytest.raises(argparse.ArgumentTypeError, match="positive"):
            parse_datacenters("dc1:0")
