# check_02_nat_egress.py (acceptance-tests/checks)
#
# Proves the actual, end-to-end reason this project exists: a private
# (VLAN-only) client instance can reach the public internet at all, and
# the IP the internet sees it as is genuinely one of this pool's own NAT
# node public IPs -- not a leak through some other unexpected path (a
# stray default route, a forgotten public IP on the client instance
# itself, etc.).
#
# -----------------------------------------------------
# What this verifies (per pool with a `client_host` configured):
#
# 1) SSHes into `client_host` (a private-subnet instance already running
#    client-agent -- see client-agent/README.md) and curls
#    `egress_test_target` (default: https://ifconfig.me/ip, a plain-text
#    "what's my IP" echo service) `sample_count` times (default 5).
# 2) Every observed egress IP must be one of the pool's own nodes'
#    `public_ips`, read live from the roster (not hardcoded in
#    config.yaml) -- so this check stays correct across node
#    replacement/autoscale without needing config edits.
# 3) Reports how many DISTINCT node IPs were observed across the sample
#    -- with more than one healthy node in the pool, seeing only one IP
#    repeatedly across `sample_count` requests can indicate client-agent
#    isn't actually load-spreading (informational, not a hard failure by
#    itself, since client-agent's consistent-hashing nexthop groups
#    intentionally give flow affinity, not necessarily per-request
#    spread -- see docs/ARCHITECTURE.md section 3.2).
#
# -----------------------------------------------------
# Usage:
#
# python run_acceptance_tests.py --only 02-nat-egress
#
# -----------------------------------------------------
# Best Practices:
#
# - `client_host` must be a private-subnet instance that ONLY reaches the
#   internet via this pool's NAT path (no public IP of its own) -- this
#   check can't tell "NAT worked" apart from "the client had its own
#   route to the internet all along" if that assumption doesn't hold.
# - Requires SSH access from wherever this suite runs to `client_host` --
#   see config.example.yaml's `ssh` block.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Real end-to-end NAT egress check: SSH into a private client instance,
curl an external IP-echo service, and confirm the observed egress IP is
genuinely one of this pool's own node public IPs (read live from the
roster).
"""
from __future__ import annotations

import subprocess
import time

import requests
from lib.config import Config, MissingConfigError
from lib.http_client import request_with_backoff
from lib.reporter import Reporter

CHECK_ID = "02-nat-egress"
DESCRIPTION = "a private client instance's egress IP is genuinely one of this pool's NAT node IPs"

DEFAULT_TARGET = "https://ifconfig.me/ip"
DEFAULT_SAMPLE_COUNT = 5
SSH_TIMEOUT_SECONDS = 15


def _ssh_curl(ssh_user: str, ssh_key: str | None, host: str, target: str) -> str:
    ssh_cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    if ssh_key:
        ssh_cmd += ["-i", ssh_key]
    # -4 is required, not optional: client-agent deliberately only manages
    # the IPv4 default route (docs/ARCHITECTURE.md) and leaves IPv6
    # untouched, so on any normal dual-stack client a plain curl to an
    # AAAA-capable target goes out the client's own native IPv6 path --
    # bypassing the NAT gateway entirely -- and this check would then
    # report a false "traffic may be leaking" FAIL against a perfectly
    # correct deployment. Found live, M28 (roadmap/M28-full-production-
    # readiness-pass.md's acceptance-suite section) -- this reproduced on
    # BOTH pools tested, not an edge case.
    ssh_cmd += [f"{ssh_user}@{host}", f"curl -4 -s --max-time 10 {target}"]
    out = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=SSH_TIMEOUT_SECONDS, check=True)
    return out.stdout.strip()


def run(cfg: Config, report: Reporter) -> None:
    ssh_user = cfg.ssh.get("user", "root")
    ssh_key = cfg.ssh.get("key_path")

    if not cfg.pools:
        report.skipped(CHECK_ID, "no pools configured in config.yaml -- nothing to check")
        return

    for pool_name, pool in cfg.pools.items():
        started = time.monotonic()
        try:
            roster_url, client_host = cfg.require(pool, "roster_url", "client_host", context=f"pool '{pool_name}'")
        except MissingConfigError as exc:
            report.skipped(CHECK_ID, f"{pool_name}: {exc}", started)
            continue

        target = pool.get("egress_test_target", DEFAULT_TARGET)
        sample_count = int(pool.get("egress_sample_count", DEFAULT_SAMPLE_COUNT))

        try:
            resp = request_with_backoff("GET", roster_url, timeout=10)
            resp.raise_for_status()
            nodes = resp.json()["nodes"]
        except (requests.exceptions.RequestException, ValueError, KeyError) as exc:
            report.failed(CHECK_ID, f"{pool_name}: could not read roster to learn expected public IPs: {exc}", started)
            continue

        expected_ips = {ip for n in nodes if n.get("healthy") for ip in n.get("public_ips", [])}
        if not expected_ips:
            report.failed(CHECK_ID, f"{pool_name}: roster reports zero healthy nodes with public IPs -- run check 01 first", started)
            continue

        observed_ips: set[str] = set()
        unexpected_ips: set[str] = set()
        try:
            for _ in range(sample_count):
                ip = _ssh_curl(ssh_user, ssh_key, client_host, target)
                if ip:
                    observed_ips.add(ip)
                    if ip not in expected_ips:
                        unexpected_ips.add(ip)
        except (subprocess.SubprocessError, OSError) as exc:
            report.failed(CHECK_ID, f"{pool_name}: could not SSH into client_host {client_host}: {exc}", started)
            continue

        if not observed_ips:
            report.failed(CHECK_ID, f"{pool_name}: {sample_count} egress attempts from {client_host} returned no IP at all -- NAT path is likely broken", started)
            continue

        if unexpected_ips:
            report.failed(
                CHECK_ID,
                f"{pool_name}: observed egress IP(s) {sorted(unexpected_ips)} NOT in this pool's known public_ips "
                f"{sorted(expected_ips)} -- traffic may be leaking through an unexpected path",
                started,
            )
            continue

        report.passed(
            CHECK_ID,
            f"{pool_name}: {sample_count}/{sample_count} egress samples matched a known pool IP "
            f"({len(observed_ips)} distinct node IP(s) observed: {sorted(observed_ips)})",
            started,
        )
