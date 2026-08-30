<!--
API-TOKEN-SETUP.md (docs)

Step-by-step instructions for creating a least-privilege Linode/Akamai
Cloud API Personal Access Token for LNG -- what scope each permission
maps to (grounded in the actual resources this codebase creates and
manages, not guessed), and how to create the token via both the Cloud
Manager web console and the linode-cli tool. Read this before your first
`terraform apply` in a production account; README.md's quickstart and
docs/RUNBOOK.md assume a token scoped exactly as described here.

Author: Sandip Gangdhar (https://github.com/sandipgangdhar)
(c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
-->

# API token setup

LNG's Terraform and `natctl` both authenticate to the Akamai Cloud (Linode) API with a **Personal Access Token (PAT)**. This document tells you exactly which permission scopes that token needs, why each one is needed, and how to create it. Every scope below was derived by checking which Linode API resources this codebase's own Terraform (`resource` blocks, not `data` sources) and Python control plane actually create, modify, or delete — not assumed from a generic "give it broad access" default.

## Why this matters

A token with `*` (unscoped, full account access) will work, but it is not least-privilege: it can also read/modify every other resource on your account — billing, other projects' instances, Kubernetes clusters, everything — regardless of whether LNG ever touches them. If this token ever leaks (a compromised CI runner, an accidentally-committed file, a misconfigured log), the blast radius should be limited to what LNG actually needs, not your whole account. This is a real, live-confirmed finding from this project's own security review (`roadmap/M2-security.md`, test case 2.9) — most tokens found registered on the account used for this project's own live testing were unscoped, and a dedicated, scoped token was created and switched to as the fix.

## The exact scopes LNG needs

| Scope | Level | Why |
|---|---|---|
| `linodes` | `read_write` | Every Compute Instance LNG creates and manages — NAT nodes (`terraform/modules/nat-fleet`), client instances (`terraform/modules/client-fleet`), the observability host (`terraform/modules/observability`) — plus `natctl`'s own elastic-node provisioning/deletion and the `natctl_cli resize`/`drain` operator commands. |
| `firewall` | `read_write` | The three Cloud Firewalls this project creates and manages (`terraform/modules/vpc`'s `nat_node`, `control_plane`, and `client` firewalls). |
| `ips` | `read_write` | Reserved IP creation/release (`linode_networking_ip`, opt-in `reserved_ip_enabled`), extra egress IPs (`linode_instance_ip`), and BGP-based IP Sharing calls (`natctl`'s buddy IP failover, `docs/ARCHITECTURE.md` §3.6). |
| `object_storage` | `read_write` | Uploading exporter/buddy-sync/natctl source and per-node config to Object Storage at boot-fetch time (`terraform/modules/artifacts`, `controller/natctl/object_storage.py`) — see that module's own header comment for why files are fetched at boot instead of embedded in cloud-init. |
| `vpc` | `read_only` | LNG **reuses an existing VPC and its subnets** — see `docs/RUNBOOK.md`'s "Bring your own VPC" section — it never creates, modifies, or deletes a VPC or subnet, only reads one via a Terraform `data` source. `read_write` is not needed and should not be granted. |
| `events` | `read_only` | **Required for `terraform destroy`/`apply` to actually complete** — real gap found live, 2026-08-30: the Linode Terraform provider polls `/account/events` internally to confirm an async operation (instance create/delete, etc.) has finished, independent of whichever specific resource scope (`linodes`, `firewall`, ...) authorized the operation itself. Without this scope, `terraform destroy` issues the delete calls but then fails with `"failed to initialize event poller: ... [401] Your OAuth token is not authorized to use this endpoint"` before confirming completion — the delete may or may not have actually gone through, leaving Terraform state inconsistent with real infrastructure. Confirmed missing from this project's own least-privilege token until this finding; add it. |

Every other scope category (`account`, `domains`, `nodebalancers`, `lke`, `databases`, `stackscripts`, `longview`, `images`, and so on) should be **left unset entirely** — LNG never calls any API under those categories. Do not grant `account` access "just in case"; it exposes billing and user-management endpoints this project has no use for.

The full, authoritative scope reference (in case Akamai adds or renames a category) is: <https://techdocs.akamai.com/linode-api/reference/get-started#oauth-reference>.

## Creating the token: Cloud Manager (web console)

1. Log into Cloud Manager and open **your username menu (top right) → My Profile → API Tokens**.
2. Click **Create a Personal Access Token**.
3. Give it a distinctive **Label** — something that identifies it as this project's automation token, e.g. `lng-<environment>-automation` (matching this project's own `label` Terraform variable is a good convention, so a token and the environment it drives are easy to correlate later).
4. Set an **Expiry** appropriate for your operational model. Infrastructure automation typically can't handle an interactive re-auth prompt, so "Never" or a long expiry with a calendar reminder to rotate it are both reasonable — pick deliberately, don't default to whichever is fastest to click through.
5. For each scope row in the table above, set the **exact** access level shown (`Read/Write` or `Read Only`) — leave every other row at **None**.
6. Click **Create Token**. **Copy the token value immediately** — Cloud Manager shows it exactly once and cannot display it again; if you lose it, you must create a new one.

## Creating the token: `linode-cli`

Equivalent, non-interactive version of the same steps:

```bash
linode-cli profile token-create \
  --label "lng-<environment>-automation" \
  --scopes "linodes:read_write,firewall:read_write,ips:read_write,object_storage:read_write,vpc:read_only,events:read_only" \
  --text --no-headers --format token
```

This prints the raw token value to stdout and nothing else. Capture it directly into wherever you're going to store it (see below) — **never** let it land in shell history, a log file, or a terminal session someone else can scroll back through. If you're piping this into a script, redirect stdout straight to the destination rather than assigning it to a variable you might later echo or print for debugging.

## Where the token goes once you have it

This project reads the token from two different places, and neither should ever contain it in a form that gets committed to git:

- **Terraform**: the `linode_token` variable in `terraform/environments/example/terraform.tfvars` (gitignored — confirm with `git check-ignore terraform.tfvars` before your first apply), or passed at apply time as the `TF_VAR_linode_token` environment variable, sourced from wherever you keep the value (a password manager, `linode-cli`'s own config file, a CI secret store) rather than hardcoded in a script.
- **`natctl`**: the `LINODE_TOKEN` environment variable, or a value in `/etc/natctl/env` (mode `0600`, root-only) on the control-plane host — **never** in `natctl.yaml` itself. `controller/natctl/config.py`'s `resolved_token()` checks exactly these two places, in that order.

If you're managing multiple Akamai Cloud accounts or projects from one workstation, `linode-cli` supports multiple named profiles in `~/.config/linode-cli` — giving this project's token its own profile (rather than overwriting your personal default profile) keeps day-to-day `linode-cli` usage for other work unaffected by this project's own credential.

## Verifying the token actually works and is actually scoped correctly

Don't just trust that scope names were accepted — a typo'd scope name is silently dropped by the API rather than rejected, so a token can look "created successfully" while missing a permission you thought you granted. Confirm both:

```bash
# Confirm the scopes Linode actually recorded, not just what you typed:
linode-cli profile tokens-list --json | python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if t['label'] == 'lng-<environment>-automation':
        print(t['scopes'])
"

# Confirm it can actually do LNG's real work:
LINODE_TOKEN=<value> linode-cli linodes list        # linodes:read_write
LINODE_TOKEN=<value> linode-cli firewalls list       # firewall:read_write
LINODE_TOKEN=<value> linode-cli vpcs list            # vpc:read_only
curl -s -H "Authorization: Bearer <value>" https://api.linode.com/v4/object-storage/buckets  # object_storage:read_write
```

A least-privilege token that's missing a scope it needs fails loudly and specifically (a 401/403 on the exact call that needed it) — much easier to diagnose than an unscoped token that "just works" everywhere, including places it shouldn't.
