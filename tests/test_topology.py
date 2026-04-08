import subprocess
import shutil
import yaml
import pytest


@pytest.fixture
def topology_workdir(tmp_path):
    """Create a temporary working directory with the topology script."""
    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir()
    shutil.copy("scripts/generate-topology.py", scripts_dir / "generate-topology.py")
    return tmp_path


def test_default_topology_generation(topology_workdir):
    """Verify default topology generation creates a valid 3-node compose file."""
    result = subprocess.run(
        ["python3", "scripts/generate-topology.py", "--nodes", "3"],
        capture_output=True,
        text=True,
        cwd=str(topology_workdir),
    )
    assert result.returncode == 0

    compose_file = topology_workdir / "docker-compose.yml"
    assert compose_file.exists()

    with open(compose_file, "r") as f:
        config = yaml.safe_load(f)

    assert len(config["services"]) == 3
    assert "hcd-node1" in config["services"]
    assert "hcd-node2" in config["services"]
    assert "hcd-node3" in config["services"]


def test_multi_dc_topology_generation(topology_workdir):
    """Verify multi-DC topology generation with specific node counts."""
    result = subprocess.run(
        ["python3", "scripts/generate-topology.py", "--datacenters", "dc1:2,dc2:1"],
        capture_output=True,
        text=True,
        cwd=str(topology_workdir),
    )
    assert result.returncode == 0

    compose_file = topology_workdir / "docker-compose.yml"
    with open(compose_file, "r") as f:
        content = f.read()
        assert "CASSANDRA_DC: dc1" in content
        assert "CASSANDRA_DC: dc2" in content
        assert "hcd-node1" in content
        assert "hcd-node2" in content
        assert "hcd-node3" in content
        assert "hcd-node4" not in content


def test_single_node_topology(topology_workdir):
    """Verify single-node topology generation."""
    result = subprocess.run(
        ["python3", "scripts/generate-topology.py", "--nodes", "1"],
        capture_output=True,
        text=True,
        cwd=str(topology_workdir),
    )
    assert result.returncode == 0

    compose_file = topology_workdir / "docker-compose.yml"
    with open(compose_file, "r") as f:
        config = yaml.safe_load(f)

    assert len(config["services"]) == 1
    assert "hcd-node1" in config["services"]


def test_invalid_node_count(topology_workdir):
    """Verify zero or negative node count is rejected."""
    result = subprocess.run(
        ["python3", "scripts/generate-topology.py", "--nodes", "0"],
        capture_output=True,
        text=True,
        cwd=str(topology_workdir),
    )
    assert result.returncode != 0


def test_invalid_subnet(topology_workdir):
    """Verify invalid subnet is rejected."""
    result = subprocess.run(
        ["python3", "scripts/generate-topology.py", "--nodes", "3", "--subnet", "999.999.0.0/24"],
        capture_output=True,
        text=True,
        cwd=str(topology_workdir),
    )
    assert result.returncode != 0
    assert "Invalid subnet" in result.stderr


def test_backup_created_on_overwrite(topology_workdir):
    """Verify existing docker-compose.yml is backed up before overwrite."""
    compose_file = topology_workdir / "docker-compose.yml"
    compose_file.write_text("original content")

    result = subprocess.run(
        ["python3", "scripts/generate-topology.py", "--nodes", "3"],
        capture_output=True,
        text=True,
        cwd=str(topology_workdir),
    )
    assert result.returncode == 0

    backup_file = topology_workdir / "docker-compose.yml.bak"
    assert backup_file.exists()
    assert backup_file.read_text() == "original content"


def test_backup_restored_on_error(topology_workdir):
    """Verify docker-compose.yml is restored from backup when generation fails."""
    compose_file = topology_workdir / "docker-compose.yml"
    compose_file.write_text("original content")

    # Use --subnet with non-/24 prefix to trigger a ValueError
    result = subprocess.run(
        ["python3", "scripts/generate-topology.py", "--nodes", "3", "--subnet", "10.0.0.0/16"],
        capture_output=True,
        text=True,
        cwd=str(topology_workdir),
    )
    assert result.returncode != 0

    # Original file should be restored
    assert compose_file.exists()
    assert compose_file.read_text() == "original content"
