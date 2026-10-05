# check_07_observability_correctness.py (acceptance-tests/checks)
#
# Closes a gap check_06 deliberately leaves open: check_06 proves the
# observability stack is UP and has SOME data. It does not prove every
# dashboard panel this project ships actually has data (rather than
# silently showing "No data" to a customer), and it does not prove the
# numbers Prometheus reports match what the node itself is actually
# doing. This check does both, white-box style -- it reads this
# project's own dashboard definition and queries each panel's real
# PromQL, and it SSHes into a real node and compares exported metrics
# against the kernel/FRR state they claim to summarize.
#
# -----------------------------------------------------
# What this verifies:
#
# 1) Dashboard panel coverage: every panel in dashboards/nat-overview.json
#    (read directly from this repo, not re-typed here, so it can never
#    drift out of sync with the file that actually ships) has its own
#    PromQL query run against Prometheus with the $pool template variable
#    expanded to match every configured pool. A panel whose query comes
#    back with zero series is reported by panel title and target
#    expression -- a customer looking at that panel would see "No data",
#    which is exactly the failure this check exists to catch before they
#    do.
#
# 2) Ground-truth cross-check, per pool with a `node_failure_drill` block
#    configured (reusing its `node_ssh_host` -- no separate config key,
#    since any SSH-reachable real node works for this): SSHes in and
#    compares the exporter's own numbers against the kernel/FRR state
#    they're computed from, on that same machine, at nearly the same
#    moment:
#      - nat_nftables_drops_total vs. `nft list counters` -- a monotonic
#        kernel counter, so the live kernel reading must be >= the
#        exporter's last-scraped value, never less (a wrong metric name
#        or table reference would show a counter that doesn't track the
#        real one at all, or structurally can't satisfy this).
#      - nat_bgp_peers_established_total vs. `vtysh -c 'show bgp summary
#        json'`'s own real session count -- a point-in-time count, so
#        this one is checked for an EXACT match.
#
# A pool with no `node_failure_drill` block configured only loses the
# ground-truth half of this check for that pool (reported as a note, not
# a FAIL) -- the dashboard-panel sweep still runs for it, since that part
# only needs Prometheus.
#
# This check is read-only -- it never changes anything on a node, only
# queries it. Best run against a deployment that has already seen real
# traffic (same reasoning as check_06's own "run this last"): a handful
# of throughput/rate-based panels can legitimately show no data on a
# truly idle, freshly-created fleet that has never forwarded a single
# packet, since rate() needs at least two real samples inside its own
# window to produce anything at all. That is a real, honest gap in THIS
# run's coverage, not a bug in the panel -- re-run after check 02 (or any
# real traffic) has exercised the fleet if this check's panel-coverage
# half fails on a brand-new deployment.
#
# -----------------------------------------------------
# Usage:
#
# python run_acceptance_tests.py --only 07-observability-correctness
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
White-box observability correctness check: every dashboard panel this
project ships actually has data, and a sample of exported metrics match
real kernel/FRR ground truth on a live node.
"""
from __future__ import annotations

import json
import re
import subprocess
import time
from pathlib import Path

import requests
from lib.config import Config
from lib.http_client import request_with_backoff
from lib.reporter import Reporter

CHECK_ID = "07-observability-correctness"
DESCRIPTION = "Every dashboard panel has data; exported metrics match real kernel/FRR state"

DASHBOARD_PATH = Path(__file__).resolve().parents[2] / "dashboards" / "nat-overview.json"
SSH_TIMEOUT_SECONDS = 15


def _ssh(ssh_user: str, ssh_key: str | None, host: str, command: str) -> subprocess.CompletedProcess:
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    if ssh_key:
        cmd += ["-i", ssh_key]
    cmd += [f"{ssh_user}@{host}", command]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=SSH_TIMEOUT_SECONDS, check=False)


def _panel_targets(pool_names: list[str]) -> list[tuple[str, str]]:
    """(panel title, expanded PromQL expr) for every target in every panel
    of this repo's own dashboards/nat-overview.json. $pool is expanded to
    match every configured pool, the same substitution Grafana itself
    does for the dashboard's "All" template-variable value."""
    dashboard = json.loads(DASHBOARD_PATH.read_text())
    pool_regex = "|".join(re.escape(p) for p in pool_names)
    out: list[tuple[str, str]] = []
    for panel in dashboard.get("panels", []):
        title = panel.get("title", f"panel {panel.get('id')}")
        for target in panel.get("targets", []):
            expr = target.get("expr")
            if not expr:
                continue
            expr = expr.replace('=~"$pool"', f'=~"{pool_regex}"').replace("$pool", pool_regex)
            out.append((title, expr))
    return out


def _resolve_node_id(prometheus_url: str, host: str) -> str | None:
    """
    nat_nftables_drops_total/nat_bgp_peers_established_total are both
    labeled by node_id/instance, neither of which is reliably node_host
    from config (instance is whatever address file_sd discovered --
    typically the node's private VPC address, not node_ssh_host's public
    one). nat_port_allocated_total carries BOTH public_ip and node_id
    together, so a node whose node_ssh_host genuinely is its public IP
    (config.example.yaml's own documented convention) can be resolved to
    its real node_id this way instead of guessing from an address
    substring match. Returns None (not an exception) on no match -- the
    caller falls back to instance=~ substring matching, which still
    covers a deployment where node_ssh_host is the private IP instead.
    """
    try:
        resp = request_with_backoff(
            "GET", f"{prometheus_url}/api/v1/query",
            params={"query": f'nat_port_allocated_total{{public_ip="{host}"}}'},
            timeout=10,
        )
        resp.raise_for_status()
        result = resp.json()["data"]["result"]
    except (requests.exceptions.RequestException, ValueError, KeyError):
        return None
    if not result:
        return None
    return result[0]["metric"].get("node_id")


def _query_result_count(prometheus_url: str, expr: str) -> int:
    resp = request_with_backoff("GET", f"{prometheus_url}/api/v1/query", params={"query": expr}, timeout=10)
    resp.raise_for_status()
    return len(resp.json()["data"]["result"])


def _check_dashboard_coverage(prometheus_url: str, pool_names: list[str], problems: list[str]) -> int:
    if not DASHBOARD_PATH.is_file():
        problems.append(f"dashboards/nat-overview.json not found at {DASHBOARD_PATH} -- cannot sweep panel coverage")
        return 0
    targets = _panel_targets(pool_names)
    checked = 0
    for title, expr in targets:
        checked += 1
        try:
            n = _query_result_count(prometheus_url, expr)
        except (requests.exceptions.RequestException, ValueError, KeyError) as exc:
            problems.append(f"panel '{title}': query failed: {exc} -- expr: {expr[:100]}")
            continue
        if n == 0:
            problems.append(f"panel '{title}': query returned NO DATA -- expr: {expr[:100]}")
    return checked


def _node_matcher(node_id: str | None, host: str) -> str:
    """PromQL label-matcher fragment selecting this one node's own series
    -- an exact node_id match when _resolve_node_id() found one, else a
    best-effort instance=~ substring match on the SSH host string."""
    if node_id:
        return f'node_id="{node_id}"'
    return f'instance=~".*{host}.*"'


def _check_nftables_drops(ssh_user: str, ssh_key: str | None, host: str, node_id: str | None, prometheus_url: str, pool_name: str, problems: list[str]) -> bool:
    proc = _ssh(ssh_user, ssh_key, host, "nft -j list counters 2>/dev/null")
    if proc.returncode != 0 or not proc.stdout.strip():
        problems.append(f"{pool_name}: could not read real nftables counters from {host} ({proc.stderr.strip() or 'empty output'})")
        return False
    try:
        kernel = json.loads(proc.stdout)
    except ValueError as exc:
        problems.append(f"{pool_name}: nft -j list counters on {host} returned unparseable JSON: {exc}")
        return False
    kernel_by_name = {}
    for item in kernel.get("nftables", []):
        c = item.get("counter")
        if c and c.get("table") == "lng_nat":
            kernel_by_name[c["name"]] = c.get("packets", 0)
    if not kernel_by_name:
        problems.append(f"{pool_name}: no lng_nat table counters found on {host} -- nftables ruleset missing or renamed?")
        return False

    matcher = _node_matcher(node_id, host)
    try:
        resp = request_with_backoff(
            "GET", f"{prometheus_url}/api/v1/query",
            params={"query": f'nat_nftables_drops_total{{pool="{pool_name}",{matcher}}}'},
            timeout=10,
        )
        resp.raise_for_status()
        result = resp.json()["data"]["result"]
    except (requests.exceptions.RequestException, ValueError, KeyError) as exc:
        problems.append(f"{pool_name}: nat_nftables_drops_total query failed: {exc}")
        return False
    if not result:
        problems.append(
            f"{pool_name}: no nat_nftables_drops_total series matched {matcher} -- "
            f"this node's own exporter may be scraped under a different address; ground-truth check "
            f"inconclusive for this pool, not confirmed correct"
        )
        return False

    ok = True
    for series in result:
        reason = series["metric"].get("reason")
        if reason not in kernel_by_name:
            continue
        exported_count = float(series["value"][1])
        real_count = kernel_by_name[reason]
        # Monotonic counter: the kernel reading taken just now can only be
        # >= whatever Prometheus last scraped, never less -- a mismatch in
        # the other direction means the exported series isn't tracking
        # this real counter at all.
        if real_count + 1 < exported_count:
            problems.append(
                f"{pool_name}/{host}: nat_nftables_drops_total{{reason=\"{reason}\"}} reports {exported_count:.0f}, "
                f"but the real kernel counter on {host} right now is only {real_count} -- exported value is higher than "
                f"ground truth, which a monotonic counter must never be"
            )
            ok = False
    return ok


def _check_bgp_peers(ssh_user: str, ssh_key: str | None, host: str, node_id: str | None, prometheus_url: str, pool_name: str, problems: list[str]) -> bool:
    proc = _ssh(ssh_user, ssh_key, host, "vtysh -c 'show bgp summary json' 2>/dev/null")
    if proc.returncode != 0 or not proc.stdout.strip():
        problems.append(f"{pool_name}: could not read real BGP state from {host} ({proc.stderr.strip() or 'empty output, is FRR/ip_failover enabled for this pool?'})")
        return False
    try:
        real = json.loads(proc.stdout)
    except ValueError as exc:
        problems.append(f"{pool_name}: vtysh BGP summary on {host} returned unparseable JSON: {exc}")
        return False
    peers = (real.get("ipv4Unicast") or real.get("ipv6Unicast") or {}).get("peers", {})
    real_established = sum(1 for p in peers.values() if p.get("state") == "Established")

    matcher = _node_matcher(node_id, host)
    try:
        resp = request_with_backoff(
            "GET", f"{prometheus_url}/api/v1/query",
            params={"query": f'nat_bgp_peers_established_total{{pool="{pool_name}",{matcher}}}'},
            timeout=10,
        )
        resp.raise_for_status()
        result = resp.json()["data"]["result"]
    except (requests.exceptions.RequestException, ValueError, KeyError) as exc:
        problems.append(f"{pool_name}: nat_bgp_peers_established_total query failed: {exc}")
        return False
    if not result:
        problems.append(
            f"{pool_name}: no nat_bgp_peers_established_total series matched {matcher} -- "
            f"this node's own exporter may be scraped under a different address; ground-truth check "
            f"inconclusive for this pool, not confirmed correct"
        )
        return False

    exported = float(result[0]["value"][1])
    if exported != real_established:
        problems.append(f"{pool_name}/{host}: nat_bgp_peers_established_total reports {exported:.0f}, but real BGP (`vtysh show bgp summary`) shows {real_established} Established peer(s) right now")
        return False
    return True


def run(cfg: Config, report: Reporter) -> None:
    started = time.monotonic()
    prometheus_url = cfg.control_plane.get("prometheus_url")
    if not prometheus_url:
        report.skipped(CHECK_ID, "control_plane.prometheus_url not set in config.yaml", started)
        return
    if not cfg.pools:
        report.skipped(CHECK_ID, "no pools configured", started)
        return

    problems: list[str] = []
    notes: list[str] = []

    panels_checked = _check_dashboard_coverage(prometheus_url, list(cfg.pools), problems)

    ssh_user = cfg.ssh.get("user", "root")
    ssh_key = cfg.ssh.get("key_path")
    ground_truth_pools = 0
    for pool_name, pool in cfg.pools.items():
        drill = pool.get("node_failure_drill") or {}
        host = drill.get("node_ssh_host") or drill.get("node_host")
        if not host:
            notes.append(f"{pool_name}: no node_failure_drill.node_ssh_host configured -- skipping ground-truth cross-check for this pool")
            continue
        ground_truth_pools += 1
        node_id = _resolve_node_id(prometheus_url, host)
        _check_nftables_drops(ssh_user, ssh_key, host, node_id, prometheus_url, pool_name, problems)
        _check_bgp_peers(ssh_user, ssh_key, host, node_id, prometheus_url, pool_name, problems)

    summary = f"{panels_checked} panel quer{'y' if panels_checked == 1 else 'ies'} checked across {len(cfg.pools)} pool(s); ground truth cross-checked for {ground_truth_pools} pool(s)"
    if notes:
        summary += "; " + "; ".join(notes)

    if problems:
        report.failed(CHECK_ID, f"{summary} -- {len(problems)} problem(s): " + " | ".join(problems), started)
        return

    report.passed(CHECK_ID, summary, started)
