# variables.tf (terraform/modules/vpc)
#
# Input variables for the VPC module: v11 -- an existing VPC/subnet(s) you
# bring yourself (vpc_id/public_subnet_id/private_subnet_ids), plus naming
# for the three Cloud Firewalls in main.tf (v14: nat_node/control_plane,
# plus client -- all three are otherwise fixed-port/SSH-only).
#
# -----------------------------------------------------
# Key Parameters:
#
# 1) label                - Name prefix for the three firewalls this module
#                            still creates.
# 2) vpc_id                - Your existing VPC's numeric id.
# 3) public_subnet_id      - Your existing VPC's subnet id that every NAT
#                             node's eth1 (VPC) interface attaches to. This
#                             module looks up its real CIDR for you (see
#                             main.tf's data.linode_vpc_subnet.public) --
#                             you don't need to also type the CIDR.
# 4) private_subnet_ids    - Map of label => existing VPC subnet id, for
#                             VPC-resident workloads that are NOT the
#                             VLAN-based NAT client fleet (see
#                             docs/ARCHITECTURE.md section 3.0). Leave
#                             empty ({}) if you don't have any.
#
# -----------------------------------------------------
# Usage:
#
# - Create the VPC and its subnet(s) yourself first (Cloud Manager,
#   linode-cli, or a separate one-time Terraform config) -- see
#   docs/RUNBOOK.md "Bring your own VPC". This module does not create or
#   destroy any VPC/subnet -- vpc_id/public_subnet_id/private_subnet_ids
#   are pure lookups.
# - Override label/private_subnet_ids per environment in your own
#   terraform.tfvars (see terraform/environments/example/terraform.tfvars.example).
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "label" {
  description = "Name prefix for the three Cloud Firewalls this module creates (this module no longer creates the VPC itself -- see vpc_id below)."
  type        = string
}

variable "vpc_id" {
  description = "Numeric id of your existing Linode VPC. This module does not create a VPC -- see docs/RUNBOOK.md \"Bring your own VPC\" for how to create one first (Cloud Manager, linode-cli, or your own separate Terraform)."
  type        = number
}

variable "public_subnet_id" {
  description = "Numeric id of your existing VPC subnet that every NAT node's eth1 (VPC) interface and the observability instance attach to. This module looks up its real CIDR via a data source (main.tf's data.linode_vpc_subnet.public) -- you do not need to separately supply the CIDR. Make sure its CIDR has enough headroom for every pool's private_ip_offset range (see terraform/modules/nat-fleet's private_ip_offset) before creating it."
  type        = number
}

variable "private_subnet_ids" {
  description = "Map of VPC private-subnet label => existing VPC subnet id. In v4 these are NOT where the NAT client fleet lives (that's VLAN now, see terraform/modules/nat-fleet's vlan_label/vlan_cidr and terraform/environments/example/variables.tf's vlan_* variables) — VPC cannot transit-route to non-VPC destinations, see docs/ARCHITECTURE.md §3.0. These VPC subnets remain for genuinely VPC-resident workloads that need to be VPC members for other reasons (e.g. an LKE Enterprise cluster deployed inside this VPC). Leave empty ({}) if you don't have any. This module does not create these subnets -- see vpc_id above."
  type        = map(number)
  default     = {}
}

# roadmap/M2-security.md: SSH (every firewall) and Grafana/Prometheus/
# Alertmanager (control_plane only) used to be hardcoded to 0.0.0.0/0 --
# open to the entire internet, with only a code comment ("tighten to your
# admin CIDR in production") telling an operator to fix it themselves.
# Deliberately no 0.0.0.0/0 default here -- an operator must make an
# explicit choice, the same discipline vpc_id/public_subnet_id above
# already use for anything that shouldn't have a plausible-looking but
# wrong default.
variable "admin_cidrs" {
  description = "List of CIDRs allowed to reach SSH (every firewall this module creates: nat_node, control_plane, client) and, on control_plane specifically, Grafana/Prometheus/Alertmanager (3000/9090/9093). No default -- you must set this explicitly (e.g. your own office/VPN egress IP as a /32, or a broader range if you know what you're doing) rather than silently defaulting to the entire internet. See docs/RUNBOOK.md for guidance on picking this."
  type        = list(string)
}
