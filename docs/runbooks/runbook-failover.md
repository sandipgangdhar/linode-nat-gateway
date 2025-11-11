# NAT HA Failover Runbook

## Soft failover drill
1. On MASTER: `sudo systemctl stop keepalived`
2. Expect VIP on BACKUP within < 3s; ping loss ≤ 3.
3. Validate: `ip a | grep <VIP>` and `curl https://www.google.com/generate_204`

## Hard failover drill
1. On MASTER: `ip link set {{ nat_ha_wan_iface | default('eth0') }} down`
2. BACKUP must assume VIP automatically.
3. Re-enable link; ensure MASTER retakes role after `preempt_delay`.

## Stateful checks
- Start `iperf3 -s` outside; `iperf3 -c <public> -R -t 120`
- Trigger failover during test; flows must continue.

## Observability checks
- Grafana: VRRP state timeline changes
- Conntrack usage (< 80% target)
- Alertmanager: no unexpected alerts
