#!/usr/bin/env bash
# Emits gauges for Prometheus node_exporter textfile collector
# Default output: /var/lib/node_exporter/textfile_collector/nat_ha.prom

OUT=${1:-/var/lib/node_exporter/textfile_collector/nat_ha.prom}
TMP="$(mktemp)"
NOW=$(date +%s)

COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)

echo "# HELP nat_conntrack_count Current conntrack entries" > "$TMP"
echo "# TYPE nat_conntrack_count gauge" >> "$TMP"
echo "nat_conntrack_count $COUNT $NOW" >> "$TMP"

echo "# HELP nat_conntrack_max Maximum conntrack entries" >> "$TMP"
echo "# TYPE nat_conntrack_max gauge" >> "$TMP"
echo "nat_conntrack_max $MAX $NOW" >> "$TMP"

# Heuristic: number of DROP_FWD rules observed (placeholder signal)
DROPS=$(nft list ruleset 2>/dev/null | awk '/DROP_FWD/ {print $0}' | wc -l | tr -d ' ')
echo "# HELP nat_drop_counters_suspected Heuristic drop indicator" >> "$TMP"
echo "# TYPE nat_drop_counters_suspected gauge" >> "$TMP"
echo "nat_drop_counters_suspected ${DROPS:-0} $NOW" >> "$TMP"

# VRRP role: read from /run/nat-ha-role set by keepalived notify
ROLE_FILE=/run/nat-ha-role
ROLE_VAL=0
if [[ -f "$ROLE_FILE" ]]; then
  case "$(tr '[:upper:]' '[:lower:]' < "$ROLE_FILE" | tr -d '\n\r\t ')" in
    master) ROLE_VAL=1 ;;
    backup|fault|stop|"") ROLE_VAL=0 ;;
  esac
fi
echo "# HELP nat_vrrp_role 1=MASTER, 0=BACKUP" >> "$TMP"
echo "# TYPE nat_vrrp_role gauge" >> "$TMP"
echo "nat_vrrp_role ${ROLE_VAL} ${NOW}" >> "$TMP"

mv "$TMP" "$OUT"
