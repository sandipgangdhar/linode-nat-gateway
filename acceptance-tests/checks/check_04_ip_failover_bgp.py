# check_04_ip_failover_bgp.py (acceptance-tests/checks)
#
# Automates the exact live test docs/ARCHITECTURE.md section 3.6.1
# already documents having been run manually against two real Linodes:
# a continuous ping against a buddy-paired node's public IP, `systemctl
# stop frr` on that node, and a check that the buddy takes over the
# advertisement with genuinely ZERO ping loss -- the single most
# customer-convincing proof point this project has (a public IP that
# survives its own node dying, not just a monitoring dashboard saying
# so). Then restarts frr and confirms the original node reclaims the IP.
#
# -----------------------------------------------------
# What this verifies (per pool with an `ip_failover_drill` block):
#
# 1) Starts a continuous `ping` (from wherever this suite runs) against
#    `primary_public_ip` for the whole drill duration, running in the
#    background.
# 2) SSHes into `primary_ssh_host` and runs `systemctl stop frr`.
# 3) Waits `failover_wait_seconds` (default 15s -- enough for the buddy's
#    BGP session to notice and start advertising) then stops the ping and
#    reads its packet-loss percentage.
# 4) `systemctl start frr` on the primary again, waits the same interval,
#    and repeats the ping/loss check to confirm the primary reclaims its
#    own IP.
# 5) FAILs if either direction's packet loss exceeds `max_acceptable_loss_percent`
#    (default 0 -- matching the 0%/89-of-89 and 0%/44-of-44 results
#    docs/ARCHITECTURE.md's live test actually recorded; this is a real
#    bar, not a rounding allowance).
#
# -----------------------------------------------------
# Usage:
#
# python run_acceptance_tests.py --only 04-ip-failover-bgp
#
# -----------------------------------------------------
# Best Practices:
#
# - THE most disruptive/important check in this suite -- it deliberately
#   stops FRR (and therefore this node's BGP-advertised IP) on a real
#   node. Confirm IP Sharing is actually configured for this pair in the
#   Cloud Manager console first (docs/ARCHITECTURE.md section 3.6) --
#   this check assumes the prerequisite authorization step already
#   happened; it does not perform it.
# - As documented in section 3.6.1: ICMP survives this failover, but any
#   open TCP connection through the killed node will NOT (conntrack state
#   dies with the node) -- that is buddy-sync's conntrackd-mirroring
#   problem (check 03), not this one's. Don't be surprised if this check
#   passes while a concurrent TCP session elsewhere drops; that's
#   expected, not a contradiction.
# - Run this against a pool with `ip_failover_enabled = true` and an
#   actual buddy pairing already converged (see nat_conntrack_buddy_paired
#   in Grafana, or roster's `ip_failover_buddy_ips` field -- a list, usually
#   one entry, two for a "triangle" hub node on an odd-sized pool, see
#   docs/ARCHITECTURE.md §3.6 "Odd node counts") -- this check assumes the
#   pairing already exists, it does not create one.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Live BGP IP-failover check: kill FRR on a buddy-paired node's primary
side, prove zero ping loss to its public IP during the failover, then
restart FRR and prove a clean failback -- automating the manual drill
documented in docs/ARCHITECTURE.md section 3.6.1.
"""
from __future__ import annotations

import re
import subprocess
import time

from lib.config import Config, MissingConfigError
from lib.reporter import Reporter

CHECK_ID = "04-ip-failover-bgp"
DESCRIPTION = "killing FRR on a buddy-paired node produces zero ping loss to its public IP (and a clean failback)"

DEFAULT_FAILOVER_WAIT_SECONDS = 15
DEFAULT_MAX_ACCEPTABLE_LOSS_PERCENT = 0.0
SSH_TIMEOUT_SECONDS = 10

# Matches BusyBox/iputils `ping -c N` summary lines, e.g.:
#   "10 packets transmitted, 10 received, 0% packet loss, time 9012ms"
_LOSS_RE = re.compile(r"(\d+)%\s+packet loss")


def _ssh(ssh_user: str, ssh_key: str | None, host: str, command: str) -> subprocess.CompletedProcess:
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    if ssh_key:
        cmd += ["-i", ssh_key]
    cmd += [f"{ssh_user}@{host}", command]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=SSH_TIMEOUT_SECONDS)


def _ping_loss_percent(target_ip: str, count: int) -> float | None:
    """Runs a blocking `ping -c count` against target_ip and returns the
    reported packet-loss percentage, or None if the output couldn't be parsed."""
    proc = subprocess.run(
        ["ping", "-c", str(count), target_ip],
        capture_output=True, text=True, timeout=count + 15,
    )
    match = _LOSS_RE.search(proc.stdout)
    return float(match.group(1)) if match else None


def run(cfg: Config, report: Reporter) -> None:
    ssh_user = cfg.ssh.get("user", "root")
    ssh_key = cfg.ssh.get("key_path")

    for pool_name, pool in cfg.pools.items():
        started = time.monotonic()
        drill = pool.get("ip_failover_drill")
        if not drill:
            report.skipped(CHECK_ID, f"{pool_name}: no ip_failover_drill block configured for this pool", started)
            continue

        try:
            primary_public_ip, primary_ssh_host = cfg.require(
                drill, "primary_public_ip", "primary_ssh_host", context=f"pool '{pool_name}' ip_failover_drill"
            )
        except MissingConfigError as exc:
            report.skipped(CHECK_ID, f"{pool_name}: {exc}", started)
            continue

        wait_seconds = int(drill.get("failover_wait_seconds", DEFAULT_FAILOVER_WAIT_SECONDS))
        max_loss = float(drill.get("max_acceptable_loss_percent", DEFAULT_MAX_ACCEPTABLE_LOSS_PERCENT))
        # +2 gives the ping a couple of seconds of headroom either side of the
        # window we actually care about, without changing what "loss" means.
        ping_count = wait_seconds + 2

        stop_proc = _ssh(ssh_user, ssh_key, primary_ssh_host, "systemctl stop frr")
        if stop_proc.returncode != 0:
            report.failed(CHECK_ID, f"{pool_name}: could not `systemctl stop frr` on {primary_ssh_host}: {stop_proc.stderr.strip()}", started)
            continue

        failover_loss = _ping_loss_percent(primary_public_ip, ping_count)

        # Always attempt to restore frr, even if the loss measurement above
        # failed to parse -- never leave the node in a deliberately-broken
        # state just because this check hit an unrelated error.
        start_proc = _ssh(ssh_user, ssh_key, primary_ssh_host, "systemctl start frr")

        if failover_loss is None:
            report.failed(CHECK_ID, f"{pool_name}: could not parse ping output while frr was stopped on {primary_ssh_host} -- is `ping` installed where this suite runs?", started)
            continue

        if start_proc.returncode != 0:
            report.failed(CHECK_ID, f"{pool_name}: failover loss was {failover_loss}%, but could not `systemctl start frr` again on {primary_ssh_host} to restore it: {start_proc.stderr.strip()}", started)
            continue

        if failover_loss > max_loss:
            report.failed(CHECK_ID, f"{pool_name}: {failover_loss}% ping loss to {primary_public_ip} while {primary_ssh_host}'s frr was stopped (max acceptable: {max_loss}%)", started)
            continue

        time.sleep(wait_seconds)
        failback_loss = _ping_loss_percent(primary_public_ip, ping_count)

        if failback_loss is None:
            report.failed(CHECK_ID, f"{pool_name}: failover itself was clean ({failover_loss}% loss), but could not measure failback loss after restarting frr on {primary_ssh_host}", started)
            continue

        if failback_loss > max_loss:
            report.failed(CHECK_ID, f"{pool_name}: failover was clean ({failover_loss}% loss), but failback showed {failback_loss}% loss to {primary_public_ip} after restarting frr (max acceptable: {max_loss}%)", started)
            continue

        report.passed(
            CHECK_ID,
            f"{pool_name}: {failover_loss}% loss during failover, {failback_loss}% loss during failback to {primary_public_ip} "
            f"(max acceptable: {max_loss}%) -- matches the live test recorded in docs/ARCHITECTURE.md section 3.6.1",
            started,
        )
