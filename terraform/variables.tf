# -----------------------------------------------------------------------------
# MULTI-PAIR MODE VARIABLES
# -----------------------------------------------------------------------------
variable "nat_pairs" {
  description = <<-EOT
  Multi-pair mode configuration.
  If this list is non-empty, Terraform ignores single-pair variables.
  Each entry represents a high-availability NAT pair.
  EOT

  type = list(object({
    name                  = string
    vlan_vip              = string
    shared_ipv4           = optional(string, "")
    anchor_linode_id      = optional(number, 0)
    vlan_label            = string
    placement_group_label = optional(string, "")
    placement_group_type  = optional(string, "anti_affinity:local")
    vrrp_id               = number
    members = list(object({
      label    = string
      vlan_ip  = string
      state    = string
      priority = number
      type     = optional(string)
    }))
  }))

  default = []
}

# -----------------------------------------------------------------------------
# SINGLE-PAIR MODE VARIABLES
# (Used only when nat_pairs = [])
# -----------------------------------------------------------------------------
variable "vlan_label" {
  description = "VLAN label for the single-pair NAT."
  type        = string
  default     = ""
}

variable "nat_a_vlan_ip" {
  description = "VLAN IP for NAT-A instance in single-pair mode."
  type        = string
  default     = ""
}

variable "nat_b_vlan_ip" {
  description = "VLAN IP for NAT-B instance in single-pair mode."
  type        = string
  default     = ""
}

variable "vlan_vip" {
  description = "Floating VLAN VIP (used as default gateway in single-pair mode)."
  type        = string
  default     = ""
}

variable "shared_ipv4" {
  description = "Shared public IPv4 for single-pair mode (used if IP sharing is enabled)."
  type        = string
  default     = ""
}

variable "anchor_linode_id" {
  description = "Linode ID that owns the shared IP (set to 0 if not used)."
  type        = number
  default     = 0
}

# -----------------------------------------------------------------------------
# COMMON SETTINGS
# -----------------------------------------------------------------------------
variable "region" {
  description = "Region where all Linodes will be created."
  type        = string
}

variable "image" {
  description = "Base image to use for NAT instances."
  type        = string
  default     = "linode/ubuntu24.04"
}

variable "type" {
  description = "Linode instance type for NAT nodes."
  type        = string
  default     = "g6-standard-2"
}

variable "root_pass" {
  description = "Root password for the instances (required by Linode provider)."
  type        = string
  default     = "" # keep empty by default
  sensitive   = true
}

# If true, put keys into cloud-init instead of provider (default: false)
variable "inject_ssh_via_cloud_init" {
  type    = bool
  default = false
}

variable "placement_group_label" {
  description = "Optional label of existing placement group (single-pair mode only)."
  type        = string
  default     = ""
}

variable "placement_group_type" {
  description = "Placement group type (anti_affinity, affinity, etc.)."
  type        = string
  default     = "anti_affinity:local"
}

variable "use_ip_share" {
  description = "Enable Linode IP sharing API call."
  type        = bool
  default     = true
}

variable "ssh_authorized_keys" {
  description = "List of SSH public keys injected into each NAT node via cloud-init."
  type        = list(string)
  default     = []
}

variable "dcid" {
  description = "Linode datacenter ID for IP sharing (refer Linode docs)."
  type        = number
}

variable "linode_token" {
  description = "API token for Linode provider."
  type        = string
  sensitive   = true
}

variable "prefix" {
  description = "Prefix for naming NAT resources."
  type        = string
  default     = "nat"
}

variable "vrrp_id" {
  description = "VRRP Router ID for single-pair mode (1-255)."
  type        = number
  default     = 51
}

variable "sync_iface" {
  type        = string
  description = "Interface used for conntrackd state-sync (usually the dedicated sync link)"
  default     = "eth1"
}

variable "nat_default_type" {
  description = "Default Linode plan type for all NAT gateways (e.g. g6-standard-2, g6-standard-4, g7-standard-2)"
  type        = string
  default     = "g6-standard-2"
}
