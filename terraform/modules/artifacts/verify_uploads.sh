#!/bin/sh
# verify_uploads.sh (terraform/modules/artifacts)
#
# Confirms every artifact this module just uploaded to Object Storage actually
# arrived intact, by comparing each object's own server-computed ETag (read
# back over HTTP, never trusted from Terraform's own write call) against the
# local source file's MD5. Run as a null_resource's local-exec provisioner
# from this module's main.tf -- see that file's own comment on
# null_resource.verify_artifact_uploads for why this exists: Terraform's
# etag = filemd5(...) argument only ever triggers a re-upload on a local
# content change, it never confirms the bytes that actually landed in Object
# Storage match what was sent. Without an independent check, a corrupted or
# truncated upload (a network blip mid-PUT, a provider-side bug) succeeds at
# the API level and is never re-tried -- every node then fetches that bad
# object at boot, and lng-fetch-verified.sh's own SHA-256 check (the OTHER
# half of this fix, in the cloud-init templates) is the only thing left to
# catch it, at boot time on every single node instead of once, here, at apply
# time.
#
# For a plain (non-multipart) PUT, Linode's Object Storage is S3-compatible
# and returns an ETag that IS the MD5 of what it received. A multipart
# upload's ETag has a different format (a hash of the parts' hashes,
# followed by "-<part count>") and cannot be
# compared this way -- this script skips (warns, does not fail) any object
# whose ETag looks multipart, rather than reporting a false mismatch. None of
# this module's own objects are large enough to trigger the Linode Terraform
# provider's own multipart threshold as of this writing, so every object is
# expected to hit the plain-MD5 path in practice.
#
# -----------------------------------------------------
# Usage:
#
# Not meant to be run by hand -- invoked by main.tf's
# null_resource.verify_artifact_uploads with these env vars already set:
#   BASE_URL          - e.g. https://<bucket>.<region>.linodeobjects.com
#   PREFIX            - the module's own object-key prefix (local.prefix)
#   VERIFICATION_JSON - {"<key relative to PREFIX>": "<expected md5>", ...}
#
# For a manual check: BASE_URL=... PREFIX=... VERIFICATION_JSON='{"exporter.py": "..."}' ./verify_uploads.sh
#
# -----------------------------------------------------
# Best Practices:
#
# - Every object is public-read (required so nodes can fetch it at boot with
#   a plain, unauthenticated curl -- see main.tf's own comments), so a plain
#   HTTP HEAD is enough; this script needs no Object Storage credentials of
#   its own.
# - Fails the whole `terraform apply` (non-zero exit) on ANY real mismatch or
#   unreachable object -- a corrupted upload must never pass silently.
# - Runs from local Python (already a dependency of this whole toolchain,
#   including the ephemeral CI runner this pipeline builds on) rather than
#   parsing curl's own output, to keep ETag/JSON handling exact.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

set -eu

: "${BASE_URL:?BASE_URL must be set}"
: "${PREFIX:?PREFIX must be set}"
: "${VERIFICATION_JSON:?VERIFICATION_JSON must be set}"

python3 -c "
import json, os, sys, urllib.request, urllib.error

base_url = os.environ['BASE_URL']
prefix = os.environ['PREFIX']
verification = json.loads(os.environ['VERIFICATION_JSON'])

failed = []
skipped = []
for key, expected_md5 in verification.items():
    url = f'{base_url}/{prefix}/{key}'
    req = urllib.request.Request(url, method='HEAD')
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            etag = resp.headers.get('ETag', '').strip('\"')
    except urllib.error.HTTPError as exc:
        failed.append(f'{key}: HTTP {exc.code} fetching {url} -- the object may not have actually been created')
        continue
    except Exception as exc:  # noqa: BLE001 -- any failure to reach it is a real finding, not swallowed
        failed.append(f'{key}: could not fetch ETag from {url} ({exc})')
        continue
    if not etag:
        failed.append(f'{key}: {url} answered with no ETag header at all')
        continue
    if '-' in etag:
        skipped.append(f'{key}: ETag {etag} looks like a multipart upload -- skipping (not comparable to a plain MD5)')
        continue
    if etag.lower() != expected_md5.lower():
        failed.append(f'{key}: remote ETag {etag} does not match the local source file\'s own MD5 {expected_md5} -- the upload may have been corrupted or truncated in transit')

for s in skipped:
    print(f'WARNING: {s}', file=sys.stderr)

if failed:
    print(f'Object Storage upload verification FAILED for {len(failed)} of {len(verification)} object(s):', file=sys.stderr)
    for f in failed:
        print(f'  - {f}', file=sys.stderr)
    sys.exit(1)

print(f'Object Storage upload verification: all {len(verification) - len(skipped)} checkable object(s) (of {len(verification)} total) match their local source.')
"
