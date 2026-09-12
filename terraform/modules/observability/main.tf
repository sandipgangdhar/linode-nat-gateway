# main.tf (terraform/modules/observability)
#
# Provisions the single control-plane instance that runs natctl (the fleet
# controller), Prometheus, Grafana, and Alertmanager together via Docker
# Compose. This is the "brain" of the fleet: every NAT node's exporter is
# scraped from here, natctl's autoscaling/buddy-pairing/IP-failover
# decisions are made here, and the roster API every client-agent polls is
# served from here.
#
# -----------------------------------------------------
# What this file creates:
#
# 1) locals.cloud_init          - Renders
#    ansible/cloud-init/observability.yaml.tftpl with the Docker Compose
#    file, Prometheus/Alertmanager/Grafana configs, natctl's config, and
#    the Linode API token. The natctl Python package itself is NOT
#    embedded here -- var.natctl_file_urls (terraform/modules/
#    artifacts) is fetched at boot instead, since Linode's Instance
#    Metadata API caps cloud-init user_data at 16384 bytes decoded. The
#    pre-built Grafana dashboard JSON is fetched at boot the same way
#    (var.nat_overview_json_url) -- besides the byte budget, this
#    also means editing the dashboard no longer forces this instance to
#    be replaced on the next apply (a `metadata.user_data` change is
#    ForceNew; a fetched-at-boot URL reference doesn't change when its
#    target content does).
# 3) linode_instance.observability - The instance itself: a public
#    interface (Grafana/Prometheus/natctl API access) plus a VPC interface
#    at a pinned static IP so NAT nodes and client-agents have a stable
#    address to reach it at.
#
# -----------------------------------------------------
# Usage:
#
# - Call once per environment (see terraform/environments/example/main.tf).
# - natctl_config_yaml must be composed at the environment level (this
#   module stays generic / pool-unaware) -- see variables.tf.
# - After apply, reach Grafana at outputs.grafana_url and Prometheus at
#   outputs.prometheus_url.
#
# -----------------------------------------------------
# Best Practices:
#
# - Tighten the control-plane Cloud Firewall (terraform/modules/vpc) to
#   your admin CIDR before exposing Grafana/Prometheus/natctl's API beyond
#   a lab environment.
# - Rotate grafana_admin_password and linode_token via Terraform variables,
#   not by hand-editing the running instance.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

# Every module that directly uses a provider's resources must declare its
# own required_providers block with an explicit source -- the root
# environment's own required_providers (terraform/environments/example/
# versions.tf) does NOT propagate this source address down to child
# modules automatically (see HashiCorp's Provider Requirements docs:
# "If you omit the source argument when requiring a provider, Terraform
# uses an implied source address of registry.terraform.io/hashicorp/
# <LOCAL NAME>"). Without this block, `terraform init` fails trying to
# resolve a nonexistent hashicorp/linode provider instead of the real
# linode/linode one -- this was a real, latent bug in this module until
# discovered against a live `terraform init` run. Version constraint
# mirrors the root's.
terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.9"
    }
  }
}

locals {
  # natctl/*.py content is not read/embedded here -- see
  # terraform/modules/artifacts/main.tf's header comment (Linode's
  # 16384-byte decoded cloud-init limit). var.natctl_file_urls (passed in
  # from environments/example/main.tf) carries the fetch-at-boot URLs
  # instead.

  cloud_init = templatefile("${path.module}/../../../ansible/cloud-init/observability.yaml.tftpl", {
    docker_compose_yml = templatefile("${path.module}/../../../ansible/templates/docker-compose.yml.tftpl", {
      grafana_admin_password = var.grafana_admin_password
    })
    prometheus_yml = templatefile("${path.module}/../../../ansible/templates/prometheus.yml.tftpl", {
      remote_write_url      = var.prometheus_remote_write_url
      remote_write_username = var.prometheus_remote_write_username
      remote_write_password = var.prometheus_remote_write_password
      # natctl's own :<api_port>/metrics only actually exists on THIS
      # host when this module also runs natctl itself -- see
      # prometheus.yml.tftpl's own header comment for the
      # natctl-on-node limitation.
      scrape_natctl_metrics = var.run_natctl
      api_port              = var.api_port
      # Non-empty only when natctl_on_node_enabled, one target per
      # enabled pool (not one target for the whole fleet, which would
      # miss every pool but the one that address's own natctl instance
      # knows about) -- see terraform/environments/example/main.tf's
      # natctl_http_sd_targets local for the full story.
      natctl_http_sd_targets = var.natctl_http_sd_targets
    })
    alertmanager_yml       = file("${path.module}/../../../ansible/templates/alertmanager.yml")
    grafana_datasource_yml = file("${path.module}/../../../ansible/templates/grafana-datasource.yml")
    grafana_dashboards_yml = file("${path.module}/../../../ansible/templates/grafana-dashboards.yml")
    nat_alerts_yml         = file("${path.module}/../../../alerts/nat-alerts.yml")

    run_natctl           = var.run_natctl
    run_monitoring_stack = var.run_monitoring_stack
    natctl_file_urls     = var.natctl_file_urls

    # See this module's vpc_sibling_subnet_cidrs variable and
    # observability.yaml.tftpl's own runcmd comment for the full
    # write-up.
    private_ip               = var.private_ip
    vpc_prefix               = var.vpc_prefix
    vpc_sibling_subnet_cidrs = var.vpc_sibling_subnet_cidrs
    # The VLAN interface attached below (dynamic "interface") needs this
    # template to know vlan_label/vlan_ip too, so the live VLAN NIC boots
    # with the same DNS-scope-removal override and explicit static-
    # address config the NAT-node renderers (cloud_init.py/
    # nat-node.yaml.tftpl) already apply for their own eth1/eth2. See
    # observability.yaml.tftpl's own runcmd comment.
    vlan_label = var.vlan_label
    vlan_ip    = var.vlan_ip
    # Fetched from Object Storage instead of embedded -- see
    # terraform/modules/artifacts' static uploads and nat-fleet's
    # matching treatment.
    natctl_requirements_txt_url = var.natctl_requirements_txt_url
    natctl_service_url          = var.natctl_service_url
    # Same treatment -- see terraform/modules/artifacts' matching change
    # and this file's nat_overview_json_url variable for why.
    nat_overview_json_url     = var.nat_overview_json_url
    natctl_config_yaml        = var.natctl_config_yaml
    linode_token              = var.linode_token
    object_storage_access_key = var.object_storage_access_key
    object_storage_secret_key = var.object_storage_secret_key

    # "source" (default) preserves the above exactly as it behaved
    # before this variable existed -- see nat-fleet/main.tf's matching
    # comment.
    agent_distribution = var.agent_distribution
    natctl_bin_url     = var.natctl_bin_url
  })
}

resource "linode_instance" "observability" {
  label           = var.label
  region          = var.region
  type            = var.instance_type
  image           = var.image
  authorized_keys = var.authorized_keys
  root_pass       = var.root_pass
  firewall_id     = var.firewall_id
  tags            = ["lng", "observability"]

  interface {
    purpose = "public"
  }

  interface {
    purpose   = "vpc"
    subnet_id = var.subnet_id
    ipv4 {
      vpc = var.private_ip
    }
  }

  # Genuine VLAN presence for this host, so a "vlan_only" client (no VPC
  # interface at all) can reach the roster API in the default
  # single-dedicated-host layout (natctl_on_node_enabled = false) --
  # without this, this instance has no VLAN interface at all, and such a
  # client structurally cannot reach it. Joins the SHARED pool's own VLAN
  # specifically (the default pool every tenant uses) -- a dedicated pool
  # on a genuinely
  # separate VLAN is unaffected by this and still needs
  # natctl_on_node_enabled (or a VPC-capable client) for the same reason
  # as before. Only attached when var.vlan_label is actually given (empty
  # string skips this interface entirely) -- backward compatible for any
  # caller that hasn't wired the new variables yet.
  dynamic "interface" {
    for_each = var.vlan_label != "" ? [1] : []
    content {
      purpose      = "vlan"
      label        = var.vlan_label
      ipam_address = var.vlan_ip # full "host/prefix" string -- caller combines them, same as nat-fleet's own node_vlan_ips/vlan_cidr pattern
    }
  }

  metadata {
    # gzip before base64 -- see nat-fleet/main.tf's matching comment.
    # The dashboard JSON (~18KB raw) is not part of this payload at all
    # (fetched at boot instead, see nat_overview_json_url above) -- what's
    # left (alerts JSON + docker-compose/prometheus/grafana configs) is
    # comfortably under Linode's 16384-byte decoded limit even before
    # gzip.
    user_data = base64gzip(local.cloud_init)
  }
}

# object_storage_access_key/secret_key's own descriptions both state
# "required whenever run_natctl is true, independent of leader_election",
# but unlike terraform/modules/nat-fleet's identical
# natctl_on_node_enabled_requires_its_own_dependencies check, nothing
# here enforced it. A caller setting run_natctl = true with either left
# at its "" default would apply silently; the first elastic-node
# autoscale event then fails at runtime (fleet.py's _provision() ->
# upload_public_object() rejected by Object Storage) with zero
# plan-time warning.
check "run_natctl_requires_object_storage_credentials" {
  assert {
    condition     = !var.run_natctl || (var.object_storage_access_key != "" && var.object_storage_secret_key != "")
    error_message = "run_natctl is true but object_storage_access_key/object_storage_secret_key are not both set -- natctl needs them to upload each elastic node's own rendered nftables.conf/artifacts. Set both."
  }
}

# vlan_label/vlan_ip are two independent optional variables with
# independent "" defaults, paired only by convention/description text --
# the dynamic "interface" block above is gated only on vlan_label != "",
# with no check that vlan_ip was also supplied. A caller setting
# vlan_label but leaving vlan_ip empty would still get a real VLAN NIC
# created with ipam_address = "", either rejected outright by the Linode
# API at apply time or booting with no usable VLAN address.
check "vlan_label_requires_vlan_ip" {
  assert {
    condition     = var.vlan_label == "" || var.vlan_ip != ""
    error_message = "vlan_label is set but vlan_ip is not -- the VLAN interface above would be created with an empty ipam_address. Set vlan_ip (a full \"host/prefix\" string, e.g. \"192.168.100.19/22\") alongside vlan_label."
  }
}
