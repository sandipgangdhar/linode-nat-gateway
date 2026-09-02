# outputs.tf (terraform/modules/vpc)
#
# Exposes the IDs/CIDRs that downstream modules (nat-fleet, observability)
# and the environment root module need to attach instances to this VPC and
# to reference its firewalls. v11: vpc_id/public_subnet_id/private_subnet_ids
# are now pure passthroughs of the BYO input variables (this module creates
# no VPC/subnet resources) -- public_subnet_cidr/private_subnet_cidrs come
# from this module's own data-source lookups instead of a resource
# attribute, so downstream modules don't need to know or care that the
# subnet already existed rather than being created here.
#
# -----------------------------------------------------
# Outputs:
#
# 1) vpc_id                    - Pass to nat-fleet/observability's vpc_id
#                                 variable so their instances join this VPC.
# 2) public_subnet_id          - Pass to nat-fleet's public_subnet_id so
#                                 every NAT node's eth1 attaches here.
# 3) public_subnet_cidr        - Used by nftables templates to scope rules
#                                 to "anything in this VPC", and
#                                 by nat-fleet/observability's cidrhost()
#                                 static-addressing math.
# 4) private_subnet_ids        - Map of private subnet label to ID, for
#                                 workloads that need to attach to a named
#                                 private subnet directly. Passthrough of
#                                 the input variable.
# 5) private_subnet_cidrs      - Map of private subnet label to its real
#                                 CIDR, looked up via data source (not
#                                 retyped by you).
# 6) firewall_id               - Attach to every NAT node instance.
# 7) control_plane_firewall_id - Attach to the observability/natctl host.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

output "vpc_id" {
  value = var.vpc_id
}

output "public_subnet_id" {
  value = var.public_subnet_id
}

output "public_subnet_cidr" {
  value = data.linode_vpc_subnet.public.ipv4
}

output "private_subnet_ids" {
  value = var.private_subnet_ids
}

output "private_subnet_cidrs" {
  value = { for k, s in data.linode_vpc_subnet.private : k => s.ipv4 }
}

output "firewall_id" {
  value = linode_firewall.nat_node.id
}

output "control_plane_firewall_id" {
  value = linode_firewall.control_plane.id
}

output "client_firewall_id" {
  description = "Attach to any client instance -- SSH only. As of M20 (2026-09-02) this project doesn't create client instances itself; a customer attaches this firewall to whatever they create via their own automation."
  value       = linode_firewall.client.id
}
