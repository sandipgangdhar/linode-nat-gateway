# Back-compat (single-pair). These become null in multi-pair mode.
output "shared_ipv4" {
  description = "Single-pair: shared IPv4 (null in multi-pair)."
  value       = local.is_multi ? null : var.shared_ipv4
}

output "vlan_vip" {
  description = "Single-pair: VLAN VIP (null in multi-pair)."
  value       = local.is_multi ? null : var.vlan_vip
}

output "nat_a_vlan_ip" {
  description = "Single-pair: NAT-A VLAN IP (null in multi-pair)."
  value       = local.is_multi ? null : var.nat_a_vlan_ip
}

output "nat_b_vlan_ip" {
  description = "Single-pair: NAT-B VLAN IP (null in multi-pair)."
  value       = local.is_multi ? null : var.nat_b_vlan_ip
}

# Multi-pair compact summary
output "pair_summary" {
  value = {
    for pair_name in local.pair_names :
    pair_name => {
      fip      = try(local.nat_pairs_by_name[pair_name].shared_ipv4, null)
      vlan_vip = try(local.nat_pairs_by_name[pair_name].vlan_vip, null)

      a = {
        id = try(linode_instance.multi["${pair_name}-a"].id, null)
        pub = try(
          linode_instance.multi["${pair_name}-a"].ip_address,
          one(linode_instance.multi["${pair_name}-a"].ipv4),
          null
        )
        vlan = try(split("/", linode_instance.multi["${pair_name}-a"].config[0].interface[1].ipam_address)[0], null)
      }
      b = {
        id = try(linode_instance.multi["${pair_name}-b"].id, null)
        pub = try(
          linode_instance.multi["${pair_name}-b"].ip_address,
          one(linode_instance.multi["${pair_name}-b"].ipv4),
          null
        )
        vlan = try(split("/", linode_instance.multi["${pair_name}-b"].config[0].interface[1].ipam_address)[0], null)
      }
    }
  }
  depends_on = [linode_instance.multi]
}
