#!/usr/bin/env bash
# install.sh (client-agent) -- CUSTOMER-REPO VARIANT
#
# One-shot installer for the compiled client-agent binary: copies it and
# its systemd unit into place, writes its env file from the given flags,
# and starts it. Identical usage/parameters to the dev repo's install.sh
# -- the only difference is that this copies a pre-compiled binary
# (client-agent, shipped alongside this script) instead of
# lng_client_agent.py + a python3 interpreter.
#
# -----------------------------------------------------
# Parameters:
#
# 1) --natctl-url  - Required. natctl's roster URL for this instance's
#    pool, e.g. http://10.0.0.5:8099/fleet/shared (use
#    /fleet/<dedicated-pool-name> for a tenant with a dedicated pool).
#    May be a comma-separated list (quote it as one argument) to fail
#    over across several natctl-on-node peers instead of pointing at a
#    single node -- see lng-client-agent.env.example's NATCTL_ROSTER_URL
#    comment for why that matters.
# 2) --iface        - Optional, default eth2 -- this project's VLAN-based
#    client fleet interface. Override only if your instance's VLAN
#    interface has a non-default name.
#
# -----------------------------------------------------
# Usage:
#
# ./install.sh --natctl-url http://10.0.0.5:8099/fleet/shared --iface eth2
#
# -----------------------------------------------------
# Best Practices:
#
# - Bake this into your own instance image/cloud-init rather than running
#   it ad hoc over SSH at scale -- see OPERATIONS.md "Onboarding a new
#   client group".
# - Verify with `ip route show default` after install -- expect multiple
#   nexthops or an nhid reference to a resilient group.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

set -euo pipefail

IFACE="eth2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --natctl-url) NATCTL_URL="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${NATCTL_URL:?--natctl-url is required, e.g. http://10.0.0.5:8099/fleet/shared}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p /opt/lng-client-agent /etc/lng-client-agent
cp "${SCRIPT_DIR}/client-agent" /opt/lng-client-agent/client-agent
chmod 750 /opt/lng-client-agent/client-agent

cat > /etc/lng-client-agent/env <<EOF
NATCTL_ROSTER_URL=${NATCTL_URL}
LNG_PRIVATE_IFACE=${IFACE}
LNG_HEALTH_PROBE_TIMEOUT=1.5
LNG_DRY_RUN=false
LNG_FALLBACK_PROBE_ENABLED=false
LNG_FALLBACK_PROBE_INTERVAL=30
EOF
chmod 640 /etc/lng-client-agent/env

cp "${SCRIPT_DIR}/lng-client-agent.service" /etc/systemd/system/lng-client-agent.service
systemctl daemon-reload
systemctl enable --now lng-client-agent
systemctl restart lng-client-agent

echo "lng-client-agent installed and started. Check status with:"
echo "  systemctl status lng-client-agent"
echo "  ip route show default"
