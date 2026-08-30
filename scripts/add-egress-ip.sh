#!/usr/bin/env bash
# add-egress-ip.sh (scripts)
#
# Wires an already-allocated extra egress IP into a running node's live
# NAT rules. This is a deliberate day-2 script, not something baked into
# initial boot -- the IP isn't known until after the node (and its
# cloud-init) already exist, same dependency-cycle reasoning documented in
# ansible/templates/nftables.conf.tftpl.
#
# -----------------------------------------------------
# Parameters:
#
# 1) --ip            - The already-allocated extra public IP to wire in.
# 2) --bucket-index   - 1 for the first extra IP, 2 for the second, etc.
# 3) --bucket-count   - Total egress IPs this node now has, including its
#    primary (bucket 0).
#
# -----------------------------------------------------
# Usage (run ON the NAT node, as root):
#
# ./add-egress-ip.sh --ip 203.0.113.42 --bucket-index 1 --bucket-count 2
#
# Prerequisite: the IP must already be allocated to this node via
# `terraform apply -var 'egress_ips_per_node=<n+1>'` on the relevant
# nat-fleet module call. See docs/ARCHITECTURE.md section 4.4.
#
# -----------------------------------------------------
# Best Practices:
#
# - Re-run the same command after any reboot -- nftables config isn't
#   regenerated from Terraform state automatically -- or check the
#   updated ruleset into your own config management.
# - Verify with `nft list table inet lng_nat` after running.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) IP="$2"; shift 2 ;;
    --bucket-index) BUCKET_INDEX="$2"; shift 2 ;;
    --bucket-count) BUCKET_COUNT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${IP:?--ip is required}"
: "${BUCKET_INDEX:?--bucket-index is required (1 for the first extra IP, 2 for the second, ...)}"
: "${BUCKET_COUNT:?--bucket-count is required (total egress IPs this node now has, including its primary)}"

# 1. Confirm the IP is actually configured on eth0 (Linode's network
#    config should have already added it — if not, add it manually first
#    via `ip addr add <ip>/32 dev eth0` and persist it in your netplan/
#    interfaces config so it survives reboot).
if ! ip -4 -o addr show eth0 | grep -q "$IP"; then
  echo "WARNING: $IP is not yet configured on eth0. Add it there first (and persist it), then re-run this script." >&2
  exit 1
fi

# 2. Add a dedicated SNAT chain for this IP and jump to it via a verdict
#    map bucket, alongside the existing masquerade-only postrouting rule.
#    This is intentionally additive/idempotent: re-running with the same
#    --ip is safe.
nft add chain inet lng_nat "snat_extra_${BUCKET_INDEX}" 2>/dev/null || true
nft flush chain inet lng_nat "snat_extra_${BUCKET_INDEX}"
# BUG FIX (found live, 2026-08-01): "snat to <ip>" (no address family) is
# invalid inside an `inet` table -- confirmed live against this exact
# lng_nat table on a freshly-provisioned node ("Error: ip or ip6 must be
# specified with address for inet tables"). inet tables are dual-stack,
# so nftables can't infer the family without an explicit qualifier -- see
# the identical fix in ansible/templates/nftables.conf.tftpl and
# controller/natctl/cloud_init.py's render_nftables().
nft add rule inet lng_nat "snat_extra_${BUCKET_INDEX}" snat ip to "$IP"

# 3. Rebuild the postrouting jump so traffic is spread across the primary
#    (masquerade, bucket 0) and every extra IP registered so far.
nft flush chain inet lng_nat postrouting
MAP="0: jump snat_primary"
for i in $(seq 1 "$((BUCKET_COUNT - 1))"); do
  MAP="${MAP}, ${i}: jump snat_extra_${i}"
done
nft add rule inet lng_nat postrouting numgen inc mod "$BUCKET_COUNT" vmap "{ $MAP }"

echo "Added $IP as egress bucket $BUCKET_INDEX of $BUCKET_COUNT. Verify with: nft list table inet lng_nat"
echo "Remember to persist this by re-running the same command after any reboot (nftables config isn't"
echo "regenerated from Terraform state automatically) or by checking the updated ruleset into your own"
echo "config-management if you use one."
