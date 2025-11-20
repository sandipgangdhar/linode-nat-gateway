###############################################################################
# NAT Gateway Outputs
###############################################################################

# List of all NAT pair names
output "nat_pairs" {
  description = "List of NAT pair names"
  value       = local.pair_names
}

# Map of pair → VLAN VIP
output "vlan_vip_by_pair" {
  description = "VLAN VIP for each pair"
  value = {
    for p in local.pair_names :
    p => local.nat_pairs_by_name[p].vlan_vip
  }
}

# Map of pair → shared IPv4 (if any)
output "shared_ipv4_by_pair" {
  description = "Shared IPv4 for each pair (empty string if none)"
  value = {
    for p in local.pair_names :
    p => try(local.nat_pairs_by_name[p].shared_ipv4, "")
  }
}

# Map of node_label → public IPv4
output "public_ip_by_node" {
  description = "Public IPv4 address for each NAT node"
  value = {
    for label, inst in linode_instance.multi :
    label => tolist(inst.ipv4)[0]
  }
}

# Map of node_label → VLAN IPv4
output "vlan_ip_by_node" {
  description = "VLAN IPv4 address (eth1) for each NAT node"
  value = {
    for label, m in local.members_by_label :
    label => trimsuffix(m.vlan_ip, "/24")
  }
}
