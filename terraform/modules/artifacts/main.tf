# main.tf (terraform/modules/artifacts) -- CUSTOMER-REPO BINARY VARIANT
#
# This is the customer-repo-overlay equivalent of the dev repo's
# terraform/modules/artifacts/main.tf. Same job (upload the pieces every
# node needs to fetch at boot to Object Storage, once per environment,
# since Linode's Instance Metadata API caps cloud-init user_data at 16384
# bytes decoded -- see the dev repo's version of this file for the full
# "why", unchanged here) but this variant uploads pre-compiled BINARIES
# (already committed into this repo at fixed paths by the release
# pipeline -- see scripts/publish/assemble_customer_repo.py's
# BINARY_PLACEMENTS in the dev repo) instead of Python source. There is
# no dual-mode support here (unlike the dev repo's agent_distribution
# flag) -- this repo only ever ships compiled binaries, so this module
# doesn't need the dev repo's compiled_agents_enabled/dist_dir variables
# at all (variables.tf still declares them, for interface compatibility,
# but this file simply doesn't reference them).
#
# variables.tf is UNCHANGED from the dev repo -- only main.tf and
# outputs.tf are replaced.
#
# -----------------------------------------------------
# Why several outputs keep the dev repo's "source" names
# (exporter_py_url/buddy_sync_py_url/natctl_service_url/
# nat_exporter_service_url/lng_buddy_sync_service_url) even though they
# now point at binaries or binary-mode unit files:
#
# terraform/modules/nat-fleet and terraform/modules/observability (copied
# VERBATIM from the dev repo, unmodified) declare exporter_py_url/
# buddy_sync_py_url as REQUIRED variables (no default) -- something has
# to satisfy them. And natctl_service_url/nat_exporter_service_url/
# lng_buddy_sync_service_url are read UNCONDITIONALLY by
# ansible/cloud-init/nat-node.yaml.tftpl and observability.yaml.tftpl
# (only the AGENT source-vs-binary fetch branches on agent_distribution --
# the unit-file URL fetch itself does not) -- so these three specifically
# MUST resolve to the binary-mode unit files for this environment (which
# always sets agent_distribution = "binary", see
# terraform/environments/example/main.tf) to actually work. Redirecting
# these existing output names, instead of introducing new ones, meant
# terraform/environments/example/main.tf only needed genuinely NEW
# argument lines added for exporter_bin_url/buddy_sync_bin_url/
# natctl_bin_url/client_agent_bin_url -- everything else needed zero
# changes, since every consumer of the unchanged names keeps working
# without ever knowing whether it's pointed at source or a binary.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.9"
    }
  }
}

locals {
  prefix = "lng-artifacts"

  natctl_bin_path       = "${path.module}/../../../controller/natctl"
  nat_exporter_bin_path = "${path.module}/../../../exporter/nat_exporter/nat-exporter"
  buddy_sync_bin_path   = "${path.module}/../../../buddy-sync/buddy-sync"
  client_agent_bin_path = "${path.module}/../../../client-agent/client-agent"
  natctl_cli_bin_path   = "${path.module}/../../../controller/natctl-cli"

  natctl_service_path          = "${path.module}/../../../controller/natctl-binary.service"
  nat_exporter_service_path    = "${path.module}/../../../exporter/nat_exporter/nat-exporter-binary.service"
  lng_buddy_sync_service_path  = "${path.module}/../../../buddy-sync/lng-buddy-sync-binary.service"
  conntrackd_peer_service_path = "${path.module}/../../../buddy-sync/conntrackd@.service"

  nat_overview_json_path = "${path.module}/../../../dashboards/nat-overview.json"

  # scripts/install-nat-client.sh itself -- a plain shell script, not a
  # compiled binary, so unlike the four Nuitka outputs above this is the
  # exact same file the dev repo uploads. Served to client instances by
  # natctl (GET /agents/install-nat-client.sh), same fetch-once-cache
  # pattern as client_agent_bin above.
  install_nat_client_script_path = "${path.module}/../../../scripts/install-nat-client.sh"

  base_url = "https://${var.bucket}.${var.s3_region}.linodeobjects.com"
}

resource "linode_object_storage_object" "natctl_bin" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/bin/natctl"
  source = local.natctl_bin_path
  acl    = "public-read"
  etag   = filemd5(local.natctl_bin_path)
}

resource "linode_object_storage_object" "nat_exporter_bin" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/bin/nat-exporter"
  source = local.nat_exporter_bin_path
  acl    = "public-read"
  etag   = filemd5(local.nat_exporter_bin_path)
}

resource "linode_object_storage_object" "buddy_sync_bin" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/bin/buddy-sync"
  source = local.buddy_sync_bin_path
  acl    = "public-read"
  etag   = filemd5(local.buddy_sync_bin_path)
}

# Served to client instances by natctl itself (GET /agents/client-agent,
# controller/natctl/api.py in the dev repo), not fetched directly from
# Object Storage by clients -- see ApiConfig.client_agent_bin_url.
# natctl's own host fetches this ONCE at its own startup and caches it
# locally from then on.
resource "linode_object_storage_object" "client_agent_bin" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/bin/client-agent"
  source = local.client_agent_bin_path
  acl    = "public-read"
  etag   = filemd5(local.client_agent_bin_path)
}

# Uploaded here the same way as the other agents, so
# nat-node.yaml.tftpl/observability.yaml.tftpl can install natctl-cli
# automatically wherever natctl itself actually runs (see those
# templates' own comments). The GitHub Release attachment (for an
# operator's own laptop, or any host outside the fleet) is unchanged
# and still the way to get it onto a machine that never runs natctl
# itself.
resource "linode_object_storage_object" "natctl_cli_bin" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/bin/natctl-cli"
  source = local.natctl_cli_bin_path
  acl    = "public-read"
  etag   = filemd5(local.natctl_cli_bin_path)
}

resource "linode_object_storage_object" "natctl_service" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/natctl.service"
  source = local.natctl_service_path
  acl    = "public-read"
  etag   = filemd5(local.natctl_service_path)
}

resource "linode_object_storage_object" "nat_exporter_service" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/nat-exporter.service"
  source = local.nat_exporter_service_path
  acl    = "public-read"
  etag   = filemd5(local.nat_exporter_service_path)
}

resource "linode_object_storage_object" "lng_buddy_sync_service" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/lng-buddy-sync.service"
  source = local.lng_buddy_sync_service_path
  acl    = "public-read"
  etag   = filemd5(local.lng_buddy_sync_service_path)
}

resource "linode_object_storage_object" "conntrackd_peer_service" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/conntrackd@.service"
  source = local.conntrackd_peer_service_path
  acl    = "public-read"
  etag   = filemd5(local.conntrackd_peer_service_path)
}

resource "linode_object_storage_object" "nat_overview_json" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/nat-overview.json"
  source = local.nat_overview_json_path
  acl    = "public-read"
  etag   = filemd5(local.nat_overview_json_path)
}

resource "linode_object_storage_object" "install_nat_client_script" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key    = "${local.prefix}/install-nat-client.sh"
  source = local.install_nat_client_script_path
  acl    = "public-read"
  etag   = filemd5(local.install_nat_client_script_path)
}

# ---------------------------------------------------------------------------
# Integrity manifest -- needed because every object above is fetched at
# boot via a plain, unauthenticated curl with no integrity check beyond
# HTTPS transport trust otherwise, and the same Object Storage write
# credential used for the
# leader-election lease record is distributed to every node in
# natctl_on_node_enabled mode -- a single compromised node could plant a
# malicious replacement for any binary/unit file here, and every OTHER
# node would fetch and RUN it as root. Same key format as the dev repo
# (path relative to this module's own prefix directory, e.g. "bin/natctl",
# "natctl.service") -- consumers (ansible/cloud-init/nat-node.yaml.tftpl's/
# observability.yaml.tftpl's lng-fetch-verified.sh, copied verbatim from
# the dev repo) derive the manifest key from any fetch URL by stripping
# the manifest's own URL directory, so this works identically regardless
# of which artifacts variant (source or binary) is in play. Deliberately
# NOT covering nat_overview_json above -- a Grafana dashboard definition
# is data, not code anything here executes.
locals {
  manifest = {
    "bin/natctl"             = filesha256(local.natctl_bin_path)
    "bin/nat-exporter"       = filesha256(local.nat_exporter_bin_path)
    "bin/buddy-sync"         = filesha256(local.buddy_sync_bin_path)
    "bin/client-agent"       = filesha256(local.client_agent_bin_path)
    "bin/natctl-cli"         = filesha256(local.natctl_cli_bin_path)
    "natctl.service"         = filesha256(local.natctl_service_path)
    "nat-exporter.service"   = filesha256(local.nat_exporter_service_path)
    "lng-buddy-sync.service" = filesha256(local.lng_buddy_sync_service_path)
    "conntrackd@.service"    = filesha256(local.conntrackd_peer_service_path)
    "install-nat-client.sh"  = filesha256(local.install_nat_client_script_path)
  }
}

resource "linode_object_storage_object" "manifest" {
  bucket     = var.bucket
  region     = var.s3_region
  access_key = var.access_key
  secret_key = var.secret_key

  key          = "${local.prefix}/manifest.sha256.json"
  content      = jsonencode(local.manifest)
  content_type = "application/json"
  acl          = "public-read"
  etag         = md5(jsonencode(local.manifest))
}
