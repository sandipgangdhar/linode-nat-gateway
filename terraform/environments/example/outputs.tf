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
# 5) client_instance_ids / client_public_ips / client_static_vlan_addresses -
#    client_groups details, including (v18) the exact VLAN address(es)
#    assigned to each static_vlan_slot group -- feed straight into
#    `natctl_cli release-static-addresses`, no cidrhost() math needed.
#
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

# v14: client instances -- empty {} when var.client_groups is left at its
# default. See terraform/modules/client-fleet's own outputs.tf for what
# each value means.
output "client_instance_ids" {
  description = "Map of group name -> (instance label -> Linode instance id)."
  value       = { for name, m in module.client_fleet : name => m.instance_ids }
}

output "client_public_ips" {
  description = "Map of group name -> (instance label -> public IPv4, empty string for \"vlan_only\"/\"vpc_vlan\" interface_mode groups -- see terraform/modules/client-fleet/outputs.tf's own public_ips description for the \"public_vpc_vlan\" caveat)."
  value       = { for name, m in module.client_fleet : name => m.public_ips }
}

# v18: for every client_groups entry, the exact VLAN addresses Terraform
# will assign to its instances -- one per client_count, in order. Exists
# so an operator never has to compute cidrhost() by hand (see main.tf's
# local.static_client_offsets). See docs/RUNBOOK.md's "Static VLAN IPs
# for client groups" section.
output "client_static_vlan_addresses" {
  description = "Map of client_groups group name -> ordered list of its actual VLAN addresses."
  value = {
    for name, g in local.static_client_groups : name => [
      for i in range(g.client_count) : cidrhost(local.pool_vlan_cidrs[g.pool_name], local.static_client_offsets[name] + i)
    ]
  }
}
