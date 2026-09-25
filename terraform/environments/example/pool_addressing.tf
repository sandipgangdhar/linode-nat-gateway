# pool_addressing.tf (terraform/environments/example)
#
# Calculates every pool's address settings so an operator never has to.
#
# What it provides:
#   local.pools            - var.pools with every address setting resolved to a
#                            concrete value (the operator's own value when one
#                            is given, the calculated one when it is not).
#                            main.tf reads local.pools, never var.pools.
#   output pool_address_plan - The resolved layout, printed on every plan/apply:
#                            each pool's VPC and VLAN ranges, and for every VLAN
#                            the address from which client instances may be
#                            numbered.
#   output preconditions   - Hard errors (they stop `terraform plan`) for every
#                            address collision and every pool that does not fit
#                            its calculated space.
#
# How addresses are calculated (docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html, Part IX,
# "Planning pool addresses"):
#
#   Every pool has a SLOT -- its position in the sorted list of pool names,
#   unless the pool sets `slot` explicitly. The slot decides where the pool
#   lives; nothing else about the pool (its node counts, its instance type)
#   moves it, so resizing a pool never renumbers another pool.
#
#   VPC side (one subnet shared by every pool). Each slot owns a fixed block of
#   pool_vpc_block_size host offsets starting at
#   pool_vpc_base_offset + slot * pool_vpc_block_size:
#       first half          floor nodes           (private_ip_offset)
#       second half         elastic nodes         (vpc_elastic_ip_offset_start)
#       last offset         the witness, if any   (witness_private_ip_offset)
#
#   VLAN side (a private network per pool, or one shared by several pools).
#   Each pool gets a reserved block of pool_vlan_reserved_prefix bits carved
#   from the START of its vlan_cidr, in slot order among the pools that share
#   that VLAN (vlan_cidr_reserved). Inside the block:
#       offsets 1..7        infrastructure (the observability host sits at 7)
#       from offset 8       floor nodes           (vlan_ip_offset)
#       second half         elastic nodes         (elastic_ip_offset_start)
#   One more block per VLAN is held back for a dedicated fleet added later
#   (pool_vlan_spare_blocks). Everything after it belongs to the customer's own
#   client instances; pool_address_plan prints the first and last client address,
#   the block held for the next fleet, and the prefix to configure clients with.
#   Nothing is held back on the VPC side: Linode offers no way to reserve VPC
#   addresses, and assigns every other instance's VPC address itself.
#
# Any of the settings above can still be set per pool as an advanced override.
# A pool that overrides anything is checked exactly like a calculated one.
#
# -----------------------------------------------------
# Usage:
#
# No action needed -- leave the address settings out of terraform.tfvars.
# Read the pool_address_plan output after `terraform plan`.
#
# -----------------------------------------------------
# Best Practices:
# - Name pools so that a NEW pool sorts after every existing one, or give it an
#   explicit `slot`: adding a pool whose name sorts before an existing one moves
#   the later pools, and the plan then shows their nodes being replaced.
# - Keep pool_vpc_base_offset, pool_vpc_block_size and pool_vlan_reserved_prefix
#   at their defaults; changing any of them moves every pool.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "pool_vpc_base_offset" {
  description = "Host offset, within public_subnet_id's CIDR, where the calculated pool blocks begin. Everything below it is left for the observability host (observability_private_ip_offset) and anything else you place in that subnet. Changing it moves every pool that uses calculated addresses."
  type        = number
  default     = 32
  validation {
    condition     = var.pool_vpc_base_offset >= 2 && floor(var.pool_vpc_base_offset) == var.pool_vpc_base_offset
    error_message = "pool_vpc_base_offset must be a whole number >= 2."
  }
}

variable "pool_vpc_block_size" {
  description = "How many host offsets in the shared VPC subnet each pool slot owns. Half holds the pool's floor nodes, the other half its elastic nodes plus one witness address, so with the default of 64 a pool can have up to 32 floor nodes and up to 31 elastic nodes. Raise it (in steps of 2) only if a pool needs more; doing so moves every pool that uses calculated addresses."
  type        = number
  default     = 64
  validation {
    condition     = var.pool_vpc_block_size >= 8 && var.pool_vpc_block_size % 2 == 0
    error_message = "pool_vpc_block_size must be an even number >= 8."
  }
}

variable "pool_vlan_spare_blocks" {
  description = "How many extra pool-sized blocks to keep free at the end of each VLAN's reserved area, for dedicated fleets you add to that VLAN later. Each spare block is exactly as large as a pool's own block, so it can hold a fleet as large as the biggest this calculation supports (up to 56 floor and 63 elastic nodes) -- even when only two fleets exist today, one more is kept in reserve. pool_address_plan lists them as reserved for future fleets and starts the client range after them, so client instances numbered from that address never collide with a fleet added tomorrow. This matters on the VLAN because nothing assigns VLAN addresses automatically: your own automation numbers the clients. A spare block is only held while at least one address is left over for clients; a VLAN too small for that says so in the plan. Set 0 to give clients everything after the current pools."
  type        = number
  default     = 1
  validation {
    condition     = var.pool_vlan_spare_blocks >= 0 && var.pool_vlan_spare_blocks <= 16 && floor(var.pool_vlan_spare_blocks) == var.pool_vlan_spare_blocks
    error_message = "pool_vlan_spare_blocks must be a whole number between 0 and 16."
  }
}

variable "pool_vlan_reserved_prefix" {
  description = "Prefix length of the block reserved for each pool's own nodes inside its vlan_cidr. A /25 (the default) holds 128 addresses: floor nodes from offset 8 (up to 56 of them) and up to 63 elastic nodes in the second half. Use /26 or /27 to reserve less when many pools share one VLAN, or /24 for very large pools. Changing it moves every pool that uses calculated addresses, and it must be at least as long as every pool's vlan_cidr prefix."
  type        = number
  default     = 25
  validation {
    condition     = var.pool_vlan_reserved_prefix >= 16 && var.pool_vlan_reserved_prefix <= 28
    error_message = "pool_vlan_reserved_prefix must be between 16 and 28."
  }
}

locals {
  # ----- slots ---------------------------------------------------------------
  # A pinned slot wins; otherwise the pool's position in the sorted pool names.
  pool_slot = {
    for k, p in var.pools : k => p.slot != null ? p.slot : local.pool_rank[k]
  }

  # A pool's position among the pools that share its VLAN, ordered by slot.
  # Pools on their own VLAN are always index 0.
  pool_vlan_block_index = {
    for k, p in var.pools : k => length([
      for k2, p2 in var.pools : k2
      if p2.vlan_label == p.vlan_label && local.pool_slot[k2] < local.pool_slot[k]
    ])
  }

  # ----- VPC side ------------------------------------------------------------
  auto_vpc_half = var.pool_vpc_block_size / 2

  auto_vpc_floor_offset   = { for k, p in var.pools : k => var.pool_vpc_base_offset + local.pool_slot[k] * var.pool_vpc_block_size }
  auto_vpc_elastic_offset = { for k, p in var.pools : k => local.auto_vpc_floor_offset[k] + local.auto_vpc_half }
  auto_vpc_witness_offset = { for k, p in var.pools : k => local.auto_vpc_floor_offset[k] + var.pool_vpc_block_size - 1 }

  # ----- VLAN side -----------------------------------------------------------
  auto_vlan_block_size     = pow(2, 32 - var.pool_vlan_reserved_prefix)
  auto_vlan_floor_offset   = 8
  auto_vlan_elastic_offset = local.auto_vlan_block_size / 2

  # The canonical network address for each vlan_cidr, so a non-canonical base
  # such as 192.168.101.0/22 (really the 192.168.100.0/22 block) is carved up
  # from the block's real start.
  pool_vlan_prefix_len = { for k, p in var.pools : k => tonumber(split("/", p.vlan_cidr)[1]) }
  pool_vlan_canonical  = { for k, p in var.pools : k => "${cidrhost(p.vlan_cidr, 0)}/${split("/", p.vlan_cidr)[1]}" }

  # How many reserved blocks fit inside each pool's vlan_cidr. Negative shift
  # (reserved prefix shorter than the VLAN's own) leaves 0 -- reported below.
  pool_vlan_block_capacity = {
    for k, p in var.pools : k => (
      var.pool_vlan_reserved_prefix >= local.pool_vlan_prefix_len[k]
      ? pow(2, var.pool_vlan_reserved_prefix - local.pool_vlan_prefix_len[k])
      : 0
    )
  }

  # try() keeps a pool that does not fit from failing HERE with an opaque
  # cidrsubnet() error; the precondition on pool_address_plan reports it by name.
  auto_vlan_reserved_cidr = {
    for k, p in var.pools : k => try(
      cidrsubnet(local.pool_vlan_canonical[k], var.pool_vlan_reserved_prefix - local.pool_vlan_prefix_len[k], local.pool_vlan_block_index[k]),
      local.pool_vlan_canonical[k]
    )
  }

  # ----- the resolved pools --------------------------------------------------
  # Legacy override rule: a pool that sets elastic_ip_offset_start itself keeps
  # the original behaviour -- that one number is used on both the VPC and the
  # VLAN side -- unless it also sets vpc_elastic_ip_offset_start.
  pools = {
    for k, p in var.pools : k => merge(p, {
      slot               = local.pool_slot[k]
      private_ip_offset  = p.private_ip_offset != null ? p.private_ip_offset : local.auto_vpc_floor_offset[k]
      vlan_cidr_reserved = p.vlan_cidr_reserved != null ? p.vlan_cidr_reserved : local.auto_vlan_reserved_cidr[k]
      vlan_ip_offset     = p.vlan_ip_offset != null ? p.vlan_ip_offset : local.auto_vlan_floor_offset

      elastic_ip_offset_start = p.elastic_ip_offset_start != null ? p.elastic_ip_offset_start : local.auto_vlan_elastic_offset
      vpc_elastic_ip_offset_start = (
        p.vpc_elastic_ip_offset_start != null ? p.vpc_elastic_ip_offset_start
        : p.elastic_ip_offset_start != null ? null
        : local.auto_vpc_elastic_offset[k]
      )

      # Without a pinned floor offset the witness takes the block's last offset;
      # with one it keeps the original default of the first offset after the floor.
      witness_private_ip_offset = (
        p.witness_private_ip_offset != null ? p.witness_private_ip_offset
        : p.private_ip_offset == null ? local.auto_vpc_witness_offset[k]
        : p.private_ip_offset + p.floor_nodes
      )
    })
  }

  # The host offset where a pool's elastic nodes start on the VPC side. Unset
  # means "the same number as the VLAN side" (the original, coupled behaviour).
  pool_vpc_elastic_start = {
    for k, p in local.pools : k => p.vpc_elastic_ip_offset_start != null ? p.vpc_elastic_ip_offset_start : p.elastic_ip_offset_start
  }

  # ----- sizes used by the hard guarantees below -----------------------------
  pool_elastic_count = { for k, p in local.pools : k => max(p.max_nodes - p.floor_nodes, 0) }

  # Number of host offsets (0 .. size-1) in each pool's reserved block; the last
  # one is the broadcast address, so the last usable offset is size - 2.
  pool_vlan_reserved_size = { for k, p in local.pools : k => pow(2, 32 - tonumber(split("/", p.vlan_cidr_reserved)[1])) }

  pools_with_duplicate_slot = [
    for k, s in local.pool_slot : k
    if length([for k2, s2 in local.pool_slot : k2 if s2 == s]) > 1
  ]

  # Only pools that use the calculated VPC values are held to the calculated
  # block's capacity; an explicit override is held to the overlap checks instead.
  pools_exceeding_auto_vpc_block = [
    for k, p in var.pools : k
    if(p.private_ip_offset == null && p.floor_nodes > local.auto_vpc_half) ||
    (p.elastic_ip_offset_start == null && p.vpc_elastic_ip_offset_start == null && local.pool_elastic_count[k] > local.auto_vpc_half - 1)
  ]

  pools_whose_reserved_block_does_not_fit_their_vlan = [
    for k, p in var.pools : k
    if p.vlan_cidr_reserved == null && local.pool_vlan_block_index[k] >= local.pool_vlan_block_capacity[k]
  ]

  pools_with_elastic_range_past_reserved_block = [
    for k, p in local.pools : k
    if p.elastic_ip_offset_start + local.pool_elastic_count[k] > local.pool_vlan_reserved_size[k] - 1
  ]

  pools_with_floor_range_past_reserved_block = [
    for k, p in local.pools : k
    if p.vlan_ip_offset + p.floor_nodes > local.pool_vlan_reserved_size[k] - 1
  ]

  # ----- what to tell the operator -------------------------------------------
  vlan_labels = distinct([for k, p in local.pools : p.vlan_label])

  # ----- per VLAN: what the gateway fleet holds, what is kept for later, and where clients start
  # Any pool on the VLAN supplies the VLAN's own CIDR and its numeric bounds.
  vlan_any_pool = { for vl in local.vlan_labels : vl => [for k, p in local.pools : k if p.vlan_label == vl][0] }
  vlan_net_int  = { for vl, k in local.vlan_any_pool : vl => local.pool_vlan_cidr_int_bounds[k][0] }
  vlan_end_int  = { for vl, k in local.vlan_any_pool : vl => local.pool_vlan_cidr_int_bounds[k][1] }

  # Last address (as a number) used by any pool's reserved block on the VLAN.
  vlan_used_end_int = {
    for vl in local.vlan_labels : vl => max([for k, p in local.pools : local.pool_reserved_int[k][1] if p.vlan_label == vl]...)
  }

  # Spare blocks are kept only while at least one address is still left over for
  # client instances: a spare block never takes the last of a VLAN's client space.
  vlan_spare_blocks_kept = {
    for vl in local.vlan_labels : vl => max(0, min(
      var.pool_vlan_spare_blocks,
      floor((local.vlan_end_int[vl] - local.vlan_used_end_int[vl] - 1) / local.auto_vlan_block_size)
    ))
  }

  vlan_spare_cidrs = {
    for vl in local.vlan_labels : vl => [
      for i in range(local.vlan_spare_blocks_kept[vl]) :
      "${cidrhost(local.pools[local.vlan_any_pool[vl]].vlan_cidr, local.vlan_used_end_int[vl] + 1 + i * local.auto_vlan_block_size - local.vlan_net_int[vl])}/${var.pool_vlan_reserved_prefix}"
    ]
  }

  # Where clients may start: right after the pools' blocks and the spare blocks.
  vlan_client_start_int = {
    for vl in local.vlan_labels : vl => local.vlan_used_end_int[vl] + 1 + local.vlan_spare_blocks_kept[vl] * local.auto_vlan_block_size
  }
  vlan_has_client_space = { for vl in local.vlan_labels : vl => local.vlan_client_start_int[vl] <= local.vlan_end_int[vl] }

  vlan_client_first = {
    for vl in local.vlan_labels : vl => (
      local.vlan_has_client_space[vl]
      ? cidrhost(local.pools[local.vlan_any_pool[vl]].vlan_cidr, local.vlan_client_start_int[vl] - local.vlan_net_int[vl])
      : "none"
    )
  }
  vlan_client_last = {
    for vl in local.vlan_labels : vl => local.vlan_has_client_space[vl] ? cidrhost(local.pools[local.vlan_any_pool[vl]].vlan_cidr, -1) : "none"
  }

  vlan_client_note = {
    for vl in local.vlan_labels : vl => (
      !local.vlan_has_client_space[vl]
      ? "No address is left for client instances: the pools' blocks${local.vlan_spare_blocks_kept[vl] > 0 ? " and the spare blocks" : ""} use the whole VLAN. Use a larger vlan_cidr."
      : local.vlan_spare_blocks_kept[vl] < var.pool_vlan_spare_blocks
      ? "Only ${local.vlan_spare_blocks_kept[vl]} of the ${var.pool_vlan_spare_blocks} spare block(s) could be held back without taking the last of this VLAN's client addresses, so there is no room reserved for a future fleet beyond that. Use a larger vlan_cidr if you expect to add dedicated fleets to this VLAN."
      : "Keep client addresses inside the range above; the spare block(s) are held for dedicated fleets you add to this VLAN later."
    )
  }
}

locals {
  # "first .. last" for a range of nodes, just the address for one node, "none" for zero.
  pool_range_text = {
    for k, p in local.pools : k => {
      vpc_floor = (
        p.floor_nodes == 0 ? "none"
        : p.floor_nodes == 1 ? cidrhost(module.vpc.public_subnet_cidr, p.private_ip_offset)
        : "${cidrhost(module.vpc.public_subnet_cidr, p.private_ip_offset)} .. ${cidrhost(module.vpc.public_subnet_cidr, p.private_ip_offset + p.floor_nodes - 1)}"
      )
      vpc_elastic = (
        local.pool_elastic_count[k] == 0 ? "none"
        : local.pool_elastic_count[k] == 1 ? cidrhost(module.vpc.public_subnet_cidr, local.pool_vpc_elastic_start[k])
        : "${cidrhost(module.vpc.public_subnet_cidr, local.pool_vpc_elastic_start[k])} .. ${cidrhost(module.vpc.public_subnet_cidr, local.pool_vpc_elastic_start[k] + local.pool_elastic_count[k] - 1)}"
      )
      vlan_floor = (
        p.floor_nodes == 0 ? "none"
        : p.floor_nodes == 1 ? cidrhost(p.vlan_cidr_reserved, p.vlan_ip_offset)
        : "${cidrhost(p.vlan_cidr_reserved, p.vlan_ip_offset)} .. ${cidrhost(p.vlan_cidr_reserved, p.vlan_ip_offset + p.floor_nodes - 1)}"
      )
      vlan_elastic = (
        local.pool_elastic_count[k] == 0 ? "none"
        : local.pool_elastic_count[k] == 1 ? cidrhost(p.vlan_cidr_reserved, p.elastic_ip_offset_start)
        : "${cidrhost(p.vlan_cidr_reserved, p.elastic_ip_offset_start)} .. ${cidrhost(p.vlan_cidr_reserved, p.elastic_ip_offset_start + local.pool_elastic_count[k] - 1)}"
      )
    }
  }
}

locals {
  # ----- the shared VPC subnet: what the gateway fleet holds, what is kept for later
  vpc_subnet_size     = pow(2, 32 - tonumber(split("/", module.vpc.public_subnet_cidr)[1]))
  vpc_last_usable_off = local.vpc_subnet_size - 2

  # Every offset a pool occupies on the shared VPC subnet: its whole calculated block when it uses
  # calculated addresses, its actual ranges when it pins them. The subnet summary is built from these,
  # so it is right for calculated, pinned and mixed deployments alike.
  pool_vpc_extent_offsets = {
    for k, p in local.pools : k => concat(
      var.pools[k].private_ip_offset == null
      ? [local.auto_vpc_floor_offset[k], local.auto_vpc_floor_offset[k] + var.pool_vpc_block_size - 1]
      : (p.floor_nodes > 0 ? [p.private_ip_offset, p.private_ip_offset + p.floor_nodes - 1] : []),
      var.pools[k].elastic_ip_offset_start == null && var.pools[k].vpc_elastic_ip_offset_start == null
      ? [local.auto_vpc_floor_offset[k], local.auto_vpc_floor_offset[k] + var.pool_vpc_block_size - 1]
      : (local.pool_elastic_count[k] > 0 ? [local.pool_vpc_elastic_start[k], local.pool_vpc_elastic_start[k] + local.pool_elastic_count[k] - 1] : []),
      local.pool_effective_witness_enabled[k] ? [local.pool_effective_witness_private_ip_offset[k]] : []
    )
  }
  vpc_all_extent_offsets = flatten(values(local.pool_vpc_extent_offsets))
  vpc_used_start_off     = length(local.vpc_all_extent_offsets) == 0 ? var.pool_vpc_base_offset : min(local.vpc_all_extent_offsets...)
  vpc_used_end_off       = length(local.vpc_all_extent_offsets) == 0 ? var.pool_vpc_base_offset - 1 : max(local.vpc_all_extent_offsets...)


  # Calculated pools whose block runs past the last usable address of the VPC subnet.
  pools_past_the_vpc_subnet = [
    for k, p in var.pools : k
    if p.private_ip_offset == null && local.auto_vpc_witness_offset[k] > local.vpc_last_usable_off
  ]
}

output "pool_address_plan" {
  description = "Every pool's resolved addresses (calculated or overridden) and, per VLAN, where client instances may be numbered from. Read this after `terraform plan`, and hand the per-VLAN 'reserved' ranges to whoever assigns client addresses."
  value = {
    pools = {
      for k, p in local.pools : k => {
        slot               = p.slot
        addressing         = (var.pools[k].private_ip_offset == null && var.pools[k].vlan_cidr_reserved == null && var.pools[k].vlan_ip_offset == null && var.pools[k].elastic_ip_offset_start == null) ? "calculated" : "calculated, with overrides"
        vpc_floor_nodes    = local.pool_range_text[k].vpc_floor
        vpc_elastic_nodes  = local.pool_range_text[k].vpc_elastic
        vpc_witness        = local.pool_effective_witness_enabled[k] ? cidrhost(module.vpc.public_subnet_cidr, local.pool_effective_witness_private_ip_offset[k]) : "none"
        vlan_reserved      = p.vlan_cidr_reserved
        vlan_floor_nodes   = local.pool_range_text[k].vlan_floor
        vlan_elastic_nodes = local.pool_range_text[k].vlan_elastic
      }
    }
    vpc_subnet = {
      subnet                    = module.vpc.public_subnet_cidr
      below_the_gateway_fleet   = local.vpc_used_start_off > 1 ? "${cidrhost(module.vpc.public_subnet_cidr, 1)} .. ${cidrhost(module.vpc.public_subnet_cidr, local.vpc_used_start_off - 1)}" : "none"
      used_by_the_gateway_fleet = "${cidrhost(module.vpc.public_subnet_cidr, local.vpc_used_start_off)} .. ${cidrhost(module.vpc.public_subnet_cidr, local.vpc_used_end_off)}"
      note                      = "The gateway fleet's floor, elastic and witness nodes are given fixed addresses inside the range above. Linode assigns other instances' VPC addresses automatically and cannot hold this range back for you, so if an instance already holds an address inside it, apply fails with 'The provided IP is already in use in the subnet' -- move the affected pool with its own slot. A pool added later takes the next slot."
    }
    vlans = {
      for vl in local.vlan_labels : vl => {
        reserved_for_the_gateway_fleet = sort([for k, p in local.pools : p.vlan_cidr_reserved if p.vlan_label == vl])
        reserved_for_future_fleets     = local.vlan_spare_cidrs[vl]
        client_addresses_start_at      = local.vlan_client_first[vl]
        client_addresses_end_at        = local.vlan_client_last[vl]
        configure_clients_with         = local.vlan_has_client_space[vl] ? "${local.vlan_client_first[vl]}/${split("/", local.pools[local.vlan_any_pool[vl]].vlan_cidr)[1]}" : "none"
        note                           = local.vlan_client_note[vl]
      }
    }
  }

  precondition {
    condition     = length(local.pools_with_duplicate_slot) == 0
    error_message = "These pools share a slot: ${join(", ", local.pools_with_duplicate_slot)}. Two pools in one slot would be given the same addresses. Give each pool its own `slot`, or remove the explicit `slot` from all but one of them."
  }

  precondition {
    condition     = length(local.pools_exceeding_auto_vpc_block) == 0
    error_message = "These pools need more than a calculated VPC block holds (up to ${local.auto_vpc_half} floor nodes and ${local.auto_vpc_half - 1} elastic nodes with pool_vpc_block_size = ${var.pool_vpc_block_size}): ${join(", ", local.pools_exceeding_auto_vpc_block)}. Lower floor_nodes/max_nodes, or raise pool_vpc_block_size (which moves every pool that uses calculated addresses)."
  }

  precondition {
    condition     = length(local.pools_past_the_vpc_subnet) == 0
    error_message = "These pools' calculated VPC blocks run past the end of public_subnet_id's CIDR (${module.vpc.public_subnet_cidr}, ${local.vpc_subnet_size} addresses): ${join(", ", local.pools_past_the_vpc_subnet)}. The subnet holds ${floor((local.vpc_last_usable_off - var.pool_vpc_base_offset + 1) / var.pool_vpc_block_size)} pool blocks of ${var.pool_vpc_block_size} at this base offset. Use a larger subnet, or fewer pools."
  }

  precondition {
    condition     = var.pool_vlan_reserved_prefix >= max(values(local.pool_vlan_prefix_len)...)
    error_message = "pool_vlan_reserved_prefix (/${var.pool_vlan_reserved_prefix}) is shorter than at least one pool's vlan_cidr prefix (/${max(values(local.pool_vlan_prefix_len)...)}), so a reserved block cannot fit inside it. Use a longer prefix, or a larger vlan_cidr."
  }

  precondition {
    condition     = length(local.pools_whose_reserved_block_does_not_fit_their_vlan) == 0
    error_message = "These pools' reserved VLAN block does not fit inside their vlan_cidr (each pool sharing a VLAN takes one /${var.pool_vlan_reserved_prefix} block from its start): ${join(", ", local.pools_whose_reserved_block_does_not_fit_their_vlan)}. Use a larger vlan_cidr, a longer pool_vlan_reserved_prefix, or put fewer pools on that VLAN."
  }

  precondition {
    condition     = length(local.pools_with_floor_range_past_reserved_block) == 0 && length(local.pools_with_elastic_range_past_reserved_block) == 0
    error_message = "These pools' nodes do not fit inside their reserved VLAN block: floor ${join(", ", local.pools_with_floor_range_past_reserved_block)}; elastic ${join(", ", local.pools_with_elastic_range_past_reserved_block)}. Lower floor_nodes/max_nodes, or use a shorter pool_vlan_reserved_prefix (a bigger block)."
  }

  precondition {
    condition     = length(local.overlapping_reserved_pool_pairs) == 0
    error_message = "These pool pairs share a VLAN but have overlapping reserved blocks: ${join(", ", local.overlapping_reserved_pool_pairs)}. Both pools' nodes would draw addresses from the same space on the same physical VLAN. Remove the vlan_cidr_reserved override from one of them, or give the pools different slots."
  }

  precondition {
    condition     = length(local.pools_with_colliding_witness_vpc_offset) == 0
    error_message = "These pools' witness VPC (eth1) address collides with another pool's floor or elastic range, their own elastic range, or observability_private_ip_offset: ${join(", ", local.pools_with_colliding_witness_vpc_offset)}. Remove the witness_private_ip_offset override, or set it to an address clear of every pool's ranges."
  }

  precondition {
    condition     = length(local.overlapping_vpc_offset_pool_pairs) == 0
    error_message = "These pool pairs have overlapping floor-node ranges on the shared VPC subnet: ${join(", ", local.overlapping_vpc_offset_pool_pairs)}. Both pools' nodes would get the same VPC (eth1) address. Remove the private_ip_offset override from one of them, or give the pools different slots."
  }

  precondition {
    condition     = length(local.pools_overlapping_observability_offset) == 0
    error_message = "observability_private_ip_offset (${var.observability_private_ip_offset}) falls inside the floor-node range of: ${join(", ", local.pools_overlapping_observability_offset)}. The observability host and one of that pool's floor nodes would get the same VPC (eth1) address. Move observability_private_ip_offset below pool_vpc_base_offset (${var.pool_vpc_base_offset}), or move the pool."
  }

  precondition {
    condition     = length(local.overlapping_elastic_vpc_pool_pairs) == 0
    error_message = "These pool pairs have a VPC-side elastic range that overlaps another pool's floor range, another pool's elastic range, or their own: ${join(", ", local.overlapping_elastic_vpc_pool_pairs)}. Elastic nodes would be given a VPC (eth1) address another node already holds. Remove the elastic_ip_offset_start / vpc_elastic_ip_offset_start override from one of them, or give the pools different slots."
  }

  precondition {
    condition     = length(local.pools_with_elastic_range_overlapping_observability_offset) == 0
    error_message = "observability_private_ip_offset (${var.observability_private_ip_offset}) falls inside the VPC-side elastic range of: ${join(", ", local.pools_with_elastic_range_overlapping_observability_offset)}. The observability host and one of that pool's elastic nodes would get the same VPC (eth1) address. Move observability_private_ip_offset below pool_vpc_base_offset (${var.pool_vpc_base_offset})."
  }

  precondition {
    condition     = length(local.pools_with_floor_reaching_elastic_offset) == 0
    error_message = "These pools have floor_nodes large enough that their floor VLAN offsets reach their own elastic start: ${join(", ", local.pools_with_floor_reaching_elastic_offset)}. This would be a real IP collision the first time natctl provisions an elastic node. Lower floor_nodes, or use a shorter pool_vlan_reserved_prefix (a bigger block)."
  }

  precondition {
    condition     = length(local.pools_with_floor_overlapping_own_elastic_vpc_range) == 0
    error_message = "These pools have a VPC-side floor range that overlaps their OWN elastic range: ${join(", ", local.pools_with_floor_overlapping_own_elastic_vpc_range)}. This would be a duplicate VPC address the first time natctl provisions an elastic node. Remove the address overrides for the affected pool(s), or adjust floor_nodes/max_nodes."
  }

  precondition {
    condition     = length(local.pools_with_non_positive_vlan_ip_offset) == 0
    error_message = "These pools have vlan_ip_offset < 2: ${join(", ", local.pools_with_non_positive_vlan_ip_offset)}. vlan_ip_offset must be >= 2: the observability host's VLAN address sits at vlan_ip_offset - 1, and offset 0 is the block's own network address."
  }
}
