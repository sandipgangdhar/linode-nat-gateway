#!/usr/bin/env bash
set -euo pipefail

# Set conntrackd to Backup
/usr/local/sbin/conntrackd-backup.sh || true

# Update VRRP role metric
mkdir -p /var/lib/node_exporter/textfile_collector || true
echo "nat_vrrp_preferred_master 0 $(date +%s)" > /var/lib/node_exporter/textfile_collector/vrrp_role.prom || true

logger -t nat-ha "Demoted to BACKUP (conntrackd Backup)"
