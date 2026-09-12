<!--
docs/CLI-GUIDE.md -- CUSTOMER-FACING DISTRIBUTION

The complete natctl-cli reference: what it is, how to get it, how to
configure it, and every subcommand it has -- with real, complete,
copy-paste invocations. OPERATIONS.md weaves CLI usage into specific
day-2 procedures; this doc is the exhaustive, command-by-command
reference those procedures point back to.

Author: Sandip Gangdhar (https://github.com/sandipgangdhar)
(c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
-->

# natctl-cli — Day-2 Operations CLI Guide

`natctl-cli` is the operator-facing command-line tool for this deployment
— the thing you reach for to answer "is the fleet healthy right now," to
retire or resize a specific node, or to change a live setting across the
whole fleet without a redeploy. This doc covers installing it,
configuring it, and every subcommand it has. For deployment itself, see
`../README.md`; for the broader day-2 operations picture (autoscaling
tuning, HA, monitoring, troubleshooting), see `OPERATIONS.md`.

## What it is, and what it isn't

`natctl` (the fleet controller) is a long-running daemon — it never takes
commands, it just runs its reconcile loop forever from the moment it
starts, on every node or on a dedicated observability host depending on
how you deployed it. `natctl-cli` is a **separate, one-shot program**:
you run it by hand, it does one thing, then it exits. Both are built from
the same underlying fleet-management logic, so what `natctl-cli status`
reports is exactly what the daemon itself currently believes — not a
second, independent source of truth, just a different way of reaching
the one that already exists.

Every command in this guide is real and complete as written — not a
paraphrase — against a live deployment.

## Installing it

Download `natctl-cli` from this version's GitHub Release page — the same
page this repository's own README points you to for the other four
compiled binaries — then:

```bash
chmod +x natctl-cli
```

Run it from wherever you operate the fleet from: your own laptop, the
observability host, or any node itself all work equally well, as long as
that machine can reach the Linode API and, for commands that read live
fleet state, the roster. It needs no Python interpreter and no
dependencies installed — a single, self-contained native binary, same as
`natctl` itself.

**This is a separate binary from the daemon, distributed differently on
purpose.** It's an operator's own tool, never fetched automatically by
Terraform or cloud-init the way the other four binaries are — you always
get it by hand, once, from the Release page.

## Configuring it

Every subcommand needs `--config <path-to-natctl.yaml>` — the same
configuration file the daemon itself reads. **`--config` is a top-level
flag, not a per-subcommand one**, so it goes right after `natctl-cli`,
before the subcommand name: `./natctl-cli --config natctl.yaml status`,
not `./natctl-cli status --config natctl.yaml` (the latter fails with
"unrecognized arguments"). `natctl-cli` reads the file fresh on every
invocation and never modifies it. If you're running the CLI from a
machine other than a live fleet node, you'll need your own local copy of
that file (and the credentials it references).

**Two different things `--config` is used for, depending on the
command**: most commands (`status`, `nodes`, `drain`, `resize`,
`check-orphans`) use it to talk to the **Linode API directly** — they
build their own live view of the fleet from Linode's own state. The
`set-*` commands instead use it only to find the pool/API defaults, then
send a real HTTP request to a **running `natctl` process's own API** —
see each command's own section below for which kind it is.

**`--natctl-url`, on the `set-*` commands only**: these commands default
to talking to `localhost` (the common case: running the CLI from the
same host `natctl` runs on, or against a specific node in the every-node
placement mode). Pass `--natctl-url http://<host>:8099` explicitly if
you're operating from anywhere else.

**The Linode API token is separate from `--config`, and needs one extra
step if you're running the CLI on a live node.** `natctl.yaml` itself
never contains the token — it resolves from the `LINODE_TOKEN`
environment variable, same as the daemon (see `natctl.yaml`'s own
`linode:` section). On a live node, that variable already lives in
`/etc/natctl/env` (the same file the daemon's systemd unit loads via
`EnvironmentFile=`), but a plain `source /etc/natctl/env` in your shell
only sets it as a local shell variable — it does **not** export it, so
a subprocess like `natctl-cli` never sees it and fails with `Linode API
error: No Linode API token configured`. Use `set -a` first so every
variable the file sets gets exported too:

```bash
set -a; source /etc/natctl/env; set +a
./natctl-cli --config /etc/natctl/config.yaml status
```

If you're running the CLI from your own laptop instead, export
`LINODE_TOKEN` yourself (or put it in your own shell environment some
other way) rather than relying on a node's `/etc/natctl/env` at all.

## Command reference

| Command | Talks to | Mutates anything? |
|---|---|---|
| [`status`](#status) | Linode API | No |
| [`nodes`](#nodes) | Linode API | No |
| [`drain`](#drain) | Linode API | Yes — deletes one elastic node |
| [`resize`](#resize) | Linode API | Yes — resizes one node in place |
| [`check-orphans`](#check-orphans) | Linode API | No |
| [`set-client-config`](#set-client-config) | A running natctl's API | Yes — live fleet-wide setting |
| [`set-pool-scaling`](#set-pool-scaling) | A running natctl's API | Yes — live fleet-wide setting |
| [`set-vpc-sibling-subnets`](#set-vpc-sibling-subnets) | A running natctl's API | Yes — live fleet-wide setting |

### `status`

The one-line, fleet-wide health check.

```bash
./natctl-cli --config natctl.yaml status
```

```
shared: 3 node(s), 3 healthy
dedicated-acme-corp: 3 node(s), 3 healthy
```

**Why**: the fastest possible answer to "is everything okay right now,"
with nothing to open, load, or log into. **When**: first, before
anything more specific — the natural opening move of any troubleshooting
session, or a quick sanity check before/after a change.

### `nodes`

Every node in one pool, in detail.

```bash
./natctl-cli --config natctl.yaml nodes --pool shared
```

```
  shared-1                       private=10.60.32.20     healthy=True  public=['172.236.173.36']
  shared-2                       private=10.60.32.21     healthy=True  public=['172.236.171.17']
  shared-elastic-100             private=10.60.32.100    healthy=False public=['172.236.180.4']
```

**Why**: where `status` gives a count, `nodes` gives the roster itself —
every node's ID, private IP, health, and public IP(s). **When**: the
moment `status` shows fewer healthy nodes than expected, to see exactly
which node it is and what its current public-facing address is.

### `drain`

Retire one elastic node on your own schedule.

```bash
./natctl-cli --config natctl.yaml drain --pool shared --node-id shared-elastic-103
```

**Why**: you want a specific elastic node gone now, rather than waiting
for the autoscaler to eventually decide it's no longer needed. **When**:
rolling a patch across the fleet, moving load off a node ahead of
planned maintenance elsewhere on it, or correcting a scale-out you no
longer want.

The named node is excluded from the roster immediately — new connections
stop landing on it at once — and deleted once its live connection count
actually empties out, or once `drain_timeout_seconds` elapses, whichever
comes first. Existing connections are allowed to finish; nothing is
severed.

Refuses outright on a Terraform floor node, by design — floor capacity is
Terraform's to manage, not natctl's. Lower the floor count instead (edit
that pool's `floor_nodes` field in `terraform.tfvars`'s `pools` map, then
`terraform apply`) if you actually want to remove permanent capacity.

### `resize`

Change a node's instance plan in place.

```bash
./natctl-cli --config natctl.yaml resize --pool shared \
  --node-id shared-3 --instance-type g6-dedicated-8
```

**Why**: a node's own traffic has genuinely outgrown its current plan.
**When**: persistently high CPU/softirq or bandwidth against that one
specific node — not a pool-wide capacity problem, which autoscaling
already handles on its own.

Works identically on a floor or elastic node, and never deletes the node
— it drains it, resizes the underlying instance, then rejoins it to the
pool, all in one invocation (warm resize, falling back to cold
automatically if Linode rejects the warm attempt).

`--node-id` is repeatable for more than one node in the same invocation
— `--node-id shared-3 --node-id shared-elastic-7` — but nodes are always
processed strictly one at a time, and the whole operation stops at the
very first failure rather than continuing against a pool that's already
short a node.

**If the resized node is a Terraform floor node**, the command prints
the exact `node_instance_type_overrides` block to add to your
`.tfvars` immediately after — do this before the next `terraform apply`,
or Terraform will see drift and try to revert the resize back to the
pool's base instance type.

### `check-orphans`

Find elastic nodes a rebuild left behind.

```bash
./natctl-cli --config natctl.yaml check-orphans --pool shared
./natctl-cli --config natctl.yaml check-orphans   # every pool at once, omit --pool
```

**Why**: `terraform destroy` only ever knows about the resources
Terraform itself created — floor nodes. It has no idea an elastic node
exists at all, since natctl provisions those dynamically, entirely
outside Terraform's view. A rebuild can leave a real, billable elastic
instance running from the previous environment with nothing left
pointing at it. **When**: before and after any `terraform
destroy`/`apply` rebuild of an environment.

Lists every node it currently sees, flags any elastic node that's
unhealthy and not already draining as a **SUSPECT ORPHAN**, and tells
you how to verify and clean one up. It's read-only — it never deletes
anything itself, just reports, so it's always safe to run.

One honest limitation: this is a single, one-shot pass, not the
long-running daemon's own continuously-updated view — a flagged node's
unhealthy status reflects only the instant you ran the command, not how
long it's actually been that way. Correlate against what you know you
just created before deciding anything is genuinely orphaned.

### `set-client-config`

Override client fallback-probe behavior fleet-wide, live.

```bash
./natctl-cli --config natctl.yaml set-client-config --pool shared \
  --fallback-probe-enabled true --fallback-probe-interval 10

# revert to each client's own local env var / natctl.yaml's baseline:
./natctl-cli --config natctl.yaml set-client-config --pool shared --clear
```

**Why**: every connected client trusts the roster's own computed health
by default rather than independently probing each node itself — correct
for almost every deployment, since it means a client never adds
duplicate probe traffic the control plane is already generating.
**When**: the rare occasion you judge that trust unacceptable for a
specific pool.

Flips the fallback probe on or off, and sets its interval, for every
currently-connected client in that pool at once — without touching
`natctl.yaml` or restarting anything anywhere. `--clear` reverts to
whatever the pool's own static configuration says. Every connected
client picks up the change within one long-poll round-trip — seconds,
not a deploy cycle.

### `set-pool-scaling`

Override a pool's elastic `min_nodes`/`max_nodes` bounds fleet-wide,
live.

```bash
./natctl-cli --config natctl.yaml set-pool-scaling --pool shared \
  --min-nodes 3 --max-nodes 8
```

**Why**: the durable path (editing `terraform.tfvars`'s `pools` map and
running `terraform apply`) is correct for a bound change you intend to
keep, but a real capacity emergency doesn't always have time for a full
apply cycle. **When**: raise `max_nodes` immediately during an incident,
then still make the same change in `terraform.tfvars` afterward so it
survives the next apply.

Writes the exact same object `terraform apply` writes for this pool's
scaling bounds — not a separate override layer, so there's no "merge"
behavior to reason about, just last-write-wins. Every controller
managing this pool re-reads it the very next reconcile pass (roughly 15
seconds by default). **The next `terraform apply`, for any reason,
overwrites it back** to whatever `terraform.tfvars` currently says —
this command is the fast, temporary path, not a replacement for keeping
Terraform's own value correct.

### `set-vpc-sibling-subnets`

Override the whole-environment list of sibling VPC subnets fleet-wide,
live.

```bash
./natctl-cli --config natctl.yaml set-vpc-sibling-subnets \
  --cidrs "10.0.0.0/13,10.8.0.0/16,10.9.0.0/24"

# empty the override (does NOT restore Terraform's own discovered value
# -- run terraform apply for that, see below):
./natctl-cli --config natctl.yaml set-vpc-sibling-subnets --clear
```

**Why**: a Linode VPC interface only ever gets a kernel route to its own
directly-connected subnet — nothing routes it to a sibling subnet in the
same VPC automatically. This project's Terraform auto-discovers every
subnet in the VPC on each apply and routes them in; this command exists
for when a subnet was just added to the VPC outside of this project's
own Terraform run (by hand, or by another team's automation sharing the
same VPC) and needs to be reachable before the next apply.

No `--pool` flag — this setting is a property of the whole environment,
not any one pool, since every pool shares the same VPC. Every controller
re-reads it the next reconcile pass, which feeds both a node's own route
to the new subnet **and** (via the roster) every connected client's
self-healing route to it too — see `../README.md`'s VPC-routing notes and
`OPERATIONS.md`'s onboarding section for the full mechanism this plugs
into. `--clear` empties the override, it does not restore Terraform's
own value: `terraform apply` always re-derives this list live from the
VPC's actual subnets, overwriting whatever `natctl-cli` last wrote,
whether that was a real CIDR list or an empty one.

**Refuses by default if the new list (or the empty list `--clear`
produces) would no longer cover this environment's own control-plane
addresses** — confirmed live to cut every client's route to natctl
itself, with no automatic recovery:

```
Refusing: this would no longer cover this environment's own
control-plane address(es) (10.8.0.50, 10.8.0.51, 10.8.0.52) -- every
client's route to natctl itself would be cut, with no automatic
recovery. Pass --force if you're certain.
```

This check runs twice — once here in the CLI before it even makes the
HTTP call, and again independently on the natctl side (so a stale or
older daemon doesn't leave you unprotected). Pass `--force` to override
it deliberately — for example, you've already confirmed some other path
(a different VPC subnet, a bastion) still reaches every node, or you're
intentionally decommissioning this environment's own control plane.
`--force` skips both checks and is sent through to the server too, so
the write always succeeds when you pass it.

## The pattern behind the three `set-*` commands

All three write to Object Storage, to the exact same object Terraform
itself writes on every `apply` — none of them are a separate override
layer sitting on top of Terraform's value. Whichever wrote most recently
is what's actually served. This makes them fast and safe for a temporary
change, with one trade-off to keep in mind: **Terraform remains
authoritative long-term** — any later `apply`, for any reason, recomputes
and overwrites the object from its own tfvars-declared or
live-discovered value. Treat a `set-*` command as "right now, until the
next apply," and update the durable Terraform-side value too whenever
the change should actually stick.

None of the three touch the Linode API — they're a plain HTTP POST to a
running `natctl` process, safe to run against any instance regardless of
which one currently holds fleet-controller leadership in the every-node
placement mode.
