#!/usr/bin/env python3
# run_acceptance_tests.py (acceptance-tests)
#
# The single entrypoint for this whole suite -- discovers every
# checks/check_*.py module automatically (sorted by filename, so they run
# in the deliberate order the filenames encode: cheapest/least-disruptive
# first, most disruptive/slowest last), loads config.yaml, runs each
# check's run(cfg, report) function, and exits non-zero if anything
# failed. This is the "one command" docs/RUNBOOK.md and this project's
# README point operators at for post-deploy validation.
#
# -----------------------------------------------------
# Parameters:
#
# 1) --config <path>  - Path to your filled-in config file (default:
#    config.yaml in this directory). See config.example.yaml for every
#    recognized key.
# 2) --only <check-id> - Run only this check (matches CHECK_ID exactly,
#    e.g. "01-roster-and-health"). Repeatable to run more than one.
# 3) --list             - Print every discovered check's ID and
#    description, then exit 0 without running anything.
#
# -----------------------------------------------------
# Usage:
#
#   cp config.example.yaml config.yaml   # fill in your real endpoints/credentials
#   pip install -r ../controller/requirements.txt
#   python run_acceptance_tests.py                          # run everything
#   python run_acceptance_tests.py --only 01-roster-and-health --only 06-observability
#   python run_acceptance_tests.py --list
#
# -----------------------------------------------------
# Best Practices:
#
# - Run the cheap checks (01, 02, 06) on every deploy. Reserve 03/04
#   (drills that briefly disrupt a real node) and 05 (provisions a real
#   billable node) for scheduled maintenance windows or a deliberate demo/validation
#   pass -- not routine CI. Gate which ones run via config.yaml (leave a
#   pool's `node_failure_drill`/`ip_failover_drill`/`autoscale_drill`
#   block out entirely to SKIP it, rather than commenting out a whole
#   check module).
# - A single check module raising an unexpected exception is caught here
#   and turned into one FAIL result for that check -- it does not abort
#   the rest of the suite. Check the printed traceback for that one
#   check's bug; every other check's result is still trustworthy.
# - Exit code is 0 only when there are zero FAILs. SKIPs never fail a
#   run by themselves -- see lib/reporter.py.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Entrypoint for the LNG post-deploy acceptance-test suite.

Discovers every checks/check_*.py module, loads config.yaml, and runs
each check's run(cfg, report) function in filename order, printing a
running PASS/FAIL/SKIP ledger and exiting non-zero if anything failed.
"""
from __future__ import annotations

import argparse
import importlib
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.config import load_config  # noqa: E402
from lib.reporter import Reporter  # noqa: E402

_CHECKS_DIR = Path(__file__).resolve().parent / "checks"


def _discover_checks():
    """Imports every checks/check_*.py module, sorted by filename, and
    returns the list of loaded modules. Filename order is deliberate --
    see this file's own header comment."""
    modules = []
    for path in sorted(_CHECKS_DIR.glob("check_*.py")):
        mod_name = f"checks.{path.stem}"
        modules.append(importlib.import_module(mod_name))
    return modules


def main() -> int:
    parser = argparse.ArgumentParser(description="LNG post-deploy acceptance-test suite")
    parser.add_argument("--config", default=str(Path(__file__).resolve().parent / "config.yaml"))
    parser.add_argument("--only", action="append", default=None, help="Run only this CHECK_ID (repeatable)")
    parser.add_argument("--list", action="store_true", help="List discovered checks and exit")
    args = parser.parse_args()

    modules = _discover_checks()

    if args.list:
        for mod in modules:
            print(f"{mod.CHECK_ID:28s} {mod.DESCRIPTION}")
        return 0

    if not Path(args.config).exists():
        print(f"Config file not found: {args.config}", file=sys.stderr)
        print("Copy config.example.yaml to config.yaml (or pass --config) and fill in your deployment's details first.", file=sys.stderr)
        return 2

    cfg = load_config(args.config)
    report = Reporter()

    for mod in modules:
        if args.only and mod.CHECK_ID not in args.only:
            continue
        print(f"\n--- {mod.CHECK_ID}: {mod.DESCRIPTION} ---")
        started = time.monotonic()
        try:
            mod.run(cfg, report)
        except Exception as exc:  # noqa: BLE001 -- one check's bug must not abort the whole suite
            traceback.print_exc()
            report.failed(mod.CHECK_ID, f"check raised an unexpected exception: {exc}", started)

    return report.summary()


if __name__ == "__main__":
    sys.exit(main())
