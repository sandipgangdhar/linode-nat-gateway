###############################################################################
# NAT HA on Linode
###############################################################################

# -----------------------------------------------------------------------------
# Cloud-init: install base tools + Ansible on first boot
# -----------------------------------------------------------------------------
locals {
  cloud_init = <<-EOF
  #cloud-config
  package_update: true
  packages:
    - ca-certificates
    - curl
    - jq
    - vim
    - python3
    - python3-pip
    - git
    - keepalived
    - nftables
    - conntrack
  runcmd:
    - pip3 install --upgrade pip
    - pip3 install ansible
    - systemctl enable keepalived || true
    - systemctl enable nftables || true
  %{if var.inject_ssh_via_cloud_init~}
  ssh_authorized_keys:
  %{for k in var.ssh_authorized_keys~}
    - ${k}
  %{endfor~}
  %{endif~}
  EOF
}

# -----------------------------------------------------------------------------
# Multi-pair data model (mandatory)
# -----------------------------------------------------------------------------
locals {
  # nat_pairs is a list(object); normalize to map(name => object)
  nat_pairs_by_name = {
    for p in var.nat_pairs : p.name => p
  }

  pair_names = keys(local.nat_pairs_by_name)

  # Flatten members for for_each
  members_flat = flatten([
    for pname, p in local.nat_pairs_by_name : [
      for m in p.members : {
        pair_name   = pname
        vlan_label  = p.vlan_label
        vlan_vip    = p.vlan_vip
        shared_ipv4 = try(p.shared_ipv4, "")
        vrrp_id     = p.vrrp_id
        label       = m.label
        vlan_ip     = m.vlan_ip        # e.g. "192.168.0.101/16"
        state       = m.state
        priority    = m.priority
      }
    ]
  ])

  # Convenience: map label -> full member object
  members_by_label = {
    for m in local.members_flat : m.label => m
  }

  # Helper: label -> bare IP (strip CIDR, works for any /XX)
  local_ip_by_label = {
    for m in local.members_flat :
    m.label => split("/", m.vlan_ip)[0]
  }

  # Helper: label -> peer label (the "other" node in the same pair)
  peer_label_by_label = merge([
    for pname, p in local.nat_pairs_by_name : {
      for m in p.members :
      m.label => element(
        [for x in p.members : x.label if x.label != m.label],
        0
      )
    }
  ]...)

  # Final: label -> peer IP (also without CIDR)
  peer_ip_by_label = {
    for label, peer_label in local.peer_label_by_label :
    label => local.local_ip_by_label[peer_label]
  }
}
# -----------------------------------------------------------------------------
# PLACEMENT GROUPS (multi-pair – per pair)
# -----------------------------------------------------------------------------
resource "linode_placement_group" "pg_auto" {
  for_each = {
    for pname, p in local.nat_pairs_by_name : pname => p
    if trimspace(try(p.placement_group_label, "")) == ""
  }

  label                = "${var.prefix}-${each.key}-placement-group"
  region               = var.region
  placement_group_type = try(each.value.placement_group_type, var.placement_group_type)
}

data "linode_placement_groups" "pg_existing" {
  for_each = {
    for pname, p in local.nat_pairs_by_name : pname => p
    if trimspace(try(p.placement_group_label, "")) != ""
  }

  filter {
    name   = "label"
    values = [try(each.value.placement_group_label, "")]
  }

  filter {
    name   = "region"
    values = [var.region]
  }
}

locals {
  # Per-pair PG IDs: combine auto-created and pre-existing (looked up by label)
  placement_group_id_by_pair = merge(
    { for k, v in linode_placement_group.pg_auto : k => v.id },
    { for k, v in data.linode_placement_groups.pg_existing : k => try(v.placement_groups[0].id, null) }
  )
}

# -----------------------------------------------------------------------------
# MULTI-PAIR INSTANCES
# -----------------------------------------------------------------------------
resource "linode_instance" "multi" {
  for_each                           = { for m in local.members_flat : m.label => m }
  label                              = each.value.label
  region                             = var.region
  image                              = var.image
  type                               = var.type
  root_pass                          = var.root_pass != "" ? var.root_pass : null
  authorized_keys                    = var.inject_ssh_via_cloud_init ? null : var.ssh_authorized_keys
  placement_group_externally_managed = true

  interface {
    purpose = "public"
  }

  interface {
    purpose      = "vlan"
    label        = each.value.vlan_label
    ipam_address = each.value.vlan_ip
  }

  tags = compact([
    "nat",
    "gateway",
    "ha",
    each.value.state == "MASTER" ? "primary" : "backup"
  ])

  metadata {
    user_data = base64encode(local.cloud_init)
  }
}

resource "linode_placement_group_assignment" "multi_attach" {
  for_each           = { for m in local.members_flat : m.label => m }
  placement_group_id = local.placement_group_id_by_pair[local.members_by_label[each.key].pair_name]
  linode_id          = linode_instance.multi[each.key].id

  depends_on = [linode_instance.multi]
}

# -----------------------------------------------------------------------------
# IP SHARING (multi-pair)
# -----------------------------------------------------------------------------
resource "null_resource" "ip_share_multi" {
  for_each = var.use_ip_share ? {
    for m in local.members_flat : m.label => m
    if length(trimspace(m.shared_ipv4)) > 0
  } : {}

  triggers = {
    shared_ipv4 = trimspace(each.value.shared_ipv4)
    linode_id   = linode_instance.multi[each.key].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOC
      set -euo pipefail
      IP="${each.value.shared_ipv4}"
      NODE_ID=${linode_instance.multi[each.key].id}
      echo "⇒ Sharing $${IP} to ${each.key} (linode_id=$${NODE_ID})"
      for i in 1 2 3; do
        curl -sS -H "Authorization: Bearer ${var.linode_token}" \
             -H "Content-Type: application/json" \
             -X POST \
             -d '{"ips":["'"$${IP}"'"],"linode_id": '"$${NODE_ID}"'}' \
             https://api.linode.com/v4/networking/ips/share && break || {
          echo "   share attempt $i failed; retrying in $((i*2))s..."
          sleep $((i*2))
        }
      done
      echo "✓ Share to ${each.key} completed."
    EOC
  }

  depends_on = [linode_instance.multi]
}

# -----------------------------------------------------------------------------
# Ansible files (inventory, group_vars, host_vars) – multi only
# -----------------------------------------------------------------------------

# Ensure host_vars dir exists
resource "null_resource" "create_hostvars_dir" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command     = "mkdir -p ../ansible/host_vars"
  }
}

# Ensure group_vars dir exists
resource "null_resource" "create_groupvars_dir" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command     = "mkdir -p ../ansible/group_vars"
  }
}

# Inventory – one group per pair + [nat:children]
resource "local_file" "ansible_inventory_multi" {
  filename = "${path.module}/../ansible/inventory.ini"

  content = join("\n", flatten([
    "# Auto-generated by Terraform — multi-pair inventory",
    "[nat:children]",
    [for p in local.pair_names : "nat_${p}"],
    "",
    flatten([
      for p in local.pair_names : [
        "[nat_${p}]",
        format("%s-a ansible_host=%s state=MASTER priority=150",
          p,
          try(tolist(linode_instance.multi["${p}-a"].ipv4)[0], "")
        ),
        format("%s-b ansible_host=%s state=BACKUP priority=100",
          p,
          try(tolist(linode_instance.multi["${p}-b"].ipv4)[0], "")
        ),
        "",
        "[nat_${p}:vars]",
        "ansible_user=root",
        "pub_if=eth0",
        "vlan_if=eth1",
        format("vlan_vip=%s", try(local.nat_pairs_by_name[p].vlan_vip, "")),
        format("shared_ipv4=%s", try(local.nat_pairs_by_name[p].shared_ipv4, "")),
        ""
      ]
    ]),
    "",
    "[nat:vars]",
    format("dcid=%s", var.dcid)
  ]))

  depends_on = [linode_instance.multi]
}

# Per-pair group_vars: vrrp + VIP + FIP + interfaces
resource "local_file" "group_vars_per_pair" {
  for_each = toset(local.pair_names)

  filename             = "${path.module}/../ansible/group_vars/nat_${each.key}.yml"
  file_permission      = "0777"
  directory_permission = "0777"

  content = <<-YAML
    # Auto-generated by Terraform. Do not edit by hand.
    # Pair: ${each.key}
    fip: "${try(local.nat_pairs_by_name[each.key].shared_ipv4, "")}"
    vlan_vip: "${try(local.nat_pairs_by_name[each.key].vlan_vip, "")}"

    # VRRP parameters
    vrrp_id: ${try(local.nat_pairs_by_name[each.key].vrrp_id, 50 + index(local.pair_names, each.key))}
    vrrp_instance: "VGW1"
    vrrp_interface: "eth1"
    vrrp_auth_pass: "${each.key}-pass"

    # Interfaces (match what Terraform creates on the Linodes)
    pub_if: "eth0"
    vlan_if: "eth1"
  YAML

  depends_on = [null_resource.create_groupvars_dir]
}

# Common nat group_vars – DCID only (no more overwriting vrrp fields)
resource "local_file" "group_vars_nat_common" {
  filename             = "${path.module}/../ansible/group_vars/nat.yml"
  file_permission      = "0777"
  directory_permission = "0777"

  content = <<-YAML
    # Auto-generated by Terraform. Do not edit by hand.
    dcid: ${var.dcid}
  YAML

  depends_on = [null_resource.create_groupvars_dir]
}

# host_vars per node – conntrack + sync IPs
resource "local_file" "hostvars_per_node" {
  for_each = { for m in local.members_flat : m.label => m }

  filename = "${path.module}/../ansible/host_vars/${each.key}.yml"

  content = <<-EOT
    # Auto-generated by Terraform — do not edit manually
    vlan_if: eth1
    ct_local_ip: "${local.local_ip_by_label[each.key]}"
    ct_peer_ip:  "${local.peer_ip_by_label[each.key]}"
    # Ansible role expected names (used in conntrackd.conf.j2)
    nat_ha_sync_iface: "${try(var.sync_iface, "eth1")}"
    nat_ha_sync_ip_self: "${local.local_ip_by_label[each.key]}"
    nat_ha_sync_ip_peer: "${local.peer_ip_by_label[each.key]}"
  EOT

  depends_on = [
    linode_instance.multi,
    null_resource.create_hostvars_dir
  ]
}
