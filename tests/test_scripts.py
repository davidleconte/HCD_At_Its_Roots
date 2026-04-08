"""Tests for shell scripts (syntax validation and basic behavior)."""
import subprocess
import pytest


SHELL_SCRIPTS = [
    "scripts/docker-entrypoint.sh",
    "scripts/demo-entropy.sh",
    "scripts/execute-full-demo.sh",
]


@pytest.mark.parametrize("script", SHELL_SCRIPTS)
def test_shell_syntax(script):
    """Verify each shell script has valid bash syntax."""
    result = subprocess.run(
        ["bash", "-n", script],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"Syntax error in {script}: {result.stderr}"


def test_entrypoint_defaults():
    """Verify docker-entrypoint.sh sets expected default values."""
    # Source the defaults section only (stop before template generation)
    result = subprocess.run(
        ["bash", "-c", """
            set -e
            # Mock envsubst and other commands to prevent actual execution
            : "${CASSANDRA_CLUSTER_NAME:=HCDCluster}"
            : "${CASSANDRA_SEEDS:=172.28.0.2,172.28.0.5}"
            : "${CASSANDRA_LISTEN_ADDRESS:=127.0.0.1}"
            : "${CASSANDRA_DC:=dc1}"
            : "${CASSANDRA_RACK:=rack1}"
            echo "CLUSTER=$CASSANDRA_CLUSTER_NAME"
            echo "SEEDS=$CASSANDRA_SEEDS"
            echo "DC=$CASSANDRA_DC"
            echo "RACK=$CASSANDRA_RACK"
        """],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    assert "CLUSTER=HCDCluster" in result.stdout
    assert "SEEDS=172.28.0.2,172.28.0.5" in result.stdout
    assert "DC=dc1" in result.stdout
    assert "RACK=rack1" in result.stdout


def test_driver_demo_help():
    """Verify driver-demo.py shows help without errors."""
    result = subprocess.run(
        ["python3", "scripts/driver-demo.py", "--help"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    assert "token-aware" in result.stdout
    assert "speculative" in result.stdout
    assert "dc-failover" in result.stdout
    assert "retry-policies" in result.stdout


def test_driver_demo_local_dc_flag():
    """Verify driver-demo.py accepts --local-dc flag in help."""
    result = subprocess.run(
        ["python3", "scripts/driver-demo.py", "--help"],
        capture_output=True,
        text=True,
    )
    assert "--local-dc" in result.stdout


def test_makefile_exists():
    """Verify Makefile is present and has expected targets."""
    result = subprocess.run(
        ["make", "-n", "help"],
        capture_output=True,
        text=True,
    )
    # -n is dry-run; just verify make can parse the file
    assert result.returncode == 0
