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
    # Verify all 72 module headers appear
    for i in range(72):
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
    assert "Valid: 0-71" in result.stdout


def test_boundary_module_valid():
    """Verify module 71 is accepted."""
    result = run_demo("--dry-run", "--no-pause", "71")
    assert result.returncode == 0
    assert "Module 71:" in result.stdout


def test_boundary_module_invalid():
    """Verify module 72 is rejected."""
    result = run_demo("--dry-run", "72")
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


def test_module_23_datacenter_kill_content():
    """Verify module 23 has datacenter failover content."""
    result = run_demo("--dry-run", "--no-pause", "23")
    assert result.returncode == 0
    assert "dc_failover" in result.stdout, "Module 23 should reference dc_failover table"


def test_module_25_cdc_content():
    """Verify module 25 has CDC-specific content."""
    result = run_demo("--dry-run", "--no-pause", "25")
    assert result.returncode == 0
    assert "cdc" in result.stdout.lower(), "Module 25 should reference CDC"


def test_module_26_audit_content():
    """Verify module 26 has audit logging content."""
    result = run_demo("--dry-run", "--no-pause", "26")
    assert result.returncode == 0
    assert "enableauditlog" in result.stdout or "audit" in result.stdout.lower(), \
        "Module 26 should reference audit logging"


def test_module_27_guardrails_content():
    """Verify module 27 has guardrails content."""
    result = run_demo("--dry-run", "--no-pause", "27")
    assert result.returncode == 0
    assert "guardrail" in result.stdout.lower() or "batch" in result.stdout.lower(), \
        "Module 27 should reference guardrails"


def test_module_28_data_modeling_content():
    """Verify module 28 has data modeling anti-pattern content."""
    result = run_demo("--dry-run", "--no-pause", "28")
    assert result.returncode == 0
    assert "bad_model" in result.stdout or "partition" in result.stdout.lower(), \
        "Module 28 should reference data modeling"


def test_module_31_compaction_content():
    """Verify module 31 has compaction strategy content."""
    result = run_demo("--dry-run", "--no-pause", "31")
    assert result.returncode == 0
    assert "compaction" in result.stdout.lower() or "STCS" in result.stdout or "LCS" in result.stdout, \
        "Module 31 should reference compaction strategies"


def test_module_32_compression_content():
    """Verify module 32 has compression content."""
    result = run_demo("--dry-run", "--no-pause", "32")
    assert result.returncode == 0
    assert "compress" in result.stdout.lower() or "LZ4" in result.stdout or "Zstd" in result.stdout, \
        "Module 32 should reference compression"


def test_module_35_adding_dc_content():
    """Verify module 35 has datacenter expansion content."""
    result = run_demo("--dry-run", "--no-pause", "35")
    assert result.returncode == 0
    assert "rebuild" in result.stdout.lower() or "datacenter" in result.stdout.lower(), \
        "Module 35 should reference adding a datacenter"


def test_module_36_backup_content():
    """Verify module 36 has backup and restore content."""
    result = run_demo("--dry-run", "--no-pause", "36")
    assert result.returncode == 0
    assert "snapshot" in result.stdout.lower() or "backup" in result.stdout.lower(), \
        "Module 36 should reference backup/snapshot"


def test_module_39_repair_content():
    """Verify module 39 has repair strategy content."""
    result = run_demo("--dry-run", "--no-pause", "39")
    assert result.returncode == 0
    assert "repair" in result.stdout.lower(), \
        "Module 39 should reference repair strategies"


def test_module_41_security_content():
    """Verify module 41 has security content."""
    result = run_demo("--dry-run", "--no-pause", "41")
    assert result.returncode == 0
    assert "role" in result.stdout.lower() or "security" in result.stdout.lower(), \
        "Module 41 should reference security"


def test_module_42_geographic_content():
    """Verify module 42 has geographic visualization content."""
    result = run_demo("--dry-run", "--no-pause", "42")
    assert result.returncode == 0
    assert "endpoint" in result.stdout.lower() or "geographic" in result.stdout.lower() \
        or "getendpoints" in result.stdout.lower(), \
        "Module 42 should reference geographic visualization"


def test_module_43_driver_policies_content():
    """Verify module 43 has driver policy content."""
    result = run_demo("--dry-run", "--no-pause", "43")
    assert result.returncode == 0
    assert "tokenaware" in result.stdout.lower() or "token-aware" in result.stdout.lower() \
        or "driver-demo" in result.stdout, \
        "Module 43 should reference TokenAware driver policies"


def test_module_44_speculative_content():
    """Verify module 44 has speculative execution content."""
    result = run_demo("--dry-run", "--no-pause", "44")
    assert result.returncode == 0
    assert "speculative" in result.stdout.lower(), \
        "Module 44 should reference speculative execution"


def test_module_45_dc_failover_driver_content():
    """Verify module 45 has driver DC failover content."""
    result = run_demo("--dry-run", "--no-pause", "45")
    assert result.returncode == 0
    assert "dc-failover" in result.stdout or "failover" in result.stdout.lower(), \
        "Module 45 should reference driver DC failover"


def test_module_46_retry_policies_content():
    """Verify module 46 has retry policy content."""
    result = run_demo("--dry-run", "--no-pause", "46")
    assert result.returncode == 0
    assert "retry" in result.stdout.lower() or "fallthrough" in result.stdout.lower(), \
        "Module 46 should reference retry policies"


def test_module_47_summary_dashboard():
    """Verify module 47 has summary dashboard content."""
    result = run_demo("--dry-run", "--no-pause", "47")
    assert result.returncode == 0
    assert "SUMMARY DASHBOARD" in result.stdout, \
        "Module 47 should contain the summary dashboard"


def test_module_48_acid_content():
    """Verify module 48 has ACID vs HCD content."""
    result = run_demo("--dry-run", "--no-pause", "48")
    assert result.returncode == 0
    assert "acid" in result.stdout.lower() or "atomicity" in result.stdout.lower(), \
        "Module 48 should reference ACID model"


def test_module_49_batch_content():
    """Verify module 49 has LOGGED/UNLOGGED batch content."""
    result = run_demo("--dry-run", "--no-pause", "49")
    assert result.returncode == 0
    assert "logged" in result.stdout.lower() or "batchlog" in result.stdout.lower(), \
        "Module 49 should reference LOGGED batch"


def test_module_50_lost_update_content():
    """Verify module 50 has lost update / read-modify-write content."""
    result = run_demo("--dry-run", "--no-pause", "50")
    assert result.returncode == 0
    assert "lost update" in result.stdout.lower() or "compare-and-swap" in result.stdout.lower() \
        or "accounts" in result.stdout, \
        "Module 50 should reference the lost update problem"


def test_module_51_banking_content():
    """Verify module 51 has banking/payment content."""
    result = run_demo("--dry-run", "--no-pause", "51")
    assert result.returncode == 0
    assert "bank" in result.stdout.lower() or "payment" in result.stdout.lower(), \
        "Module 51 should reference banking/payments"


def test_module_52_saga_content():
    """Verify module 52 has saga pattern content."""
    result = run_demo("--dry-run", "--no-pause", "52")
    assert result.returncode == 0
    assert "saga" in result.stdout.lower() or "compensat" in result.stdout.lower(), \
        "Module 52 should reference saga pattern"


def test_module_53_decision_framework():
    """Verify module 53 has decision framework content."""
    result = run_demo("--dry-run", "--no-pause", "53")
    assert result.returncode == 0
    assert "decision" in result.stdout.lower() or "golden rules" in result.stdout.lower(), \
        "Module 53 should reference the decision framework"


def test_module_62_rbac_content():
    """Verify module 62 has RBAC content."""
    result = run_demo("--dry-run", "--no-pause", "62")
    assert result.returncode == 0
    assert "role" in result.stdout.lower() or "rbac" in result.stdout.lower() \
        or "authenticator" in result.stdout.lower(), \
        "Module 62 should reference RBAC"


def test_module_63_tde_content():
    """Verify module 63 has encryption at rest content."""
    result = run_demo("--dry-run", "--no-pause", "63")
    assert result.returncode == 0
    assert "encrypt" in result.stdout.lower() or "tde" in result.stdout.lower(), \
        "Module 63 should reference encryption"


def test_module_64_commitlog_content():
    """Verify module 64 has commitlog crash recovery content."""
    result = run_demo("--dry-run", "--no-pause", "64")
    assert result.returncode == 0
    assert "commitlog" in result.stdout.lower() or "crash" in result.stdout.lower(), \
        "Module 64 should reference commitlog recovery"


def test_module_65_hint_expiration_content():
    """Verify module 65 has hint expiration content."""
    result = run_demo("--dry-run", "--no-pause", "65")
    assert result.returncode == 0
    assert "hint" in result.stdout.lower() or "max_hint_window" in result.stdout.lower(), \
        "Module 65 should reference hint expiration"


def test_module_66_rf_change_content():
    """Verify module 66 has dynamic RF change content."""
    result = run_demo("--dry-run", "--no-pause", "66")
    assert result.returncode == 0
    assert "replication" in result.stdout.lower() or "alter keyspace" in result.stdout.lower(), \
        "Module 66 should reference replication factor change"


def test_module_67_streaming_content():
    """Verify module 67 has streaming/bootstrap content."""
    result = run_demo("--dry-run", "--no-pause", "67")
    assert result.returncode == 0
    assert "stream" in result.stdout.lower() or "bootstrap" in result.stdout.lower() \
        or "netstats" in result.stdout.lower(), \
        "Module 67 should reference streaming"


def test_module_68_mv_content():
    """Verify module 68 has materialized view content."""
    result = run_demo("--dry-run", "--no-pause", "68")
    assert result.returncode == 0
    assert "materialized" in result.stdout.lower() or "view" in result.stdout.lower(), \
        "Module 68 should reference materialized views"


def test_module_69_nodetool_content():
    """Verify module 69 has nodetool ops content."""
    result = run_demo("--dry-run", "--no-pause", "69")
    assert result.returncode == 0
    assert "tablestats" in result.stdout.lower() or "tpstats" in result.stdout.lower() \
        or "proxyhistograms" in result.stdout.lower(), \
        "Module 69 should reference nodetool operations"


def test_module_70_cross_dc_content():
    """Verify module 70 has cross-DC consistency content."""
    result = run_demo("--dry-run", "--no-pause", "70")
    assert result.returncode == 0
    assert "disconnect" in result.stdout.lower() or "cross-dc" in result.stdout.lower() \
        or "diverge" in result.stdout.lower() or "partition" in result.stdout.lower(), \
        "Module 70 should reference cross-DC consistency"


def test_module_71_bloom_filter_content():
    """Verify module 71 has bloom filter/cache tuning content."""
    result = run_demo("--dry-run", "--no-pause", "71")
    assert result.returncode == 0
    assert "bloom" in result.stdout.lower() or "cache" in result.stdout.lower() \
        or "fp_chance" in result.stdout.lower(), \
        "Module 71 should reference bloom filter or cache tuning"


@pytest.mark.parametrize("module_id", [str(i) for i in range(72)])
def test_individual_modules_dry(module_id):
    """Verify each individual module runs in dry-run mode."""
    result = run_demo("--dry-run", "--no-pause", module_id)
    assert result.returncode == 0, f"Module {module_id} failed with stderr: {result.stderr}"
    assert f"Module {module_id}:" in result.stdout
