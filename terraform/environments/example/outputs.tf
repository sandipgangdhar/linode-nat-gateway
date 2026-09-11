# outputs.tf (terraform/environments/example)
#
# Everything you need after `terraform apply` to wire up client instances
# and reach the observability stack.
#
# -----------------------------------------------------
# Outputs:
#
# 1) pool_node_private_ips / pool_placement_group_ids - One entry per pool
#    (keyed the same way var.pools is). Reference only; client-agent
#    doesn't need node_private_ips directly since it polls the roster
#    URLs below instead.
# 2) pool_roster_urls - One entry per pool. Feed directly into
#    client-agent/install.sh --natctl-url on every private instance that
#    needs NAT egress from that pool.
# 3) grafana_url / prometheus_url - Open these to see the fleet's live
#    metrics and dashboards.
# 4) vpc_id / private_subnet_ids   - Reference for wiring up additional
#    workloads into this same VPC.
#
# This environment no longer creates client instances, so there are no
# client-related outputs here -- see scripts/install-nat-client.sh and
# docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §9.3 instead.
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

output "pool_node_private_ips" {
  description = "Per pool, point every client instance in that pool's subnets' ECMP next-hop set at all of these (see client-agent/) — not a single VIP."
  value       = { for k, m in module.nat_fleet : k => m.node_private_ips }
}

output "pool_placement_group_ids" {
  description = "Per pool, its Placement Group IDs when placement_group_enabled is true; empty list otherwise."
  value       = { for k, m in module.nat_fleet : k => m.placement_group_ids }
}

output "pool_roster_urls" {
  description = "Per pool, set NATCTL_ROSTER_URL to this on every client-agent instance in that pool's subnets. Uses local.natctl_roster_base_url (not module.observability directly) since natctl_on_node_enabled may mean there's no dedicated observability instance to point at all -- see main.tf's create_observability_instance."
  value       = { for k, m in module.nat_fleet : k => "${local.natctl_roster_base_url}/fleet/${k}" }
}

output "grafana_url" {
  description = "null when run_monitoring_stack is false -- you're using your own Grafana/dashboard instead. See variables.tf."
  value       = var.run_monitoring_stack ? module.observability[0].grafana_url : null
}

output "prometheus_url" {
  description = "null when run_monitoring_stack is false -- see grafana_url above and customer_prometheus_remote_write_url if you still want this Prometheus to forward samples into your own backend."
  value       = var.run_monitoring_stack ? module.observability[0].prometheus_url : null
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}
