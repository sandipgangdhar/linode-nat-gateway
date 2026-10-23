# log_shipping.tf (terraform/environments/example)
#
# Node log shipping: every NAT node streams its systemd journal (natctl,
# buddy-sync, FRR, conntrackd, cloud-init, ...) to Grafana Loki on the
# observability host, and Loki keeps it in a dedicated Object Storage
# bucket for log_retention_days. A node's logs therefore outlive the node:
# an elastic node deleted on scale-in, or a node that crashed or was fenced.
# Grafana's "Node logs" dashboard reads them.
#
# -----------------------------------------------------
# What this file provides:
#
# 1) linode_object_storage_bucket.logs / linode_object_storage_key.loki -
#    The logs bucket and an access key scoped to it alone, for Loki.
# 2) linode_object_storage_object.log_shipping - natctl/log-shipping.json
#    in the natctl bucket: where nodes push. natctl reads it every
#    reconcile pass and serves it to the node's own nat-exporter, so it can
#    change without replacing any node. Written as {"enabled": false} when
#    shipping is off or there is no observability host to push to.
#
# -----------------------------------------------------
# Usage:
#
# - log_shipping_enabled (default true) and log_retention_days (default 14)
#   in terraform.tfvars. Turning shipping on or off changes the
#   observability host's user_data, which replaces that host (Prometheus
#   and Grafana history on it is lost); nodes are not replaced.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

locals {
  # Loki runs on the observability host, so shipping needs one running the monitoring stack.
  log_shipping_active = var.log_shipping_enabled && local.create_observability_instance && var.run_monitoring_stack
  log_shipping_config = jsonencode(local.log_shipping_active ? {
    enabled  = true
    push_url = "http://${local.natctl_private_ip}:3100/loki/api/v1/push"
    } : {
    enabled = false
  })
}

resource "random_id" "logs_bucket_suffix" {
  count       = local.log_shipping_active ? 1 : 0
  byte_length = 3
}

resource "linode_object_storage_bucket" "logs" {
  count   = local.log_shipping_active ? 1 : 0
  cluster = local.natctl_object_storage_region
  label   = "${var.label}-logs-${random_id.logs_bucket_suffix[0].hex}"
}

resource "linode_object_storage_key" "loki" {
  count = local.log_shipping_active ? 1 : 0
  label = "${var.label}-loki"

  bucket_access {
    bucket_name = linode_object_storage_bucket.logs[0].label
    cluster     = local.natctl_object_storage_region
    permissions = "read_write"
  }
}

resource "linode_object_storage_object" "log_shipping" {
  bucket     = var.natctl_object_storage_bucket
  region     = local.natctl_object_storage_region
  access_key = local.natctl_object_storage_access_key
  secret_key = local.natctl_object_storage_secret_key

  key     = "natctl/log-shipping.json"
  content = local.log_shipping_config
  etag    = md5(local.log_shipping_config)
}
