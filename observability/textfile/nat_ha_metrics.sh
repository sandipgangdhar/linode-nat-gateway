#!/usr/bin/env bash
# Emits simple gauges for Prometheus node_exporter textfile collector
# Usage: nat_ha_metrics.sh > /var/lib/node_exporter/textfile_collector/nat_ha.prom

OUT=${1:-/var/lib/node_exporter/textfile_collector/nat_ha.prom}
TMP="$(mktemp)"
NOW=$(date +%s)

COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)

echo "# HELP nat_conntrack_count Current conntrack entries" > "$TMP"
echo "# TYPE nat_conntrack_count gauge" >> "$TMP"
echo "nat_conntrack_count $COUNT $NOW" >> "$TMP"

echo "# HELP nat_conntrack_max Maximum conntrack entries" >> "$TMP"
echo "# TYPE nat_conntrack_max gauge" >> "$TMP"
echo "nat_conntrack_max $MAX $NOW" >> "$TMP"

# nftables counters (example: forward chain drops)
DROPS=$(nft list ruleset | awk '/DROP_FWD/ {print $0}' | wc -l | tr -d ' ')
echo "# HELP nat_drop_counters_suspected Number of drop rules observed (indicative)" >> "$TMP"
echo "# TYPE nat_drop_counters_suspected gauge" >> "$TMP"
echo "nat_drop_counters_suspected $DROPS $NOW" >> "$TMP"

mv "$TMP" "$OUT"
