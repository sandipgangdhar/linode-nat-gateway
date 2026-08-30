# check_03_buddy_failover_drill.py (acceptance-tests/checks)
#
# Wraps scripts/node-failure-drill.sh (rather than reimplementing its
# logic) to automate the exact manual drill docs/RUNBOOK.md already
# documents: stop nat-exporter on one node (simulating it going
# unhealthy without touching the instance itself), confirm the observing
# client's client-agent removes it from its ECMP route within
# `max_wait_seconds`, restore it, and confirm the client re-adds it. See
# that script's own header for the full detail -- this file is
# deliberately thin, just plumbing config.yaml's drill target into it and
# turning its exit code into a Reporter result.
#
# -----------------------------------------------------
# What this verifies (per pool with a `node_failure_drill` block):
#
# 1) Runs scripts/node-failure-drill.sh --node-host <node_host>
#    --client-host <client_host> --ssh-user <ssh.user> --max-wait <...>.
# 2) PASS iff the script exits 0 (both transitions -- removal, then
#    rejoin -- happened within max_wait_seconds). Any non-zero exit is a
#    FAIL, with the script's own stderr surfaced in the message.
#
# -----------------------------------------------------
# Usage:
#
# python run_acceptance_tests.py --only 03-buddy-failover-drill
#
# -----------------------------------------------------
# Best Practices:
#
# - This is DISRUPTIVE (however briefly): it stops nat-exporter on a real
#   node. Run it against a pool with more than min_nodes healthy so
#   failing one node doesn't also trip an unrelated autoscale event
#   mid-drill -- see the wrapped script's own Best Practices section.
# - Uses the SAME node-failure-drill.sh operators already run manually
#   day-2 (docs/RUNBOOK.md) -- if this check's behavior ever needs to
#   change, change the script, not this wrapper, so manual and automated
#   runs never drift apart.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Buddy/conntrack node-failure drill check: a thin subprocess wrapper
around scripts/node-failure-drill.sh, reusing that script rather than
reimplementing its ssh/route-table logic here.
"""
from __future__ import annotations

import subprocess
import time
from pathlib import Path

from lib.config import Config, MissingConfigError
from lib.reporter import Reporter

CHECK_ID = "03-buddy-failover-drill"
DESCRIPTION = "node-failure-drill.sh: an unhealthy node is routed around, then rejoins cleanly"

_REPO_ROOT = Path(__file__).resolve().parents[2]
_DRILL_SCRIPT = _REPO_ROOT / "scripts" / "node-failure-drill.sh"
DEFAULT_MAX_WAIT_SECONDS = 20
DRILL_TIMEOUT_SECONDS = 120


def run(cfg: Config, report: Reporter) -> None:
    ssh_user = cfg.ssh.get("user", "root")

    for pool_name, pool in cfg.pools.items():
        started = time.monotonic()
        drill = pool.get("node_failure_drill")
        if not drill:
            report.skipped(CHECK_ID, f"{pool_name}: no node_failure_drill block configured for this pool", started)
            continue

        try:
            node_host, client_host = cfg.require(drill, "node_host", "client_host", context=f"pool '{pool_name}' node_failure_drill")
        except MissingConfigError as exc:
            report.skipped(CHECK_ID, f"{pool_name}: {exc}", started)
            continue

        # node_ssh_host is optional and separate from node_host -- see
        # scripts/node-failure-drill.sh's own --node-ssh-host comment for
        # why: node_host is matched against the client's route table
        # (this branch's VLAN address), which is deliberately NOT
        # SSH-reachable (roadmap/M2-security.md test case 2.8), so a real
        # deployment on this branch needs a different address for the
        # actual SSH calls (confirmed live, 2026-08-30,
        # roadmap/M7-acceptance-suite.md -- omitting this falls back to
        # node_host, for any topology where a single address serves both
        # roles).
        node_ssh_host = drill.get("node_ssh_host")

        max_wait = int(drill.get("max_wait_seconds", DEFAULT_MAX_WAIT_SECONDS))

        if not _DRILL_SCRIPT.exists():
            report.failed(CHECK_ID, f"{pool_name}: {_DRILL_SCRIPT} not found -- repo layout may have changed", started)
            continue

        cmd = [
            str(_DRILL_SCRIPT),
            "--node-host", node_host,
            "--client-host", client_host,
            "--ssh-user", ssh_user,
            "--max-wait", str(max_wait),
        ]
        if node_ssh_host:
            cmd += ["--node-ssh-host", node_ssh_host]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=DRILL_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            report.failed(CHECK_ID, f"{pool_name}: node-failure-drill.sh did not complete within {DRILL_TIMEOUT_SECONDS}s", started)
            continue

        if proc.returncode != 0:
            report.failed(CHECK_ID, f"{pool_name}: drill failed (exit {proc.returncode}): {proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else 'no stderr output'}", started)
            continue

        report.passed(CHECK_ID, f"{pool_name}: {node_host} was removed from {client_host}'s route table and rejoined cleanly (max_wait={max_wait}s)", started)
