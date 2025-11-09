variable "linode_token" { 
  type = string
}

variable "region" {
  type    = string
  default = "in-maa"
}

variable "image" { 
  type = string  
  default = "linode/ubuntu24.04"
}

variable "type" { 
  type = string
  default = "g6-standard-2"
}

# VLAN attachment (must already exist in the same region)
variable "vlan_label" { 
  type = string
}

variable "nat_a_vlan_ip" {
  type = string
}

variable "nat_b_vlan_ip" {
  type = string
}

# SSH access
variable "ssh_authorized_keys" { 
  type = list(string) 
}

variable "root_pass" { 
  type = string  
  default = null
}

# Naming
variable "prefix" {
  type = string 
  default = "nat" 
}

variable "shared_ipv4" {
  description = "Additional public IPv4 allocated by Support (owned by customer's anchor). Example: 203.0.113.45"
  type        = string
  default     = ""
}

variable "anchor_linode_id" {
  description = "Optional: Linode ID of the customer's anchor node that owns shared_ipv4"
  type        = number
  default     = 0
}

variable "use_ip_share" {
  description = "If true, call Linode /share API to allow nat-a/b to use shared_ipv4"
  type        = bool
  default     = true
}

variable "vlan_vip" {
  description = "Floating VLAN IP (VIP) used as the default gateway for NAT traffic, e.g., 172.16.0.1/24"
  type        = string
}

variable "dcid" {
  description = "Linode DCID for lelastic (in-maa = 25)"
  type        = number
}
