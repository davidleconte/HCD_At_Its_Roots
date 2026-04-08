import subprocess
import pytest


def run_demo(*args):
    """Helper to run demo-entropy.sh with given arguments."""
    return subprocess.run(
        ["bash", "scripts/demo-entropy.sh", *args],
        capture_output=True,
        text=True,
    )


def test_dry_run_execution():
    """Verify the script runs through all modules in dry-run mode without errors."""
    result = run_demo("--dry-run", "--no-pause")
    assert result.returncode == 0, f"Script failed with stderr: {result.stderr}"
    assert "[DRY-RUN]" in result.stdout
    # Verify all 84 module headers appear
    for i in range(84):
        assert f"Module {i}:" in result.stdout, f"Module {i} header missing from full run"


def test_dry_run_no_docker_commands():
    """Verify dry-run mode never executes real docker commands."""
    result = run_demo("--dry-run", "--no-pause")
    assert result.returncode == 0
    assert "[EXEC]" not in result.stdout, "Dry-run should not produce [EXEC] markers"


def test_invalid_module():
    """Verify the script handles invalid module numbers gracefully."""
    result = run_demo("--dry-run", "99")
    assert "Invalid module number" in result.stdout
    assert "Valid: 0-83" in result.stdout


def test_boundary_module_valid():
    """Verify module 83 is accepted."""
    result = run_demo("--dry-run", "--no-pause", "83")
    assert result.returncode == 0
    assert "Module 83:" in result.stdout


def test_boundary_module_invalid():
    """Verify module 84 is rejected."""
    result = run_demo("--dry-run", "84")
    assert "Invalid module number" in result.stdout


def test_negative_module():
    """Verify negative module numbers are not treated as valid modules."""
    result = run_demo("--dry-run", "--no-pause", "-1")
    # -1 doesn't match [0-9]* so it's ignored (treated as unknown flag)
    # Script runs all modules since no valid module number was selected
    assert result.returncode == 0
    assert "Module 0:" in result.stdout


def test_module_zero_alone():
    """Verify module 0 (Introduction) runs independently."""
    result = run_demo("--dry-run", "--no-pause", "0")
    assert result.returncode == 0
    assert "Module 0:" in result.stdout
    assert "Module 1:" not in result.stdout, "Should only run module 0"


def test_color_output_present():
    """Verify color escape codes are present in output."""
    result = run_demo("--dry-run", "--no-pause", "0")
    assert result.returncode == 0
    # Check for ANSI escape sequences (color codes)
    assert "\033[" in result.stdout or "\x1b[" in result.stdout, \
        "Color escape codes should be present in output"


def test_takeaway_present_in_modules():
    """Verify takeaway summaries appear in module output."""
    result = run_demo("--dry-run", "--no-pause")
    assert result.returncode == 0
    assert "Takeaway" in result.stdout, "Takeaway sections should appear in output"


def test_lookfor_guidance_present():
    """Verify 'look for' guidance appears in module output."""
    result = run_demo("--dry-run", "--no-pause")
    assert result.returncode == 0
    assert ">>>" in result.stdout, "Lookfor guidance (>>>) should appear in output"


def test_combined_flags():
    """Verify --dry-run --no-pause with a module number work together."""
    result = run_demo("--dry-run", "--no-pause", "5")
    assert result.returncode == 0
    assert "Module 5:" in result.stdout
    assert "[DRY-RUN]" in result.stdout


def test_score_mode():
    """Verify --score flag runs scorecard and reports 84/84 pass."""
    result = run_demo("--score")
    assert result.returncode == 0
    assert "84" in result.stdout, "Scorecard should report 84 modules"
    assert "PASS" in result.stdout, "Scorecard should show PASS results"
    assert "100%" in result.stdout, "All modules should pass (100%)"


# Parameterized content tests: verify each module produces expected keywords.
# This replaces ~30 individual test functions with a single data-driven test.
MODULE_CONTENT_EXPECTATIONS = [
    ("0", ["cluster", "topology", "roadmap"]),
    ("1", ["replication", "rf=1", "rf=3"]),
    ("2", ["consistency", "quorum", "local_quorum"]),
    ("3", ["node failure", "hcd-node3", "still works"]),
    ("4", ["hinted handoff", "hint", "replay"]),
    ("5", ["read repair", "digest"]),
    ("6", ["anti-entropy", "repair", "merkle"]),
    ("7", ["token", "ring", "vnode"]),
    ("8", ["write path", "mutation", "commit"]),
    ("9", ["read path", "digest"]),
    ("10", ["recovery", "gossip", "hint"]),
    ("11", ["tombstone", "delete", "gc_grace"]),
    ("12", ["lightweight", "paxos", "if not exists"]),
    ("13", ["summary", "health", "schema"]),
    ("14", ["ghost", "rack", "failure"]),
    ("15", ["schema", "disagreement", "describecluster"]),
    ("16", ["gossip", "heartbeat"]),
    ("17", ["zombie", "partition", "network"]),
    ("18", ["sai", "index", "storage attached"]),
    ("19", ["json", "fromjson", "tojson"]),
    ("20", ["vector", "similarity", "ann"]),
    ("21", ["mutation", "upsert", "lww"]),
    ("22", ["compaction", "sstable", "merge"]),
    ("23", ["dc_failover"]),
    ("25", ["cdc"]),
    ("26", ["enableauditlog", "audit"]),
    ("27", ["guardrail", "batch"]),
    ("28", ["bad_model", "partition"]),
    ("31", ["compaction", "STCS", "LCS"]),
    ("32", ["compress", "LZ4", "Zstd"]),
    ("35", ["rebuild", "datacenter"]),
    ("36", ["snapshot", "backup"]),
    ("39", ["repair"]),
    ("41", ["role", "security"]),
    ("42", ["endpoint", "geographic", "getendpoints"]),
    ("43", ["tokenaware", "token-aware", "driver-demo"]),
    ("44", ["speculative"]),
    ("45", ["dc-failover", "failover"]),
    ("46", ["retry", "fallthrough"]),
    ("47", ["CHECKPOINT"]),
    ("48", ["acid", "atomicity"]),
    ("49", ["logged", "batchlog"]),
    ("50", ["lost update", "compare-and-swap", "accounts"]),
    ("51", ["bank", "payment"]),
    ("52", ["saga", "compensat"]),
    ("53", ["decision", "golden rules"]),
    ("54", ["data api", "rest", "8181"]),
    ("55", ["tenant", "isolation"]),
    ("56", ["decommission", "removenode"]),
    ("57", ["snapshot", "disaster", "restore"]),
    ("58", ["corrupt", "verify", "scrub"]),
    ("59", ["saga", "outbox", "compensat"]),
    ("60", ["contention", "paxos"]),
    ("61", ["merkle", "gc_grace", "zombie"]),
    ("62", ["role", "rbac", "authenticator"]),
    ("63", ["encrypt", "tde"]),
    ("64", ["commitlog", "crash"]),
    ("65", ["hint", "max_hint_window"]),
    ("66", ["replication", "alter keyspace"]),
    ("67", ["stream", "bootstrap", "netstats"]),
    ("68", ["materialized", "view"]),
    ("69", ["tablestats", "tpstats", "proxyhistograms"]),
    ("70", ["disconnect", "cross-dc", "diverge", "partition"]),
    ("71", ["bloom", "cache", "fp_chance"]),
    ("72", ["dora", "ransomware"]),
    ("73", ["snapshot", "worm", "integrity"]),
    ("74", ["commitlog", "pitr", "archiv"]),
    ("75", ["attack", "truncate", "ransom"]),
    ("76", ["recovery", "restore", "worm"]),
    ("77", ["failover", "disconnect", "datacenter", "partition"]),
    ("78", ["k8ssandra", "kubernetes", "auto-heal"]),
    ("79", ["counter", "increment", "non-idempotent"]),
    ("80", ["prepared", "idempoten", "driver"]),
    ("81", ["jvm", "heap", "gc", "compressedoops"]),
    ("82", ["aggregat", "count", "sum", "avg"]),
    ("83", ["frozen", "collection", "set", "map"]),
]


@pytest.mark.parametrize(
    "module_id,keywords",
    MODULE_CONTENT_EXPECTATIONS,
    ids=[f"module_{m}" for m, _ in MODULE_CONTENT_EXPECTATIONS],
)
def test_module_content(module_id, keywords):
    """Verify each module produces at least one of its expected keywords."""
    result = run_demo("--dry-run", "--no-pause", module_id)
    assert result.returncode == 0, f"Module {module_id} failed with stderr: {result.stderr}"
    stdout_lower = result.stdout.lower()
    found = any(kw.lower() in stdout_lower for kw in keywords)
    assert found, (
        f"Module {module_id} should contain one of {keywords}, "
        f"but none found in output"
    )


@pytest.mark.parametrize("module_id", [str(i) for i in range(84)])
def test_individual_modules_dry(module_id):
    """Verify each individual module runs in dry-run mode."""
    result = run_demo("--dry-run", "--no-pause", module_id)
    assert result.returncode == 0, f"Module {module_id} failed with stderr: {result.stderr}"
    assert f"Module {module_id}:" in result.stdout
