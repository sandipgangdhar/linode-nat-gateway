<!--
docs/OPERATIONS.md -- CUSTOMER-FACING DISTRIBUTION

Day-2 operations reference for this LNG deployment: configuration
reference, common procedures, high availability, and troubleshooting.
Read ../README.md first for what this is and how to deploy it.

Author: Sandip Gangdhar (https://github.com/sandipgangdhar)
(c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
-->

# Operations Guide

## How this repository is built

`natctl` (the fleet controller), `natctl-cli` (the operator-facing day-2
CLI — `status`/`nodes`/`drain`/`resize`/`check-orphans`/
`set-client-config`/`set-pool-scaling`/`set-vpc-sibling-subnets`, a
separate entry point from the daemon with no subcommands of its own —
see `CLI-GUIDE.md` for the complete reference), `nat-exporter` (the
Prometheus exporter),
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
real, working command as written, invoked as `./natctl-cli --config
natctl.yaml <subcommand> ...` (`--config` is a top-level flag, so it
comes before the subcommand, not after; no `python -m` prefix — it's a
compiled binary, not a Python module). **This was a real, live-found gap in
earlier releases of this repository** (through `v0.1.14`): only the
`natctl` daemon had a compiled binary, so every `natctl_cli` command
documented here failed outright with "command not found" — fixed as of
this release.

## `natctl.yaml` configuration reference

`natctl` reads one YAML file per environment (see `natctl.example.yaml`,
in this same `docs/` folder, for a fully commented starting point
covering every field below with real example values). This section is
the complete field-by-field reference;
"How to update any field" right after it is the actual step-by-step
procedure for changing one on a live deployment.

**Not hot-reloaded**: `natctl` reads this file once, at process startup.
Editing it alone changes nothing — the running process keeps using
whatever it loaded at boot until it's restarted. Three specific fields
(`min_nodes`/`max_nodes`, the whole-environment `vpc_sibling_subnet_cidrs`,
and the `client_fallback_probe_*` pair) are the exception: they're also
mirrored into a small live Object Storage object every natctl instance
re-reads every reconcile pass, and `natctl-cli`'s `set-pool-scaling` /
`set-vpc-sibling-subnets` / `set-client-config` change them fleet-wide
with no restart at all — see `CLI-GUIDE.md`. Every other field below
needs the edit-and-restart procedure.

### Global settings (top level, outside `pools:`)

| Field | Type | Default | What it does |
|---|---|---|---|
| `reconcile_interval_seconds` | int | `15` | How often the background loop runs: discover nodes, health-check, pair buddies, evaluate autoscale. Lower = faster reaction, more Linode API calls. |
| `prometheus_url` | string | *(required)* | Where natctl queries Prometheus for the real per-node conntrack/port/throughput metrics autoscaling decisions depend on. |
| `file_sd_path` | string or omit | *(unset)* | Local disk path to write a Prometheus file_sd target list to after every reconcile pass. Leave unset if Prometheus runs on a different host than natctl — use `GET /file_sd` over HTTP instead (natctl's roster API already serves the same data that way). |
| `vpc_sibling_subnet_cidrs` | list of strings | `[]` | **Live-overridable — see `CLI-GUIDE.md`'s `set-vpc-sibling-subnets`.** The whole-VPC sibling-subnet list; Terraform keeps this current automatically on every `apply`, rarely hand-edited. |

### `api:` block — the roster HTTP API

| Field | Type | Default | What it does |
|---|---|---|---|
| `listen_host` | string | `0.0.0.0` | Address the roster HTTP API binds to. |
| `listen_port` | int | `8099` | Port the roster API listens on — must match every client/buddy-sync `NATCTL_ROSTER_URL` and every `natctl-cli --natctl-url` pointed at this instance. |
| `client_agent_bin_url` | string | `""` | **Terraform-managed — do not hand-edit.** Object Storage URL of the compiled `client-agent` binary, fetched once at natctl's own startup and served from `GET /agents/client-agent` for `vlan_only`/`vpc_vlan` clients with no other internet path. |
| `client_agent_bin_cache_path` | string | `/opt/lng-agents/client-agent` | Where natctl caches that fetched binary on local disk. Rarely changed. |
| `client_agent_source_url` / `client_agent_source_cache_path` | string | `""` / `/opt/lng-agents/client-agent.py` | **Terraform-managed.** Source-mode sibling of the two fields above — unused in this repo, which only ever ships compiled binaries. |
| `install_nat_client_script_url` | string | `""` | **Terraform-managed.** Object Storage URL of `install-nat-client.sh` itself, fetched once and served from `GET /agents/install-nat-client.sh` — lets a brand-new client bootstrap with one `curl` against the fleet's own VLAN/VPC instead of already needing a copy of the script. |
| `install_nat_client_script_cache_path` | string | `/opt/lng-agents/install-nat-client.sh` | Where that fetched script is cached on local disk. |

### `linode:` block

| Field | Type | Default | What it does |
|---|---|---|---|
| `api_base` | string | `https://api.linode.com/v4` | Base URL for the Linode API. Only change for a non-default endpoint. |
| `token` | string or omit | *(unset)* | **Leave this unset.** natctl resolves the token from the `LINODE_TOKEN` environment variable (set in `/etc/natctl/env`, mode 0600) if this field is empty — never put a real token directly in `config.yaml`, which is typically more widely readable and, under `natctl_on_node_enabled`, copied identically to every node. |

### `leader_election:` block — only meaningful under `natctl_on_node_enabled`

Omit this whole block entirely in single-dedicated-host mode (the
default) — there's nothing to elect with one instance.

| Field | Type | Default | What it does |
|---|---|---|---|
| `enabled` | bool | `false` | Turns on STONITH-style leader election across every instance of natctl running this pool. |
| `object_storage_endpoint` / `object_storage_bucket` / `object_storage_key` | string | `""` / `""` / `natctl/leader-lease.json` | Where the shared leader-lease record lives. `object_storage_key` gets a per-pool suffix automatically (e.g. `natctl/leader-lease-common.json`) — leadership is always scoped per pool, never fleet-wide. |
| `object_storage_access_key` / `object_storage_secret_key` | string | `""` / `""` | **Prefer the `NATCTL_OBJECT_STORAGE_ACCESS_KEY`/`NATCTL_OBJECT_STORAGE_SECRET_KEY` environment variables instead** (same `/etc/natctl/env` treatment as `LINODE_TOKEN`) — these fields exist for completeness but shouldn't hold a real secret in a file copied to every node. |
| `lease_ttl_seconds` | float | `45.0` | How long a claimed leadership lease is valid before it's considered expired. |
| `election_jitter_max_seconds` | float | `10.0` | Random delay before a node attempts to claim leadership, to avoid every node racing for it at the exact same instant. |
| `fence_confirm_timeout_seconds` | float | `60.0` | How long a new leader waits for confirmation that the previous leader was actually powered off before proceeding. |
| `renewal_retry_attempts` / `renewal_retry_backoff_seconds` | int / float | `2` / `1.0` | Bounded retry on the lease-store read/renewal path. |
| `liveness_probe_timeout_seconds` | float | `3.0` | Timeout for the pre-fence check of whether the previous leader's own roster API still answers. |

### Per-pool: placement and identity (`pools.<name>.*`)

Set once at initial deployment, matched 1:1 against this pool's
Terraform module call (`terraform/environments/example/main.tf`'s
`pools` map). **Changing these on a live pool without also changing the
matching Terraform variable creates drift** — floor nodes and
natctl-provisioned elastic nodes in the same pool must agree, or buddy
pairing/BGP failover/VLAN routing breaks in confusing, inconsistent
ways.

| Field | Type | What it does |
|---|---|---|
| `region` | string | Linode region this pool's nodes are created in. |
| `vpc_id` | int | The VPC this pool's nodes join. |
| `public_subnet_id` / `public_subnet_cidr` | int / string | The VPC subnet elastic nodes' `eth1` (VPC) interface lives on. |
| `firewall_id` | int | Cloud Firewall applied to every node in this pool. |
| `private_subnet_cidrs` | list of strings | VLAN-side CIDR(s) the private client fleet lives on — NOT the VPC subnet above; VPC can't transit-route to non-VPC destinations (see `NAT-GATEWAY-DEFINITIVE-GUIDE.html` §1.2). |
| `authorized_keys` | list of strings | SSH public keys installed on every node natctl provisions for this pool. |
| `root_pass` | string | Root password set on provisioning (SSH key auth is still the expected access path). |
| `vlan_label` / `vlan_cidr` | string | The VLAN every node's `eth2` joins, and its CIDR. Must match this pool's `nat-fleet` module's own `vlan_label`/`vlan_cidr`. |
| `vlan_reserved_cidr` | string | This pool's own small, wholly-owned sub-block nested inside `vlan_cidr` — every floor/elastic/observability node's address is drawn from here, never from the wider VLAN a customer's own client fleet also lives on. |
| `vlan_ip_offset` / `elastic_ip_offset_start` | int | Host offsets within `vlan_reserved_cidr` — the floor's addresses start at `vlan_ip_offset`, elastic nodes' at `elastic_ip_offset_start`. Compared directly against each other, never summed. |
| `image` | string | Base OS image for nodes natctl provisions (default `linode/ubuntu22.04`). |

### Per-pool: sizing

| Field | Type | Default | What it does |
|---|---|---|---|
| `min_nodes` / `max_nodes` | int | `3` / `12` | Bounds on elastic capacity. **Live-overridable — see `CLI-GUIDE.md`'s `set-pool-scaling`** for a fast, temporary change; edit here for the durable value. |
| `instance_type` | string | `g6-dedicated-4` | The Linode plan every *new* elastic node in this pool gets provisioned as — doesn't retroactively resize existing nodes (see "Changing instance types" below). |
| `egress_ips_per_node` | int | `1` | Extra public egress IPs per node, to multiply available ephemeral ports. |
| `conntrack_max` | int | `1048576` | Per-node connection-tracking table size — size this against expected peak concurrent connections per node (see `NAT-GATEWAY-DEFINITIVE-GUIDE.html` §10.1's pre-production checklist). |
| `natctl_on_node_enabled` | bool | `false` | Whether elastic nodes natctl provisions for this pool also run their own natctl (leader-election-eligible), matching the pool's Terraform `natctl_on_node_enabled` variable for floor nodes. Keep both in sync. |

### Per-pool: reserved (sticky) public IPs

| Field | Type | Default | What it does |
|---|---|---|---|
| `reserved_ip_enabled` | bool | `false` | Fixes each elastic node's public IP to a Linode Reserved IP (survives instance replacement) instead of an ephemeral one — for downstream IP-whitelisting. Account-gated on Linode's side. |
| `reserved_ip_pool` | list of strings | `[]` | Addresses you already own (from a prior deployment, or reserved out-of-band) for natctl to prefer over minting a brand-new reservation — verified against the account's real unattached reserved IPs before ever being trusted. Only meaningful with `reserved_ip_enabled: true`. |
| `reserved_ip_prereserve_to_max` | bool | `false` | Proactively reserves this pool's full `max_nodes`-sized footprint up front instead of one address at a time as real scale-out happens. No cost guardrail beyond this flag — reserving ahead of need costs real money whether used or not. |

### Per-pool: HA — buddy-sync and BGP IP failover

See "High availability" below for what each layer actually protects against.

| Field | Type | Default | What it does |
|---|---|---|---|
| `conntrack_buddy_sync_enabled` | bool | `true` | Whether this pool's nodes run conntrackd buddy-pair sync. Only takes effect if `natctl_roster_base_url` below is also set. |
| `natctl_roster_base_url` | string | `""` | This pool's own roster API base URL (e.g. `http://10.0.0.5:8099`) — must match the `natctl_roster_url` Terraform variable given to this pool's `nat-fleet` module, so floor and elastic nodes sync against one consistent roster view. |
| `ip_failover_enabled` | bool | `false` | Whether nodes run FRR (BGP-based IP Sharing) so a buddy can take over a dead node's public IP. Requires `conntrack_buddy_sync_enabled`, `natctl_roster_base_url`, and `linode_bgp_dcid` below. |
| `linode_bgp_dcid` | int or omit | *(unset)* | The BGP data-center ID for this pool's region — look it up from Linode's current failover docs before enabling `ip_failover_enabled`. |
| `ip_failover_auto_configure` | bool | `true` | Whether natctl calls Linode's IP-sharing API itself as buddy pairings form. **Leave this `true`** — the reverse was live-verified to be a trap: BGP sessions silently never establish at all with no error surfaced anywhere short of a manual `vtysh` check. Set `false` only if you specifically want to run the first pairing by hand (see "Turning on HA deliberately" below). |

### Per-pool: client behavior baseline

| Field | Type | Default | What it does |
|---|---|---|---|
| `client_fallback_probe_enabled` / `client_fallback_probe_interval` | bool or null / int or null | `null` / `null` | `null` means "no opinion, respect each client's own local `LNG_FALLBACK_PROBE_ENABLED`/`LNG_FALLBACK_PROBE_INTERVAL` env var." **Live-overridable — see `CLI-GUIDE.md`'s `set-client-config`** for a fleet-wide change with no client restart; set here only for this pool's static baseline. |

### Per-pool: `autoscale:` block

See "Autoscaling" below for the full semantics (when each trigger fires, the sustained-breach window, step caps). Field-by-field:

| Field | Type | Default | What it does |
|---|---|---|---|
| `conntrack_high_watermark` / `conntrack_low_watermark` | float | `0.70` / `0.30` | Scale-out / scale-in triggers on connection-tracking table occupancy. |
| `port_headroom_low_watermark` | float | `0.15` | Scale-out trigger: only this fraction of usable source ports per destination remain free. |
| `throughput_high_watermark` | float | `0.85` | Scale-out trigger: this fraction of the node's real, per-instance-type bandwidth capacity (queried live from Linode's API). |
| `cpu_high_watermark` | float | `0.80` | Scale-out-only trigger: the busiest core's network-softirq saturation ratio. No scale-in equivalent. |
| `target_conntrack_ratio` / `target_port_utilization_ratio` / `target_throughput_ratio` / `target_cpu_ratio` | float | `0.50` each | Where a scale action aims to land each metric after acting, not the trigger watermark itself — see "Autoscaling" below's sizing formula. |
| `sustained_breach_passes` | int | `2` | Consecutive reconcile passes a metric must stay past its watermark before it's trusted enough to act on. |
| `max_scale_out_step_fraction` / `max_scale_in_step_fraction` | float | `1.0` / `0.5` | Caps a single scaling action as a fraction of current (scale-out) or current elastic (scale-in) capacity. |
| `cooldown_seconds` | int | `300` | No further scaling decision is evaluated for this long after one fires. |
| `drain_timeout_seconds` | int | `180` | How long a scaling-in node is given to empty out before forced deletion. |
| `unhealthy_replace_after_seconds` | int | `900` | How long an elastic node must fail its own health check continuously before it's drained and replaced. Covers a fresh node's full cloud-init boot time, not just steady-state failures — don't set this too low. |
| `auto_provision_enabled` | bool | `true` | Whether autoscaling is active at all for this pool. `min_nodes`/`max_nodes` remain the hard bounds either way. |

### Per-pool: Terraform-managed internal wiring — do not hand-edit

These exist so natctl's own elastic-node provisioning can fetch the
same artifacts Terraform already uploaded for floor nodes. Every one of
them is populated automatically on `terraform apply` and gets
overwritten back to Terraform's own value on the next apply regardless
— hand-editing any of these only lasts until then, and in the meantime
risks pointing an elastic node at a stale or wrong artifact.

| Field | What it's for |
|---|---|
| `exporter_py_url` / `buddy_sync_py_url` / `natctl_file_urls` | Source-mode artifact URLs (unused in this compiled-binary repo). |
| `agent_distribution` | `"source"` or `"binary"` — always `"binary"` in this repo. |
| `exporter_bin_url` / `buddy_sync_bin_url` / `natctl_bin_url` | Compiled-binary artifact URLs elastic nodes fetch at boot. |
| `nat_exporter_service_url` / `lng_buddy_sync_service_url` / `conntrackd_peer_service_url` / `natctl_service_url` / `natctl_requirements_txt_url` | Static systemd unit files (and, in source mode, `requirements.txt`) uploaded once per environment. |
| `object_storage_bucket` / `object_storage_s3_region` | The bucket/region natctl itself uploads a newly-provisioned elastic node's own per-node `nftables.conf` to, and reads/writes the three live-override objects (`set-pool-scaling`/`set-vpc-sibling-subnets`/`set-client-config`) from. Required for any of those three commands to work at all for this pool. |

## How to update any field

The field reference above tells you what each field does; this is the
actual procedure for changing one safely on a live deployment.

**Before you start: which host(s) you need to touch depends entirely on
your placement mode.**

- **Single dedicated host** (the default — natctl only runs on the
  observability instance): exactly one file, `/etc/natctl/config.yaml`
  on that host.
- **`natctl_on_node_enabled: true`**: every floor *and* elastic node in
  that pool runs its own independent natctl process, each with its own
  `/etc/natctl/config.yaml`, read once at that process's own startup.
  **A YAML-only field (anything not flagged "live-overridable" above)
  has to be changed on every single one of those nodes** — editing it
  on just one node only changes that one node's own behavior, not the
  fleet's. This also affects *future* elastic nodes: a brand-new elastic
  node's own baked-in config comes from whichever node is currently the
  leader, using that leader's own in-memory config as of its last
  restart — so as long as every node gets the same edit-and-restart
  (which you should be doing anyway, for consistency), future
  provisioning stays correct automatically, with no separate step
  needed.

**The procedure, per host:**

1. **Back up the file first** — a single `cp`, not a real backup system, but enough to make a bad edit trivially reversible:
   ```bash
   cp /etc/natctl/config.yaml /etc/natctl/config.yaml.bak
   ```
2. **Make your edit.** This repo ships compiled binaries with no Python interpreter installed on the node (see "How this repository is built" above) — there's no `python3 -c "import yaml..."` syntax check available locally on the node itself. If you want to validate the YAML is well-formed before touching a live node, do it on your own machine first (or against your own copy of `docs/natctl.example.yaml`), then copy the verified file over.
3. **Restart natctl:**
   ```bash
   systemctl restart natctl
   ```
4. **Confirm it came back up clean** — a bad edit (invalid YAML, a field set to a value `config.py` rejects) surfaces here, not at edit time:
   ```bash
   systemctl status natctl      # should show "active (running)", not "failed"
   journalctl -u natctl -n 50   # look for a normal reconcile-pass log line, not a startup traceback
   ```
5. **If it failed to come back up**, restore the backup and restart again:
   ```bash
   cp /etc/natctl/config.yaml.bak /etc/natctl/config.yaml
   systemctl restart natctl
   ```

**Under `natctl_on_node_enabled`, do this one node at a time, not all at
once** — if a bad edit is going to take a node down, you want to find
that out with the rest of the fleet still healthy and serving traffic,
not discover it after every node has already restarted simultaneously
with the same mistake.

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
4. Only then run a real failover drill (`../acceptance-tests/checks/check_04_ip_failover_bgp.py`) to prove it end to end.

If you'd rather authorize the first pairing yourself before `natctl` touches it, set `ip_failover_auto_configure = false`, run `linode-cli networking ip-share` by hand for both directions, watch it converge, then flip it back to `true`.

## Changing instance types

**Resizing an existing node (floor or elastic) — the safe, in-place way**, via the operator CLI (handles drain → resize → rejoin for you, never deletes the node):

```bash
./natctl-cli --config natctl.yaml resize --pool shared \
  --node-id shared-3 --instance-type g6-dedicated-8
```

If the resized node is a **Terraform floor node**, the command prints the exact `node_instance_type_overrides` block to add to your `.tfvars` — do this immediately, or the next `terraform apply` will see drift and revert the resize.

**Changing the base type** (what future nodes get provisioned as): edit the target pool's own `instance_type` field in `terraform.tfvars`'s `pools` map (floor) or the pool's `instance_type` in `natctl.yaml` + restart `natctl` (elastic) — neither retroactively resizes existing nodes.

## Common day-2 procedures

**Raise the floor** (permanent capacity increase): edit the target pool's `floor_nodes` field in `terraform.tfvars`'s `pools` map, then:
```bash
terraform apply
```

**Adjust elastic bounds (`min_nodes`/`max_nodes`)** — durable: edit that pool's `max_nodes` field (or `floor_nodes` for the minimum) in `terraform.tfvars`'s `pools` map, then `terraform apply`. Fast, temporary (a real capacity emergency, no time for a full apply cycle):
```bash
./natctl-cli --config natctl.yaml set-pool-scaling --pool shared --min-nodes 3 --max-nodes 8
```
Update `terraform.tfvars` too afterward if it should stick — the next `terraform apply`, for any reason, overwrites this back to whatever the file says. See `CLI-GUIDE.md`'s `set-pool-scaling` for the full detail.

**Get a newly-added VPC subnet reaching nodes and clients** — durable: `terraform apply` (re-discovers every VPC subnet automatically, no tfvars edit needed). Fast, temporary (a subnet added outside this project's own Terraform run, needs to be reachable before the next apply):
```bash
./natctl-cli --config natctl.yaml set-vpc-sibling-subnets --cidrs "10.0.0.0/13,10.8.0.0/16,10.9.0.0/24"
```
No `--pool` flag — one list, shared by the whole environment. See `CLI-GUIDE.md`'s `set-vpc-sibling-subnets` for the full detail.

**Manually drain and remove an elastic node**:
```bash
./natctl-cli --config natctl.yaml drain --pool shared --node-id shared-elastic-103
```
Refuses to drain a Terraform floor node — lower the floor via Terraform instead.

**Onboarding a client instance**: this project doesn't create client instances or apply their VLAN addresses -- create the instance yourself through your own automation (Terraform, an autoscaling group, hand-provisioned, whatever you already use), attach its VLAN interface, and apply a static VLAN address to it, entirely your own responsibility (no tooling or collision check from this project). Pick the address from outside your pool's dedicated reserved sub-block (that pool's own `vlan_cidr_reserved` field in the `pools` map, `.tfvars` -- that block belongs to this pool's own floor/elastic/observability nodes only) so it can never collide with a future node, and apply it **at the pool's WIDE `vlan_cidr` prefix length** (e.g. `/22`), not whatever prefix fits your address alone -- get this wrong and `client-agent` silently fails to install its route (`ip nexthop` rejects it with `Error: Nexthop has invalid gateway`, only visible in `journalctl -u lng-client-agent`), since this client's own connected route then can't reach the wider block a NAT node's address lives in. See `NAT-GATEWAY-DEFINITIVE-GUIDE.html` §3.4 (Static VLAN Addressing) for the full writeup and fix. Once the address is applied, run `../scripts/install-nat-client.sh --vlan-iface <iface> --roster-url <roster-url>` -- it verifies the address is really there (failing fast if not) and installs/starts client-agent if the instance has no working internet path of its own.

**If this pool runs `natctl_on_node_enabled`** (every node runs its own natctl), pass every node's own address to `--roster-url` as one comma-separated value instead of just one, e.g. `--roster-url "http://192.168.100.20:8099/fleet/shared,http://192.168.100.21:8099/fleet/shared,http://192.168.100.22:8099/fleet/shared"` -- client-agent tries each in turn and only fails if every one of them is down. A single hardcoded address leaves a freshly-starting (or restarting) client with zero NAT routes if that one specific node happens to be down at that exact moment, even though every other node is healthy. Prefer each node's **VLAN** address here (as above) over its VPC address -- it's reachable with no routing needed at all, since every node and every client share the same VLAN.

**Rolling security patches**: patch elastic nodes first via drain-and-replace. For floor nodes, patch one at a time — drain it manually (there's no automatic drain for a floor node), patch/reboot, confirm `/healthz` passes again, move to the next. Never patch every node in a pool simultaneously.

**Checking fleet status**:
```bash
./natctl-cli --config natctl.yaml status
./natctl-cli --config natctl.yaml nodes --pool shared
```

## HA fleet health check

Run through this whenever you're asked "is this fleet actually highly available," or periodically as a standing check:

1. **Enough healthy nodes?** `./natctl-cli status`, or the roster's `healthy_count` vs `node_count`.
2. **Buddy-pair sync actually paired?** Grafana's "Buddy-Paired Nodes" panel, or `nat_conntrack_buddy_paired` (1/0 per node). `0` on a node in an otherwise-healthy pool means genuinely unpaired.
3. **BGP sessions actually established?** "BGP Peers Established" vs "BGP Peers Configured" should match; `nat_bgp_peer_state` should be `1` per peer.
4. **Every node announcing its own IP?** `nat_ip_failover_self_announced` should be `1` on every node with `ip_failover_enabled`.
5. **Real buddy-backup coverage?** `nat_ip_failover_buddy_count` — `1` on a normal pair, `2` on an odd-node triangle's hub, `0` only if IP failover isn't configured for that node.
6. **Would a real failover actually work?** Steps 1–5 tell you the mechanism is armed; `../acceptance-tests/checks/check_04_ip_failover_bgp.py` is the real drill (genuinely disruptive — run in a maintenance window).

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

See `API-TOKEN-SETUP.md` for exactly which scopes to grant and how to create a least-privilege token via Cloud Manager or `linode-cli`.
