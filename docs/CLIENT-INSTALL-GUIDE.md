<!--
CLIENT-INSTALL-GUIDE.md (docs) -- CUSTOMER-REPO VARIANT

A standalone, task-focused walkthrough for turning any existing Linux
Linode into a client of this NAT gateway fleet -- one place with the
exact commands, the four interface-mode shapes, natctl-on-node
multi-URL failover, verification, and the troubleshooting cases that
have actually come up live. OPERATIONS.md's "Onboarding a client
instance" note is the condensed version of this same material; this
file is the detailed one to reach for when you're doing it for the
first time or something isn't working.

This project provides no VLAN-addressing tooling at
all -- applying a client's static VLAN address is entirely your own
automation's responsibility. scripts/install-nat-client.sh is the one
script here: it verifies the address is really there, then sets up NAT
routing.

Author: Sandip Gangdhar (https://github.com/sandipgangdhar)
(c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
-->

# Client install guide

How to turn any existing Linux Linode into a working NAT-gateway client
-- outbound traffic ECMP-routed across every healthy node in a pool,
surviving individual node failures with no client-side reconfiguration.

This project does not create client instances or attach their network
interfaces -- your own automation does that. This guide starts once the
instance exists and has its VLAN interface attached.

## VLAN addressing is yours; NAT routing is this script's

This project provides no VLAN-addressing tooling -- getting a working
static address onto the client's VLAN interface is entirely your own
automation's job:

| | Attach the VLAN interface | Choose and apply the VLAN address | Set up NAT routing |
|---|---|---|---|
| **Who does it** | You / your automation (account-level) | You / your automation (pick from the reserved sub-block below -- no auto-assignment or collision check exists) | `scripts/install-nat-client.sh` |

`install-nat-client.sh` checks that its `--vlan-iface` already has a
real address applied and fails fast with a clear error if it doesn't --
so a missing or not-yet-applied address is caught immediately, not a
silent half-working state.

## Before you start

- **The instance's VLAN interface must already be attached** at the
  Linode account level -- neither script attaches it. Cloud Manager, or:
  ```bash
  linode-cli linodes interface-add <linode-id> \
    --purpose vlan --label <vlan-label> --ipam_address <cidr>
  ```
  (power the instance off first if replacing an existing interface).
- **Pick a VLAN address from outside your pool's dedicated reserved
  sub-block** (that pool's own `vlan_cidr_reserved` field in the `pools`
  map, `terraform.tfvars` -- that block belongs to this pool's own
  floor/elastic/observability nodes only) so it can't collide with a
  node's own range -- there is no reservation system or collision check
  for manually-assigned clients at all; your own automation is fully
  responsible for uniqueness.
- **Apply it at the pool's WIDE VLAN CIDR prefix length, not whatever
  prefix happens to fit your address** --
  applying e.g. `/24` when the pool's real `vlan_cidr` is a `/22` still
  "succeeds" with no error, but `client-agent` then fails to install its
  route at all (`ip nexthop` rejects it with `Error: Nexthop has invalid
  gateway`, since this client's own kernel-connected route doesn't cover
  the wider block a NAT node's address can live in) -- silent from
  `install-nat-client.sh`'s own output, only visible in
  `journalctl -u lng-client-agent`. Fix by re-applying the same address
  with the correct wide prefix (e.g. `ip addr add <same-address>/<wide-prefix>
  dev <iface>` or whatever your own automation uses) then
  `systemctl restart lng-client-agent`. See
  `docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html` §3.4 (Static VLAN Addressing)
  for the full writeup.
- **Know your pool's roster URL — and whether that's a VPC or VLAN
  address depends on where natctl itself runs, not on the client:**
  - **Default (single dedicated control-plane host)**: natctl runs on
    the `observability` instance, which has public + VPC interfaces
    plus a **VLAN** interface on the shared pool's
    own VLAN. **A client on that same VLAN can use its VLAN address
    directly**, `vlan_only` included:
    `http://<observability-instance-VLAN-ip>:8099/fleet/shared`. A
    client on a *different* VLAN (a dedicated tenant pool with its own
    separate VLAN) still needs its own VPC interface (`vpc_vlan` or
    `public_vpc_vlan` mode) and the observability instance's **VPC
    private IP** instead:
    `http://<observability-instance-VPC-private-ip>:8099/fleet/<pool>`
    -- the observability instance only ever joins one VLAN, so a
    `vlan_only` client on a different VLAN structurally cannot reach it.
  - **`natctl_on_node_enabled = true`**: natctl runs on every NAT node,
    and every NAT node has a VLAN interface (`eth2`) -- **prefer a
    node's VLAN IP here, even if this client also has a VPC interface**
    (`vpc_vlan`/`public_vpc_vlan` mode). VLAN is one flat L2 segment, so
    this needs no routing at all -- just ARP -- and is simpler than the
    VPC path below. This is also what lets a `vlan_only` client (no VPC
    interface at all) reach it in the first place, since both sides
    share the same VLAN L2 segment. See "natctl-on-node pools: multi-URL
    failover" below.
  - **Either way**, this only affects how the roster itself is
    *fetched* -- the actual NAT egress traffic always rides each node's
    **VLAN IP**, which is what's inside the roster response and what
    `client-agent` builds its ECMP route against, regardless of which
    address you used to reach the roster endpoint.
  - **If you do need the VPC path** (a `vpc_vlan`/`public_vpc_vlan`
    client against the default single-control-plane host, which has no
    VLAN interface at all -- or any genuinely VPC-only workload): every
    subnet in your environment's VPC is auto-discovered and routed into
    every node's/the observability host's `eth1` at boot, so a client on
    a different VPC subnet than the fleet's own nodes is reachable
    out of the box. See `docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html#c3-3`
    if this ever silently hangs instead of connecting.
- **Run this script ON the target Linux instance itself** (SSH in, or
  as its own user-data), never on the machine driving your automation --
  it configures a Linux network stack directly and will fail with a
  confusing error on anything else (see "Troubleshooting" below).

## Quick steps

```bash
# on the client instance itself, as root

# 1. Apply a static VLAN address yourself first (your own automation --
#    this project provides no tooling for it), e.g.:
ip addr add 192.168.100.130/22 dev eth0

# 2. Set up NAT routing
sudo ./install-nat-client.sh \
  --vlan-iface eth0 \
  --roster-url http://<observability-instance-VPC-private-ip>:8099/fleet/shared
```

(That roster URL is the default single-control-plane-host case -- see
"Before you start" above for why it's the observability host's **VPC**
address, not a VLAN one, and when to use a NAT node's VLAN address
instead.)

Then verify:

```bash
ip route show default              # expect multiple nexthops, or an nhid resilient-group reference
journalctl -u lng-client-agent -f  # expect nodes reporting healthy
curl -s https://ifconfig.me        # expect a NAT node's public IP, not this host's
```

That's it for the common case. The rest of this doc covers natctl-on-node's
multi-URL flag, every flag in detail, the four interface-mode shapes,
and troubleshooting.

`install-nat-client.sh` fetches the **compiled** `client-agent` binary
at install time (rather than Python source) -- no `python3` needed on
the target instance for this script. Copy it onto the instance (`scp`,
or bake it into your image/cloud-init per "Best practices" below), or
paste it as that instance's own Linode user-data at create time, after
your own VLAN-addressing step -- see the script's own header comment for
the exact user-data variant (flags become exported env vars instead,
since user-data scripts run with no arguments).

**Or fetch it directly from natctl, no prior copy needed**: `GET
/agents/install-nat-client.sh` on natctl's roster API serves the script
itself, the same fetch-once-serve-locally mechanism already used for
`client-agent`'s own compiled binary. Useful for a `vlan_only`/`vpc_vlan`
instance with no internet path of its own, or just to skip a separate
copy/scp step:

```bash
curl -fsSL http://192.168.100.10:8099/agents/install-nat-client.sh -o install-nat-client.sh
chmod +x install-nat-client.sh
```

## natctl-on-node pools: multi-URL failover

If this pool runs `natctl_on_node_enabled` (every node runs its own
natctl, all serving an identical roster for that pool), pass **every**
node's address to `--roster-url`, comma-separated, instead of just one.
`client-agent` tries each in turn -- starting from whichever last
succeeded -- and only fails if every listed one is down:

```bash
sudo ./install-nat-client.sh \
  --vlan-iface eth0 \
  --roster-url "http://192.168.140.20:8099/fleet/dedicated-trio,http://192.168.140.21:8099/fleet/dedicated-trio,http://192.168.140.22:8099/fleet/dedicated-trio"
```

**Why this matters**: with a single hardcoded address, a client that's
*freshly starting* (or restarting) while that one specific node happens
to be down comes up with **zero NAT routes**, silently, until that node
recovers. An already-running client tolerates a node outage fine (keeps
its last-known-good roster and fails over on the next long-poll), but a
cold start has nothing to fall back to. This disproportionately hits
Kubernetes-style clients (pods reschedule far more often than a VM
reboots) but is the identical code path on a VM too. `NATCTL_ROSTER_URL`
(what `--roster-url` ultimately sets) accepts a comma-separated list for
exactly this reason -- list every node in a `natctl_on_node_enabled`
pool, not one. See `client-agent/lng-client-agent.env.example`'s
`NATCTL_ROSTER_URL` comment for the source-level detail.

For a single-control-plane pool (the default, not `natctl_on_node_enabled`),
one URL is fine -- there's only one natctl to point at either way.

## What this script actually does

**`install-nat-client.sh`:**

1. **Verifies `--vlan-iface` already has a real address** -- fails fast
   with a clear error if not (it never applies one itself; that's your
   own automation's job).
2. **Sets the kernel's ECMP hash policy** (`net.ipv4.fib_multipath_hash_policy=1`,
   persisted via `/etc/sysctl.d/99-lng-ecmp.conf`), unconditionally.
   Without this, the kernel's default hashes only source+destination IP
   (not port), so repeated connections to the same destination all land
   on the same NAT node regardless of how many healthy nodes exist.
   (`client-agent` itself also sets this at its own startup, so this
   step is belt-and-suspenders, not load-bearing on its own.)
3. **If `--vpc-iface` is given, sanity-checks it has a real address**
   -- the actual VPC sibling-subnet route management happens dynamically
   inside `client-agent` itself, from natctl's roster, not here (see
   "Restoring VPC sibling-subnet reachability" above); this is just an
   early, actionable failure if the named interface looks wrong.
4. **Detects whether this instance already has its own WORKING path to
   the internet** (a public IP, or VPC membership with 1:1 NAT) -- this
   is a real connectivity check (a request to `api.linode.com`, 3s
   timeout), not just "does a default route entry exist." A `vpc_vlan`
   instance's VPC interface, if marked primary with no 1:1 NAT, still
   gets a default route from Linode's own Network Helper on the
   ifupdown stack -- a route that's present but structurally cannot
   reach the internet. If it has a real path, `client-agent` is **not**
   installed by default -- nothing for it to manage. If it doesn't (no
   route, or a non-functional one), `client-agent` is installed and
   takes over the default route. Pass `--force` to install it anyway (a
   deliberate dual-path egress policy).

Prints a "Summary of changes" at the end (ECMP hash policy, default
route before/after, and client-agent's install location) -- a real,
itemized record of what that run actually did.

Safe to re-run: every step is idempotent.

## All flags

**`install-nat-client.sh`:**

| Flag | Env var | Required | Default | Notes |
|---|---|---|---|---|
| `--roster-url <url>` | `LNG_ROSTER_URL` | yes | — | natctl's roster URL for this client's pool. Comma-separated list supported (see above). |
| `--vlan-iface <name>` | `LNG_VLAN_IFACE` | **yes** | — | Must already have a real address applied by your own automation -- not auto-detected here, since by this point an addressless interface is a sign something upstream went wrong, not a useful hint. |
| `--artifact-base-url <url>` | `LNG_ARTIFACT_BASE_URL` | no | fetched via natctl's roster API | Only needed to fetch `client-agent` directly from Object Storage instead (e.g. a `public_vlan`-mode client that would rather not depend on natctl's serving endpoint). |
| `--fallback-probe-enabled true\|false` | `LNG_FALLBACK_PROBE_ENABLED` | no | `false` | Client trusts natctl's own computed health by default; enable for extra independent per-node probing (ANDed with natctl's view). Also settable fleet-wide, live, via `natctl-cli set-client-config` -- see OPERATIONS.md. |
| `--fallback-probe-interval <3-60>` | `LNG_FALLBACK_PROBE_INTERVAL` | no | `30` | Only meaningful with the fallback probe enabled. |
| `--health-probe-timeout <seconds>` | `LNG_HEALTH_PROBE_TIMEOUT` | no | `1.5` | |
| `--vpc-iface <name>` | `LNG_VPC_IFACE` | no | unset | This instance's VPC interface, if it has one. Only relevant for `vlan_only`/`vpc_vlan` instances whose VPC interface WAS their own default route before this script ran -- see "Restoring VPC sibling-subnet reachability" below. |
| `--force` | `LNG_FORCE=true` | no | `false` | Install/start `client-agent` even if this instance already has its own working path out. |
| `--help`, `-h` | — | no | — | Print the full flag reference and exit. |

Full detail and live-found caveats for each flag are in each script's
own header comment -- treat these tables as a quick reference, those
comments as the source of truth.

## Restoring VPC sibling-subnet reachability (`--vpc-iface`)

If this instance's VPC interface was its own default route **before** this script ran — i.e. a `vlan_only`/`vpc_vlan` instance with no public IP, so VPC was its only path out — that default route may have given it real reachability to *other* subnets in the same VPC (Akamai's VPC fabric forwards a packet between sibling subnets via a plain on-link route through the VPC interface, no gateway IP needed). Once this script hands the default route to `client-agent` for internet egress via the VLAN, that implicit sibling-subnet reachability is lost as a side effect — the default route now points at the VLAN, not VPC.

Pass `--vpc-iface <name>` to fix this. It just tells `client-agent` which interface is VPC; `client-agent` itself then adds/removes explicit, non-default routes to whatever VPC subnets natctl's roster currently reports — self-healing on every roster poll, so a subnet you add to the VPC later reaches this client automatically, no re-run needed:

```bash
sudo ./install-nat-client.sh \
  --vlan-iface eth1 --roster-url http://192.168.100.10:8099/fleet/common \
  --vpc-iface eth0
```

**Never** work around this by pointing the *default* route at the fleet's VPC addresses instead — NAT nodes' VPC interface is deliberately scoped to buddy-pair conntrackd sync only and never masquerades client traffic to the internet, so that breaks internet egress outright.

## Interface-mode shapes

Whatever interfaces your own tooling attaches, one of these four shapes
applies:

| `interface_mode` | Interfaces | Default route | VPC-resident reachability | Public reachability |
|---|---|---|---|---|
| `vlan_only` | eth0 = VLAN | client-agent, ECMP via VLAN | None | None (LISH / same-VLAN only) |
| `public_vlan` | eth0 = public, eth1 = VLAN | Untouched (Network Helper) | None | Yes, via eth0 |
| `vpc_vlan` | eth0 = VPC (no NAT), eth1 = VLAN | client-agent, ECMP via VLAN | Yes, via eth0 | None (VPC alone has no internet path) |
| `public_vpc_vlan` | eth0 = VPC + 1:1 NAT, eth1 = VLAN | Untouched (Network Helper / 1:1 NAT) | Yes, via eth0 | Yes, via eth0's 1:1 NAT |

`client-agent` (`install-nat-client.sh`) only ever manages the default
route -- installed precisely when nothing else on the instance already
provides one (`vlan_only`, `vpc_vlan`), skipped when something else does
(`public_vlan`, `public_vpc_vlan`). VLAN and VPC connected routes come
from whatever applied the address (your own automation) and the
kernel-OS network stack directly, independent of `interface_mode`. Full
mechanics: `docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html#c3-3`.

## Verification

```bash
ip route show default
#   default nhid 100
#       nexthop via 192.168.100.20 dev eth0 weight 1
#       nexthop via 192.168.100.21 dev eth0 weight 1
#       nexthop via 192.168.100.22 dev eth0 weight 1

journalctl -u lng-client-agent -f       # should show nodes healthy, no repeated errors

curl -s https://ifconfig.me             # a NAT node's public IP, not this instance's own

# Confirm real spread across nodes (each separate connection gets its own
# ephemeral source port, so this actually exercises the ECMP hash):
for i in $(seq 1 20); do curl -s https://ifconfig.me; echo; done | sort | uniq -c
```

## Troubleshooting

**`sysctl: unknown oid 'net.ipv4.fib_multipath_hash_policy'`** — this is
macOS/BSD's sysctl error wording, not Linux's (Linux says `cannot stat
... No such file or directory` instead). It means the script ran on the
wrong host — your laptop or automation runner, not the target Linux
client instance. SSH into the actual instance and run it there, or
deliver it as that instance's own user-data. `install-nat-client.sh`
fails fast with a clear message for this (a `uname -s` preflight)
instead of the cryptic sysctl error.

**Script hangs on the roster fetch** — check the NAT node/observability
instance's Cloud Firewall CIDR scoping for port 8099 before assuming
`client-agent` is broken; a client on the VPC's wrong subnet is a real,
silent way for this to fail.

**"This instance already has a default route via another interface --
client-agent will NOT be installed" on an instance you know has no real
internet path** — `install-nat-client.sh` now actually tests reachability
(a real request to `api.linode.com`) instead of just checking whether a
default route entry exists. On an older script predating this fix, a
`vpc_vlan` instance whose VPC interface is marked primary with no 1:1
NAT gets a default route from Linode's own Network Helper anyway
(ifupdown stack) — present in the route table, but structurally
incapable of reaching the internet (VPC alone can't reach it on its
own, see `docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html#c1-1`). Re-run with an
up-to-date `install-nat-client.sh`, or pass `--force` to install
`client-agent` regardless of what the route table shows.

**`install-nat-client.sh` errors immediately with "has no IPv4 address
configured"** — this is the expected, intentional guard: it never
applies the VLAN address itself (that's entirely your own automation's
job), and refuses to proceed if `--vlan-iface` looks unaddressed rather
than silently building a route through an interface that was never
actually configured. Apply a real static address to that interface with
your own automation, then re-run.

**VLAN address never applies / `ip -4 addr show <iface>` shows nothing**
— either your own addressing automation never ran (or failed partway),
or the instance's own VLAN interface was never actually attached at the
Linode account level. Check:
```bash
ip -4 -o addr show dev <vlan-iface>           # is the address actually applied?
networkctl status <iface>                     # (systemd-networkd) is it managing this interface, with the expected address?
journalctl -u systemd-networkd -b             # (systemd-networkd) or check your own addressing tool's own logs
```
If the interface never appears in `ip link` at all, it was never
attached to this instance at the Linode account level — that's a step
your own creation automation is responsible for, not something
`install-nat-client.sh` can fix from inside the guest OS.

**A freshly-started client shows zero routes even though nodes are
healthy** — if this pool runs `natctl_on_node_enabled` and
`--roster-url` only lists one node, and that one node happened to be
down at the moment this client started, this is exactly the cold-start
gap described above. Re-run with every node's address, comma-separated.

**`ECMP route exists but all traffic lands on one node`** — the kernel's
ECMP hash policy isn't set to include the port. Should be fixed
automatically by both `install-nat-client.sh` and `client-agent` itself;
if you're diagnosing an older client installed before that fix, re-run
`install-nat-client.sh` (or `client-agent/install.sh`) against it to
pick up the fix.

## Best practices

- Bake this script (after your own VLAN-addressing step) into your own
  instance image/cloud-init rather than running it ad hoc over SSH at
  scale.
- Safe to re-run against an already-configured instance.
- If you only want a one-off connectivity test against a single node
  (not full ECMP failover), a manual
  `ip route add <dest> via <nat-node-vlan-ip> dev <iface>` is simpler —
  `install-nat-client.sh` is unnecessary overhead for that narrower case.

## See also

- `OPERATIONS.md` — "Onboarding a client instance" (the condensed,
  day-2-ops version of this same material).
- `docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html#c3-3` — interface layout
  rationale and the full four-shape table, including `--vpc-iface` /
  VPC sibling-subnet reachability; `#c2-2`/`#c2-3` for the
  roster/control-plane design this all sits on top of.
- `scripts/install-nat-client.sh` — its own header comment is the
  authoritative, most detailed reference for every flag.
- `client-agent/install.sh`, `client-agent/lng-client-agent.env.example`
  — for installing `client-agent` directly, without
  `install-nat-client.sh`'s wrapper.
