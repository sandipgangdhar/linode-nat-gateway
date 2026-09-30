#!/bin/sh
# check_resize_disk_fit.sh (terraform/modules/nat-fleet)
#
# Pre-checks, for every floor node with an explicit node_instance_type_overrides
# entry, whether that node's CURRENT total allocated disk size actually fits the
# TARGET instance type's disk allowance, before this apply lets
# linode_instance.node attempt the resize itself. Linode's own resize API
# rejects a downsize based on total allocated disk size exceeding the target
# plan's allowance -- not actual used space -- so an operator reverting an
# override back down (or shrinking instance_type on a uniform floor) can fail
# outright mid-apply with a confusing provider error, well after Terraform has
# already started applying other changes in the same run. natctl_cli's own
# `resize` command already pre-checks this and refuses with clear guidance
# (fleet.py's DiskFitError) -- this script is the same check, reused here so a
# plain `terraform apply` gets the same protection instead of only the CLI
# path having it. See node_instance_type_overrides' own variable description.
#
# -----------------------------------------------------
# Usage:
#
# Not meant to be run by hand -- invoked by main.tf's
# null_resource.check_resize_disk_fit with these env vars already set:
#   LINODE_TOKEN     - a Linode API token with read access to these instances
#   OVERRIDES_JSON    - {"<node label>": "<target instance type>", ...} --
#                        var.node_instance_type_overrides as-is
#   NODE_IDS_JSON     - {"<node label>": <linode instance id>, ...} for every
#                        node label this pool currently manages
#
# For a manual check:
#   LINODE_TOKEN=... OVERRIDES_JSON='{"lng-shared-2": "g6-dedicated-4"}' \
#   NODE_IDS_JSON='{"lng-shared-2": 12345}' ./check_resize_disk_fit.sh
#
# -----------------------------------------------------
# Best Practices:
#
# - Only checks node_ids present in OVERRIDES_JSON -- a node without an
#   override always targets the pool's own base instance_type, and if that
#   never shrinks, no resize (and no possible disk-fit failure) occurs via
#   Terraform for it at all.
# - A node_id in OVERRIDES_JSON that isn't in NODE_IDS_JSON is a brand-new
#   node being CREATED at this size, not resized -- skipped, since a create
#   has no prior disk allocation to conflict with.
# - Fails the whole `terraform apply` (non-zero exit) on any real fit
#   problem, with the exact manual-recovery steps DiskFitError's own message
#   gives an operator using natctl_cli resize -- never lets Linode's own
#   less-specific resize error be the first thing an operator sees.
# - Runs from local Python (already a dependency of this whole toolchain)
#   for exact JSON/API handling, matching verify_uploads.sh's own pattern in
#   the sibling artifacts module.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

set -eu

: "${LINODE_TOKEN:?LINODE_TOKEN must be set}"
: "${OVERRIDES_JSON:?OVERRIDES_JSON must be set}"
: "${NODE_IDS_JSON:?NODE_IDS_JSON must be set}"

python3 -c "
import json, os, sys, urllib.request, urllib.error

token = os.environ['LINODE_TOKEN']
overrides = json.loads(os.environ['OVERRIDES_JSON'])
node_ids = json.loads(os.environ['NODE_IDS_JSON'])

def api(path):
    req = urllib.request.Request(f'https://api.linode.com/v4{path}',
                                  headers={'Authorization': f'Bearer {token}'})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode())

failed = []
checked = 0
for label, target_type in overrides.items():
    linode_id = node_ids.get(label)
    if linode_id is None:
        continue  # a brand-new node being created at this size, not resized
    try:
        target_spec = api(f'/linode/types/{target_type}')
        target_disk_mb = target_spec.get('disk')
        if target_disk_mb is None:
            continue
        disks = api(f'/linode/instances/{linode_id}/disks').get('data', [])
        current_disk_mb = sum((d.get('size') or 0) for d in disks)
    except urllib.error.HTTPError as exc:
        failed.append(f'{label}: could not check disk fit -- HTTP {exc.code} from the Linode API')
        continue
    except Exception as exc:  # noqa: BLE001 -- any failure to check is a real finding, not swallowed
        failed.append(f'{label}: could not check disk fit ({exc})')
        continue
    checked += 1
    if current_disk_mb > target_disk_mb:
        failed.append(
            f'{label}: current allocated disk ({current_disk_mb} MB) exceeds {target_type}\'s disk '
            f'allowance ({target_disk_mb} MB). This is a downsize the Linode resize API will reject -- '
            f'it checks TOTAL ALLOCATED disk size, not actual used space, so this can happen even with a '
            f'mostly-empty disk if the current partition was sized larger than the target plan allows.\n'
            f'  To proceed manually:\n'
            f'    1. SSH into {label} and confirm actual used space: df -h\n'
            f'    2. Free up space if needed so used data fits comfortably within {target_disk_mb} MB.\n'
            f'    3. Shrink the disk partition to fit: linode-cli linodes disk-resize {linode_id} <disk-id> --size <MB, <= {target_disk_mb}>\n'
            f'       (or via Cloud Manager: on that instance, the Storage tab -> Resize on the disk)\n'
            f'    4. Re-run terraform apply once the disk fits.'
        )

if failed:
    print(f'Resize disk-fit check FAILED for {len(failed)} of {checked} checked node(s):', file=sys.stderr)
    for f in failed:
        print(f'  - {f}', file=sys.stderr)
    sys.exit(1)

print(f'Resize disk-fit check: all {checked} node(s) with an instance_type override fit their target plan.')
"
