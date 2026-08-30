# _runner.py (acceptance-tests/tests)
#
# The same minimal pytest-free runner as the main project's tests/_runner.py
# (see that file for the full rationale), scoped to this suite's own
# harness self-tests (test_lib.py) -- NOT to the live checks/check_*.py
# modules, which make real network/SSH/ping calls against a real
# deployment and are deliberately never auto-discovered or run by any
# test runner. This file only proves lib/config.py, lib/reporter.py, and
# run_acceptance_tests.py's check-discovery logic are themselves correct.
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
"""
Minimal pytest-free runner for this suite's own harness self-tests
(test_lib.py) -- mirrors the main project's tests/_runner.py exactly.
Never touches checks/check_*.py, which are live-infrastructure checks by
design, not unit tests.
"""
import importlib.util
import sys
import traceback
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent


def run_module(path: Path) -> tuple[int, int]:
    spec = importlib.util.spec_from_file_location(path.stem, path)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception:
        print(f"  MODULE IMPORT FAILED: {path.name}")
        traceback.print_exc()
        return 0, 1

    passed = failed = 0
    for name in dir(mod):
        if not name.startswith("test_"):
            continue
        fn = getattr(mod, name)
        if not callable(fn):
            continue
        try:
            fn()
            passed += 1
        except Exception:
            failed += 1
            print(f"  FAIL: {path.name}::{name}")
            traceback.print_exc()
    return passed, failed


def main() -> int:
    targets = sys.argv[1:] or sorted(TESTS_DIR.glob("test_*.py"))
    total_pass = total_fail = 0
    for t in targets:
        p = Path(t)
        print(f"== {p.name} ==")
        passed, failed = run_module(p)
        total_pass += passed
        total_fail += failed
        print(f"   {passed} passed, {failed} failed")
    print(f"\nTOTAL: {total_pass} passed, {total_fail} failed")
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
