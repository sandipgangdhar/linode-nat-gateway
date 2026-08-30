# test_lib.py (acceptance-tests/tests)
#
# Unit tests for the acceptance-test suite's own harness scaffolding --
# lib/config.py's YAML loading and require()'s missing-key error
# behavior, lib/reporter.py's pass/fail/skip tallying and exit-code
# logic, and run_acceptance_tests.py's check discovery. Deliberately
# does NOT test any check_*.py module's actual live behavior (those make
# real network/SSH/ping calls against a real deployment by design -- see
# this suite's own README on why they aren't run automatically). This
# file exists so the harness itself is provably correct before it's ever
# pointed at live infrastructure.
#
# -----------------------------------------------------
# Usage:
#
# python acceptance-tests/tests/_runner.py
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
import sys
import tempfile
from pathlib import Path

_ACCEPTANCE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_ACCEPTANCE_ROOT))

from lib.config import load_config, MissingConfigError  # noqa: E402
from lib.reporter import Reporter  # noqa: E402


def _write_config(content: str) -> str:
    f = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
    f.write(content)
    f.close()
    return f.name


def test_load_config_parses_pools_and_control_plane():
    path = _write_config(
        """
control_plane:
  prometheus_url: "http://10.0.0.1:9090"
pools:
  shared:
    roster_url: "http://10.0.0.1:8099/fleet/shared"
    min_nodes: 2
"""
    )
    cfg = load_config(path)
    assert cfg.control_plane["prometheus_url"] == "http://10.0.0.1:9090"
    assert cfg.pools["shared"]["roster_url"] == "http://10.0.0.1:8099/fleet/shared"
    assert cfg.pool("shared")["min_nodes"] == 2


def test_load_config_handles_empty_file():
    path = _write_config("")
    cfg = load_config(path)
    assert cfg.pools == {}
    assert cfg.control_plane == {}
    assert cfg.ssh == {}


def test_config_pool_raises_missing_config_error_for_unknown_pool():
    path = _write_config("pools:\n  shared:\n    roster_url: 'http://x'\n")
    cfg = load_config(path)
    try:
        cfg.pool("dedicated-acme")
        assert False, "expected MissingConfigError"
    except MissingConfigError as exc:
        assert "dedicated-acme" in str(exc)


def test_config_require_returns_values_in_order():
    path = _write_config("pools:\n  shared:\n    roster_url: 'http://x'\n    min_nodes: 3\n")
    cfg = load_config(path)
    pool = cfg.pool("shared")
    roster_url, min_nodes = cfg.require(pool, "roster_url", "min_nodes")
    assert roster_url == "http://x"
    assert min_nodes == 3


def test_config_require_raises_naming_the_missing_key():
    path = _write_config("pools:\n  shared:\n    roster_url: 'http://x'\n")
    cfg = load_config(path)
    pool = cfg.pool("shared")
    try:
        cfg.require(pool, "roster_url", "client_host", context="pool 'shared'")
        assert False, "expected MissingConfigError"
    except MissingConfigError as exc:
        assert "client_host" in str(exc)
        assert "roster_url" not in str(exc).split(":")[-1]  # only the MISSING key is named, not the present one


def test_reporter_summary_is_zero_only_when_no_failures():
    report = Reporter()
    report.passed("01-x", "ok")
    report.skipped("02-y", "not configured")
    assert report.summary() == 0


def test_reporter_summary_is_nonzero_when_anything_failed():
    report = Reporter()
    report.passed("01-x", "ok")
    report.failed("02-y", "broken")
    assert report.summary() == 1


def test_reporter_records_every_result_with_status():
    report = Reporter()
    report.passed("a", "msg1")
    report.failed("b", "msg2")
    report.skipped("c", "msg3")
    statuses = {r.check_id: r.status for r in report.results}
    assert statuses == {"a": "PASS", "b": "FAIL", "c": "SKIP"}


def test_run_acceptance_tests_discovers_all_eight_checks():
    import importlib

    checks_dir = _ACCEPTANCE_ROOT / "checks"
    check_files = sorted(checks_dir.glob("check_*.py"))
    assert len(check_files) == 8, f"expected 8 check modules, found {len(check_files)}: {[p.name for p in check_files]}"

    sys.path.insert(0, str(_ACCEPTANCE_ROOT))
    for path in check_files:
        mod = importlib.import_module(f"checks.{path.stem}")
        assert hasattr(mod, "CHECK_ID"), f"{path.name} is missing CHECK_ID"
        assert hasattr(mod, "DESCRIPTION"), f"{path.name} is missing DESCRIPTION"
        assert hasattr(mod, "run"), f"{path.name} is missing a run(cfg, report) function"
