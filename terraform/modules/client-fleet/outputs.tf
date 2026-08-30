# outputs.tf (terraform/modules/client-fleet)
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

output "instance_ids" {
  description = "Map of instance label -> Linode instance id, for this group."
  value       = { for k, i in linode_instance.client : k => i.id }
}

output "public_ips" {
  description = "Map of instance label -> public IPv4. Empty string for any instance when interface_mode is \"vlan_only\" or \"vpc_vlan\" (no public-purpose interface at all). For \"public_vpc_vlan\" (1:1 NAT on a VPC interface, no separate public-purpose interface), whether linode_instance's own ip_address attribute reflects the NAT'd address is UNVERIFIED against a real apply as of this writing -- if it comes back empty for that mode, look up the NAT'd address via Cloud Manager/linode-cli instead."
  value       = { for k, i in linode_instance.client : k => try(i.ip_address, "") }
}

output "labels" {
  description = "Every instance label created by this group -- e.g. for cross-referencing against `linode-cli linodes list` or Cloud Manager."
  value       = local.node_ids
}
