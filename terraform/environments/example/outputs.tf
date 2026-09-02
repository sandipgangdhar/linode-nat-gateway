# outputs.tf (terraform/environments/example)
#
# Everything you need after `terraform apply` to wire up client instances
# and reach the observability stack.
#
# -----------------------------------------------------
# Outputs:
#
# 1) shared_pool_node_private_ips / dedicated_acme_pool_node_private_ips -
#    Reference only; client-agent doesn't need these directly since it
#    polls the roster URLs below instead.
# 2) natctl_roster_url_shared / natctl_roster_url_dedicated_acme - Feed
#    directly into client-agent/install.sh --natctl-url on every private
#    instance that needs NAT egress.
# 3) grafana_url / prometheus_url - Open these to see the fleet's live
#    metrics and dashboards.
# 4) vpc_id / private_subnet_ids   - Reference for wiring up additional
#    workloads into this same VPC.
# 5) shared_pool_placement_group_ids / dedicated_acme_pool_placement_group_ids -
#    M16: this pool's Placement Group IDs when placement_group_enabled is
#    true; empty otherwise.
#
# roadmap/M20-remove-terraform-client-creation.md: this environment no
# longer creates client instances, so there are no client-related
# outputs here anymore -- see scripts/install-nat-client.sh and
# docs/RUNBOOK.md's "Onboard a client instance" section instead.
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

output "shared_pool_node_private_ips" {
  description = "Point every private-app-1 / private-app-2 client instance's ECMP next-hop set at all of these (see client-agent/) — not a single VIP."
  value       = module.nat_fleet_shared.node_private_ips
}

output "dedicated_acme_pool_node_private_ips" {
  value = var.enable_dedicated_pool_example ? module.nat_fleet_dedicated_acme[0].node_private_ips : {}
}

output "shared_pool_placement_group_ids" {
  description = "M16: this pool's Placement Group IDs when placement_group_enabled is true; empty list otherwise."
  value       = module.nat_fleet_shared.placement_group_ids
}

output "dedicated_acme_pool_placement_group_ids" {
  description = "M16: this pool's Placement Group IDs when placement_group_enabled is true; empty list otherwise (or if the dedicated pool itself is disabled)."
  value       = var.enable_dedicated_pool_example ? module.nat_fleet_dedicated_acme[0].placement_group_ids : []
}

output "natctl_roster_url_shared" {
  description = "Set NATCTL_ROSTER_URL to this on every client-agent instance in the shared pool's subnets. Uses local.natctl_roster_base_url (not module.observability directly) since natctl_on_node_enabled may mean there's no dedicated observability instance to point at all -- see main.tf's create_observability_instance."
  value       = "${local.natctl_roster_base_url}/fleet/shared"
}

output "natctl_roster_url_dedicated_acme" {
  value = var.enable_dedicated_pool_example ? "${local.natctl_roster_base_url}/fleet/dedicated-acme-corp" : null
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

# roadmap/M20-remove-terraform-client-creation.md (2026-09-02):
# client_instance_ids/client_public_ips/client_static_vlan_addresses
# outputs (v14/v18, fed by module.client_fleet/var.client_groups) are
# removed alongside that mechanism -- this environment no longer creates
# client instances, so there's nothing left to report here. See
# docs/RUNBOOK.md's "Onboard a client instance" section.
