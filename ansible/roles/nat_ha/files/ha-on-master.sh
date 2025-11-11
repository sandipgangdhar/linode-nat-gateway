#!/usr/bin/env bash
set -euo pipefail

# Set conntrackd to Primary
/usr/local/sbin/conntrackd-master.sh || true

VIP="{{ vlan_vip }}"
LAN="{{ vlan_if }}"

# GARP on the interface that holds the VIP (VLAN side)
arping -c 4 -A -I "${LAN}" "${VIP}" || true

# Expose VRRP role metric (for Alertmanager)
mkdir -p /var/lib/node_exporter/textfile_collector || true
echo "nat_vrrp_preferred_master 1 $(date +%s)" > /var/lib/node_exporter/textfile_collector/vrrp_role.prom || true

logger -t nat-ha "Promoted to MASTER (VIP ${VIP} on ${LAN}, conntrackd Primary)"
