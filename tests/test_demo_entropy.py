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
    # Verify all 85 module headers appear
    for i in range(85):
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
    assert "Valid: 0-84" in result.stdout


def test_boundary_module_valid():
    """Verify module 84 is accepted."""
    result = run_demo("--dry-run", "--no-pause", "84")
    assert result.returncode == 0
    assert "Module 84:" in result.stdout


def test_boundary_module_invalid():
    """Verify module 85 is rejected."""
    result = run_demo("--dry-run", "85")
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
    """Verify --score flag runs scorecard and reports 85/85 pass."""
    result = run_demo("--score")
    assert result.returncode == 0
    assert "85" in result.stdout and ("85/85" in result.stdout or "Score:  100%" in result.stdout), \
        "Scorecard should report 85 modules with 85/85 pass or 100%"
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
    ("20", ["json", "udt", "enterprise", "versioning"]),
    ("21", ["vector", "similarity", "ann"]),
    ("22", ["mutation", "upsert", "lww"]),
    ("23", ["compaction", "sstable", "merge"]),
    ("24", ["dc_failover"]),
    ("25", ["self-healing", "cascading", "grand finale"]),
    ("26", ["cdc"]),
    ("27", ["enableauditlog", "audit"]),
    ("28", ["guardrail", "batch"]),
    ("29", ["bad_model", "partition"]),
    ("30", ["latency", "local_quorum", "consistency"]),
    ("31", ["time-series", "time_series", "ttl", "windowed"]),
    ("32", ["compaction", "STCS", "LCS"]),
    ("33", ["compress", "LZ4", "Zstd"]),
    ("34", ["failover", "load", "write"]),
    ("35", ["conflict", "multi-dc", "timestamp"]),
    ("36", ["rebuild", "datacenter"]),
    ("37", ["snapshot", "backup"]),
    ("38", ["rolling", "restart", "seed"]),
    ("39", ["thread", "tpstats", "pool"]),
    ("40", ["repair"]),
    ("41", ["stress", "bloom", "insert"]),
    ("42", ["role", "security"]),
    ("43", ["endpoint", "geographic", "getendpoints"]),
    ("44", ["tokenaware", "token-aware", "driver-demo"]),
    ("45", ["speculative"]),
    ("46", ["dc-failover", "failover"]),
    ("47", ["retry", "fallthrough"]),
    ("48", ["CHECKPOINT"]),
    ("49", ["acid", "atomicity"]),
    ("50", ["logged", "batchlog"]),
    ("51", ["lost update", "compare-and-swap", "accounts"]),
    ("52", ["bank", "payment"]),
    ("53", ["saga", "compensat"]),
    ("54", ["decision", "golden rules"]),
    ("55", ["data api", "rest", "8181"]),
    ("56", ["tenant", "isolation"]),
    ("57", ["decommission", "removenode"]),
    ("58", ["snapshot", "disaster", "restore"]),
    ("59", ["corrupt", "verify", "scrub"]),
    ("60", ["saga", "outbox", "compensat"]),
    ("61", ["contention", "paxos"]),
    ("62", ["merkle", "gc_grace", "zombie"]),
    ("63", ["role", "rbac", "authenticator"]),
    ("64", ["encrypt", "tde"]),
    ("65", ["commitlog", "crash"]),
    ("66", ["hint", "max_hint_window"]),
    ("67", ["replication", "alter keyspace"]),
    ("68", ["stream", "bootstrap", "netstats"]),
    ("69", ["materialized", "view"]),
    ("70", ["tablestats", "tpstats", "proxyhistograms"]),
    ("71", ["disconnect", "cross-dc", "diverge", "partition"]),
    ("72", ["bloom", "cache", "fp_chance"]),
    ("73", ["dora", "ransomware"]),
    ("74", ["snapshot", "worm", "integrity"]),
    ("75", ["commitlog", "pitr", "archiv"]),
    ("76", ["attack", "truncate", "ransom"]),
    ("77", ["recovery", "restore", "worm"]),
    ("78", ["failover", "disconnect", "datacenter", "partition"]),
    ("79", ["k8ssandra", "kubernetes", "auto-heal"]),
    ("80", ["counter", "increment", "non-idempotent"]),
    ("81", ["prepared", "idempoten", "driver"]),
    ("82", ["jvm", "heap", "gc", "compressedoops"]),
    ("83", ["aggregat", "count", "sum", "avg"]),
    ("84", ["frozen", "collection", "set", "map"]),
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


@pytest.mark.parametrize("module_id", [str(i) for i in range(85)])
def test_individual_modules_dry(module_id):
    """Verify each individual module runs in dry-run mode."""
    result = run_demo("--dry-run", "--no-pause", module_id)
    assert result.returncode == 0, f"Module {module_id} failed with stderr: {result.stderr}"
    assert f"Module {module_id}:" in result.stdout
