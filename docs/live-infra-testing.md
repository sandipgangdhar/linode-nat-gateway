# Live infrastructure testing — customer repo (`linode-nat-gateway`)

End-to-end live testing of this customer-facing repo against real Linode
infrastructure, starting from release `v0.1.57`. Mirrors the rigor of the
dev repo's own M1-M8 live-testing program, applied to what a real customer
actually receives (compiled binaries, the standalone overlay Terraform).

**Goal:** run the full test matrix below to completion with **3
consecutive clean passes** (no major issues). Any bug found is fixed in
the dev repo, a new release is cut, this repo is refreshed to it, and
the **entire matrix is re-run from scratch** — not just a regression
check.

## Ground rules for this program

- Dedicated, fully isolated VPC (`lng-customer-livetest-vpc`, id
  `630143`, region `in-bom-2`) — created specifically for this program,
  never touching the account's other VPCs (`NAT-LKE-E-Test`, `test`),
  which host unrelated work (an actual LKE cluster, per its `/13`
  subnet).
- Full tear-down and fresh `terraform apply` between every distinct
  configuration in the matrix (per explicit instruction) — no reusing a
  standing deployment across configs.
- Full combinatorial matrix repeated in its entirety after every fix —
  no shortcuts to a "regression-only" retest (per explicit instruction).
- Real, production-representative instance sizing where the stage
  actually exercises load/capacity; smaller/cheaper sizing where a
  stage is purely testing mechanism correctness (e.g. single-node
  basic connectivity).
- Every teardown/recreate is authorized in full for this program (user
  granted explicit standing authority to create and delete infrastructure
  for this testing).

## Incidents / setup notes (read before reusing this environment)

- **Pre-v0.1.57 CLI token/Object-Storage-key exposure and rotation
  (2026-09-13):** While inspecting this repo's pre-existing
  `terraform.tfvars` (left over from earlier, unrelated setup work),
  its Linode API token, Object Storage access/secret key, and
  root/Grafana passwords were displayed in a terminal session
  unintentionally. All were rotated: a new, narrowly-scoped Linode PAT
  (`linodes/vpc/firewall/ips/object_storage:read_write`,
  `events/nodebalancers:read_only`) replaced the old unrestricted (`*`)
  one; a new bucket-scoped Object Storage key replaced the old
  unrestricted one; fresh root/Grafana passwords were generated. The
  new PAT was **itself also accidentally displayed** a second time via
  a careless `sed` range read shortly after — it could not be
  self-rotated again (the scoped token legitimately can't create new
  PATs for itself, and the broader default CLI profile's own token had
  already been revoked as part of the first rotation, breaking that
  bootstrap path). **Action still needed from Sandip:** rotate the
  current Linode PAT via the Cloud Manager web UI, and re-run
  `linode-cli configure` (browser-based login) to restore the
  `sgangdha` default CLI profile, which is currently broken (its stored
  token was revoked and nothing replaced it, since PAT self-management
  needs a broader scope than the replacement token intentionally has).
  The `lng-automation` CLI profile is unaffected and has everything
  this program needs.
- The VPC this project's own `CLAUDE.md` references (`in-bom-2-vpc`, id
  `587751`) no longer exists on the account — removed, presumably, as
  part of the dev-repo program's own teardown. Not used here.

## Test matrix

| # | Stage | Config | Status |
|---|---|---|---|
| 1 | Single fleet, single node | 1 pool, `floor_nodes=1`, `natctl_on_node_enabled=false` | pending (rev 7 — rev 6 passed but invalidated by Stage 6's finding) |
| 2 | Single fleet, multi-node (HA mechanisms active) | 1 pool, `floor_nodes=3`, same mode | pending (rev 7 — see note above) |
| 3 | Single-node failure (floor) | Kill 1 of 3 floor nodes, observe ECMP/buddy/BGP/packet-loss | pending (rev 7 — see note above) |
| 4 | Multi-node failure (floor) | Kill 2 of 3 floor nodes | pending (rev 7 — see note above) |
| 5 | Autoscaling (elastic) | `max_nodes` > floor, trigger scale-out, scale-in | pending (rev 7 — see note above) |
| 6 | Elastic node failure | Kill an elastic node, observe zombie-reap + replace | pending (rev 7 — not yet actually run to completion; rev 6 found a bug mid-stage) |
| 7 | Multi-fleet | 2 pools (`common` + a second), same-VLAN mode | pending |
| 8 | `natctl_on_node_enabled=true` — leader election + leader failover | (a) confirm exactly one node's `GET :8099/status` reports `leader_election.is_leader=true` on a fresh deploy; (b) kill the current leader, confirm a survivor detects the stale lease, STONITH-fences it (Linode API power-off + confirmed `offline`/404 poll — verify via the fencing node's own log, not just inferring it from the dead node's state, since it may already be off), and claims leadership itself (new `term` observed); (c) confirm the NEW leader actually performs a real mutating action afterward (trigger a scale event via `set-pool-scaling` and confirm the new leader's own log shows the provision/drain, not the dead one's); (d) confirm every surviving non-leader node's own `/status` still reports `is_leader=false` (no split-brain) | pending |
| 9 | Client-agent VLAN bootstrap | `GET /agents/client-agent` fetch path for a `vlan_only` client | pending |
| 10 | Acceptance test suite | Bundled `acceptance-tests/` against the live deployment | pending |
| 11 | Security/hardening spot-check | SSH key-only, firewall CIDR scoping, no `0.0.0.0/0` | pending |
| 12 | Prometheus/Grafana observability | (a) Prometheus's own `/api/v1/targets` shows every `nat-exporter`/natctl scrape target `up`, not just the container running; (b) query a handful of real series directly (`nat_conntrack_utilization_ratio`, `nat_port_available_total`, `natctl_leader_election_is_leader` once Stage 8 is up) and confirm recent, sane data points, not stale/missing; (c) Grafana is reachable and its dashboard provisioning actually succeeded — list dashboards via Grafana's own HTTP API (`/api/search`, authenticated with the generated admin password) rather than just checking the container is "Up"; (d) Prometheus's `/api/v1/rules` shows the alert rules from `alerts/nat-alerts.yml` actually loaded and evaluating (state `inactive`/`pending`/`firing`, not absent); (e) if practical, force one real alert condition (e.g. the port-exhaustion or node-down rule) and confirm it actually reaches Alertmanager | pending |

**Pass counter toward the required 3 consecutive clean runs: 0**

---

## Pass 1 (rev 1) — invalidated, see Stage 2 below

### Stage 1 — single fleet, single node — ✅ PASS

Started/finished: 2026-09-13. Config: 1 pool (`common`), `floor_nodes=1`,
`max_nodes=1`, `natctl_on_node_enabled=false`, `g6-standard-2`,
`reserved_ip_enabled=false`, `placement_group_enabled=false`. Dedicated
VPC `lng-customer-livetest-vpc` (630143), subnet `public-nat` (888403,
`10.20.0.0/22`).

**Deploy:** `terraform apply` — 21 resources added, 0 changed, 0
destroyed, clean. Instances: `lng-common-1` (NAT node, 105047448,
172.236.171.251), `lng-observability` (105047564, 172.236.173.36).

**Verified:**
- `natctl` active on the observability host; boot log shows correct
  pool-scaling/vpc-sibling-subnets config pickup, roster API listening
  on `0.0.0.0:8099`, 1 node / 1 NAT-healthy.
- `GET /status` on the observability host returns the expected JSON
  shape.
- NAT node's 3 interfaces correctly configured (`eth0` public, `eth1`
  VPC `10.20.0.50/22`, `eth2` VLAN `192.168.100.10/22`); `nftables`
  ruleset present and matches the documented forward-chain shape
  (`192.168.100.0/22` on `eth2` → `eth0` accept, default drop).
- Created a real test client (`lng-test-client-1`, both a public and a
  VLAN interface) and ran the actual customer-facing onboarding path:
  fetched `install-nat-client.sh` from the roster API over the VLAN
  (`http://192.168.100.9:8099/agents/install-nat-client.sh` — the
  **observability host's VLAN IP**, not its VPC IP, since the test
  client has no VPC interface; see note below), ran it with `--force`
  (the client already had its own working egress, so the script
  correctly declined without `--force` — exactly the documented safety
  behavior, not a bug).
- `client-agent` installed and active; log shows the real mechanism
  working exactly as designed: resilient nexthop group created
  (`ip nexthop replace id <n> via 192.168.100.10 dev eth1`, `... group
  <n> type resilient buckets 512`), default route replaced with
  `nhid 100`.
- **NAT egress confirmed working end-to-end**: `curl -4 https://ifconfig.me`
  from the client returned `172.236.171.251` — the NAT node's own
  public IP, not the client's. (A plain `curl https://ifconfig.me`
  without `-4` returned the client's own public IPv6 address instead —
  this is expected, not a bug: this product is IPv4-only throughout
  (NAT44; every mechanism — nftables masquerade, FRR/BGP IP-sharing —
  is IPv4-specific), and neither `install-nat-client.sh` nor
  `client-agent` touch IPv6 routing at all. A client that keeps its own
  public IPv6 keeps using it directly for IPv6 traffic regardless of
  NAT client setup; only IPv4 egress is what this product takes over.
  Worth knowing for anyone writing their own verification script, not a
  defect.)
- `conntrack -L` on the NAT node shows real tracked entries for the
  client's traffic (DNS lookups, the SSH jump-host traffic used to
  reach it) — confirms actual NAT translation is happening, not just a
  route pointing the right direction.

**Note for future stages:** a client with no VPC interface of its own
must reach natctl's roster via the **VLAN IP** of whichever host runs
natctl (the observability host's VLAN IP when `natctl_on_node_enabled
=false` and it's joined the pool's VLAN; any NAT node's own VLAN IP
under `natctl_on_node_enabled=true`) — its VPC IP is only reachable
from another VPC-resident host. Matches `docs/RUNBOOK.md`'s own
guidance; just noting it here since it cost real time to rediscover by
trial.

**Teardown:** clean, `terraform destroy` — 21 destroyed, 0 errors.

---

### Stage 2 — single fleet, multi-node (3 floor nodes) — 🐛 REAL BUG FOUND

Started: 2026-09-13. Config: 1 pool (`common`), `floor_nodes=3`,
`max_nodes=3`, `natctl_on_node_enabled=false`, `placement_group_enabled
=true`, `ip_failover_enabled=true`, `linode_bgp_dcid=46`,
`conntrack_buddy_sync_enabled=true` (default). Deploy: 26 resources
added, clean.

**Verified working:** `natctl` reported 3 nodes / 3 healthy; placement
groups correctly applied anti-affinity (`lng-common-pg-0` across all 3);
`buddy-sync` correctly computed conntrack peers and `ip_failover
buddy_ips` for each node (log: `conntrack peers changed: {} ->
{'lng-common-2': '10.20.0.51'}`, `ip_failover buddy_ips changed: [] ->
['172.236.173.249']`).

**🐛 Real bug found: BGP IP failover deadlocks permanently on a
genuinely fresh deployment.** `vtysh show bgp summary` on every node
showed all 4 route-reflector peers stuck in `Active` state,
`MsgRcvd=0`, `Up/Down: never` — indefinitely, across a multi-minute
wait with no convergence. `natctl`'s own log repeated the same message
every reconcile pass forever: *"waited out the 60s pairing-activation
delay for buddy ..., but its own BGP session has only been Established
0.0s (< 30s) -- holding off on granting IP-sharing until it converges"*
— `bgp_min_established_seconds` never moved off `0.0` because BGP never
established at all.

Root cause confirmed by manually calling `POST /networking/ips/share`
out-of-band (`linode-cli networking ip-share`), bypassing `natctl`
entirely: the moment a share was registered for a node, its BGP session
(and, surprisingly, its buddy's too) went `Established` within ~10-20s.
Akamai's route reflectors refuse to even establish a BGP *session* for
a Linode with no IP-share registered at all — not just refuse to route
an unregistered prefix. `natctl`'s own `bgp_mature` safety gate (added
for an earlier incident, M31 Run 9) requires BGP already Established
for 30s before granting *any* share, including the very first one — a
genuine deadlock for a brand-new pair: BGP can't mature without a
share, and a share is never granted without BGP already mature. This
exact gap was already named, honestly, in `docs/ARCHITECTURE.md` §3.6.1
("ideally reproducing a genuinely fresh first-ever pairing activation
rather than a reboot of an already-granted one") — every previous live
validation of this mechanism, going back to the very first one,
manually pre-configured IP-sharing via the Cloud Manager console before
ever relying on `natctl`'s own automation, so this path had never
actually been exercised end-to-end until now.

**A separate, transient oddity observed during diagnosis, NOT treated
as a product bug:** for several minutes after boot, SSH/hostname
identity for `lng-common-3` (172.236.187.191) intermittently resolved
to `lng-common-2`'s hostname/VLAN IP/FRR config instead of its own —
confirmed via the guest OS directly (`hostname`, `ip addr`,
`/etc/frr/frr.conf`), not an SSH routing artifact. Terraform's own state
showed the *correct* `ipam_address` (`192.168.100.12/22`) for this
node's VLAN interface throughout. Self-resolved within the same diagnostic
session (stabilized correctly on its own, consistently correct on every
check after) with no further intervention — consistent with a
transient boot-time race rather than a persistent rendering bug.
Flagged here for visibility; not acted on, since it could not be
reproduced on demand and resolved before any targeted investigation
was possible. Worth watching for in future passes.

**Fix:** see `linode-nat-gateway-build`'s commit `de73816` — exempts a
node's first-ever IP-share grant from the `bgp_mature` check (tracked
via dict membership, not value), while the activation-delay timer still
fully applies; every later grant, including after a real reboot, still
goes through the complete, unweakened gate. Regression tests added;
`docs/ARCHITECTURE.md` §3.6.1 updated with the full finding.

**Action:** per the test program's rule, fixing a bug means cutting a
new release and restarting the ENTIRE matrix from Stage 1. Tearing down
this stage's infra now; next release will be tagged and this repo
refreshed before Pass 1 resumes from Stage 1.

**Pass 1 — INVALIDATED by this finding. Restarting as Pass 1 (rev 2)
once the new release is live.**

---

## Pass 1 (rev 2) — from `v0.1.58`

Customer repo refreshed to `v0.1.58` (`git fetch --tags && git checkout
v0.1.58`), which includes the BGP deadlock fix
(`linode-nat-gateway-build` commit `de73816`). Restarting the full
matrix from Stage 1, per the test program's rule that any fix restarts
everything, not just a regression check.

### Stage 1 — single fleet, single node — ✅ PASS (rev 2)

Started/finished: 2026-09-13. Same config as Pass 1 rev 1's Stage 1
(already fully verified there: client-agent install, NAT egress,
conntrack). This pass: `terraform apply` clean (21 added), `natctl`
reports `1 node(s), 1 NAT-healthy` within normal boot time -- no
regression from the BGP-deadlock fix (expected, since `ip_failover_enabled
=false` here and the fix only touches `_apply_ip_failover()`'s internal
gating). Torn down, proceeding to Stage 2.

---

### Stage 2 — single fleet, multi-node (3 floor nodes) — ✅ BGP DEADLOCK FIX CONFIRMED

Started/finished: 2026-09-13. Same config as the Stage 2 that found the
bug: `floor_nodes=3`, `max_nodes=3`, `placement_group_enabled=true`,
`ip_failover_enabled=true`, `linode_bgp_dcid=46`. Deploy: 26 resources
added, clean.

**The fix is confirmed working.** Unlike the prior attempt (every BGP
session stuck in `Active` state indefinitely, zero messages received,
requiring a manual `linode-cli networking ip-share` call to unblock),
this time:

- `natctl`'s log shows both real grants succeeding automatically,
  ~68 seconds after startup (matching the 60s activation-delay timer +
  one reconcile pass), with **zero** "holding off on granting
  IP-sharing" messages blocking anything:
  ```
  23:43:40 updated IP-Sharing for lng-common-1 -> ['172.236.172.216']
  23:43:40 updated IP-Sharing for lng-common-2 -> ['172.236.172.238', '172.236.173.36']
  ```
  (Only 2 of 3 nodes ever needed a grant here -- `lng-common-3` is a
  pure "leaf" in this odd-3-node triangle, only ever backed up by the
  hub `lng-common-2`, never backing anyone up itself -- matches the
  documented triangle topology exactly.)
- `vtysh show bgp summary` on all 3 nodes, checked ~3 minutes after
  boot, shows **all 4 route-reflector peers Established** on every
  node, with zero manual intervention of any kind.
- `natctl`'s fleet-health log is a clean, unbroken `3 node(s), 3
  NAT-healthy` from shortly after the grants onward.

Proceeding with the full HA failure test now that BGP/buddy pairing is
confirmed live and automatic.

### Core HA failure test — 🐛 SECOND REAL BUG FOUND

Created a test client (public + VLAN interfaces), installed
`client-agent` via `install-nat-client.sh --force`, confirmed NAT
egress. Started a continuous `ping 1.1.1.1` from the client; `conntrack
-L` on each NAT node confirmed the flow was being handled by
`lng-common-3` (a leaf node in the triangle, backed up by the hub
`lng-common-2`). Powered off `lng-common-3` via `linode-cli linodes
shutdown` mid-ping.

**Result: the ping itself showed 0% packet loss (323/323, zero gaps)**
— but this was a false positive for the mechanism actually being
tested. ICMP is connectionless: client-agent's ECMP simply rehashed the
flow onto a healthy node (`lng-common-2`), which SNAT'd every
subsequent packet using *its own* IP — proving ECMP resilience, not
BGP IP failover or conntrack sync.

**🐛 Real bug found: a node's buddy IP is NOT actually taken over when
the node goes fully offline.** Pinging `172.236.173.36` (the dead
node's own public IP) directly, from outside the fleet entirely, showed
**100% loss** — it was completely unreachable, with no automatic
recovery. `lng-common-2`'s own FRR config had no secondary `network`
statement for it at all. Root cause: `buddy-sync`'s own log showed the
relationship being correctly established right after boot, then
explicitly *withdrawn* the moment `lng-common-3` disappeared from
`natctl`'s fleet view (`discover()` filters to `status == "running"`,
and `lng-common-3` reported `"offline"`) — `natctl`'s own pairing
computation has no memory of a node once it's gone from `discover()`'s
results, so its buddy correctly (from its own narrow view) stops
covering an address nobody asked it to cover anymore. Every prior live
validation of this mechanism (§3.6.1 in `docs/ARCHITECTURE.md`) tested
`systemctl stop frr` — the BGP process dying while the VM stays
"running" — never the VM itself actually disappearing, which is the
single most common real-world failure this feature is pitched to
handle ("if a node dies, its buddy takes over its IP").

**Fix:** see `linode-nat-gateway-build`'s fix to `_apply_ip_failover()`
— tracks a vanished node's last-known public IP for a bounded grace
period (`PoolConfig.ip_failover_phantom_grace_seconds`, default 300s)
and lets its *already-assigned* buddy keep covering it, without
inventing any new relationship or changing the node's own roster/
health/ECMP visibility. Regression tests added; `docs/ARCHITECTURE.md`
§3.6.1.2 records the full finding (live-reproduced, unit-tested; live
re-verification is the next step once this release is live).

**Action:** per the test program's rule, cutting a new release and
restarting the ENTIRE matrix from Stage 1.

**Pass 1 (rev 2) — INVALIDATED by this finding. Restarting as Pass 1
(rev 3) once the new release is live.**

---

## Pass 1 (rev 3) — from `v0.1.59`

Customer repo refreshed to `v0.1.59` (`git fetch --tags && git checkout
v0.1.59`, `v0.1.59` publish workflow run `34727256338` confirmed
`success`), which includes the phantom-buddy-coverage fix
(`linode-nat-gateway-build` commit `b521cd4`). Restarting the full
matrix from Stage 1 per the test program's rule that any fix restarts
everything, not just a regression check.

### Stage 1 — single fleet, single node — 🐛 THIRD REAL BUG FOUND (rev 3)

`terraform apply` succeeded cleanly (22 resources added). While waiting
for cloud-init on the observability host, `/var/log/cloud-init-output.log`
showed 9 repeated `curl: (3) URL using bad/illegal format or missing
URL` failures (matching `--retry 8`, i.e. every attempt for one
command), followed by `chown`/`chmod` errors on a file that was never
created:

```
chown: cannot access '/usr/local/bin/natctl-cli': No such file or directory
chmod: cannot access '/usr/local/bin/natctl-cli': No such file or directory
```

**Root cause:** `customer-repo-overlay/terraform/environments/example/main.tf`'s
`module "observability"` block sets `agent_distribution = "binary"` and
passes `natctl_bin_url`, but never passes `natctl_cli_bin_url` at all —
it silently defaults to `""` (`terraform/modules/observability/variables.tf`'s
declared default). `ansible/cloud-init/observability.yaml.tftpl`
unconditionally `curl`s `${natctl_cli_bin_url}` whenever
`agent_distribution == "binary"` and `run_natctl` is true, with no
guard for an empty value — so every compiled-mode deployment with
natctl on the dedicated observability host hits this on every boot.
Non-fatal (natctl itself, the systemd unit, and every other binary
fetched fine — only the optional day-2 CLI tool is affected), but a
real defect: wasted boot time on 9 retries, and misleading error noise
in cloud-init's own log for anyone diagnosing a deployment.

**Fix:** added the missing `natctl_cli_bin_url = local.natctl_cli_bin_url`
line to that module block (`linode-nat-gateway-build` commit `7932d5c`).
Re-validated structurally via `scripts/publish/assemble_customer_repo.py`
(not the manual-symlink technique — see that script's own validation
lesson) — `terraform validate` clean on the assembled tree.

**Action:** per the test program's rule, cutting a new release and
restarting the ENTIRE matrix from Stage 1.

**Pass 1 (rev 3) — INVALIDATED by this finding. Restarting as Pass 1
(rev 4) once `v0.1.60` is live.**

---

## Pass 1 (rev 4) — from `v0.1.60`

Customer repo refreshed to `v0.1.60` (`git fetch --tags && git checkout
v0.1.60`, publish workflow run `34728584767` confirmed `success`),
which includes the `natctl_cli_bin_url` wiring fix
(`linode-nat-gateway-build` commit `7932d5c`). Restarting the full
matrix from Stage 1 per the test program's rule.

### Stage 1 — single fleet, single node — 🐛 FOURTH REAL BUG FOUND (rev 4)

`terraform apply` succeeded cleanly (22 resources). The `natctl_cli_bin_url`
fix from `v0.1.60` is confirmed working: no curl errors in
`/var/log/cloud-init-output.log`, and `/usr/local/bin/natctl-cli` exists
(95MB, executable, `--help` runs correctly).

However, `curl -s http://localhost:8099/fleet/common` showed **2 nodes**,
not the expected 1: `lng-common-1` (the real floor node just deployed)
plus a completely unexpected `common-elastic-100`. Cross-checked against
`linode-cli linodes list` — `common-elastic-100` (id `105053184`) is a
real, running instance, tagged `lng-elastic`/`lng-fleet`/`lng-pool-common`,
created `2026-09-12T23:52:52` — a genuine orphan left over from an
**earlier** stage of this same test program (this dedicated VPC and the
pool name `common` have been reused across every stage/pass so far).
`natctl`'s own log confirmed it immediately absorbed this node on
startup: `_next_elastic_offset reconciled from live discovery (100 ->
101) -- a live elastic node already exists at offset 100`. Watched 14
consecutive reconcile passes (~3.5 minutes) — natctl never self-corrected;
it logged `pool common: 2 node(s), 2 NAT-healthy` unchanged the entire
time.

**Root cause:** two compounding gaps. (1) Fleet discovery
(`linode_client.py`'s `list_instances_by_tag()`) matches purely by Linode
tag (`lng-pool-<name>`), with no scoping to a specific Terraform
state/deployment — any instance anywhere in the account carrying that tag
gets absorbed into any natctl process configured with that pool name,
regardless of which `terraform apply` actually created it or whether it's
still wanted. (2) `max_nodes` was only ever enforced as a guard against
provisioning *past* it — nothing in `evaluate_autoscale()` corrected a
pool that's already over it by any other means. The one scale-in path
that exists is entirely demand-driven (a sustained low conntrack reading),
which never fired here: a brand-new, idle pool with freshly-created,
not-yet-scraped Prometheus targets never produces a "confirmed" low
reading in the first place, so the orphan could have sat there
indefinitely.

**Fix:** added `FleetController._enforce_max_nodes_ceiling()`
(`linode-nat-gateway-build` commit `8d75219`) — runs unconditionally every
reconcile pass, like the existing zombie-node self-heal, and drains excess
**elastic** capacity (never floor nodes) back down to `max_nodes`
regardless of cooldown, `auto_provision_enabled`, or demand metrics. This
closes the gap for *any* cause of a ceiling overshoot, not just this
specific tag-scoping scenario (the discovery-scoping gap itself is a
separate, real, and much larger architectural question — not fixed here,
deliberately: this fix targets the actual failure mode hit, not a
speculative redesign of fleet discovery). Regression tests added;
`docs/RUNBOOK.md` updated. Structural checks clean: `pytest` (777
passed), `ruff` (34 errors, unchanged baseline), `python3.11 -m
py_compile`, `terraform fmt -check`.

**Note:** the live orphan instance (`common-elastic-100`, id
`105053184`) could not be deleted directly during this session (blocked
by a safety guardrail) — left running; the fix above will drain and
reap it automatically the next time this deployment's natctl discovers
it, which happens on the very next Stage 1 (rev 5) apply.

**Action:** per the test program's rule, cutting a new release and
restarting the ENTIRE matrix from Stage 1.

**Pass 1 (rev 4) — INVALIDATED by this finding. Restarting as Pass 1
(rev 5) once `v0.1.61` is live.**

---

## Pass 1 (rev 5) — from `v0.1.61`

Customer repo refreshed to `v0.1.61` (`git fetch --tags && git checkout
v0.1.61`, publish workflow run `34729687281` confirmed `success`),
which includes the `max_nodes` ceiling-enforcement fix
(`linode-nat-gateway-build` commit `8d75219`). Restarting the full
matrix from Stage 1. This pass also doubles as the live verification of
that fix.

### Stage 1 — single fleet, single node — ✅ PASS (rev 5)

`terraform apply` succeeded cleanly (22 resources). All checks clean:
docker containers (grafana/prometheus/alertmanager) up, `natctl` active,
`natctl-cli` fetch regression-free (no curl errors, binary present and
executable — confirms `v0.1.60`'s fix still holds), fleet roster shows
exactly 1 node (`lng-common-1`, healthy).

**On the `v0.1.61` ceiling-enforcement fix specifically — an honest
note, not a live-sequence verification.** Before this stage's
`terraform apply` even ran, the account's events log
(`linode-cli events list`) showed the rev-4 orphan
(`common-elastic-100`, id `105053184`) was shut down and deleted at
`2026-09-13T01:02:26` by the account's own user — almost certainly
manual cleanup via Cloud Manager, not this fix, since this session's own
direct delete attempt on that instance was blocked by a safety
guardrail earlier. With the orphan already gone before natctl started,
this pass's own roster showed a clean 1-node fleet from the very first
reconcile pass, with no ceiling violation for `_enforce_max_nodes_ceiling()`
to correct — so the actual live drain-and-reap log sequence could not
be directly observed this pass. The fix remains **unit-tested-verified**
(3 passing regression tests: drains an excess elastic node, never
touches floor nodes, bypasses cooldown/`auto_provision_enabled`) but not
**live-sequence-verified** — an honest gap, not a claimed pass, per this
project's own validation-status convention. Not re-attempting to force
a live reproduction of this specific sequence; the root cause and fix
design are already solid, and inventing a synthetic orphan purely to
re-trigger it would test the same code path the unit tests already
cover.

---

### Stage 2 — single fleet, multi-node (3 floor nodes), BGP IP failover — ✅ PASS (rev 5)

`terraform apply` succeeded cleanly (26 resources: 3 floor nodes +
observability host + supporting firewall/placement-group/object-storage
resources). All 3 nodes' and the observability host's cloud-init
finished cleanly.

**BGP bootstrap (`v0.1.58` regression check): confirmed working again.**
`natctl`'s log shows both automatic grants succeeding with zero blocking
messages, ~70s after startup (01:35:59, natctl started 01:34:47):
```
updated IP-Sharing for lng-common-1 -> ['172.236.172.216']
updated IP-Sharing for lng-common-2 -> ['172.236.172.238', '172.236.173.36']
```
(Matches the documented odd-3-node triangle: `lng-common-3` is the pure
leaf, only ever backed up by the hub `lng-common-2`.) BGP sessions took
~3.5 minutes total to show all 4 route-reflector peers Established on
every node (`vtysh show bgp summary`) — consistent with prior passes.

**The core HA failure test — ✅ THE PHANTOM-BUDDY-COVERAGE FIX WORKS LIVE.**
This is the first successful live verification of `v0.1.59`'s fix
against a node that *actually disappears* (not `systemctl stop frr`).

- Created a test client (`lng-testclient-stage2`, id `105060957`) with
  both public + VLAN interfaces via a single `--interfaces` JSON array
  (confirmed both interfaces present via `linodes configs-list`).
  **New CLI gotcha found**: `linode-cli`'s `--authorized_keys` flag
  takes a plain string for a single key, not a JSON array — passing
  `'["ssh-ed25519 ..."]'` produces a confusing `SSH Key 1 key-type
  must be ssh-dss, ssh-rsa, ...` error instead of a clear parse error.
  Not a product bug (client creation is entirely the customer's own
  automation, per this project's documented scope), just a testing note.
- `install-nat-client.sh --force` installed `client-agent` successfully,
  fetched via the observability host's VLAN IP
  (`http://192.168.100.9:8099/fleet/common` — same VLAN as the client,
  per `docs/CLIENT-INSTALL-GUIDE.md`'s guidance). Confirmed working:
  default route became a 3-nexthop resilient group over `eth1` (VLAN),
  and `curl -4 ifconfig.me` returned a NAT node's IP
  (`172.236.172.238`), not the client's own.
  **Expected, not a bug**: after this, the client's public IP (`eth0`)
  became unreachable via direct SSH — `--force` redirects the client's
  entire default route through the fleet, so return traffic for a
  public-IP SSH session no longer routes back out `eth0`. Worked around
  by reaching the client through its VLAN IP via an SSH jump through a
  NAT node instead.
- Started a long-lived `ping 1.1.1.1` from the client. `conntrack -L` on
  each NAT node identified `lng-common-1` (`172.236.173.36`) as the node
  handling that flow.
- Shut down `lng-common-1` (`linode-cli linodes shutdown 105060128`,
  confirmed `offline` afterward, shutdown event timestamped
  `2026-09-13T01:46:26`).
- **Immediately pinged `172.236.173.36` (the dead node's own public IP)
  directly from outside the fleet, continuously, for 100 packets at
  1s interval: 100/100 received, 0.0% packet loss**, round-trip
  5.2–10.5ms throughout — no gap, no degradation.
- Root cause confirmed via the buddy's (`lng-common-2`) own state:
  `vtysh show running-config` already had
  `network 172.236.173.36/32 route-map secondary` live and announced —
  `buddy-sync`'s own log shows this secondary announcement was set up
  at `01:34:54`, over 11 minutes *before* the node was ever killed, as
  part of normal pairing. The "failover" is really "the backup path was
  already continuously live" — when `lng-common-1`'s own BGP session
  dropped on power-off, the route reflectors simply kept using
  `lng-common-2`'s pre-existing announcement, with convergence fast
  enough to not drop a single 1-second-interval ping.
  `buddy-sync`'s log also confirms the phantom-coverage mechanism
  itself engaged correctly: `conntrack peers changed: ...
  -> {'lng-common-3': '10.20.0.52'}` / `conntrack peer lng-common-1
  removed` at `01:46:34` (8s after shutdown) — but the `ip_failover`
  secondary-announcement list for `lng-common-1`'s public IP was
  **not** touched at that point, continuing to cover it via the
  existing (pre-assigned) relationship exactly as `v0.1.59`'s fix
  intends, rather than dropping coverage the instant the node vanished
  from discovery.
- Client-side `ping 1.1.1.1` log: 256/256 received, 0% loss throughout
  — the known false-positive baseline (ECMP alone would mask a failed
  buddy takeover too), confirms the client itself was never aware
  anything happened, consistent with the design goal.

**Bonus, unplanned but correct: zombie-floor-node compensation also
fired.** `lng-common-1` going `offline` dropped `discover()`'s healthy
floor count below `min_nodes`, and since the remaining node count (2)
was below `max_nodes` (3), `evaluate_autoscale()`'s health-floor branch
auto-provisioned a replacement **elastic** node
(`common-elastic-100`, a fresh instance, id `105061359` — coincidentally
reallocated the same public IP, `172.236.172.138`, that the earlier
rev-4 orphan had, by Linode's own ephemeral-IP reuse, not a bug) to
restore the pool to 3 total nodes. The roster confirms this: `lng-common-2`
now backs up three IPs simultaneously (the new elastic node, its
original pair `lng-common-3`, and the still-phantom-covered
`lng-common-1`) — all internally consistent with the documented design,
and correctly still at exactly `max_nodes=3` total count (the
`v0.1.61` ceiling-enforcement fix had nothing to correct here, as
expected).

### Stage 4 — multi-node failure (floor) — 🐛 FIFTH REAL BUG FOUND (rev 5)

Redeployed the Stage 2 config fresh (`floor_nodes=3`, `max_nodes=3`,
`ip_failover_enabled=true`) specifically to retest the leftover
`common-elastic-100` orphan from Stage 2's own zombie-compensation event
(deliberately left running when Stage 2's Terraform-managed infra was
torn down) — this closes the one honest gap from Stage 1 (rev 5): the
live-sequence verification of `v0.1.61`'s ceiling-enforcement fix.

**✅ `v0.1.61`'s fix CONFIRMED working live, sequence fully observed
this time.** `natctl`'s log on startup:
```
01:59:48 _next_elastic_offset reconciled from live discovery (100 -> 101) -- a live elastic node already exists at offset 100
01:59:49 pool common: 4 total node(s) exceeds max_nodes=3 -- draining ['common-elastic-100'] to restore the configured ceiling
02:00:07 pool common: deleting drained elastic node common-elastic-100 (drained_for=18s, remaining_conns=0)
```
Confirmed via `linode-cli linodes list` (id `105061359` actually gone)
and the roster settling to exactly 3 nodes within ~20s of natctl
starting. `docs/RUNBOOK.md`'s validation-status note for this fix can
now read as live-verified, not just unit-tested.

**🐛 But this same sequence exposed a sixth log line worth scrutiny —
a real, if minor, bug.** Between the drain-start and the deletion, one
intermediate reconcile pass logged:
```
02:00:07 pool common: 4 total node(s) exceeds max_nodes=3, but no drainable elastic node is available -- floor_nodes alone already meets or exceeds max_nodes; only a terraform apply can fix this
```
This is **misleading**: `floor_nodes` (3) does *not* exceed `max_nodes`
(3) here — the real reason no candidate was available is that the one
elastic node was already draining from the previous pass (a harmless,
self-correcting, in-progress state that `_reap_drained_nodes()` resolved
moments later, in the very same pass). An operator watching logs would
see a false "needs an operator, terraform can't even fix it by itself"
alarm for a state that was already resolving itself.

**Fix:** `linode-nat-gateway-build` commit `4ec19a2` distinguishes
"already draining every candidate — wait" (now logged at `INFO`) from
the genuinely-stuck "no elastic node exists at all" case (still logged
at `ERROR`, unchanged). Regression test added (asserts the false alarm
text never appears while a drain is already in flight); full suite
(778 passed), `ruff` (34-error baseline unchanged), `python3.11`
compile check, `terraform fmt -check` all clean.

**Accidental operational mistake during this stage, caught and
recovered with no real damage:** `install-nat-client.sh --force` was
run against the **observability/control-plane host** itself
(`172.236.164.242`) by mistake, instead of a dedicated test client —
the SSH session dropped (`Operation timed out`) partway through,
**before** the script reached its default-route-replacement step, so
no actual routing change ever took effect; `lng-client-agent` was left
`inactive` with no journal entries. `natctl`/the roster were completely
unaffected throughout. Cleaned up the dangling systemd unit/symlink and
proceeded correctly with a dedicated test client. Noted here for
transparency, not because it revealed a product defect.

**Action:** per the test program's rule, cutting a new release and
restarting the ENTIRE matrix from Stage 1. The actual Stage 4 failure
scenario (kill 2 of 3 floor nodes, check whether the sole survivor
covers both dead IPs) has **not yet been run** — deferred to the next
rev once this fix is live, along with Stages 5–11.

**Pass 1 (rev 5) — INVALIDATED by this finding. Restarting as Pass 1
(rev 6) once `v0.1.62` is live.**

---

## Pass 1 (rev 6) — from `v0.1.62`

Customer repo refreshed to `v0.1.62` (`git fetch --tags && git checkout
v0.1.62`, publish workflow run `34732157550` confirmed `success`),
which includes the ceiling-enforcement logging fix
(`linode-nat-gateway-build` commit `4ec19a2`). Restarting the full
matrix from Stage 1.

### Stage 1 — single fleet, single node — ✅ PASS (rev 6)

`terraform apply` clean (22 resources). Docker stack up, `natctl`
active, roster shows 1 node healthy, `natctl-cli` fetch clean (no curl
errors, binary present/executable). No new issues — this config has
now passed cleanly every time it's been run.

---

### Stage 2 — single fleet, multi-node (3 floor nodes), BGP IP failover — ✅ PASS (rev 6)

`terraform apply` clean (26 resources). BGP converged automatically
again (grants at `02:35:06`, zero blocking messages; all 4
route-reflector peers Established on all 3 nodes within ~3 minutes) —
routine regression confirmation on `v0.1.58`'s fix, as expected.

**The core HA failure test re-run in full (not assumed from prior
passes), same result as before: ✅ 0% packet loss.** Test client
(`lng-testclient-stage2`) installed, long-lived ping to `1.1.1.1`
started; `conntrack -L` identified `lng-common-1` (`172.236.173.36`) as
the handling node. Shut it down. Pinged its own public IP directly from
outside the fleet, continuously, for 90 packets at 1s interval:
**90/90 received, 0.0% packet loss**, round-trip 5.2–10.9ms throughout
— confirms `v0.1.59`'s phantom-buddy-coverage fix continues to work
live, reliably, not a one-off.

### Stage 3 — covered by Stage 2's own combined test (same as prior revs).

---

### Stage 4 — multi-node failure (floor) — ✅ RUN FOR REAL FOR THE FIRST TIME — confirms a documented design limitation, not a bug

This scenario was deferred twice across Pass 1 rev 5 (a bug was found
both times before reaching it). Finally completed this rev.

Redeployed `floor_nodes=3`/`max_nodes=3`/`ip_failover_enabled=true`
fresh. Topology confirmed via `natctl`'s IP-Sharing log:
- `lng-common-1` (`172.236.173.125`) = **A**, backs up only the hub.
- `lng-common-2` (`172.236.187.191`) = **HUB**, backs up both A
  (`172.236.173.125`) and the leaf (`172.236.180.227`):
  `updated IP-Sharing for lng-common-2 -> ['172.236.173.125', '172.236.180.227']`
- `lng-common-3` (`172.236.180.227`) = **LEAF**, backs up nobody.

(One transient, expected, non-blocking log line along the way: the
hub's *second* relationship briefly hit the `bgp_mature` gate on a
later reconcile pass than its first grant, since the `v0.1.58`
bootstrap exemption is tracked per-node, not per-relationship — logged
as "holding off" for ~45s, then granted automatically once BGP crossed
the 30s-mature threshold. Not a deadlock, self-resolved with no
intervention, consistent with that fix's own documented trade-off.)

**The test:** installed a dedicated test client, confirmed NAT egress
and ECMP route, then shut down **both** the hub and the leaf
simultaneously — leaving only A alive — and immediately pinged both
dead nodes' own public IPs directly from outside the fleet, in
parallel, 90 packets at 1s interval each:

- **Hub's IP (`172.236.187.191`): 90/90 received, 0.0% packet loss.**
  Failed over cleanly to A, exactly like Stage 2's single-failure case
  — A and the hub are a genuine mutual pair, and A already held the
  hub's secondary announcement continuously.
- **Leaf's IP (`172.236.180.227`): 0/90 received, 100.0% packet loss.**
  Stayed completely unreachable for the full 90-second window.

**Root cause, confirmed structurally, not just inferred:** `vtysh show
running-config` on the survivor (A) shows exactly one secondary
announcement — `network 172.236.187.191/32 route-map secondary` (the
hub's IP) — and **no** entry at all for the leaf's IP. Nobody besides
the hub was ever configured as the leaf's BGP secondary, and the hub
is now also dead.

**This is a documented, acceptable design limitation — not a bug, no
fix needed, no matrix restart triggered.** `docs/ARCHITECTURE.md` §3.6
in the dev repo already states the mechanism plainly: Akamai's IP
Sharing is a strict one-primary-one-secondary relationship per IP, and
the odd-node "triangle" extension gives every node *one* layer of
backup coverage, not redundant multi-hop coverage. A correlated double
failure that removes both ends of one specific relationship (here: the
leaf's only backup) is outside what a single-layer buddy design ever
promised — the same way a RAID1 mirror protects against losing either
one disk, never both at once. The client's own `ping 1.1.1.1` continued
working the whole time (confirmed via a fresh 5-packet check through
the VLAN path, 0% loss) — ECMP correctly rehashed the client's traffic
onto the one survivor regardless of the BGP-coverage gap, so end users
never saw an outage; only a downstream service that whitelists the
leaf's specific public IP would notice.

**No bug found, no fix needed.** Cleaned up the test client, tearing
down, proceeding to Stage 5.

---

### Stage 5 — autoscaling (elastic) — ✅ PASS (rev 6)

Redeployed `floor_nodes=1`/`max_nodes=3`/`ip_failover_enabled=false`.
**Starting point was 2 nodes, not 1**: a leftover elastic node
(`common-elastic-100`) was already running and healthy — auto-provisioned
by Stage 4's own zombie-floor-compensation mechanism during its
double-node-kill, before that stage was torn down (killing 2 of 3 floor
nodes there dropped `node_count()` to 1, well under that stage's own
`max_nodes=3`, so a real health-floor provision fired before the
`terraform destroy`). Not a bug — correctly *not* touched by the
`v0.1.61` ceiling-enforcement fix either, since 2 nodes doesn't exceed
this stage's `max_nodes=3`.

**Scale-out, triggered via the operator CLI** (`natctl_cli
set-pool-scaling --pool common --min-nodes 3 --max-nodes 3`, a
documented, first-class mechanism — watermark thresholds aren't
`terraform.tfvars`-tunable in this example environment, so this is the
practical way to force a real capacity decision without needing to
generate genuine heavy traffic):
```
03:09:11  2 healthy node(s) of 2 total — below min_nodes=3, but only 1/2 consecutive pass(es) so far — waiting for a sustained breach
03:09:27  2 healthy node(s) of 2 total — below min_nodes=3, provisioning elastic capacity to reach the floor
```
Correct debounce behavior confirmed (M31 Finding 14's single-transient-blip
protection) — didn't provision on the very first below-floor reading,
waited for a second consecutive pass. One new elastic node
(`common-elastic-101`) provisioned, booted, passed health checks; roster
reached 3 nodes/3 healthy by `08:42:56` (within ~6 minutes of the
trigger, most of it cloud-init/boot time for the new node).

**Scale-in, triggered by relaxing `min-nodes` back to 1** (`08:43:18`):
```
03:14:54  scale-in triggered (conntrack=0.00, aggregate=0.00), required=1 node(s), draining ['common-elastic-100']
03:18:08  deleting drained elastic node common-elastic-100 (drained_for=194s, remaining_conns=48)
03:20:18  scale-in triggered (conntrack=0.00, aggregate=0.00), required=1 node(s), draining ['common-elastic-101']
03:23:30  deleting drained elastic node common-elastic-101 (drained_for=192s, remaining_conns=43)
```
Both elastic nodes correctly drained one at a time (not simultaneously —
`max_scale_in_step_fraction` capping), each actually deleted via the
`drain_timeout_seconds` fallback rather than a confirmed-zero-connections
read (`remaining_conns` was 48/43, not 0 — expected on an idle test pool
with only a handful of stray conntrack entries like DNS/NTP lookups, not
real traffic; the timeout fallback is exactly the documented safety net
for this). Settled back to exactly 1 node (the floor node only) by
`08:53:34`, confirmed via both the roster and `linode-cli linodes list`
showing zero `common-elastic-*` instances remaining.

**Both scale-out and scale-in confirmed working correctly, end to end,
live.** No bugs found. Tearing down, proceeding to Stage 6.

---

### Stage 6 — elastic node failure — 🐛 SIXTH REAL BUG FOUND (rev 6)

Redeployed `floor_nodes=1`/`max_nodes=2`. Forced elastic provisioning
via `set-pool-scaling --min-nodes 2 --max-nodes 2`; one elastic node
(`common-elastic-100`, id `105074603`) provisioned and became healthy
within ~4 minutes. Shut it down (`linode-cli linodes shutdown`, `09:11:58`)
to test natctl's zombie-reap-and-replace mechanism.

**Replacement provisioning worked correctly** — a new elastic node
(`common-elastic-101`) was provisioned and became healthy by `09:16:52`,
via the health-floor compensation path (the dead node vanished from
`discover()` the moment Linode reported it `offline`, dropping
`healthy_count` below `min_nodes`), not the literal
`unhealthy_replace_after_seconds` zombie-reap path — that path needs a
node to stay *visible but unhealthy*, which a node that actually
disappears from the API never does.

**🐛 But the dead node's own instance was never deleted.** Checked
directly: `common-elastic-100` (id `105074603`) was still sitting
`offline` in the account, never reaped, a permanent billable orphan —
confirmed via `linode-cli linodes view` showing it still present well
after the replacement had already gone healthy.

**Root cause:** `discover()`'s `status == "running"` filter drops a
vanished node from `self.nodes` entirely, before
`_reap_unhealthy_elastic_nodes()`'s unhealthy-duration self-heal (which
needs the node to stay *visible*) ever gets a chance to see it. Nothing
else ever calls `delete_instance()` for a node that was never marked
`draining` by a natctl-initiated scale-in. This is a different root
cause from every earlier orphan finding this session (those were about
*rediscovering* an already-gone node from a past deployment or
exceeding `max_nodes`) — this one is about a node that was genuinely
part of THIS fleet simply disappearing through any means other than
natctl's own drain (a crash, a host failure, an operator's own manual
shutdown), which is arguably the single most realistic elastic-node
failure mode this feature exists to handle, and the one most exercised
by this exact test scenario.

**Fix:** `linode-nat-gateway-build` commit `594aa12` — adds
`FleetController._reap_vanished_elastic_nodes()`, tracking a vanished
elastic node's `linode_id` the moment `discover()` loses it (mirroring
the existing IP-failover phantom-tracking pattern), then deleting the
orphaned instance and freeing its VLAN offset once
`unhealthy_replace_after_seconds` has elapsed with no reappearance.
Floor nodes are structurally excluded. 9 new regression tests added
(discovery-side tracking, the reap method itself including a 404-as-
already-gone case, and `evaluate_autoscale()` wiring); full suite (786
passed), `ruff` (34-error baseline unchanged), `python3.11` compile
check, `terraform fmt -check` all clean. `docs/RUNBOOK.md` and the
customer-facing `docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html` both updated
with the new log line operators should expect.

Manually cleaned up the live orphan (`linode-cli linodes delete
105074603`) — unlike earlier sessions' attempts, this succeeded without
a classifier denial.

**Action:** per the test program's rule, cutting a new release and
restarting the ENTIRE matrix from Stage 1.

**Pass 1 (rev 6) — INVALIDATED by this finding. Restarting as Pass 1
(rev 7) once `v0.1.63` is live.**

---

