#!/usr/bin/env bash
# build-secrets-bundle.sh (scripts)
#
# Builds and (optionally) publishes the runtime secrets bundle that
# natctl's opt-in secrets_bundle_url mechanism fetches at startup (see
# docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html, Part VIII 8.3). Decrypts
# terraform/environments/<env>/secrets.enc.json with your own SOPS+age
# key (the one that can decrypt it -- see .sops.yaml), remaps its
# lowercase field names to the exact UPPERCASE env var names natctl
# actually reads (config.py's LINODE_TOKEN/NATCTL_OBJECT_STORAGE_*_KEY --
# secrets_bundle.py applies a bundle's JSON keys to os.environ verbatim,
# with no case translation, so this step is load-bearing, not cosmetic),
# then re-encrypts just those three fields as one age-encrypted blob for
# the recipient public key that matches whichever age PRIVATE key your
# nodes have at /etc/natctl/age-key.txt (the one Terraform writes from
# secrets_bundle_age_private_key in that same secrets.enc.json).
# root_pass, grafana_admin_password, and secrets_bundle_age_private_key
# itself are deliberately left out of the bundle payload -- none of them
# are things natctl reads from its own environment. This age step is a
# genuinely different encryption step from the SOPS one above it --
# SOPS encrypts each JSON field individually and needs the `sops`
# format/metadata to decrypt; this step produces a single whole-file age
# ciphertext, decryptable with nothing but the plain `age` CLI already
# required on every node.
#
# The plaintext never touches disk at any point in this script -- `sops
# --decrypt` streams through `jq` into `age --encrypt` via pipes.
#
# -----------------------------------------------------
# Usage:
#
#   ./build-secrets-bundle.sh <bundle-recipient-age-public-key> <output-file> [secrets.enc.json path]
#
#   # Build the blob locally:
#   ./build-secrets-bundle.sh age1<your-bundle-recipient-public-key> /tmp/secrets-bundle.json.age
#
#   # Build it and upload straight to Object Storage as public-read
#   # (requires the AWS CLI or linode-cli configured against your bucket):
#   ./build-secrets-bundle.sh age1<your-bundle-recipient-public-key> /tmp/secrets-bundle.json.age
#   aws s3 cp /tmp/secrets-bundle.json.age s3://<bucket>/natctl/secrets-bundle.json.age --acl public-read
#
# Defaults to terraform/environments/example/secrets.enc.json relative to
# this script's own location if the third argument is omitted -- pass an
# explicit path for any other environment.
#
# -----------------------------------------------------
# Best Practices:
#
# - The recipient public key here is the bundle's own age keypair (see
#   secrets_bundle_age_private_key in secrets.enc.json and
#   secrets_bundle_age_key_path on every node) -- a DIFFERENT keypair
#   from whichever one decrypts secrets.enc.json itself. Mixing the two
#   up doesn't fail loudly: age will happily encrypt to the wrong
#   recipient, and every node will then fail to decrypt the bundle at
#   startup (a clear, loud failure in natctl's own logs -- see
#   secrets_bundle.py's fail-open design -- but not caught here).
# - Delete the output file once it's uploaded -- it's ciphertext, safe to
#   leave lying around briefly, but there's no reason to keep a local
#   copy once Object Storage has the authoritative one.
# - Re-run this (and re-upload) any time secrets.enc.json's own values
#   change -- an already-running natctl process only re-reads the bundle
#   at its own next startup, not continuously (same "reads config once at
#   process start" behavior natctl.yaml itself already has).
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
set -euo pipefail

RECIPIENT="${1:?usage: $0 <bundle-recipient-age-public-key> <output-file> [secrets.enc.json path]}"
OUT_FILE="${2:?usage: $0 <bundle-recipient-age-public-key> <output-file> [secrets.enc.json path]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${3:-$SCRIPT_DIR/../terraform/environments/example/secrets.enc.json}"

command -v sops >/dev/null 2>&1 || { echo "sops is required -- see https://github.com/getsops/sops" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "age is required -- see https://github.com/FiloSottile/age" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required -- see https://jqlang.org" >&2; exit 1; }
[ -f "$SECRETS_FILE" ] || { echo "not found: $SECRETS_FILE" >&2; exit 1; }

# secrets.enc.json's own field names (linode_token, natctl_object_storage_*)
# are lowercase, but natctl reads its credentials from specific UPPERCASE
# env var names (config.py's os.environ.get("LINODE_TOKEN") etc.) --
# fetch_and_apply_secrets_bundle() applies a bundle's JSON keys to
# os.environ VERBATIM, with no case translation, so piping secrets.enc.json
# straight through (as this script used to) produces a bundle whose keys
# natctl never actually reads. This jq step is the fix: remap to the exact
# env var names, and drop everything else (root_pass, grafana_admin_password,
# secrets_bundle_age_private_key itself) -- none of those are things natctl
# reads from its own environment, so they don't belong in this payload.
sops --decrypt "$SECRETS_FILE" \
  | jq '{
      LINODE_TOKEN: .linode_token,
      NATCTL_OBJECT_STORAGE_ACCESS_KEY: .natctl_object_storage_access_key,
      NATCTL_OBJECT_STORAGE_SECRET_KEY: .natctl_object_storage_secret_key
    }' \
  | age --encrypt --recipient "$RECIPIENT" --output "$OUT_FILE"

echo "Wrote $OUT_FILE ($(wc -c < "$OUT_FILE") bytes, ciphertext)."
echo "Upload it (public-read is fine -- it's ciphertext) to the Object Storage URL configured as secrets_bundle_url, then restart natctl on any node that should pick up the new bundle."
