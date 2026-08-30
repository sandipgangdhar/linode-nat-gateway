# check_01_roster_and_health.py (acceptance-tests/checks)
#
# The foundational check every other check implicitly depends on: is
# natctl's roster API reachable at all, and does each configured pool
# have at least its configured min_nodes NAT-healthy? If this fails,
# every later check that reads the roster (egress, autoscale) is almost
# certainly going to fail too for the same underlying reason -- run this
# one first and read its message before chasing failures further down
# the suite.
#
# -----------------------------------------------------
# What this verifies (per pool in config.yaml's `pools` section):
#
# 1) GET <roster_url> returns HTTP 200 with valid JSON matching
#    controller/natctl/fleet.py's roster() shape ({"pool": ..., "nodes": [...]}).
# 2) At least `min_nodes` (from this pool's config block) nodes report
#    healthy: true. Uses config, not a hardcoded number, since every
#    pool's floor is different (see terraform/modules/nat-fleet's
#    min_nodes/node_count).
#
# -----------------------------------------------------
# Usage:
#
# python run_acceptance_tests.py --only 01-roster-and-health
#
# -----------------------------------------------------
# Best Practices:
#
# - Run this in isolation first against a freshly deployed environment
#   before running anything else in this suite -- it's the cheapest,
#   fastest, least disruptive check here (a single GET, no drills, no
#   load generation), and a clean pass here is the prerequisite for
#   every later check's results being meaningful.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Roster reachability + minimum healthy-node-count check.

Every pool configured in config.yaml's `pools` section gets its own
roster_url polled and its node list validated against that pool's own
min_nodes expectations.
"""
from __future__ import annotations

import time

import requests

from lib.config import Config, MissingConfigError
from lib.http_client import request_with_backoff
from lib.reporter import Reporter

CHECK_ID = "01-roster-and-health"
DESCRIPTION = "natctl roster is reachable and each pool has enough healthy nodes"


def run(cfg: Config, report: Reporter) -> None:
    if not cfg.pools:
        report.skipped(CHECK_ID, "no pools configured in config.yaml -- nothing to check")
        return

    for pool_name, pool in cfg.pools.items():
        started = time.monotonic()
        try:
            (roster_url,) = cfg.require(pool, "roster_url", context=f"pool '{pool_name}'")
        except MissingConfigError as exc:
            report.skipped(CHECK_ID, f"{pool_name}: {exc}", started)
            continue

        min_nodes = int(pool.get("min_nodes", 1))

        try:
            resp = request_with_backoff("GET", roster_url, timeout=10)
        except requests.exceptions.RequestException as exc:
            report.failed(CHECK_ID, f"{pool_name}: roster unreachable at {roster_url}: {exc}", started)
            continue

        if resp.status_code != 200:
            report.failed(CHECK_ID, f"{pool_name}: roster returned HTTP {resp.status_code}", started)
            continue

        try:
            data = resp.json()
            nodes = data["nodes"]
        except (ValueError, KeyError) as exc:
            report.failed(CHECK_ID, f"{pool_name}: roster response is not the expected shape ({exc})", started)
            continue

        healthy_nodes = [n for n in nodes if n.get("healthy")]
        if len(healthy_nodes) < min_nodes:
            report.failed(
                CHECK_ID,
                f"{pool_name}: only {len(healthy_nodes)}/{len(nodes)} nodes healthy, "
                f"need at least min_nodes={min_nodes}",
                started,
            )
            continue

        report.passed(
            CHECK_ID,
            f"{pool_name}: {len(healthy_nodes)}/{len(nodes)} nodes healthy (min_nodes={min_nodes})",
            started,
        )
