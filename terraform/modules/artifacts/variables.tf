# variables.tf (terraform/modules/artifacts)
#
# Every input this module accepts. See main.tf's header comment for why
# this module exists at all.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "bucket" {
  description = "Linode Object Storage bucket to upload exporter.py/buddy_sync.py/the natctl package into. Must already exist (this module does not create the bucket itself -- see main.tf's header comment for why) -- same bucket terraform/environments/example/variables.tf's natctl_object_storage_bucket documents for leader-election lease storage."
  type        = string
}

variable "s3_region" {
  description = "The Object Storage S3-compatible endpoint's region/cluster id (e.g. \"us-east-1\", \"in-maa-1\") -- NOT necessarily the same value as this environment's compute region (var.region). Confirmed against Linode's own docs (https://techdocs.akamai.com/cloud-computing/docs/access-buckets-and-files-through-urls): both linode_object_storage_object's region argument and the public File URL format (https://[bucket-label].[s3-endpoint-hostname].linodeobjects.com/[key]) use this same value. The caller derives this from natctl_object_storage_endpoint by stripping the https:// prefix and .linodeobjects.com suffix -- see environments/example/main.tf's local.natctl_object_storage_region."
  type        = string
}

variable "access_key" {
  description = "Object Storage access key -- same credential natctl_object_storage_access_key already documents for leader-election lease storage; reused here since it's the same bucket."
  type        = string
  sensitive   = true
}

variable "secret_key" {
  description = "Object Storage secret key -- see access_key above."
  type        = string
  sensitive   = true
}

# v21: compiled-binary uploads, additive and off by default -- see
# main.tf's matching v21 comment and docs/PUBLISHING.md. The dev repo
# never builds dist/ (no Nuitka step in its own CI), so this stays false
# for every existing deployment; a release pipeline that DOES build the
# three binaries sets it true and points dist_dir at them.
variable "compiled_agents_enabled" {
  description = "Whether to additionally upload pre-compiled natctl/nat-exporter/buddy-sync binaries (from dist_dir) for agent_distribution == \"binary\" pools. False (default) uploads nothing here and leaves every other resource in this module completely unaffected."
  type        = bool
  default     = false
}

variable "dist_dir" {
  # NOTE: variable defaults must be literal constants (no path.module) --
  # this is resolved relative to the repo root by local.dist_dir in
  # main.tf, not used directly.
  description = "Directory (relative to the repo root) containing the three compiled binaries (natctl, nat-exporter, buddy-sync), only read when compiled_agents_enabled is true."
  type        = string
  default     = "dist"
}
