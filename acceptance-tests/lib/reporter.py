# reporter.py (acceptance-tests/lib)
#
# The pass/fail/skip ledger every check module writes into and
# run_acceptance_tests.py reads back at the end to decide the process
# exit code. Deliberately the same "plain list of results, printed as we
# go, summarized at the end" shape as tests/_runner.py, so anyone who's
# already read that file recognizes this one immediately.
#
# -----------------------------------------------------
# What this provides:
#
# 1) Reporter.passed()/failed()/skipped() - Record one result each,
#    printing it immediately (so a long-running live drill's progress is
#    visible in real time, not just at the very end).
# 2) Reporter.summary() - Prints the final PASS/FAIL/SKIP tally per check
#    and returns a process exit code (0 only if there were zero FAILs;
#    SKIPs never fail the run by themselves).
#
# -----------------------------------------------------
# Usage:
#
#   report = Reporter()
#   report.passed("01-roster-and-health", "shared: 3/3 nodes healthy")
#   report.failed("06-ip-failover-bgp", "shared: 4.2% packet loss during failover (expected 0%)")
#   sys.exit(report.summary())
#
# -----------------------------------------------------
# Best Practices:
#
# - Always pass the check's CHECK_ID as the first argument, not a
#   free-form label -- run_acceptance_tests.py's --only filter matches
#   against it, and the final summary groups by it.
# - Keep messages one line and specific (which pool, which node, the
#   actual observed value vs. the expected one) -- these lines are what
#   an operator pastes into an incident channel or a demo readout.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Pass/fail/skip ledger for the LNG acceptance-test suite.

Mirrors tests/_runner.py's plain, dependency-free "print as we go, tally
at the end" shape, extended with a SKIP status for checks whose
prerequisite config/feature isn't present in this deployment.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field


@dataclass
class Result:
    check_id: str
    status: str  # "PASS" | "FAIL" | "SKIP"
    message: str
    elapsed_seconds: float


@dataclass
class Reporter:
    results: list[Result] = field(default_factory=list)

    def _record(self, check_id: str, status: str, message: str, started_at: float) -> None:
        elapsed = time.monotonic() - started_at
        self.results.append(Result(check_id, status, message, elapsed))
        print(f"[{status:4s}] {check_id}: {message}  ({elapsed:.1f}s)")

    def passed(self, check_id: str, message: str, started_at: float | None = None) -> None:
        self._record(check_id, "PASS", message, started_at or time.monotonic())

    def failed(self, check_id: str, message: str, started_at: float | None = None) -> None:
        self._record(check_id, "FAIL", message, started_at or time.monotonic())

    def skipped(self, check_id: str, message: str, started_at: float | None = None) -> None:
        self._record(check_id, "SKIP", message, started_at or time.monotonic())

    def summary(self) -> int:
        """
        Prints the final tally and returns the process exit code: 0 if
        there are zero FAILs (any number of PASS/SKIP is fine), 1
        otherwise. SKIP is informational -- a pool that doesn't have a
        given drill block configured SKIPping that check is expected,
        not a suite failure.
        """
        passed = sum(1 for r in self.results if r.status == "PASS")
        failed = sum(1 for r in self.results if r.status == "FAIL")
        skipped = sum(1 for r in self.results if r.status == "SKIP")

        print()
        print("=" * 60)
        print(f"ACCEPTANCE TEST SUMMARY: {passed} passed, {failed} failed, {skipped} skipped")
        if failed:
            print()
            print("Failed checks:")
            for r in self.results:
                if r.status == "FAIL":
                    print(f"  - {r.check_id}: {r.message}")
        print("=" * 60)

        return 1 if failed else 0
