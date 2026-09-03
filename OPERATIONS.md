<!--
OPERATIONS.md (repository root) -- CUSTOMER-FACING DISTRIBUTION

Day-2 operations reference for this LNG deployment: configuration
reference, common procedures, high availability, and troubleshooting.
Read README.md first for what this is and how to deploy it.

Author: Sandip Gangdhar (https://github.com/sandipgangdhar)
(c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
-->

# Operations Guide

## How this repository is built

`natctl` (the fleet controller), `natctl-cli` (the operator-facing day-2
CLI — `status`/`nodes`/`drain`/`resize`/`check-orphans`/
`set-client-config`, a separate entry point from the daemon with no
subcommands of its own), `nat-exporter` (the Prometheus exporter),
`buddy-sync` (conntrackd buddy-pair sync + BGP IP failover), and
`client-agent` (ECMP routing on private-subnet instances) are shipped as
pre-compiled, self-contained native binaries — not Python scripts. This
doesn't change how you deploy this repository: Terraform still
provisions everything, and `natctl.yaml` still configures `natctl`. The
only practical difference for the fleet-controller daemon itself is that
no node needs a Python interpreter installed — a compiled binary is
fetched (from your own Object Storage bucket, via the same mechanism as
every other config file this project uploads) and run directly.

**`natctl-cli` is distributed differently from the other four,
deliberately.** It's an operator's own tool, run by hand from wherever
you choose to operate the fleet from (your laptop, the observability
host, a node — your call) — never something a node needs automatically,
so it isn't fetched by Terraform/cloud-init the way the other four are.
Download it directly from this version's GitHub Release (the same page
this repository's Terraform config and README point you at for every
other binary), `chmod +x natctl-cli`, and run it from there — every
`natctl_cli`/`natctl-cli` command in "Common procedures" below is the
real, working command as written, invoked as `./natctl-cli <subcommand>
--config natctl.yaml ...` (no `python -m` prefix — it's a compiled
binary, not a Python module). **This was a real, live-found gap in
earlier releases of this repository** (through `v0.1.14`): only the
`natctl` daemon had a compiled binary, so every `natctl_cli` command
documented here failed outright with "command not found" — fixed as of
this release.

## `natctl.yaml` configuration reference

`natctl` reads one YAML file per environment (see `controller/natctl.example.yaml`
for a fully commented starting point). The fields you'll actually tune day
to day, per pool:

| Field | What it controls |
|---|---|
| `min_nodes` / `max_nodes` | Bounds on elastic capacity `natctl` is allowed to add/remove automatically. |
| `instance_type` | The Linode plan every elastic node in this pool gets provisioned as. |
| `conntrack_max` | Per-node connection-tracking table size. |
| `autoscale.*` | Watermarks, target ratios, cooldown, and step caps — see "Autoscaling" below. |
| `conntrack_buddy_sync_enabled` / `ip_failover_enabled` | HA layers — see "High availability" below. |
| `reserved_ip_enabled` | Fixes each node's public IP to a Linode Reserved IP (survives instance replacement) instead of an ephemeral one — for downstream IP-whitelisting. |

**Not hot-reloaded**: `natctl` reads `natctl.yaml` once, at process startup. After editing a running deployment's config, restart the service:

```bash
systemctl restart natctl
```

It takes effect starting the next reconcile pass (every `reconcile_interval_seconds`, default 15s) — no other action needed.

## Autoscaling: when it fires, and how to tune it

Every reconcile pass, three independent triggers are evaluated per pool. Any one crossing its watermark is enough to act:

| Trigger | Default watermark | Meaning |
|---|---|---|
| Conntrack utilization | ≥ 0.70 | The node's connection-tracking table is 70% full. |
| Port headroom | ≤ 0.15 | Only 15% of usable source ports (per destination) remain free. |
| Throughput ratio | ≥ 0.85 | 85% of the node's real, per-instance-type network bandwidth capacity (queried live from Linode's own API). |

A metric must stay past its threshold for `sustained_breach_passes` (default 2) consecutive passes before it's trusted enough to act on — one noisy reading doesn't trigger a scale event on its own. Once triggered, the resulting scale-out/scale-in is capped as a fraction of current capacity (`max_scale_out_step_fraction`/`max_scale_in_step_fraction`) and followed by a cooldown (`cooldown_seconds`, default 300s) during which no further scaling decision is evaluated.

To change any of these, edit the pool's `autoscale:` block in `natctl.yaml`:

```yaml
pools:
  shared:
    autoscale:
      conntrack_high_watermark: 0.70
      port_headroom_low_watermark: 0.15
      throughput_high_watermark: 0.85
      cooldown_seconds: 300
      sustained_breach_passes: 2
      target_conntrack_ratio: 0.50
      max_scale_out_step_fraction: 1.0
      max_scale_in_step_fraction: 0.5
```

then `systemctl restart natctl` (see "Not hot-reloaded" above).

**Two different log lines, two different meanings.** `natctl`'s logs distinguish a real, load-driven scale-out from capacity added to compensate for an unhealthy Terraform-managed node (which `natctl` never deletes or replaces on its own — see "High availability" below):

```
pool shared: scale-out triggered (conntrack=0.90), sustained=['conntrack'], required=5 node(s), adding 1 (step-capped)
pool shared: 1 healthy node(s) of 3 total -- below min_nodes=3, provisioning elastic capacity to reach the floor
```

The second line means something is actually unhealthy, not just busy — go find out which node and why (see "Troubleshooting" below).

## High availability

Four layered mechanisms, each closing a specific gap:

1. **Client-side ECMP** (always on). Survives a node dying — but a single in-flight TCP connection on that node is lost. No NAT design avoids this on its own.
2. **Conntrack buddy-pair sync** (opt-in: `conntrack_buddy_sync_enabled`). Mirrors connection-tracking state between paired nodes. On its own this does nothing useful — the dead node's IP still isn't reachable — it only pays off combined with layer 3.
3. **Buddy IP failover** (opt-in: `ip_failover_enabled`). FRR (FRRouting) plus Akamai's BGP-based IP Sharing — every node is bidirectionally both its own primary announcer and its buddy's secondary. `ip_failover_auto_configure` gates the actual Linode IP-share API call and **defaults to true**: `natctl` authorizes each pairing itself as it forms. This matters more than it might look — without a registered IP-share, Akamai's BGP route reflectors reject the session outright (TCP connects, but every BGP OPEN gets an immediate close), so failover doesn't degrade without it, it simply never comes up. Set it `false` only if you want to authorize the first pairing yourself via Cloud Manager or `linode-cli networking ip-share` before trusting `natctl` with it.
4. **Odd node counts**: with 3+ healthy nodes and an odd count, one node ("the hub") backs up two buddies instead of one — no node is ever left fully unprotected.

**Zombie-node handling**: `natctl` checks *healthy* node count against `min_nodes`, not raw count. A persistently-unhealthy elastic node is drained and replaced automatically after `unhealthy_replace_after_seconds`. A Terraform-managed floor node is **never** auto-touched — `natctl` instead provisions extra elastic capacity to compensate, and the pool running above its nominal floor with one node marked unhealthy is expected, not itself an error.

**Turning on HA deliberately**, in order:
1. Set `conntrack_buddy_sync_enabled = true` and redeploy — starts mirroring state, nothing user-visible yet.
2. Set `ip_failover_enabled = true` (`ip_failover_auto_configure` stays at its default of `true`, so no separate action is needed for `natctl` to authorize pairings itself).
3. Verify a pairing converged (check the roster's `ip_failover_buddy_ips` field, or the `nat_conntrack_buddy_paired` Grafana panel) and that BGP actually established (`vtysh -c "show bgp summary"` should show `Established`, not `Active`) before trusting it.
4. Only then run a real failover drill (`acceptance-tests/checks/check_04_ip_failover_bgp.py`) to prove it end to end.

If you'd rather authorize the first pairing yourself before `natctl` touches it, set `ip_failover_auto_configure = false`, run `linode-cli networking ip-share` by hand for both directions, watch it converge, then flip it back to `true`.

## Changing instance types

**Resizing an existing node (floor or elastic) — the safe, in-place way**, via the operator CLI (handles drain → resize → rejoin for you, never deletes the node):

```bash
./natctl-cli resize --config natctl.yaml --pool shared \
  --node-id shared-3 --instance-type g6-dedicated-8
```

If the resized node is a **Terraform floor node**, the command prints the exact `node_instance_type_overrides` block to add to your `.tfvars` — do this immediately, or the next `terraform apply` will see drift and revert the resize.

**Changing the base type** (what future nodes get provisioned as): edit `nat_instance_type` in `terraform.tfvars` (floor) or the pool's `instance_type` in `natctl.yaml` + restart `natctl` (elastic) — neither retroactively resizes existing nodes.

## Common day-2 procedures

**Raise the floor** (permanent capacity increase):
```bash
terraform apply -var 'shared_pool_floor_nodes=<n>'
```

**Manually drain and remove an elastic node**:
```bash
./natctl-cli drain --config natctl.yaml --pool shared --node-id shared-elastic-103
```
Refuses to drain a Terraform floor node — lower the floor via Terraform instead.

**Onboarding a client instance**: this project doesn't create client instances -- create yours through your own automation (Terraform, an autoscaling group, hand-provisioned, whatever you already use), attach its VLAN interface, then run `scripts/install-nat-client.sh --vlan-iface <iface> --vlan-ip <address>/<prefix> --natctl-url <roster-url>` against it. The script applies the address (after a live ARP-probe check that it isn't already in use by a NAT node or another client) and installs/starts client-agent if the instance has no internet path of its own. Pick the address from inside your pool's reserved window (`client_static_vlan_reserved` in `.tfvars`) so it can never collide with a future elastic node.

**Rolling security patches**: patch elastic nodes first via drain-and-replace. For floor nodes, patch one at a time — drain it manually (there's no automatic drain for a floor node), patch/reboot, confirm `/healthz` passes again, move to the next. Never patch every node in a pool simultaneously.

**Checking fleet status**:
```bash
./natctl-cli status --config natctl.yaml
./natctl-cli nodes --config natctl.yaml --pool shared
```

## HA fleet health check

Run through this whenever you're asked "is this fleet actually highly available," or periodically as a standing check:

1. **Enough healthy nodes?** `./natctl-cli status`, or the roster's `healthy_count` vs `node_count`.
2. **Buddy-pair sync actually paired?** Grafana's "Buddy-Paired Nodes" panel, or `nat_conntrack_buddy_paired` (1/0 per node). `0` on a node in an otherwise-healthy pool means genuinely unpaired.
3. **BGP sessions actually established?** "BGP Peers Established" vs "BGP Peers Configured" should match; `nat_bgp_peer_state` should be `1` per peer.
4. **Every node announcing its own IP?** `nat_ip_failover_self_announced` should be `1` on every node with `ip_failover_enabled`.
5. **Real buddy-backup coverage?** `nat_ip_failover_buddy_count` — `1` on a normal pair, `2` on an odd-node triangle's hub, `0` only if IP failover isn't configured for that node.
6. **Would a real failover actually work?** Steps 1–5 tell you the mechanism is armed; `acceptance-tests/checks/check_04_ip_failover_bgp.py` is the real drill (genuinely disruptive — run in a maintenance window).

## Monitoring

Prometheus scrapes every node's `:9200/metrics` (target list tracks autoscaling automatically) plus `natctl`'s own `:8099/metrics` for fleet-wide figures. Grafana dashboard and alert rules are provisioned automatically by the observability host.

Key alerts to know before you're on call: `NATConntrackTableNearFull`/`Critical`, `NATPortExhaustionImminent`, `NATNodeDown`/`Unhealthy`, `NATPoolBelowFloor`, `NATHighDropRate`, `NATConntrackBuddyUnpaired`, `NATBGPSessionNotEstablished`, `NATIPFailoverSelfNotAnnounced`, `NATAutoscaleCeilingReached`.

## Troubleshooting

| Symptom | Most likely cause | Where to look |
|---|---|---|
| A client instance has no default route / can't reach the internet | `client-agent` not running, or its roster fetch is failing | `systemctl status lng-client-agent`, then its journal |
| One node stops receiving any new traffic | It failed its own `/healthz` and client-agent routed around it — working as designed | That node's `nat-exporter` journal — why is `/healthz` unhealthy? |
| A node was unhealthy, recovered, but hasn't rejoined | client-agent's roster-refresh interval governs re-discovery of a *recovered* node — can lag behind how fast removal happened | client-agent journal for "healthy node set changed" lines |
| A client instance has no route at all, even after recovering | client-agent's own health tracking got stuck believing zero nodes are healthy | `ip nexthop show` (empty is the tell); `systemctl restart lng-client-agent` forces a fresh rebuild |
| BGP IP failover doesn't happen when a node's `frr` stops | Session never established, or IP Sharing was never authorized for this pairing | `NATBGPSessionNotEstablished`/`NATIPFailoverSelfNotAnnounced` alerts; confirm the manual Cloud Manager authorization step happened |
| An alert fires but the metric looks fine moments later | Working as designed — sustained-breach gating means a transient spike alone shouldn't drive action, but a single noisy evaluation can still fire the alert rule itself | Check the breach-streak panel, not just the instantaneous value |
| SSH into a NAT node's VLAN address hangs | Working as designed — SSH is deliberately excluded from the VLAN interface | Use the node's VPC or public address instead |

**Escalation order** (no vendor support line for self-run infrastructure):
1. A private-subnet instance's `client-agent` isn't running, or can't reach `natctl` — check this first, it's the most common issue.
2. `natctl`'s Linode API token has expired or lost a scope.
3. `min_nodes`/`max_nodes` are misconfigured for actual load.

## API token

See `docs/API-TOKEN-SETUP.md` for exactly which scopes to grant and how to create a least-privilege token via Cloud Manager or `linode-cli`.
