<!--
README.md (repository root) -- CUSTOMER-FACING DISTRIBUTION

Top-level entry point for the LNG customer distribution: what LNG is,
why it exists, its core capabilities, repository layout, and a
copy-paste quickstart. See OPERATIONS.md for day-2 operations, config
reference, and troubleshooting.

This repository ships the natctl control plane and the nat-exporter/
buddy-sync/client-agent runtime agents as pre-compiled native binaries,
not Python source -- see OPERATIONS.md's "How this repository is built"
section for what that means for you operationally (short version:
nothing changes about how you deploy or operate it; a compiled binary is
fetched and run instead of a script).

Author: Sandip Gangdhar (https://github.com/sandipgangdhar)
(c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
-->

# Linode NAT Gateway (LNG)

A production-grade, highly available, horizontally scalable NAT gateway for **Akamai Cloud (Linode)**, built entirely on Akamai Cloud's native compute and networking primitives — Compute Instances, VPC, VLAN, Cloud Firewall, and BGP-based IP Sharing. LNG is designed to match, and in several areas exceed, the operational characteristics of AWS NAT Gateway and GCP Cloud NAT, while giving you full transparency and control over the infrastructure layer.

Status: production-track, self-operated infrastructure you deploy into your own Akamai Cloud account — not a black-box managed service.

**Design: three-interface active-active fleet with bidirectional buddy IP failover.** Every NAT node is independently active all the time — there are no active/passive pairs and no idle standby capacity. A private-subnet instance's traffic is spread via ECMP across every healthy node in its pool, so a single heavy tenant can burst across the whole fleet instead of being capped at one pair. The private client fleet runs over an Akamai Cloud VLAN, with each node carrying a dedicated interface for it; buddy-pair conntrack sync is backed by real, bidirectional BGP-based IP failover built on FRRouting and Akamai Cloud's native IP Sharing capability, so a node's buddy can take over both its connection state and its public IP.

## Why this exists

Akamai Cloud gives every VPC-member instance a private interface and, per instance, a 1:1 NAT to a public IP — a clean, simple building block. Enterprises that need to put a whole private subnet behind a **small, shared, static pool of egress IPs** — for partner/vendor firewall allow-lists, or centralized, auditable egress under a compliance regime — need one more layer on top of that. LNG builds exactly that layer, entirely from Akamai Cloud's own primitives: VPC, VLAN, Compute Instances, Cloud Firewall, and BGP-based IP Sharing. Nothing in this project depends on infrastructure outside Akamai Cloud.

## What it is

A pool of independently-active NAT nodes per zone, each owning its own public egress IP(s). Private-subnet instances run a small agent (`client-agent`) that spreads their outbound traffic across every currently-healthy node in the pool via ECMP — ordinary Linux multipath routing, no shared floating IP required. A control plane (`natctl`) continuously health-checks the fleet, serves the current node roster to every client-agent, and scales pools automatically (bounded by configured floors/ceilings) as load grows or shrinks. A purpose-built Prometheus exporter exposes conntrack, port-allocation, PPS, and throughput metrics per pool, per node, and per IP — deeper visibility than either hyperscaler gives you.

## Core capabilities

- **High availability**: every node is active — a node failure affects only the ~1/N of connections that were hashed to it, with the rest of the fleet unaffected. No idle standby capacity, no failover cliff. Client-agent detects and routes around a dead node in seconds, independent of the control plane's own availability. Opt-in conntrack buddy-pair sync, paired with opt-in BGP-based buddy IP failover, lets a buddy take over both a dead node's connection state *and* its public IP — a node that's "running" but failing its own health check is drained and replaced automatically. See OPERATIONS.md's "High availability" section for exactly what this does and doesn't protect against.
- **Horizontal scale-out**: a Terraform-managed floor (baseline capacity) plus natctl-managed elastic capacity above it, fully automatic within configured `min_nodes`/`max_nodes` bounds. A single tenant's traffic spreads across the *entire pool*, not one pair.
- **Multi-tenant isolation, when you want it**: default shared pool for cost efficiency, or dedicated pools with reserved capacity for tenants that need isolation — both are the same Terraform module, just a different `pool_name`.
- **Vertical scale**: swap instance plans, up to Akamai Cloud's 40 Gbps in / 12 Gbps out dedicated-CPU plans.
- **Multi-IP egress**: each node can hold multiple public egress IPs to multiply available ephemeral ports (55K connections per IP per destination, same ceiling AWS documents).
- **Static VLAN addressing for the client fleet**: since Linode VLANs carry no address-assignment mechanism of their own, a client instance's VLAN address is applied by `scripts/install-nat-client.sh` (run against an instance your own automation already created), with a live ARP-probe preflight guarding against reusing an address already in use. See OPERATIONS.md "Onboarding a client instance".
- **Security**: default-deny Cloud Firewall templates on public/VPC interfaces, egress-only posture, minimal node-side attack surface, node-level flood/rate-limiting.
- **Rich observability**: Prometheus metrics for NAT (conntrack utilization, port exhaustion, PPS, throughput, drop counters, node health) — plus fleet-aware scraping that tracks autoscaling automatically, pre-built Grafana dashboards, and alert rules.
- **Infrastructure as code**: full Terraform module set for Akamai Cloud; reproducible, auditable, GitOps-friendly, and fully owned by you.

## Repository layout

```
terraform/                 Terraform modules & example environment (Linode provider)
  modules/vpc/               VPC + subnets + firewall rules (NAT-node + control-plane)
  modules/nat-fleet/         One pool of N independently-active, 3-interface NAT nodes (public/VPC/VLAN)
  modules/observability/     Prometheus + Grafana + natctl, all on one instance
  modules/artifacts/         Uploads compiled binaries + config to Object Storage
  environments/example/      Wired-up example: shared pool + a dedicated-tenant pool
ansible/cloud-init/        Cloud-init user-data rendered by Terraform
ansible/templates/         nftables ruleset, Prometheus/Grafana/Docker Compose configs
client-agent/               Compiled binary + systemd unit: ECMP routing on private-subnet instances
buddy-sync/                 Compiled binary + systemd unit: conntrackd buddy-pair sync + BGP IP failover
controller/                 Compiled natctl binary + systemd unit + natctl.yaml reference (natctl.example.yaml)
exporter/nat_exporter/      Compiled Prometheus exporter binary + systemd unit
dashboards/                 Grafana dashboard JSON
alerts/                     Prometheus alerting rules
docs/                       API token setup instructions
acceptance-tests/           Post-deploy checks you can run against your own live deployment
scripts/                    Load-test and day-2 operational scripts
OPERATIONS.md               Day-2 operations, configuration reference, troubleshooting
```

## Quickstart

```bash
# 1. Provision the example environment (shared pool + example dedicated pool +
#    an observability host running Prometheus + Grafana + natctl, the fleet
#    controller).
cd terraform/environments/example
cp terraform.tfvars.example terraform.tfvars   # fill in your Linode API token, region, SSH key
# See docs/API-TOKEN-SETUP.md for exactly which token scopes to grant --
# a least-privilege token, not an unscoped one, in under 5 minutes.
terraform init
terraform apply

# 2. Configure a client instance you already created (through your own
#    automation -- this project doesn't create client instances, see
#    OPERATIONS.md "Onboarding a client instance"): apply its static
#    VLAN address and install client-agent, in one step.
./scripts/install-nat-client.sh --vlan-iface eth0 --vlan-ip <address>/<prefix> \
  --natctl-url "$(terraform -chdir=terraform/environments/example output -raw natctl_roster_url_shared)"

# 3. Open Grafana
terraform -chdir=terraform/environments/example output grafana_url
```

See OPERATIONS.md for the full day-2 reference: how autoscaling works and how to tune it, changing instance types, HA health checks, and troubleshooting. `acceptance-tests/` is a ready-to-run suite that validates your deployment end to end after you apply — see `acceptance-tests/README.md`.

## Requirements

- An Akamai Cloud (Linode) account with API access (Personal Access Token — see `docs/API-TOKEN-SETUP.md` for exactly which scopes to grant)
- Terraform >= 1.6, Linode provider `~> 2.x`
- Linux kernel 5.19+ on private-subnet client instances recommended (resilient ECMP nexthop groups); older kernels fall back automatically with a logged warning
- If enabling buddy IP failover (`ip_failover_enabled`), confirm your Akamai Cloud region supports BGP-based IP Sharing and look up its data-center ID — see OPERATIONS.md "Turning on HA deliberately"

No Python installation is required anywhere in this deployment — every node fetches and runs a self-contained compiled binary at boot.

## Honest limits

LNG is not a zero-ops replacement for AWS NAT Gateway or GCP Cloud NAT — it trades managed-service simplicity for transparency, cost, and control, and that trade should be made deliberately. See OPERATIONS.md's "High availability" section for exactly what LNG's HA model does and doesn't protect against.

## License

Proprietary — see `LICENSE`. Contact Sandip Gangdhar (https://github.com/sandipgangdhar) for licensing questions.
