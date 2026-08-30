#!/usr/bin/env bash
# loadtest.sh (scripts)
#
# Drives synthetic concurrent HTTP egress traffic out through whichever
# NAT nodes client-agent's ECMP route currently sends it to. This is the
# primary tool for generating real demo/validation data in Grafana: watch
# per-node and fleet-wide throughput, conntrack occupancy, and port
# headroom respond in real time while this runs.
#
# -----------------------------------------------------
# Parameters:
#
# 1) --connections - Concurrent connections to drive (default 500).
# 2) --duration     - How long to run, in seconds (default 120).
# 3) --target        - URL to hit repeatedly (default a lightweight
#    generate_204 endpoint so the test doesn't waste bandwidth on
#    response bodies).
# 4) --target-ip     - Optional. Pre-resolved IPv4 address for --target's
#    hostname, pinned into /etc/hosts before the run instead of trusting
#    THIS host's own DNS resolver -- see the BUG FIX comment further
#    down for why this matters once every request opens a genuinely new
#    connection (a small client instance's own resolver can become the
#    actual bottleneck, or fail outright, under real concurrency).
#    acceptance-tests/checks/check_05_autoscale.py resolves this itself
#    and always passes it; a manual run can omit it and fall back to
#    local resolution.
#
# -----------------------------------------------------
# Usage:
#
# ./loadtest.sh --connections 500 --duration 120 --target https://example.com
#
# Run FROM a private-subnet client instance with client-agent already
# installed and running (not from your workstation) -- requires `hey`
# (https://github.com/rakyll/hey).
#
# -----------------------------------------------------
# Best Practices:
#
# - Cross-check nat_conntrack_entries and nat_interface_bytes_total across
#   every node in the pool afterward -- with enough concurrent
#   connections you should see load spread across multiple nodes, not
#   concentrated on one.
# - Confirm no NATPortExhaustionImminent / NATConntrackTableCritical
#   alerts fired unless the run was deliberately sized to trigger them.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

set -euo pipefail

CONNECTIONS=500
DURATION=120
TARGET="https://www.gstatic.com/generate_204"
TARGET_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    # BUG FIX (found live, 2026-08-30): --disable-keepalive below means a
    # fresh DNS lookup per request, not just a fresh TCP connection --
    # confirmed live this can overwhelm a small client instance's own
    # local resolver under real concurrency (500-way concurrency
    # achieved only ~37 req/sec, almost all requests failing with
    # "Temporary failure in name resolution", not just running slower).
    # Optional: resolve the target's IP from wherever's invoking this
    # script (see acceptance-tests/checks/check_05_autoscale.py, which
    # resolves it before SSHing in) instead of trusting THIS host's own
    # resolver, which may be less reliable. Falls back to local
    # resolution below if not given.
    --target-ip) TARGET_IP="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v hey >/dev/null 2>&1 || {
  echo "This script uses 'hey' (https://github.com/rakyll/hey) for concurrent HTTP load." >&2
  echo "Install it first, e.g.: go install github.com/rakyll/hey@latest" >&2
  exit 1
}

echo "Driving ${CONNECTIONS} concurrent connections against ${TARGET} for ${DURATION}s..."
echo "Watch dashboards/nat-overview.json (conntrack utilization, PPS, throughput) during this run."

# BUG FIX (found live, 2026-08-30, same investigation as the -disable-
# keepalive fix below): forcing a fresh TCP connection per request also
# means a fresh DNS lookup per request (no connection to cache it
# against) -- confirmed live this overwhelms a small client instance's
# own local resolver under real concurrency: a 500-concurrency run
# achieved only ~37 req/sec, with the overwhelming majority of requests
# failing outright ("Temporary failure in name resolution" /
# context-deadline-exceeded waiting on a hung lookup), not just running
# slower. Pin the target's hostname to its already-resolved IP in
# /etc/hosts once, up front, instead of re-resolving it thousands of
# times a minute -- every subsequent lookup (from hey or anything else)
# now resolves instantly, locally, with zero network round-trips.
# Deliberately NOT done by rewriting TARGET to a raw IP + a `hey -host`
# override instead: that would change what SNI hostname the TLS
# handshake presents, which a real multi-tenant HTTPS endpoint (this
# script's own default target included) can reject or mis-route on --
# pinning /etc/hosts keeps the hostname in the URL/SNI/Host header
# exactly as before, only short-circuiting the lookup itself.
TARGET_HOST=$(echo "$TARGET" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')
if [[ -n "$TARGET_HOST" ]]; then
  if [[ -n "$TARGET_IP" ]]; then
    RESOLVED_IP="$TARGET_IP"
  else
    # Fall back to local resolution. NOTE: `RESOLVED_IP=$(cmd)` alone
    # trips `set -e` on a non-zero exit from cmd even though the value
    # is checked right afterward -- the failure happens at the
    # assignment itself. `|| true` makes a lookup failure non-fatal,
    # exactly as intended (proceed without pinning, not abort the drill).
    RESOLVED_IP=$(getent ahostsv4 "$TARGET_HOST" 2>/dev/null | awk '{print $1; exit}') || true
  fi
  if [[ -n "$RESOLVED_IP" ]]; then
    sed -i "/[[:space:]]${TARGET_HOST}\$/d" /etc/hosts
    echo "${RESOLVED_IP} ${TARGET_HOST}" >> /etc/hosts
    echo "Pinned ${TARGET_HOST} -> ${RESOLVED_IP} in /etc/hosts (avoids DNS becoming the bottleneck under concurrent -disable-keepalive load)."
  else
    echo "WARNING: could not resolve ${TARGET_HOST} (no --target-ip given and local resolution failed) -- proceeding without pinning it; expect DNS lookups to become a real bottleneck under load." >&2
  fi
fi

# BUG FIX (found live, 2026-08-30, roadmap/M7-acceptance-suite.md's
# check_05 investigation): hey reuses each worker's TCP connection across
# every request it sends (HTTP keep-alive) unless told not to -- so
# raising --duration/request-count alone never increased the number of
# DISTINCT connections opened, only --connections (concurrency) did.
# Confirmed live: a 500-connection, 120s run completed 1,000,000 requests
# at ~14,800 req/sec, yet natctl's own conntrack/port-headroom/throughput
# metrics stayed essentially at baseline throughout, because only ~500
# actual TCP connections (matching the concurrency, not the request
# count) were ever open against the fleet at once. -disable-keepalive
# forces a genuinely new TCP connection per request -- the realistic
# scenario this check exists to simulate (many distinct clients/flows
# through the NAT gateway, not one client reusing a handful of
# connections) -- so request RATE, not just concurrency, now drives real
# conntrack-entry creation pressure the way a real traffic spike would.
hey -disable-keepalive -z "${DURATION}s" -c "${CONNECTIONS}" -m GET "${TARGET}" || true

echo
echo "Done. Cross-check nat_conntrack_entries and nat_interface_bytes_total across the"
echo "pool's nodes (dashboards/nat-overview.json) against what this run should have"
echo "produced — with enough concurrent connections you should see load spread across"
echo "multiple nodes, not concentrated on one. Confirm no NATPortExhaustionImminent /"
echo "NATConntrackTableCritical alerts fired unless expected."
