#!/usr/bin/env bash
# node-failure-drill.sh (scripts)
#
# Simulates one NAT node going unhealthy (without actually taking the
# instance down) and verifies the active-active fleet's core promise: a
# client instance's client-agent notices and routes around it within a
# few probe cycles, and the node rejoins cleanly once restored.
#
# -----------------------------------------------------
# What this verifies:
#
# 1) The node's own /healthz starts failing (simulated by stopping
#    nat-exporter, not the node itself).
# 2) The observing client's client-agent removes the node from its ECMP
#    route/nexthop group within --max-wait seconds.
# 3) Restoring nat-exporter lets the node rejoin the client's route
#    within --max-wait seconds.
#
# -----------------------------------------------------
# Parameters:
#
# 1) --node-host    - The NAT node's address AS IT APPEARS IN THE CLIENT'S
#    ROUTE TABLE -- on this project's pure-nat-gateway branch, that's the
#    node's VLAN (eth2) address (client-agent's ECMP nexthops are VLAN
#    addresses, docs/ARCHITECTURE.md §3.0/§3.2), used ONLY for the
#    before/after `ip route show`/`ip nexthop show` grep match -- never
#    SSHed into directly.
# 2) --node-ssh-host - The address actually used to SSH into the node and
#    run `systemctl stop/start nat-exporter` -- MUST be different from
#    --node-host on this branch: the node's own nftables ruleset
#    deliberately excludes SSH on the VLAN interface entirely
#    (`iifname != "eth2" tcp dport 22 ... accept`, roadmap/M2-security.md
#    test case 2.8), so passing the VLAN address here would just fail to
#    connect -- confirmed live, 2026-08-30, roadmap/M7-acceptance-suite.md
#    (a real bug: this parameter used to double as both the route-match
#    target AND the SSH target, which only ever worked by coincidence on
#    a topology where a node's "private IP" was a single address serving
#    both roles). Use the node's VPC or public IP -- whichever this
#    script's own caller can actually reach given the Cloud Firewall's
#    admin_cidrs/VPC-subnet scoping (see that same M2 test case). Defaults
#    to --node-host if not given, for any topology where a single address
#    genuinely does serve both roles.
# 3) --client-host   - Private IP of a client instance running
#    client-agent, to observe from.
# 4) --ssh-user       - SSH user for all hosts (default root).
# 5) --max-wait        - Seconds to wait for each expected transition
#    (default 20).
#
# -----------------------------------------------------
# Usage:
#
# ./node-failure-drill.sh --node-host <nat-node-vlan-ip> --node-ssh-host <nat-node-vpc-or-public-ip> --client-host <client-instance-ip>
#
# -----------------------------------------------------
# Best Practices:
#
# - Run this against a pool with more than 2 healthy nodes so failing one
#   doesn't also violate min_nodes and trigger an unrelated autoscale
#   event mid-drill.
# - Exits non-zero on either failure mode (node not removed in time, node
#   not rejoined in time) -- safe to wire into the automated test suite
#   (see docs/RUNBOOK.md and the post-deploy test plan).
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

set -euo pipefail

SSH_USER="root"
MAX_WAIT_SECONDS=20
NODE_SSH_HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-host) NODE_HOST="$2"; shift 2 ;;
    --node-ssh-host) NODE_SSH_HOST="$2"; shift 2 ;;
    --client-host) CLIENT_HOST="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --max-wait) MAX_WAIT_SECONDS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${NODE_HOST:?}" "${CLIENT_HOST:?}"
NODE_SSH_HOST="${NODE_SSH_HOST:-$NODE_HOST}"

ssh_cmd() { ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@$1" "$2"; }

echo "== LNG node-failure drill =="
echo "Target node (route-table match): ${NODE_HOST}   SSH target: ${NODE_SSH_HOST}   Observing client: ${CLIENT_HOST}"

echo "Baseline: checking ${NODE_HOST} is currently in the client's route table..."
if ! ssh_cmd "$CLIENT_HOST" "ip route show default" | grep -q "$NODE_HOST"; then
  echo "WARNING: ${NODE_HOST} was not found in the client's current default route. Continuing anyway — it may be legitimately unhealthy already, or using a resilient nexthop group (check 'ip nexthop show')." >&2
fi

echo "Stopping nat-exporter on ${NODE_HOST} (this makes /healthz stop responding, simulating an unhealthy node without actually taking the instance down)..."
ssh_cmd "$NODE_SSH_HOST" "systemctl stop nat-exporter"

echo -n "Waiting for the client to remove ${NODE_HOST} from its route table (max ${MAX_WAIT_SECONDS}s)..."
elapsed=0
while (( elapsed < MAX_WAIT_SECONDS )); do
  if ! ssh_cmd "$CLIENT_HOST" "ip route show default; ip nexthop show 2>/dev/null" | grep -q "$NODE_HOST"; then
    echo " done in ${elapsed}s"
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
  echo -n "."
done

if ssh_cmd "$CLIENT_HOST" "ip route show default; ip nexthop show 2>/dev/null" | grep -q "$NODE_HOST"; then
  echo
  echo "FAIL: ${NODE_HOST} is still present in the client's route table after ${MAX_WAIT_SECONDS}s" >&2
  echo "Restoring nat-exporter on ${NODE_HOST} before exiting..."
  ssh_cmd "$NODE_SSH_HOST" "systemctl start nat-exporter"
  exit 1
fi

echo "PASS: client removed the unhealthy node within ${MAX_WAIT_SECONDS}s"

echo "Restoring nat-exporter on ${NODE_HOST}..."
ssh_cmd "$NODE_SSH_HOST" "systemctl start nat-exporter"

echo -n "Waiting for the client to re-add ${NODE_HOST} (max ${MAX_WAIT_SECONDS}s)..."
elapsed=0
while (( elapsed < MAX_WAIT_SECONDS )); do
  if ssh_cmd "$CLIENT_HOST" "ip route show default; ip nexthop show 2>/dev/null" | grep -q "$NODE_HOST"; then
    echo " done in ${elapsed}s"
    echo "PASS: node rejoined cleanly. Drill complete."
    exit 0
  fi
  sleep 2
  elapsed=$((elapsed + 2))
  echo -n "."
done

echo
echo "FAIL: ${NODE_HOST} did not rejoin the client's route table within ${MAX_WAIT_SECONDS}s of recovering" >&2
exit 1
