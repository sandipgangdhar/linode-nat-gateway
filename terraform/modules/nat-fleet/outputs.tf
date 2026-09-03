# outputs.tf (terraform/modules/nat-fleet)
#
# What this module hands back to the caller after provisioning a pool of
# NAT nodes -- primarily the IPs client-agent, natctl, and other Terraform
# modules need to reach this fleet.
#
# -----------------------------------------------------
# Outputs:
#
# 1) pool_name         - Echoes the pool_name input, for convenience.
# 2) node_ids           - The deterministic node name list this fleet created.
# 3) node_private_ips    - VLAN IP per node; feed into client-agent's ECMP
#                          next-hop configuration.
# 4) node_public_ips     - Primary public IP plus any extra egress IPs per
#                          node. Safe to compute here (not inside main.tf's
#                          cloud-init rendering) since outputs are not fed
#                          back into the resources that produced them.
# 5) node_linode_ids     - Linode numeric IDs per node, useful for
#                          linode-cli / IP-Sharing calls (docs/RUNBOOK.md
#                          "Enable buddy IP failover for a pool").
# 6) placement_group_ids - M16 (roadmap/M16-anti-affinity-placement-groups.md):
#                          this pool's placement group IDs when
#                          placement_group_enabled is true; empty list
#                          otherwise.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

output "pool_name" {
  value = var.pool_name
}

output "node_ids" {
  value = local.node_ids
}

output "node_private_ips" {
  description = "Point client instances' ECMP next-hop set at these — see client-agent/."
  # v9 fix: was `local.node_private_ips`, which was never declared anywhere
  # in main.tf (a real bug, caught by a live `terraform plan` run) --
  # main.tf's locals block calls this `node_vlan_ips` (the VLAN-facing IP
  # client-agent's ECMP next-hop set actually needs -- see main.tf's own
  # "What this file creates" header comment, item 1).
  value = local.node_vlan_ips
}

output "node_vpc_ips" {
  description = "Each node's VPC (eth1) address -- what natctl itself listens on (:8099) and what natctl-api's firewall rule scopes to. Distinct from node_private_ips above (VLAN, for client-agent's ECMP nexthops) -- found needed live, 2026-09-02, while fixing a natctl_on_node_enabled deployment's Prometheus service-discovery gap (see terraform/environments/example/main.tf's natctl_http_sd_targets local / roadmap/M2-security.md's regression note, corrected for a second bug in roadmap/M28-full-production-readiness-pass.md's Phase 4 severe finding -- one target per enabled pool now, not one for the whole fleet)."
  value       = local.node_vpc_ips
}

output "node_public_ips" {
  description = "Primary public IP per node, plus any extra egress IPs. Safe to compute here (unlike inside main.tf's cloud-init rendering) since outputs aren't fed back into the resources that produced them — see the cycle note in main.tf."
  value = {
    for node_id in local.node_ids : node_id => concat(
      # v9: linode_instance's own `ip_address` attribute is deprecated by
      # the Terraform Linode provider (confirmed via the provider's own
      # deprecation warning on a live `terraform apply`) in favor of
      # `ipv4`, a list of this instance's public IPv4 addresses -- each
      # node here has exactly one public interface (see this module's
      # linode_instance.node), so tolist(...) is always a single-element
      # list, same value ip_address used to provide.
      tolist(linode_instance.node[node_id].ipv4),
      [for k, ip in linode_instance_ip.extra_egress : ip.address if ip.linode_id == linode_instance.node[node_id].id]
    )
  }
}

output "node_linode_ids" {
  value = { for k, v in linode_instance.node : k => v.id }
}

output "placement_group_ids" {
  description = "M16: this pool's Placement Group IDs (one per up-to-5-node contiguous block) when placement_group_enabled is true; an empty list when it's false. See linode_placement_group.nodes in main.tf."
  value       = linode_placement_group.nodes[*].id
}
