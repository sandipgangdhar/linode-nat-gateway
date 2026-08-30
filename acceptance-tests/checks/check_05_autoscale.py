# check_05_autoscale.py (acceptance-tests/checks)
#
# Verifies natctl's elastic autoscaling actually fires under real load --
# not just that the config values (min_nodes/max_nodes/cooldown_seconds)
# are set correctly, but that a real load spike genuinely produces a new
# `lng-elastic`-tagged node in the roster within a reasonable window. See
# docs/ARCHITECTURE.md section 4.1 and docs/RUNBOOK.md for the mechanism
# this exercises.
#
# -----------------------------------------------------
# What this verifies (per pool with an `autoscale_drill` block):
#
# 1) Records the pool's current node_count from the roster.
# 2) SSHes into `client_host` and runs scripts/loadtest.sh (reusing that
#    script rather than reimplementing load generation here) with this
#    drill's `connections`/`duration`/`target`.
# 3) Polls the roster every 15s for up to `expected_scale_within_seconds`
#    (default 300s) waiting for node_count to increase.
# 4) PASSes as soon as node_count grows; FAILs if it never does within
#    the window. Does NOT wait for or verify scale-IN afterward --
#    cooldown_seconds is typically much longer than this check's
#    patience, and confirming scale-in isn't needed to prove the
#    autoscale mechanism itself works.
#
# -----------------------------------------------------
# Usage:
#
# python run_acceptance_tests.py --only 05-autoscale
#
# -----------------------------------------------------
# Best Practices:
#
# - This is the SLOWEST and most expensive check in this suite by far --
#   it deliberately provisions a brand new billable elastic Linode. Only
#   include an `autoscale_drill` block for pools you actually want to
#   pay to verify this on, and expect this single check to take several
#   minutes.
# - Requires `hey` installed on `client_host` (see scripts/loadtest.sh's
#   own prerequisites) -- this check does not install it for you.
# - The new node it provisions does not get torn down automatically by
#   this check -- natctl's own scale-in logic (cooldown_seconds) will
#   eventually remove it once load subsides, exactly as it would for a
#   real traffic spike. If you need it gone sooner, see docs/RUNBOOK.md's
#   scale-in guidance.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Autoscale check: drives real load via scripts/loadtest.sh and polls the
roster until a new elastic node appears (or the patience window expires).
"""
from __future__ import annotations

import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse

import requests

from lib.config import Config, MissingConfigError
from lib.http_client import request_with_backoff
from lib.reporter import Reporter

CHECK_ID = "05-autoscale"
DESCRIPTION = "a real load spike causes natctl to provision an additional elastic node"

_REPO_ROOT = Path(__file__).resolve().parents[2]
_LOADTEST_SCRIPT = _REPO_ROOT / "scripts" / "loadtest.sh"

DEFAULT_EXPECTED_SCALE_WITHIN_SECONDS = 300
POLL_INTERVAL_SECONDS = 15
SSH_TIMEOUT_SECONDS = 10


def _node_count(roster_url: str) -> int:
    resp = request_with_backoff("GET", roster_url, timeout=10)
    resp.raise_for_status()
    return len(resp.json()["nodes"])


def run(cfg: Config, report: Reporter) -> None:
    ssh_user = cfg.ssh.get("user", "root")
    ssh_key = cfg.ssh.get("key_path")

    for pool_name, pool in cfg.pools.items():
        started = time.monotonic()
        drill = pool.get("autoscale_drill")
        if not drill:
            report.skipped(CHECK_ID, f"{pool_name}: no autoscale_drill block configured for this pool (this check is opt-in -- it provisions a real billable node)", started)
            continue

        try:
            (roster_url,) = cfg.require(pool, "roster_url", context=f"pool '{pool_name}'")
            (client_host,) = cfg.require(drill, "client_host", context=f"pool '{pool_name}' autoscale_drill")
        except MissingConfigError as exc:
            report.skipped(CHECK_ID, f"{pool_name}: {exc}", started)
            continue

        connections = int(drill.get("connections", 500))
        duration = int(drill.get("duration", 120))
        target = drill.get("target", "https://www.gstatic.com/generate_204")
        patience = int(drill.get("expected_scale_within_seconds", DEFAULT_EXPECTED_SCALE_WITHIN_SECONDS))

        if not _LOADTEST_SCRIPT.exists():
            report.failed(CHECK_ID, f"{pool_name}: {_LOADTEST_SCRIPT} not found -- repo layout may have changed", started)
            continue

        try:
            baseline_count = _node_count(roster_url)
        except (requests.exceptions.RequestException, ValueError, KeyError) as exc:
            report.failed(CHECK_ID, f"{pool_name}: could not read baseline node_count from roster: {exc}", started)
            continue

        # BUG FIX (found live, 2026-08-30, roadmap/M7-acceptance-suite.md):
        # loadtest.sh's -disable-keepalive fix (a fresh TCP connection per
        # request, needed so request RATE -- not just concurrency --
        # drives real conntrack pressure) means a fresh DNS lookup per
        # request too. Confirmed live this can overwhelm a small client
        # instance's own local resolver under real concurrency (almost
        # all requests failing with "Temporary failure in name
        # resolution", not just running slower). Resolve the target's IP
        # HERE -- wherever this check itself is running, not the client
        # -- and pass it through, so the client only ever pins an
        # already-known-good IP into /etc/hosts instead of depending on
        # its own resolver working reliably under load.
        target_ip = ""
        try:
            target_host = urlparse(target).hostname
            if target_host:
                target_ip = socket.gethostbyname(target_host)
        except OSError:
            pass  # loadtest.sh falls back to local resolution on the client if this is empty

        ssh_cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if ssh_key:
            ssh_cmd += ["-i", ssh_key]
        remote_loadtest = f"bash -s -- --connections {connections} --duration {duration} --target {target}"
        if target_ip:
            remote_loadtest += f" --target-ip {target_ip}"
        ssh_cmd += [f"{ssh_user}@{client_host}", remote_loadtest]

        try:
            with open(_LOADTEST_SCRIPT, "rb") as script_stdin:
                subprocess.run(ssh_cmd, stdin=script_stdin, timeout=duration + 30, check=False)
        except (subprocess.SubprocessError, OSError) as exc:
            report.failed(CHECK_ID, f"{pool_name}: could not run loadtest.sh on {client_host}: {exc}", started)
            continue

        deadline = time.monotonic() + patience
        scaled = False
        latest_count = baseline_count
        while time.monotonic() < deadline:
            try:
                latest_count = _node_count(roster_url)
            except (requests.exceptions.RequestException, ValueError, KeyError):
                pass  # transient roster hiccup during a load spike -- keep polling until the deadline
            if latest_count > baseline_count:
                scaled = True
                break
            time.sleep(POLL_INTERVAL_SECONDS)

        if not scaled:
            report.failed(CHECK_ID, f"{pool_name}: node_count stayed at {baseline_count} for {patience}s after driving {connections} connections x {duration}s -- natctl did not scale out", started)
            continue

        report.passed(CHECK_ID, f"{pool_name}: node_count grew from {baseline_count} to {latest_count} within {patience}s of the load spike", started)
