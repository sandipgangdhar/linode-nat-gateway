# variables.tf (terraform/modules/client-fleet)
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "group_name" {
  description = "Short, unique-within-this-environment name for this group of client instances (e.g. \"web-tier\"). Used to build instance labels (lng-client-<group_name>-N) and the lng-client-group-<group_name> tag -- does not need to match anything else, it's purely this group's own identifier."
  type        = string
}

variable "client_count" {
  description = "Number of client instances to create in this group."
  type        = number
  default     = 1
}

variable "pool_name" {
  description = "Which NAT pool this group's instances belong to (\"shared\" or a dedicated pool's pool_name, e.g. \"dedicated-acme-corp\") -- used to build the roster URL path (natctl_roster_base_url + \"/fleet/\" + pool_name) and purely for logging/tagging context. Must match the vlan_label/natctl_roster_base_url values actually passed in below -- this module has no way to cross-check that itself."
  type        = string
}

variable "vlan_label" {
  description = "VLAN label this group's instances join -- MUST match the target pool's own vlan_label (e.g. var.vlan_label_shared from the environment root module) so this group actually lands on the right pool's VLAN."
  type        = string
}

# v17: every client instance needs a static VLAN address -- Linode VLANs
# carry no address-assignment mechanism of their own. See
# static_vlan_ip_offset below for the full picture.
variable "vlan_cidr" {
  description = "The target pool's own VLAN CIDR, used to compute this group's static VLAN addresses (see static_vlan_ip_offset below). Must match the same pool's own vlan_cidr (e.g. var.vlan_cidr_shared from the environment root module) exactly -- same cross-check discipline as vlan_label above."
  type        = string
}

variable "static_vlan_ip_offset" {
  description = <<-EOT
    Static VLAN addressing for this client group. Every instance in this
    group gets a Terraform-assigned, permanent VLAN IP --
    cidrhost(vlan_cidr, static_vlan_ip_offset + i) for i in
    0..client_count-1 -- set once at boot as that interface's
    ipam_address and never renewed or renegotiated, exactly like every
    NAT floor/elastic node's own static addressing (see
    terraform/modules/nat-fleet's vlan_ip_offset and
    controller/natctl/fleet.py's elastic_ip_offset_start). See
    docs/RUNBOOK.md's "Static VLAN IPs for client groups" section for
    the full mechanics.

    v17.2: this module's own interface is still a plain number -- picking
    the actual value, and making sure two groups never collide, is NOT
    this module's job or the caller's manual responsibility either (this
    module has no visibility into the target pool's own floor/elastic
    node ranges, or any OTHER client group's offset, so it never could
    have validated non-collision itself). terraform/environments/example/
    main.tf's client_groups variable exposes a small static_vlan_slot
    INTEGER instead (0, 1, 2, ...) -- that root module computes this
    argument automatically (local.static_client_offsets =
    pool_static_reserved_start + slot * client_static_vlan_slot_size), so
    a group's address depends only on its own slot number and one
    pool-wide constant, never on any other group's config or existence --
    deleting or resizing one static group can never move another's
    address. Its own check blocks catch a slot collision, a client_count
    that overflows its own slot, and running out of room in the reserved
    window, all at `terraform plan` time. If you're calling this module
    directly, outside client_groups from the example environment, you are
    responsible for computing a non-colliding value to pass in here
    yourself -- the equivalent of what that root module already does for
    you.
    EOT
  type        = number
}

# v15: replaces the old assign_public_ip boolean -- see main.tf's v15
# header note for why Linode's newer "Linode Interfaces" model was
# deliberately NOT used for any of these, even "vlan_only" (verified
# against the Terraform Linode provider's own docs that legacy
# Configuration Profile Interfaces already support every mode below).
variable "interface_mode" {
  description = <<-EOT
    Which legacy interface layout this group's instances get. VLAN is
    always attached (that's what makes this a client of the NAT fleet) --
    this variable controls what else joins it:

    - "vlan_only": VLAN only, no public IP, no VPC membership. Not
      reachable from the public internet at all (LISH or same-VLAN only).
      client-agent IS installed (nothing else provides internet egress).
      v20: the roster fetch this needs now works too, in principle --
      pass natctl_roster_vlan_url (below) so it's reachable over the
      VLAN instead of the VPC-only natctl_roster_base_url. HOWEVER
      (confirmed live, 2026-08-03): this mode does not currently work
      end to end regardless, for a completely separate reason -- Linode's
      Metadata Service does not deliver user-data to an instance with
      ONLY a VLAN interface at all. cloud-init reaches "status: done"
      with 0 bytes of user-data, so it never gets to write_files/runcmd
      -- client-agent is never installed, the VLAN interface's own
      static-address config is never written, nothing in this module's
      cloud-init template runs. The natctl_roster_vlan_url fix above is real,
      correct, and still needed for if/when that platform-level gap is
      ever closed (or a non-user-data bootstrap path is built), but
      until then "vlan_only" is not a usable choice here -- use
      "vpc_vlan" instead (confirmed working end to end: a VPC interface
      DOES receive user-data correctly, and gets you the same "no
      internet path of its own, client-agent takes the default route"
      behavior).
    - "public_vlan": a real public interface (eth0) + VLAN. client-agent
      is NOT installed -- this instance already has its own path to the
      internet.
    - "vpc_vlan": a VPC interface (no 1:1 NAT, so no public reachability
      -- VPC alone can't transit-route to a non-VPC destination, see
      docs/ARCHITECTURE.md §3.0) + VLAN. client-agent IS installed, same
      reasoning as "vlan_only" -- VPC membership alone doesn't provide
      internet egress.
    - "public_vpc_vlan": a VPC interface WITH 1:1 NAT (ipv4.nat_1_1 =
      "any") for public reachability, + VLAN -- Linode's own recommended
      way to get both VPC membership and internet access on ONE
      interface instead of two ("Having both a VPC interface and a
      public interface is not recommended"). client-agent is NOT
      installed, same reasoning as "public_vlan".

    Requires public_subnet_id/vpc_id to be set (see below) for
    "vpc_vlan"/"public_vpc_vlan" -- harmless to leave them unset
    otherwise.
    EOT
  type        = string
  default     = "public_vlan"
  validation {
    condition     = contains(["vlan_only", "public_vlan", "vpc_vlan", "public_vpc_vlan"], var.interface_mode)
    error_message = "interface_mode must be one of: vlan_only, public_vlan, vpc_vlan, public_vpc_vlan."
  }
}

variable "vpc_id" {
  description = "This environment's VPC id -- only actually used (via public_subnet_id below) when interface_mode is \"vpc_vlan\" or \"public_vpc_vlan\". Pass module.vpc.vpc_id. Harmless to leave at its default otherwise."
  type        = number
  default     = 0
}

variable "public_subnet_id" {
  description = "The VPC subnet this group's VPC interface joins -- only actually used when interface_mode is \"vpc_vlan\" or \"public_vpc_vlan\". Pass module.vpc.public_subnet_id (the same public/NAT-node subnet, unless you have a reason to use a different one -- e.g. one of private_subnet_ids). Harmless to leave at its default otherwise."
  type        = number
  default     = 0
}

variable "region" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "g6-standard-1"
}

variable "image" {
  type    = string
  default = "linode/ubuntu22.04"
}

variable "authorized_keys" {
  type = list(string)
}

variable "root_pass" {
  type      = string
  sensitive = true
}

variable "firewall_id" {
  description = "Cloud Firewall to attach -- pass module.vpc's client_firewall_id (SSH only; client-agent needs no inbound port)."
  type        = number
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "natctl_roster_base_url" {
  description = "natctl's roster base URL (e.g. http://10.60.32.20:8099, WITHOUT the /fleet/<pool> suffix -- that's appended using pool_name above, same pattern terraform/modules/nat-fleet's own natctl_roster_url variable follows). Only actually read by the rendered cloud-init when this group needs client-agent (interface_mode \"vlan_only\"/\"vpc_vlan\") -- harmless to pass even otherwise. VPC-addressed -- see natctl_roster_vlan_url below for why a true vlan_only group needs a different value."
  type        = string
}

# v20 (found live, 2026-08-02/03): a real vlan_only client (no VPC
# interface at all) could install client-agent fine but could never reach
# natctl_roster_base_url above -- that address is always VPC-addressed by
# every environment that sets it (see terraform/environments/example/
# main.tf's natctl_roster_base_url local), and vlan_only has no VPC
# interface to route it through. This was flagged as an open gap while
# fixing the roster-timeout bugs for a "vpc_vlan" instance in this same
# debugging session, then actually built once the user asked for real
# vlan_only support.
#
# STILL NOT ENOUGH ON ITS OWN (confirmed live, 2026-08-03): "vlan_only"
# doesn't work at all today, for a completely separate, platform-level
# reason -- see interface_mode's own description above for the full
# story (Metadata Service never delivers user-data to a VLAN-only
# instance, so client-agent never even installs). This variable and the
# nftables/render_nftables VLAN rule it depends on are still correct and
# worth keeping -- they're exactly what a real vlan_only client would
# need once/if that separate gap is ever closed -- but don't expect
# "vlan_only" to actually work in this project today just because this
# is set. Use "vpc_vlan" for internet-less clients in the meantime.
#
# Fix: natctl's roster is reachable over the VLAN too now (both
# ansible/templates/nftables.conf.tftpl and controller/natctl/
# cloud_init.py's render_nftables() open 8099 on the VLAN interface when
# natctl_on_node_enabled, in addition to the existing VPC-only rule) --
# but unlike natctl_roster_base_url, there's no single VLAN address that
# works for every pool: VLANs are pool-scoped, non-routable to each other
# (Linode VLAN is pure L2, not a VPC), so a pool's vlan_only clients can
# only ever reach a node that's on THEIR OWN pool's VLAN. Pass that pool's
# own roster-over-VLAN address here (e.g.
# terraform/environments/example/main.tf's natctl_roster_vlan_urls map,
# keyed by pool_name) -- main.tf's natctl_roster_url_effective local below
# picks this over natctl_roster_base_url only when interface_mode is
# exactly "vlan_only" and this is non-empty. Leave at the default (empty)
# for every other interface_mode, or if you're not using true vlan_only
# clients -- vpc_vlan (the workaround used earlier in this same debugging
# session) keeps working exactly as before either way.
variable "natctl_roster_vlan_url" {
  description = "This group's pool's own roster URL reached over the VLAN (e.g. http://10.128.0.20:8099, same WITHOUT-/fleet/<pool>-suffix convention as natctl_roster_base_url) -- used INSTEAD OF natctl_roster_base_url only when interface_mode is \"vlan_only\", since that mode has no VPC interface to reach the VPC-addressed URL through. Empty by default: falls back to natctl_roster_base_url (which will simply never connect for a true vlan_only group until this is set). Harmless to pass for any other interface_mode -- it's only ever read for \"vlan_only\"."
  type        = string
  default     = ""
}

# BUG FIX (found live, 2026-08-02): v14 originally fetched client-agent
# from Object Storage at boot (client_agent_py_url etc.,
# module.artifacts's outputs), the same fetch-at-boot pattern
# nat-fleet/observability use for the much larger natctl package. That
# pattern is fundamentally broken for THIS module specifically: the whole
# point of "vlan_only"/"vpc_vlan" interface_mode is that the instance has
# NO internet path of its own until client-agent establishes one via the
# NAT fleet -- so the boot-time curl fetch OF client-agent itself always
# failed ("Could not resolve host"), confirmed live on a real deployed
# instance, leaving client-agent entirely uninstalled ("Unit file ... does
# not exist"). "public_vlan"/"public_vpc_vlan" instances have real internet
# access and never hit this (and don't install client-agent at all), but
# this module can't tell at the variable-declaration level which mode a
# given call will use, so the fix applies unconditionally: client-agent is
# now EMBEDDED directly in this module's own cloud-init user-data instead
# of fetched -- no network access needed to install it, for any mode. See
# main.tf's combined_agent_bundle_raw/combined_agent_bundle_gz_b64 locals
# and lng-agents-bundle-extract.py (this module's own file) for the
# mechanics. These variables are gone -- nothing to pass in anymore.
