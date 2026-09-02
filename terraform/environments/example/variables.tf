# variables.tf (terraform/environments/example)
#
# Every input this example environment accepts. Copy
# terraform.tfvars.example to terraform.tfvars and fill in at minimum
# linode_token, authorized_keys, and root_pass -- everything else has a
# working default.
#
# -----------------------------------------------------
# Key Parameters:
#
# 1) linode_token/region/authorized_keys/root_pass - Required; account and
#    access basics.
# 2) shared_pool_floor_nodes/shared_pool_max_nodes/nat_instance_type -
#    Sizing for the default pool.
# 3) enable_dedicated_pool_example - Toggle the second example pool on/off.
# 4) ip_failover_enabled/linode_bgp_dcid - Buddy IP failover (see
#    docs/ARCHITECTURE.md section 3.6, docs/RUNBOOK.md "Enable buddy IP
#    failover for a pool").
# 5) reserved_ip_enabled - Fixed/whitelist-safe public IPs for every node,
#    floor and elastic (account-gated by Linode, off by default).
# 6) shared_pool_reserved_ip_pool/dedicated_acme_pool_reserved_ip_pool -
#    Bring-your-own reserved IPs for floor nodes, by position (M17, off
#    by default -- see roadmap/M17-reserved-ip-pool-and-prereservation.md).
# 7) placement_group_enabled/placement_group_policy - Spread floor nodes
#    across separate physical hosts (M16, off by default; floor nodes
#    only -- see roadmap/M16-anti-affinity-placement-groups.md).
# 8) grafana_admin_password         - Change before any real deployment.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "linode_token" {
  description = "Linode Personal Access Token (scopes: linodes:read_write, vpc:read_write, networking:read_write)"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Linode region/data center, e.g. us-east"
  type        = string
  default     = "us-east"
}

variable "label" {
  description = "Prefix for every resource this environment creates whose name is otherwise fixed (currently module.vpc's three Cloud Firewalls: '<label>-nat-node-fw'/'<label>-control-plane-fw'/'<label>-client-fw'). Change this to run a second, clearly-distinguishable copy of this environment in the same account/region without any naming collision with an existing 'lng-example' deployment -- e.g. a live-testing/verification environment alongside a real one."
  type        = string
  default     = "lng-example"
}

# ---------------------------------------------------------------------------
# v11: Bring Your Own VPC. This automation no longer creates the Linode VPC
# or its subnet(s) -- see terraform/modules/vpc/main.tf's header comment
# for why, and docs/RUNBOOK.md "Bring your own VPC" for how to create one
# yourself (Cloud Manager, linode-cli, or a separate one-time Terraform
# config) before running `terraform apply` here. vpc_id/public_subnet_id
# are required, no defaults -- there's no environment-agnostic default
# that would make sense for an id specific to your account.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "Numeric id of your existing Linode VPC. Create this yourself first -- see docs/RUNBOOK.md \"Bring your own VPC\"."
  type        = number
}

variable "public_subnet_id" {
  description = "Numeric id of your existing VPC subnet that every NAT node's eth1 (VPC) interface and the observability instance attach to. Its CIDR is looked up automatically (see terraform/modules/vpc's data.linode_vpc_subnet.public) -- make sure it has enough headroom for every pool's private_ip_offset range (shared pool starts at .20, dedicated-acme at .50 in this example -- see main.tf's module.nat_fleet_* calls) before creating it."
  type        = number
}

variable "admin_cidrs" {
  description = "List of CIDRs allowed to reach SSH (every node) and Grafana/Prometheus/Alertmanager (the control-plane host) -- see roadmap/M2-security.md. No default, deliberately: previously hardcoded to 0.0.0.0/0 (open to the entire internet) with only a code comment telling an operator to fix it. Set this to your own admin/office/VPN egress CIDR(s), e.g. [\"203.0.113.4/32\"]."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Map of VPC private-subnet label => existing subnet id, for VPC-resident workloads that are NOT the VLAN-based NAT client fleet (e.g. an LKE Enterprise cluster sharing this VPC) -- see docs/ARCHITECTURE.md §3.0. Leave empty ({}) if you don't have any; this is optional, unlike vpc_id/public_subnet_id."
  type        = map(number)
  default     = {}
}

# ---------------------------------------------------------------------------
# v11: VLAN label/CIDR, promoted from hardcoded locals to real input
# variables so you can override them from terraform.tfvars without editing
# main.tf. Linode VLANs have no standalone Terraform resource (a VLAN is
# just a label -- see terraform/modules/nat-fleet's vlan_label/vlan_cidr
# variables) so, unlike the VPC above, there is nothing to "bring your
# own" here in the sense of a pre-existing object; you're simply choosing
# the label/address space instead of having it chosen for you. Defaults
# reproduce this environment's original values exactly, so leaving these
# unset changes nothing.
# ---------------------------------------------------------------------------

variable "vlan_label_shared" {
  description = "VLAN label the shared pool's nodes (and its private client fleet) join. See terraform/modules/nat-fleet's vlan_label."
  type        = string
  default     = "lng-vlan-shared"
}

variable "vlan_cidr_shared" {
  description = "VLAN address space for the shared pool -- covers both the pool's own static node IPs (vlan_ip_offset+) and its reserved static-IP window (vlan_reserved_ceiling_shared/vlan_usable_ceiling_shared). OK to overlap or nest with vlan_cidr_dedicated_acme in every case -- separate VLAN labels are fully isolated L2 domains on Linode regardless of numeric CIDR overlap (same as two unrelated VPCs both reusing 10.0.0.0/8). v13: vlan_label_shared and vlan_label_dedicated_acme are ALSO allowed to be the SAME value (\"same-VLAN mode\", e.g. one account-wide VLAN shared with VPN traffic) -- when they are, main.tf automatically excludes vlan_cidr_dedicated_acme's whole block from this pool's own computed reserved window (see locals.same_vlan_mode/vlan_usable_ceiling_shared and the \"same_vlan_dedicated_acme_reservation_valid\" check block, both in main.tf, and docs/RUNBOOK.md's \"Same-VLAN mode\" section), so the two pools' reserved windows never collide on that shared L2 segment. That mode does require vlan_cidr_dedicated_acme to be nested inside this CIDR and positioned after this pool's own floor+elastic node IPs -- enforced at plan time, not just documented."
  type        = string
  default     = "192.168.100.0/22" # covers private-app-1 + private-app-2 clients
}

variable "vlan_label_dedicated_acme" {
  description = "VLAN label the dedicated-acme example pool's nodes join. Only relevant if enable_dedicated_pool_example is true. See terraform/modules/nat-fleet's vlan_label. Can be DIFFERENT from vlan_label_shared (separate VLANs, the original/simplest setup) or the SAME value (\"same-VLAN mode\" -- see vlan_cidr_shared's description above and docs/RUNBOOK.md's \"Same-VLAN mode\" section); if you make it the same, vlan_cidr_dedicated_acme must be nested inside vlan_cidr_shared and positioned past the shared pool's own node offsets -- main.tf's \"same_vlan_dedicated_acme_reservation_valid\" check block validates this at plan time rather than leaving it to chance."
  type        = string
  default     = "lng-vlan-acme"
}

variable "vlan_cidr_dedicated_acme" {
  description = "VLAN address space for the dedicated-acme example pool -- see vlan_cidr_shared above for the same reasoning; overlapping/nesting inside vlan_cidr_shared's range is fine regardless of whether vlan_label_dedicated_acme matches vlan_label_shared or not. Only relevant if enable_dedicated_pool_example is true."
  type        = string
  default     = "192.168.105.0/24"
}

variable "authorized_keys" {
  description = "SSH public key(s) installed on every instance"
  type        = list(string)
}

variable "root_pass" {
  description = "Root password for provisioned instances (SSH key auth is still recommended as the primary access path)"
  type        = string
  sensitive   = true
}

variable "shared_pool_floor_nodes" {
  description = "Terraform-managed baseline node count for the shared pool. Defaults to 1 -- start minimal and raise it (or let natctl add elastic capacity above the floor) once real load justifies it, rather than assuming multi-node capacity is needed up front. At 1 node, conntrack buddy-sync and buddy IP failover (if enabled) simply stay dormant -- there's nothing to pair with -- and activate automatically the moment a second node joins; see docs/ARCHITECTURE.md §3.5's \"Already self-adjusts to node count\" note. See docs/ARCHITECTURE.md §4."
  type        = number
  default     = 1
}

variable "shared_pool_max_nodes" {
  description = "Ceiling natctl will never scale the shared pool past, floor + elastic combined."
  type        = number
  default     = 12
}

variable "enable_dedicated_pool_example" {
  description = "Whether to provision the example dedicated pool (for a tenant needing isolated capacity) alongside the shared pool."
  type        = bool
  default     = true
}

variable "nat_instance_type" {
  type    = string
  default = "g6-dedicated-4"
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme-lng-grafana"
}

variable "ip_failover_enabled" {
  description = "Enable BIDIRECTIONAL BGP-based IP Sharing (FRR, v5) between buddy pairs so a dead node's public IP fails over, not just its conntrack state — each node self-announces its own IP and backs up its buddy's simultaneously. Requires linode_bgp_dcid to be set for your region. See docs/ARCHITECTURE.md §3.5/§3.6/§3.6.1."
  type        = bool
  default     = false
}

variable "linode_bgp_dcid" {
  description = "Linode BGP data-center ID for IP Sharing's route-server neighbors. Look this up from Linode's current failover documentation (https://www.linode.com/docs/products/compute/compute-instances/guides/failover/) for your region — deliberately not hardcoded here since it's a Linode-side mapping that can change. Required if ip_failover_enabled is true."
  type        = number
  default     = null
}

variable "reserved_ip_enabled" {
  description = "Whether every NAT node's primary public IP (floor AND natctl-provisioned elastic nodes) is a Linode Reserved IP instead of the ephemeral one Linode auto-assigns — so a node's egress IP stays the same even across an instance replacement, which matters if any downstream service IP-whitelists this fleet's addresses. Off by default: Linode's Reserved IP feature is account-gated (\"IP reservation is not currently available to all users\") — confirm it's enabled for your account (Cloud Manager, or Linode support) before turning this on. See terraform/modules/nat-fleet/variables.tf's reserved_ip_enabled and docs/ARCHITECTURE.md for the full design, including what this does NOT cover (egress_ips_per_node's extra IPs stay ephemeral)."
  type        = bool
  default     = false
}

variable "shared_pool_reserved_ip_pool" {
  description = "roadmap/M17-reserved-ip-pool-and-prereservation.md: reserved IPv4 addresses you ALREADY OWN (reused from a prior deployment on this account, or reserved out-of-band ahead of time), for the shared pool's floor nodes to use instead of always minting a brand-new reservation. Assigned by position -- the first entry goes to this pool's first floor node by creation order, and so on; any floor node beyond the length of this list still gets a freshly-created reservation. Only meaningful when reserved_ip_enabled is true. Must not exceed shared_pool_floor_nodes in length -- see terraform/modules/nat-fleet's reserved_ip_pool_fits_node_count check block. Default [] (fully backward compatible)."
  type        = list(string)
  default     = []
}

variable "dedicated_acme_pool_reserved_ip_pool" {
  description = "Same as shared_pool_reserved_ip_pool above, but for the dedicated-acme-corp pool's floor nodes (only meaningful when enable_dedicated_pool_example is true). Kept as a separate variable, not shared with the shared pool's list, since the two pools' floor node counts/positions are entirely independent -- see terraform/modules/nat-fleet's reserved_ip_pool for the full design."
  type        = list(string)
  default     = []
}

variable "placement_group_enabled" {
  description = "roadmap/M16-anti-affinity-placement-groups.md: whether floor nodes (shared and, if enabled, dedicated-acme-corp pools) are spread across Linode Placement Groups (anti_affinity:local) so Akamai avoids co-locating them on the same physical host — closes the correlated-physical-host-failure gap docs/COMPARISON.md documents. Off by default — same opt-in pattern as reserved_ip_enabled. Floor nodes only; natctl-provisioned elastic nodes are NOT covered (deliberately out of scope, see the roadmap file). See terraform/modules/nat-fleet/variables.tf's placement_group_enabled and docs/ARCHITECTURE.md §3.6.2 for the full design, including the multi-group chunking behavior for pools over 5 nodes."
  type        = bool
  default     = false
}

variable "placement_group_policy" {
  description = "Linode's placement_group_policy for every placement group this environment creates when placement_group_enabled is true: \"strict\" (default — refuses to violate anti-affinity, fails the operation rather than co-locating) or \"flexible\" (best-effort). See terraform/modules/nat-fleet/variables.tf's placement_group_policy for the full trade-off."
  type        = string
  default     = "strict"
}

# ---------------------------------------------------------------------------
# v12: Reserved static-IP ranges are now COMPUTED (see main.tf's
# vlan_reserved_ceiling_shared/vlan_usable_ceiling_shared locals), not
# hand-typed -- you were previously required to pick an IP literal range
# that (a) falls inside the right VLAN CIDR and (b) stays clear of every
# node's static vlan_ip, entirely by hand, with no automated check.
# That's exactly the kind of arithmetic a machine should do: main.tf now
# derives both ranges directly from vlan_cidr_shared/vlan_cidr_dedicated_acme,
# each pool's own vlan_ip_offset/elastic_ip_offset_start/max_nodes, and the
# margin below -- see docs/RUNBOOK.md for the exact formula and an HONEST
# CAVEAT about its limits. vlan_elastic_headroom_margin is the only knob
# left; the rest of what used to be separate start/end inputs no longer
# exists as separate inputs.
# ---------------------------------------------------------------------------

variable "vlan_elastic_headroom_margin" {
  description = "Extra host-offset headroom (on top of elastic_ip_offset_start + max_nodes) reserved for floor+elastic static VLAN IPs before the pool's reserved static-IP window begins -- the SAME number is applied to both pools, so it's sized for the smallest configured VLAN CIDR, not the largest. See docs/RUNBOOK.md for why this can't be a mathematically perfect guarantee (natctl's elastic VLAN IP offset counter increments once per node EVER provisioned for a pool's whole lifetime, never reused when a node drains -- see controller/natctl/fleet.py's _next_elastic_offset) and is instead a practical buffer sized for realistic autoscaling churn. This environment's default is deliberately conservative because the dedicated-acme example pool's VLAN CIDR is only a /24 (vlan_cidr_dedicated_acme, 254 usable hosts) with elastic_ip_offset_start_dedicated_acme=150 and a 6-node ceiling already consuming addresses up to offset 176 -- a bigger margin here makes Terraform's cidrhost() call fail outright with \"prefix of 24 does not accommodate a host numbered N\" (a hard error, not a silent collision, which is the whole point of computing this instead of hand-typing it). If every pool in your environment uses a roomier CIDR (e.g. a /22 like vlan_cidr_shared's default), or you don't enable the dedicated-acme example pool at all, you can safely raise this for more autoscaling headroom."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# v6: natctl-on-node (opt-in) — removes the requirement for a dedicated
# control-plane host by running natctl itself, leader-elected with STONITH
# fencing, on every NAT node instead. See controller/natctl/leader_election.py,
# docs/ARCHITECTURE.md's leader-election section, and docs/RUNBOOK.md's
# natctl-on-node section. Leave natctl_on_node_enabled at its default
# (false) to keep this environment's original single-dedicated-host layout
# (module.observability runs natctl) unchanged.
# ---------------------------------------------------------------------------

variable "natctl_on_node_enabled" {
  description = "Run natctl on every NAT node (both example pools, floor AND elastic) instead of on a single dedicated module.observability host. When true, this file also flips module.observability's run_natctl off (running natctl in two places at once would be redundant and the observability host isn't given its own leader-election identity) and turns on leader_election in the composed natctl.yaml, with ANY node in the fleet eligible to hold leadership."
  type        = bool
  default     = false
}

variable "natctl_object_storage_endpoint" {
  description = "S3-compatible endpoint URL for a Linode Object Storage bucket (e.g. \"https://us-east-1.linodeobjects.com\") -- REQUIRED unconditionally as of v9, not just when natctl_on_node_enabled: terraform/modules/artifacts uploads exporter.py/buddy_sync.py/the natctl package here and every NAT node fetches them at boot, since embedding their content directly in cloud-init exceeds Linode's 16384-byte decoded user_data limit (confirmed against a real terraform apply, not assumed -- see that module's main.tf header for the full numbers). Also still backs the leader-election lease when natctl_on_node_enabled (controller/natctl/leader_election.py's ObjectStorageLeaseStore) -- same bucket, dual purpose."
  type        = string
}

variable "natctl_object_storage_bucket" {
  description = "Object Storage bucket name -- see natctl_object_storage_endpoint above for why this is required unconditionally now (artifact hosting), not just for the leader-election lease."
  type        = string
}

variable "natctl_object_storage_access_key" {
  description = "Object Storage access key -- used both to upload artifacts at apply time (terraform/modules/artifacts) and, when natctl_on_node_enabled, written to each node's /etc/natctl/env for the leader-election lease (kept out of natctl_config_yaml itself -- see config.py's LeaderElectionConfig docstring for why). Required unconditionally now -- see natctl_object_storage_endpoint above."
  type        = string
  sensitive   = true
}

variable "natctl_object_storage_secret_key" {
  description = "Object Storage secret key -- see natctl_object_storage_access_key above. Required unconditionally now."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# v6: monitoring-stack opt-out — reuse an existing Prometheus/Grafana (or
# push into one via remote_write) instead of standing up a second one. See
# terraform/modules/observability's run_monitoring_stack/
# prometheus_remote_write_url and docs/OBSERVABILITY.md "Bring your own
# monitoring".
# ---------------------------------------------------------------------------

variable "run_monitoring_stack" {
  description = "Whether this environment provisions its own Prometheus/Grafana/Alertmanager at all. Default true (unchanged behavior). Set to false if you already have monitoring — point your own Prometheus at every NAT node's :9200/metrics (via natctl's GET /file_sd for target discovery) instead, or set customer_prometheus_remote_write_url below to have a still-provisioned local Prometheus forward samples into your existing backend."
  type        = bool
  default     = true
}

variable "customer_prometheus_remote_write_url" {
  description = "If set (and run_monitoring_stack is true), the local Prometheus this environment provisions also pushes every scraped sample here via remote_write — e.g. your Grafana Cloud / Mimir / Thanos Receive / VictoriaMetrics endpoint. Leave empty for the original local-only behavior."
  type        = string
  default     = ""
}

variable "customer_prometheus_remote_write_username" {
  description = "Basic-auth username for customer_prometheus_remote_write_url, if your receiver requires it."
  type        = string
  default     = ""
}

variable "customer_prometheus_remote_write_password" {
  description = "Basic-auth password for customer_prometheus_remote_write_url, if your receiver requires it."
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# roadmap/M20-remove-terraform-client-creation.md (2026-09-02): the v14
# client_groups variable and module.client_fleet that used to live here
# are removed. This environment no longer creates client instances --
# see docs/RUNBOOK.md's "Onboard a client instance" section for the
# replacement (scripts/install-nat-client.sh, run against an instance
# the customer's own automation already created).
# ---------------------------------------------------------------------------
# client_static_vlan_slot_size (per-slot address width) is removed
# alongside client_groups -- it only ever existed to size a Terraform-
# computed slot, which no longer exists. client_static_vlan_reserved
# stays: it's still meaningful as "how much VLAN address space to leave
# alone for manually-assigned client instances", independent of whether
# Terraform ever subdivided that window into named slots.
variable "client_static_vlan_reserved" {
  description = "Number of VLAN addresses, per pool, reserved for manually-assigned client instances -- see docs/RUNBOOK.md's \"Onboard a client instance\" section. natctl's elastic-node allocator (fleet.py's _provision()) never hands out an address at or past this reservation's ceiling (main.tf's vlan_reserved_ceiling_shared/vlan_reserved_ceiling_dedicated_acme), so an operator can safely hand-assign an address anywhere in this window without racing natctl for it. Backward compatible: 0 (the default) reserves nothing, identical to the address layout before this variable existed."
  type        = number
  default     = 0
}
